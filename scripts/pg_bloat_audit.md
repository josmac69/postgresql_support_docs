# pg_bloat_audit.sh — Cheat Sheet

**Purpose:** Zero-dependency, read-only audit that connects to a PostgreSQL database to estimate table and B-Tree index bloat, evaluate global autovacuum settings, and print a recommended remediation plan.

**Usage:**
```bash
./pg_bloat_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>]
./pg_bloat_audit.sh -t 30 -s 10   # 30% bloat threshold, 10MB min-size filter
```
- `-h, --host` (default `localhost`/`PGHOST`), `-p, --port` (scans 5432–5435 if unset), `-U, --user` (default `postgres`/`PGUSER`), `-d, --dbname` (default `postgres`/`PGDATABASE`), `-t, --threshold` bloat % to report (default 30), `-s, --min-size` min table/index MB to report (default 10), `--help`. Env vars `PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE` are respected.
- **Privileges:** No sudo. Needs `psql` and a DB role that can connect and read catalogs/stats (`pg_stats`, `pg_stat_user_tables`, `pg_settings`) — `postgres` by default. If run as OS user `postgres` it strips `-h` to force Unix-socket peer login.
- **Read-only:** Yes — issues only `SELECT` queries and `pg_size_pretty`; it prints remediation DDL (`ALTER SYSTEM`, `REINDEX`, `VACUUM`, `ALTER TABLE`) as suggestions but never executes them, installs, or modifies anything.

## What it tests
- **Table bloat** — real physical table size vs estimated size derived from `reltuples`, column widths, and `fillfactor`.
- **B-Tree index bloat** — real index size vs estimated size derived from `reltuples` and indexed-column widths.
- **Autovacuum enabled** — whether the autovacuum daemon is `on`.
- **Autovacuum workers** — `autovacuum_max_workers` count.
- **Worker memory** — `autovacuum_work_mem` (or inherited `maintenance_work_mem`) × workers as a share of system RAM.
- **Cost limit/delay** — `autovacuum_vacuum_cost_limit`/`_cost_delay` (or inherited `vacuum_cost_*`) throttling.
- **Scale factor** — `autovacuum_vacuum_scale_factor` (and analyze scale factor) vs recommended values.
- **Custom table overrides** — per-table `reloptions` in `pg_class`.
- **Untuned large tables** — tables > 1 GB with no table-level `autovacuum_vacuum_scale_factor`.

## How it tests
- Auto-discovers a live instance with `pg_isready` scanning ports 5432–5435 (unless `-p` given), then confirms with a `psql ... SELECT 1` probe.
- Reads `/proc/meminfo` (`MemTotal`) via `awk` to size RAM (falls back to 4096 MB).
- Statistics-based bloat estimation SQL: `pg_class.reltuples`, `pg_stats.avg_width`, `fillfactor` parsed from `reloptions`, and 8192-byte page math; compares against `pg_relation_size`.
- Table detail query joins `pg_stat_user_tables` for `n_dead_tup` and `greatest(last_vacuum, last_autovacuum)`; top 15 by bloat size, filtered by `--min-size` (`MIN_SIZE_BYTES`) and `--threshold`.
- Index detail query estimates pages from indexed-column widths via `pg_index`/`pg_attribute`/`pg_stats`; top 15 filtered the same way.
- Global settings pulled from `pg_settings`; the reference section runs a `CASE`-based evaluation over all `%vacuum%`/`%freeze%` params with colorized `OK/WARN/FIX` labels.
- Dependency math in bash: worker-memory cap vs RAM %, effective cost limit ÷ workers, inherited `-1` values resolved to their parent settings.
- Custom overrides from `pg_class.reloptions`; large untuned tables from `pg_relation_size(...) > 1 GB` lacking a scale-factor reloption.

## Recommendations
- **Autovacuum disabled** → `ALTER SYSTEM SET autovacuum = 'on'`. *Rationale:* it reclaims dead tuples; leaving it off causes severe bloat and transaction-ID wraparound that forces a shutdown.
- **`autovacuum_work_mem` inherits high `maintenance_work_mem`** (worker cap > 15% of RAM) → set `autovacuum_work_mem = '512MB'`. *Rationale:* caps memory so parallel workers cannot trigger OOM crashes.
- **Low cost limit** (effective `autovacuum_vacuum_cost_limit` ≤ 200) → raise to 1000 (and keep `cost_delay = 2`). *Rationale:* prevents autovacuum from being throttled under heavy write loads.
- **High cost delay** (effective `_cost_delay` ≥ 20 ms) → set `autovacuum_vacuum_cost_delay = 2`. *Rationale:* reduces sleep between I/O cycles so sweeps finish faster.
- **High scale factor** (`autovacuum_vacuum_scale_factor` > 0.10) → lower to 0.05–0.10 globally, lower still for large tables. *Rationale:* large tables shouldn't accumulate massive dead tuples before a vacuum triggers.
- **Too few workers** (`autovacuum_max_workers` < 3, or = 3 with many tables) → increase toward 5+. *Rationale:* avoids autovacuum queue congestion on busy schemas.
- **Bloated indexes** → `REINDEX INDEX CONCURRENTLY <index>`. *Rationale:* rebuilds shrink files and restore optimal page fill without blocking reads/writes.
- **Bloated tables** → `VACUUM (ANALYZE, VERBOSE) <table>`, or `VACUUM FULL`/`pg_repack` for full rebuild. *Rationale:* reclaims wasted space; note `VACUUM FULL` takes an exclusive lock, so prefer `pg_repack` for zero-downtime.
- **Large untuned tables** (> 1 GB) → `ALTER TABLE <table> SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_vacuum_threshold = 100)`. *Rationale:* triggers autovacuum sooner on big tables to prevent bloat buildup.
