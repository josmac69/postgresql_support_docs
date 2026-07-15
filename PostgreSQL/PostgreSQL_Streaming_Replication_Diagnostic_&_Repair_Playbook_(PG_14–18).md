# PostgreSQL Streaming Replication Diagnostic & Repair Playbook (PG 14–18)

**A hands-on runbook for a Senior PostgreSQL DBA. Covers physical streaming replication (with logical notes) across PostgreSQL 14, 15, 16, 17, and 18. Current as of July 2026.**

## TL;DR
- Diagnose from both ends: on the PRIMARY use `pg_stat_replication` + `pg_replication_slots`; on the REPLICA use `pg_is_in_recovery()`, `pg_stat_wal_receiver`, and the `pg_last_wal_*` functions. The single most common outage — a full `pg_wal` on the primary — is almost always an inactive replication slot or a failing `archive_command`.
- Version deltas that matter: `wal_keep_segments`→`wal_keep_size` and `max_slot_wal_keep_size` (PG13); `archive_library`/`basic_archive` and `recovery_prefetch` (PG15); logical decoding on standbys + slots surviving promotion (PG16); failover/synchronized slots, `sync_replication_slots`, `pg_createsubscriber`, incremental backups (PG17); `idle_replication_slot_timeout`, async I/O + `pg_aios`, WAL rows in `pg_stat_io`, data checksums on by default (PG18).
- Repair decision tree: if `wal_status='lost'` the slot/replica is unrecoverable via streaming — re-clone (`pg_basebackup`) or restore from archive; if the disk is filling, first prove whether the cause is a slot (`pg_replication_slots`) or the archiver (`pg_stat_archiver`) before dropping anything.

## Key Findings
- `pg_stat_replication` lives ONLY on the primary (one row per connected walsender); `pg_stat_wal_receiver` lives ONLY on the replica (one row). An empty `pg_stat_replication` on a server you believe is a primary means no standby is connected, regardless of config.
- The authoritative slot-safety signal is `pg_replication_slots.wal_status`: `reserved` → `extended` → `unreserved` → `lost`. `lost` is terminal. `safe_wal_size` (added in PostgreSQL 13beta3, initially `min_safe_lsn`; negative when past the limit) tells you how many bytes remain before invalidation.
- The classic error `requested WAL segment ... has already been removed` means the primary recycled WAL the replica still needed. Prevention is a physical replication slot and/or a WAL archive with `restore_command`; recovery is re-clone or archive restore.
- Promotion has been fully modernized: use `pg_promote()` or `pg_ctl promote`. `promote_trigger_file` was removed in PG16; `recovery.conf` was removed back in PG12 (replaced by `standby.signal`/`recovery.signal` + normal GUCs).
- `pg_rewind` requires the target to have been initialized with data checksums OR `wal_log_hints=on`, plus `full_page_writes=on`. Per the PostgreSQL 18 release notes (listed as an incompatibility): *"Change initdb default to enable data checksums (Greg Sabino Mullane)... Checksums can be disabled with the new initdb option `--no-data-checksums`."* — so `pg_rewind` "just works" on fresh PG18 installs.

## Details

### 0. Orientation: is this node a primary or a standby?
Run this first on any node whose role is uncertain. It works identically on all versions 14–18.
```sql
-- Role, WAL positions, and whether replay is paused (run on ANY node)
SELECT
  pg_is_in_recovery()                       AS is_standby,       -- t = standby, f = primary
  pg_last_wal_receive_lsn()                 AS receive_lsn,      -- NULL on a primary
  pg_last_wal_replay_lsn()                  AS replay_lsn,       -- NULL on a primary
  pg_last_xact_replay_timestamp()           AS last_replay_ts,   -- NULL on a primary
  pg_is_wal_replay_paused()                 AS replay_paused;
```
- On a **primary**: `is_standby = f`, and the three receive/replay values are NULL.
- On a **standby**: `is_standby = t`; receive/replay LSNs advance; `last_replay_ts` is recent.

At the OS level, confirm the process roles:
```bash
ps -ef | grep -E 'walsender|walreceiver|startup|walsummarizer'
# walsender     -> present on the primary (one per connected standby)
# walreceiver   -> present on the standby
# startup       -> the recovery/replay process on the standby
```

---

### 1. Identifying replication type, role, and sync state

#### 1a. On the PRIMARY — who is connected and how
```sql
SELECT
  pid, usename, application_name,
  client_addr, client_port,
  backend_start, backend_xmin,
  state,                       -- startup | catchup | streaming | backup | stopping
  sent_lsn, write_lsn, flush_lsn, replay_lsn,
  write_lag, flush_lag, replay_lag,
  sync_priority, sync_state,   -- async | potential | sync | quorum
  reply_time
FROM pg_stat_replication
ORDER BY application_name;
```
Column/state interpretation:
- **state**: `streaming` is the healthy steady state. `catchup` means the standby is still replaying backlog after connecting. `startup`/`backup` are transient.
- **sync_state**: `async` = primary does not wait for it. `potential` = eligible to become sync but not currently chosen. `sync` = a priority-based synchronous standby. `quorum` = a member of an `ANY N (...)` quorum set.
- **sync_priority**: 0 for async standbys; for `FIRST`/priority lists, lower non-zero number = higher priority. All quorum members share the behavior of `quorum`.
- A logical replication subscriber also appears here with `application_name` = the subscription name; pair it with `pg_stat_subscription`/`pg_stat_subscription_stats` on the subscriber.

Physical vs logical, and whether sync is even configured:
```sql
SHOW wal_level;                    -- replica = physical only; logical = logical decoding enabled
SHOW synchronous_standby_names;    -- empty = fully async cluster
SHOW synchronous_commit;           -- off | local | remote_write | on | remote_apply
SELECT slot_name, slot_type FROM pg_replication_slots;  -- physical vs logical slots
```

`synchronous_standby_names` syntax (unchanged 14–18):
- `FIRST 2 (s1, s2, s3)` — priority/2-safe: wait for the 2 highest-priority connected standbys.
- `ANY 2 (s1, s2, s3)` — quorum: wait for any 2 of the listed standbys.
- Bare list `s1, s2` ≡ `FIRST 1 (s1, s2)`. `*` matches any application_name.
- The standby name is its `application_name`, set in `primary_conninfo` (defaults to `cluster_name`, else `walreceiver`).

`synchronous_commit` durability ladder (only meaningful when `synchronous_standby_names` is non-empty): `off` < `local` (local flush only) < `remote_write` (standby OS write) < `on` (standby durable flush — the default) < `remote_apply` (standby has replayed and made visible). For a `sync` standby, monitor **flush_lag** (that is what gates commits), not just replay_lag.

#### 1b. On the REPLICA — what am I receiving
```sql
SELECT
  pid, status,                     -- streaming | catchup | starting | stopping | waiting | restarting
  receive_start_lsn, receive_start_tli,
  received_lsn, received_tli,
  last_msg_send_time, last_msg_receipt_time,   -- diff ≈ network latency
  latest_end_lsn, latest_end_time,
  slot_name, sender_host, sender_port, conninfo
FROM pg_stat_wal_receiver;
```
- One row when streaming; **zero rows means the WAL receiver is not running** (not connected, or the standby is replaying only from archive). Combine with §0 and the log.
- `status = streaming` + a recent `last_msg_receipt_time` = healthy. `sender_host`/`slot_name` confirm which primary and slot are in use.

**Recovery prefetch (PG15+)** — how efficiently WAL is being replayed on the standby:
```sql
-- pg_stat_recovery_prefetch: added in PG15; one row; NULLs/zeros if recovery_prefetch=off
SELECT stats_reset, prefetch, hit, skip_init, skip_new, skip_fpw, skip_rep,
       wal_distance, block_distance, io_depth
FROM pg_stat_recovery_prefetch;
SHOW recovery_prefetch;    -- try (default) | on | off; needs posix_fadvise support
```
A high `prefetch` relative to `hit` with a busy standby indicates prefetch is doing useful work reducing replay I/O stalls.

---

### 2. Measuring replication lag

#### 2a. From the PRIMARY (authoritative for "how far behind in bytes")
```sql
SELECT
  application_name, client_addr, state, sync_state,
  pg_current_wal_lsn()                               AS primary_lsn,
  sent_lsn, write_lsn, flush_lsn, replay_lsn,
  pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)    AS pending_send_bytes,
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)  AS total_lag_bytes,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS total_lag_pretty,
  write_lag, flush_lag, replay_lag
FROM pg_stat_replication
ORDER BY total_lag_bytes DESC;
```
Interpreting the three pipeline stages (the LSNs and the matching time-based lags, both added for time in PG10 and stable 14–18):
- **sent → write** (`write_lag`): time from local commit until the standby acknowledges the OS *write*. High here points to network throughput/latency between primary and standby.
- **write → flush** (`flush_lag`): time until the standby *fsync*s. High here points to standby disk/fsync latency. This is the stage that gates `synchronous_commit=on`.
- **flush → replay** (`replay_lag`): time until the standby *applies* WAL to data files (single-threaded startup process). High `replay_lag` with low write/flush lag means apply is the bottleneck — a long-running conflicting query, a slow standby CPU/disk, or heavy WAL volume.

Note the documented quirk (14–18): on a fully caught-up, idle system the lag columns keep showing the last measured value and then flip to NULL — they do not read as zero. Treat NULL-on-idle as "caught up." Two minor-release bugs are worth knowing before trusting anomalous NULLs:
- **PostgreSQL 18.1** (released Nov 13, 2025), fix by Fujii Masao, verbatim release note: *"Fix incorrect reporting of replication lag in pg_stat_replication view... If any standby server's replay LSN stopped advancing, the write_lag and flush_lag columns would eventually stop updating."*
- **PostgreSQL 18.4** (released May 14, 2026), verbatim: *"Fix incorrect reporting of replication lag in pg_stat_replication view... The lag columns frequently read as NULL even while replication activity was happening."*

#### 2b. From the REPLICA
```sql
-- Byte lag on the receive vs replay side (local view)
SELECT
  pg_last_wal_receive_lsn()                                        AS received_lsn,
  pg_last_wal_replay_lsn()                                         AS replayed_lsn,
  pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS apply_backlog_bytes;

-- Time-based lag, guarded against an idle primary reporting false growth
SELECT
  CASE
    WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
    ELSE EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))
  END AS replica_lag_seconds;
```
Key caveat: pure time-based lag (`now() - pg_last_xact_replay_timestamp()`) inflates when the **primary is idle** (no new commits to replay). Always corroborate with byte distance. The `receive vs replay` split localizes the problem: if `received_lsn` keeps up with the primary but `replayed_lsn` trails, the network is fine and **apply** is the bottleneck; if `received_lsn` itself trails, it is a streaming/network problem.

Helpers valid 14–18:
```sql
SELECT pg_current_wal_lsn();                              -- primary only
SELECT * FROM pg_walfile_name_offset(pg_current_wal_lsn());
SELECT pg_wal_lsn_diff('0/3A000000','0/38000000');       -- 33554432 = 2 segments
```

---

### 3. Replication slots

#### 3a. Core inventory + WAL retained per slot
```sql
SELECT
  slot_name, slot_type,          -- physical | logical
  plugin, database, temporary,
  active, active_pid,
  restart_lsn, confirmed_flush_lsn,   -- confirmed_flush_lsn is logical-only
  wal_status,                    -- reserved | extended | unreserved | lost   (PG13+)
  safe_wal_size,                 -- bytes before invalidation; negative = past limit (PG13beta3+/14)
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```
`wal_status` semantics (this is the single most important slot health signal, PG13+):
- **reserved** — retained WAL is within `max_wal_size`. Normal.
- **extended** — beyond `max_wal_size` but still protected by `wal_keep_size`/`max_slot_wal_keep_size`. Normal.
- **unreserved** — exceeded `max_slot_wal_keep_size`; WAL is in imminent danger of removal but the slot can still recover if the consumer catches up before the next checkpoint.
- **lost** — required WAL has been removed. **Terminal**; the consumer must be rebuilt.
- `unreserved`/`lost` only appear when `max_slot_wal_keep_size >= 0`.

Detect the dangerous ones:
```sql
-- Inactive slots and/or slots that are past safe territory
SELECT slot_name, slot_type, active, wal_status, safe_wal_size,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE NOT active OR wal_status IN ('unreserved','lost') OR (safe_wal_size IS NOT NULL AND safe_wal_size < 0);
```
Distinguish **inactive** (`active=false`, no walsender at all → candidate for dropping) from **lagging** (`active=true` but `retained_wal` growing → the consumer is connected but not acknowledging; fix the consumer, do not drop).

`max_slot_wal_keep_size` behavior (PG13+, default `-1` = unlimited): if a slot's `restart_lsn` falls behind current LSN by more than this, at the next checkpoint the slot is invalidated and you'll see a log line like `invalidating slot "X" because its restart_lsn ... exceeds max_slot_wal_keep_size`. Setting a finite value (e.g. `'100GB'`) trades a broken slot for a protected primary — the correct trade in almost all production cases.

#### 3b. PG17+ slot columns & failover/synchronized slots
PG17 added these columns to `pg_replication_slots` (present in 17 and 18):
```sql
SELECT slot_name, slot_type, active, wal_status,
       inactive_since,        -- when the slot last went inactive (PG17)
       conflicting,           -- logical slot invalidated by recovery conflict (PG16 for standby slots)
       invalidation_reason,   -- why invalidated: wal_removed | rows_removed | wal_level_insufficient | idle_timeout (PG17+)
       failover,              -- slot is a failover slot, synced to standbys (PG17)
       synced                 -- this slot was synchronized FROM a primary (PG17)
FROM pg_replication_slots;
```
- **PG16**: logical decoding on standbys became possible; a physical standby's slots now **survive promotion**. Use `pg_log_standby_snapshot()` on the primary to speed up logical slot creation on a standby.
- **PG17**: native failover slots. Create with `pg_create_logical_replication_slot('s','pgoutput', false, false, true)` (5th arg `failover=true`) or `CREATE SUBSCRIPTION ... WITH (failover=true)`. On the standby set `sync_replication_slots=on` (+ `hot_standby_feedback=on`, `primary_slot_name`, and a valid `dbname` in `primary_conninfo`); a `slotsync worker` then keeps them in sync. Manually sync via `pg_sync_replication_slots()` (standby only; testing/debug). On the primary, list the physical standby slot(s) in `synchronized_standby_slots` (renamed from `standby_slot_names`, PG17) so logical subscribers cannot advance past the physical standby.
- Confirm failover readiness on the standby before promoting:
```sql
SELECT slot_name, (synced AND NOT temporary AND invalidation_reason IS NULL) AS failover_ready
FROM pg_replication_slots WHERE failover;
```
- **PG18**: `idle_replication_slot_timeout` (default `0`, disabled; feature by Nisha Moond and Bharath Rupireddy) auto-invalidates slots inactive longer than the configured duration. Per the PG18 docs, invalidation is evaluated *at checkpoint* — *"Slot invalidation due to idle timeout occurs during checkpoint... The duration of slot inactivity is calculated using the slot's pg_replication_slots.inactive_since value."* Exemptions, verbatim: *"the idle timeout invalidation mechanism is not applicable for slots that do not reserve WAL or for slots on the standby server that are being synced from the primary server (i.e., standby slots having pg_replication_slots.synced value true). Synced slots are always considered to be inactive because they don't perform logical decoding to produce changes."*

#### 3c. Dropping an orphaned slot (and the risks)
```sql
-- 1) confirm it is safe: not needed by any live consumer
SELECT slot_name, active, active_pid, wal_status, inactive_since
FROM pg_replication_slots WHERE slot_name = 'old_slot';
-- 2) if a stale backend holds it, terminate that backend first
SELECT pg_terminate_backend(active_pid) FROM pg_replication_slots
WHERE slot_name = 'old_slot' AND active;
-- 3) drop it
SELECT pg_drop_replication_slot('old_slot');
```
Risk: dropping a slot that a real (temporarily disconnected) standby/subscriber still needs forces a full re-clone of that consumer. You cannot drop an `active` slot. There is no built-in pause; `pg_alter_replication_slot()` (PG16) only changes `failover`/`two_phase`, it cannot deactivate a slot.

---

### 4. Detecting lost / missing WAL segments

Symptom in the log (standby side, walreceiver): `FATAL: could not receive data from WAL stream: ERROR: requested WAL segment 0000...XX has already been removed`. Cause: the primary recycled WAL the replica still needed (replica was down/behind, no slot, `wal_keep_size` too small, or a timeline mismatch after repeated failovers).

Diagnostics:
```sql
-- Primary: how much WAL am I actually keeping, and is any slot 'lost'?
SHOW wal_keep_size;          -- PG13+; was wal_keep_segments (integer) in 12 and earlier
SHOW max_slot_wal_keep_size; -- PG13+
SELECT slot_name, active, wal_status, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS behind
FROM pg_replication_slots;

-- Compare the replica's needed LSN vs the oldest WAL the primary still has
-- (run on replica) what does it still need?
SELECT pg_last_wal_replay_lsn();
-- (run on primary) oldest segment present in pg_wal
SELECT name FROM pg_ls_waldir() ORDER BY name LIMIT 1;  -- oldest file name
```
Interpretation: if the replica's required LSN maps to a segment older than the oldest file in the primary's `pg_wal` (and it isn't in the archive), streaming cannot resume. If a slot exists but shows `wal_status='lost'`, the same conclusion holds for that slot.

Recovery options (in order of preference):
1. **WAL archive present** — set a `restore_command` on the standby; it will fetch the missing segments from the archive and catch up without a re-clone. (Note: as of PG18 the *primary's* walsender still does not automatically read its own archive to satisfy a standby's request; you either restore on the standby or manually stage the segment into the primary's `pg_wal`.)
2. **Re-clone the standby** from the current primary:
```bash
pg_basebackup -h primary -U replicator -D $PGDATA -R -X stream -c fast -P \
  --slot=standby1 -C     # -C creates the named slot atomically (PG11+)
# -R writes standby.signal + primary_conninfo automatically
```
3. **Prevent recurrence**: give the standby a physical replication slot (`primary_slot_name` + `pg_create_physical_replication_slot`) AND set a finite `max_slot_wal_keep_size` so a dead standby can never fill the primary; keep a WAL archive as the safety net.

---

### 5. Archive command / archiving failures

`pg_stat_archiver` is a single-row view (columns stable 14–18):
```sql
SELECT
  archived_count, last_archived_wal, last_archived_time,
  failed_count,   last_failed_wal,   last_failed_time,
  stats_reset,
  now() - last_archived_time AS since_last_archive,
  CASE
    WHEN last_failed_time IS NULL                         THEN 'healthy'
    WHEN last_archived_time IS NULL                       THEN 'never succeeded'
    WHEN last_failed_time > last_archived_time            THEN 'currently failing'
    ELSE 'healthy'
  END AS archiver_status
FROM pg_stat_archiver;
```
Signatures:
- **Wedged archiver**: `failed_count` climbing while `archived_count` is flat, and `last_failed_time > last_archived_time`. PostgreSQL retries the *same* segment indefinitely, so `pg_wal` grows until the volume fills (then a PANIC shutdown — committed data is safe, but the DB is offline until space is freed).
- **Never succeeded**: `last_archived_time IS NULL` with a non-zero `failed_count` → misconfigured `archive_command`/`archive_library` from the start.

Related config:
```sql
SHOW archive_mode;      -- off | on | always (always = standbys archive too, PG9.5+)
SHOW archive_command;   -- shell command; %p = path, %f = filename
SHOW archive_library;   -- PG15+ loadable module alternative (e.g. 'basic_archive')
SHOW archive_timeout;   -- force a segment switch after this interval on low-write systems
```
**PG15 transition**: `archive_library` provides an in-process module alternative to `archive_command` (the contrib `basic_archive` is the reference module — it writes to a temp name, fsyncs, then atomically renames, and verifies content on collision). PG16 made it an error to set both `archive_command` and `archive_library` simultaneously. A caveat for both mechanisms (documented 14–18): if the archiver is killed by a signal or exits with status >125 (e.g. command-not-found), or an archive module raises ERROR/FATAL, the archiver restarts and that particular failure is **not** counted in `pg_stat_archiver.failed_count` — so also watch the server log.

Diagnose why it fails: run the exact `archive_command` by hand as the postgres OS user against a real segment (check destination reachability, permissions, disk space, and that it refuses to overwrite an existing file).

**Emergency backlog clearing** (disk filling): the fastest safe stopgap is to point archiving at a working destination or, as a last resort, temporarily neutralize it so `pg_wal` can drain:
```sql
ALTER SYSTEM SET archive_command = '/bin/true';  -- pretends success; WAL recycles
SELECT pg_reload_conf();
```
Danger: `/bin/true` marks segments archived without actually saving them, creating a gap that breaks PITR and any archive-based standby recovery. Use only to save the primary, restore the real command the moment space is recovered, and **take a fresh base backup immediately afterward**. Never run `pg_archivecleanup` against a primary's live `pg_wal`.

---

### 6. General health, logs, and recovery conflicts

Where to look and what to grep for (log location: `log_directory`/`log_filename`, or `journalctl -u postgresql`):
- `requested WAL segment ... has already been removed` → §4 (missing WAL).
- `terminating walsender process due to replication timeout` → `wal_sender_timeout` exceeded (network stall or dead standby).
- `could not receive data from WAL stream` → walreceiver lost the connection.
- `terminating connection due to conflict with recovery` / `canceling statement due to conflict with recovery` → recovery conflict on the standby (below).
- `invalidating slot ... exceeds max_slot_wal_keep_size` / `invalidating obsolete replication slot` → slot invalidation.

Recovery conflicts (standby only) via `pg_stat_database_conflicts`:
```sql
SELECT datname,
       confl_tablespace, confl_lock, confl_snapshot,
       confl_bufferpin, confl_deadlock,
       confl_active_logicalslot   -- added PG16 (logical slot conflicts on standby)
FROM pg_stat_database_conflicts
WHERE datname = current_database();
```
Conflict types & tuning:
- **confl_snapshot** (most common): a standby query still needs row versions that VACUUM removed on the primary. **confl_lock**: replay needs an AccessExclusiveLock (DDL on primary) that a standby query blocks. **confl_bufferpin**, **confl_deadlock**, **confl_tablespace**: rarer.
- Levers: `max_standby_streaming_delay` (default 30s; how long replay waits before cancelling a conflicting query on streamed WAL) and `max_standby_archive_delay` (same for archive-sourced WAL). `-1` = wait forever (replica can fall arbitrarily behind); `0` = cancel immediately.
- `hot_standby_feedback = on` makes the standby report its oldest xmin to the primary so VACUUM defers cleanup of rows the standby still needs — eliminates most snapshot conflicts at the cost of potential bloat on the primary. Use `log_recovery_conflict_waits = on` (PG14+) to log waits exceeding `deadlock_timeout`.
- To see exactly what replay is blocked on:
```sql
SELECT relation::regclass, mode, granted, pid
FROM pg_locks
WHERE NOT granted
  AND pid = (SELECT pid FROM pg_stat_activity WHERE backend_type = 'startup');
```

Timeouts to check on both ends:
```sql
SHOW wal_sender_timeout;    -- primary; default 60s (0 disables). Unchanged in PG18.
SHOW wal_receiver_timeout;  -- standby; default 60s.
```
`wal_sender_timeout` (added in PostgreSQL 9.3) is confirmed per the official docs: *"Terminate replication connections that are inactive for longer than this amount of time... The default value is 60 seconds. A value of zero disables the timeout mechanism."* For cross-region links, either raise both timeouts or add TCP keepalives to `primary_conninfo` (`keepalives=1 keepalives_idle=... keepalives_interval=... keepalives_count=...`).

**PG18 I/O observability**: WAL I/O activity (including WAL receiver writes on standbys) now appears as rows in `pg_stat_io`, which gained byte-granular `read_bytes`/`write_bytes`/`extend_bytes` columns (the old `op_bytes` was removed); WAL timing moved out of `pg_stat_wal` (which lost `wal_write`/`wal_sync`/`wal_write_time`/`wal_sync_time`) and is now governed by `track_wal_io_timing` feeding `pg_stat_io`. Per-backend stats are available via `pg_stat_get_backend_io(pid)` and `pg_stat_get_backend_wal(pid)`. The new `pg_aios` view exposes in-flight async I/O handles (async I/O in PG18 covers reads only — sequential/bitmap scans, VACUUM — not WAL writes/replay, so it does not directly change standby replay behavior; replay speed is still helped by `recovery_prefetch`).

---

### 7. Configuration reference (PG 14–18)

Set on the **PRIMARY** (sending side):
| Parameter | Purpose | Default / notes | Version notes |
|---|---|---|---|
| `wal_level` | `replica` for physical, `logical` for logical decoding | `replica` | — |
| `max_wal_senders` | Max concurrent walsenders | `10` | — |
| `max_replication_slots` | Max slots | `10` | PG18: origin count split out to `max_active_replication_origins` |
| `wal_keep_size` | Min WAL retained for standbys w/o slots | `0` (MB) | Replaced `wal_keep_segments` in PG13 |
| `max_slot_wal_keep_size` | Cap WAL a slot may retain | `-1` (unlimited) | Added PG13; drives `unreserved`/`lost` |
| `synchronous_standby_names` | Which standbys are sync (`FIRST`/`ANY`) | empty (async) | — |
| `synchronous_commit` | Durability level | `on` | — |
| `archive_mode` | `off`/`on`/`always` | `off` | `always` = PG9.5+ |
| `archive_command` | Shell archive | empty | — |
| `archive_library` | Module archive | empty | Added PG15; can't coexist w/ `archive_command` (PG16) |
| `archive_timeout` | Force segment switch | `0` (off) | — |
| `wal_sender_timeout` | Kill idle walsender | `60s` (0 disables) | Added PG9.3 |
| `synchronized_standby_slots` | Physical slots logical senders wait for | empty | PG17 (renamed from `standby_slot_names`) |
| `idle_replication_slot_timeout` | Auto-invalidate idle slots | `0` (disabled) | **PG18** |
| `summarize_wal` | Enable WAL summarizer for incremental backups | `off` | PG17 |

Set on the **STANDBY** (receiving side):
| Parameter | Purpose | Default / notes | Version notes |
|---|---|---|---|
| `primary_conninfo` | Connection to sender | — | GUC since PG12 (was in recovery.conf) |
| `primary_slot_name` | Physical slot to use on primary | empty | — |
| `restore_command` | Fetch WAL from archive | empty | — |
| `recovery_target*` | PITR targets (`_time`/`_lsn`/`_xid`/`_name`) | — | — |
| `hot_standby` | Allow read queries during recovery | `on` | — |
| `hot_standby_feedback` | Reduce snapshot conflicts | `off` | — |
| `max_standby_streaming_delay` | Delay before cancelling conflicting query (stream) | `30s` | — |
| `max_standby_archive_delay` | Same for archive WAL | `30s` | — |
| `wal_receiver_timeout` | Detect dead upstream | `60s` | — |
| `recovery_prefetch` | Prefetch blocks during replay | `try` | Added PG15 |
| `sync_replication_slots` | Run slotsync worker for failover slots | `off` | PG17 |
| `recovery_min_apply_delay` | Deliberate replay delay | `0` | — |

Version/behavior deltas to call out during a support session:
- **recovery.conf removed in PG12**: all recovery/standby GUCs live in `postgresql.conf`/`ALTER SYSTEM`; presence of `recovery.conf` prevents startup. A standby is signaled by an empty `standby.signal` file (PITR by `recovery.signal`).
- **`promote_trigger_file` removed in PG16** (and `vacuum_defer_cleanup_age` removed). Promote via `pg_promote()`/`pg_ctl promote`.
- **PG13**: `wal_keep_segments`→`wal_keep_size`; `max_slot_wal_keep_size` added.
- **PG15**: `archive_library`/`basic_archive`; `recovery_prefetch`+`pg_stat_recovery_prefetch`; stats collector replaced by shared-memory stats.
- **PG16**: logical decoding on standbys; slots persist across promotion; `confl_active_logicalslot`; `pg_alter_replication_slot()`.
- **PG17**: failover/synchronized slots (`failover`, `synced`, `inactive_since`, `invalidation_reason` columns; `sync_replication_slots`, `synchronized_standby_slots`, `pg_sync_replication_slots()`); `pg_createsubscriber`; incremental base backups (`pg_basebackup --incremental`, `pg_combinebackup`, `pg_walsummary`); `pg_stat_checkpointer`.
- **PG18**: `idle_replication_slot_timeout`; async I/O (`io_method` = `worker` default | `sync` | `io_uring`, restart required) + `pg_aios`; WAL rows & byte columns in `pg_stat_io`; per-backend `pg_stat_get_backend_io/wal`; **data checksums enabled by default at initdb** (*"Change initdb default to enable data checksums (Greg Sabino Mullane)... Checksums can be disabled with the new initdb option `--no-data-checksums`."*); MD5 auth deprecated.

---

### 8. Repair / remediation procedures

#### (a) Replica lost WAL and cannot catch up
1. Confirm the diagnosis (§4): standby log shows "already been removed" and/or the slot is `wal_status='lost'`.
2. If a WAL **archive** exists: set `restore_command` on the standby and restart it — it replays from archive and rejoins. No re-clone needed.
3. Otherwise **re-clone**: stop the standby, move aside/remove the old data dir, then:
```bash
pg_basebackup -h primary -U replicator -D $PGDATA -R -X stream -c fast -P -C --slot=standby1
```
4. Start the standby; verify with §1b/§2.
5. Harden: physical slot + finite `max_slot_wal_keep_size` + archive.

#### (b) Slot causing WAL bloat on the primary
1. Identify (§3a): the slot with the largest `retained_wal`, especially `active=false` or `wal_status IN ('unreserved','lost')`.
2. If it belongs to a **live but lagging** consumer (`active=true`): fix the consumer (network, apply speed), do not drop.
3. If it is truly **orphaned**: terminate any holder and drop it (§3c). WAL recycles at the next checkpoint.
4. If disk is critically low right now and you can accept re-cloning that consumer: drop the slot to release WAL immediately.
5. Prevent recurrence: set `max_slot_wal_keep_size`; on PG18 optionally `idle_replication_slot_timeout`; monitor `pg_replication_slots` for `active=false` and `wal_status` transitions.

#### (c) Archive command failing and pg_wal filling the disk
1. Confirm the archiver is the culprit (§5): rising `failed_count`, stale `last_archived_time`.
2. Free headroom fast: extend the WAL volume if you can, or (last resort) `ALTER SYSTEM SET archive_command='/bin/true'; SELECT pg_reload_conf();` to let WAL drain — **breaks PITR/archive continuity**.
3. Fix the real cause (reachability/permissions/space in the archive destination); restore the real `archive_command`/`archive_library`.
4. Once healthy, take a fresh base backup (the `/bin/true` window left a gap). Optionally `SELECT pg_stat_reset_shared('archiver');` to clear counters.

#### (d) Promoting a standby
```sql
-- Preferred, from a session on the standby (grantable to non-superusers):
SELECT pg_promote(wait => true, wait_seconds => 60);
```
```bash
# Or from the shell:
pg_ctl promote -D $PGDATA
```
Version notes: `pg_promote()` exists since PG12; `promote_trigger_file` was removed in PG16 (do not rely on a trigger file on 16+). Promotion bumps the timeline; other standbys must then follow the new primary (update `primary_conninfo`, and use `pg_rewind` if they diverged).

#### (e) Rewinding a former primary with pg_rewind
Requirements on the **target** (the old primary being rewound): initialized with **data checksums** OR `wal_log_hints=on`, and `full_page_writes=on` (default). PG18 fresh clusters have checksums on by default. The target must be **cleanly shut down** first.
```bash
# On the new primary after promotion, force a checkpoint so its control file reflects the new timeline:
psql -c "CHECKPOINT;"

# On the old primary (target), cleanly stopped:
pg_rewind --target-pgdata=$PGDATA \
          --source-server="host=newprimary user=postgres dbname=postgres" \
          --restore-target-wal -P
# --restore-target-wal uses the target's restore_command to fetch WAL missing from pg_wal
```
After rewind: `pg_rewind` copies config files from the source, so re-check recovery config; ensure `standby.signal` exists and `primary_conninfo` points at the new primary, then start. If `pg_rewind` fails midway, the target dir is likely unusable — take a fresh `pg_basebackup` instead. Old WAL back to the divergence point must be reachable (in the target's `pg_wal` or via `restore_command`).

## Recommendations
1. **Instrument both ends now.** Alert on: `pg_stat_replication` byte lag > threshold; any `pg_replication_slots.wal_status IN ('unreserved','lost')` or `safe_wal_size < 0`; any `active=false` slot with large `retained_wal`; `pg_stat_archiver` "currently failing"; and WAL volume > 70–75%. These four catch the overwhelming majority of replication outages before they page you at 3 AM.
2. **Always use a physical slot AND a finite `max_slot_wal_keep_size` AND a WAL archive.** The slot guarantees a lagging standby can catch up; the cap guarantees a dead standby can never take down the primary; the archive is the recovery path when the cap kicks in. This trio removes the two classic failure modes (lost WAL vs. full disk) simultaneously.
3. **Match the tuning to the standby's job.** HA standby: short `max_standby_streaming_delay` (fast, minimal lag), accept query cancellations. Reporting standby: `hot_standby_feedback=on` and/or longer delays, accept some primary bloat. Do not set `max_standby_streaming_delay=-1` on an HA standby.
4. **On PG17+, adopt failover/synchronized slots for logical HA**; on PG18, consider `idle_replication_slot_timeout` as a second safety net for CDC consumers that vanish. Verify `failover_ready` before every planned switchover.
5. **Pre-stage `pg_rewind`**: ensure every node has checksums (default on PG18) or `wal_log_hints=on` from day one, so a failed primary can be rejoined in minutes instead of re-cloned in hours.
6. **Thresholds that change the plan**: `wal_status='lost'` → stop trying to stream, re-clone/restore. Disk >90% and rising → emergency mitigation (§8c/§8b) before root-causing. `replay_lag` high but `write/flush_lag` low → investigate the standby's apply path (conflicts, CPU, disk), not the network.

## Caveats
- `pg_stat_replication` is empty on standbys and `pg_stat_wal_receiver` is empty on primaries — an empty view is itself a diagnostic, not necessarily an error.
- Time-based lag misleads when the primary is idle; always corroborate with byte distance (`pg_wal_lsn_diff`).
- Lag columns flip to NULL (not zero) on a fully caught-up idle system (14–18). Two PG18 minor-version bugs affected lag reporting (fixed in 18.1 and 18.4, per the release notes quoted in §2a) — verify your minor version before trusting anomalous NULLs.
- `/bin/true` archive mitigation and dropping a slot are both destructive to a consumer's recoverability; treat as save-the-primary actions of last resort, always followed by a fresh base backup / re-clone.
- Async I/O in PG18 accelerates reads only; it does not change WAL write or standby replay semantics. Do not expect it to fix replication lag — replay is still single-threaded and helped instead by `recovery_prefetch`.
- Some behavior (e.g. whether the primary auto-reads its own archive to satisfy a standby's WAL request) has been the subject of ongoing community discussion (pgsql-hackers, July 2025); as of PG18 you should not rely on it — provision a `restore_command` on the standby.
- Defaults cited are community PostgreSQL; managed platforms (RDS, Cloud SQL, Crunchy, etc.) frequently override `max_wal_senders`, `max_replication_slots`, `wal_keep_size`, and archiving, and may add their own slot/replica management. Always confirm with `SHOW` on the actual instance.