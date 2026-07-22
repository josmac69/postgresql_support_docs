# pg_tune_audit.sh — Cheat Sheet

**Purpose:** Read-only tuning audit that discovers host resources (RAM, CPU, SSD/HDD) and compares the live PostgreSQL configuration — from a running instance or a `postgresql.conf` file — against workload heuristics, flagging each parameter OK/WARN/FIX and printing an `ALTER SYSTEM` action plan.

**Usage:**
```bash
./pg_tune_audit.sh
./pg_tune_audit.sh --profile oltp --connections 200
./pg_tune_audit.sh --conf /etc/postgresql/17/main/postgresql.conf
```
Supported flags: `-p|--profile <web|oltp|dw|desktop|mixed>` (default `mixed`), `-c|--connections <num>`, `-m|--mem <GB>`, `-cpu|--cpus <num>`, `--ssd <1|0>`, `-f|--conf <path>`, `-h|--host <host>`, `--port <port>`, `-U|--user <user>`, `-d|--dbname <name>`, `--help`. (Note: `-p` binds to `--profile`; the port flag is `--port` only.)
- **Privileges:** No sudo needed — runs as a normal user reading world-readable `/proc` and `/sys/block`, and connecting to PostgreSQL as a DB user (default `postgres`, with an automatic peer/Unix-socket login when run as the `postgres` OS user). Root/sudo is only referenced in the *printed* sysctl huge-pages suggestions, never invoked by the script.
- **Read-only:** Yes — queries `pg_settings`, `pg_extension`, `pg_database`, and replication views, or parses a `.conf` file; it only emits recommended `ALTER SYSTEM` / `sysctl` commands and never executes, installs, benchmarks, or modifies anything.

## What it tests
- **Host resources** — total RAM (`/proc/meminfo`), logical CPU count, and whether the data directory sits on SSD/NVMe vs rotational disk.
- **DB metadata** — server version, installed extensions, total database size vs RAM, primary/standby role.
- **Replication health** — standby replay lag, active replicas and their state/sync, replication slots (inactive or `lost`).
- **Memory parameters** — `shared_buffers`, `effective_cache_size`, `maintenance_work_mem`, `work_mem`, `wal_buffers`.
- **WAL & checkpoints** — `min_wal_size`, `max_wal_size`, `checkpoint_completion_target`.
- **Planner & I/O costs** — `random_page_cost`, `effective_io_concurrency`.
- **Parallelism** — `max_worker_processes`, `max_parallel_workers`, `max_parallel_workers_per_gather`, `max_parallel_maintenance_workers`.
- **OS integration** — `huge_pages` (cross-checked against Linux `nr_hugepages`), `jit`, `track_io_timing`, `data_sync_retry`, `autovacuum_max_workers`.

## How it tests
- Reads RAM from `/proc/meminfo` (`MemTotal`), CPUs from `nproc`/`getconf`, and huge-page state from `/proc/sys/vm/nr_hugepages` and `Hugepagesize` — each overridable via `-m`, `-cpu`, `--ssd`.
- Detects storage type in `get_path_rotational()`: resolves the data dir's device via `df`/`realpath`, reads `/sys/block/<dev>/queue/rotational`, and walks dm-mapper `slaves` plus `nvme`/`mmcblk`/`sdX` partition parents.
- Gets current config one of two ways: parses a file with an `awk` `key = value` extractor (`-f`), or auto-detects a live instance by probing ports 5432–5435 with `pg_isready` and reading `pg_settings` via `psql` (unit-normalized to MB/GB).
- Resolves the data directory from `data_directory`, else from `-D`/`--data-directory` on the running `postgres` process (`pgrep`/`ps` + `/proc/<pid>/cmdline`), else `/var/lib/postgresql` or `/`.
- Pulls metadata with `SELECT version()`, `pg_extension`, `pg_database_size`, `pg_is_in_recovery()`, `pg_last_wal_receive/replay_lsn()`, `pg_last_xact_replay_timestamp()`, `pg_stat_replication`, and `pg_replication_slots`.
- Compares via helpers: `compare_mem` (OK within 0.8×–1.2× of target, FIX if ≤0.5×, WARN if ≥1.8×), `compare_num` (OK if equal, FIX if < rec/2, else WARN), `compare_flag` (OK if equal else FIX), and `compare_huge_pages` (validates Linux `nr_hugepages` covers `shared_buffers`); floats use `awk` `ge`/`le` and `bc`.
- Collects flagged items into a `WARN_FLAGS` array, prints a triage summary + legend, then an `ALTER SYSTEM` action plan split into online (reloadable) vs offline (restart-required) blocks, with conditional `sysctl vm.nr_hugepages` guidance.

## Recommendations
- **shared_buffers off ~25% RAM** (12.5% for `desktop`) → set to ~25% of RAM. *Rationale:* keeps the working set cached in RAM, preventing disk reads.
- **effective_cache_size too low** → set to ~75% RAM (25% for `desktop`). *Rationale:* tells the planner how much OS cache exists so it favors index over sequential scans.
- **work_mem too low/high** → use the connection-scaled value (free RAM ÷ connections × profile factor, clamped 4–2048 MB). *Rationale:* keeps sorts/joins in memory without spilling to temp files or risking OOM.
- **maintenance_work_mem too low** → raise toward RAM/8 (dw, cap 4 GB) or ~6.25% RAM (cap 2 GB). *Rationale:* speeds up VACUUM, CREATE INDEX, and ALTER.
- **random_page_cost 4.0 on SSD** → set 1.1 (keep 4.0 on HDD). *Rationale:* random access on SSD is nearly as cheap as sequential, so the planner should stop under-costing index scans.
- **effective_io_concurrency mismatched** → 200 on SSD, 2 on HDD. *Rationale:* matches prefetch depth to the storage's real queue capability.
- **checkpoint_completion_target ≠ 0.9** → set 0.9. *Rationale:* spreads dirty-page writes across the checkpoint window, avoiding I/O spikes.
- **huge_pages disabled/misaligned on >16 GB hosts** → set `on` and allocate the required Linux `nr_hugepages` via sysctl. *Rationale:* shrinks kernel page tables and TLB-miss overhead — and if PG is `on` while `nr_hugepages` is insufficient the server fails to start.
- **data_sync_retry = on** → set `off`. *Rationale:* prevents silent data corruption after an fsync failure on Linux.
- **jit misaligned with workload** → `off` for web/oltp/mixed/desktop, `on` for `dw`. *Rationale:* JIT compilation wastes CPU on short queries but pays off on analytical ones.
- **track_io_timing off** → set `on`. *Rationale:* required to diagnose per-block storage read/write latency.
- **Parallel/worker counts below cores** → align `max_worker_processes` / `max_parallel_workers` to CPU count (per-gather and maintenance scaled by profile). *Rationale:* lets parallel query and index builds use available cores.
- **autovacuum_max_workers low** → 5 on >8-core hosts, else 3. *Rationale:* enough concurrent autovacuum to keep bloat in check.
- **Inactive or lost replication slot** → drop or reactivate it. *Rationale:* inactive slots retain WAL and can exhaust disk; `lost` means WAL is already recycled and the consumer cannot resume.
- **High standby replay lag (>60 s)** → investigate network or resource saturation. *Rationale:* large lag risks stale reads and data loss on failover.
