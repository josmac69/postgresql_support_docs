# pg_stat_monitor: Installation and Practitioner's Guide for Finding Problematic PostgreSQL Workloads (PostgreSQL 14–18)

## TL;DR
- **pg_stat_monitor (PGSM) is Percona's advanced, drop-in superset of pg_stat_statements** that aggregates statistics into rotating time buckets and adds dimensions pg_stat_statements lacks (client IP, application, username, actual query examples, query plan, relations, SQL comments, error levels, latency histogram). Install it via `percona-release setup ppgXX` + `percona-pg-stat-monitorXX`, add it to `shared_preload_libraries` **after** `pg_stat_statements`, restart, and `CREATE EXTENSION pg_stat_monitor` in every database you want to query. The current release is 2.3.2 (released March 2, 2026, per Percona Documentation) and supports PostgreSQL 13–18.
- **The single biggest operational gotcha is time-bucketing**: data is written to a chain of buckets (`pgsm_max_buckets` × `pgsm_bucket_time`), and when a bucket's lifetime is reused its contents are overwritten, so long-lived cumulative analysis requires either snapshotting buckets externally (this is exactly what PMM's Query Analytics does) or widening buckets. Most GUCs that control memory/buckets/histogram are `postmaster` context and require a restart.
- **PGSM does NOT expose PostgreSQL wait events** — there is no `wait_event`/`wait_event_type` column in any version of the view; for true wait analysis you still sample `pg_stat_activity`. PGSM's I/O timing columns (`shared_blk_read_time`, etc.) are the closest proxy. For version-specific compatibility, know the version-specific column renames (PG14 `username`→PG15 `user`→PG16+ `username`; PG16 `blk_read_time`→PG17/18 `shared_blk_read_time`; PG18 adds `wal_buffers_full`, `parallel_workers_to_launch`, `parallel_workers_launched`).

## Key Findings

1. **Packaging is straightforward and identical across PG 14–18** — only the version suffix changes. Percona repos (`percona-pg-stat-monitorNN`), PGDG YUM (`pg_stat_monitor_NN`), PGXN (`pgxn install pg_stat_monitor`), or source (`make USE_PGXS=1`). Percona and PGDG ship RPM/DEB for 13, 14, 15, 16, 17, 18.
2. **Load ordering matters.** On PG13 PGSM *must* follow pg_stat_statements. On PG14+ order is free, but per Percona/PGXN docs, "if both pg_stat_statements and pg_stat_monitor are loaded, only the last listed extension captures utility queries, CREATE TABLE, Analyze, etc." — so Percona recommends `ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements, pg_stat_monitor'` (PGSM last).
3. **The view is multi-dimensional**: the aggregation key includes bucket, userid, dbid, queryid, client_ip, planid, application_name, toplevel and command type — far finer than pg_stat_statements' (userid, dbid, queryid). This is what enables noisy-neighbor and per-app troubleshooting.
4. **Histogram (`resp_calls` + `histogram()` function)** is PGSM's distinguishing feature for finding long-tail/bimodal latency and P99 outliers that a mean hides.
5. **Query plan capture is off by default and is comparatively expensive** — `pgsm_enable_query_plan` creates a separate row per distinct plan, which can distort timing aggregation; Percona/PMM explicitly recommend leaving it off for routine monitoring.
6. **PMM Query Analytics (QAN) consumes PGSM** via `pmm-admin add postgresql --query-source=pgstatmonitor`; QAN persists the bucketed data so you get historical trend analysis without losing data to bucket rotation.

## Details

### 1. Installation (all methods, PG 14–18)

#### 1.1 Version-compatibility matrix

| pg_stat_monitor release | Date | PostgreSQL majors supported | Notable |
|---|---|---|---|
| 2.3.2 | 2026-03-02 | 13, 14, 15, 16, 17, 18 | Fixes truncation of queries mid multi-byte character |
| 2.3.1 | 2025-11-27 (release-notes page) / news post says 2025-11-28 | 13–18 | **Adds PG18 compatibility**; adds `wal_buffers_full`, `parallel_workers_to_launch`, `parallel_workers_launched` |
| 2.3.0 | — | — | **Never released** (skipped; use 2.3.1) |
| 2.2.0 | 2025-06-30 | 13–17 | |
| 2.1.1 | 2025-02-27 | 13–17 | |
| 2.1.0 | 2024-09-10 | 13–17 | |
| 2.0.0 | 2023-03-20 | 13–15 (at the time) | Major rearchitecture; pg_stat_statements-compatible view; `pgsm_query_id`; deprecated/removed `pg_stat_monitor_settings` view; per the 2.0.0 release notes, "Its improved internal architecture leads to fewer lock acquisitions, and therefore an improved performance by approximately 20% when tested using pgbench." |

Percona states PGSM "should work on the latest version of both Percona Distribution for PostgreSQL and PostgreSQL, but is only tested with these versions" — 13, 14, 15, 16, 17, 18. PGSM is a superset of pg_stat_statements and the two **can coexist** (both loaded together), with the caveat that when both are loaded, memory-block and WAL statistics are displayed inconsistently between them, and only the last-listed extension captures utility statements.

**PostgreSQL 18-specific note:** PG18 support arrived in PGSM 2.3.1. Per Percona Documentation: "This release adds compatibility with PostgreSQL 18 and introduces three new monitoring metrics for improved visibility into write-ahead log (WAL) and parallel workers." The three new columns are `wal_buffers_full`, `parallel_workers_to_launch`, and `parallel_workers_launched`, and they appear only in the PG18 view. Amazon RDS introduced pg_stat_monitor for RDS PostgreSQL 18.2+ ("Introduced the pg_stat_monitor extension for PostgreSQL 18.2 and higher to provide comprehensive query performance insights and help identify performance bottlenecks").

#### 1.2 Install from Percona repositories (apt/yum) — recommended

```bash
# 1. Install the percona-release tool (Debian/Ubuntu example)
wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
sudo dpkg -i percona-release_latest.generic_all.deb

# 2. Enable the Percona Distribution for PostgreSQL repo (ppgXX = PG major)
sudo percona-release setup ppg17      # ppg14 / ppg15 / ppg16 / ppg17 / ppg18

# 3a. Debian/Ubuntu
sudo apt update
sudo apt-get install percona-pg-stat-monitor17

# 3b. RHEL / Rocky / Alma / Oracle Linux
sudo yum install percona-pg-stat-monitor17
```

Package name pattern: **`percona-pg-stat-monitorNN`** (e.g. `percona-pg-stat-monitor14` … `percona-pg-stat-monitor18`). Some Percona blog docs also show `apt install -y percona-pg-stat-monitor-15` with a dash; the canonical package name is `percona-pg-stat-monitorNN`.

#### 1.3 Install from the PGDG official repositories

The RPM packages are available in the official PostgreSQL (PGDG) YUM repositories for all supported versions (RHEL/Rocky/CentOS/Oracle Linux). After enabling the PGDG repo:

```bash
sudo dnf install -y pg_stat_monitor_17     # pg_stat_monitor_14 ... pg_stat_monitor_18
```

Package name pattern for PGDG: **`pg_stat_monitor_NN`** (underscore, matches the PGDG convention). Percona's docs note the YUM repository supports PGSM for all supported versions on RHEL/Rocky/CentOS/Oracle Linux 7, 8 (and 9), and it is also built for PGDG apt.

#### 1.4 Install from PGXN

```bash
pgxn install pg_stat_monitor
```

Requires the PGXN client. PGXN builds from source, so it needs the same toolchain as a source build (below).

#### 1.5 Build from source

```bash
git clone git://github.com/percona/pg_stat_monitor.git
cd pg_stat_monitor
make USE_PGXS=1
sudo make USE_PGXS=1 install
```

**Build dependencies:** `git`, `make`, `gcc`, and `pg_config` (from the matching `-devel`/`-dev` PostgreSQL package). `USE_PGXS=1` tells the PGXS build system to locate the server headers/libraries via `pg_config`. If you have multiple PostgreSQL versions installed, point the build at the right one:

```bash
make USE_PGXS=1 PG_CONFIG=/usr/pgsql-17/bin/pg_config
make USE_PGXS=1 PG_CONFIG=/usr/pgsql-17/bin/pg_config install
```

`pg_config` must correspond to the exact major version you intend to load the extension into, since the compiled `.so` is ABI-specific to a PostgreSQL major version.

#### 1.6 Enable and create the extension (setup)

pg_stat_monitor requires additional shared memory and therefore must be preloaded at server start — it cannot be enabled at runtime.

```sql
-- Preload. If other modules are already present, list them ALL, comma-separated.
-- PGSM should come AFTER pg_stat_statements.
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements, pg_stat_monitor';
```

```bash
# Restart is mandatory for shared_preload_libraries to take effect
sudo systemctl restart postgresql-17
```

```sql
-- Create the view in EACH database you want to inspect (superuser or db owner)
CREATE EXTENSION pg_stat_monitor;
```

**Ordering rationale:** `shared_preload_libraries` is read at startup; both PGSS and PGSM hook the executor. On **PG13**, PGSM must be listed after PGSS or it will not initialize correctly. On **PG14+**, either order works, *but* only the last-listed extension captures utility commands (CREATE, ANALYZE, VACUUM, etc.) while the first captures ordinary SELECT/INSERT/UPDATE/DELETE. To get complete statistics in PGSM, list it **last**: `'pg_stat_statements, pg_stat_monitor'`.

**Per-database gotcha:** After preloading, PGSM collects stats for *all* databases immediately, but the *view* is only accessible in databases where you ran `CREATE EXTENSION`. A newly created database's stats are visible only if you query them from a database that already has the extension, or after you create the extension there. Percona documents an "auto-create for new databases" recipe (a template/event-trigger approach) to automate this.

**Security:** Only superusers and members of `pg_read_all_stats` can see SQL text, `client_ip`, and `queryid` of other users' queries; ordinary users see their own plus aggregate stats.

#### 1.7 GUCs that must be set at load time vs runtime

Configuration parameter *context* (from `pg_settings`) determines whether a restart is required:

- **`postmaster` context (restart required):** `pgsm_max`, `pgsm_query_max_len`, `pgsm_max_buckets`, `pgsm_bucket_time`, `pgsm_histogram_min`, `pgsm_histogram_max`, `pgsm_histogram_buckets`, `pgsm_query_shared_buffer`, `pgsm_enable_overflow`. These allocate or partition shared memory at startup.
- **`userset` context (reload / SET, no restart):** `pgsm_track`, `pgsm_track_utility`, `pgsm_track_application_names`, `pgsm_normalized_query`, `pgsm_enable_query_plan`, `pgsm_extract_comments`, `pgsm_enable_pgsm_query_id`, `pgsm_track_planning`.

Since v2.0.0 the old `pg_stat_monitor_settings` view is removed; inspect configuration via:

```sql
SELECT name, setting, unit, context, vartype, boot_val, reset_val, pending_restart
FROM pg_settings WHERE name LIKE 'pg_stat_monitor.%';
```

### 2. Configuration parameters (full enumeration)

| GUC | Default | Range | Context | Purpose / tuning tradeoff |
|---|---|---|---|---|
| `pgsm_max` | 256 (MB) | 10–10240 | postmaster (restart) | Total shared memory for statement metadata; divided equally among buckets. Too low → "hash table is out of memory" and dropped queries. |
| `pgsm_query_max_len` | 2048 (bytes) | 1024–2147483647 | postmaster (restart) | Max stored query text length; longer queries truncated (multibyte-safe since 2.3.2). Raising it increases memory per entry. |
| `pgsm_max_buckets` | 10 | 1–20000 | postmaster (restart) | Number of buckets in the chain. More buckets = longer retention but more memory subdivision. |
| `pgsm_bucket_time` | 60 (s) | 1–2147483647 | postmaster (restart) | Lifetime of each bucket. Retention window ≈ `pgsm_max_buckets × pgsm_bucket_time`. |
| `pgsm_histogram_min` | 1 (ms) | 0–50000000 | postmaster (restart) | Lower bound of histogram range (decimal allowed ≥2.0.0). |
| `pgsm_histogram_max` | 10000 (ms) | 10–50000000 | postmaster (restart) | Upper bound of histogram range. |
| `pgsm_histogram_buckets` | 20 | 2–50 | postmaster (restart) | Number of histogram buckets (max 50 since 1.1.0). ≥2.0.0 adds two extra outlier buckets (below min, above max). |
| `pgsm_query_shared_buffer` | 20 (MB) | 1–10000 | postmaster (restart) | Shared memory reserved for query text, used circularly. |
| `pgsm_track_utility` | on | boolean | userset | Track non-DML (CREATE/ALTER/VACUUM, stored procedures). |
| `pgsm_track_application_names` | on | boolean | userset | Include application_name in the key. **Resource-intensive with many connections** — Percona recommends disabling it to consolidate stats and improve performance. |
| `pgsm_enable_pgsm_query_id` | on | boolean | userset | Compute version/DB/user-independent query hash (`pgsm_query_id`). Adds load. |
| `pgsm_normalized_query` | off | boolean | userset | off = store actual parameter values (default since 1.1.0); on = placeholders. Actual values ease EXPLAIN but can expose sensitive data. |
| `pgsm_enable_overflow` | on | boolean | postmaster (restart) | Allow spill beyond shared memory into swap/disk. Replaces deprecated `pgsm_overflow_target`. |
| `pgsm_enable_query_plan` | off | boolean | userset | Capture actual plans. **Off by default**; creates one row per distinct plan and can distort timing — keep off for routine monitoring. |
| `pgsm_extract_comments` | off | boolean | userset | Parse `/* ... */` (SQLcommenter) comments into the `comments` column. |
| `pgsm_track` | top | top/all/none | userset | `top`=top-level only; `all`=include nested (may duplicate); `none`=collect nothing (still loaded). |
| `pgsm_track_planning` | off | boolean | userset | Track planning-time stats. **PG14+ only.** |

Deprecated: `pgsm_overflow_target` (use `pgsm_enable_overflow`); `pgsm_enable` (older on/off master switch); `pgsm_respose_time_step` (1.x histogram step).

Change example (reload-only GUC):
```sql
ALTER SYSTEM SET pg_stat_monitor.pgsm_bucket_time = 30;
SELECT pg_reload_conf();
```

### 3. Core concepts that differentiate PGSM from pg_stat_statements

- **Time-based bucketing.** Rather than one ever-increasing counter set, PGSM writes into a chain of buckets, each active for `pgsm_bucket_time`. When a bucket's lifetime expires, PGSM advances to the next and resets its counters; when the chain wraps, old contents are overwritten. This makes min/max/mean meaningful over short windows and lets you see, e.g., a query that spiked between 11:00–15:00. The `bucket`, `bucket_start_time`, and `bucket_done` columns expose this; `bucket_done=true` means the bucket is finalized and safe to read.
- **Query examples with min/max/mean/stddev.** `total_exec_time`, `min_exec_time`, `max_exec_time`, `mean_exec_time`, `stddev_exec_time` (and the parallel `*_plan_time` set).
- **Latency histogram.** `resp_calls` array plus the `histogram(bucket, queryid)` function render an ASCII distribution — the key to finding bimodal/long-tail latency and P99 behavior.
- **Actual plan capture.** `query_plan` (+ `planid`) when `pgsm_enable_query_plan` is on. The plan omits per-node costs/widths by design because rows aggregate across executions.
- **Multi-dimensional identity.** `client_ip`, `application_name`, `username`/`user`, `datname`, `dbid`, `userid` — enabling per-app/per-tenant drill-down.
- **SQLcommenter comments.** `comments` column ties queries back to ORM/application source via Google SQLcommenter key-value tags.
- **Error/message tracking.** `elevel`, `sqlcode`, `message` capture ERROR/WARNING/LOG-terminated statements — decode with `decode_error_level(elevel)`.
- **Top/parent-child.** `top_queryid`/`top_query` link nested statements (e.g. a query executed inside a function) back to the calling statement.
- **Command classification.** `cmd_type` (1=SELECT, 2=UPDATE, 3=INSERT, 4=DELETE) and `cmd_type_text`.
- **Relations.** `relations` array lists tables (and views, flagged with `*`) touched by the statement.
- **Wait events: NOT captured.** There is no `wait_event` column in any PGSM version. Percona flagged accurate wait-event attribution as an unimplemented goal from the very first tech-preview; it remains absent. Use `pg_stat_activity.wait_event_type`/`wait_event` sampling for wait analysis.

### 4. Use-case-driven workflows

> Column names below target PG16/17/18. On PG15 use `user` instead of `username`; on PG16 and earlier use `blk_read_time`/`blk_write_time` instead of `shared_blk_read_time`/`shared_blk_write_time`. Aggregate across buckets with `SUM()`/`GROUP BY` because each row is per-bucket.

**4.1 Slowest queries by total and mean time**
```sql
-- Biggest total consumers (aggregate across buckets)
SELECT queryid, SUM(calls) AS calls,
       ROUND(SUM(total_exec_time)::numeric,2) AS total_ms,
       ROUND(SUM(total_exec_time)::numeric / NULLIF(SUM(calls),0),3) AS mean_ms,
       LEFT(query,80) AS query
FROM pg_stat_monitor
GROUP BY queryid, query
ORDER BY total_ms DESC
LIMIT 20;

-- Slowest on average (catches rare-but-painful queries)
SELECT queryid, calls, ROUND(mean_exec_time::numeric,3) AS mean_ms,
       ROUND(max_exec_time::numeric,3) AS max_ms, LEFT(query,80) AS query
FROM pg_stat_monitor
ORDER BY mean_exec_time DESC
LIMIT 20;
```
Total time finds systemic load; mean/max finds individually slow operations that a total-time ranking buries.

**4.2 Unstable/unpredictable queries (high variance)**
```sql
SELECT queryid, calls,
       ROUND(mean_exec_time::numeric,2) AS mean_ms,
       ROUND(stddev_exec_time::numeric,2) AS stddev_ms,
       ROUND(min_exec_time::numeric,2) AS min_ms,
       ROUND(max_exec_time::numeric,2) AS max_ms,
       LEFT(query,60) AS query
FROM pg_stat_monitor
WHERE calls > 50
ORDER BY stddev_exec_time DESC
LIMIT 20;
```
A `stddev_exec_time` near or above `mean_exec_time`, or `max_exec_time` orders of magnitude above `mean_exec_time`, signals plan instability, cache-state dependence, or lock contention. Confirm with the histogram (4.10).

**4.3 High I/O queries (block reads/writes, dirtied, temp)**
```sql
SELECT queryid, SUM(calls) AS calls,
       SUM(shared_blks_read)  AS shared_read,
       SUM(shared_blks_written) AS shared_written,
       SUM(shared_blks_dirtied) AS dirtied,
       SUM(temp_blks_read + temp_blks_written) AS temp_blocks,
       LEFT(query,60) AS query
FROM pg_stat_monitor
GROUP BY queryid, query
ORDER BY shared_read DESC
LIMIT 20;
```
High `shared_blks_read` = cache misses hitting disk; high `shared_blks_dirtied`/`written` = write amplification (checkpointer/bgwriter pressure).

**4.4 Temp-file usage (work_mem tuning candidates)**
```sql
SELECT queryid, SUM(calls) AS calls,
       SUM(temp_blks_written) AS temp_blks_written,
       SUM(temp_blks_read)    AS temp_blks_read,
       ROUND(SUM(temp_blks_written) * 8 / 1024.0, 1) AS temp_mb_written,
       LEFT(query,70) AS query
FROM pg_stat_monitor
GROUP BY queryid, query
HAVING SUM(temp_blks_written) > 0
ORDER BY temp_blks_written DESC
LIMIT 20;
```
Nonzero temp blocks = sorts/hashes spilling to disk. These are prime candidates for a higher session `work_mem` (or `hash_mem_multiplier` on PG13+) or better indexing. Confirm with `EXPLAIN (ANALYZE, BUFFERS)` looking for "external merge Disk" or hash "Batches > 1".

**4.5 Problematic workloads by time bucket (time-of-day spikes)**
```sql
SELECT bucket, bucket_start_time,
       SUM(calls) AS calls,
       ROUND(SUM(total_exec_time)::numeric,1) AS total_ms
FROM pg_stat_monitor
GROUP BY bucket, bucket_start_time
ORDER BY bucket_start_time;

-- One query's behavior over buckets
SELECT bucket_start_time, calls, ROUND(mean_exec_time::numeric,2) AS mean_ms
FROM pg_stat_monitor
WHERE queryid = :queryid
ORDER BY bucket_start_time;
```
This is the feature pg_stat_statements cannot replicate: you see *when* load or latency changed, not just cumulative totals. Remember bucket retention is finite — for multi-day trends use PMM/QAN or snapshot buckets.

**4.6 Wait analysis (proxy only)**
PGSM has no wait_event column. Use its I/O timing as a proxy for the biggest wait class (I/O), then confirm root cause live in `pg_stat_activity`:
```sql
-- PGSM I/O-wait proxy (PG17/18 column names)
SELECT queryid,
       ROUND(SUM(shared_blk_read_time)::numeric,1)  AS read_wait_ms,
       ROUND(SUM(shared_blk_write_time)::numeric,1) AS write_wait_ms,
       LEFT(query,60) AS query
FROM pg_stat_monitor
GROUP BY queryid, query
ORDER BY read_wait_ms DESC
LIMIT 20;   -- requires track_io_timing = on
```
```sql
-- True wait events (sample repeatedly; PG17+ can join pg_wait_events for descriptions)
SELECT wait_event_type, wait_event, COUNT(*) AS sessions
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
GROUP BY wait_event_type, wait_event
ORDER BY sessions DESC;
```

**4.7 Queries by client IP / application / user (multi-tenant, noisy neighbor)**
```sql
SELECT client_ip, application_name, username,
       SUM(calls) AS calls,
       ROUND(SUM(total_exec_time)::numeric,1) AS total_ms
FROM pg_stat_monitor
GROUP BY client_ip, application_name, username
ORDER BY total_ms DESC
LIMIT 20;
```
Because client_ip and application_name are part of the aggregation key, you can attribute load to a specific tenant/host — a capability Percona highlights as one of PGSM's most valuable in real support work.

**4.8 Capturing actual plans for slow queries**
```sql
ALTER SYSTEM SET pg_stat_monitor.pgsm_enable_query_plan = on;  -- enable deliberately
SELECT pg_reload_conf();

SELECT queryid, planid, ROUND(mean_exec_time::numeric,2) AS mean_ms,
       LEFT(query,50) AS query, query_plan
FROM pg_stat_monitor
WHERE query_plan IS NOT NULL
ORDER BY mean_exec_time DESC
LIMIT 10;
```
Multiple `planid` values for one `queryid` reveal plan changes over time. Disable again when done — plan capture multiplies rows and can distort timing aggregation.

**4.9 Queries generating errors/warnings**
```sql
SELECT LEFT(query,50) AS query,
       decode_error_level(elevel) AS level,
       sqlcode, SUM(calls) AS calls,
       LEFT(message,60) AS message
FROM pg_stat_monitor
WHERE elevel <> 0
GROUP BY query, elevel, sqlcode, message
ORDER BY calls DESC;
```
Lets you measure failed vs successful executions separately and see, e.g., recurring `division by zero` (sqlcode) or lock timeouts.

**4.10 Latency distribution with the histogram**
```sql
-- Find queries whose resp_calls array shows a spread
SELECT bucket, queryid, resp_calls, LEFT(query,40) AS query
FROM pg_stat_monitor
WHERE queryid = :queryid;

-- Render the ASCII histogram for a (bucket, queryid)
SELECT * FROM histogram(:bucket, ':queryid')
  AS t(range TEXT, freq INT, bar TEXT);
```
A single tall bar = predictable latency; two clusters = bimodal (e.g., cache hit vs miss, or fast path vs lock wait); a long right tail = P99 problem. This is Percona's recommended tool for P99/outlier hunting.

**4.11 Cache hit ratio per query**
```sql
SELECT queryid, LEFT(query,60) AS query,
       SUM(shared_blks_hit)  AS hits,
       SUM(shared_blks_read) AS reads,
       ROUND(100.0 * SUM(shared_blks_hit)
             / NULLIF(SUM(shared_blks_hit) + SUM(shared_blks_read),0), 2) AS hit_pct
FROM pg_stat_monitor
GROUP BY queryid, query
HAVING SUM(shared_blks_hit) + SUM(shared_blks_read) > 0
ORDER BY reads DESC
LIMIT 20;
```
A low per-query hit ratio on a high-call query is a candidate for indexing or `shared_buffers`/working-set review.

**4.12 Most frequent vs most expensive**
```sql
SELECT queryid, SUM(calls) AS calls, LEFT(query,60) AS query
FROM pg_stat_monitor GROUP BY queryid, query
ORDER BY calls DESC LIMIT 15;
```
Compare against 4.1: the most-called query is often cheap per call but dominates load; the most-expensive-per-call may be rare. Both deserve attention for different reasons.

**4.13 WAL generation per query**
```sql
SELECT queryid, LEFT(query,60) AS query,
       SUM(wal_records) AS wal_records,
       SUM(wal_fpi)     AS wal_fpi,
       pg_size_pretty(SUM(wal_bytes)::numeric) AS wal_size
FROM pg_stat_monitor
GROUP BY queryid, query
ORDER BY SUM(wal_bytes) DESC
LIMIT 20;
```
High `wal_fpi` (full-page images) points to writes right after checkpoints — consider checkpoint tuning. On PG18, `wal_buffers_full` shows WAL buffer pressure.

**4.14 Correlate with application code via comments**
```sql
ALTER SYSTEM SET pg_stat_monitor.pgsm_extract_comments = on;
SELECT pg_reload_conf();

-- Using hstore to parse SQLcommenter tags
CREATE EXTENSION IF NOT EXISTS hstore;
SELECT LEFT(query,50) AS query,
       (hstore(comments::text[]))->'application' AS app,
       (hstore(comments::text[]))->'controller' AS controller
FROM pg_stat_monitor
WHERE comments IS NOT NULL;
```
Ties a slow SQL statement back to the ORM/route/controller that issued it. Only the latest comment value is preserved per row.

**4.15 Planning time vs execution time**
```sql
ALTER SYSTEM SET pg_stat_monitor.pgsm_track_planning = on;  -- PG14+
SELECT pg_reload_conf();

SELECT queryid, LEFT(query,50) AS query,
       ROUND(SUM(total_plan_time)::numeric,2) AS plan_ms,
       ROUND(SUM(total_exec_time)::numeric,2) AS exec_ms
FROM pg_stat_monitor
GROUP BY queryid, query
ORDER BY plan_ms DESC
LIMIT 20;
```
Planning time approaching execution time flags candidates for prepared statements or generic-plan tuning.

### 5. View column reference (grouped; PG14–18 differences called out)

**Identity / dimensions:** `bucket`, `bucket_start_time`, `bucket_done`, `userid`, `username` (PG14 & PG16/17/18) / `user` (PG15), `dbid`, `datname`, `client_ip`, `application_name`, `pgsm_query_id`, `queryid`, `toplevel`, `top_queryid`, `top_query`, `query`, `comments`, `planid`, `query_plan`, `relations`, `cmd_type`, `cmd_type_text`, `elevel`, `sqlcode`, `message`.

**Execution timing:** `calls`, `total_exec_time`, `min_exec_time`, `max_exec_time`, `mean_exec_time`, `stddev_exec_time`. **Planning timing (PG14+):** `plans`, `total_plan_time`, `min_plan_time`, `max_plan_time`, `mean_plan_time`, `stddev_plan_time`. **CPU:** `cpu_user_time`, `cpu_sys_time`.

**Rows:** `rows`.

**Blocks / I/O:** `shared_blks_hit`, `shared_blks_read`, `shared_blks_dirtied`, `shared_blks_written`, `local_blks_hit/read/dirtied/written`, `temp_blks_read`, `temp_blks_written`. **I/O timing:** PG16 and earlier use `blk_read_time`/`blk_write_time`; **PG17/18 rename to `shared_blk_read_time`/`shared_blk_write_time`** and add `local_blk_read_time`/`local_blk_write_time`. `temp_blk_read_time`/`temp_blk_write_time` exist PG15+ (not PG13/14).

**WAL:** `wal_records`, `wal_fpi`, `wal_bytes`; **`wal_buffers_full` (PG18 / PGSM 2.3.1+ only)**.

**Histogram:** `resp_calls` (array).

**JIT (PG15+):** `jit_functions`, `jit_generation_time`, `jit_inlining_count/time`, `jit_optimization_count/time`, `jit_emission_count/time`; `jit_deform_count/time` (PG17/18).

**Parallelism (PG18 / PGSM 2.3.1+):** `parallel_workers_to_launch`, `parallel_workers_launched`.

**Stats lifetime (PG17/18):** `stats_since`, `minmax_stats_since` (PGSM has no min/max reset, so `minmax_stats_since` always equals `stats_since`).

Key cross-version renames to note for compatibility: `username`↔`user` (PG15), `blk_read_time`↔`shared_blk_read_time` (PG17), and the PG18-only WAL/parallel columns.

### 6. Operational / support-engineer practices

**Reset statistics:**
```sql
SELECT pg_stat_monitor_reset();   -- superuser by default; GRANT to delegate
```
Other functions: `pg_stat_monitor_version()`, `histogram(bucket,queryid)`, `range()`, `decode_error_level()`, `get_histogram_timings()`, `get_cmd_type()`. Internal `pgsm_create_*_view` functions are not for direct use.

**Bucket rotation & visibility.** Retention ≈ `pgsm_max_buckets × pgsm_bucket_time` (defaults: 10 × 60s = 10 minutes). When the chain wraps, the oldest bucket is overwritten — *read a bucket before it is reused or the data is lost*. Query `bucket_done = true` for finalized buckets. For long-term retention, feed PGSM into PMM/QAN or snapshot into a time-series store.

**Memory sizing.** `pgsm_max` (default 256MB) holds statement metadata split across buckets; `pgsm_query_shared_buffer` (default 20MB) holds query text. If you see the server log error "Hash table is out of memory and can no longer store queries!" the guidance is to reset the view or raise `pgsm_max`. With many distinct queries or many buckets, raise `pgsm_max`; with long query texts, raise `pgsm_query_shared_buffer` and/or `pgsm_query_max_len`. `pgsm_enable_overflow=on` lets PGSM spill instead of dropping, at a performance cost.

**Overhead & how to minimize it.** Percona's stated position is that PGSM achieves its extra features "while having performance overhead comparable to the original pg_stat_statements extension" (from the tech-preview announcement blog). The 2.0 rearchitecture, per the 2.0.0 release notes, "leads to fewer lock acquisitions, and therefore an improved performance by approximately 20% when tested using pgbench" (PMM docs phrase the same figure as "fewer lock acquisitions and increases performance by approximately 20%"). To minimize overhead: disable `pgsm_track_application_names` (costly at high connection counts), keep `pgsm_enable_query_plan` off, keep `pgsm_track=top` unless you need nested queries, and leave `pgsm_enable_pgsm_query_id` off if you don't need cross-cluster query correlation. Treat these as vendor claims and validate on your own workload.

**Common pitfalls.**
- *Data "disappearing"* — almost always bucket rotation, not a bug. Widen buckets or snapshot.
- *Normalized vs actual query text* — default (`pgsm_normalized_query=off`) stores actual parameter values, which can expose PII; turn on normalization (or PMM's "disable query examples") for sensitive environments.
- *Coexistence with pg_stat_statements* — both can run, but block/WAL stats display inconsistently between the two, and only the last-preloaded one captures utility statements.
- *Missing view in a database* — you must `CREATE EXTENSION` per database.
- *Plan capture distorting timing* — one row per plan; enable only for targeted investigation.

**Integration with PMM (Query Analytics / QAN).** PMM has consumed PGSM 2.0 in QAN since PMM 2.36 (per PMM 2.36.0 release notes: "PMM 2.36 now supports pg_stat_monitor 2.0 (PGSM 2.0) in QAN… PMM 2.36 and PGSM 2.0 now support PG 13, 14, and 15"). Add the service:
```bash
pmm-admin add postgresql --username=pmm --password=pass \
  --query-source=pgstatmonitor
# add --disable-queryexamples to avoid storing actual parameter values (PII)
```
This runs the `qan-postgresql-pgstatmonitor-agent`, which scrapes the PGSM view each minute and persists it in PMM Server — solving bucket-rotation data loss and giving historical trend/"Load" graphs, per-query histograms, and (for PGSM) the `top_query` in the QAN details. PMM recommends a monitoring role with `pg_monitor`/superuser and explicitly recommends keeping `pgsm_enable_query_plan` off for QAN because plan capture creates multiple records per query and skews timing.

**PGSM vs pg_stat_statements — feature comparison**

| Capability | pg_stat_statements | pg_stat_monitor |
|---|---|---|
| Aggregation model | Single ever-increasing counters | Rotating time buckets |
| Grouping key | userid, dbid, queryid, toplevel | + client_ip, application_name, planid, bucket |
| min/max/mean/stddev exec & plan time | ✅ | ✅ |
| Latency histogram | ❌ | ✅ (`resp_calls` + `histogram()`) |
| Actual query examples (literals) | ❌ (normalized only) | ✅ (`pgsm_normalized_query=off`) |
| Query plan capture | ❌ | ✅ (`pgsm_enable_query_plan`) |
| client_ip / application_name / username dims | ❌ | ✅ |
| SQLcommenter comment extraction | ❌ | ✅ (`comments`) |
| Error/warning tracking (elevel/sqlcode/message) | ❌ | ✅ |
| Relations touched | ❌ | ✅ (`relations`) |
| top/parent-child (function) tracking | partial (toplevel) | ✅ (`top_queryid`/`top_query`) |
| CPU user/sys time | ❌ | ✅ |
| Wait events | ❌ | ❌ |
| WAL stats | ✅ | ✅ |
| Part of core/contrib | ✅ (contrib) | ❌ (Percona/PGDG package) |

## Recommendations

**Stage 1 — Baseline install (any of PG14–18).** Install `percona-pg-stat-monitorNN` from Percona repos, set `shared_preload_libraries = 'pg_stat_statements, pg_stat_monitor'`, enable `track_io_timing = on` (so I/O-timing columns populate), restart, and `CREATE EXTENSION pg_stat_monitor` in each monitored database. Keep defaults except **disable `pgsm_track_application_names`** on high-connection systems. Benchmark threshold: if TPS drop from monitoring exceeds ~3–5% vs a no-extension baseline, prune tracking (`pgsm_track=top`, disable pgsm_query_id).

**Stage 2 — Right-size retention and memory.** Decide your analysis window. For ad-hoc live triage, defaults (10 min) are fine. For "time-of-day" pattern hunting without PMM, widen to e.g. `pgsm_max_buckets=24`, `pgsm_bucket_time=3600` (24h) and raise `pgsm_max` accordingly. Threshold to act: any "hash table is out of memory" log line → raise `pgsm_max` (and/or `pgsm_query_shared_buffer` for long queries) and restart.

**Stage 3 — Investigation workflow.** Triage in this order: (1) total-time ranking (4.1) for systemic load; (2) stddev + histogram (4.2, 4.10) for instability; (3) I/O and cache-hit (4.3, 4.11) and temp files (4.4) for resource root cause; (4) client_ip/app (4.7) for attribution. Only then, for the top offenders, temporarily enable `pgsm_enable_query_plan` (4.8) to capture plans, and disable it afterward.

**Stage 4 — Productionize.** For anything beyond short-window triage, connect the instance to **PMM with `--query-source=pgstatmonitor`** (add `--disable-queryexamples` if data is sensitive) so bucketed data is persisted and trendable. Use `pg_stat_activity` sampling (or a sampler) alongside PGSM to cover the wait-event gap.

**Threshold cheatsheet that should change your action:**
- `stddev_exec_time ≳ mean_exec_time` or `max ≫ mean` → investigate plan instability/locks (not just slow SQL).
- Per-query cache hit % < ~95–99% on a high-call query → index/working-set problem.
- Nonzero `temp_blks_written` → raise session `work_mem`/`hash_mem_multiplier` or add indexes.
- High `wal_fpi` → checkpoint tuning; high PG18 `wal_buffers_full` → raise `wal_buffers`.

## Caveats

- **No wait events.** PGSM cannot attribute PostgreSQL wait events to queries; this was an explicit unimplemented goal from the tech-preview era and remains absent in 2.x. Any "wait analysis" via PGSM is an I/O-timing proxy only — use `pg_stat_activity`/`pg_wait_events` (PG17+) for real wait data.
- **The ~20% performance improvement and "overhead comparable to pg_stat_statements" claims are Percona's own** (2.0.0 release notes / PMM docs / the launch blog), not independent third-party benchmarks; the "comparable overhead" line dates to the tech-preview announcement. Validate overhead on your own workload.
- **Bucket rotation silently overwrites data.** Without PMM or external snapshotting, PGSM is a short-window tool by default; do not treat it as a long-term historical store.
- **Column names and availability shift by both PGSM version and PG major** (`user`/`username`, `blk_read_time`/`shared_blk_read_time`, PG18-only WAL/parallel columns, JIT columns PG15+). Always confirm with `\d pg_stat_monitor` on the actual target before scripting queries.
- **2.3.0 was never released** — the 13→18 support line current as of mid-2026 is 2.3.1/2.3.2. Verify the installed version with `SELECT pg_stat_monitor_version();`. Note a minor date discrepancy in Percona's own materials for 2.3.1: the release-notes page is titled 2025-11-27 while the "has been released" news post says November 28, 2025.
- **Some Percona RPMs in late-2025 quarterly builds shipped with `--enable-cassert` (debug assertions) enabled**, causing performance degradation. Per the Percona Distribution for PostgreSQL 18.1.1 (2025-11-28) release notes, the affected PSP/PPG RPMs span PostgreSQL 13–18 (specifically 18.1, 17.6, 17.7, 16.10, 16.11, 15.14, 15.15, 14.19, 14.20, 13.22, 13.23). Verify with `pg_config --configure` (look for `--enable-cassert`) and update to fixed packages if affected.
- **Coexistence inconsistency:** when both PGSS and PGSM are loaded, block-memory and WAL statistics are reported inconsistently between the two views; pick one as your source of truth for those metrics.