# PostgreSQL 18 Shared Memory Internals: Everything Beyond `shared_buffers`

## TL;DR
- Besides the buffer pool (`shared_buffers`), PostgreSQL 18's main shared memory segment holds dozens of named structures registered through `CalculateShmemSize()`/`CreateOrAttachShmemStructs()` in `src/backend/storage/ipc/ipci.c`: buffer descriptors and the buffer mapping hash table, `XLogCtl` + WAL buffers, the SLRU caches (CLOG, subtrans, multixact, commit_ts, serial, notify), the ProcArray/PGPROC array, the heavyweight and predicate lock hash tables, the LWLock array, ProcSignal/PMSignal, checkpointer/bgwriter/autovacuum state, replication (WalSnd/WalRcv/slots/origins/logical launcher), the shared-memory cumulative statistics system, sinval, two-phase state, and the DSM control segment.
- The single most important PG18-specific change is the new **Asynchronous I/O (AIO) subsystem** (`src/backend/storage/aio/`), which allocates its own shared memory (`AioShmemSize()`/`AioShmemInit()` in `aio_init.c`): the `PgAioCtl` control struct with IO handles, iovec and per-block data arrays, plus per-method state — a submission-queue ring and worker-control array for `io_method=worker`, or one io_uring instance per backend for `io_method=io_uring`.
- Other PG18 changes: fast-path locks are now variable-sized and allocated as a **separate** shared segment ("Fast-Path Lock Array") sized by `max_locks_per_transaction` (not a fixed 16), NUMA observability via `pg_shmem_allocations_numa`/`pg_buffercache_numa`, and (from PG17) configurable SLRU buffer sizes via `transaction_buffers`, `subtransaction_buffers`, `multixact_offset_buffers`, etc. Inspect everything with `SELECT * FROM pg_shmem_allocations ORDER BY size DESC;`.

## Key Findings

**1. One estimate, one segment, one index.** At startup the postmaster computes the total size with `CalculateShmemSize()`, creates a single anonymous-mmap (or SysV) segment via `PGSharedMemoryCreate()` (`src/backend/port/sysv_shmem.c`), then carves it up. Every named allocation is registered in the **ShmemIndex** hash table and is visible through `pg_shmem_allocations`. Extensions add to the total via `RequestAddinShmemSpace()` inside a `shmem_request_hook`.

**2. The buffer pool is only the largest of a family of buffer-related structures.** `BufferManagerShmemSize()` (`buf_init.c`) sums the buffer blocks, the `BufferDescriptors` array, the `BufferIOCVArray` condition variables, the checkpoint sort array (`CkptBufferIds`), and the `StrategyControl`/buffer-mapping hash table (`freelist.c`, `buf_table.c`) — all scaling with `NBuffers`.

**3. Transaction/SLRU metadata got user-tunable in PG17.** CLOG, subtrans, multixact offsets/members, commit timestamps, the SSI SLRU and the notify queue each have a configurable buffer pool GUC.

**4. Locking is split across four allocations.** The heavyweight lock table (`LOCK`+`PROCLOCK` hashes), the predicate/SSI structures, the LWLock array and named tranches, and — new in PG18 — the standalone fast-path lock array.

**5. PG18 adds a genuinely new shared-memory subsystem (AIO)** with its own sizing/init entry points and LWLocks, which is the headline internals change versus PG17.

## Details

### 1. Creation and sizing at startup

The entry point is `CreateSharedMemoryAndSemaphores()` in `src/backend/storage/ipc/ipci.c`. In REL_18_STABLE the flow is:

1. `size = CalculateShmemSize(&numSemas)` — estimate total bytes.
2. `PGSharedMemoryCreate(size, &shim)` — create the OS segment (`src/backend/port/sysv_shmem.c`).
3. `InitShmemAccess()` / `InitShmemAllocation()` — set up the low-level bump allocator.
4. `PGReserveSemaphores(numSemas)` — reserve kernel semaphores.
5. `CreateOrAttachShmemStructs()` — call every subsystem's `XxxShmemInit()`.
6. `dsm_postmaster_startup(shim)` — initialize dynamic shared memory.
7. `shmem_startup_hook()` — let preloaded extensions allocate.

`CalculateShmemSize()` starts with a 100000-byte slop allowance plus the ShmemIndex hash, then calls `add_size()` for every subsystem. The full REL_18_STABLE list of size functions (from `ipci.c`'s reference set) is: `hash_estimate_size(SHMEM_INDEX_SIZE,...)`, `dsm_estimate_size()`, `DSMRegistryShmemSize()`, `BufferManagerShmemSize()`, `LockManagerShmemSize()`, `PredicateLockShmemSize()`, `ProcGlobalShmemSize()`, `XLogPrefetchShmemSize()`, `XLOGShmemSize()`, `XLogRecoveryShmemSize()`, `CLOGShmemSize()`, `CommitTsShmemSize()`, `SUBTRANSShmemSize()`, `TwoPhaseShmemSize()`, `BackgroundWorkerShmemSize()`, `MultiXactShmemSize()`, `LWLockShmemSize()`, `ProcArrayShmemSize()`, `BackendStatusShmemSize()`, `SharedInvalShmemSize()`, `PMSignalShmemSize()`, `ProcSignalShmemSize()`, `CheckpointerShmemSize()`, `AutoVacuumShmemSize()`, `ReplicationSlotsShmemSize()`, `ReplicationOriginShmemSize()`, `WalSndShmemSize()`, `WalRcvShmemSize()`, `WalSummarizerShmemSize()`, `PgArchShmemSize()`, `ApplyLauncherShmemSize()`, `SlotSyncShmemSize()`, `BTreeShmemSize()`, `SyncScanShmemSize()`, `AsyncShmemSize()`, `StatsShmemSize()`, `WaitEventCustomShmemSize()`, `InjectionPointShmemSize()`, `AioShmemSize()`, `VarsupShmemSize()`, and `total_addin_request`.

**`ShmemInitStruct()` / `ShmemAlloc()` / ShmemIndex.** Each subsystem calls `ShmemInitStruct("Name", size, &found)`, which looks up "Name" in the ShmemIndex hash table; if absent it bump-allocates via `ShmemAlloc()` and records the name, address and size. Because each entry is named and sized, `pg_shmem_allocations` (`src/backend/storage/ipc/shmem.c`) can report the full inventory, and unallocated slack appears as the special `<anonymous>` / free rows.

**Anonymous mmap and huge pages.** By default `shared_memory_type = mmap`: PostgreSQL allocates the big region as an anonymous `mmap(MAP_SHARED|MAP_ANONYMOUS)` and only keeps a tiny SysV segment (the "shim", ~48 bytes) as a startup-interlock. `huge_pages = try/on` causes `sysv_shmem.c` to request `MAP_HUGETLB`; `InitializeShmemGUCs()` exposes the computed `shared_memory_size` and `shared_memory_size_in_huge_pages` runtime GUCs so you can size `vm.nr_hugepages` before starting.

**DSM/DSA is separate.** The main segment is fixed-size and created once. Dynamic shared memory (`dsm.c`, controlled by `dynamic_shared_memory_type`, default `posix`) is used at runtime for parallel query, and its control segment (`dsm_control`) plus `min_dynamic_shared_memory` are the only DSM footprint in the main segment. The cumulative stats system uses a DSA created *in place* inside the main segment (see §8).

### 2. Buffer-related structures (`buf_init.c`, `freelist.c`, `buf_table.c`)

`BufferManagerShmemSize()` (definition at `buf_init.c:153`) sums, all as functions of `NBuffers`:

| Structure | ShmemInitStruct name | Size formula | Purpose |
|---|---|---|---|
| Buffer blocks | `Buffer Blocks` | `NBuffers * BLCKSZ + PG_IO_ALIGN_SIZE` | The actual 8 KB page frames = `shared_buffers` |
| Buffer descriptors | `Buffer Descriptors` | `NBuffers * sizeof(BufferDescPadded)` | Per-buffer header: tag, state (refcount/usage/flags packed in an atomic `uint32`), wait-list |
| Buffer IO condition vars | `Buffer IO Condition Variables` | `NBuffers * sizeof(ConditionVariableMinimallyPadded)` | Backends wait here for in-progress IO to finish (replaces old IO LWLocks) |
| Checkpoint sort array | (checkpoint sort ids) | `NBuffers * sizeof(CkptSortItem)` | `CkptBufferIds`: lets the checkpointer sort dirty buffers by file/block for sequential writeback |
| Buffer strategy | `Buffer Strategy Status` | `sizeof(BufferStrategyControl)` | `StrategyControl`: clock-sweep hand (`nextVictimBuffer`), the (legacy) freelist head/tail, bgwriter position |
| Buffer lookup table | `Shared Buffer Lookup Table` | `hash_estimate_size(NBuffers + NUM_BUFFER_PARTITIONS, ...)` | The buffer mapping hash (`buf_table.c`) mapping `BufferTag`→buffer id, partitioned into `NUM_BUFFER_PARTITIONS` (128) for lock striping |

Content locks and IO progress no longer use a separate "Buffer IO Locks" array as in old versions: in PG18 the per-buffer content lock is an `LWLock` embedded in the `BufferDesc` (tranche `buffer_content`) and IO completion is signalled via the `BufferIOCVArray` condition variables. `buf_init.c`'s `BufferManagerShmemInit()` initializes each descriptor with `LWLockInitialize()` and `ConditionVariableInit()`, and clears the AIO write-reference (`pgaio_wref_clear`) — a PG18 addition tying buffers to the new AIO subsystem.

### 3. WAL structures (`xlog.c`)

`XLOGShmemSize()` returns:

- `sizeof(XLogCtlData)` — the central `XLogCtl` struct: insertion position, `LogwrtResult`/`LogwrtRqst` write/flush pointers, `InitializedUpTo`, the info spinlock, timeline info, and the `XLogCtlInsert` sub-struct.
- `mul_size(sizeof(WALInsertLockPadded), NUM_XLOGINSERT_LOCKS + 1)` — the **WAL insertion locks** (`NUM_XLOGINSERT_LOCKS` = 8), which serialize reservation of space in the WAL buffers. The "+1" is for alignment padding.
- `mul_size(sizeof(XLogRecPtr), XLOGbuffers)` — the `xlblocks` array mapping each WAL buffer page to its ending LSN.
- `XLOG_BLCKSZ` alignment padding + `mul_size(XLOG_BLCKSZ, XLOGbuffers)` — the **WAL buffers** themselves (`wal_buffers`, auto-tuned to 1/32 of `shared_buffers` when `-1`, via `XLOGChooseNumBuffers()`).

Related WAL/recovery allocations counted separately in `CalculateShmemSize()`: `XLogPrefetchShmemSize()` (recovery prefetch stats), `XLogRecoveryShmemSize()` (recovery-state shared struct), and `WalSummarizerShmemSize()` — the WAL summarizer shared state (`walsummarizer.c`) that supports incremental backup, controlled by `summarize_wal`.

### 4. Transaction, SLRU and varsup structures

`VarsupShmemSize()` covers `TransamVariables` (called `VariableCache` historically) — the shared XID/OID counters (`nextXid`, `oldestXid`, `xidVacLimit`, `nextOid`, etc.).

The SLRU caches, each a `SlruShared` control struct + a page buffer pool + per-page LWLocks, allocated through `SimpleLruShmemSize()` in `slru.c` and its callers. **In PG17 (carried into PG18) their sizes became GUC-configurable** (previously compile-time `NUM_*_BUFFERS` macros):

| SLRU | Source file | GUC (PG17+) | Default | Purpose |
|---|---|---|---|---|
| pg_xact / CLOG | `clog.c` | `transaction_buffers` | 0 = auto (scales with `shared_buffers`) | Commit/abort status, 2 bits/xact |
| pg_subtrans | `subtrans.c` | `subtransaction_buffers` | 0 = auto | Subtransaction → parent xid mapping |
| pg_multixact/offsets | `multixact.c` | `multixact_offset_buffers` | 16 | MultiXact id → members offset |
| pg_multixact/members | `multixact.c` | `multixact_member_buffers` | 32 | MultiXact member arrays |
| pg_commit_ts | `commit_ts.c` | `commit_timestamp_buffers` | 0 = auto | Per-xact commit timestamps (`track_commit_timestamp`) |
| pg_serial | `predicate.c` | `serializable_buffers` | 32 | SSI old-committed-xact conflict tracking |
| NOTIFY queue | `async.c` | `notify_buffers` | 16 | LISTEN/NOTIFY async message SLRU |

`transaction_buffers`, `subtransaction_buffers` and `commit_timestamp_buffers` auto-tune from `shared_buffers` when set to 0. The GUC names were deliberately chosen to avoid the internal term "SLRU"; the corresponding wait events (e.g. `SubtransSLRU`, `MultiXactOffsetSLRU`) and `pg_stat_slru` expose contention.

`CommitTsShmemSize()`, `CLOGShmemSize()`, `SUBTRANSShmemSize()`, `MultiXactShmemSize()` also include small control structs (e.g. multixact's `MultiXactStateData` with the offset/member generation state).

### 5. The proc array and PGPROC (`procarray.c`, `proc.c`)

- `ProcArrayShmemSize()` — the `ProcArrayStruct` with its array of `pgprocnos` (indexes into the PGPROC array), sized `PROCARRAY_MAXPROCS = MaxBackends + max_prepared_xacts`. Under Hot Standby it also allocates the `KnownAssignedXids` array and its valid-flags array (`TOTAL_MAX_CACHED_SUBXIDS`).
- `ProcGlobalShmemSize()` (`proc.c`) sums: `sizeof(PROC_HDR)` (the `ProcGlobal` header with the free lists), a `slock_t`, `PGSemaphoreShmemSize(ProcGlobalSemas())` (one semaphore per backend+aux proc), `PGProcShmemSize()` (the PGPROC array itself plus the auxiliary `PGPROC`s, subxid caches, XID/statusFlags arrays), and `FastPathLockShmemSize()`.

`TotalProcs = MaxBackends + NUM_AUXILIARY_PROCS + max_prepared_xacts`. Each `PGPROC` holds a backend's XID, LSN, wait info, group-commit links (`clogGroupNext`, `procArrayGroupNext`) and the fast-path lock pointers.

**Fast-path locking change in PG18.** Historically each PGPROC held a fixed 16-slot inline fast-path array (introduced in 9.2). In PG18, commit `c4d5cb71d229095a39fda1121a75ee40e6069a2a` ("Increase the number of fast-path lock slots," Tomas Vondra) *replaces the fixed-size array of fast-path locks with arrays, sized on startup based on `max_locks_per_transaction`*, and moves them to a **separate** shared allocation named `Fast-Path Lock Array`, referenced by pointers from each PGPROC. As PostgresAI (Nikolay Samokhvalov, 2025-10-08) puts it, in PG18 "fast-path locks are stored in variable-sized arrays in separate shared memory (referenced via pointers from PGPROC) … [which] scales with `max_locks_per_transaction` (default 64 slots)." `FastPathLockShmemSize()` computes, per proc, `fpLockBitsSize = MAXALIGN(FastPathLockGroupsPerBackend * sizeof(uint64))` and `fpRelIdSize = MAXALIGN(FastPathLockSlotsPerBackend() * sizeof(Oid))`, times `TotalProcs`. The number of 16-way groups is derived from `max_locks_per_transaction` (using a 2^n rule up to 1024 groups = 16384 slots); with the default `max_locks_per_transaction = 64` you get 64 fast-path slots per backend instead of 16. This dramatically reduces `LWLock:LockManager` contention on partition-heavy workloads. `InitializeFastPathLocks()` (in `postinit.c`) recomputes the group count, and in EXEC_BACKEND builds it is re-run in `AttachSharedMemoryStructs()`.

### 6. Lock managers (`lock.c`, `predicate.c`, `lwlock.c`)

- **Heavyweight locks:** `LockManagerShmemSize()` (formerly `LockShmemSize()`; renamed in PG18) estimates two partitioned hash tables — the `LOCK` table (lockable objects) and the `PROCLOCK` table (per-holder), each sized `NLOCKENTS() = max_locks_per_transaction * (MaxBackends + max_prepared_xacts)` and partitioned into `NUM_LOCK_PARTITIONS` (16). `LockManagerShmemInit()` creates them; backends inherit pointers via fork and keep a private locallock hash.
- **Predicate/SSI locks:** `PredicateLockShmemSize()` estimates the `PREDICATELOCKTARGET` hash (`NPREDICATELOCKTARGETENTS()` from `max_pred_locks_per_transaction`), the `PREDICATELOCK` hash (2×), the `PredXactList` of `SERIALIZABLEXACT` structures (`(MaxBackends + max_prepared_xacts) * 10`), the `SERIALIZABLEXID` hash, and the `RWConflictPool` (×5), plus a 10% safety margin. `PredicateLockShmemInit()` (formerly `InitPredicateLocks()`) builds them.
- **LWLocks:** `LWLockShmemSize()` covers the main LWLock array plus named tranches. Individual (named) LWLocks are declared in `lwlocklist.h`; dynamic tranches are registered by `LWLockRegisterTranche()` and buffer/predicate/etc. tranches by their subsystems. Extensions request LWLocks with `RequestNamedLWLockTranche()`. In PG18 named LWLock tranche requests are themselves stored in shared memory (commit by Nathan Bossart) to fix an EXEC_BACKEND segfault.

Spinlocks are compiled inline (the `--disable-spinlocks` emulation-via-semaphores path was removed), so there is no separate spinlock semaphore allocation in PG18; the per-backend semaphores are for PGPROC waits and are allocated inside `ProcGlobalShmemSize()`.

### 7. Process management, signalling and background subsystems

| Structure | Size func / file | Sizing GUCs | Purpose |
|---|---|---|---|
| `BackendStatusArray` | `BackendStatusShmemSize()` `backend_status.c` | `MaxBackends` (+ aux) | Backs `pg_stat_activity`: each `PgBackendStatus` holds state, query text (in a separate activity-string buffer), wait event, etc. |
| ProcSignal | `ProcSignalShmemSize()` `procsignal.c` | `NumProcSignalSlots` = `MaxBackends + NUM_AUXILIARY_PROCS` | Per-backend signal slots + the **ProcSignalBarrier** generation machinery for global barriers |
| PMSignal | `PMSignalShmemSize()` `pmsignal.c` | fixed + `MaxLivePostmasterChildren` | Child→postmaster status signalling |
| Checkpointer | `CheckpointerShmemSize()` `checkpointer.c` | request queue = `NBuffers` | `CheckpointerShmem`: the fsync request queue backends hand to the checkpointer, plus checkpoint progress counters |
| Autovacuum | `AutoVacuumShmemSize()` `autovacuum.c` | `autovacuum_worker_slots` / `autovacuum_max_workers` | `AutoVacuumShmemStruct`: worker free-list, current-worker table, work items |
| Background workers | `BackgroundWorkerShmemSize()` `bgworker.c` | `max_worker_processes` | `BackgroundWorkerArray` registration slots |
| WAL senders | `WalSndShmemSize()` `walsender.c` | `max_wal_senders` | `WalSndCtl`: per-sender slots + sync-standby state |
| WAL receiver | `WalRcvShmemSize()` `walreceiver.c` | fixed (1) | `WalRcv`/`WalRcvData`: single receiver state on a standby |
| Replication slots | `ReplicationSlotsShmemSize()` `slot.c` | `max_replication_slots` | `ReplicationSlotCtl` + `ReplicationSlot` array (physical/logical slots) |
| Replication origins | `ReplicationOriginShmemSize()` `origin.c` | `max_replication_slots` | Origin progress tracking for logical replication |
| Logical launcher | `ApplyLauncherShmemSize()` `launcher.c` | `max_logical_replication_workers` | Launcher + apply-worker slots |
| Slot sync | `SlotSyncShmemSize()` `slotsync.c` | fixed | Standby slot-synchronization state (failover slots) |
| Archiver | `PgArchShmemSize()` `pgarch.c` | fixed | `PgArch`: archiver process state |

### 8. The shared-memory statistics system (`pgstat_shmem.c`)

Since PG15 the cumulative statistics collector is gone; stats live in shared memory. `StatsShmemSize()` returns `MAXALIGN(sizeof(PgStat_ShmemControl))` plus `pgstat_dsa_init_size()` (256 KB) plus, in PG18, space for **custom fixed-numbered stats kinds** (the pluggable cumulative-statistics API, commit `7949d9594582`). `StatsShmemInit()` creates the `Shared Memory Stats` allocation, then `dsa_create_in_place()` builds a DSA **inside** the main segment and a dshash table for variable-numbered objects (tables, functions, relations, replication slots). Fixed-numbered stats (WAL, archiver, bgwriter, checkpointer, IO, SLRU) are stored directly in `PgStat_ShmemControl`. `pg_stat_io` (with PG18's new `read_bytes`/`write_bytes` columns) and WAL statistics are part of this fixed area.

### 9. Other subsystems

- **Shared invalidation (sinval):** `SharedInvalShmemSize()` (`sinvaladt.c`, formerly `SInvalShmemSize`) allocates the `SISeg` — the ring buffer of `SharedInvalidationMessage`s (catalog/relcache invalidations) with a per-backend `ProcState` array (`MaxBackends`).
- **NOTIFY/LISTEN:** `AsyncShmemSize()` (`async.c`) — the `AsyncQueueControl` head/tail pointers plus per-backend queue positions; the message bodies live in the `notify_buffers` SLRU (§4).
- **Two-phase commit:** `TwoPhaseShmemSize()` (`twophase.c`) — the `TwoPhaseState` array of `GlobalTransaction`/`GlobalTransactionData` entries, sized by `max_prepared_transactions`.
- **DSM control & registry:** `dsm_estimate_size()` (main-segment DSM bookkeeping + `min_dynamic_shared_memory` pre-reserve) and `DSMRegistryShmemSize()` — the DSM registry (§10).
- **Misc small ones:** `BTreeShmemSize()` (nbtree vacuum cycle-id counter), `SyncScanShmemSize()` (synchronized seqscan positions), `WaitEventCustomShmemSize()` (custom wait-event name registry, PG17+), and `InjectionPointShmemSize()` (only meaningful with `--enable-injection-points`).

### 10. Extension mechanism and ordering

1. An extension in `shared_preload_libraries` sets a `shmem_request_hook` in `_PG_init()`, and inside it calls `RequestAddinShmemSpace(size)` and `RequestNamedLWLockTranche(name, n)`. These fail with `cannot request additional shared memory outside shmem_request_hook` if called elsewhere — `RequestAddinShmemSpace` checks `process_shmem_requests_in_progress`.
2. The requested bytes accumulate in `total_addin_request`, added into `CalculateShmemSize()`.
3. After the core structs are built, `CreateSharedMemoryAndSemaphores()` calls the `shmem_startup_hook`, where the extension does `ShmemInitStruct()` to claim its space and `GetNamedLWLockTranche()` to get its locks. **`pg_stat_statements`** is the canonical example: `pgss_shmem_request()` calls `RequestAddinShmemSpace(pgss_memsize())` and (historically) `RequestNamedLWLockTranche("pg_stat_statements", 1)`; `pgss_shmem_startup()` allocates the hash and query-text file state. In PG18 core converted `pg_stat_statements` to embed its `LWLock` in its own struct rather than use `RequestNamedLWLockTranche`.
4. **DSM registry alternative (PG17+):** `GetNamedDSMSegment(name, size, init_cb, &found)` (`dsm_registry.c`) lets a library allocate/attach a DSM segment by string name *without* `shared_preload_libraries` — the handle is stored in a dshash keyed by name. PG18 adds `GetNamedDSA()` and `GetNamedDSHash()` helpers. The injection-points test module uses `GetNamedDSMSegment` for its shared state.

### 11. PG18 AIO subsystem (`src/backend/storage/aio/`)

New in PG18, controlled by `io_method` (initial commit `da722699`). The default is **`worker`**; `io_uring` can be selected only if PostgreSQL was built with `--with-liburing`/`-Dliburing` (otherwise the server errors with `HINT: Available values: sync, worker`); `sync` mirrors the pre-18 synchronous path. `AioShmemSize()`/`AioShmemInit()` in `aio_init.c` allocate:

- **`PgAioCtl`** (ShmemInitStruct `AioCtl`): the top-level control struct holding the `io_handles` array of `PgAioHandle` (one set of `io_max_concurrency` handles per process), the shared `iovecs` array, and the per-block `handle_data` array. `AioShmemSize()` sums `AioCtlShmemSize()`, per-backend backend state, the handle array, the iovec array (`sizeof(struct iovec) * io_max_combine_limit * AioProcs() * io_max_concurrency`), the handle-data array (same shape with `uint64`), and the per-method size.
- **`AioProcs()` = `MaxBackends + NUM_AUXILIARY_PROCS`.** `io_max_concurrency` defaults to -1 (auto, capped at 64) and is a `PGC_POSTMASTER` GUC because it sizes shared memory; `effective_io_concurrency` (per-session) governs how much any one scan issues. Note that PG18 raised `effective_io_concurrency`'s default from 1 to 16 (commit `ff79b5b2aba02d720f9b7fff644dd50ce07b8c6e`, Melanie Plageman — "The new default is 16, which should be more appropriate for common hardware while still avoiding flooding low IOPs devices with I/O requests"; `maintenance_io_concurrency` likewise defaults to 16).
- **`io_method=worker`** (`method_worker.c`): a `PgAioWorkerSubmissionQueue` ring buffer (`io_worker_queue_size` = 64, rounded to a power of two) into which backends push IO ids, and a `PgAioWorkerControl` with a `workers[]` flexible array of `PgAioWorkerSlot` (each holding a `Latch*` and `in_use`), sized for `MAX_IO_WORKERS` = 32. In PG18 the pool is **static**: the `io_workers` GUC defaults to 3 (min 1, max 32, `PGC_SIGHUP`) and you pick the size at boot; PGPROC slots for all 32 are reserved unconditionally (so `NUM_AUXILIARY_PROCS` grows to include `MAX_IO_WORKERS`). Only one named LWLock, `AioWorkerSubmissionQueue` (id 53 in `lwlocklist.h`), guards the queue. (The auto-scaling `io_min_workers`/`io_max_workers`/`io_worker_idle_timeout`/`io_worker_launch_interval` pool and the extra `AioWorkerControl` LWLock are a **PG19/master** change — "PG19 replaces that single dial with a self-managed worker pool" — and are *not* in PG18.)
- **`io_method=io_uring`** (`method_io_uring.c`): one `PgAioUringContext` per backend (cacheline-aligned, containing an embedded `completion_lock` LWLock of tranche `AioUringCompletion` and a `struct io_uring`). The count is `pgaio_uring_procs() = MaxBackends + NUM_AUXILIARY_PROCS - MAX_IO_WORKERS` (IO workers are unused under io_uring). Rings and contexts are allocated together in a single `AioUringContext` ShmemInitStruct; when the kernel/liburing supports `io_uring_queue_init_mem()` with `IORING_SETUP_NO_MMAP`, the ring memory is placed directly in Postgres shared memory (page-aligned), otherwise `io_uring_queue_init()` is used. Each ring has depth `io_max_concurrency`. Rings are created in the postmaster so any backend can reap another's completions.

`sync` mode uses the same AIO API path synchronously and needs no extra shared memory. The new `pg_aios` view exposes in-flight IO handles.

### 12. PG18 vs PG17 summary of shared-memory changes

- **AIO subsystem** — entirely new (`AioShmemSize`/`AioShmemInit`, `PgAioCtl`, worker/uring state, `AioWorkerSubmissionQueue` + `AioUringCompletion` LWLocks).
- **Fast-path locks** — moved from fixed 16-slot inline arrays in PGPROC to a variable-size, separately-allocated `Fast-Path Lock Array` sized by `max_locks_per_transaction` (commit `c4d5cb71d229`).
- **NUMA observability** — `pg_shmem_allocations_numa` view and `pg_buffercache_numa` (build with `--with-libnuma`), plus `pg_numa_available()`. These do not add structures but report per-NUMA-node distribution of the existing segment (they touch every page, so they are expensive and force allocation).
- **Buffer manager** — content locks/IO handled via embedded LWLock + condition variables + AIO write-refs; function renames (`BufferShmemSize`→`BufferManagerShmemSize`, `InitBufferPool`→`BufferManagerShmemInit`).
- **Naming cleanups** — `LockShmemSize`→`LockManagerShmemSize`, `SInvalShmemSize`→`SharedInvalShmemSize`, `CreateSharedProcArray`→`ProcArrayShmemInit`.
- **Custom cumulative statistics** — pluggable stats kinds add fixed-stat space to `StatsShmemSize()`.
- Data checksums default on (unrelated to shmem layout but a PG18 initdb default), and per-backend IO stats via `pg_stat_get_backend_io()`.

The PG17 SLRU-buffer GUCs (`transaction_buffers` et al.) and the DSM registry (`GetNamedDSMSegment`) both carry into PG18 unchanged in concept.

## Recommendations

1. **Baseline your allocations first.** Run `SELECT name, size, pg_size_pretty(size) FROM pg_shmem_allocations ORDER BY size DESC;` on the target instance. `Buffer Blocks` should dominate; the next tier is typically `Buffer Descriptors`, `XLOG Ctl`/WAL buffers, the lock hash tables, and `Shared Memory Stats`. Anything unexpectedly large points at a mis-set GUC.
2. **Tune the connection-scaled structures deliberately.** `max_connections`, `max_prepared_transactions`, `max_locks_per_transaction` and `max_pred_locks_per_transaction` multiply through the PGPROC array, ProcArray, both lock tables, the fast-path array and the predicate structures. On PG18, raising `max_locks_per_transaction` now *also* enlarges the fast-path array (helping partition-heavy `LWLock:LockManager` contention) — a good reason to raise it to 128–256 on partitioned workloads, budgeting the extra memory.
3. **Address SLRU contention with the PG17+ GUCs, not recompilation.** If `pg_stat_slru` or wait events (`SubtransSLRU`, `MultiXactOffsetSLRU`, `MultiXactMemberSLRU`) show pressure, raise `subtransaction_buffers`, `multixact_offset_buffers`, `multixact_member_buffers` (restart required). Leave the auto-tuned ones (`transaction_buffers`, `commit_timestamp_buffers`) at 0 unless you have measured need.
4. **Choose the AIO method by platform.** On modern Linux (kernel ≥5.1) built `--with-liburing` and where your security posture allows it, prefer `io_method=io_uring` (lowest syscall overhead, one ring per backend). Otherwise keep the default `worker` and, in PG18, tune the static `io_workers` (start at 3, raise if you see submission-queue fallback to synchronous IO); size `io_max_concurrency`/`effective_io_concurrency` to your storage queue depth. Use `sync` only for regression testing or to rule AIO out. AIO in 18 accelerates reads only (sequential scans, bitmap heap scans, VACUUM/ANALYZE); do not expect write-path gains.
5. **For huge pages,** read the computed `shared_memory_size_in_huge_pages` GUC (`SHOW shared_memory_size_in_huge_pages;`) and set `vm.nr_hugepages` accordingly with `huge_pages=try` first, `on` once validated.
6. **Extension authors:** prefer the DSM registry (`GetNamedDSMSegment`/`GetNamedDSA`/`GetNamedDSHash`) when you can, to avoid forcing users into `shared_preload_libraries`; use `shmem_request_hook` + `RequestAddinShmemSpace` only when you truly need main-segment space at startup, and embed your LWLock in your own struct (as core PG18 now does for `pg_stat_statements`).

**Benchmarks/thresholds that change the advice:** if `pg_shmem_allocations` free space is near zero and startup fails with "out of shared memory", raise the offending GUC or total; if `LWLock:LockManager` waits exceed a few percent of wait time, raise `max_locks_per_transaction`; if AIO submission stalls appear (worker mode) increase `io_workers`; if `io_uring` is unavailable at runtime (`io_uring_disabled`), fall back to `worker`.

## Caveats

- **Master vs REL_18_STABLE drift.** The public doxygen and GitHub `master` mirror already contain PG19-era refactors that are *not* in PG18: notably the auto-scaling IO worker pool (`io_min_workers`/`io_max_workers`/`io_worker_idle_timeout`/`io_worker_launch_interval` and the `AioWorkerControl` LWLock — PG19 is in feature freeze headed for a ~September 2026 release), and an in-progress "resize shared_buffers without restart" reorganization of `ipci.c` (subsystem callback lists, `ShmemInitRegistered`). This report describes PG18 behavior (static `io_workers` default 3/max 32; `CalculateShmemSize`/`CreateOrAttachShmemStructs` as shipped). Verify exact line numbers against the REL_18_STABLE tag rather than `master`.
- **Exact byte sizes vary** with `BLCKSZ`, alignment (`PG_IO_ALIGN_SIZE`, `MAXALIGN`, cacheline padding), platform pointer width, and the 10%/safety margins some size functions add; treat the formulas as structural, not exact. `pg_shmem_allocations` is authoritative for a running instance.
- **`pg_shmem_allocations_numa` and `pg_buffercache_numa`** require `--with-libnuma` and are Linux-only; they are deliberately slow (they touch every page and can force allocation) and exclude anonymous and DSM allocations — do not poll them from monitoring.
- Some numbers cited (e.g. `NUM_XLOGINSERT_LOCKS`=8, `NUM_LOCK_PARTITIONS`=16, `NUM_BUFFER_PARTITIONS`=128, `MAX_IO_WORKERS`=32, `io_worker_queue_size`=64, `io_max_concurrency` cap 64, `notify_buffers`/`multixact_offset_buffers` defaults 16) are compile-time constants/defaults for stock PG18 and can differ in patched or vendor builds.
- The AIO subsystem in PG18 covers **reads** (seq scans, bitmap heap scans, VACUUM/ANALYZE); the write path remains synchronous (WAL is still written and flushed before commit; shared-buffer writes still go through bgwriter/checkpointer), so AIO shared-memory structures are provisioned but exercised only for read-side IO in 18.0.