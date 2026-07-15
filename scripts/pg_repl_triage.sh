#!/bin/bash
# ============================================================================
# SCRIPT: pg_repl_triage.sh
# DESCRIPTION:
#   Zero-dependency diagnostic script that audits PostgreSQL streaming replication
#   roles, parameters, archiving status, slot allocation, and verifies TCP network
#   reachability to peer cluster nodes. Read-only diagnostic script.
#
# PARAMETERS CHECKED:
#   - Replication role: Primary vs Standby recovery state, current WAL write/replay LSN.
#   - Configuration: wal_level, max_wal_senders, max_replication_slots, hot_standby,
#     wal_keep_size / wal_keep_segments, primary_conninfo, primary_slot_name.
#   - WAL Archiver: archived/failed counts, last archived/failed WAL filename and timestamp.
#   - Streaming metrics: client IP, sync state, and lag (sent/write/replay) on Primary;
#     receiver status, last message timing, and connection string on Standby.
#   - Replication slots: slot type, active state, restart_lsn, and retained WAL size.
#   - Network reachability: Peer IPs (/etc/hosts, patroni.yml) scanned on ports 5432, 6432,
#     8008, 2379 using non-blocking /dev/tcp connection checks.
#
# RECOMMENDATIONS & RATIONALE:
#   - If wal_level is not replica or logical: Recommends raising it. Rationale: Streaming
#     replication is impossible without sufficient replication metadata in the WAL stream.
#   - If hot_standby is off: Recommends enabling it. Rationale: Standby instances cannot serve
#     read queries if hot_standby is disabled.
#   - If WAL archiving is failing: Recommends testing the archive_command manually. Rationale:
#     Unsent WAL logs accumulate in pg_wal, quickly leading to disk space exhaustion and database PANIC.
#   - If replication slots are inactive: Recommends dropping them via pg_drop_replication_slot().
#     Rationale: Inactive slots force the primary to keep WAL files indefinitely, risking disk exhaustion.
#   - If network probes to peers fail: Recommends checking firewalls and security groups. Rationale:
#     Network blockages prevent primary-standby synchronization, causing replica lag or split-brain.
#
# USAGE:
#   ./pg_repl_triage.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] [--peers <ip1,ip2>]
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
PEER_HOSTS=""

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --host <host>       PostgreSQL host (default: localhost or PGHOST)
  -p, --port <port>       PostgreSQL port (scans 5432-5435 if not set)
  -U, --user <user>       PostgreSQL user (default: postgres or PGUSER)
  -d, --dbname <db>       PostgreSQL database to audit (default: postgres or PGDATABASE)
  --peers <ips>           Comma-separated list of peer IPs/hostnames to scan
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
        --peers) PEER_HOSTS="$2"; shift 2 ;;
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
echo "${C_BOLD}PostgreSQL Replication & Network Audit${C_RST}"
hr
echo "Host            : $PG_HOST"
echo "Port            : $CONNECTED_PORT"
echo "Database        : $PG_DBNAME"
hr

# Helper function to run query
run_query() {
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -c "$1"
}

# 1. RECOVERY STATE & ROLE IDENTIFICATION
echo
echo "${C_BOLD}1. Instance Recovery State & Timeline${C_RST}"
hr
role_res=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT 
  pg_is_in_recovery()::text,
  CASE WHEN pg_is_in_recovery() THEN 'STANDBY (Read-Only)' ELSE 'PRIMARY (Read-Write)' END,
  pg_wal_lsn_diff(pg_current_wal_lsn(), '0/00000000')::text
" 2>/dev/null || psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT 
  pg_is_in_recovery()::text,
  CASE WHEN pg_is_in_recovery() THEN 'STANDBY (Read-Only)' ELSE 'PRIMARY (Read-Write)' END,
  pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '0/00000000')::text
" 2>/dev/null || echo "failed")

IS_STANDBY=0
if [ "$role_res" != "failed" ]; then
    IFS='|' read -r in_recovery role_label cur_lsn <<< "$role_res"
    if [ "$in_recovery" = "true" ]; then
        IS_STANDBY=1
    fi
    echo "Active Role  : $role_label"
    echo "Current LSN  : $cur_lsn"
else
    echo "Failed to identify role."
fi
hr

# 2. KEY REPLICATION PARAMETERS
echo
echo "${C_BOLD}2. Key Configuration Parameters${C_RST}"
hr
run_query "
SELECT 
  name AS \"Parameter\",
  setting AS \"Current Value\",
  boot_val AS \"Default Value\",
  CASE 
    WHEN name = 'wal_level' AND setting != 'replica' AND setting != 'logical' THEN 'FIX: Must be replica or logical for streaming replication'
    WHEN name = 'hot_standby' AND setting = 'off' THEN 'FIX: Standby instances cannot serve read queries if off'
    WHEN name = 'max_wal_senders' AND setting::integer < 2 THEN 'WARN: Low sender capacity. Limit replication targets'
    ELSE 'OK'
  END AS \"Evaluation\"
FROM pg_settings
WHERE name IN (
  'wal_level', 'max_wal_senders', 'max_replication_slots', 
  'hot_standby', 'wal_keep_size', 'wal_keep_segments',
  'primary_conninfo', 'primary_slot_name'
)
ORDER BY name;
"

# 3. WAL ARCHIVER STATUS
echo
echo "${C_BOLD}3. Write-Ahead Log (WAL) Archiver status${C_RST}"
hr
run_query "
SELECT 
  archived_count AS \"Archived Count\",
  failed_count AS \"Failed Count\",
  last_archived_wal AS \"Last Archived WAL\",
  coalesce(to_char(last_archived_time, 'YYYY-MM-DD HH24:MI'), 'never') AS \"Last Archived Time\",
  last_failed_wal AS \"Last Failed WAL\",
  coalesce(to_char(last_failed_time, 'YYYY-MM-DD HH24:MI'), 'never') AS \"Last Failed Time\",
  CASE WHEN failed_count > 0 AND last_failed_time > coalesce(last_archived_time, 'epoch'::timestamp) 
       THEN 'CRITICAL: Archive command is actively failing!' 
       ELSE 'OK' 
  END AS \"Status\"
FROM pg_stat_archiver;
"

# 4. DATA-STREAM ACTIVE VIEW (PRIMARY or STANDBY details)
if [ "$IS_STANDBY" -eq 0 ]; then
    echo
    echo "${C_BOLD}4. Connected Standby Instances (Primary view)${C_RST}"
    hr
    run_query "
    SELECT 
      application_name AS \"App Name\",
      client_addr AS \"Client IP\",
      state AS \"State\",
      sync_state AS \"Sync Mode\",
      pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) AS \"Sent Lag\",
      pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)) AS \"Write Lag\",
      pg_size_pretty(pg_wal_lsn_diff(write_lsn, replay_lsn)) AS \"Replay Lag\"
    FROM pg_stat_replication;
    "
else
    echo
    echo "${C_BOLD}4. Active Replication Receiver State (Standby view)${C_RST}"
    hr
    run_query "
    SELECT 
      status AS \"Status\",
      receive_start_lsn AS \"Start LSN\",
      received_lsn AS \"Received LSN\",
      received_tli AS \"Received Timeline\",
      last_msg_send_time AS \"Last Message Sent\",
      last_msg_receipt_time AS \"Last Message Received\",
      conninfo AS \"Connection Info\"
    FROM pg_stat_wal_receiver;
    "
fi

# 5. REPLICATION SLOTS AUDIT
echo
echo "${C_BOLD}5. Active & Inactive Replication Slots${C_RST}"
hr
run_query "
SELECT 
  slot_name AS \"Slot Name\",
  plugin AS \"Plugin\",
  slot_type AS \"Slot Type\",
  active AS \"Is Active\",
  wal_status AS \"WAL Status\",
  pg_size_pretty(pg_wal_lsn_diff(
    CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END, 
    restart_lsn
  )) AS \"Retained WAL Size\",
  CASE WHEN active = 'f' THEN 'CRITICAL: Slot is inactive but retaining WAL (disks can fill!)' ELSE 'OK' END AS \"Evaluation\"
FROM pg_replication_slots;
"

# 6. PEER NETWORK SCANS (PORT SCANNING VIA /dev/tcp)
echo
echo "${C_BOLD}6. Peer Network Connection Diagnostics${C_RST}"
hr

# Build host list to test:
declare -a HOSTS_TO_TEST=()
if [ -n "$PEER_HOSTS" ]; then
    IFS=',' read -r -a HOSTS_TO_TEST <<< "$PEER_HOSTS"
else
    # Parse peer candidates from /etc/hosts (excluding local loopbacks)
    if [ -r /etc/hosts ]; then
        while read -r ip hostname rest; do
            # Filter valid IPv4 formats and skip localhost
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
               [ "$ip" != "127.0.0.1" ] && [ "$ip" != "127.0.0.53" ] && [ "$ip" != "127.0.0.54" ]; then
                # Check if already added
                if [[ ! " ${HOSTS_TO_TEST[*]} " =~ " ${ip} " ]]; then
                    HOSTS_TO_TEST+=("$ip")
                fi
            fi
        done < <(grep -E '^[0-9]' /etc/hosts)
    fi
    # Also parse Patroni configuration if readable
    for pf in /etc/patroni/patroni.yml /etc/patroni/*.yml /etc/patroni.yml; do
        if [ -r "$pf" ]; then
            while read -r line; do
                if [[ "$line" =~ host:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    ip="${BASH_REMATCH[1]}"
                    if [ "$ip" != "127.0.0.1" ] && [[ ! " ${HOSTS_TO_TEST[*]} " =~ " ${ip} " ]]; then
                        HOSTS_TO_TEST+=("$ip")
                    fi
                fi
            done < "$pf"
        fi
    done
fi

PORTS_TO_SCAN=(5432 6432 8008 2379) # Postgres, pgBouncer, Patroni API, etcd

if [ ${#HOSTS_TO_TEST[@]} -gt 0 ]; then
    printf "%-18s %-6s %-12s %-30s\n" "Target Peer IP" "Port" "TCP Status" "Service Type"
    hr
    for target in "${HOSTS_TO_TEST[@]}"; do
        for port in "${PORTS_TO_SCAN[@]}"; do
            # Translate port to service description
            service="Unknown"
            case "$port" in
                5432) service="PostgreSQL" ;;
                6432) service="pgBouncer Connection Pooler" ;;
                8008) service="Patroni REST API" ;;
                2379) service="etcd DCS Client API" ;;
            esac
            
            # Non-blocking, fast bash TCP probe
            if (timeout 1 bash -c "echo > /dev/tcp/$target/$port") >/dev/null 2>&1; then
                printf "%-18s %-6s ${C_GRN}%-12s${C_RST} %-30s\n" "$target" "$port" "OPEN" "$service"
            else
                printf "%-18s %-6s ${C_RED}%-12s${C_RST} %-30s\n" "$target" "$port" "CLOSED/BLOCKED" "$service"
            fi
        done
        hr
    done
else
    echo "No peer IP targets found in /etc/hosts. Pass custom peers via --peers <ip1,ip2>."
fi

# 7. REMEDIATION SUGGESTIONS
echo
echo "${C_BOLD}7. Actionable Replication Rescue Plan${C_RST}"
hr
if [ "$IS_STANDBY" -eq 1 ]; then
    echo "-- STANDBY NODE RESOLUTION SCHEME"
    echo "-- If replication has broken (standby is not streaming/lagging or timelines diverged):"
    echo
    echo "1. Verify networking to primary host (OPEN status in Section 6 above)."
    echo "2. Check primary_conninfo configurations in postgresql.auto.conf or postgresql.conf."
    echo "3. Rebuild replica from scratch using pg_basebackup (Warning: deletes standby data!):"
    echo "   # Step A: Stop database service"
    echo "     systemctl stop postgresql # or patroni"
    echo "   # Step B: Backup/rename old data directory"
    echo "     mv /var/lib/postgresql/data /var/lib/postgresql/data_broken"
    echo "   # Step C: Re-clone using pg_basebackup"
    echo "     pg_basebackup -h <PRIMARY_IP> -p <PRIMARY_PORT> -U <REPL_USER> -D /var/lib/postgresql/data -P -R -X stream"
    echo "   # Step D: Start database service"
    echo "     systemctl start postgresql"
    echo
    echo "4. Resync standby timeline divergence using pg_rewind (preserves existing data!):"
    echo "   # Standby must be cleanly stopped first"
    echo "     pg_rewind -D /var/lib/postgresql/data --source-server=\"host=<PRIMARY_IP> port=<PRIMARY_PORT> user=postgres\""
else
    echo "-- PRIMARY NODE RESOLUTION SCHEME"
    echo "-- If standby nodes are unable to connect or register:"
    echo
    echo "1. Verify client subnet permissions in pg_hba.conf:"
    echo "   -- Locate file: SHOW hba_file;"
    echo "   -- Add rule (e.g. at bottom of pg_hba.conf):"
    echo "      host replication replication_user 10.0.0.0/24 scram-sha-256"
    echo "   -- Apply config: SELECT pg_reload_conf();"
    echo
    echo "2. Secure orphaned replication slots to prevent disk-full conditions:"
    echo "   -- Remove inactive slots retaining massive WAL logs:"
    echo "      SELECT pg_drop_replication_slot('slot_name');"
fi
hr
echo
