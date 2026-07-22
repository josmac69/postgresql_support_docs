# pg_gotcha_sweep.sh — Cheat Sheet

**Purpose:** Zero-dependency sweep for classic PostgreSQL config gotchas, silent GUC shadowing, clock/timezone drift, unpersisted mounts, and scheduled jobs that could collide with maintenance or break reboot survival.

**Usage:**
```bash
./pg_gotcha_sweep.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>]
./pg_gotcha_sweep.sh --lookahead 4   # flag scheduled jobs firing within the next 4 hours
./pg_gotcha_sweep.sh --help
```
Flags: `-h/--host` (default `localhost` or `$PGHOST`), `-p/--port` (scans 5432-5435 via `pg_isready` if unset), `-U/--user` (default `postgres` or `$PGUSER`), `-d/--dbname` (default `postgres` or `$PGDATABASE`), `--lookahead <hours>` (default 4), `--help`.
- **Privileges:** Runs best with passwordless `sudo` (auto-detected via `sudo -n`) to read `postgresql.auto.conf`, config files, crontabs, and `atq`; without it those checks degrade gracefully. DB connection is optional — filesystem/clock/job checks run regardless.
- **Read-only:** Yes — only runs `SELECT`/`SHOW` queries and reads config/system files; it never restarts, edits, benchmarks, or modifies anything. All fixes are printed as suggested commands only.

## What it tests
- **Pending restart** — GUCs changed in config but not yet applied (`pending_restart` in `pg_settings`).
- **ALTER SYSTEM shadowing** — settings whose live source is `postgresql.auto.conf`, silently overriding `postgresql.conf`.
- **auto.conf tampering** — hand-edit fingerprint (more than the one standard comment line) and duplicate keys inside `postgresql.auto.conf`.
- **postgresql.conf hygiene** — `include` directives that hide settings, plus duplicate uncommented keys (last wins).
- **data_sync_retry** — should be `off`; `on` risks silent corruption on fsync failure.
- **pg_hba ordering** — first-match-wins traps where a broad `all/all` `0.0.0.0/0`/`::/0` `reject` or `trust` rule shadows everything below it.
- **Reboot survival** — active data mounts missing from `/etc/fstab` (or a systemd mount unit), especially if the `data_directory` lives on one.
- **Clock & timezone** — NTP sync state, OS-vs-PostgreSQL epoch drift, and PostgreSQL timezone.
- **Scheduled jobs** — systemd timers, cron entries, and `at` jobs that are heavy or fire in the lookahead window.
- **Logrotate** — logrotate configs touching the PG stack (postgres/pgbouncer/patroni/haproxy) and `copytruncate` use.

## How it tests
- Optionally connects with `psql -At`, probing ports 5432-5435 via `pg_isready`; a wrapper strips `-h` for peer auth when run as the `postgres` user. All FS checks proceed even with no DB.
- Section 1: `SELECT ... FROM pg_settings WHERE pending_restart`.
- Section 2: `SHOW data_directory`/`config_file`; `pg_settings WHERE sourcefile LIKE '%postgresql.auto.conf'`; `cat` of auto.conf counting `^\s*#` lines (>1 = hand-edited) and duplicate keys via `cut -d= | sort | uniq -d`; greps `postgresql.conf` for `include` lines and duplicate keys; summary query grouping `pg_settings` by `source`.
- Section 3: `SHOW data_sync_retry`.
- Section 4: `pg_hba_file_rules` iterated in `line_number` order, flagging broad `all/all` `0.0.0.0/0`/`::/0` rules with `reject` or `trust`.
- Section 5: walks `/proc/mounts` for `ext4/xfs/btrfs/ext3/zfs` (skips `/`, `/boot*`, `/snap*`), matches against `/etc/fstab` by mountpoint path or `lsblk` UUID, then `systemd-escape`/`systemctl is-enabled` for mount units; cross-checks `data_directory`.
- Section 6: `timedatectl` for `System clock synchronized: yes`, falling back to `chronyc tracking`/`ntpq -p`; compares `date +%s` against `extract(epoch FROM now())` and warns on drift > 2s.
- Section 7: `systemctl list-timers` grepped for `backup|vacuum|reindex|dump|apt|dnf|unattended|update`; cron from `/etc/crontab`, `/etc/cron.d/*`, and `crontab -l` for `root`/`postgres` (parsed by `parse_cron_line`), grepped for `pg_dump|vacuum|reindex|backup|rsync|find /|dd|restart|reboot` with an `awk` hour-field check for this/next hour; `atq` for one-shot jobs.
- Section 8: greps `/etc/logrotate.conf` and `/etc/logrotate.d/*` for `postgres|pgbouncer|patroni|haproxy` and checks for `copytruncate`.
- Findings accumulate in `ISSUES`/`REMEDS` arrays printed as a final severity summary (`OK`/`INFO`/`WARN`/`CRIT`).

## Recommendations
- **GUCs pending restart** → restart to apply (justify the outage) or revert the unintended change. *Rationale:* running values differ from the config files, so behavior can change unexpectedly on the next reboot.
- **ALTER SYSTEM override active** → `ALTER SYSTEM RESET <name>; SELECT pg_reload_conf();`. *Rationale:* `postgresql.auto.conf` silently overrides `postgresql.conf`, so editing the latter has no effect.
- **Hand-edited auto.conf** → review the file, migrate intended settings into `postgresql.conf` or re-apply via `ALTER SYSTEM`, then clean up with `ALTER SYSTEM RESET`. *Rationale:* manual edits may not match what `ALTER SYSTEM` actually recorded.
- **Duplicate keys in postgresql.conf** → keep one authoritative line per parameter and verify with `SHOW <param>;`. *Rationale:* only the last uncommented line applies; earlier lines are decoys that mislead admins.
- **data_sync_retry = on** → set it `off` and restart. *Rationale:* on Linux, retrying fsync can act on pages the page cache already discarded, causing silent corruption; `off` panics PG immediately so WAL recovery preserves integrity.
- **pg_hba global reject** → move the reject line below specific allow rules (or delete it) and `pg_reload_conf()`. *Rationale:* first-match-wins means a top `reject all/all` makes every network rule beneath it dead.
- **pg_hba global trust** → replace with `scram-sha-256` and narrow CIDRs, then `pg_reload_conf()`. *Rationale:* a global `trust` lets the whole internet connect without a password and shadows stricter rules below.
- **Mount missing from fstab** → persist it (`UUID=... <mnt> <fstype> defaults,noatime 0 2`) and validate with `sudo findmnt --verify`. *Rationale:* an unpersisted mount will not return after reboot; if the `data_directory` lives on it, PG starts with a missing datadir.
- **Clock not NTP-synchronized** → `sudo timedatectl set-ntp true` or install/enable chrony. *Rationale:* clock drift breaks Patroni TTL/leasing math, log timestamp correlation, and SSL/TLS certificate validity.
- **Heavy scheduled job in the window** → note it in the report; delay a single run with `systemctl stop <name>.timer` (restart after) only with customer approval — never disable permanently. *Rationale:* colliding jobs cause resource contention during maintenance.
- **Pending `at` jobs** → inspect payloads with `sudo at -c <jobid>` and remove with `sudo atrm <jobid>` only if malicious/mistaken. *Rationale:* one-shot `at` jobs are a common hiding spot for surprise commands.
