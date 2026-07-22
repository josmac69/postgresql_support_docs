# pg_backup_audit.sh — Cheat Sheet

**Purpose:** Zero-dependency, read-only audit of a PostgreSQL cluster's backup readiness — WAL archiving config and archiver health, installed backup tooling, scheduled backup jobs, data checksums, and PITR/recovery settings.

**Usage:**
```bash
bash pg_backup_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] | tee pg_backup_audit_$(hostname).log
```
Long forms `--host/--port/--user/--dbname` and `--help` also work; connection env vars (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`) are respected. If `-p` is omitted it probes ports 5432-5435 with `pg_isready` and connects to the first that answers `SELECT 1`.
- **Privileges:** Runs as a normal user (or as `postgres`, where a wrapper strips `-h` for peer auth); needs a role that can read GUCs and stats views. Passwordless `sudo -n` is used only as a fallback to read `pg_wal/archive_status` and `du` the WAL directory — no sudo, no filesystem checks (still runs).
- **Read-only:** Yes — only `SHOW`/`SELECT` queries plus `find`/`du`/`grep` on the filesystem; every `ALTER SYSTEM`, `pg_checksums`, `systemctl restart`, and install command is printed as a recommendation, never executed.

## What it tests
- **WAL archiving config** — `wal_level`, `archive_mode`, `archive_command`, `archive_library`.
- **Archiver runtime health** — `pg_stat_archiver` archived vs failed counts, last archived/failed WAL and timestamp, and whether it is actively FAILING.
- **WAL backlog** — count of unarchived `*.ready` segments in `pg_wal/archive_status`.
- **WAL disk consumption** — `pg_wal` on-disk size compared against `max_wal_size`.
- **Backup tooling** — presence of pgBackRest, Barman, WAL-G plus their configs, stanzas, and backup info.
- **Scheduled backup jobs** — cron entries and systemd timers referencing backup tools or `pg_dump`.
- **Data checksums** — `data_checksums` GUC, `pg_stat_database.checksum_failures`, and `pg_amcheck` availability.
- **Recovery/retention settings** — `restore_command`, `recovery_target_time`, `recovery_target_action`, `wal_keep_size`, `max_slot_wal_keep_size`, `checkpoint_timeout`, and any in-progress base backup.

## How it tests
- Connects with `psql`; if no port given, scans 5432-5435 via `pg_isready` and validates each with `SELECT 1;` before use.
- Reads GUCs through `SHOW` and `pg_settings`; parses parsed output with a `q()` helper (`psql -At -F'|'`) and prints tables with `run_query()`.
- Pulls archiver stats from `pg_stat_archiver`, flagging FAILING when `last_failed_time` is newer than `last_archived_time`.
- Counts `*.ready` files via `find "$DATA_DIR/pg_wal/archive_status"` (with `sudo -n` fallback); sizes WAL with `du -sm` and compares to `max_wal_size` from `pg_settings`.
- Detects tools with `command -v` and probes them: `pgbackrest version`/`info` (parsing stanzas from `/etc/pgbackrest.conf` or `/etc/pgbackrest/pgbackrest.conf`), `barman list-servers`, `wal-g --version`.
- Greps `/etc/crontab`, `/etc/cron.d/*`, and spool crontabs for `pg_dump|pg_basebackup|pgbackrest|barman|wal-g`, and `systemctl list-timers` for backup-related timers.
- Sums `checksum_failures` across `pg_stat_database` and checks `pg_stat_progress_basebackup` for a running backup.
- Accumulates findings into `ISSUES`/`REMEDS` arrays and prints a severity summary (`OK`/`WARN`/`CRIT`). Thresholds: `.ready` backlog >50 = CRIT, >10 = WARN; `pg_wal` >2× `max_wal_size` = CRIT; any `checksum_failures` >0 = CRIT.

## Recommendations
- **wal_level = minimal** → `ALTER SYSTEM SET wal_level = 'replica'` and restart. *Rationale:* minimal logging omits the WAL detail needed for physical base backups and PITR.
- **archive_mode = off** → enable archiving (`archive_mode = on` + a real `archive_command`, restart required). *Rationale:* without WAL archiving only crash recovery from the last base backup is possible, no PITR.
- **archive_mode on but command/library empty** → set a real `archive_command` and `pg_reload_conf()`. *Rationale:* empty commands leave `.ready` files piling up until `pg_wal` fills the disk.
- **archive_command is a no-op** (`true`, `/bin/true`, `cd .`, `:`) → replace with a real tool command and reload. *Rationale:* no-ops silently discard WAL, so PITR is impossible despite archiving appearing "on".
- **Archiver actively failing / backlog >50** → test the command manually as the `postgres` OS user, check destination permissions, then confirm `failed_count` stops growing. *Rationale:* unarchived segments clog `pg_wal` and risk a sudden disk-full crash.
- **pg_wal >2× max_wal_size** → find the stuck retention cause (failed archiving, inactive replication slot, `wal_keep_size`); run `pg_repl_triage.sh` for slots. *Rationale:* WAL is being retained and cannot be recycled.
- **No backup tool installed** → install pgBackRest (`apt-get`/`dnf` per distro); as a stopgap take `pg_basebackup -Ft -z -X stream` or per-DB `pg_dump -Fc`. *Rationale:* a host with no dedicated backup engine has no reliable recovery path.
- **data_checksums = off** → enable in a maintenance window with `pg_checksums --enable -D <datadir>` (cluster cleanly stopped). *Rationale:* without checksums silent page corruption (bit rot, hardware faults) goes undetected.
- **checksum_failures > 0** → identify the affected DB via `pg_stat_database`, verify hardware/`dmesg`, and restore affected relations from backup. *Rationale:* confirms active on-disk data corruption.
