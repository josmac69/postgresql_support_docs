#!/bin/bash
# ============================================================================
# SCRIPT: pg_activity_audit.sh
# DESCRIPTION:
#   Zero-dependency, portable diagnostics script that connects to a target
#   PostgreSQL database and analyzes pg_stat_activity and pg_prepared_xacts
#   to audit connection saturation, client skews, slow queries, lock-blocked sessions,
#   and orphaned two-phase commit (2PC) transactions.
#
# PARAMETERS CHECKED:
#   - Connection Saturation (pg_stat_activity vs max_connections GUC)
#   - Client Distribution (IP addresses and user account connection counts)
#   - Idle-In-Transaction duration (state_change age)
#   - Long-Running Queries (query_start age)
#   - Lock Waiting status (wait_event_type = 'Lock')
#   - Prepared (2PC) Transaction age (pg_prepared_xacts prepared time)
#   - Background workers (autovacuum process runtime)
#
# RECOMMENDATIONS & RATIONALE:
#   - If Connection Saturation >= 70%: Warns to check connection pooling. Rationale:
#     Unpooled connection spikes exhaust backend resources and cause OS-level context switching.
#   - If Idle-in-Transaction sessions persist: Recommends terminating via pg_terminate_backend.
#     Rationale: Idle-in-transaction sessions hold locks and pin the database catalog xmin,
#     blocking VACUUM from cleanup and causing massive table and index bloat.
#   - If Long-Running active queries exist: Recommends cancelling via pg_cancel_backend.
#     Rationale: Identifies unoptimized or locked queries consuming CPU and memory.
#   - If Orphaned Prepared (2PC) Transactions found: Recommends ROLLBACK PREPARED. Rationale:
#     2PC transactions persist across backend exits and server reboots, blocking VACUUM
#     indefinitely and presenting a serious Transaction ID (XID) wraparound hazard.
#   - If Autovacuum workers run > 15 mins: Recommends adjusting cost-limit GUCs or optimizing.
#     Rationale: Runaway workers indicate heavy write load, vacuum starvation, or aggressive lock conflicts.
#
# USAGE:
#   ./pg_activity_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>]
#   ./pg_activity_audit.sh --idle-tx 5 --long-query 10 --prepared 5
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
IDLE_TX_THRESHOLD_SEC=5
LONG_QUERY_THRESHOLD_SEC=10
PREPARED_TX_THRESHOLD_MIN=5

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --host <host>       PostgreSQL host (default: localhost or PGHOST)
  -p, --port <port>       PostgreSQL port (scans 5432-5435 if not set)
  -U, --user <user>       PostgreSQL user (default: postgres or PGUSER)
  -d, --dbname <db>       PostgreSQL database (default: postgres or PGDATABASE)
  --idle-tx <sec>         Idle-in-transaction alert threshold in seconds (default: 5)
  --long-query <sec>      Long query alert threshold in seconds (default: 10)
  --prepared <min>        Prepared transaction alert threshold in minutes (default: 5)
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
        --idle-tx) IDLE_TX_THRESHOLD_SEC="$2"; shift 2 ;;
        --long-query) LONG_QUERY_THRESHOLD_SEC="$2"; shift 2 ;;
        --prepared) PREPARED_TX_THRESHOLD_MIN="$2"; shift 2 ;;
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
echo "${C_BOLD}PostgreSQL Activity & Process Performance Audit${C_RST}"
hr
echo "Host            : $PG_HOST"
echo "Port            : $CONNECTED_PORT"
echo "Database        : $PG_DBNAME"
echo "Triage Rules    : Idle-in-TX > ${IDLE_TX_THRESHOLD_SEC}s | Query > ${LONG_QUERY_THRESHOLD_SEC}s | PrepTX > ${PREPARED_TX_THRESHOLD_MIN}m"
hr

# Helper function to run query
run_query() {
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -c "$1"
}

# 1. CONNECTION RESOURCE UTILITIES & SATURATION
echo
echo "${C_BOLD}1. Connection Capacity & Saturation${C_RST}"
hr

conn_data=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT 
  (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'),
  count(*),
  sum(CASE WHEN state = 'active' THEN 1 ELSE 0 END),
  sum(CASE WHEN state = 'idle' THEN 1 ELSE 0 END),
  sum(CASE WHEN state LIKE 'idle in transaction%' THEN 1 ELSE 0 END)
FROM pg_stat_activity;
" 2>/dev/null || echo "failed")

MAX_CONNS=100
CUR_CONNS=0
ACTIVE_CONNS=0
IDLE_CONNS=0
IDLE_IN_TX_CONNS=0

if [ "$conn_data" != "failed" ]; then
    IFS='|' read -r max_c cur_c act_c idle_c idletx_c <<< "$conn_data"
    MAX_CONNS="${max_c:-100}"
    CUR_CONNS="${cur_c:-0}"
    ACTIVE_CONNS="${act_c:-0}"
    IDLE_CONNS="${idle_c:-0}"
    IDLE_IN_TX_CONNS="${idletx_c:-0}"
    
    PCT_USED=$(awk "BEGIN {print ($CUR_CONNS / $MAX_CONNS) * 100}")
    
    echo "Max Allowed Connections : $MAX_CONNS"
    echo "Current Connections     : $CUR_CONNS (Saturation: ${PCT_USED}%)"
    echo "  - Active Sessions     : $ACTIVE_CONNS"
    echo "  - Idle Sessions       : $IDLE_CONNS"
    echo "  - Idle in Transaction : $IDLE_IN_TX_CONNS"
    
    if (( $(echo "$PCT_USED >= 85" | bc -l) )); then
        echo "${C_RED}[CRITICAL] Connection pool saturation is extremely high (>= 85%). Risk of refusing new connections!${C_RST}"
    elif (( $(echo "$PCT_USED >= 70" | bc -l) )); then
        echo "${C_YEL}[WARN] Connection pool saturation is moderate (>= 70%). Check connection pooler routing.${C_RST}"
    else
        echo "${C_GRN}[OK] Connection pool capacity is healthy (< 70%).${C_RST}"
    fi
else
    echo "Failed to gather connection resource statistics."
fi
hr

# 2. CLIENT SOURCE PORT & USER CONNECTION SKEWS
echo
echo "${C_BOLD}2. Client Connection Squeals & Distribution (Top Sources)${C_RST}"
hr
echo "Top client IP addresses by active connection count:"
run_query "
SELECT 
  coalesce(client_addr::text, '[Local Socket]') AS \"Client Address\", 
  count(*) AS \"Connections\",
  round(100.0 * count(*) / (SELECT nullif(count(*), 0) FROM pg_stat_activity), 1) AS \"Percentage (%)\"
FROM pg_stat_activity 
GROUP BY 1 
ORDER BY 2 DESC 
LIMIT 5;
"

echo "Top database user accounts by active connection count:"
run_query "
SELECT 
  usename AS \"Database User\",
  count(*) AS \"Connections\",
  round(100.0 * count(*) / (SELECT nullif(count(*), 0) FROM pg_stat_activity), 1) AS \"Percentage (%)\"
FROM pg_stat_activity 
GROUP BY 1 
ORDER BY 2 DESC 
LIMIT 5;
"

# 3. IDLE IN TRANSACTION TRIAGE
echo
echo "${C_BOLD}3. Idle-In-Transaction Triage (Threshold: ${IDLE_TX_THRESHOLD_SEC}s)${C_RST}"
hr

idle_in_tx_list=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT 
  pid, usename, datname, coalesce(client_addr::text, 'local'), 
  date_trunc('second', now() - state_change) AS duration,
  substring(query from 1 for 50)
FROM pg_stat_activity 
WHERE state LIKE 'idle in transaction%' 
  AND now() - state_change > interval '$IDLE_TX_THRESHOLD_SEC seconds'
ORDER BY state_change ASC;
" 2>/dev/null || echo "")

declare -a IDLE_TX_PIDS=()

if [ -n "$idle_in_tx_list" ]; then
    echo "${C_RED}[WARN] Detected Idle-In-Transaction sessions holding lock pins!${C_RST}"
    printf "%-8s %-12s %-12s %-15s %-10s %-30s\n" "PID" "User" "Database" "Client IP" "Idle Time" "Last Statement Preview"
    hr
    while IFS='|' read -r pid usr db cl_ip dur stmt; do
        printf "%-8s %-12.12s %-12.12s %-15s %-10s %-30s\n" "$pid" "$usr" "$db" "$cl_ip" "$dur" "$stmt"
        IDLE_TX_PIDS+=("$pid")
    done <<< "$idle_in_tx_list"
else
    echo "${C_GRN}[PASS]${C_RST} No long-running idle-in-transaction sessions found."
fi
hr

# 4. LONG-RUNNING ACTIVE QUERIES
echo
echo "${C_BOLD}4. Slow Running Active Queries (Threshold: ${LONG_QUERY_THRESHOLD_SEC}s)${C_RST}"
hr

long_query_list=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT 
  pid, usename, datname, date_trunc('second', now() - query_start) AS duration,
  wait_event_type || ': ' || wait_event,
  substring(query from 1 for 50)
FROM pg_stat_activity 
WHERE state = 'active'
  AND backend_type = 'client backend'
  AND now() - query_start > interval '$LONG_QUERY_THRESHOLD_SEC seconds'
ORDER BY query_start ASC;
" 2>/dev/null || echo "")

declare -a LONG_QUERY_PIDS=()

if [ -n "$long_query_list" ]; then
    echo "${C_RED}[WARN] Detected slow queries active on the engine!${C_RST}"
    printf "%-8s %-12s %-12s %-10s %-18s %-30s\n" "PID" "User" "Database" "Duration" "Wait Event" "Query Preview"
    hr
    while IFS='|' read -r pid usr db dur wait_ev stmt; do
        printf "%-8s %-12.12s %-12.12s %-10s %-18.18s %-30s\n" "$pid" "$usr" "$db" "$dur" "$wait_ev" "$stmt"
        LONG_QUERY_PIDS+=("$pid")
    done <<< "$long_query_list"
else
    echo "${C_GRN}[PASS]${C_RST} No slow-running queries found."
fi
hr

# 5. WAITING FOR LOCK BLOCKS
echo
echo "${C_BOLD}5. Sessions Blocked and Waiting for Locks${C_RST}"
hr

waiting_list=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT 
  pid, usename, datname, date_trunc('second', now() - query_start) AS duration,
  wait_event, substring(query from 1 for 50)
FROM pg_stat_activity 
WHERE wait_event_type = 'Lock'
ORDER BY duration DESC;
" 2>/dev/null || echo "")

if [ -n "$waiting_list" ]; then
    echo "${C_RED}[WARN] Found sessions blocked on relation locks!${C_RST}"
    printf "%-8s %-12s %-12s %-10s %-15s %-30s\n" "PID" "User" "Database" "Wait Time" "Lock Wait Type" "Blocked Query Preview"
    hr
    while IFS='|' read -r pid usr db dur wait_ev stmt; do
        printf "%-8s %-12.12s %-12.12s %-10s %-15.15s %-30s\n" "$pid" "$usr" "$db" "$dur" "$wait_ev" "$stmt"
    done <<< "$waiting_list"
    echo
    echo "${C_YEL}Run 'pg_lock_triage.sh' to inspect the full blocker-blocked transaction tree.${C_RST}"
else
    echo "${C_GRN}[PASS]${C_RST} No sessions currently waiting on database locks."
fi
hr

# 6. ORPHANED PREPARED (2PC) TRANSACTIONS
echo
echo "${C_BOLD}6. Orphaned Prepared Transactions (Threshold: ${PREPARED_TX_THRESHOLD_MIN}m)${C_RST}"
hr

prepared_list=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT 
  gid, owner, database, 
  date_trunc('second', now() - prepared) AS age
FROM pg_prepared_xacts 
WHERE now() - prepared > interval '$PREPARED_TX_THRESHOLD_MIN minutes'
ORDER BY prepared ASC;
" 2>/dev/null || echo "")

declare -a PREPARED_GIDS=()

if [ -n "$prepared_list" ]; then
    echo "${C_RED}[WARN] Found orphaned prepared transactions! These block VACUUM cleanup and cause severe bloat.${C_RST}"
    printf "%-25s %-15s %-15s %-12s\n" "Global ID (GID)" "Owner" "Database" "Prepared Age"
    hr
    while IFS='|' read -r gid own db age; do
        printf "%-25.25s %-15.15s %-15.15s %-12s\n" "$gid" "$own" "$db" "$age"
        PREPARED_GIDS+=("$gid")
    done <<< "$prepared_list"
else
    echo "${C_GRN}[PASS]${C_RST} No long-running prepared transactions found."
fi
hr

# 7. SLOW BACKGROUND PROCESSES (AUTOVACUUM RUNAWAY WORKERS)
echo
echo "${C_BOLD}7. Running Autovacuum & Background Workers (> 15m)${C_RST}"
hr

bg_workers=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT 
  pid, date_trunc('second', now() - query_start) AS duration, query 
FROM pg_stat_activity 
WHERE query LIKE 'autovacuum:%' 
  AND now() - query_start > interval '15 minutes'
ORDER BY query_start ASC;
" 2>/dev/null || echo "")

if [ -n "$bg_workers" ]; then
    echo "${C_YEL}[WARN] Autovacuum workers are taking a long time to complete:${C_RST}"
    printf "%-8s %-12s %-50s\n" "PID" "Duration" "Worker Process Activity"
    hr
    while IFS='|' read -r pid dur q; do
        printf "%-8s %-12s %-50s\n" "$pid" "$dur" "$q"
    done <<< "$bg_workers"
else
    echo "${C_GRN}[PASS]${C_RST} No runaway autovacuum workers detected."
fi
hr

# 8. REMEDIATION SUGGESTIONS
echo
echo "${C_BOLD}8. Actionable Recovery Plan${C_RST}"
hr

REMEDY_COUNT=0

if [ ${#IDLE_TX_PIDS[@]} -gt 0 ]; then
    ((REMEDY_COUNT++))
    echo "  -- [ISSUE: Idle-In-Transaction Sessions]"
    echo "     To gracefully release lock locks, terminate the idle backends:"
    for pid in "${IDLE_TX_PIDS[@]}"; do
        echo "     SELECT pg_terminate_backend($pid); -- terminates connection"
    done
    echo
fi

if [ ${#LONG_QUERY_PIDS[@]} -gt 0 ]; then
    ((REMEDY_COUNT++))
    echo "  -- [ISSUE: Long-Running Queries]"
    echo "     Cancel the query execution cleanly (retains client connection):"
    for pid in "${LONG_QUERY_PIDS[@]}"; do
        echo "     SELECT pg_cancel_backend($pid); -- cancels executing query"
    done
    echo
fi

if [ ${#PREPARED_GIDS[@]} -gt 0 ]; then
    ((REMEDY_COUNT++))
    echo "  -- [ISSUE: Orphaned Prepared Transactions]"
    echo "     Resolve or rollback the transactions to allow autovacuum to reclaim space:"
    for gid in "${PREPARED_GIDS[@]}"; do
        echo "     ROLLBACK PREPARED '$gid';"
    done
    echo
fi

if [ "$REMEDY_COUNT" -eq 0 ]; then
    echo "${C_GRN}[PASS]${C_RST} No process anomalies flagged. Database is running smoothly."
fi
hr
echo
