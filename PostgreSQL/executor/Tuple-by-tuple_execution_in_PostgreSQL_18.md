# Tuple-by-tuple execution in PostgreSQL 18

PostgreSQL 18's `REL_18_STABLE` branch preserves the classic Volcano/Iterator executor but rewires the bottom of the stack so that buffer reads are **asynchronous and vectored** through a new `read_stream` API backed by `pgaio`. The per-tuple contract ­— a parent calls `ExecProcNode(child)` and receives one `TupleTableSlot *` until the slot is empty — is unchanged, and the executor still resets a per-tuple memory context between tuples. What has changed is that `SeqScan`, `BitmapHeapScan`, and maintenance scans no longer synchronously `ReadBuffer()` one page at a time; they register a callback with a `ReadStream` whose lookahead pins blocks in advance via `io_method = worker | io_uring | sync`. For a performance engineer on a PG18 fork, the practical consequences are concentrated at four seams: (1) `heap_beginscan` now allocates `scan->rs_read_stream`; (2) `heap_getnextslot` pulls pre-pinned buffers from `read_stream_next_buffer` instead of issuing a `ReadBuffer`; (3) `nodeBitmapHeapscan.c` shrank dramatically (`2b73a8cd3`) because prefetch is now the stream's job; and (4) `heapgettup_pagemode` remains the tuple-level inner loop, unchanged in shape but now fed warm buffers. The volcano iterator and expression interpreter above that seam — `ExecProcNodeMtd` dispatch, `ExprState`/`EEOP_*` opcodes, `TupleTableSlotOps`, per-tuple `ExprContext` resets — operate identically to PG16/17.

Below is a layered walkthrough, grounded in the source tree and in PG18 commits (in particular Thomas Munro's `b5a9b18cd0` / Melanie Plageman's `2b73a8cd3`, and the Andres Freund / Munro / Yavuz / Plageman AIO merge documented in the PG18 release notes).

---

## 1. The Volcano/pull model in `src/backend/executor`

### 1.1 `ExecProcNode`: a virtual method per `PlanState`

The executor is a tree of `PlanState` nodes that mirror the planner's `Plan` tree. Every `PlanState` (see `src/include/nodes/execnodes.h`) carries **two** function pointers:

```c
typedef TupleTableSlot *(*ExecProcNodeMtd) (struct PlanState *pstate);

struct PlanState {
    NodeTag         type;
    Plan           *plan;
    EState         *state;
    ExecProcNodeMtd ExecProcNode;      /* the entry actually called */
    ExecProcNodeMtd ExecProcNodeReal;  /* the real node method */
    Instrumentation *instrument;
    ...
    ExprState      *qual;
    PlanState      *lefttree;
    PlanState      *righttree;
    ...
    TupleTableSlot *ps_ResultTupleSlot;
    ExprContext    *ps_ExprContext;
    ProjectionInfo *ps_ProjInfo;
};
```

`ExecProcNode` is declared as a `static inline` in `src/include/executor/executor.h` and simply calls the function pointer:

```c
static inline TupleTableSlot *
ExecProcNode(PlanState *node) {
    if (node->chgParam != NULL) ExecReScan(node);
    return node->ExecProcNode(node);
}
```

**The two-step wrapper.** During `ExecInitNode` (in `execProcnode.c`), each node installs its concrete method (e.g. `ExecSeqScan`, `ExecHashJoin`) via `ExecSetExecProcNode(ps, ExecFoo)` (`execProcnode.c:~430`). That routine does not store `ExecFoo` into `ExecProcNode` directly — it stores it into `ExecProcNodeReal` and puts `ExecProcNodeFirst` into `ExecProcNode`:

```c
void
ExecSetExecProcNode(PlanState *node, ExecProcNodeMtd function) {
    node->ExecProcNodeReal = function;
    node->ExecProcNode     = ExecProcNodeFirst;
}
```

`ExecProcNodeFirst` (`execProcnode.c:~448`) performs **one-time** work on the very first invocation of the node: `check_stack_depth()` (expensive on x86 and thus amortized once per node), and, if instrumentation is active, it swaps `ExecProcNode` to `ExecProcNodeInstr` (the wrapper that calls `InstrStartNode` / `InstrStopNode`). Otherwise it overwrites `node->ExecProcNode = node->ExecProcNodeReal;` so all subsequent calls are a direct indirect call to the real node function with zero dispatch cost beyond one load and one branch. This is the Volcano dispatch: a virtual call per tuple per node, cache-friendly because `ExecProcNode` and `ExecProcNodeReal` are packed at the top of `PlanState`.

### 1.2 `ExecutorRun` → `ExecutePlan`: the pump

Top-of-stack control flow lives in `src/backend/executor/execMain.c`:

```
ExecutorRun (hook) → standard_ExecutorRun → ExecutePlan
```

`ExecutePlan` is the only loop that ever has to exist: parents pull children transitively, so the outermost loop is:

```c
for (;;) {
    slot = ExecProcNode(planstate);         /* recurse down the tree */
    if (TupIsNull(slot)) break;             /* empty slot = EOF */
    if (sendTuples)
        if (!dest->receiveSlot(slot, dest)) /* printtup, COPY, SPI, etc. */
            break;
    if (numberTuples && ++current_tuple_count >= numberTuples) break;
}
```

Everything else — joins, sorts, aggregates — is implemented as one node pulling another's `ExecProcNode` inside its own body. There is no top-level scheduler.

### 1.3 `TupleTableSlot` — the tuple carrier

The single data type that travels between nodes is `TupleTableSlot *` (`src/include/executor/tuptable.h`). A slot is a **polymorphic tuple container** with a virtual-method table `TupleTableSlotOps` (`const struct TupleTableSlotOps *tts_ops`). Four ops families are instantiated in `src/backend/executor/execTuples.c`:

| Ops family | Backing storage | Typical use |
|---|---|---|
| `TTSOpsVirtual` | `Datum[]` + `bool null[]` arrays only | Output of `ExecProject`, expressions |
| `TTSOpsHeapTuple` | A palloc'd `HeapTuple` the slot owns | Materialized or hand-built heap tuples |
| `TTSOpsMinimalTuple` | `MinimalTuple` (no xmin/xmax header) | Hash join inner side, sort, tuplestore, shm_mq |
| `TTSOpsBufferHeapTuple` | Pointer to a tuple *inside a pinned shared buffer* | Output of all heap scans |

Key invariants encoded in `TTS_FLAG_*` bits:

- `TTS_FLAG_EMPTY` — cleared by `ExecClearTuple`, the universal "no tuple here" marker (`TupIsNull` checks this).
- `TTS_FLAG_SHOULDFREE` — slot owns a palloc'd tuple and must free on clear/replace.
- `TTS_FLAG_FIXED` — slot is bound to one ops family.

The lifecycle per tuple in a scan node is:

```
ExecClearTuple(slot)                  /* drop prior tuple, unpin prior buffer */
  → heap_getnextslot(scan, dir, slot) /* TAM fills slot */
      → ExecStoreBufferHeapTuple(tuple, slot, buffer) 
            /* stores pointer into buffer, pins buffer, sets tts_tid */
  → slot_getsomeattrs(slot, nattrs)   /* lazy deform, virtual column cache */
```

`ExecStoreBufferHeapTuple` is the hot-path entry for scans: it does **not** copy the tuple, it stores the pointer to the on-page `HeapTupleHeader` and acquires an extra pin on the buffer so the tuple remains valid across the caller's processing. `ExecStoreHeapTuple` (in-memory) and `ExecStoreMinimalTuple` (sort/hashjoin) are the other common storers. `ExecStoreVirtualTuple` is called by `ExecProject` to mark a virtual slot as populated after the interpreter has written `tts_values[]`/`tts_isnull[]`.

Column extraction is lazy. `slot_getsomeattrs(slot, n)` calls the ops' `getsomeattrs` callback (e.g. `tts_buffer_heap_getsomeattrs`), which calls `heap_deform_tuple` only up to attribute `n` using `tts_nvalid` as a resume cursor. Because PG has variable-width attributes and NULL bitmaps, deforming only what is needed is a large portion of real-world scan CPU; the JIT path specializes this further.

### 1.4 `ExprContext`, `ExprState`, and the per-tuple memory context

Every `PlanState` that evaluates expressions holds an `ExprContext` (in `node->ps_ExprContext`, built by `ExecAssignExprContext` in `execUtils.c`). The crucial field is:

```c
MemoryContext ecxt_per_tuple_memory;    /* reset PER TUPLE */
MemoryContext ecxt_per_query_memory;    /* lives for the query */
TupleTableSlot *ecxt_scantuple, *ecxt_innertuple, *ecxt_outertuple;
ParamListInfo   ecxt_param_list_info;
```

`ResetExprContext(econtext)` calls `MemoryContextReset(ecxt_per_tuple_memory)`. This is the discipline that makes the executor memory-safe in O(1): every intermediate `Datum` allocated during expression evaluation (detoasted varlenas, concatenated strings, numeric intermediates) is allocated in the per-tuple context and freed in bulk at the next tuple boundary. The reset happens in three canonical places:

1. Inside `ExecScan` (`execScan.c`) between tuples when re-checking quals.
2. At the top of `ExecProject` via `ResetExprContext(econtext)` (actually controlled by the node — e.g. `ExecQualAndReset`).
3. In `nodeAgg.c`'s `advance_aggregates` loop between input tuples (`ResetExprContext(aggstate->tmpcontext)`).

Expressions compile into an `ExprState` (`src/backend/executor/execExpr.c`, `ExecInitExpr` → `ExecInitExprRec` → `ExecReadyExpr`). An `ExprState` is essentially a linear program of `ExprEvalStep` opcodes (`EEOP_*`). The steps include `EEOP_INNER_VAR`, `EEOP_SCAN_VAR`, `EEOP_CONST`, `EEOP_FUNCEXPR_STRICT`, `EEOP_BOOL_AND_STEP`, `EEOP_ASSIGN_SCAN_VAR`, `EEOP_AGG_STRICT_INPUT_CHECK_ARGS`, and so on — around 80 opcodes in PG18. The expression is executed by:

- **Interpreter** (`src/backend/executor/execExprInterp.c`, `ExecInterpExpr`): a computed-goto dispatch (`EEO_SWITCH`/`EEO_CASE`/`EEO_DISPATCH` macros use `&&label` on GCC/Clang, fall back to `switch` otherwise). Each opcode advances `op++` and jumps; `EEOP_DONE` returns.
- **JIT** (`src/backend/jit/llvm/llvmjit_expr.c`, not part of this report): emits LLVM IR that inlines the same opcodes into native code when cost thresholds `jit_above_cost`, `jit_inline_above_cost`, `jit_optimize_above_cost` are exceeded.

`ExecBuildProjectionInfo` (`execExpr.c`) builds a single `ExprState` whose last opcodes are `EEOP_ASSIGN_{SCAN,INNER,OUTER}_VAR` steps that write directly into the target virtual slot's `tts_values[]` / `tts_isnull[]`. That is why `ExecProject` can be so cheap: there is no intermediate tuple; the expression interpreter writes columns in place, then `ExecStoreVirtualTuple` clears `EMPTY` on the result slot.

`ExecQual(qualstate, econtext)` (`executor.h`, inline) is the same machinery: it runs the ExprState, reads `*op->resvalue`, and returns `bool`. Short-circuit AND is encoded as `EEOP_BOOL_AND_STEP`/`EEOP_QUAL` with forward jump offsets.

### 1.5 A tuple's round-trip through one scan node

The canonical `ExecScan` loop in `src/backend/executor/execScan.c` is:

```
ExecScan(ScanState *node, ExecScanAccessMtd accessMtd, ExecScanRecheckMtd recheck):
    econtext = node->ps.ps_ExprContext
    for (;;) {
        ResetExprContext(econtext);                 /* free prior per-tuple allocs */
        slot = accessMtd(node);                     /* e.g. SeqNext → table_scan_getnextslot */
        if (TupIsNull(slot)) return ExecClearTuple(node->ps.ps_ResultTupleSlot);
        econtext->ecxt_scantuple = slot;            /* make Vars resolvable */
        if (qual == NULL || ExecQual(qual, econtext))
            return projInfo ? ExecProject(projInfo) : slot;
        InstrCountFiltered1(node, 1);
        /* failed qual → loop for next tuple */
    }
```

So per tuple, in order: **reset per-tuple memory context → TAM call → visibility check (inside TAM) → point `ecxt_scantuple` at the buffer slot → run qual interpreter → optionally run projection interpreter → hand slot up**.

---

## 2. Storage layer: Table AM, heap, MVCC, buffers

### 2.1 The Table Access Method indirection

`src/include/access/tableam.h` defines `TableAmRoutine`, a ~40-entry vtable reached through `Relation->rd_tableam`. The callers use thin `static inline` wrappers:

```c
static inline bool
table_scan_getnextslot(TableScanDesc scan, ScanDirection dir,
                       TupleTableSlot *slot)
{
    return scan->rs_rd->rd_tableam->scan_getnextslot(scan, dir, slot);
}
```

For heap, the vtable is `heapam_methods` in `src/backend/access/heap/heapam_handler.c`:

```c
static const TableAmRoutine heapam_methods = {
    .slot_callbacks            = heapam_slot_callbacks,     /* -> TTSOpsBufferHeapTuple */
    .scan_begin                = heap_beginscan,
    .scan_end                  = heap_endscan,
    .scan_rescan               = heap_rescan,
    .scan_getnextslot          = heap_getnextslot,
    .scan_set_tidrange         = heap_set_tidrange,
    .scan_getnextslot_tidrange = heap_getnextslot_tidrange,
    .parallelscan_estimate     = table_block_parallelscan_estimate,
    .parallelscan_initialize   = table_block_parallelscan_initialize,
    .parallelscan_reinitialize = table_block_parallelscan_reinitialize,
    .index_fetch_begin         = heapam_index_fetch_begin,
    .index_fetch_reset         = heapam_index_fetch_reset,
    .index_fetch_end           = heapam_index_fetch_end,
    .index_fetch_tuple         = heapam_index_fetch_tuple,
    .tuple_insert              = heapam_tuple_insert,
    .tuple_update              = heapam_tuple_update,
    .tuple_delete              = heapam_tuple_delete,
    .tuple_lock                = heapam_tuple_lock,
    /* ... TID bitmap callbacks are now block-driven via read_stream ... */
};
```

### 2.2 `HeapScanDescData` and `heap_beginscan`

The scan state lives in `struct HeapScanDescData` (`src/include/access/heapam.h`). In **PG18 the key additions are `rs_read_stream`, `rs_prefetch_block`, and `rs_dir`**:

```c
typedef struct HeapScanDescData {
    TableScanDescData rs_base;       /* rd, rs_snapshot, rs_flags, rs_parallel, rs_tbmiterator */
    BlockNumber       rs_nblocks;    /* set by RelationGetNumberOfBlocks at init */
    BlockNumber       rs_startblock;
    BlockNumber       rs_numblocks;
    bool              rs_inited;
    HeapTupleData     rs_ctup;       /* current tuple (HeapTupleData header) */
    Buffer            rs_cbuf;       /* currently pinned buffer (NULL after stream fetch) */
    BlockNumber       rs_cblock;     /* current block number */
    int               rs_cindex;     /* current index into rs_vistuples[] */
    int               rs_ntuples;    /* number of entries in rs_vistuples[] */
    OffsetNumber      rs_vistuples[MaxHeapTuplesPerPage]; /* visible offsets on current page */
    BufferAccessStrategy rs_strategy;

    /* --- PG18 streaming I/O additions --- */
    ReadStream       *rs_read_stream;
    BlockNumber       rs_prefetch_block;
    ScanDirection     rs_dir;
    bool              rs_inited;
    ParallelBlockTableScanWorkerData *rs_parallelworkerdata;
} HeapScanDescData;
```

`heap_beginscan` (`heapam.c`) allocates the descriptor, opens `rs_strategy = GetAccessStrategy(BAS_BULKREAD)` for large scans (a ring buffer of 256 KB so a seqscan does not evict shared buffers), and — if the scan is of a kind that wants streaming (plain seqscan, TID-range, sample) — attaches a read stream:

```c
if (rs_flags & SO_TYPE_SEQSCAN || ... ) {
    ReadStreamBlockNumberCB cb = (scan->rs_base.rs_parallel)
                                  ? heap_scan_stream_read_next_parallel
                                  : heap_scan_stream_read_next_serial;
    scan->rs_read_stream =
        read_stream_begin_relation(READ_STREAM_SEQUENTIAL | READ_STREAM_USE_BATCHING,
                                   scan->rs_strategy, relation,
                                   MAIN_FORKNUM, cb, scan, 0);
}
```

The two PG18 callbacks (`heapam.c`) are tiny:

```c
static BlockNumber
heap_scan_stream_read_next_serial(ReadStream *stream, void *cbdata, void *pbd)
{
    HeapScanDesc scan = (HeapScanDesc) cbdata;
    if (unlikely(!scan->rs_inited)) {
        scan->rs_prefetch_block = heapgettup_initial_block(scan, scan->rs_dir);
        scan->rs_inited = true;
    } else
        scan->rs_prefetch_block = heapgettup_advance_block(scan,
                                      scan->rs_prefetch_block, scan->rs_dir);
    return scan->rs_prefetch_block;
}
```

`heap_scan_stream_read_next_parallel` instead calls `table_block_parallelscan_nextpage` under a spinlock/atomics on the shared `ParallelBlockTableScanDesc`.

### 2.3 `heap_getnextslot` and `heap_prepare_pagescan`

`heap_getnextslot` wraps `heapgettup_pagemode`, the **page-at-a-time** inner loop. It has two levels:

1. **Page arrival.** When `rs_cindex >= rs_ntuples`, the current page is exhausted. The scan calls `heap_prepare_pagescan`, which in PG18:
   - releases the previous buffer pin,
   - calls `read_stream_next_buffer(rs_read_stream, NULL)` to obtain the **already-prefetched, pinned** buffer for the next target block (this is the core AIO integration point),
   - acquires a share lock on the buffer,
   - walks every `ItemId` on the page, checking `ItemIdIsNormal`, running `HeapTupleSatisfiesVisibility` once, and recording the visible offsets into `rs_vistuples[0..rs_ntuples-1]`,
   - releases the buffer share lock (but keeps the pin for the duration of the page).
   
2. **Tuple delivery.** `heapgettup_pagemode` then advances `rs_cindex` through `rs_vistuples[]`, and for each offset does:
   ```c
   ItemId  lp     = PageGetItemId(page, offnum);
   HeapTupleHeader hth = (HeapTupleHeader) PageGetItem(page, lp);
   scan->rs_ctup.t_data = hth;
   scan->rs_ctup.t_len  = ItemIdGetLength(lp);
   ItemPointerSet(&scan->rs_ctup.t_self, blkno, offnum);
   ExecStoreBufferHeapTuple(&scan->rs_ctup, slot, scan->rs_cbuf);
   return true;
   ```

The critical design point is: **MVCC visibility is batched per page, tuple extraction is per tuple.** This is unchanged from PG16/17 in shape, but the buffer was once `ReadBuffer()`-obtained synchronously and is now `read_stream_next_buffer()`-obtained from a pool of buffers whose reads were submitted asynchronously `effective_io_concurrency` pages ago.

### 2.4 MVCC: `HeapTupleSatisfiesVisibility`

`src/backend/utils/time/heapam_visibility.c` implements the snapshot dispatch. The hot path for SELECT is `HeapTupleSatisfiesMVCC`:

1. **Cheap cases via hint bits.** If `HEAP_XMIN_COMMITTED` and `HEAP_XMAX_INVALID`/`HEAP_XMAX_COMMITTED` are already set on `t_infomask`, the answer is determined directly from `xmin`/`xmax` vs `snapshot->xmin/xmax/xip[]`.
2. **Uncommitted xmin.** Needs `TransactionIdIsCurrentTransactionId` / `TransactionIdIsInProgress` / `TransactionIdDidCommit` (the last may touch `pg_xact`/CLOG). On commit, `SetHintBits` stamps `HEAP_XMIN_COMMITTED` to avoid the lookup next time (this is the source of the "hint bit" dirty-page problem).
3. **Snapshot arithmetic.** `XidInMVCCSnapshot(xmin, snapshot)` compares against `snapshot->xip[]` (the in-progress list) and `snapshot->xmax`.
4. **xmax analysis.** If a valid `xmax` exists, treats the tuple as deleted or locked (`HEAP_XMAX_IS_LOCKED_ONLY`), using the same CLOG/hint-bit machinery.

The batched nature (once per page, for all `MaxHeapTuplesPerPage ≈ 291` potential tuples) means this is often the dominant CPU cost on a cached seqscan. Serializable isolation adds `CheckForSerializableConflictOut` after visibility determination.

### 2.5 BufferAccessStrategy and ring buffers

`GetAccessStrategy(BAS_BULKREAD)` (`src/backend/storage/buffer/freelist.c`) returns a 256 KB ring (32 × 8 KB buffers) that a sequential scan reuses. When `StrategyGetBuffer` is called during a scan, it evicts and reuses buffers from this ring, preventing a one-shot seqscan of a multi-GB table from evicting an active working set out of `shared_buffers`. The ring is `BAS_BULKREAD` / `BAS_VACUUM` / `BAS_BULKWRITE` / `BAS_NORMAL`; seqscans select `BULKREAD` automatically when the relation size exceeds `NBuffers/4` (`initscan` logic).

### 2.6 Parallel heap scan

`ParallelBlockTableScanDescData` (in `relscan.h`) holds the **shared** scan state in DSM:

```c
pg_atomic_uint64 phs_nallocated;  /* how many blocks have been handed out */
BlockNumber      phs_nblocks;
BlockNumber      phs_startblock;
slock_t          phs_mutex;       /* only for init */
```

Each worker requests blocks in chunks (not one-by-one, to avoid hot-line contention): `table_block_parallelscan_nextpage` atomically fetch-adds `phs_nallocated` in a geometrically decreasing chunk size (`PARALLEL_SEQSCAN_RAMPDOWN_CHUNKS`). The read stream callback in each worker calls this to pull the next block. On a large NUMA box, the atomic on `phs_nallocated` is a scalability hot spot, which is why chunking matters — this is an area worth profiling on an IvorySQL 18 fork.

### 2.7 Index scan

`src/backend/access/index/indexam.c` exposes the AM-independent index scan API, itself a dispatcher over `IndexAmRoutine` (`amgettuple`, `amgetbitmap`, etc.):

```
index_beginscan → relation_openrv + IndexScanDescData + am->ambeginscan
index_rescan   → am->amrescan
index_getnext_tid → am->amgettuple (btbeginscan/btgettuple for btree)
                   → returns TID in scan->xs_heaptid; on B-tree, runs the
                     ScalarArrayOp/skip-scan machinery introduced in PG17/PG18
index_fetch_heap → heapam_index_fetch_tuple → ReadBufferExtended +
                   heap_hot_search_buffer (MVCC + HOT chain walk) +
                   ExecStoreBufferHeapTuple
index_getnext_slot → convenience: loop fetching TIDs until one is visible
```

`IndexScanDescData` carries `xs_snapshot`, `xs_heaptid`, `xs_heap_continue` (HOT chain progression), `xs_recheck`, and for ordered scans `xs_orderbyvals[]`/`xs_orderbynulls[]` which feed the reorder queue used by `IndexNextWithReorder`.

### 2.8 Index-only scan and the visibility map

`IndexOnlyScanState` holds `ioss_VMBuffer`. `IndexOnlyNext` does:

1. `index_getnext_tid` → a TID,
2. `VM_ALL_VISIBLE(relation, blockno, &ioss_VMBuffer)` — a 2-bits-per-page bitmap kept in a tiny `_vm` fork, queried without pinning the heap page,
3. If all-visible: call `StoreIndexTuple` which materializes the slot from `xs_itup` (the index tuple), including any INCLUDE columns, and increments `ntuples_fetched`. No heap access at all.
4. Otherwise: fall back to `index_fetch_heap` and bump `heap_fetches`.

This is why covering indexes (`INCLUDE`) massively change index-only scan CPU: you avoid `heap_fetch` and its buffer I/O on the non-all-visible minority. For PG18 with AIO, the heap-fetch fallback does **not** currently benefit from `read_stream` (it's a one-shot `ReadBuffer`); the per-tuple buffer fault remains synchronous.

### 2.9 Bitmap heap scan (before and after PG18)

Before PG17/18, `nodeBitmapHeapscan.c` maintained two `TIDBitmap` iterators in lockstep: a **main iterator** delivering pages, and a **prefetch iterator** running `effective_io_concurrency` pages ahead calling `PrefetchBuffer` (which maps to `posix_fadvise(WILLNEED)` on Linux). In PG18, commit `2b73a8cd33b745c5b8a7f44322f86642519e3a40` ("BitmapHeapScan uses the read stream API", Melanie Plageman, Mar 2025) removed ~310 net lines from `nodeBitmapHeapscan.c` and the prefetch iterator disappeared. The heap AM installs `heap_scan_bitmap_next_block`-style read-stream callback that pulls the next `TBMIterateResult` from `scan->rs_base.rs_tbmiterator` (via `tbm_iterate`) and returns its `blockno`. The executor node is now mostly:

```
BitmapHeapNext(node):
  while ((slot = table_scan_bitmap_next_tuple(...)) != NULL-ish) {
      if (lossy page and recheck) if (!ExecQual(bitmapqualorig, econtext)) continue;
      return slot;
  }
  /* when a page is exhausted, the heap AM internally pulls the next buffer
     from the read stream, preserving async pipelining across pages */
```

The two helper commits that shaped this API split were `de380a62b5` (making `table_scan_bitmap_next_block` async-friendly by moving page-exhaustion signaling into `next_tuple`) and `7bd7aa4d30` (moving EXPLAIN counters into the heap-specific callback). One PG18.x back-patch (the `#ifdef NOT_ANYMORE` block in `BitmapHeapNext`) disabled the old "skip heap fetch for empty target list" optimization because it interacted incorrectly with concurrent VACUUM marking pages all-visible while their TIDs still appeared in the bitmap.

---

## 3. PG18-specific changes: AIO, `read_stream`, and friends

### 3.1 The `pgaio` subsystem

PG18 introduces a genuine asynchronous I/O subsystem (release-notes credit: Andres Freund, Thomas Munro, Nazir Bilal Yavuz, Melanie Plageman). The subsystem lives in `src/backend/storage/aio/` and consists of:

- `aio.c` / `aio_callback.c` / `aio_io.c` / `aio_init.c` — core API: `pgaio_io_acquire`, `pgaio_io_start_readv`, `pgaio_io_reopen`, `pgaio_io_wait`, `pgaio_io_release`.
- `method_sync.c` — legacy synchronous method (pretends to be async, executes inline).
- `method_worker.c` — the default in PG18.0: dedicated `io worker` auxiliary processes pull submitted IO handles from a shared queue and execute `preadv` on behalf of the originating backend.
- `method_io_uring.c` — Linux-only, requires `--with-liburing` and `io_method=io_uring`. Uses a per-backend `io_uring` submission/completion ring; completions are reaped either by the waiter or by a signal handler, so a backend that blocks on something else does not starve other backends' IO.

A `PgAioHandle` is a slot in shared memory (`MaxBackends * io_max_concurrency`). Its lifecycle is: **acquire → prep (target = `PGAIO_SUBJ_SMGR` with rel/fork/blk/nblocks, op = `PGAIO_OP_READV`, callback chain) → submit → (concurrent kernel work) → reap → release.** Callbacks are chained — e.g., `shared_buffer_readv` is the first callback and is responsible for CRC verification of arriving pages and marking `BufferDesc` state transitions (`BM_IO_IN_PROGRESS` → `BM_VALID`).

Key GUCs added in PG18:

- `io_method` = `sync | worker | io_uring` (default `worker` in 18.0).
- `io_workers` = 3 by default.
- `io_combine_limit` / `io_max_combine_limit` (default 16, max clamped by `PG_IOV_MAX`) — how many 8 KB blocks the buffer manager may merge into one `preadv` system call.
- `effective_io_concurrency` default raised from 1 → 16.
- `maintenance_io_concurrency` = 16 (for VACUUM/ANALYZE).

A new system view `pg_aios` exposes in-flight I/O handles for observability (file, offset, length, state, owning backend).

**Important scope note:** in PG18, only **reads** are asynchronous. Writes, including WAL and buffer flush on eviction, remain synchronous. The write side is expected in PG19+.

### 3.2 The `read_stream` API

`src/backend/storage/aio/read_stream.c` is the consumer-facing abstraction. A scan does not directly manipulate `PgAioHandle`; it provides a callback that returns "the next block I want" and is handed back pinned buffers in the same order:

```c
typedef BlockNumber (*ReadStreamBlockNumberCB)(
    ReadStream *stream,
    void       *callback_private_data,
    void       *per_buffer_data);

ReadStream *read_stream_begin_relation(
    int flags,                        /* READ_STREAM_SEQUENTIAL | _MAINTENANCE | _USE_BATCHING */
    BufferAccessStrategy strategy,
    Relation rel,
    ForkNumber fork,
    ReadStreamBlockNumberCB cb,
    void *cbdata,
    size_t per_buffer_data_size);

Buffer read_stream_next_buffer(ReadStream *stream, void **per_buffer_data);
void   read_stream_reset(ReadStream *stream);
void   read_stream_end(ReadStream *stream);
```

Internally, `read_stream` maintains three windows:

1. **Requested** — blocks the callback has already returned.
2. **In flight** — blocks for which `StartReadBuffers()` has submitted a (possibly combined) vectored I/O to `pgaio` but not yet completed.
3. **Ready, pinned** — blocks whose `PgAioHandle` completed and whose `BufferDesc` is `BM_VALID`; these are returned to the caller one at a time.

The **adaptive lookahead distance** is the stream's core intelligence. It grows up to `effective_io_concurrency` on cache misses (when it is actually doing useful work in hiding I/O latency) and shrinks on runs of cache hits (when issuing more prefetch is wasted CPU). When adjacent blocks are requested, the stream coalesces them into a single `preadv` up to `io_combine_limit` blocks — this is the single biggest per-I/O-op efficiency win over the PG17 model, independent of AIO itself.

`READ_STREAM_USE_BATCHING` tells the stream it may hold completions back in the hope of coalescing; `READ_STREAM_SEQUENTIAL` tells it to ramp distance aggressively (because the access pattern is known-sequential); `READ_STREAM_MAINTENANCE` causes it to use `maintenance_io_concurrency` instead of `effective_io_concurrency`.

### 3.3 Integration into sequential scan

`heap_beginscan` attaches the stream (see §2.2). The tuple loop is:

```
SeqScan per-tuple flow (PG18):
  ExecSeqScan(pstate)
    → ExecSeqScanWithQual / …WithoutQualWithProject / …WithoutQualNoProject  [PG18 dispatch]
        → ExecScan(node, SeqNext, SeqRecheck)
            → ResetExprContext(econtext)
            → SeqNext(node)
                → table_scan_getnextslot(sscan, dir, slot)
                    → heap_getnextslot(sscan, dir, slot)
                        → heapgettup_pagemode(scan, dir, …)
                            → if page exhausted:
                                 heap_prepare_pagescan(scan)
                                   → read_stream_next_buffer(rs_read_stream, NULL)
                                       [may block on AIO completion; buffer arrives pinned]
                                   → LockBuffer + per-page visibility loop → rs_vistuples[]
                              → ItemId lp = PageGetItemId(page, rs_vistuples[rs_cindex++])
                              → PageGetItem → HeapTupleHeader
                              → ExecStoreBufferHeapTuple(&rs_ctup, slot, rs_cbuf)
            → ExecQual(qual, econtext)?
            → ExecProject(projInfo)?
    → return slot to parent
```

(In PG18, `ExecSeqScan` was split into three specialized variants installed by `ExecInitSeqScan` depending on whether there is a qual and/or projection, each of which becomes the `ExecProcNodeReal`. This removes a handful of branches per tuple in the hot path.)

### 3.4 Integration into bitmap heap scan

Described in §2.9: the PG18 commit `2b73a8cd33` removed the prefetch iterator from `nodeBitmapHeapscan.c` and pushed the async responsibility into the heap TAM via a stream callback that consumes the `TIDBitmap` iterator. The rework also reorganized `table_scan_bitmap_next_block`/`_next_tuple` (`7bd7aa4d30`, `de380a62b5`) so that the "no more blocks" signal is delivered by the block callback returning `InvalidBlockNumber` rather than by `next_block` returning false-but-still-call-next_tuple. That change is purely to interoperate with the stream's lookahead discipline.

### 3.5 Other PG18 tuple-processing changes worth flagging

- **`TidStore` for VACUUM dead-TID tracking.** PG17/18 replaced the old dead-tuple array with `TidStore` (`src/backend/lib/radixtree.h`-based), memory-efficient and enabling AIO-friendly bulk prefetch. Relevant in `vacuumlazy.c`, not in per-tuple executor path, but it uses the same `read_stream` machinery for the second pass.
- **B-tree skip scan** (commit `92fe23d93`, Peter Geoghegan, PG18). Inside `_bt_readpage`/`_bt_readnextpage`, the scan can now emit an internal dynamic equality constraint for a skipped prefix column, making the inner loop generate extra "primitive scans" under the hood. For the executor it is transparent — `index_getnext_tid` keeps returning TIDs; EXPLAIN (ANALYZE) surfaces it as `Index Searches: N > 1`.
- **Asynchronous-friendly refactors of `table_scan_bitmap_next_block/tuple`** in `tableam.h` — semantic flip where "no visible tuples" vs "no more blocks" are now cleanly separated.
- **Virtual generated columns** (Peter Eisentraut). These are computed per read; the generated expression compiles to an `ExprState` stored on the relation's `TupleDesc` and is evaluated lazily by `slot_getsomeattrs` when the virtual column is actually projected.
- **EXPLAIN (ANALYZE, BUFFERS)** now counts read-stream-provided buffers distinctly and `pg_stat_io` tracks AIO completion paths.

### 3.6 NUMA/shared-memory implications for an IvorySQL 18 fork

For a performance engineer working on IvorySQL 18.3 forked from PG18, the practical impact areas are:

1. **`ParallelBlockTableScanDescData` contention.** With `io_uring` and `io_combine_limit=32`, each worker burns through blocks fast; the atomic `fetch_add` on `phs_nallocated` can become visible on very wide NUMA boxes. Chunk sizing in `table_block_parallelscan_nextpage` is the lever.
2. **PgAioHandle shared array.** `pgaio_io_acquire` lockless-pops from a per-backend freelist that falls back to a shared pool; the shared pool coordinates across NUMA nodes. If the fork pins backends to NUMA nodes, evaluate `numa_localalloc` on `PgAioCtl` / per-backend slots.
3. **BufferDesc state transitions in completion callbacks.** With `io_method=io_uring`, any backend may reap any AIO (including another backend's), which means `shared_buffer_readv_complete` flips `BM_IO_IN_PROGRESS → BM_VALID` from a non-owning backend. Cacheline bouncing on `BufferDesc` is worth profiling under a hot seqscan workload on multi-socket hardware.
4. **Ring-buffer `BAS_BULKREAD` interaction with AIO.** The 256 KB ring is small relative to `io_combine_limit × effective_io_concurrency`, so under aggressive prefetch the ring is effectively "in flight" rather than "cached for reuse" — the reuse benefit is diluted. Consider whether the fork should widen the ring when `io_method != sync`.

---

## 4. Node-by-node per-tuple behavior

### 4.1 `SeqScan` (`nodeSeqscan.c`)

State: `SeqScanState` = `ScanState` (which embeds `PlanState`) + a reference to `TableScanDesc`. `ExecInitSeqScan` calls `table_beginscan` to allocate the heap scan, installs `ExecSeqScan*` variants (with/without qual, with/without projection), and sets `ps_ResultTupleSlot` backed by `TTSOpsBufferHeapTuple` for input and `TTSOpsVirtual` for projected output.

`ExecSeqScan` → `ExecScan(node, SeqNext, SeqRecheck)`. `SeqNext` is one `table_scan_getnextslot` call. `SeqRecheck` is a no-op (seqscan has nothing to recheck; quals are always applied at the node itself).

### 4.2 `IndexScan` (`nodeIndexscan.c`)

State: `IndexScanState` with `iss_ScanDesc` (`IndexScanDescData`), `iss_RuntimeKeys` / `iss_NumRuntimeKeys` (for parametrized scans, re-evaluated on `ExecReScan`), and `iss_ReorderQueue` / `iss_OrderByTypLens` (used when ordering-op operators feed a binary heap for kNN-like queries).

`ExecIndexScan` → `ExecScan(node, IndexNext, IndexRecheck)`. `IndexNext`:

```
IndexNext:
  for (;;) {
     if (!index_getnext_tid(iss_ScanDesc, dir))   /* amgettuple → TID */
        return ExecClearTuple(slot);
     if (!index_fetch_heap(iss_ScanDesc, slot))   /* MVCC miss → try next TID */
        continue;
     if (iss_ScanDesc->xs_recheck)
        ExecQual(iss_RecheckQual, econtext) or skip;
     return slot;                                 /* TTSOpsBufferHeapTuple */
  }
```

`ExecReScanIndexScan` re-evaluates runtime keys (e.g. for a parametrized inner side of a nestloop) and calls `index_rescan`.

### 4.3 `IndexOnlyScan` (`nodeIndexonlyscan.c`)

State: `IndexOnlyScanState` with `ioss_VMBuffer` (cached VM buffer pin), `ioss_RuntimeKeys`, `ioss_NumRuntimeKeys`. `IndexOnlyNext`:

```
for (;;) {
   tid = index_getnext_tid(...);
   if (!tid) return ClearTuple;
   if (VM_ALL_VISIBLE(rel, blk, &ioss_VMBuffer))
       StoreIndexTuple(slot, xs_itup, xs_itupdesc);   /* no heap access */
   else {
       if (!index_fetch_heap(...)) continue;          /* MVCC verified via heap */
       StoreIndexTuple(slot, ...);                    /* but return index cols */
   }
   predicate_lock_page if needed;
   return slot;
}
```

The memory-bandwidth saving is huge: index tuples are packed and narrow, and `xs_itup` sits in an already-pinned index buffer.

### 4.4 `BitmapHeapScan` (`nodeBitmapHeapscan.c`)

State: `BitmapHeapScanState` with `tbm` (the `TIDBitmap *` built by child `BitmapIndexScan` / `BitmapAnd` / `BitmapOr`), `tbmiterator` (or `shared_tbmiterator` for parallel), `return_empty_tuples` (for aggregates that don't need columns), and `recheck`. In PG18 the `prefetch_iterator` / `prefetch_pages` / `prefetch_target` fields are gone; their job is in the read stream.

Flow (`BitmapHeapNext`):

```
if (!initialized) {
    tbm = (TIDBitmap *) MultiExecProcNode(outerPlanState(node));
    tbmiterator = tbm_begin_iterate(tbm);
    table_beginscan_bm(...) with rs_tbmiterator attached;
    heap AM sets up a READ_STREAM_DEFAULT stream whose callback pulls
       TBMIterateResult.blockno from tbm_iterate(tbmiterator);
    initialized = true;
}
for (;;) {
    slot = table_scan_bitmap_next_tuple(scan, slot);
    if (slot is "page done")      continue;        /* AM advances page internally */
    if (slot is "bitmap done")    return ClearTuple;
    if (recheck && !ExecQual(bitmapqualorig, econtext))
        continue;
    return slot;
}
```

Lossy-page handling: when `TIDBitmap` runs out of `work_mem`, it converts entries to page-level chunks. `TBMIterateResult.ntuples == -1` signals a lossy page, requiring the scan to return every tuple on the page and rely on `bitmapqualorig` recheck.

### 4.5 `NestLoop` (`nodeNestloop.c`)

State: `NestLoopState` with `nl_NeedNewOuter`, `nl_MatchedOuter`, and the parameter machinery (`NestLoopParam.paramno` entries updated before each inner rescan so `EEOP_PARAM_EXEC` ops in the inner's quals see fresh values).

```
ExecNestLoop:
  for (;;) {
    if (nl_NeedNewOuter) {
        outer = ExecProcNode(outerPlan);
        if (TupIsNull(outer)) return ClearTuple;
        econtext->ecxt_outertuple = outer;
        /* populate NestLoopParams from outer's columns → pass to inner's Params */
        foreach nlp in nestParams: prm->value = slot_getattr(outer, nlp->paramval->varattno)
        ExecReScan(innerPlan);   /* resets child's chgParam-driven state */
        nl_NeedNewOuter = false; nl_MatchedOuter = false;
    }
    inner = ExecProcNode(innerPlan);
    if (TupIsNull(inner)) {
        nl_NeedNewOuter = true;
        if (jointype in (LEFT, ANTI) && !nl_MatchedOuter)
            /* emit outer-joined NULL tuple */ ;
        continue;
    }
    econtext->ecxt_innertuple = inner;
    if (ExecQual(joinqual)) {
        nl_MatchedOuter = true;
        if (jointype == ANTI) { nl_NeedNewOuter = true; continue; }
        if (ExecQual(otherqual)) return ExecProject(projInfo);
    }
  }
```

The ExecReScan on the inner is where nestloop's O(outer × inner) cost comes from. `Memoize` (§4.11) was added to PG14 to cache that rescan's output.

### 4.6 `HashJoin` (`nodeHashjoin.c`)

HashJoin is a **per-tuple state machine** with explicit `HJ_*` states stored in `HashJoinState.hj_JoinState`:

```
HJ_BUILD_HASHTABLE
  → MultiExecHash(innerPlan)
      loop: inner = ExecProcNode; ExecHashGetHashValue; ExecHashTableInsert
      (may call ExecHashIncreaseNumBatches, spilling inner to batch files via BufFile)
HJ_NEED_NEW_OUTER
  → outer = ExecProcNode(outerPlan)
      if NULL: HJ_NEED_NEW_BATCH
      ExecHashGetHashValue(outer) → hashvalue
      if batch != 0: write outer to outer batch file; loop (don't probe yet)
      else: ExecHashGetBucketAndBatch → hj_CurBucketNo; HJ_SCAN_BUCKET
HJ_SCAN_BUCKET
  → walk bucket chain (HashJoinTuple linked list)
    for each match where hashvalue equal and joinqual true:
        econtext->ecxt_innertuple = slot_from_minimaltuple(match);
        if ExecQual(otherqual): emit ExecProject
    when chain exhausted: if outer unmatched in outer join → HJ_FILL_OUTER_TUPLE
    else HJ_NEED_NEW_OUTER
HJ_FILL_INNER_TUPLES   (right/full join only; walks unmatched inner entries)
HJ_NEED_NEW_BATCH
  → close current batch; load next batch's inner tuples from BufFile into hash table;
    reposition outer BufFile; HJ_NEED_NEW_OUTER
```

Batching: when `ExecHashTableInsert` detects the hash table exceeds `work_mem`, `ExecHashIncreaseNumBatches` doubles `nbatch`, re-partitions existing entries by a bucket-vs-batch bit split, and writes the non-current batch tuples out to `BufFile` tapes. During probe, outer tuples whose `batchno != 0` are likewise spilled to an outer BufFile.

Parallel hash join (`nodeHashjoin.c` + `nodeHash.c` + `src/include/executor/hashjoin.h`) uses a shared hash table in DSM (`SharedHashJoinBatch`), with a **barrier** protocol (`BarrierArriveAndWait`) between `PHJ_BUILD_*` → `PHJ_GROW_BATCHES_*` → `PHJ_BATCH_PROBING` phases.

PG18 per release notes: hash join memory usage was improved (David Rowley, Jeff Davis), including hash table memory accounting and hash operator improvements that also accelerate GROUP BY, EXCEPT, and hash subplans.

### 4.7 `MergeJoin` (`nodeMergejoin.c`)

Requires both inputs sorted on merge keys. State machine lives in `MergeJoinState.mj_JoinState`:

```
EXEC_MJ_INITIALIZE_OUTER → pull first outer
EXEC_MJ_INITIALIZE_INNER → pull first inner; ExecMarkPos(inner)
EXEC_MJ_JOINTUPLES       → mj_ExtraMarks? for each inner with equal key:
                             emit if otherqual; pull next inner
EXEC_MJ_NEXTOUTER        → pull next outer
    if equal to previous outer key: ExecRestrPos(inner); JOINTUPLES
    else: SKIP_TEST
EXEC_MJ_NEXTINNER        → pull next inner
EXEC_MJ_SKIP_TEST        → compare outer.key vs inner.key via mj_Compare
    <  : NEXTOUTER
    >  : NEXTINNER
    =  : mark inner, JOINTUPLES
EXEC_MJ_ENDOUTER / EXEC_MJ_ENDINNER  (for outer joins, emit nullified rows)
```

`mj_Compare` is a specialized `ExprState` that evaluates `merge_clauses` comparing outer's and inner's sort columns with operator strategy numbers. `ExecMarkPos` / `ExecRestrPos` push down into the inner node: for `Material` this is cheap (move tuplestore read pointer); for `Sort` it is free (sorted output is already materialized). That is why merge join often has a `Materialize` inserted above its inner input.

### 4.8 `Aggregate` (`nodeAgg.c`)

Four strategies encoded in `AggStrategy`: `AGG_PLAIN` (single row, no grouping), `AGG_SORTED` (grouped, input sorted), `AGG_HASHED` (grouped via hash), `AGG_MIXED` (multiple GROUPING SETS, combination of sorted + hashed passes).

Per-tuple data: `AggStatePerTransData` (transition state per distinct transition function), `AggStatePerAggData` (final value per aggregate call), `tmpcontext` (the per-tuple `ExprContext` reset between input tuples).

Hash path (`agg_retrieve_hash_table`, `lookup_hash_entries`):

```
for each input tuple (from lefttree):
    econtext->ecxt_outertuple = slot
    ResetExprContext(tmpcontext)
    for each GroupingSet hashtable:
        hash = ExecHashAggHashTuple(hashtable, slot)
        entry = LookupTupleHashEntry(hashtable, slot, &isnew, hash)
        if isnew: initialize_aggregates for entry's pergroup
        advance_aggregates(aggstate, pergroup):
            for each transfunc:
                compute args via ExprState (strict-arg check via EEOP_AGG_STRICT_INPUT_CHECK_ARGS)
                FunctionCallInvoke(transfn, transvalue, args) → new transvalue
                if not byval and not in aggcontext: datumCopy into aggcontext
(when input exhausted or memory pressure triggers spill)
for each hash entry:
    finalize_aggregates → final value → project → emit one slot
```

If the hash table exceeds `hash_mem_multiplier * work_mem`, PG15+ spills to tape (`hashagg_spill_init`). Spilled tuples are re-partitioned by hash bits; after the in-memory groups are emitted, each partition is read back and processed recursively (`hashagg_batch_read`), up to depth 32.

Sorted path (`agg_retrieve_direct`):

```
while (still grouping):
    for each tuple until group key changes:
        advance_aggregates(pergroup)
    finalize_aggregates; project; emit
    start new group
```

PG18 per release notes: GROUP BY (hashed) performance and memory usage improved (Rowley/Davis); functionally dependent columns dropped from GROUP BY keys.

### 4.9 `Sort` (`nodeSort.c`)

Sort is the clearest example of a **pipeline-breaking** node. On first invocation, `ExecSort` drains the child completely:

```
if (!sort_Done) {
    tuplesortstate = tuplesort_begin_heap(tupdesc, nkeys, sortColIdx,
                                          sortOperators, collations, nullsFirst,
                                          work_mem, coordinate(for parallel), ...);
    for (;;) {
        slot = ExecProcNode(outer);
        if (TupIsNull(slot)) break;
        tuplesort_puttupleslot(tuplesortstate, slot);
    }
    tuplesort_performsort(tuplesortstate);   /* sort or finalize runs */
    sort_Done = true;
}
tuplesort_gettupleslot(tuplesortstate, forward, false, resultslot, NULL);
return resultslot;
```

`tuplesort.c` internal states (`Tuplesortstate.status`): `TSS_INITIAL` (accumulating in memory), `TSS_BOUNDED` (top-N heapsort for `LIMIT N ORDER BY`), `TSS_BUILDRUNS` (external: write sorted runs to tape via `logtape.c`), `TSS_SORTEDONTAPE` / `TSS_FINALMERGE` (N-way merge on replay). Memory budget is `work_mem`; above it, spill.

Parallel sort: workers independently build sorted runs, a shared `Tuplesortstate` merges them (handled via `tuplesortvariants.c`).

### 4.10 `Materialize` (`nodeMaterial.c`)

`MaterialState` wraps a `Tuplestorestate`. Per tuple:

```
if (forward direction and not at EOF of tuplestore):
    if tuplestore_gettupleslot returns a tuple: return it
    else: pull from outer, tuplestore_puttupleslot, return it
else:
    tuplestore_gettupleslot (backward / rescan reads pre-materialized tuples)
```

Purpose: allow parents to rescan or mark/restore without re-executing the child. The classic use is above a `Sort` or below a `MergeJoin` inner for mark/restore, and for protecting against volatile child results during rescans.

### 4.11 `Memoize` (`nodeMemoize.c`)

New in PG14, used as the inner of a parametrized `NestLoop` when the planner estimates many duplicate parameter values. `MemoizeState` holds a hash table (`memoize_hash`) keyed on `NestLoopParam` values; values are `MemoizeEntry` lists of tuples stored in per-entry `Tuplestorestate`s. Per tuple:

```
if params changed since last ExecReScan:
    key = make_memoize_key(paramvalues);
    entry = memoize_lookup(key);
    if entry and entry->complete:
        mstate->replay_tuplestore = entry->tuplestore;
        state = MEMO_CACHE_FETCH_NEXT_TUPLE;
    else:
        cache-miss: pull from outer, also write to entry->tuplestore;
        state = MEMO_FILLING_CACHE;
/* per ExecMemoize call */
switch state:
    MEMO_CACHE_FETCH_NEXT_TUPLE: tuplestore_gettupleslot → slot
    MEMO_FILLING_CACHE: slot = ExecProcNode(outer); tuplestore_put; if EOF mark entry complete
    MEMO_CACHE_BYPASS: outer directly (cache full or cant cache)
```

Eviction: LRU when `work_mem * hash_mem_multiplier` exceeded. Statistics (hits / misses / evictions) shown in EXPLAIN ANALYZE.

### 4.12 `ModifyTable` (`nodeModifyTable.c`)

`ModifyTableState` carries per-result-relation info (`ResultRelInfo *` array: one per partition and/or per WITH). Per incoming tuple from child (which supplies a slot with the new row for INSERT, the junk-TID-plus-new-values for UPDATE, or the junk-TID for DELETE):

```
ExecModifyTable loop:
    slot = ExecProcNode(outerPlanState(node))
    if TupIsNull(slot) → return NULL (or partition-pending batch flush)
    switch operation:
      CMD_INSERT: ExecInsert(slot, ...)
          → resolve partition via ExecFindPartition
          → BEFORE ROW INSERT triggers
          → check constraints (NOT NULL, CHECK, FK via AFTER triggers)
          → table_tuple_insert(rel, slot, cid, options, bistate)
          → AFTER ROW INSERT triggers queued
          → if resultRelInfo->ri_projectReturning: ExecProcessReturning → emit
      CMD_UPDATE: ExecUpdate(tupleid, oldslot, slot, …)
          → BEFORE ROW UPDATE triggers
          → table_tuple_update(rel, tid, slot, cid, snapshot, crosscheck,
                                wait, &tmfd, &lockmode, &update_indexes)
            returns TM_Ok / TM_Updated / TM_SelfModified / TM_BeingModified
          → on TM_Updated: EvalPlanQual re-read latest row, re-check qual;
            may recurse as UPDATE on updated row
          → partition key update → convert to DELETE on source partition + INSERT on target
          → AFTER ROW UPDATE triggers
          → RETURNING via ExecProcessReturning
      CMD_DELETE: ExecDelete
      CMD_MERGE : ExecMerge → ExecMergeMatched / ExecMergeNotMatched state machine
                   each WHEN branch runs one of the above
```

RETURNING: `ri_projectReturning` is an `ExprState` / `ProjectionInfo` built by `ExecBuildProjectionInfo` over the RETURNING list; `ExecProcessReturning` sets `econtext->ecxt_scantuple = slot` (the post-DML row) and runs the interpreter, returning a virtual slot upward. PG18 added `OLD` and `NEW` prefixes in RETURNING, so `ExecBuildProjectionInfo` now can reference both `ri_oldTupleSlot` and `ri_newTupleSlot` in the same projection (relevant for UPDATE/DELETE/MERGE RETURNING).

Bulk INSERT optimization: for `INSERT … SELECT`/`COPY`, `ExecInsert` can batch into `multi_insert` via `CopyMultiInsertBuffer`, and for FDW result relations, batch INSERT is driven by `ExecInsert`/`ExecBatchInsert`.

### 4.13 `Gather` and `GatherMerge` (`nodeGather.c`, `nodeGatherMerge.c`)

Parallelism in PG is tuple-pull on top of shared-memory tuple queues. `GatherState.nworkers_launched` workers each run the partial plan and `push` tuples into a `shm_mq` via a `DestReceiver` (`TQueueDestReceiver`). Leader pulls.

`ExecGather`:

```
if (!initialized) { launch workers via ExecParallelCreateReaders; initialized = true; }
for (;;) {
    if (funnel->nreaders == 0 && !need_to_scan_locally) return ClearTuple;
    slot = gather_getnext(gatherstate):
        round-robin over TupleQueueReader array; shm_mq_receive on each
        if all queues empty and no workers alive: NULL
        on empty-but-alive: block on latch for any queue's wait event
        on data: construct minimal tuple in slot (TTSOpsMinimalTuple)
    if (need_to_scan_locally && slot is NULL from workers):
        slot = ExecProcNode(outerPlanState(node));   /* leader participation */
    return slot;
}
```

`tuples_needed` is propagated downward so the partial plan can honor LIMIT.

`ExecGatherMerge` preserves sort order across workers using a binary heap (`binaryheap`) keyed by the `SortSupport` over merge keys:

```
Initialize: pull one tuple from each worker's queue into gm_slots[i];
            binaryheap_add_unordered for each i; binaryheap_build.
For each tuple requested:
    top_i = binaryheap_first(&heap)
    result = gm_slots[top_i]   /* min/max element */
    refill: gm_slot[top_i] = gm_readnext_tuple(top_i)
    if (refilled) binaryheap_replace_first else binaryheap_remove_first
    return result
```

Leader participation is also possible here. Note: tuples crossing the shm_mq are `MinimalTuple` form (no xmin/xmax, smaller header) — the sender serializes with `ExecCopySlotMinimalTuple`, receiver with a virtual view over the received bytes.

---

## Closing synthesis

The per-tuple flow in PG18 can be summarized in one sentence: **a tuple is deformed lazily from a pointer into a pinned shared buffer (pinned by a buffer whose read was issued asynchronously through `pgaio`), validated against the snapshot using page-batched MVCC state, carried up the plan tree as a `TupleTableSlot *` through a chain of virtual `ExecProcNode` calls, evaluated by an opcode-based `ExprState` interpreter backed by a per-tuple memory context that is reset between tuples, and delivered to the destination receiver as `TTSOpsVirtual` data materialized by `ExecProject`.** The Volcano model is intact; the storage/buffer seam underneath is the one that changed meaningfully in PG18.

For an IvorySQL 18.3 performance engineer, the highest-value instrumentation points are (i) `ExecProcNodeFirst` → real-method transition (already hot-swap optimized), (ii) `ResetExprContext` frequency and the cost distribution of `slot_getsomeattrs`, (iii) `read_stream_next_buffer` latency histograms under `io_method=worker` vs `io_uring`, (iv) `HeapTupleSatisfiesMVCC` branch behavior on hint-bit-cold pages, (v) `ParallelBlockTableScanDesc.phs_nallocated` atomic hotness on NUMA, and (vi) `pg_aios` + `pg_stat_io` for end-to-end async accounting. The three PG18 commits to keep bookmarked are Thomas Munro's `b5a9b18cd0` (streaming seqscan), Melanie Plageman's `2b73a8cd33` (bitmap heap scan on `read_stream`), and Peter Geoghegan's `92fe23d93` (B-tree skip scan) — these bracket the sections of the executor and AM layers that diverged most from the PG17 baseline you may be carrying patches against.