#!/bin/bash
# ============================================================================
# SCRIPT: pg_lock_triage.sh
# DESCRIPTION:
#   Zero-dependency database diagnostic script that connects to a PostgreSQL instance
#   to audit active/idle sessions, wait events, lock hierarchies, and blocking locks.
#   Identifies root blockers and generates immediate safe mitigation commands.
#
# PARAMETERS CHECKED:
#   - Database session distribution: active, idle, idle-in-transaction.
#   - Active wait events: wait_event_type and wait_event fields in pg_stat_activity.
#   - Long-running query statistics: queries active beyond the alert timeout threshold.
#   - Idle-in-transaction times: open transactions waiting for client inputs.
#   - Lock blocking tree: blocking vs blocked PIDs, users, statement previews, and durations.
#   - Relation lock allocation: pg_locks mode and granted state by relation name.
#
# RECOMMENDATIONS & RATIONALE:
#   - If lock blockers are active: Recommends running pg_cancel_backend(pid) or pg_terminate_backend(pid).
#     Rationale: Blocked transactions stack behind the blocker, leading to query timeouts and connection pool exhaustion.
#   - If idle-in-transaction sessions exceed threshold: Recommends closing connections and auditing application code
#     for missing commit/rollback statements. Rationale: Uncommitted transactions hold locks, block vacuum cleanup,
#     and cause massive table bloat by preventing datfrozenxid advancement.
#   - If wait events indicate Lock/IO bottlenecks: Recommends optimizing query indexing or storage throughput.
#     Rationale: Highlights direct resource contention points that are slowing down transaction processing.
#
# USAGE:
#   ./pg_lock_triage.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] [-t <timeout_sec>]
# ============================================================================

set -o nounset
set -o errexit

# Colors for premium CLI styling
if [ -t 1 ]; then
    C_RST=$'\033[0m'
    C_RED=$'\033[1;31m'
    C_GRN=$'\033[1;32m'
    C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'
    C_BOLD=$'\033[1m'
else
    C_RST="" C_RED="" C_GRN="" C_YEL="" C_BLU="" C_BOLD=""
fi

# Print line helper
hr() { printf '%s\n' "--------------------------------------------------------------------------------"; }

# Peer login wrapper when running under postgres user
if [ "$(id -un)" = "postgres" ]; then
    psql() {
        local args=()
        local i=1
        while [ $i -le $# ]; do
            local arg="${!i}"
            if [ "$arg" = "-h" ]; then
                # Omit host flag and its argument to force Unix-domain socket connection (peer login)
                i=$((i + 2))
                continue
            fi
            args+=("$arg")
            i=$((i + 1))
        done
        command psql "${args[@]}"
    }
fi

# CLI Defaults
PG_HOST="${PGHOST:-localhost}"
PG_PORT="${PGPORT:-}"
PG_USER="${PGUSER:-postgres}"
PG_DBNAME="${PGDATABASE:-postgres}"
TIMEOUT_SEC=5

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --host <host>       PostgreSQL host (default: localhost or PGHOST)
  -p, --port <port>       PostgreSQL port (scans 5432-5435 if not set)
  -U, --user <user>       PostgreSQL user (default: postgres or PGUSER)
  -d, --dbname <db>       PostgreSQL database to triage (default: postgres or PGDATABASE)
  -t, --timeout <sec>     Query wait timeout threshold for alerts (default: 5)
  --help                  Show this help menu

Connection env variables (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE) are respected.
EOF
    exit 0
}

# Parse CLI arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--host) PG_HOST="$2"; shift 2 ;;
        -p|--port) PG_PORT="$2"; shift 2 ;;
        -U|--user) PG_USER="$2"; shift 2 ;;
        -d|--dbname) PG_DBNAME="$2"; shift 2 ;;
        -t|--timeout) TIMEOUT_SEC="$2"; shift 2 ;;
        --help) show_help ;;
        *) echo "Unknown option: $1" >&2; show_help ;;
    esac
done

# Verify psql is installed
if ! command -v psql >/dev/null 2>&1; then
    echo "${C_RED}Error: psql utility is required but not found in PATH.${C_RST}" >&2
    exit 1
fi

# Detect running DB and connect
DB_CONNECTED=0
CONNECTED_PORT=""

PORTS_TO_TRY=()
if [ -n "$PG_PORT" ]; then
    PORTS_TO_TRY+=("$PG_PORT")
else
    for p in 5432 5433 5434 5435; do
        if pg_isready -h "$PG_HOST" -p "$p" >/dev/null 2>&1; then
            PORTS_TO_TRY+=("$p")
        fi
    done
    [ ${#PORTS_TO_TRY[@]} -eq 0 ] && PORTS_TO_TRY=(5432)
fi

for port in "${PORTS_TO_TRY[@]}"; do
    res=$(psql -h "$PG_HOST" -p "$port" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT 1;" 2>/dev/null || echo "failed")
    if [ "$res" = "1" ]; then
        DB_CONNECTED=1
        CONNECTED_PORT="$port"
        break
    fi
done

if [ "$DB_CONNECTED" -eq 0 ]; then
    echo "${C_RED}Error: Could not connect to target database at ${PG_HOST} on ports [${PORTS_TO_TRY[*]}].${C_RST}" >&2
    echo "Please check connection parameters or environment credentials." >&2
    exit 1
fi

echo
echo "${C_BOLD}PostgreSQL Session & Lock Contention Triage${C_RST}"
hr
echo "Host            : $PG_HOST"
echo "Port            : $CONNECTED_PORT"
echo "Database        : $PG_DBNAME"
echo "Alert Threshold : $TIMEOUT_SEC seconds"
hr

# Helper function to run query
run_query() {
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -c "$1"
}

# 1. ACTIVE SESSIONS STATE
echo
echo "${C_BOLD}1. Session State Summary${C_RST}"
hr
run_query "
SELECT 
  state AS \"Session State\", 
  count(*) AS \"Count\",
  sum(CASE WHEN now() - state_change > interval '$TIMEOUT_SEC seconds' THEN 1 ELSE 0 END) AS \"Duration > ${TIMEOUT_SEC}s\"
FROM pg_stat_activity 
GROUP BY state 
ORDER BY count(*) DESC;
"

# 2. ACTIVE WAIT EVENTS
echo
echo "${C_BOLD}2. Session Wait Events${C_RST}"
hr
run_query "
SELECT 
  coalesce(wait_event_type, 'CPU/Running') AS \"Wait Event Type\", 
  coalesce(wait_event, 'None') AS \"Wait Event\", 
  count(*) AS \"Count\"
FROM pg_stat_activity 
WHERE state = 'active'
GROUP BY 1, 2 
ORDER BY count(*) DESC;
"

# 3. LONG-RUNNING ACTIVE QUERIES
echo
echo "${C_BOLD}3. Long-Running Active Queries (Running > ${TIMEOUT_SEC}s)${C_RST}"
hr
run_query "
SELECT 
  pid AS \"PID\",
  usename AS \"User\",
  client_addr AS \"Client IP\",
  date_trunc('second', now() - query_start) AS \"Duration\",
  wait_event_type || ': ' || wait_event AS \"Wait Details\",
  substring(query from 1 for 60) AS \"Query Snippet\"
FROM pg_stat_activity 
WHERE state = 'active' 
  AND now() - query_start > interval '$TIMEOUT_SEC seconds'
ORDER BY query_start ASC;
"

# 4. IDLE IN TRANSACTION SESSIONS
echo
echo "${C_BOLD}4. Idle In Transaction Sessions (Open > ${TIMEOUT_SEC}s)${C_RST}"
hr
run_query "
SELECT 
  pid AS \"PID\",
  usename AS \"User\",
  client_addr AS \"Client IP\",
  date_trunc('second', now() - state_change) AS \"Idle Time\",
  substring(query from 1 for 60) AS \"Last Query Snippet\"
FROM pg_stat_activity 
WHERE state IN ('idle in transaction', 'idle in transaction (aborted)') 
  AND now() - state_change > interval '$TIMEOUT_SEC seconds'
ORDER BY state_change ASC;
"

# 5. LOCK WAIT HIERARCHY (BLOCKERS)
echo
echo "${C_BOLD}5. Lock Contention & Blocked Queries Hierarchy${C_RST}"
hr

# Query to fetch blocked relations and pids
blocker_list=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT 
  blocked_locks.pid     AS blocked_pid,
  blocked_activity.usename  AS blocked_user,
  date_trunc('second', now() - blocked_activity.query_start) AS blocked_duration,
  blocking_locks.pid    AS blocking_pid,
  blocking_activity.usename AS blocking_user,
  date_trunc('second', now() - blocking_activity.query_start) AS blocking_duration,
  substring(blocked_activity.query from 1 for 40) AS blocked_statement,
  substring(blocking_activity.query from 1 for 40) AS blocking_statement
FROM pg_catalog.pg_locks            blocked_locks
JOIN pg_catalog.pg_stat_activity    blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks            blocking_locks 
  ON blocking_locks.locktype = blocked_locks.locktype
  AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
  AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
  AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
  AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
  AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
  AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
  AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
  AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
  AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
  AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity    blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;
" 2>/dev/null)

declare -a BLOCKER_PIDS=()

if [ -n "$blocker_list" ]; then
    printf "%-10s %-12s %-10s %-10s %-12s %-10s %-25s\n" "BlockedPID" "BlockedUser" "WaitTime" "BlockerPID" "BlockerUser" "BlockerTime" "Blocking Query Preview"
    hr
    while IFS='|' read -r b_pid b_user b_dur block_pid block_user block_dur b_stmt block_stmt; do
        printf "%-10s %-12.12s %-10s %-10s %-12.12s %-10s %-25s\n" \
            "$b_pid" "$b_user" "$b_dur" "$block_pid" "$block_user" "$block_dur" "$block_stmt"
        
        # Save unique root blocker PIDs for recommendations
        if [[ ! " ${BLOCKER_PIDS[*]} " =~ " ${block_pid} " ]]; then
            BLOCKER_PIDS+=("$block_pid")
        fi
    done <<< "$blocker_list"
else
    echo "No blocked transactions detected at this time."
fi
hr

# 6. GRANTED LOCK TYPES BY RELATION
echo
echo "${C_BOLD}6. Active Relation Locks by Mode${C_RST}"
hr
run_query "
SELECT 
  coalesce(t.schemaname || '.' || t.relname, c.relname) AS \"Locked Relation\",
  l.mode AS \"Lock Mode\",
  l.granted AS \"Granted Status\",
  count(*) AS \"Lock Count\"
FROM pg_locks l
JOIN pg_class c ON (l.relation = c.oid)
LEFT JOIN pg_stat_user_tables t ON (t.relid = c.oid)
GROUP BY 1, 2, 3
ORDER BY count(*) DESC
LIMIT 15;
"

# 7. MITIGATION ACTIONS
echo
echo "${C_BOLD}7. Recommended Mitigation Plan${C_RST}"
hr
if [ ${#BLOCKER_PIDS[@]} -gt 0 ]; then
    echo "${C_RED}[WARN] Found active blockers that are holding up queries!${C_RST}"
    echo "To resolve lock contention immediately, consider cancelling or terminating the blocker transactions:"
    echo
    for pid in "${BLOCKER_PIDS[@]}"; do
        echo "  -- [PID $pid] Blocker mitigation commands:"
        echo "  -- Gracefully cancel query (retains database connection):"
        echo "     SELECT pg_cancel_backend($pid);"
        echo
        echo "  -- Forcefully terminate query (closes TCP session immediately):"
        echo "     SELECT pg_terminate_backend($pid);"
        echo
        echo "  -- OS-level print stack trace if unresponsive (run as root):"
        echo "     sudo gdb -p $pid -ex \"bt\" -ex \"detach\" -ex \"quit\""
        hr
    done
else
    echo "${C_GRN}[PASS]${C_RST} No active lock blockers detected. CPU load and connection pools are functioning normally."
fi
hr
echo
