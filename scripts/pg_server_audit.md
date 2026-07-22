# pg_server_audit.sh — Cheat Sheet

**Purpose:** Comprehensive read-only OS + PostgreSQL diagnostics that flags system, kernel, and database anomalies and prints copy-paste remediation commands.

**Usage:**
```bash
sudo ./pg_server_audit.sh
# capture the report (colors auto-disable when piped):
sudo ./pg_server_audit.sh | tee pg_server_audit_$(hostname).log
```
- **Privileges:** Takes no flags/arguments. Needs root (`sudo`) for full coverage — `dmesg` OOM scan, `journalctl`, cron, and `/proc/<pid>/{limits,oom_score_adj}` are root-only; runs `psql` as the `postgres` OS user via `su`/`sudo -u postgres` (peer auth). Also works as the `postgres` user or an unprivileged user, but warns that those checks are skipped.
- **Read-only:** Yes — only reads OS state and runs `SHOW`/`SELECT` queries. It never installs, restarts, or alters anything; remediation is emitted as copy-paste commands only.

## What it tests
- **System identity** — OS family, kernel, arch, uptime, load, CPU count, AWS EC2 instance type (IMDSv2 with v1 fallback).
- **Disk & inodes** — filesystem usage (WARN ≥80%, CRIT ≥90%), inode usage (≥80%), block devices, `noatime` on data mounts.
- **Memory & swap** — total RAM, swap presence, and active swap use (WARN if >256 MB used).
- **Kernel/sysctl** — `vm.dirty_ratio`/`dirty_background_ratio`, `swappiness`, `overcommit_memory`/`overcommit_ratio`, Transparent Huge Pages, explicit HugePages.
- **I/O, limits, time** — per-device I/O scheduler, postmaster `LimitNOFILE` (WARN <4096), postmaster `oom_score_adj`, NTP sync.
- **Processes/services/logs/cron** — top memory consumers, failed systemd units, `dmesg` OOM-kill events, recent journal errors, root/postgres/`/etc/cron.d` cron entries.
- **PG install & service** — `psql` client version, postmaster/cluster count, Debian `pg_lsclusters` down clusters, service enabled at boot.
- **PG key config** — version/minor currency, `shared_buffers`, `effective_cache_size`, `work_mem`, `maintenance_work_mem`, WAL/checkpoint GUCs (`fsync`, `full_page_writes`, `data_sync_retry`, `synchronous_commit`, `max_wal_size`), `random_page_cost`, `max_connections`, autovacuum GUCs, logging GUCs, all non-default settings, pending-restart count.
- **PG security** — `pg_hba_file_rules` (non-local `trust`, `0.0.0.0/0`/`::/0`), superuser roles, `listen_addresses`.
- **Vacuum/bloat/wraparound** — top dead-tuple tables, never-analyzed tables, per-database XID age (WARN >500M, CRIT >1.5B).
- **WAL/replication/slots** — `pg_wal` size (CRIT >10 GB), replication slots and inactive ones, replica/replication lag, archiver failures.
- **Indexes & query-opt** — invalid indexes, largest unused indexes, `pg_stat_statements` presence + top offenders, `default_statistics_target`, database sizes, long/idle-in-transaction sessions.

## How it tests
- Sources `/etc/os-release` to set OS family (debian vs redhat); terminal-aware colored output; accumulates `WARN_COUNT`/`CRIT_COUNT`.
- Disk: `df -hP`, `df -P`, `df -iP` with `awk` threshold parsing; `du -xh` culprit hint; `lsblk`; `mount | grep noatime`.
- Memory: `free -h`/`free -k` and `/proc/meminfo` (`MemTotal`, `SwapTotal`, `HugePages_Total`).
- Kernel: `sysctl -n` for the `vm.*` params; reads `/sys/kernel/mm/transparent_hugepage/enabled`.
- I/O/limits/time: reads `/sys/block/*/queue/scheduler`; finds postmaster via `pgrep`, reads `/proc/<pid>/limits` and `/proc/<pid>/oom_score_adj`; `timedatectl`.
- Health: `ps aux --sort=-%mem`, `systemctl list-units --failed`, `dmesg -T | grep oom` (root), `journalctl -p err -b` (root), `crontab -l` + `/etc/cron.d`.
- Service: `psql -V`, `pgrep`/`ps -ef`, Debian `pg_lsclusters`, `systemctl list-unit-files`/`is-enabled`.
- Database: `run_psql` wrapper runs `psql -XAtq` (scalars) / `-Xq` (tables) as the `postgres` OS user via `su - postgres` (root), direct (postgres), or `sudo -n -u postgres`. Queries `pg_settings`, `pg_hba_file_rules`, `pg_roles`, `pg_stat_user_tables`, `pg_database` (`age(datfrozenxid)`), `pg_ls_waldir()`, `pg_replication_slots`, `pg_stat_replication`, `pg_stat_archiver`, `pg_index`, `pg_stat_user_indexes`, `pg_extension`/`pg_stat_statements`, and `pg_stat_activity`.

## Recommendations
- **Dirty ratios at/near defaults** (`vm.dirty_ratio` >15 or `dirty_background_ratio` >5) → set 15 and 5 in `/etc/sysctl.d/99-postgresql.conf`. *Rationale:* prevents long system-wide I/O pauses when large dirty-page volumes flush.
- **`vm.swappiness` >10** → set to 1. *Rationale:* DB servers should not swap out working memory.
- **`vm.overcommit_memory` ≠ 2** → set to 2 with a sized `overcommit_ratio`. *Rationale:* stops heuristic overcommit from letting the OOM killer terminate the postmaster.
- **THP = always** → set to `never` (persist via kernel cmdline). *Rationale:* avoids latency stalls and memory bloat.
- **`fsync` off / `full_page_writes` off** (CRIT) → re-enable via `ALTER SYSTEM`. *Rationale:* guards against data loss and torn-page corruption on crash.
- **`data_sync_retry` on** (CRIT) → turn off (needs restart). *Rationale:* avoids silent data loss when Linux discards dirty pages after an fsync failure.
- **`random_page_cost` ≥3.9** → set to 1.1 on SSD/EBS. *Rationale:* keeps the planner from unfairly favoring sequential over index scans.
- **`autovacuum` off** (CRIT) → turn on. *Rationale:* prevents bloat, stale planner stats, and transaction-ID wraparound.
- **Default `shared_buffers` on a ≥4 GB host** → size to ~25% of RAM (restart required). *Rationale:* the 128 MB default underuses available memory.
- **Non-local `trust` / world-open `0.0.0.0/0` `pg_hba` rules** → tighten authentication and address scope. *Rationale:* trust-over-network is unauthenticated access; open rules rely solely on external firewalls.
- **High XID age** (>1.5B CRIT, >500M WARN) → run aggressive `VACUUM (FREEZE)`. *Rationale:* approaching transaction-ID wraparound risks forced shutdown.
- **Inactive replication slots** (CRIT) → `pg_drop_replication_slot()` after confirming the consumer is gone. *Rationale:* orphaned slots retain WAL and eventually fill the disk.
- **`pg_wal` >10 GB / archiver failures** → investigate abandoned slots, failing `archive_command`, or oversized `max_wal_size`. *Rationale:* blocked WAL recycling fills storage.
- **Invalid indexes** → `REINDEX INDEX CONCURRENTLY` or `DROP INDEX`. *Rationale:* leftover failed builds cost writes but serve no reads.
- **Idle-in-transaction >5 min** → set `idle_in_transaction_session_timeout`. *Rationale:* long-open transactions block vacuum and hold locks.
