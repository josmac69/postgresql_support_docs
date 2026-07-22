# pg_repl_triage.sh — Cheat Sheet

**Purpose:** Zero-dependency, read-only triage of PostgreSQL streaming replication — audits recovery role, key WAL/replication parameters, archiver health, standby/receiver streaming state, replication slots, and TCP reachability to peer cluster nodes.

**Usage:**
```bash
./pg_repl_triage.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] [--peers <ip1,ip2>]
```
- **Privileges:** No sudo required; runs as a normal user. When invoked as the `postgres` OS user it wraps `psql` to drop `-h`, forcing Unix-socket peer login. Peer discovery reads `/etc/hosts` and `/etc/patroni/*.yml` only if those files are readable.
- **Read-only:** Yes — issues only `SELECT` queries and non-blocking TCP port probes; never installs, benchmarks, writes config, or modifies data. Respects `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE` env vars.

## What it tests
- **Recovery role** — Primary vs Standby via `pg_is_in_recovery()`, plus current WAL LSN offset.
- **Key parameters** — `wal_level`, `max_wal_senders`, `max_replication_slots`, `hot_standby`, `wal_keep_size`/`wal_keep_segments`, `primary_conninfo`, `primary_slot_name` (current, default, and an evaluation verdict).
- **WAL archiver** — archived/failed counts, last archived/failed WAL name and timestamp, and whether the archive command is actively failing.
- **Streaming state** — on Primary: connected standbys with client IP, state, sync mode, and sent/write/replay lag; on Standby: receiver status, received LSN/timeline, last message timing, and conninfo.
- **Replication slots** — slot name, plugin, type, active flag, `wal_status`, and retained WAL size, flagging inactive slots.
- **Peer reachability** — TCP probes of peer IPs on ports 5432 (PostgreSQL), 6432 (pgBouncer), 8008 (Patroni REST API), 2379 (etcd).

## How it tests
- Requires `psql` in `PATH` (exits otherwise); if `-p` is not given, probes ports 5432–5435 with `pg_isready` and connects to the first that answers `SELECT 1`.
- Role/LSN from `pg_is_in_recovery()`, `pg_current_wal_lsn()` (Primary) / `pg_last_wal_replay_lsn()` (Standby), diffed via `pg_wal_lsn_diff()`.
- Parameters queried from `pg_settings`; archiver from `pg_stat_archiver`; streaming from `pg_stat_replication` (Primary) or `pg_stat_wal_receiver` (Standby); slots from `pg_replication_slots`.
- In-SQL `CASE` logic emits the verdicts: `wal_level` not `replica`/`logical`, `hot_standby=off`, `max_wal_senders<2`, archiver `failed_count>0` with `last_failed_time>last_archived_time`, and slots with `active='f'`.
- Peer list comes from `--peers`, else IPv4 entries in `/etc/hosts` (excluding 127.0.0.1/.53/.54) and `host:` lines in `/etc/patroni/*.yml`.
- TCP probe is a non-blocking `timeout 1 bash -c "echo > /dev/tcp/<ip>/<port>"`, printing OPEN vs CLOSED/BLOCKED per host/port.
- Section 7 prints role-specific remediation runbooks (standby rebuild vs primary access).

## Recommendations
- **`wal_level` not `replica`/`logical`** → raise it. *Rationale:* streaming replication is impossible without enough replication metadata in the WAL stream.
- **`hot_standby` off** → enable it. *Rationale:* standby instances cannot serve read queries while it is disabled.
- **`max_wal_senders` < 2** → increase sender capacity or limit replication targets. *Rationale:* too few senders cap the number of concurrent replicas.
- **Archive command actively failing** → test the `archive_command` manually. *Rationale:* unsent WAL accumulates in `pg_wal`, exhausting disk and triggering a database PANIC.
- **Inactive replication slot retaining WAL** → drop it with `pg_drop_replication_slot('slot_name')`. *Rationale:* inactive slots force the primary to retain WAL indefinitely, risking disk exhaustion.
- **Peer port CLOSED/BLOCKED** → check firewalls and security groups. *Rationale:* network blockages prevent primary–standby sync, causing replica lag or split-brain.
- **Broken/lagging standby** → verify networking and `primary_conninfo`, then rebuild via `pg_basebackup -R -X stream` or realign a diverged timeline with `pg_rewind`. *Rationale:* restores streaming when the replica cannot catch up.
- **Standby cannot register on primary** → add a `replication` rule to `pg_hba.conf` and `pg_reload_conf()`. *Rationale:* missing host-based auth rules block replica connections.
