# pg_stat_statements for Finding and Diagnosing Problematic Workloads (PostgreSQL 14–18): A Practitioner's Field Manual

## TL;DR
- `pg_stat_statements` is the primary macro-analysis tool for finding problematic workloads: it aggregates per-normalized-statement counters (time, calls, rows, buffers, temp, WAL, JIT, parallelism) since the last reset, and the correct workflow is almost always **reset → wait a window → snapshot deltas → rank by the dimension that matches the symptom**, not just reading cumulative totals.
- Column names and available metrics differ by major version: PG13 renamed timing to `total_exec_time`/`total_plan_time` and added WAL columns; PG14 added `toplevel` and `pg_stat_statements_info`; PG15 added temp-block I/O timing and JIT counters; PG17 renamed `blk_read_time`→`shared_blk_read_time` and added `local_blk_*_time`, `jit_deform_*`, `stats_since`/`minmax_stats_since`; PG18 added `wal_buffers_full`, `parallel_workers_to_launch`, `parallel_workers_launched`. Write version-aware SQL.
- For a Percona context, pair `pg_stat_statements` with `pg_stat_monitor` (time-bucketed aggregation, histograms, client IP, query examples, plan capture, error/state tracking — the engine behind PMM Query Analytics) and with `pg_stat_activity`, `pg_stat_user_tables`, `auto_explain`, and `pg_wait_sampling` for the parts pgss cannot see (live sessions, per-execution plans, wait events).

## Key Findings

1. **pgss is cumulative, not time-series.** Every counter accumulates since the last `pg_stat_statements_reset()` (or since server start with `save=on`). It has no native time dimension. To find what is problematic *right now* rather than *since reset*, you must take periodic snapshots and compute deltas, or reset strategically. This single fact drives most correct workflows.

2. **Version awareness is mandatory.** The most common live-support failure is running a query with `total_time`/`blk_read_time` against a server where those columns were renamed. `total_time`→`total_exec_time` happened in PG13; `blk_read_time`→`shared_blk_read_time` in PG17.

3. **Timing metrics need supporting GUCs.** `total_plan_time` is zero unless `track_planning = on`; all `*_blk_*_time` columns are zero unless `track_io_timing = on`. Without these, whole classes of analysis silently return zeros.

4. **Normalization groups by queryid.** Literals are replaced by `$1`, `$2`; in PG18 even lists (`IN (1,2,3)`) squash to `$1 /*, ... */`. This is what makes pgss useful, but it also merges different-cost literal cases and hides the exact parameter values — for which you need `auto_explain` or `pg_stat_monitor`.

5. **pgss cannot capture per-execution plans, live waits, or (successfully) failed statements.** It tracks only successful executions and stores no plans. The docs are explicit that "`plans` and `calls` aren't always expected to match because planning and execution statistics are updated at their respective end phase, and only for successful operations. For example, if a statement is successfully planned but fails during the execution phase, only its planning statistics will be updated." Diagnosis of *why* a ranked query is slow requires `EXPLAIN (ANALYZE, BUFFERS)`, `auto_explain`, and wait-event sampling.

## Details

### 1. Version compatibility matrix (verify columns against the target server)

The internal extension version (`\dx`, `pg_extension.extversion`) maps to the server major version as follows. Note that several capabilities sometimes attributed to PG14 (planning-time columns, WAL columns) actually arrived in **PG13**, and JIT counters arrived in **PG15** — the accurate timeline is below.

| Extension ver | PG major | SQL-visible change |
|---|---|---|
| 1.8 | **13** | Renamed `total_time`→`total_exec_time`, `mean_time`→`mean_exec_time`, etc.; added planning columns `plans`, `total_plan_time`, `min/max/mean/stddev_plan_time`; added WAL columns `wal_records`, `wal_fpi`, `wal_bytes`; added `track_planning` GUC |
| 1.9 | **14** | Added `toplevel` column; added `pg_stat_statements_info` view (`dealloc`, `stats_reset`); core `compute_query_id` GUC (default `auto`); `query_id` exposed in `pg_stat_activity`, `EXPLAIN`, logs |
| 1.10 | **15** | Added `temp_blk_read_time`, `temp_blk_write_time` (needs `track_io_timing`); added JIT counters `jit_functions`, `jit_generation_time`, `jit_inlining_count/time`, `jit_optimization_count/time`, `jit_emission_count/time` |
| 1.10 (unchanged) | **16** | No new pgss columns. Core added query jumbling for **utility statements** (constants normalized in DDL/utility commands); `compute_query_id` gained `regress` value |
| 1.11 | **17** | **Renamed** `blk_read_time`→`shared_blk_read_time`, `blk_write_time`→`shared_blk_write_time`; added `local_blk_read_time`, `local_blk_write_time`; added `jit_deform_count`, `jit_deform_time`; added `stats_since`, `minmax_stats_since`; added `minmax_only` 4th arg to `pg_stat_statements_reset()`; DEALLOCATE/savepoint/two-phase GIDs/CALL params shown as constants |
| 1.12 | **18** | Added `wal_buffers_full` (confirmed by the `pg_stat_statements--1.11--1.12.sql` upgrade script adding `wal_buffers_full | bigint`; patch by Bertrand Drouvot of the AWS RDS Open Source Databases team, pgsql-hackers Feb 2025, to "tune for wal_buffers with better insights"); added `parallel_workers_to_launch`, `parallel_workers_launched`; `SET` values shown as constants |

Key points for version compatibility:
- **PG13 boundary:** below 13 use `total_time`/`mean_time`/`stddev_time`; from 13 use `total_exec_time`/`mean_exec_time`/`stddev_exec_time`.
- **PG17 boundary:** shared-block I/O timing columns changed name. Code written for ≤16 (`blk_read_time`) errors with `column "blk_read_time" does not exist` on 17/18.
- **PG18:** `pg_stat_statements.sample_rate` was proposed during the PG18 cycle but **not committed to PG18** (it is not in the PG18 docs' configuration-parameter list); do not rely on it existing. Committer Michael Paquier indicated deeper pgss integration was planned for PG19.
- **queryid stability:** the PG18 docs state that "it can be assumed that queryid values are stable between minor version releases of PostgreSQL, providing that instances are running on the same machine architecture and the catalog metadata details match. Compatibility will only be broken between minor versions as a last resort." It is *not* safe to assume stability across *major* versions; the value is derived from the post-parse-analysis tree (OIDs, architecture-sensitive). Two physical-replication peers share the same `queryid` for the same query.

### 2. Setup and configuration

`postgresql.conf` (requires restart because it is a shared-memory preloaded module):

```
shared_preload_libraries = 'pg_stat_statements'   # restart required
compute_query_id = on            # or 'auto' (default); required for pgss to be active
pg_stat_statements.max = 10000   # default 5000; rows tracked before LRU eviction
pg_stat_statements.track = top   # top (default) | all (includes nested) | none
pg_stat_statements.track_utility = on   # default on; DDL/VACUUM/etc.
pg_stat_statements.track_planning = off # default OFF; turn on to populate plan-time columns
pg_stat_statements.save = on     # default on; persist across restart
track_io_timing = on             # NOT a pgss GUC; needed for *_blk_*_time columns
track_wal_io_timing = on         # PG14–17 relevant where WAL I/O timing is wanted
```

Then, per database you want to query the view in: `CREATE EXTENSION pg_stat_statements;`

Notes and gotchas:
- The module consumes shared memory (`pg_stat_statements.max * track_activity_query_size`) whenever loaded, even with `track = none`.
- The default `pg_stat_statements.max` is **5000** (PG18 docs, §F.32). Raising it to 10000 is the common recommendation for busy systems.
- `compute_query_id` must be `on` or `auto` (or a third-party module loaded), otherwise pgss is inactive. If you use an external queryid module, set `compute_query_id = off`.
- `track = all` is invaluable for tuning functions/procedures (nested statements) but doubles the accounting; totals then include both the top-level call and its nested statements, so **do not sum across `toplevel` values** without filtering.
- `track_utility = on` means `VACUUM`, `CREATE INDEX`, `COPY`, etc. appear. Turn off if utility noise (e.g. XA `PREPARE TRANSACTION`/`COMMIT PREPARED`) dominates and is unwanted.
- `track_activity_query_size` (default 1024 bytes for `pg_stat_activity`) and the pgss query-text file govern truncation; long normalized texts can be truncated. Raise `track_activity_query_size` (e.g. 2048+) if long queries matter — Percona's PMM setup documentation states "It is important to set maximal length of query to 2048 characters or more for PMM to work properly."
- On very high-TPS systems the pgss spinlock in `pgss_store()` can become a bottleneck; mitigations are a smaller `max`, fewer per-database scrapers, or (future) sampling.

### 3. Workflow: top queries by total time (aggregate load)

**Symptom:** general slowness / high CPU; "which queries consume the most server time overall."

**PG13+ (recommended, includes planning time and % of total):**
```sql
SELECT queryid,
       calls,
       round((total_exec_time + total_plan_time)::numeric, 2) AS total_time_ms,
       round(mean_exec_time::numeric, 3) AS mean_ms,
       round((100 * (total_exec_time + total_plan_time)
              / sum(total_exec_time + total_plan_time) OVER ())::numeric, 2) AS pct_total,
       rows,
       left(query, 100) AS query
FROM pg_stat_statements
ORDER BY (total_exec_time + total_plan_time) DESC
LIMIT 25;
```
For ≤12 substitute `total_time` for `total_exec_time` and drop `total_plan_time`.

**Interpretation:** the `pct_total` column is the single most useful triage number — it tells you what fraction of database time a normalized statement is responsible for. A query at 40% of total time is your first target regardless of whether it is individually "slow." Fast queries run millions of times routinely outrank individually slow ones.

**Remediation follows the sub-cause** (index, rewrite, work_mem, plan management — see the specific workflows below). This query only prioritizes.

### 4. Workflow: slowest by mean time

**Symptom:** individual latency / SLA breaches.
```sql
SELECT queryid, calls,
       round(mean_exec_time::numeric, 2)   AS mean_ms,
       round(max_exec_time::numeric, 2)    AS max_ms,
       round(stddev_exec_time::numeric, 2) AS stddev_ms,
       rows / nullif(calls,0)              AS rows_per_call,
       left(query, 120) AS query
FROM pg_stat_statements
WHERE calls > 10                 -- ignore one-off noise
ORDER BY mean_exec_time DESC
LIMIT 25;
```
**Interpretation / pitfall:** always gate on `calls`. A single `pg_sleep()` or a one-time maintenance query will otherwise top the list. Compare `mean` against `max` and `stddev` — a low mean with a huge max signals occasional pathology (locking, cold cache, plan flip), not a consistently slow query.

### 5. Workflow: high-frequency, low-cost queries

**Symptom:** "no single query is slow but the box is saturated" — death by a thousand cuts, often an N+1 pattern or a chatty ORM.
```sql
SELECT queryid, calls,
       round(mean_exec_time::numeric, 4) AS mean_ms,
       round(total_exec_time::numeric, 2) AS total_ms,
       left(query, 120) AS query
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT 25;
```
**Remediation:** batch/collapse N+1 queries, add application-side caching, use prepared statements to cut planning overhead, and introduce connection pooling (PgBouncer) if the volume is driven by connection churn. This is where the delta approach matters most: high call counts accumulate fastest, so a recent window highlights active offenders.

### 6. Workflow: high-variance / inconsistent queries

**Symptom:** unpredictable latency, suspected plan instability or contention.
```sql
SELECT queryid, calls,
       round(mean_exec_time::numeric, 2)   AS mean_ms,
       round(stddev_exec_time::numeric, 2) AS stddev_ms,
       round(min_exec_time::numeric, 2)    AS min_ms,
       round(max_exec_time::numeric, 2)    AS max_ms,
       round((stddev_exec_time / nullif(mean_exec_time,0))::numeric, 2) AS coeff_var,
       left(query, 100) AS query
FROM pg_stat_statements
WHERE calls > 50
ORDER BY stddev_exec_time DESC
LIMIT 25;
```
**Interpretation:** a high coefficient of variation (stddev/mean) points to bimodal behaviour: generic-vs-custom plan flips, parameter-dependent plans (skewed data), cache warm/cold effects, or lock waits. **Caveat:** `min`/`max`/`stddev` are non-cumulative and are *not* recoverable by snapshot subtraction — deltas give you counts and totals only. In PG17+ you can reset just the min/max with `pg_stat_statements_reset(0,0,0,true)` (the `minmax_only` argument) to re-baseline extremes without losing cumulative history; `minmax_stats_since` tells you when that last happened.
**Remediation:** `EXPLAIN (ANALYZE, BUFFERS)` with representative and edge-case parameters; consider `plan_cache_mode`, extended statistics (`CREATE STATISTICS`), or query rewrite; sample waits to rule out contention.

### 7. Workflow: poor cache hit ratio / I/O-heavy queries

**Symptom:** disk-bound queries, high read latency.
```sql
SELECT queryid, calls,
       shared_blks_hit, shared_blks_read,
       round(100.0 * shared_blks_hit
             / nullif(shared_blks_hit + shared_blks_read, 0), 2) AS hit_pct,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       left(query, 100) AS query
FROM pg_stat_statements
WHERE shared_blks_hit + shared_blks_read > 10000   -- ignore trivial I/O
ORDER BY shared_blks_read DESC
LIMIT 25;
```
**Interpretation guide (community rule of thumb):** hit ratio >99% excellent; 90–99% acceptable; 50–90% investigate; <50% poor. **Critical caveat:** `shared_blks_read` means "read from the PostgreSQL buffer pool" — it is *not necessarily a physical disk read*, because the OS page cache may satisfy it. Do not equate `shared_blks_read` with disk I/O; use `track_io_timing` and `shared_blk_read_time` (PG17+) / `blk_read_time` (≤16) for genuine I/O-wait time. Rank by absolute `shared_blks_read`, not ratio alone, because a huge-volume query at 98% can still dominate physical reads.

### 8. Workflow: temp file / spill (work_mem candidates)

**Symptom:** sorts/hashes spilling to disk; slow analytics.
```sql
SELECT queryid, calls,
       temp_blks_read, temp_blks_written,
       pg_size_pretty((temp_blks_written * 8192)::bigint) AS temp_written,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       left(query, 100) AS query
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 25;
```
On PG15+ with `track_io_timing = on`, also select `temp_blk_read_time + temp_blk_write_time` to quantify the time cost of spilling.
**Remediation:** raise `work_mem` — preferably per role/session/transaction (`SET LOCAL work_mem = '256MB'`, or `ALTER ROLE reporting SET work_mem = ...`) rather than globally, because `work_mem` is allocated *per sort/hash node per connection* and a global bump multiplies across concurrency. Confirm the spill with `EXPLAIN (ANALYZE, BUFFERS)` — look for `Sort Method: external merge Disk:` or `Hash Batches: N > 1`. Consider `hash_mem_multiplier`, indexing to avoid the sort entirely, or query rewrite. Enable `log_temp_files = 0` to log every spill. Set `temp_file_limit` to cap runaway spills.

### 9. Workflow: WAL generation (write amplification)

**Symptom:** replication lag, checkpoint/backup pressure, write-heavy load. (PG13+)
```sql
SELECT queryid, calls,
       wal_records, wal_fpi,
       pg_size_pretty(wal_bytes::bigint) AS wal,
       round((wal_bytes / nullif(calls,0))::numeric, 0) AS wal_bytes_per_call,
       left(query, 100) AS query
FROM pg_stat_statements
ORDER BY wal_bytes DESC
LIMIT 25;
```
**Interpretation:** high `wal_fpi` (full-page images) points to writes concentrated just after checkpoints — full-page writes dominate; widen `checkpoint_timeout` / raise `max_wal_size` to spread checkpoints. A classic pathology: `begin; delete ...; rollback;` loops generate large WAL for no net work (and, because the statements succeed inside the transaction, pgss still records them). On PG18, add `wal_buffers_full` to find queries repeatedly filling WAL buffers — a signal to raise `wal_buffers`.
**Remediation:** batch writes, reduce index count on hot tables (fewer FPIs), checkpoint tuning, fillfactor for HOT updates.

### 10. Workflow: planning vs execution overhead (PG13+, needs track_planning)

**Symptom:** short queries dominated by planning; candidates for prepared statements / generic plans.
```sql
SELECT queryid, calls,
       round(total_plan_time::numeric, 2) AS plan_ms,
       round(total_exec_time::numeric, 2) AS exec_ms,
       round((100 * total_plan_time
              / nullif(total_plan_time + total_exec_time,0))::numeric, 1) AS plan_pct,
       round(mean_plan_time::numeric, 3) AS mean_plan_ms,
       left(query, 100) AS query
FROM pg_stat_statements
WHERE plans > 0
ORDER BY total_plan_time DESC
LIMIT 25;
```
**Interpretation:** a high `plan_pct` on frequently-called queries means planning cost is wasted repeatedly — use server-side prepared statements so PostgreSQL can reuse a generic plan (`plan_cache_mode`). Note the docs caveat: `plans` and `calls` need not match — if a cached plan is reused, only execution stats update; if a statement plans then fails execution, only planning stats update.
**Pitfall:** `track_planning` is off by default; if `total_plan_time` is all zeros that is the reason. It adds measurable overhead on high-concurrency systems (planning-time contention), so enable deliberately.

### 11. Workflow: real I/O time (needs track_io_timing)

**Symptom:** distinguish CPU-bound from I/O-bound queries.
```sql
-- PG17/18 column names:
SELECT queryid, calls,
       round(shared_blk_read_time::numeric, 2)  AS shared_read_ms,
       round(shared_blk_write_time::numeric, 2) AS shared_write_ms,
       round(local_blk_read_time::numeric, 2)   AS local_read_ms,
       round(temp_blk_read_time::numeric, 2)    AS temp_read_ms,
       round(mean_exec_time::numeric, 2)        AS mean_ms,
       left(query, 100) AS query
FROM pg_stat_statements
ORDER BY (shared_blk_read_time + shared_blk_write_time) DESC
LIMIT 25;
```
For **PG13–16** use `blk_read_time` / `blk_write_time` (there is no shared/local split; temp timing exists from PG15). The proportion of `*_blk_read_time` to `total_exec_time` tells you whether a query is I/O-bound (optimize I/O: indexing, caching, faster storage) or CPU-bound (optimize computation: rewrite, JIT tuning, better plans). `track_io_timing` is off by default because it repeatedly queries the OS clock; measure timer overhead with `pg_test_timing` before enabling.

### 12. Workflow: JIT overhead (PG15+)

**Symptom:** analytical queries slower than expected after JIT kicks in; JIT compiling more than it saves.
```sql
SELECT queryid, calls,
       round(((jit_generation_time + jit_inlining_time
             + jit_optimization_time + jit_emission_time)
             / nullif(total_exec_time + total_plan_time,0) * 100)::numeric, 1)
             AS jit_time_pct,
       jit_functions,
       round((jit_generation_time + jit_inlining_time
             + jit_optimization_time + jit_emission_time)::numeric, 1) AS jit_total_ms,
       left(query, 100) AS query
FROM pg_stat_statements
WHERE jit_functions > 0
ORDER BY jit_time_pct DESC
LIMIT 25;
```
On PG17+ add `jit_deform_count`/`jit_deform_time`. **Interpretation:** a high `jit_time_pct` means JIT compilation is eating the query's own runtime — JIT is triggering too eagerly (the cost thresholds are plan-time estimates, so bad row estimates can wrongly cross `jit_above_cost`). The percentage can exceed 100 when parallel workers compile concurrently.
**Remediation:** raise `jit_above_cost` / `jit_inline_above_cost` / `jit_optimize_above_cost`, or set `jit = off` for affected OLTP workloads. Verify with `EXPLAIN (ANALYZE)` JIT timing block.

### 13. Workflow: row-returning / bloated result sets

**Symptom:** network saturation, slow app, `SELECT *` over-fetching.
```sql
SELECT queryid, calls, rows,
       rows / nullif(calls,0) AS rows_per_call,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       left(query, 100) AS query
FROM pg_stat_statements
WHERE calls > 0
ORDER BY rows / nullif(calls,0) DESC
LIMIT 25;
```
**Remediation:** add `LIMIT`/pagination, select only needed columns, push aggregation into SQL. Note `rows` also counts rows affected by DML and (PG13+) rows from `CREATE TABLE AS`, `SELECT INTO`, `FETCH`, `REFRESH MATERIALIZED VIEW`.

### 14. Workflow: missing indexes (pgss + pg_stat_user_tables)

pgss alone does not know about scans; combine it with `pg_stat_user_tables`. Start table-side to find heavy sequential scanning:
```sql
SELECT schemaname, relname,
       seq_scan, seq_tup_read, idx_scan,
       seq_tup_read / nullif(seq_scan,0) AS avg_rows_per_seq_scan,
       n_live_tup,
       pg_size_pretty(pg_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE seq_scan > 0 AND n_live_tup > 10000
ORDER BY seq_tup_read DESC
LIMIT 20;
```
Then pivot to pgss to find the specific statements hitting that table and their filter columns:
```sql
SELECT queryid, calls, round(mean_exec_time::numeric,2) AS mean_ms, rows,
       left(query, 150) AS query
FROM pg_stat_statements
WHERE query ILIKE '%orders%'
ORDER BY mean_exec_time * calls DESC
LIMIT 10;
```
Then confirm with `EXPLAIN (ANALYZE, BUFFERS)` and read the `Filter:`/`Sort:` lines for index candidates. **Interpretation (CYBERTEC method):** the gold-standard signal is a large table with huge `seq_tup_read` and near-zero `idx_scan`; the offending query almost always also ranks high in pgss by `total_exec_time`. A single missing index in a hot path can degrade the entire instance.
**Remediation:** `CREATE INDEX CONCURRENTLY` (most-selective/equality columns first, range/sort columns last), then reset pgss and the table stats and re-measure. Context matters — small reference tables and OLAP full scans are legitimately sequential.

### 15. Workflow: query normalization, queryid, and correlation

- Normalization replaces literals with `$n`; the stored text is the *first* occurrence's text (comments and layout preserved). Different `search_path` can split identical texts into separate entries; dropped/recreated objects change the `queryid`.
- **Correlate with live sessions** (PG14+ exposes `query_id` in `pg_stat_activity`):
```sql
SELECT a.pid, a.state, a.wait_event_type, a.wait_event,
       now() - a.query_start AS running_for,
       s.queryid, left(s.query, 100) AS normalized
FROM pg_stat_activity a
LEFT JOIN pg_stat_statements s ON s.queryid = a.query_id
WHERE a.state = 'active' AND a.pid <> pg_backend_pid()
ORDER BY running_for DESC;
```
This is the only reliable way to link a live backend to its pgss entry — the query *text* in `pg_stat_activity` (raw, up to `track_activity_query_size`) does not match the normalized pgss text.
- **Correlate with logs and plans:** set `compute_query_id = on`, put `query_id=%Q` in `log_line_prefix` (needs `log_duration`/`log_min_duration_statement`), and use `auto_explain` (with `auto_explain.log_verbose` honoring `compute_query_id` from PG16) to capture actual plans and bound parameter values for a given `queryid`.

### 16. Workflow: toplevel vs nested, utility statements

With `track = all`, the `toplevel` boolean (PG14+) distinguishes client-issued statements from statements executed inside functions/procedures. To analyze only client-visible load:
```sql
SELECT queryid, calls, round(total_exec_time::numeric,2) AS total_ms, left(query,80) AS q
FROM pg_stat_statements
WHERE toplevel                       -- PG14+
ORDER BY total_exec_time DESC LIMIT 25;
```
Procedures/functions are tracked via `CALL ...` at top level; their internal SQL only appears with `track = all`. **Pitfall:** summing time across both levels double-counts. PG16 added utility-statement jumbling so DDL/utility commands now normalize their constants too.

### 17. Workflow: snapshot / delta analysis (what is problematic RIGHT NOW)

Because pgss is cumulative, the professional method (PostgresAI / pgDash) is to snapshot and diff:
```sql
CREATE TABLE IF NOT EXISTS pgss_snap AS
  SELECT now() AS snap_time, * FROM pg_stat_statements WITH NO DATA;

-- take a snapshot (schedule every 1–5 min):
INSERT INTO pgss_snap SELECT now(), * FROM pg_stat_statements;

-- diff two snapshots over a window:
WITH a AS (SELECT * FROM pgss_snap WHERE snap_time = :t1),
     b AS (SELECT * FROM pgss_snap WHERE snap_time = :t2)
SELECT b.queryid,
       b.calls - a.calls AS calls_delta,
       round((b.total_exec_time - a.total_exec_time)::numeric, 2) AS exec_ms_delta,
       round(((b.total_exec_time - a.total_exec_time)
              / nullif(b.calls - a.calls,0))::numeric, 3) AS mean_ms_in_window,
       (b.shared_blks_read - a.shared_blks_read) AS reads_delta,
       (b.wal_bytes - a.wal_bytes) AS wal_delta
FROM b JOIN a USING (queryid, userid, dbid, toplevel)
WHERE b.calls > a.calls
ORDER BY exec_ms_delta DESC
LIMIT 25;
```
Three derived-metric families to compute per window (PostgresAI): time-series rates (dM/dt — e.g. calls/sec, MB WAL/sec), per-call averages (dM/d(calls)), and share-of-total (%M). **Caveat:** `min`/`max`/`stddev` cannot be derived from deltas — only cumulative counters subtract meaningfully. `pg_stat_statements_info.stats_reset` (PG14+) tells you the baseline for the "since reset" special case; before PG14 that timestamp was unavailable.

### 18. Workflow: percentage-of-total DB time

Already embedded above via `sum(...) OVER ()`. Present a whole-instance summary for triage:
```sql
SELECT sum(calls) AS total_calls,
       round((sum(total_exec_time)/1000)::numeric, 1) AS total_exec_s,
       round(100.0 * sum(shared_blks_hit)
             / nullif(sum(shared_blks_hit + shared_blks_read),0), 2) AS overall_hit_pct
FROM pg_stat_statements;
```

### 19. Reset strategy, retention, and eviction

- **Selective reset** (PG12+): `pg_stat_statements_reset(userid, dbid, queryid)`. All-zero args reset everything. Reset a single statement after tuning it: `SELECT pg_stat_statements_reset(0, 0, :queryid);`
- **Min/max-only reset** (PG17+): `pg_stat_statements_reset(0,0,0,true)` re-baselines extremes without discarding cumulative history.
- **Eviction / retention:** when distinct statements exceed `pg_stat_statements.max`, the least-used entries are evicted (deallocated) in batches. Watch this via `pg_stat_statements_info` (PG14+):
```sql
SELECT dealloc, stats_reset FROM pg_stat_statements_info;
```
A steadily climbing `dealloc` means `max` is too low — you are losing statements. The PG18 docs warn that "Queries on which normalization can be applied may be observed with constant values in pg_stat_statements, especially when there is a high rate of entry deallocations… consider increasing pg_stat_statements.max." So high dealloc rates cause literals to leak into the displayed text; raise `pg_stat_statements.max`.
- **Query-text file:** representative texts live in an external file, not shared memory; if it grows unmanageable pgss may discard texts (view shows NULL `query` but keeps stats) — reduce `max` if this recurs.
- **`save` behaviour:** with `save = on` (default) stats survive restart; with `save = off` they reset on restart. Reset before benchmarks.
- **Security/permissions:** only superusers and roles with `pg_read_all_stats` can see other users' SQL text and `queryid`; other users see stats but not text. `pg_stat_statements_reset()` is superuser-only unless granted. `track_activity_query_size` and `log_line_prefix` exposure are the usual data-governance levers.

### 20. Combining with other tools

- **`pg_stat_activity`** — live/in-flight sessions, wait events, `query_id` join (§15). pgss is historical/aggregate; `pg_stat_activity` is the now.
- **`pg_stat_user_tables` / `pg_stat_user_indexes`** — scan counts, index usage, unused indexes; the table-side complement for the missing-index workflow (§14).
- **`auto_explain`** — the only way to get the *actual per-execution plan* and bound parameters for a ranked query; pgss stores no plans. Use `auto_explain.log_min_duration`, `log_analyze`, `log_buffers`; from PG16 verbose mode honors `compute_query_id`.
- **`pg_wait_sampling`** — samples wait events and (with pgss) aggregates them per `queryid` in `pg_wait_sampling_profile`. Load order matters: put `pg_stat_statements` *before* `pg_wait_sampling` in `shared_preload_libraries` so utility-statement queryids are not overwritten; set `pg_wait_sampling.profile_queries = top` (or `all`). This answers *what a ranked query waits on* (I/O, locks, LWLocks) — the dimension pgss cannot express.
- **`EXPLAIN (ANALYZE, BUFFERS)`** — the confirm-and-fix step for any candidate; PG18 shows buffer counts by default.

### 21. Percona pg_stat_monitor (PGSM) and PMM Query Analytics

`pg_stat_monitor` is Percona's superset of pgss (built on the same hooks, "more advanced replacement"), supporting PostgreSQL 14+ and packaged for 13–18. It addresses pgss's core limitation — the lack of a time dimension — by aggregating into **configurable time buckets** (`pgsm_bucket_time`, number via `pgsm_max_buckets`), so you can compare peak vs off-peak vs report windows without manual snapshotting.

Key additions over pgss:
- **Time-interval bucketing** — max/min/mean become meaningful over short windows; bucket status (done/current) is exposed.
- **Response-time histograms** — `resp_calls` / the histogram view (`pgsm_histogram_buckets`, `pgsm_histogram_min`, `pgsm_histogram_max`); from 2.0 extra out-of-range buckets. This surfaces the "runs fast 60k times, slow 1k times" bimodality pgss hides.
- **Multi-dimensional grouping** — `(userid, clientip, dbid, queryid)` vs pgss's `(userid, dbid, queryid[, toplevel])`; the client IP lets you trace load to a specific app server.
- **Actual query examples** — `pgsm_normalized_query = 0` shows real parameter values (runnable for `EXPLAIN`), not just placeholders.
- **Query plan capture** (`pgsm_enable_query_plan`), **table-access tracking** per statement, **CPU time**, **command type** (`cmd_type`), and **error/warning/state tracking** (`elevel`, captures failed queries pgss misses) — plus SQLcommenter metadata.

Cautions: PGSM and pgss report memory/WAL stats inconsistently if run together; PGSM is in-memory bucketed and best paired with a long-term store; only superusers / `pg_read_all_stats` see sensitive columns; `pgsm_max` bounds its shared memory (with `pgsm_enable_overflow`). Note also a known PMM defect (per Percona PMM 2.44.1 release notes): with `pg_stat_monitor.pgsm_enable_query_plan` enabled, "Query Analytics (QAN) displays incorrect execution times that can be off by 1000x or more… because enabling query plans causes pg_stat_monitor to create multiple records for each query." Enable plan capture with that caveat in mind.

**PMM Query Analytics (QAN)** is the visualization layer: `pmm-agent` scrapes either pgss (`qan-postgresql-pgstatements-agent`) or PGSM, ships one-minute buckets aggregated by query ID to the PMM server, and stores them in ClickHouse. PMM 2.36.0 first added PGSM 2.0 support in QAN — per Percona's release notes, "We are excited to announce PMM 2.36 now supports pg_stat_monitor 2.0 (PGSM 2.0) in QAN," and PGSM 2.0's rearchitecture yields "fewer lock acquisitions and increases performance by approximately 20%." QAN adds plan/histogram/metadata tabs when PGSM is the source. Set `track_activity_query_size ≥ 2048` for PMM.

**When to use which:** pgss for a universally-available baseline and scripted diagnostics on any server (including RDS/managed); PGSM/PMM when you need time-windowed trends, histograms, per-client attribution, captured plans, failed-query visibility, or a dashboard for a team.

## Recommendations

**Stage 1 — Baseline setup (do first, once).** Ensure `shared_preload_libraries` includes `pg_stat_statements` (and `pg_stat_monitor` first-then-`pg_wait_sampling` if used), `compute_query_id = on`, `track_io_timing = on`, `pg_stat_statements.max = 10000`, `track_activity_query_size = 2048`. Decide `track = top` (OLTP triage) vs `all` (function-heavy tuning). Leave `track_planning` off unless you specifically need plan-time analysis. Verify `\dx` version matches the server major to pick correct column names. *Threshold to change:* if `pg_stat_statements_info.dealloc` climbs, raise `max`.

**Stage 2 — Triage (per incident).** Run the total-time + %-of-total query (§3) to rank load, then branch by symptom: mean-time (§4) for SLA, calls (§5) for N+1, stddev (§6) for instability, cache/read (§7) for I/O, temp (§8) for work_mem, WAL (§9) for write/replication. Join `pg_stat_activity` on `query_id` (§15) to see if the offender is live.

**Stage 3 — Windowed analysis.** If cumulative totals are dominated by history, switch to snapshot deltas (§17) or `pg_stat_monitor` buckets to isolate what is problematic *now*. Use `pg_wait_sampling` to attribute waits per queryid.

**Stage 4 — Confirm and fix.** For each candidate, run `EXPLAIN (ANALYZE, BUFFERS)` (or pull the plan from `auto_explain`/PGSM). Apply the remediation matched to the metric — `CREATE INDEX CONCURRENTLY`, targeted `work_mem`, query rewrite, prepared statements/`plan_cache_mode`, checkpoint/WAL tuning, JIT thresholds, pooling. Then `pg_stat_statements_reset(0,0,:queryid)` and re-measure that one statement. *Success threshold:* the statement's share of total time and its `mean_exec_time` both drop materially in the next window.

**Stage 5 — Institutionalize.** Persist periodic snapshots (or PMM/ClickHouse) for trend baselines and post-deploy regression checks (compare `seq_scan` and pgss rankings before/after each release).

## Caveats

- **No time dimension** — cumulative since reset; use deltas/buckets for "now."
- **Version-specific columns** — `total_time`→`total_exec_time` at PG13; `blk_read_time`→`shared_blk_read_time` at PG17; plan columns need `track_planning`; `*_blk_*_time` need `track_io_timing`. Always match SQL to the server version.
- **Normalization merges literals** — different-cost literal cases share one row; exact values require `auto_explain` or PGSM examples. Hash collisions can (rarely) merge unrelated queries; differing `search_path` can split identical texts.
- **Successful executions only** — statements that fail (including on `statement_timeout`) are not tracked by pgss; but statements that succeed inside a later-rolled-back transaction *are*. PGSM can track failed queries.
- **No per-execution plans** — pgss stores none; pair with `auto_explain`/`EXPLAIN`.
- **`shared_blks_read` ≠ disk read** — it is a buffer-pool miss possibly served by OS cache; use I/O timing for true disk cost.
- **Truncation** — long normalized texts limited by the query-text file / `track_activity_query_size`; the file may be discarded under pressure (NULL `query`, stats preserved).
- **Overhead** — low for most hardware but real at extreme TPS (spinlock in `pgss_store`), and `track_planning`/`track_io_timing` add cost; `pg_test_timing` measures timer overhead before enabling I/O timing.
- **Security** — non-privileged users cannot see other users' query text/`queryid`; grant `pg_read_all_stats` deliberately.
- **queryid stability** — assumed stable only between minor versions on matching architecture and catalog metadata; not guaranteed across major versions. Compare only within the same server version and catalog state.
- **`sample_rate`** — not present in PG18 despite dev-cycle discussion; do not assume it exists.
- **`min`/`max`/`stddev`** — non-cumulative; not recoverable via snapshot subtraction (PG17 `minmax_only` reset re-baselines them).