# pg_activity_audit.sh — Cheat Sheet

**Purpose:** Zero-dependency, read-only triage of live PostgreSQL activity — audits connection saturation, client/user skews, idle-in-transaction sessions, slow queries, lock-blocked sessions, orphaned 2PC transactions, and runaway autovacuum workers.

**Usage:**
```bash
./pg_activity_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>]
./pg_activity_audit.sh --idle-tx 5 --long-query 10 --prepared 5
```
Flags: `-h/--host`, `-p/--port` (auto-scans 5432–5435 via `pg_isready` if unset), `-U/--user`, `-d/--dbname`, `--idle-tx <sec>` (default 5), `--long-query <sec>` (default 10), `--prepared <min>` (default 5), `--help`. `PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE` are respected.
- **Privileges:** No `sudo`. Needs a DB role that can read `pg_stat_activity`/`pg_prepared_xacts` (superuser or `pg_read_all_stats` for other sessions' query text); when run as the `postgres` OS user it drops `-h` to force Unix-socket peer login.
- **Read-only:** Yes — issues only `SELECT` queries against catalog/stat views. It never terminates, cancels, or rolls back anything; remediation commands (`pg_terminate_backend`, `pg_cancel_backend`, `ROLLBACK PREPARED`) are only printed for you to run.

## What it tests
- **Connection saturation** — current connections vs `max_connections`, broken into active / idle / idle-in-transaction.
- **Client & user distribution** — top 5 client IPs and top 5 DB user accounts by connection count, with percentages.
- **Idle-in-transaction sessions** — sessions idle in a transaction longer than the `--idle-tx` threshold.
- **Long-running queries** — active client-backend queries running longer than the `--long-query` threshold.
- **Lock-blocked sessions** — sessions with `wait_event_type = 'Lock'`.
- **Orphaned prepared (2PC) transactions** — `pg_prepared_xacts` entries older than the `--prepared` threshold.
- **Runaway autovacuum workers** — autovacuum backends running longer than a hardcoded 15 minutes.

## How it tests
- Verifies `psql` is on PATH; probes ports with `pg_isready`, then confirms with `SELECT 1;` to pick the live port.
- Connection stats: one aggregate query over `pg_stat_activity` plus `max_connections` from `pg_settings`; percentage computed with `awk`, thresholds compared with `bc -l` (`>=85%` critical, `>=70%` warn).
- Distribution: `GROUP BY` on `client_addr` and `usename`, `ORDER BY count DESC LIMIT 5`.
- Idle-in-TX: `state LIKE 'idle in transaction%' AND now()-state_change > interval '<idle-tx> seconds'`.
- Long queries: `state='active' AND backend_type='client backend' AND now()-query_start > interval '<long-query> seconds'`.
- Locks: `wait_event_type='Lock'` ordered by wait duration.
- Prepared TX: `pg_prepared_xacts WHERE now()-prepared > interval '<prepared> minutes'`.
- Autovacuum: `query LIKE 'autovacuum:%' AND now()-query_start > interval '15 minutes'`.
- Collects flagged PIDs/GIDs into bash arrays and prints ready-to-run remediation SQL in a final recovery plan.

## Recommendations
- **Saturation ≥ 70% (≥ 85% critical)** → check connection-pooler routing / add pooling. *Rationale:* unpooled spikes exhaust backend resources and drive OS context-switching; near 100% new connections are refused.
- **Idle-in-transaction sessions** → `SELECT pg_terminate_backend(pid);`. *Rationale:* they hold locks and pin the catalog xmin, blocking VACUUM and causing table/index bloat.
- **Long-running active queries** → `SELECT pg_cancel_backend(pid);`. *Rationale:* cancels unoptimized or blocked queries consuming CPU/memory while keeping the client connection.
- **Lock-blocked sessions** → run `pg_lock_triage.sh` to inspect the full blocker-blocked tree. *Rationale:* the audit only flags waiters; the tree reveals the head blocker to resolve.
- **Orphaned prepared (2PC) transactions** → `ROLLBACK PREPARED '<gid>';`. *Rationale:* they survive backend exit and reboots, block VACUUM indefinitely, and are an XID-wraparound hazard.
- **Autovacuum workers running > 15 min** → adjust cost-limit GUCs or optimize the workload. *Rationale:* runaway workers signal heavy write load, vacuum starvation, or aggressive lock conflicts.
