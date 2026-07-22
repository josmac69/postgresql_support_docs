# pg_lock_triage.sh — Cheat Sheet

**Purpose:** Zero-dependency PostgreSQL triage that connects via `psql` to audit session states, wait events, long-running and idle-in-transaction sessions, and lock-blocking hierarchies, then prints ready-to-run mitigation commands for the root blockers.

**Usage:**
```bash
./pg_lock_triage.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] [-t <timeout_sec>]
./pg_lock_triage.sh --help
```
- **Privileges:** Runs as a normal user — needs only a `psql` login (respects `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`); when invoked as the `postgres` OS user it auto-drops `-h` to use peer/socket auth. No `sudo` required to run; `sudo` only appears inside a suggested `gdb` command.
- **Read-only:** Yes — issues only `SELECT` queries against catalog/stat views; it never cancels, terminates, or modifies anything. Mitigation commands (`pg_cancel_backend`, `pg_terminate_backend`, `gdb`) are printed as suggestions, not executed.

## What it tests
- **Session state summary** — counts by `state` (active, idle, idle-in-transaction) plus how many exceed the timeout threshold.
- **Wait events** — `wait_event_type`/`wait_event` distribution across active sessions (CPU/Running when none).
- **Long-running active queries** — active sessions whose `query_start` is older than the timeout threshold, with duration, user, client IP, wait details, and query snippet.
- **Idle-in-transaction sessions** — sessions in `idle in transaction` / `idle in transaction (aborted)` open longer than the threshold.
- **Lock contention hierarchy** — blocked vs blocking PIDs, users, durations, and blocking statement preview.
- **Relation locks by mode** — top 15 `pg_locks` entries grouped by relation, lock mode, and granted status.
- **Mitigation plan** — per unique root-blocker PID, the safe commands to relieve contention.

## How it tests
- Verifies `psql` is on `PATH`; aborts if missing.
- Port discovery: uses `-p` if given, else `pg_isready` probes ports 5432–5435 and connects with a `SELECT 1;` test (falls back to 5432).
- Peer-login wrapper: when `id -un` is `postgres`, a shell `psql()` function strips the `-h` flag to force a Unix-socket connection.
- All checks run as `psql -c` queries against `pg_stat_activity`, `pg_locks`, `pg_class`, and `pg_stat_user_tables`.
- Long-running / idle checks compare `now() - query_start` (or `state_change`) against `interval '<timeout> seconds'`.
- Blocking tree: self-join of `pg_locks` (blocked vs blocking) on all lock-identity columns joined to `pg_stat_activity`, filtered to `NOT blocked_locks.granted`; output is parsed with `IFS='|'` and unique blocker PIDs collected into a `BLOCKER_PIDS` array.
- Formatted with ANSI colors (TTY only) and a `hr()` rule; severity tags `[WARN]`/`[PASS]` mark the mitigation section.

## Recommendations
- **Active lock blockers found** → run the printed `SELECT pg_cancel_backend(<pid>);` (graceful) or `SELECT pg_terminate_backend(<pid>);` (forceful), or `sudo gdb -p <pid> -ex "bt" ...` if unresponsive. *Rationale:* blocked transactions stack behind the blocker, causing query timeouts and connection-pool exhaustion.
- **Idle-in-transaction over threshold** → close the connections and audit application code for missing commit/rollback. *Rationale:* uncommitted transactions hold locks, block vacuum cleanup, and cause table bloat by preventing `datfrozenxid` advancement.
- **Wait events indicate Lock/IO bottlenecks** → optimize query indexing or storage throughput. *Rationale:* these are direct resource-contention points slowing transaction processing.
- **No blockers detected** → `[PASS]`, no action. *Rationale:* CPU load and connection pools are functioning normally.
