# pg_log_audit.sh — Cheat Sheet

**Purpose:** Zero-dependency log forensics audit that locates PostgreSQL logs across files, syslog, and journald and scans them for crashes, resource pressure, lock contention, checkpoint/WAL issues, and auth failures, then audits the logging GUCs themselves.

**Usage:**
```bash
sudo bash pg_log_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] [--hours <n>] [--lines <n>]
```
- `-h/--host` (default `localhost`/`PGHOST`), `-p/--port` (probes 5432-5435 via `pg_isready` if unset), `-U/--user` (default `postgres`/`PGUSER`), `-d/--dbname` (default `postgres`/`PGDATABASE`), `--hours` journald/syslog scan window (default 24), `--lines` sample lines per finding (default 15), `--help`.
- **Privileges:** Runs as a normal user but is best with `sudo` — log dirs are often `0700 postgres:postgres`, and `dmesg`/`journalctl` need root; it auto-uses `sudo -n` when available and degrades gracefully otherwise.
- **Read-only:** Yes — only reads log files, `dmesg`, journald, and `SHOW` GUCs; it prints remediation commands but never runs them or modifies anything.

## What it tests
- **Log destination discovery** — `log_destination`, `logging_collector`, `log_directory`, current logfile, distro default paths, and journald units.
- **Critical events** — PANIC errors, backend crashes / signal terminations, unclean-shutdown & crash-recovery messages, FATAL entries.
- **Resource pressure** — in-PostgreSQL out-of-memory, kernel OOM-killer kills, disk-full/no-space errors, connection-limit rejections, temp-file spills.
- **Locking pathologies** — deadlocks, `log_lock_waits` long waits, admin/timeout-cancelled or terminated backends.
- **Checkpoint & WAL pressure** — "checkpoints occurring too frequently", archive command failures, standby replication/recovery conflicts.
- **Authentication & security** — failed password / missing `pg_hba.conf` entry, `permission denied` role errors.
- **Top error fingerprints** — aggregated, normalized `ERROR:` message frequency.
- **Logging GUC audit** — `log_checkpoints`, `log_lock_waits`, `log_temp_files`, `log_min_duration_statement`, `log_line_prefix`.

## How it tests
- Optionally connects with `psql` (tests `SELECT 1`); with no `-p`, probes ports 5432-5435 via `pg_isready`, else defaults to 5432. All DB queries go through a `q()` helper (`SHOW`/`SELECT`), so the whole script degrades to filesystem-only mode when the DB is unreachable.
- Discovers logs by resolving `log_directory` against `data_directory` and `pg_current_logfile()`, falling back to `ls -1t | head -3` in the resolved dir and in distro defaults (`/var/log/postgresql`, `/var/lib/pgsql/*/data/log`, `/var/lib/postgresql/*/main/log`), deduping the file list.
- Detects journald with `journalctl -u 'postgresql*'`; `dump_logs()` concatenates `sudo cat` of the files plus `journalctl -u 'postgresql*' --since "-${HOURS_BACK}h"`.
- `scan_pattern()` runs `grep -aE <pattern>` over `dump_logs`, counts hits with `grep -acE`, and prints the last `--lines` samples, tagging each as CRIT or WARN.
- Kernel OOM: `sudo dmesg | grep 'killed process.*(postgres|postmaster)'`, falling back to `journalctl -k` within the scan window.
- Top errors: greps `ERROR:`, normalizes with `sed` (digits → `N`, quoted/`"..."` literals → `X`), then `sort | uniq -c | sort -rn | head -10`.
- GUC audit via `check_guc()` compares each `SHOW` value to the recommended one; accumulates findings into `ISSUES`/`REMEDS` arrays for a final severity-tagged summary.

## Recommendations
- **PANIC detected** → investigate root cause first; check `df -h` and `dmesg`. *Rationale:* usually WAL/disk corruption or a full disk causing service downtime.
- **Backend crash / signal termination** → correlate timestamps with `dmesg` (OOM/segfault), check extension faults and core dumps. *Rationale:* pinpoints hardware, memory, or extension bugs.
- **Unclean shutdown** → verify cause (power/OOM/`kill -9`) and confirm recovery completed. *Rationale:* ensures the instance actually recovered cleanly.
- **PostgreSQL OOM** → audit `work_mem × max_connections` budget and check `vm.overcommit_memory=2`. *Rationale:* prevents allocation failures under load.
- **Kernel OOM-killer hit** → set postmaster `oom_score_adj`/`OOMScoreAdjust=-1000` and reduce overcommit. *Rationale:* protects DB processes from termination.
- **Disk full** → free space (`df -h`, WAL dir usage), fix archiving/rotation; never delete `pg_wal` manually. *Rationale:* avoids irreversible WAL loss.
- **Connection saturation** → deploy/verify pgBouncer or raise `max_connections` after memory budgeting. *Rationale:* stops connection-slot rejections.
- **Temp-file spills** → raise `work_mem` for the offending roles/sessions. *Rationale:* avoids disk spills from undersized `work_mem`.
- **Deadlocks** → extract the two statements, enforce consistent lock ordering, keep transactions short. *Rationale:* removes cyclic lock waits.
- **Long lock waits** → run `pg_lock_triage.sh` live to map the blocker tree. *Rationale:* identifies the blocking session.
- **Frequent checkpoints** → raise `max_wal_size` and keep `checkpoint_timeout >= 15min` for OLTP. *Rationale:* reduces full-page-image write I/O.
- **Archive command failures** → run `pg_backup_audit.sh` and test `archive_command` manually as `postgres`. *Rationale:* protects PITR/backup chain integrity.
- **Recovery conflicts on standby** → enable `hot_standby_feedback` or raise `max_standby_streaming_delay`. *Rationale:* trades primary bloat against query cancellations.
- **Auth failures** → verify credentials and `pg_hba.conf` ordering; restrict CIDRs / add fail2ban for brute force. *Rationale:* closes credential and access-list gaps.
- **Permission errors** → grant only the privileges the app role needs. *Rationale:* least-privilege access.
- **Sub-optimal logging GUCs** → enable `log_checkpoints`, `log_lock_waits`, `log_temp_files`, `log_min_duration_statement`, and an informative `log_line_prefix`. *Rationale:* missing logs make spills, lock delays, and tuning invisible.
