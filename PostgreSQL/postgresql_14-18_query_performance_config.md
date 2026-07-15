# PostgreSQL Query-Performance Configuration Parameters: A Version-Aware Reference for PG 14–18

## TL;DR
- PostgreSQL 18 is the most consequential release for query performance in a decade: it adds a real asynchronous I/O subsystem (`io_method`, `io_workers`, `io_max_concurrency`, `io_combine_limit`/`io_max_combine_limit`), raises `effective_io_concurrency`/`maintenance_io_concurrency` defaults from 1/10 to 16 (Melanie Plageman), adds a hard-cap autovacuum trigger (`autovacuum_vacuum_max_threshold`), and adds two new planner toggles (`enable_self_join_elimination`, `enable_distinct_reordering`).
- Across 14→18 the highest-impact default/behavior changes to memorize are: `hash_mem_multiplier` 1.0→2.0 (PG15, Peter Geoghegan), `checkpoint_completion_target` 0.5→0.9 (PG14), `wal_compression` boolean→enum with lz4/zstd (PG15), `effective_io_concurrency`/`maintenance_io_concurrency`→16 (PG18), `io_combine_limit` introduced (PG17), and the planner-toggle additions `enable_memoize` (PG14), `enable_presorted_aggregate` (PG16), `enable_group_by_reordering` (PG17).
- For diagnosing slow queries as a support engineer, the durable rule set is: verify statistics freshness first (stale stats → bad plans), read `work_mem`×`hash_mem_multiplier` spills in EXPLAIN (ANALYZE, BUFFERS), confirm parallel worker launch vs. plan, watch for JIT overhead on misestimated cost, and on PG18 use `pg_stat_io`/`pg_aios` plus `track_io_timing`/`track_wal_io_timing` to attribute latency to I/O.

## Key Findings
1. **PG18's AIO is read-only and scoped.** It accelerates sequential scans, bitmap heap scans, and vacuum/analyze — not writes, not (yet) index scans. Default `io_method=worker` (3 workers); `io_uring` is Linux-only and requires `--with-liburing`. `sync` reproduces PG17 behavior.
2. **`effective_io_concurrency` changed meaning in PG18.** In ≤PG17 it was a `posix_fadvise` prefetch hint that only affected bitmap heap scans; in PG18 with an async `io_method` it directly governs internal read-ahead depth, and its default rose to 16.
3. **`hash_mem_multiplier` default 1.0→2.0 in PG15** is the single most common cause of plan/OOM behavior differences between PG13/14 and PG15+ — hash nodes now get 2× the `work_mem` budget by default. Per the PG15 release notes: "Increase hash_mem_multiplier default to 2.0 (Peter Geoghegan)… This allows query hash operations to use more work_mem memory than other operations."
4. **Planner toggles were added steadily:** `enable_memoize` (PG14), `enable_presorted_aggregate` (PG16), `enable_group_by_reordering` (PG17), and `enable_distinct_reordering` + `enable_self_join_elimination` (PG18) — all default `on`.
5. **JIT (`jit=on` since PG12) remains a frequent latency regression source** on misestimated high-cost plans; it stays `on` throughout 14–18. Note: PostgreSQL 19 (Beta 1 released June 4, 2026) will ship JIT disabled by default — PG19 release notes: "Change JIT to be disabled by default (Jelte Fennema-Nio)… this costing has been determined to be unreliable, so require sites… doing many large analytical queries to manually enable JIT."

## How Each Parameter Can Be Changed (restart / reload / runtime)

PostgreSQL exposes the change-mechanism via `pg_settings.context`. Query it directly on any server:
`SELECT name, setting, unit, context, pending_restart FROM pg_settings WHERE name = ANY(ARRAY[...]);`
The relevant context values, from most to least restrictive:

- **`postmaster`** — requires a full **server restart** (set in `postgresql.conf` or on the command line). Cannot be changed with `SET` or a reload.
- **`sighup`** — changed with a **reload** (`SELECT pg_reload_conf();`, `pg_ctl reload`, or SIGHUP). No restart needed. Cannot be set per-session.
- **`superuser-backend` / `backend`** — set at connection start only; not changeable within an active session.
- **`superuser`** — changeable at **runtime** with `SET` (or `ALTER SYSTEM` + reload), but only by a superuser (or a role granted the parameter via `GRANT ... ON PARAMETER`).
- **`user`** — fully **dynamic**: any role can change it at runtime per-session/per-transaction with `SET`, and it can also be pinned with `ALTER ROLE`/`ALTER DATABASE ... SET`. This is the level that lets you tune a single slow query without affecting anyone else.

**Practical rule for a support engineer:** almost every *planner* GUC (cost constants, `enable_*` toggles, `work_mem`, `hash_mem_multiplier`, `join_collapse_limit`, `jit*`, `default_statistics_target`, `effective_io_concurrency`, `random_page_cost`) is `user` context — change it in-session on the problem query, verify with EXPLAIN, then decide whether to persist it. The things that force a **restart** are the shared-memory and process-pool sizing GUCs (`shared_buffers`, `max_worker_processes`, `wal_buffers`, `io_method`, `io_workers`, `io_max_combine_limit`, `io_max_concurrency`, `huge_pages`, `autovacuum_worker_slots`). Most autovacuum, WAL, checkpoint, and bgwriter GUCs are `sighup` (reload). Watch `pg_settings.pending_restart = true` after `ALTER SYSTEM` on a `postmaster` GUC — it means the new value is written to `postgresql.auto.conf` but not yet active.

### Consolidated change-mechanism reference

**Requires RESTART (`postmaster`)**
`shared_buffers`, `huge_pages`, `wal_buffers`, `max_worker_processes`, `max_connections`, `superuser_reserved_connections`, `autovacuum_worker_slots` (PG18), `io_method` (PG18), `io_workers` (PG18)†, `io_max_concurrency` (PG18), `io_max_combine_limit` (PG18), `jit_provider`, `track_activity_query_size`, `shared_preload_libraries`, `wal_level`.

**Requires RELOAD (`sighup`) — no restart, not per-session**
`checkpoint_timeout`, `checkpoint_completion_target`, `checkpoint_flush_after`, `max_wal_size`, `min_wal_size`, `wal_compression`‡, `wal_writer_delay`, `wal_writer_flush_after`, `bgwriter_delay`, `bgwriter_lru_maxpages`, `bgwriter_lru_multiplier`, `bgwriter_flush_after`, `full_page_writes`, `autovacuum` (on/off), `autovacuum_max_workers`, `autovacuum_naptime`, `autovacuum_vacuum_scale_factor`, `autovacuum_analyze_scale_factor`, `autovacuum_vacuum_threshold`, `autovacuum_analyze_threshold`, `autovacuum_vacuum_insert_threshold`, `autovacuum_vacuum_max_threshold` (PG18), `autovacuum_vacuum_cost_delay`, `autovacuum_vacuum_cost_limit`, `autovacuum_work_mem`, `vacuum_max_eager_freeze_failure_rate` (PG18), `track_cost_delay_timing` (PG18).

**Fully DYNAMIC at runtime (`user` — `SET` per-session, no restart/reload)**
`work_mem`, `hash_mem_multiplier`, `maintenance_work_mem`, `effective_cache_size`, `temp_buffers`¶, `logical_decoding_work_mem`§, `seq_page_cost`, `random_page_cost`, `cpu_tuple_cost`, `cpu_index_tuple_cost`, `cpu_operator_cost`, `parallel_setup_cost`, `parallel_tuple_cost`, `min_parallel_table_scan_size`, `min_parallel_index_scan_size`, `effective_io_concurrency`, `maintenance_io_concurrency`, `io_combine_limit` (PG17), `jit`, `jit_above_cost`, `jit_inline_above_cost`, `jit_optimize_above_cost`, all `enable_*` toggles, `default_statistics_target`, `constraint_exclusion`, `cursor_tuple_fraction`, `from_collapse_limit`, `join_collapse_limit`, `geqo`, `geqo_threshold`, `plan_cache_mode`, `max_parallel_workers_per_gather`, `max_parallel_workers`, `max_parallel_maintenance_workers`, `parallel_leader_participation`, `synchronous_commit`, `vacuum_buffer_usage_limit` (PG16), `debug_parallel_query`.

**Runtime but SUPERUSER-only (`superuser` context)**
`commit_delay`, `commit_siblings`, `vacuum_cost_delay`, `vacuum_cost_limit`, `track_io_timing`, `track_wal_io_timing`, `track_activities`, `track_counts`, `compute_query_id`. These are settable at runtime without a restart/reload, but only by a superuser or a role granted the parameter.

**Notes:** † `io_workers` is `sighup` in the released build (the worker pool adjusts on reload), but `io_method` itself is `postmaster`, so a method switch needs a restart. ‡ `wal_compression` is `sighup` (reload); listed under restart-adjacent only to flag it changed *type* (boolean→enum) in PG15. § `logical_decoding_work_mem` is `user`-settable but only meaningfully applies to walsender/decoding contexts. ¶ `temp_buffers` is `user` but can only be changed before the session first touches a temp table. **Always confirm the exact context on the target major version with `pg_settings`,** since a handful shift between releases; the lists above reflect PG18 defaults.

## Details

### 1. Memory Parameters
- **`shared_buffers`** — default 128MB; **RESTART** (`postmaster`). The database page cache; too small forces buffer eviction churn and more physical reads. Rule of thumb ~25% RAM on a dedicated server. No default change 14–18. Interacts with huge pages and NUMA placement.
- **`work_mem`** — default 4MB; **DYNAMIC** (`user`). Per-operation (per sort/hash node, per worker) budget. Exceeding it spills to temp files (visible as "external merge Disk" / "Batches > 1" in EXPLAIN). Because it's per-node and per-worker, a parallel multi-node plan can multiply consumption dramatically. No default change 14–18.
- **`hash_mem_multiplier`** — added PG13 (default 1.0); **default changed to 2.0 in PG15** (Peter Geoghegan); **DYNAMIC** (`user`). Effective hash memory = `work_mem × hash_mem_multiplier`. Applies to hash joins, hash aggregates, and hash-based set ops. Per PG18 docs §19.4: "Higher settings in the range of 2.0 - 8.0 or more may be effective in environments where work_mem has already been increased to 40MB or more."
- **`maintenance_work_mem`** — default 64MB; **DYNAMIC** (`user`). Used by VACUUM, CREATE INDEX, ALTER TABLE ADD FOREIGN KEY. Larger values speed index builds and reduce vacuum index-scan passes. Indirect query-perf effect via faster/better index creation and less bloat.
- **`autovacuum_work_mem`** — default -1 (falls back to `maintenance_work_mem`); **RELOAD** (`sighup`). Caps memory per autovacuum worker; relevant when many workers run concurrently.
- **`effective_cache_size`** — default 4GB; **DYNAMIC** (`user`); planner-only estimate (allocates nothing). Higher values make index (especially index-only and nested-loop-with-index) scans look cheaper. Set to ~50–75% of RAM. No default change 14–18.
- **`temp_buffers`** — default 8MB; **DYNAMIC** (`user`, but only before the session first uses a temp table). Per-session cache for temporary tables.
- **`logical_decoding_work_mem`** — default 64MB; **DYNAMIC** (`user`). Caps memory before logical decoding spills to disk. Mostly a replication/publisher concern.
- **PG18 improved hash join and GROUP BY memory usage** (David Rowley, Jeff Davis): "This also improves hash set operations used by EXCEPT, and hash lookups of subplan values."

### 2. Planner Cost Parameters
All parameters in this section are **DYNAMIC** (`user` context) — settable per-session with `SET`, no restart or reload.
- **`seq_page_cost`** (1.0), **`random_page_cost`** (4.0) — the sequential-vs-random read cost ratio. On SSD/NVMe or heavily cached DBs, lowering `random_page_cost` toward 1.1–1.5 is the most impactful single planner tweak to encourage index scans. No default change 14–18. Note: PG18 AIO narrows the random/sequential gap, strengthening the case to lower `random_page_cost`.
- **`cpu_tuple_cost`** (0.01), **`cpu_index_tuple_cost`** (0.005), **`cpu_operator_cost`** (0.0025) — per-row/-index-entry/-operator CPU cost estimates. Rarely tuned. No default change 14–18.
- **`parallel_setup_cost`** (1000), **`parallel_tuple_cost`** (0.1) — startup and per-tuple transfer cost for parallelism. Lowering both encourages parallel plans. No default change 14–18.
- **`min_parallel_table_scan_size`** (8MB), **`min_parallel_index_scan_size`** (512kB) — minimum relation/index size before parallelism is considered. No default change 14–18.
- **`jit_above_cost`** (100000), **`jit_inline_above_cost`** (500000), **`jit_optimize_above_cost`** (500000) — see JIT section.
- **`default_statistics_target`** — default 100; controls histogram/MCV granularity from ANALYZE. Raise (to 250–1000) for skewed columns; per-column override via ALTER TABLE ... SET STATISTICS. No default change 14–18.
- **`constraint_exclusion`** — default `partition`. Legacy inheritance/UNION ALL optimization; largely superseded by native partition pruning.
- **`cursor_tuple_fraction`** — default 0.1; biases cursor plans toward fast-start (first-rows) plans. No default change 14–18.
- **`from_collapse_limit`** (8), **`join_collapse_limit`** (8) — control subquery/JOIN flattening; `join_collapse_limit=1` forces literal join order. No default change 14–18.
- **`geqo`** (on), **`geqo_threshold`** (12) — genetic query optimizer kicks in above this many FROM items. No default change 14–18.
- **`plan_cache_mode`** — default `auto`; forces `force_generic_plan`/`force_custom_plan` for prepared statements.

### 3. Planner Method Toggles (all default `on` unless noted; all DYNAMIC / `user` context)
- **`enable_seqscan`, `enable_indexscan`, `enable_indexonlyscan`, `enable_bitmapscan`** — scan-type toggles (diagnostic; can't fully suppress seqscan).
- **`enable_hashjoin`, `enable_mergejoin`, `enable_nestloop`** — join-method toggles.
- **`enable_hashagg`, `enable_material`, `enable_gathermerge`** — aggregation/materialize/gather-merge.
- **`enable_memoize`** — **added PG14**; caches inner-side results of parameterized nested loops (Memoize node). PG16 extended it to sit atop UNION ALL.
- **`enable_incremental_sort`** — added PG13; exploits partially-sorted input.
- **`enable_parallel_hash`** — parallel hash join.
- **`enable_partition_pruning`** — plan-time and execution-time partition elimination.
- **`enable_partitionwise_join`, `enable_partitionwise_aggregate`** — **default `off`** (memory/planning cost); enable per-session for large partitioned analytics. Each can multiply `work_mem`-bounded nodes by partition count.
- **`enable_presorted_aggregate`** — **added PG16**; lets ORDER BY/DISTINCT aggregates consume presorted input.
- **`enable_group_by_reordering`** — **added PG17**; reorders GROUP BY keys to match an available sort/index order.
- **`enable_distinct_reordering`** — **added PG18**; reorders DISTINCT/DISTINCT ON keys to match input pathkeys.
- **`enable_self_join_elimination`** — **added PG18**; removes redundant self-joins on unique columns (common with ORMs).

### 4. Parallel Query
- **`max_parallel_workers_per_gather`** — default 2; **DYNAMIC** (`user`). Workers per Gather/Gather Merge. 0 disables parallelism. Most common OLAP under-utilization: default of 2 leaves cores idle.
- **`max_parallel_workers`** — default 8; **DYNAMIC** (`user`). Cluster-wide parallel worker ceiling, drawn from `max_worker_processes`.
- **`max_worker_processes`** — default 8; **RESTART** (`postmaster`). Total background worker pool (includes parallel + extensions + logical apply).
- **`max_parallel_maintenance_workers`** — default 2; **DYNAMIC** (`user`). Parallel CREATE INDEX / VACUUM index phases.
- **`parallel_leader_participation`** — default on; **DYNAMIC** (`user`). Whether the leader also scans.
- **`force_parallel_mode` renamed to `debug_parallel_query` in PG16** — testing-only; **DYNAMIC** (`user`). Does NOT make queries "more parallel."
- No default changes to the worker/cost parameters across 14–18. PG18 added `pg_stat_database.parallel_workers_to_launch`/`parallel_workers_launched` for diagnosing worker shortfalls.

### 5. JIT
- **`jit`** — default `on` (since PG12); **DYNAMIC** (`user`); remains on in 14–18. PG19 (Beta 1, June 4, 2026) changes the default to `off` (Jelte Fennema-Nio).
- **`jit_provider`** — default `llvmjit`; **RESTART** (`postmaster`).
- **Cost gates** (all **DYNAMIC** / `user`): `jit_above_cost` (100000), `jit_inline_above_cost` (500000), `jit_optimize_above_cost` (500000). Decisions are made at plan time (matters for prepared/generic plans).
- **When JIT hurts:** short OLTP queries whose estimated cost crosses the threshold (often via misestimation) pay compile/emit overhead. When it helps: long analytical queries with heavy expression evaluation. Mitigation is raising thresholds or `jit=off` for OLTP pools (both per-session).

### 6. I/O and Asynchronous I/O
- **`effective_io_concurrency`** — **default changed 1→16 in PG18** (Melanie Plageman); **DYNAMIC** (`user`); range 0–1000. ≤PG17: `posix_fadvise` prefetch hint affecting only bitmap heap scans. PG18: with async `io_method`, governs internal read-ahead depth.
- **`maintenance_io_concurrency`** — **default changed 10→16 in PG18** (Melanie Plageman); **DYNAMIC** (`user`). Prefetch depth for maintenance (vacuum/analyze).
- **`io_method`** (PG18) — `worker` (default), `sync`, `io_uring`; **RESTART** (`postmaster`). `io_uring` needs Linux 5.1+ and `--with-liburing`.
- **`io_workers`** (PG18) — default 3; **RELOAD** (`sighup`); only relevant when `io_method=worker`. Community benchmarks suggest ~¼–½ of CPU threads/cores as a starting point on many-core boxes.
- **`io_max_concurrency`** (PG18) — default -1 (auto, capped at 64); **RESTART** (`postmaster`); per-process max in-flight I/Os.
- **`io_combine_limit`** (**added PG17**) — default 128kB; **DYNAMIC** (`user`); largest combined I/O size. **`io_max_combine_limit`** (**added PG18**) — default 128kB; **RESTART** (`postmaster`); silently clamps `io_combine_limit`.
- **PG17 streaming I/O / read-stream infrastructure** underlies sequential-scan and ANALYZE read batching; `io_combine_limit` is its user-facing knob.
- **AIO scope in PG18:** reads only — sequential scans, bitmap heap scans, vacuum/analyze. Writes (incl. WAL) remain synchronous; index scans not yet covered. New `pg_aios` view exposes in-flight AIOs.

### 7. WAL / Checkpoint / Background Writer (query-latency-relevant)
- **`checkpoint_completion_target`** — **default changed 0.5→0.9 in PG14**; **RELOAD** (`sighup`). Spreads checkpoint write I/O over 90% of the interval, smoothing I/O spikes that cause query latency jitter.
- **`checkpoint_timeout`** (5min), **`max_wal_size`** (1GB), **`min_wal_size`** (80MB), **`checkpoint_flush_after`** (256kB on Linux, 0 elsewhere) — all **RELOAD** (`sighup`). Too-frequent checkpoints from small `max_wal_size` inflate full-page-write WAL. No default changes 14–18.
- **`wal_compression`** — default `off`; **RELOAD** (`sighup`); **PG15 turned it from boolean into an enum** adding `lz4` and `zstd`. lz4 is the balanced choice.
- **`wal_buffers`** — default -1 (auto: ~1/32 of `shared_buffers`, bounded 64kB–16MB); **RESTART** (`postmaster`).
- **`full_page_writes`** — default `on`; **RELOAD** (`sighup`); disabling risks torn pages — not recommended.
- **`synchronous_commit`** — default `on` (values `remote_apply`/`on`/`remote_write`/`local`/`off`); **DYNAMIC** (`user`). Setting `off` or `local` dramatically cuts commit latency at the cost of a small durability window (no corruption risk). One of the biggest write-latency levers, and per-session tunable. No default change 14–18.
- **`commit_delay`** (0 µs) / **`commit_siblings`** (5) — group-commit tuning; **runtime, SUPERUSER-only** (`superuser` context). Niche.
- **Background writer:** `bgwriter_delay` (200ms), `bgwriter_lru_maxpages` (100), `bgwriter_lru_multiplier` (2.0), `bgwriter_flush_after` (512kB on Linux), `backend_flush_after` (0), `wal_writer_delay` (200ms), `wal_writer_flush_after` (1MB) — all **RELOAD** (`sighup`). No default changes 14–18.
- **`track_wal_io_timing`** — added PG14 (default off); **runtime, SUPERUSER-only** (`superuser`). In ≤PG17 populated `pg_stat_wal`; **in PG18 repurposed to feed `pg_stat_io` (object `wal`)**. Has measurable overhead; enable only when diagnosing.

### 8. Autovacuum / Statistics (plan-quality and bloat)
- **`autovacuum_vacuum_scale_factor`** (0.2), **`autovacuum_analyze_scale_factor`** (0.1), **`autovacuum_vacuum_threshold`** (50), **`autovacuum_analyze_threshold`** (50), **`autovacuum_vacuum_insert_threshold`** (1000) — all **RELOAD** (`sighup`); also settable per-table via storage parameters. Stale statistics is the #1 root cause of sudden bad plans; bloat degrades scan efficiency and index-only-scan visibility.
- **`autovacuum_vacuum_max_threshold`** — **added PG18**; default 100,000,000 tuples (-1 disables); **RELOAD** (`sighup`). Hard cap so very large tables trigger vacuum sooner. Vacuum threshold = `Min(max_threshold, base_threshold + scale_factor × reltuples)`. Best set per-table (10–50M) for a few giant hot tables.
- **PG18 also:** `autovacuum_worker_slots` (default 16; **RESTART** / `postmaster`) decouples slot reservation from `autovacuum_max_workers` (now **RELOAD**-tunable); eager freezing via `vacuum_max_eager_freeze_failure_rate` (**RELOAD**); the insert threshold no longer counts frozen pages. PG16 added `vacuum_buffer_usage_limit` (default 256kB; **DYNAMIC** / `user`) / the BUFFER_USAGE_LIMIT option.
- **`vacuum_cost_delay`/`vacuum_cost_limit`** — **runtime, SUPERUSER-only** (`superuser`). `autovacuum_vacuum_cost_delay`/`autovacuum_vacuum_cost_limit` — **RELOAD** (`sighup`). Too-aggressive throttling lets bloat accumulate; PG18 adds `track_cost_delay_timing` (default off; **RELOAD**) for observability.
- **Statistics/observability GUCs:** `track_io_timing` (off), `track_activities` (on), `track_counts` (on; required for autovacuum), `compute_query_id` (`auto`) — all **runtime, SUPERUSER-only** (`superuser` context). `track_io_timing` is needed for EXPLAIN BUFFERS I/O timings and `pg_stat_io`.

## Version-by-Version Changelog (query-performance-relevant GUCs)

**PostgreSQL 14**
- Added `enable_memoize` (Memoize node for parameterized nested loops).
- Added `track_wal_io_timing`.
- `checkpoint_completion_target` default 0.5→0.9.
- ANALYZE prefetch now uses `maintenance_io_concurrency`.
- LZ4 TOAST compression (`default_toast_compression`, default pglz).
- Added `client_connection_check_interval`, `remove_temp_files_after_crash`; system views `pg_stat_wal`, `pg_stat_progress_copy`, `pg_backend_memory_contexts`.

**PostgreSQL 15**
- `hash_mem_multiplier` default 1.0→2.0 (Peter Geoghegan) — biggest memory-behavior change.
- `wal_compression` boolean→enum; added `lz4` and `zstd`.
- Server-side base backup LZ4/zstd; `recovery_prefetch` for WAL replay prefetch.
- SELECT DISTINCT parallelization, sort performance improvements.

**PostgreSQL 16**
- Added `enable_presorted_aggregate`.
- `force_parallel_mode` renamed to `debug_parallel_query`.
- Added `vacuum_buffer_usage_limit` (BUFFER_USAGE_LIMIT).
- Removed `vacuum_defer_cleanup_age`, `promote_trigger_file`, `lc_collate`/`lc_ctype` (read-only vars).
- Incremental sort in more cases; parallel FULL/right OUTER hash joins; string_agg/array_agg parallelization.

**PostgreSQL 17**
- Added `enable_group_by_reordering`.
- Added `io_combine_limit` (streaming/read-stream I/O for seq scans & ANALYZE).
- Removed `old_snapshot_threshold`; removed `db_user_namespace`; removed Windows `wal_sync_method=fsync_writethrough`.
- New VACUUM memory management (dead-tuple TID store); `pg_stat_checkpointer`; up-to-2× WAL write throughput under concurrency; pg_stat_statements timing column renames.

**PostgreSQL 18**
- New AIO subsystem: `io_method` (worker default; RESTART), `io_workers` (3; RELOAD), `io_max_concurrency` (-1; RESTART), `io_max_combine_limit` (128kB; RESTART); `pg_aios` view.
- `effective_io_concurrency` 1→16; `maintenance_io_concurrency` 10→16 (both DYNAMIC).
- Added `enable_distinct_reordering`, `enable_self_join_elimination` (both default on, DYNAMIC).
- Added `autovacuum_vacuum_max_threshold` (100M; RELOAD); `autovacuum_worker_slots` (16; RESTART); `vacuum_max_eager_freeze_failure_rate` (RELOAD); `track_cost_delay_timing` (RELOAD).
- Improved hash join / GROUP BY memory usage (David Rowley, Jeff Davis).
- WAL I/O now in `pg_stat_io`; `track_wal_io_timing` repurposed; per-backend `pg_stat_get_backend_io()`.
- EXPLAIN ANALYZE shows BUFFERS by default; initdb enables data checksums by default; skip-scan for multicolumn btree; OR-to-ANY and IN(VALUES)→ANY transforms.

## Recommendations
1. **Baseline audit on any version:** capture `pg_settings` (including `context` and `pending_restart`) for all parameters above; flag non-default and version-sensitive ones. Confirm `hash_mem_multiplier` (2.0 on ≥PG15), `effective_io_concurrency`/`maintenance_io_concurrency` (16 on PG18), and `checkpoint_completion_target` (0.9 on ≥PG14).
2. **Slow-query triage order** (all steps use DYNAMIC/`user` GUCs, so change them in-session and verify): (a) `ANALYZE` freshness and `default_statistics_target`; (b) EXPLAIN (ANALYZE, BUFFERS) for spills (raise `work_mem`/`hash_mem_multiplier` per session, not globally); (c) parallel Workers Launched vs Planned (raise `max_parallel_workers_per_gather`, ensure `max_parallel_workers`/`max_worker_processes` headroom — the latter needs a restart); (d) JIT overhead — raise `jit_above_cost` or `jit=off` for the pool; (e) `random_page_cost` down to ~1.1–1.5 on SSD/cached systems.
3. **PG18 upgrades:** `io_method` and `io_max_combine_limit`/`io_max_concurrency` are restart-only, so plan a maintenance window; test `io_method=worker` (default) first on a replica, then `io_uring` only where kernel/platform allows. Tune `io_workers` (reload) up if `pg_aios`/wait events show saturation. Re-evaluate `random_page_cost` downward given AIO narrows the random/sequential gap. Set `autovacuum_vacuum_max_threshold` per-table for very large hot tables.
4. **Write-latency levers:** `synchronous_commit=off/local` (DYNAMIC — can be scoped to a session or role) for latency-sensitive, loss-tolerant workloads; `wal_compression=lz4` (reload) if WAL I/O bound; keep `checkpoint_completion_target=0.9` and size `max_wal_size` to avoid checkpoint storms.
5. **Thresholds that change the recommendation:** if EXPLAIN shows Batches=1 and no temp files, stop raising memory. If Workers Launched consistently < Planned, the bottleneck is pool sizing (restart-level `max_worker_processes`), not per-gather. If JIT time < ~5% of execution on genuinely expensive analytical queries, leave JIT on.

## Caveats
- Some default values (e.g., `bgwriter_flush_after` 512kB, `checkpoint_flush_after` 256kB) are Linux-specific and are 0 on other platforms.
- `io_uring` availability and behavior depend on kernel version and distro/managed-platform policy; several managed Postgres services run PG18 with `io_method=sync`.
- PG18 AIO benchmarks showing large gains are workload- and storage-dependent (largest on high-latency cloud/network storage, cold cache); local NVMe often shows only modest gains.
- `pg_settings.context` values can shift between major versions for a small number of GUCs — always verify on the exact target version rather than trusting a static list.
- Always benchmark memory changes against `max_connections × max_parallel_workers_per_gather × work_mem × hash_mem_multiplier` to avoid OOM.
