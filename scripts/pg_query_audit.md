# pg_query_audit.sh — Cheat Sheet

**Purpose:** Zero-dependency, read-only audit of query performance and index health on a live PostgreSQL instance — surfaces slow queries, missing/unused/duplicate/invalid indexes, PK-less tables, stale planner stats, and cache hit ratios.

**Usage:**
```bash
./pg_query_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] [--min-size <MB>] [--min-scans <n>] [--top <n>]
./pg_query_audit.sh --help
```
Options (defaults respect `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`): `-h/--host` (localhost), `-p/--port` (auto-probes 5432-5435 if unset), `-U/--user` (postgres), `-d/--dbname` (postgres), `--min-size` MB seq-scan floor (10), `--min-scans` seq_scan count floor (1000), `--top` rows per listing (10). Note `-h` means host, not help; use `--help`.
- **Privileges:** No OS `sudo` needed. Requires DB access with rights to read stats/catalog views (superuser or `pg_monitor`); when invoked as the `postgres` OS user a wrapper strips `-h` to use peer/local auth.
- **Read-only:** Yes — issues only `SELECT`/`SHOW` queries plus `pg_isready` probes; never installs, alters, or drops anything. All remediation SQL is printed as advice, not executed.

## What it tests
- **Top resource queries** — busiest statements by total exec time, mean exec time (min 5 calls), and shared block reads, via `pg_stat_statements`.
- **pg_stat_statements availability** — whether the extension is installed and/or preloaded in `shared_preload_libraries`.
- **Sequential scans** — large tables (> `--min-size` MB, > `--min-scans` scans, seq > idx) that likely need indexes.
- **Unused indexes** — non-PK/non-unique indexes > 1MB with zero scans since last stats reset.
- **Duplicate indexes** — index groups with identical column/expression/predicate definitions.
- **Invalid indexes** — indexes with `indisvalid = false` from failed `CONCURRENTLY` builds.
- **Missing primary keys** — user tables (`relkind = 'r'`) with no `p`-type constraint.
- **Stale planner stats** — tables never analyzed (>1000 live rows) or analyzed > 7 days ago with mods > 10% of live rows.
- **Cache hit ratios** — heap and index buffer hit percentages.

## How it tests
- Connects with `psql`; if no `-p` given, probes ports 5432-5435 with `pg_isready` then confirms each candidate with `SELECT 1;` (`-At`).
- Reads `SHOW server_version_num` to pick column names (`total_exec_time`/`mean_exec_time` on PG13+, else `total_time`/`mean_time`).
- Availability: counts `pg_extension WHERE extname='pg_stat_statements'` and checks `pg_settings` for the library in `shared_preload_libraries`.
- Top queries: three ordered `pg_stat_statements` listings (self-queries filtered via `NOT ILIKE '%pg_stat_statements%'`).
- Seq scans: `pg_stat_user_tables` (`seq_scan`, `idx_scan`, `pg_total_relation_size`, `n_live_tup`).
- Unused indexes: `pg_stat_user_indexes` joined to `pg_index`, excluding `indisprimary`/`indisunique`; also prints `stats_reset` from `pg_stat_database`.
- Duplicates: groups `pg_index` by a composite key of `indrelid|indclass|indkey|indexprs|indpred`, keeping groups with `count(*) > 1`.
- Invalid: `pg_index` join `pg_class`/`pg_namespace` where `NOT indisvalid`.
- No-PK: `pg_class`/`pg_namespace` with `NOT EXISTS` a `pg_constraint` of `contype='p'`, skipping `pg_catalog`/`information_schema`.
- Stale stats: `pg_stat_user_tables` on `greatest(last_analyze, last_autoanalyze)` and `n_mod_since_analyze`.
- Cache: `pg_statio_user_tables` and `pg_statio_user_indexes` hit/read sums.
- Findings accumulate in a `REMEDS` array, printed as a numbered "Actionable Optimization Plan" at the end.

## Recommendations
- **pg_stat_statements missing but preloaded** → run `CREATE EXTENSION pg_stat_statements;` (no restart). *Rationale:* without query tracking you cannot find resource-hogging or slow queries.
- **pg_stat_statements not preloaded** → `ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';`, restart, then `CREATE EXTENSION`. *Rationale:* the library must be loaded at startup to record statistics.
- **Large seq-scanned tables** → capture the query, run `EXPLAIN (ANALYZE, BUFFERS)`, then `CREATE INDEX CONCURRENTLY`. *Rationale:* sequential scans read whole tables from disk, burning CPU and I/O.
- **Unused indexes** → `DROP INDEX CONCURRENTLY` after verifying stats-reset age and rare/periodic jobs. *Rationale:* redundant indexes add write amplification and waste disk.
- **Duplicate indexes** → keep one per group, `DROP INDEX CONCURRENTLY` the rest. *Rationale:* identical indexes double DML overhead and storage for no gain.
- **Invalid indexes** → rebuild with `REINDEX INDEX CONCURRENTLY` or remove with `DROP INDEX CONCURRENTLY`. *Rationale:* failed builds are ignored by the planner yet still maintained on every write.
- **Tables without primary keys** → add an identity column, `CREATE UNIQUE INDEX CONCURRENTLY`, then `ADD CONSTRAINT ... PRIMARY KEY USING INDEX`. *Rationale:* PKs are essential for logical replication, deduplication, and ORM/indexing use.
- **Stale planner statistics** → `ANALYZE <table>;` or `vacuumdb --analyze-only -d <db>`. *Rationale:* outdated statistics lead the planner to pick sub-optimal execution plans.
- **Low cache hit ratio (< ~99% OLTP)** → run `pg_tune_audit.sh` to size `shared_buffers` before adding indexes. *Rationale:* a persistently low ratio means the working set exceeds `shared_buffers`.
