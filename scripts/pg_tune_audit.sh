#!/usr/bin/env bash
# ============================================================================
# SCRIPT: pg_tune_audit.sh
# DESCRIPTION:
#   Discovers system resources and audits the active PostgreSQL configuration
#   (either via direct DB connection or parsing a postgresql.conf file).
#   Assigns OK/WARN/FIX flags based on workload heuristics. Read-only diagnostic utility.
#
# PARAMETERS CHECKED:
#   - DB metadata: server version, installed extensions list, database sizes,
#     recovery role (standby vs primary), standby timeline lag, active replication
#     status, replication slots health.
#   - Memory parameters: shared_buffers, effective_cache_size, maintenance_work_mem,
#     work_mem, wal_buffers.
#   - WAL & Checkpoints: min_wal_size, max_wal_size, checkpoint_completion_target.
#   - Planner & IO: random_page_cost, effective_io_concurrency.
#   - Parallelism: max_worker_processes, max_parallel_workers,
#     max_parallel_workers_per_gather, max_parallel_maintenance_workers.
#   - OS Integration: huge_pages, jit, track_io_timing, data_sync_retry, autovacuum_max_workers.
#
# RECOMMENDATIONS & RATIONALE:
#   - If shared_buffers deviates from ~25% RAM: Recommends adjustment. Rationale:
#     Optimizes memory-caching of table blocks, preventing disk reads.
#   - If effective_cache_size is too low: Recommends ~75% RAM. Rationale: Guides the
#     optimizer on available OS caches to favor index scans over sequential scans.
#   - If work_mem is too low/high: Recommends connection-scaled values. Rationale:
#     Prevents in-memory sort/join operations from spilling to temp disk files while
#     avoiding OOM crashes.
#   - If random_page_cost is at default 4.0 on SSD: Recommends 1.1. Rationale: Tells the
#     planner that random page access on solid-state drives is almost as fast as sequential access.
#   - If checkpoint_completion_target != 0.9: Recommends 0.9. Rationale: Spreads the I/O load
#     of dirty page writing across the checkpoint duration, preventing disk write spikes.
#   - If huge_pages is disabled on >16GB systems: Recommends enabling. Rationale: Reduces
#     kernel page table sizes and CPU address-translation overhead.
#   - If data_sync_retry is set to on: Recommends off. Rationale: Prevents silent
#     data corruption on fsync failure on Linux.
#
# USAGE:
#   ./pg_tune_audit.sh
#   ./pg_tune_audit.sh --profile oltp --connections 200
#   ./pg_tune_audit.sh --conf /etc/postgresql/17/main/postgresql.conf
# ============================================================================


set -u
LC_ALL=C

# ---------- Defaults ----------
PROFILE="mixed"
CONN_OVERRIDE=""
MEM_OVERRIDE=""
CPU_OVERRIDE=""
SSD_OVERRIDE=""
CONF_FILE=""
CONNECTED_PORT=""
PG_DATA_DIR=""

PG_HOST="${PGHOST:-localhost}"
PG_PORT="${PGPORT:-}"
PG_USER="${PGUSER:-postgres}"
PG_DBNAME="${PGDATABASE:-postgres}"

# ---------- colours (disabled if not a tty) ----------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""; C_RST=""
fi

# ---------- warnings collector ----------
WARN_FLAGS=()

# ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

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

row() {
    local label="$1" cur="$2" rec="$3" status="$4" detail="${5:-}"
    local mark col
    case "$status" in
        OK)   mark="OK   "; col="$C_GRN" ;;
        WARN) mark="WARN "; col="$C_YEL"; WARN_FLAGS+=("WARN: $label - $detail (current: $cur)") ;;
        FIX)  mark="FIX  "; col="$C_RED"; WARN_FLAGS+=("FIX: $label - $detail (current: $cur, rec: $rec)") ;;
        INFO) mark="INFO "; col="$C_BLU" ;;
        *)    mark="?    "; col="$C_RST" ;;
    esac
    printf "%s[%s]%s %-34s cur=%-14s rec=%-14s %s\n" \
        "$col" "$mark" "$C_RST" "$label" "${cur:-<unset>}" "${rec:--}" "$detail"
}

ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0<=b+0)}'; }

hr() { printf '%s\n' "--------------------------------------------------------------------------------"; }

get_path_rotational() {
    local target_path="$1"
    target_path=$(realpath "$target_path" 2>/dev/null || echo "$target_path")
    
    while [ ! -d "$target_path" ] && [ "$target_path" != "/" ]; do
        target_path=$(dirname "$target_path")
    done
    
    local dev_name
    dev_name=$(df -P "$target_path" 2>/dev/null | tail -n 1 | awk '{print $1}')
    [ -z "$dev_name" ] && { echo "1"; return; }
    
    local real_dev
    real_dev=$(realpath "$dev_name" 2>/dev/null || echo "$dev_name")
    
    local dev_base
    dev_base=$(basename "$real_dev")
    
    if [[ "$dev_base" =~ ^dm- ]] && [ -d "/sys/block/$dev_base/slaves" ]; then
        local has_rotational=0
        for slave in /sys/block/"$dev_base"/slaves/*; do
            [ -e "$slave" ] || continue
            local slave_name=$(basename "$slave")
            if [ -f "/sys/block/$slave_name/queue/rotational" ]; then
                local rot_val=$(cat "/sys/block/$slave_name/queue/rotational" 2>/dev/null)
                if [ "$rot_val" = "1" ]; then
                    has_rotational=1
                fi
            fi
        done
        echo "$has_rotational"
        return
    fi
    
    local parent_dev="$dev_base"
    if [[ "$dev_base" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        parent_dev="${BASH_REMATCH[1]}"
    elif [[ "$dev_base" =~ ^(mmcblk[0-9]+)p[0-9]+$ ]]; then
        parent_dev="${BASH_REMATCH[1]}"
    elif [[ "$dev_base" =~ ^([a-z]+)[0-9]+$ ]]; then
        parent_dev="${BASH_REMATCH[1]}"
    fi
    
    if [ -f "/sys/block/$parent_dev/queue/rotational" ]; then
        cat "/sys/block/$parent_dev/queue/rotational" 2>/dev/null
    else
        echo "1"
    fi
}

print_db_metadata() {
    [ "$DB_CONNECTED" -eq 0 ] && return
    
    local pg_ver
    pg_ver=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT version();" 2>/dev/null)
    echo "${C_BOLD}PostgreSQL Instance Metadata${C_RST}"
    hr
    printf "Version         : %s\n" "${pg_ver:-Unknown}"
    
    local ext_list
    ext_list=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
        SELECT extname, extversion FROM pg_extension ORDER BY 1;
    " 2>/dev/null)
    if [ -n "$ext_list" ]; then
        echo -n "Extensions      : "
        local first=1
        while IFS='|' read -r extname extversion; do
            [ -z "$extname" ] && continue
            if [ "$first" -eq 1 ]; then
                printf "%s (%s)" "$extname" "$extversion"
                first=0
            else
                printf ", %s (%s)" "$extname" "$extversion"
            fi
        done <<< "$ext_list"
        echo
    else
        echo "Extensions      : None detected or query failed"
    fi

    local total_db_size_bytes
    total_db_size_bytes=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT sum(pg_database_size(oid)) FROM pg_database;" 2>/dev/null)
    if [ -n "$total_db_size_bytes" ] && [ "$total_db_size_bytes" -gt 0 ] 2>/dev/null; then
        local total_db_size_mb=$(( total_db_size_bytes / 1024 / 1024 ))
        local total_db_size_gb
        total_db_size_gb=$(awk -v m="$total_db_size_mb" 'BEGIN{printf "%.1f", m/1024}')
        local ram_gb
        ram_gb=$(awk -v m="$RAM_MB" 'BEGIN{printf "%.1f", m/1024}')
        
        if [ "$total_db_size_mb" -lt 1024 ]; then
            if [ "$total_db_size_mb" -lt "$RAM_MB" ]; then
                printf "Total DB Size   : %s MB (Fits entirely in memory (%s GB)!)\n" "$total_db_size_mb" "$ram_gb"
            else
                printf "Total DB Size   : %s MB (Larger than memory (%s GB); disk I/O performance is critical)\n" "$total_db_size_mb" "$ram_gb"
            fi
        else
            if [ "$total_db_size_mb" -lt "$RAM_MB" ]; then
                printf "Total DB Size   : %s GB (Fits entirely in memory (%s GB)!)\n" "$total_db_size_gb" "$ram_gb"
            else
                printf "Total DB Size   : %s GB (Larger than memory (%s GB); disk I/O performance is critical)\n" "$total_db_size_gb" "$ram_gb"
            fi
        fi
    fi
    
    local in_recovery
    in_recovery=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "
        SELECT pg_is_in_recovery();
    " 2>/dev/null)
    
    if [ "$in_recovery" = "t" ]; then
        printf "Server Role     : Standby (Replica in recovery)\n"
        
        local standby_info
        standby_info=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
            SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), 
                   pg_last_xact_replay_timestamp(),
                   COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())), 0)
        " 2>/dev/null)
        
        if [ -n "$standby_info" ]; then
            IFS='|' read -r rcv_lsn rpl_lsn rpl_time lag_sec <<< "$standby_info"
            printf "  Last WAL Recv : %s\n" "${rcv_lsn:-unknown}"
            printf "  Last WAL Repl : %s\n" "${rpl_lsn:-unknown}"
            printf "  Replay Time   : %s\n" "${rpl_time:-unknown}"
            
            if [ -n "$lag_sec" ]; then
                local lag_sec_int=${lag_sec%.*}
                if [ "$lag_sec_int" -le 10 ]; then
                    printf "  Replay Status : %s[OK]%s Lag: %ss\n" "$C_GRN" "$C_RST" "$lag_sec_int"
                elif [ "$lag_sec_int" -le 60 ]; then
                    printf "  Replay Status : %s[WARN]%s Lag: %ss (Slight lag in replication)\n" "$C_YEL" "$C_RST" "$lag_sec_int"
                else
                    printf "  Replay Status : %s[FIX]%s Lag: %ss (High replication lag! Check network or resource saturation)\n" "$C_RED" "$C_RST" "$lag_sec_int"
                fi
            fi
        fi
    else
        printf "Server Role     : Primary (Writable)\n"
        
        local replica_list
        replica_list=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
            SELECT COALESCE(client_addr::text, 'local'), application_name, state, sync_state,
                   COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), 0)
            FROM pg_stat_replication;
        " 2>/dev/null)
        
        if [ -n "$replica_list" ]; then
            local rep_count=0
            while read -r line; do
                [ -n "$line" ] && ((rep_count++))
            done <<< "$replica_list"
            
            printf "Active Replicas : %s\n" "$rep_count"
            
            while IFS='|' read -r client app state sync lag_bytes; do
                [ -z "$client" ] && continue
                local lag_str
                if [ -n "$lag_bytes" ]; then
                    if [ "$lag_bytes" -eq 0 ]; then
                        lag_str="0 bytes (Synchronized)"
                    else
                        lag_str="$(awk -v b="$lag_bytes" 'BEGIN{printf "%.1f MB", b/1024/1024}') lag"
                    fi
                else
                    lag_str="unknown lag"
                fi
                
                local replica_status="$C_GRN[OK]$C_RST"
                if [ "$state" != "streaming" ]; then
                    replica_status="$C_YEL[WARN]$C_RST (state: $state)"
                fi
                
                printf "  - %-15s (%s) state=%s sync=%s status=%s %s\n" \
                    "$client" "${app:-unknown}" "$state" "$sync" "$replica_status" "$lag_str"
            done <<< "$replica_list"
        else
            printf "Active Replicas : 0\n"
        fi
        
        local slots_list
        slots_list=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
            SELECT slot_name, slot_type, active, wal_status
            FROM pg_replication_slots;
        " 2>/dev/null)
        
        if [ -n "$slots_list" ]; then
            printf "Replica Slots   :\n"
            while IFS='|' read -r slot_name slot_type active wal_status; do
                [ -z "$slot_name" ] && continue
                local slot_health="$C_GRN[OK]$C_RST"
                if [ "$active" = "f" ]; then
                    slot_health="$C_RED[FIX]$C_RST (Inactive - risks disk exhaustion by retaining WALs!)"
                fi
                if [ "$wal_status" = "lost" ]; then
                    slot_health="$C_RED[FIX]$C_RST (Lost - WAL segment already recycled!)"
                fi
                printf "  - %-20s type=%s active=%s wal=%s status=%s\n" \
                    "$slot_name" "$slot_type" "$active" "${wal_status:-unknown}" "$slot_health"
            done <<< "$slots_list"
        fi
    fi
    hr
}

compare_huge_pages() {
    local cur="$1" rec="$2"
    
    local req_pages=$(( (rec_shared_buffers * 1024) / LINUX_HUGEPAGE_SIZE_KB ))
    local cur_sb_mb=0
    if [ "$CUR_shared_buffers" != "<unknown>" ]; then
        cur_sb_mb=$(to_mb "$CUR_shared_buffers")
    fi
    local cur_req_pages=$(( (cur_sb_mb * 1024) / LINUX_HUGEPAGE_SIZE_KB ))
    [ "$cur_req_pages" -le 0 ] && cur_req_pages="$req_pages"

    if [ "$cur" = "<unknown>" ]; then
        row "huge_pages" "<unknown>" "$rec" INFO "Alleviates page table memory consumption for shared_buffers"
        return
    fi

    if [ "$LINUX_NR_HUGEPAGES" -eq 0 ]; then
        if [ "$cur" = "on" ]; then
            row "huge_pages" "$cur" "$rec" FIX "PostgreSQL is set to huge_pages=on, but Linux nr_hugepages is 0! Server will FAIL to start. Set sysctl vm.nr_hugepages=$cur_req_pages."
        elif [ "$cur" = "off" ]; then
            if [ "$rec" = "on" ]; then
                row "huge_pages" "$cur" "$rec" FIX "Huge pages are disabled in PG and not allocated in Linux. Recommended: allocate $req_pages pages in Linux and set huge_pages=on."
            else
                row "huge_pages" "$cur" "$rec" OK "Disabled (aligned with tiny shared_buffers)"
            fi
        else # try
            if [ "$rec" = "on" ]; then
                row "huge_pages" "$cur" "$rec" FIX "PG set to 'try' but Linux nr_hugepages is 0. Falls back to normal pages. Recommended: allocate $req_pages pages in Linux and set huge_pages=on."
            else
                row "huge_pages" "$cur" "$rec" OK "Set to 'try' (falls back to normal pages; ok for small buffers)"
            fi
        fi
    else
        if [ "$LINUX_NR_HUGEPAGES" -lt "$cur_req_pages" ]; then
            if [ "$cur" = "on" ]; then
                row "huge_pages" "$cur" "$rec" FIX "Linux nr_hugepages ($LINUX_NR_HUGEPAGES) is insufficient for shared_buffers! Server will FAIL to start. Increase sysctl vm.nr_hugepages to at least $cur_req_pages."
            else
                row "huge_pages" "$cur" "$rec" FIX "Linux nr_hugepages ($LINUX_NR_HUGEPAGES) is less than required ($cur_req_pages). Increase sysctl vm.nr_hugepages to at least $cur_req_pages."
            fi
        else
            if [ "$cur" = "$rec" ]; then
                row "huge_pages" "$cur" "$rec" OK "Optimal huge pages configuration (Linux nr_hugepages=$LINUX_NR_HUGEPAGES >= $cur_req_pages)"
            elif [ "$cur" = "try" ] && [ "$rec" = "on" ]; then
                row "huge_pages" "$cur" "$rec" FIX "Huge pages are allocated in Linux ($LINUX_NR_HUGEPAGES) but PG is set to 'try'. Change PG to 'on' to guarantee use."
            else
                row "huge_pages" "$cur" "$rec" OK "Huge pages configured correctly (Linux nr_hugepages=$LINUX_NR_HUGEPAGES >= $cur_req_pages)"
            fi
        fi
    fi
}

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -p, --profile <type>    Workload profile: web, oltp, dw, desktop, mixed (default: mixed)
  -c, --connections <num> Target max_connections override
  -m, --mem <size_in_gb>  RAM override in GB
  -cpu, --cpus <num>      CPU core count override
  --ssd <1|0>             1 for SSD, 0 for HDD
  -f, --conf <path>       Parse values from a postgresql.conf file
  -h, --host <host>       PostgreSQL host (default: localhost)
  -p, --port <port>       PostgreSQL port
  -U, --user <user>       PostgreSQL user (default: postgres)
  -d, --dbname <name>     PostgreSQL database name (default: postgres)
  --help                  Show this help text
EOF
    exit 0
}

# ---------- Parse Arguments ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--profile)
            PROFILE="$2"
            shift 2
            ;;
        -c|--connections)
            CONN_OVERRIDE="$2"
            shift 2
            ;;
        -m|--mem)
            MEM_OVERRIDE="$2"
            shift 2
            ;;
        -cpu|--cpus)
            CPU_OVERRIDE="$2"
            shift 2
            ;;
        --ssd)
            SSD_OVERRIDE="$2"
            shift 2
            ;;
        -f|--conf)
            CONF_FILE="$2"
            shift 2
            ;;
        -h|--host)
            PG_HOST="$2"
            shift 2
            ;;
        --port)
            PG_PORT="$2"
            shift 2
            ;;
        -U|--user)
            PG_USER="$2"
            shift 2
            ;;
        -d|--dbname)
            PG_DBNAME="$2"
            shift 2
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help
            ;;
    esac
done

# Validate profile
case "$PROFILE" in
    web|oltp|dw|desktop|mixed) ;;
    *)
        echo "${C_RED}Error: Invalid workload profile '${PROFILE}'. Use: web, oltp, dw, desktop, mixed.${C_RST}" >&2
        exit 1
        ;;
esac

# ---------- Hardware Resource Discovery ----------
if [ -n "$MEM_OVERRIDE" ]; then
    RAM_MB=$(( MEM_OVERRIDE * 1024 ))
    RAM_SOURCE="CLI Override"
else
    RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
    if [ "$RAM_KB" -gt 0 ]; then
        RAM_MB=$(( RAM_KB / 1024 ))
        RAM_SOURCE="Auto-Discovered"
    else
        RAM_MB=4096
        RAM_SOURCE="Fallback Default"
    fi
fi

if [ -n "$CPU_OVERRIDE" ]; then
    CPUS="$CPU_OVERRIDE"
    CPU_SOURCE="CLI Override"
else
    CPUS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo "4")
    CPU_SOURCE="Auto-Discovered"
fi

# ---------- Linux Huge Pages Discovery ----------
LINUX_NR_HUGEPAGES=0
if [ -f "/proc/sys/vm/nr_hugepages" ]; then
    LINUX_NR_HUGEPAGES=$(cat "/proc/sys/vm/nr_hugepages" 2>/dev/null || echo "0")
fi

LINUX_HUGEPAGE_SIZE_KB=2048
if [ -r "/proc/meminfo" ]; then
    hp_size_line=$(grep -i "Hugepagesize" /proc/meminfo 2>/dev/null)
    if [[ "$hp_size_line" =~ ([0-9]+) ]]; then
        LINUX_HUGEPAGE_SIZE_KB="${BASH_REMATCH[1]}"
    fi
fi

# ---------- PostgreSQL config parser helper ----------
parse_conf_file() {
    local conf_file="$1"
    awk '
    /^[[:space:]]*[a-zA-Z0-9_]+[[:space:]]*=/ {
        split($0, parts, "=")
        param = parts[1]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", param)
        val = parts[2]
        gsub(/[#].*$/, "", val)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        gsub(/^[\047\042]|[\047\042]$/, "", val)
        print param " " val
    }
    ' "$conf_file"
}

# ---------- Initialize current settings to unknown ----------
for param in shared_buffers effective_cache_size maintenance_work_mem work_mem \
             min_wal_size max_wal_size checkpoint_completion_target wal_buffers \
             random_page_cost effective_io_concurrency max_connections \
             max_worker_processes max_parallel_workers max_parallel_workers_per_gather \
             max_parallel_maintenance_workers huge_pages jit autovacuum_max_workers track_io_timing \
             data_sync_retry data_directory; do
    eval "CUR_$param=\"<unknown>\""
done

# ---------- Retrieve Active Configuration ----------
DB_CONNECTED=0
CONF_PARSED=0

if [ -n "$CONF_FILE" ]; then
    if [ ! -r "$CONF_FILE" ]; then
        echo "${C_RED}Error: Cannot read configuration file '${CONF_FILE}'${C_RST}" >&2
        exit 1
    fi
    echo "Parsing parameters from: ${CONF_FILE}"
    while read -r name val; do
        [ -z "$name" ] && continue
        eval "CUR_$name=\"$val\""
    done <<< "$(parse_conf_file "$CONF_FILE")"
    CONF_PARSED=1
else
    # Auto-detect running DB
    PORTS_TO_TRY=()
    if [ -n "$PG_PORT" ]; then
        PORTS_TO_TRY+=("$PG_PORT")
    else
        for p in 5432 5433 5434 5435; do
            if pg_isready -h localhost -p "$p" >/dev/null 2>&1; then
                PORTS_TO_TRY+=("$p")
            fi
        done
        [ ${#PORTS_TO_TRY[@]} -eq 0 ] && PORTS_TO_TRY=(5432)
    fi
    
    for port in "${PORTS_TO_TRY[@]}"; do
        res=$(psql -h "$PG_HOST" -p "$port" -U "$PG_USER" -d "$PG_DBNAME" -At -c "
            SELECT name, setting, unit, vartype 
            FROM pg_settings 
            WHERE name IN (
                'shared_buffers', 'effective_cache_size', 'maintenance_work_mem', 
                'work_mem', 'min_wal_size', 'max_wal_size', 'checkpoint_completion_target',
                'wal_buffers', 'random_page_cost', 'effective_io_concurrency',
                'max_connections', 'max_worker_processes', 'max_parallel_workers',
                'max_parallel_workers_per_gather', 'max_parallel_maintenance_workers',
                'huge_pages', 'jit', 'autovacuum_max_workers', 'track_io_timing',
                'data_sync_retry', 'data_directory'
            );
        " 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$res" ]; then
            DB_CONNECTED=1
            CONNECTED_PORT="$port"
            echo "Connected to running database at ${PG_HOST}:${port} (user: ${PG_USER}, db: ${PG_DBNAME})"
            
            while IFS='|' read -r name setting unit vartype; do
                [ -z "$name" ] && continue
                local_val="$setting"
                if [ "$unit" = "8kB" ]; then
                    local_val=$(awk -v blocks="$setting" 'BEGIN{printf "%.0fMB", (blocks*8)/1024}')
                elif [ "$unit" = "kB" ]; then
                    local_val=$(awk -v kb="$setting" 'BEGIN{printf "%.0fMB", kb/1024}')
                elif [ "$unit" = "MB" ]; then
                    local_val="${setting}MB"
                elif [ "$unit" = "GB" ]; then
                    local_val="${setting}GB"
                fi
                eval "CUR_$name=\"$local_val\""
            done <<< "$res"
            break
        fi
    done
    
    if [ "$DB_CONNECTED" -eq 0 ]; then
        echo "Could not connect to local running database. Run with --conf <path> or check connection variables."
        echo "Proceeding with resource-based recommendations (current values will show as <unknown>)."
    fi
fi

# ---------- Resolve PostgreSQL Data Directory ----------
PG_DATA_DIR="${CUR_data_directory:-}"
if [ -z "$PG_DATA_DIR" ] || [ "$PG_DATA_DIR" = "<unknown>" ]; then
    # Fallback: Check running processes
    pids=$(pgrep -d, -f 'postgres|postmaster' 2>/dev/null || ps -ef | grep -E 'postgres|postmaster' | grep -v grep | awk '{print $2}' | tr '\n' ',')
    if [ -n "$pids" ]; then
        for pid in $(echo "$pids" | tr ',' ' '); do
            cmd=$(cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ')
            if [[ "$cmd" =~ -D[[:space:]]*([^[:space:]]+) ]]; then
                PG_DATA_DIR="${BASH_REMATCH[1]}"
                break
            elif [[ "$cmd" =~ --data-directory[=[:space:]]*([^[:space:]]+) ]]; then
                PG_DATA_DIR="${BASH_REMATCH[1]}"
                break
            fi
        done
    fi
fi

[ -z "$PG_DATA_DIR" ] || [ "$PG_DATA_DIR" = "<unknown>" ] && [ -d "/var/lib/postgresql" ] && PG_DATA_DIR="/var/lib/postgresql"
[ -z "$PG_DATA_DIR" ] || [ "$PG_DATA_DIR" = "<unknown>" ] && PG_DATA_DIR="/"

# ---------- Storage Device Rotational Check ----------
if [ -n "$SSD_OVERRIDE" ]; then
    IS_SSD="$SSD_OVERRIDE"
    SSD_SOURCE="CLI Override"
else
    rot_flag=$(get_path_rotational "$PG_DATA_DIR")
    if [ "$rot_flag" = "0" ]; then
        IS_SSD=1
    else
        IS_SSD=0
    fi
    SSD_SOURCE="Auto-Discovered ($PG_DATA_DIR)"
fi

# ---------- Print Audit Header ----------
echo
echo "${C_BOLD}PostgreSQL Configuration Tuning Audit${C_RST}"
hr
printf "Host            : %s\n" "$(hostname -f 2>/dev/null || hostname)"
printf "Workload Profile: %s\n" "$PROFILE"
printf "Host Memory     : %.1f GB (%s)\n" "$(awk -v m="$RAM_MB" 'BEGIN{printf "%.1f", m/1024}')" "$RAM_SOURCE"
printf "Logical CPUs    : %s (%s)\n" "$CPUS" "$CPU_SOURCE"
printf "Data Directory  : %s\n" "$PG_DATA_DIR"
printf "Storage Device  : %s (%s)\n" "$( [ "$IS_SSD" -eq 1 ] && echo "SSD/NVMe" || echo "HDD (Rotational)" )" "$SSD_SOURCE"
hr

print_db_metadata

# ---------- Resolve Connection Count ----------
if [ -n "$CONN_OVERRIDE" ]; then
    CONNS="$CONN_OVERRIDE"
    CONN_SOURCE="CLI Override"
elif [ "$CUR_max_connections" != "<unknown>" ]; then
    CONNS=$(echo "$CUR_max_connections" | tr -cd '0-9')
    CONN_SOURCE="Active Discovered"
else
    case "$PROFILE" in
        web)     CONNS=200 ;;
        oltp)    CONNS=500 ;;
        dw)      CONNS=40 ;;
        desktop) CONNS=20 ;;
        mixed|*) CONNS=100 ;;
    esac
    CONN_SOURCE="Workload Default"
fi
printf "Audit Connections: %s (%s)\n" "$CONNS" "$CONN_SOURCE"
hr

# ---------- Helper to convert values to MB ----------
to_mb() {
    local val="$1"
    val=$(echo "$val" | tr -d " '\"")
    local val_lc=$(echo "$val" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$val_lc" =~ ^[0-9]+$ ]]; then
        echo "$val"
        return
    fi
    
    if [[ "$val_lc" =~ ^([0-9.]+)[[:space:]]*(kb)$ ]]; then
        awk -v num="${BASH_REMATCH[1]}" 'BEGIN{printf "%.0f", num/1024}'
    elif [[ "$val_lc" =~ ^([0-9.]+)[[:space:]]*(mb|m)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$val_lc" =~ ^([0-9.]+)[[:space:]]*(gb|g)$ ]]; then
        awk -v num="${BASH_REMATCH[1]}" 'BEGIN{printf "%.0f", num*1024}'
    else
        echo "$val" | tr -cd '0-9.'
    fi
}

from_mb() {
    local mb="$1"
    if ge "$mb" 1024; then
        awk -v m="$mb" 'BEGIN{printf "%.0f GB", m/1024}'
    else
        echo "${mb} MB"
    fi
}

# ---------- Heuristics Calculation ----------

# 1. shared_buffers
if [ "$PROFILE" = "desktop" ]; then
    rec_shared_buffers=$(( RAM_MB * 625 / 10000 ))
else
    rec_shared_buffers=$(( RAM_MB / 4 ))
fi

# 2. effective_cache_size
if [ "$PROFILE" = "desktop" ]; then
    rec_effective_cache_size=$(( RAM_MB / 4 ))
else
    rec_effective_cache_size=$(( RAM_MB * 3 / 4 ))
fi

# 3. maintenance_work_mem
if [ "$PROFILE" = "dw" ]; then
    rec_maintenance_work_mem=$(( RAM_MB / 8 ))
    [ "$rec_maintenance_work_mem" -gt 4096 ] && rec_maintenance_work_mem=4096
else
    rec_maintenance_work_mem=$(( RAM_MB * 625 / 10000 ))
    [ "$rec_maintenance_work_mem" -gt 2048 ] && rec_maintenance_work_mem=2048
fi
[ "$rec_maintenance_work_mem" -lt 64 ] && rec_maintenance_work_mem=64

# 4. work_mem
free_mem=$(( RAM_MB - rec_shared_buffers ))
case "$PROFILE" in
    web)     rec_work_mem=$(( free_mem / (CONNS * 4) )) ;;
    oltp)    rec_work_mem=$(( free_mem / (CONNS * 2) )) ;;
    dw)      rec_work_mem=$(( free_mem * 2 / (CONNS * 3) )) ;;
    mixed|*) rec_work_mem=$(( free_mem / (CONNS * 3) )) ;;
esac
[ "$rec_work_mem" -lt 4 ] && rec_work_mem=4
[ "$rec_work_mem" -gt 2048 ] && rec_work_mem=2048

# 5. wal_buffers
rec_wal_buffers=$(( rec_shared_buffers * 3 / 100 ))
[ "$rec_wal_buffers" -gt 16 ] && rec_wal_buffers=16
[ "$rec_wal_buffers" -lt 1 ] && rec_wal_buffers=1 # min 1MB if buffers are tiny
[ "$rec_shared_buffers" -ge 512 ] && [ "$rec_wal_buffers" -lt 16 ] && rec_wal_buffers=16 # default 16MB for normal servers

# 6. min/max wal size
if [ "$PROFILE" = "desktop" ]; then
    rec_min_wal_size=100
    rec_max_wal_size=2048
elif [ "$PROFILE" = "dw" ]; then
    rec_min_wal_size=4096
    rec_max_wal_size=65536
else
    rec_min_wal_size=1024
    rec_max_wal_size=10240
fi

# 7. checkpoint_completion_target
rec_checkpoint_completion_target="0.9"

# 8. random_page_cost
if [ "$IS_SSD" -eq 1 ]; then
    rec_random_page_cost="1.1"
else
    rec_random_page_cost="4.0"
fi

# 9. effective_io_concurrency
if [ "$IS_SSD" -eq 1 ]; then
    rec_effective_io_concurrency=200
else
    rec_effective_io_concurrency=2
fi

# 10. Parallel Query Settings
rec_max_worker_processes="$CPUS"
rec_max_parallel_workers="$CPUS"

if [ "$PROFILE" = "desktop" ]; then
    rec_max_parallel_workers_per_gather=2
    rec_max_parallel_maintenance_workers=2
elif [ "$PROFILE" = "dw" ]; then
    rec_max_parallel_workers_per_gather=$(( CPUS / 2 ))
    rec_max_parallel_maintenance_workers=$(( CPUS / 4 ))
    [ "$rec_max_parallel_maintenance_workers" -lt 2 ] && rec_max_parallel_maintenance_workers=2
    [ "$rec_max_parallel_maintenance_workers" -gt 16 ] && rec_max_parallel_maintenance_workers=16
else
    rec_max_parallel_workers_per_gather=$(( CPUS / 2 ))
    [ "$rec_max_parallel_workers_per_gather" -gt 4 ] && rec_max_parallel_workers_per_gather=4
    [ "$rec_max_parallel_workers_per_gather" -lt 2 ] && rec_max_parallel_workers_per_gather=2
    
    rec_max_parallel_maintenance_workers=$(( CPUS / 4 ))
    [ "$rec_max_parallel_maintenance_workers" -gt 4 ] && rec_max_parallel_maintenance_workers=4
    [ "$rec_max_parallel_maintenance_workers" -lt 2 ] && rec_max_parallel_maintenance_workers=2
fi

# 11. huge_pages
if [ "$RAM_MB" -gt 16384 ]; then
    rec_huge_pages="on"
else
    rec_huge_pages="try"
fi

# 12. JIT
if [ "$PROFILE" = "dw" ]; then
    rec_jit="on"
else
    rec_jit="off"
fi

# 13. autovacuum_max_workers
if [ "$CPUS" -gt 8 ]; then
    rec_autovacuum_max_workers=5
else
    rec_autovacuum_max_workers=3
fi

# 14. track_io_timing
rec_track_io_timing="on"

# ============================================================================
# AUDIT & REPORT COMPARATOR
# ============================================================================
echo "${C_BOLD}Auditing Memory Parameters${C_RST}"
hr

compare_mem() {
    local name="$1" cur_raw="$2" rec_val="$3" desc="$4"
    if [ "$cur_raw" = "<unknown>" ]; then
        row "$name" "<unknown>" "$(from_mb "$rec_val")" INFO "$desc"
        return
    fi
    local cur_mb=$(to_mb "$cur_raw")
    local rec_str=$(from_mb "$rec_val")
    
    if ge "$cur_mb" "$(( rec_val * 8 / 10 ))" && le "$cur_mb" "$(( rec_val * 12 / 10 ))"; then
        row "$name" "$cur_raw" "$rec_str" OK "Optimal allocation"
    elif le "$cur_mb" "$(( rec_val / 2 ))"; then
        row "$name" "$cur_raw" "$rec_str" FIX "Significantly low; restricts performance ($desc)"
    elif ge "$cur_mb" "$(( rec_val * 18 / 10 ))"; then
        row "$name" "$cur_raw" "$rec_str" WARN "Excessive value; risks resource starvation ($desc)"
    else
        row "$name" "$cur_raw" "$rec_str" WARN "Suboptimal configuration ($desc)"
    fi
}

compare_mem "shared_buffers" "$CUR_shared_buffers" "$rec_shared_buffers" "Keeps the working set in RAM cache"
compare_mem "effective_cache_size" "$CUR_effective_cache_size" "$rec_effective_cache_size" "Guides planner on available OS caches"
compare_mem "maintenance_work_mem" "$CUR_maintenance_work_mem" "$rec_maintenance_work_mem" "Used by VACUUM, CREATE INDEX, and ALTER"
compare_mem "work_mem" "$CUR_work_mem" "$rec_work_mem" "Memory allocated per-connection sort/join"
compare_mem "wal_buffers" "$CUR_wal_buffers" "$rec_wal_buffers" "Buffering transaction log writes before flush"
echo

echo "${C_BOLD}Auditing WAL & Checkpoints${C_RST}"
hr
compare_mem "min_wal_size" "$CUR_min_wal_size" "$rec_min_wal_size" "Minimum size to retain WAL segments"
compare_mem "max_wal_size" "$CUR_max_wal_size" "$rec_max_wal_size" "Maximum size before triggering checkpoints"

if [ "$CUR_checkpoint_completion_target" = "<unknown>" ]; then
    row "checkpoint_completion_target" "<unknown>" "$rec_checkpoint_completion_target" INFO "Spreads checkpoint writes over time"
else
    if [ "$CUR_checkpoint_completion_target" = "$rec_checkpoint_completion_target" ]; then
        row "checkpoint_completion_target" "$CUR_checkpoint_completion_target" "$rec_checkpoint_completion_target" OK "Optimal write smoothing"
    else
        row "checkpoint_completion_target" "$CUR_checkpoint_completion_target" "$rec_checkpoint_completion_target" FIX "Set to 0.9 to avoid sudden disk write spikes"
    fi
fi
echo

echo "${C_BOLD}Auditing Query Planner & I/O Costs${C_RST}"
hr
if [ "$CUR_random_page_cost" = "<unknown>" ]; then
    row "random_page_cost" "<unknown>" "$rec_random_page_cost" INFO "Tuning ratio for random vs sequential page access"
else
    # parse floats
    if [ "$(echo "$CUR_random_page_cost == $rec_random_page_cost" | bc 2>/dev/null)" = "1" ] || [ "$CUR_random_page_cost" = "$rec_random_page_cost" ]; then
        row "random_page_cost" "$CUR_random_page_cost" "$rec_random_page_cost" OK "Aligned with storage type"
    else
        row "random_page_cost" "$CUR_random_page_cost" "$rec_random_page_cost" FIX "Mismatch with storage type (current assumes slower HDD access)"
    fi
fi

if [ "$CUR_effective_io_concurrency" = "<unknown>" ]; then
    row "effective_io_concurrency" "<unknown>" "$rec_effective_io_concurrency" INFO "Number of simultaneous read requests"
else
    if [ "$CUR_effective_io_concurrency" = "$rec_effective_io_concurrency" ]; then
        row "effective_io_concurrency" "$CUR_effective_io_concurrency" "$rec_effective_io_concurrency" OK "Optimal disk queue depth"
    else
        row "effective_io_concurrency" "$CUR_effective_io_concurrency" "$rec_effective_io_concurrency" FIX "Tweak based on disk queue capabilities"
    fi
fi
echo

echo "${C_BOLD}Auditing Parallel Query & Worker Processes${C_RST}"
hr
compare_num() {
    local name="$1" cur="$2" rec="$3" desc="$4"
    if [ "$cur" = "<unknown>" ]; then
        row "$name" "<unknown>" "$rec" INFO "$desc"
        return
    fi
    local cur_n=$(echo "$cur" | tr -cd '0-9')
    if [ "$cur_n" -eq "$rec" ]; then
        row "$name" "$cur" "$rec" OK "Aligned with core count"
    elif [ "$cur_n" -lt "$(( rec / 2 ))" ]; then
        row "$name" "$cur" "$rec" FIX "Underutilizes core cores ($desc)"
    else
        row "$name" "$cur" "$rec" WARN "Suboptimal parallelism ($desc)"
    fi
}
compare_num "max_worker_processes" "$CUR_max_worker_processes" "$rec_max_worker_processes" "Total background process slots"
compare_num "max_parallel_workers" "$CUR_max_parallel_workers" "$rec_max_parallel_workers" "Total parallel worker threads"
compare_num "max_parallel_workers_per_gather" "$CUR_max_parallel_workers_per_gather" "$rec_max_parallel_workers_per_gather" "Workers per parallel query plan"
compare_num "max_parallel_maintenance_workers" "$CUR_max_parallel_maintenance_workers" "$rec_max_parallel_maintenance_workers" "Workers per index build/vacuum"
echo

echo "${C_BOLD}Auditing Operating System Integration & Auxiliary Settings${C_RST}"
hr
compare_flag() {
    local name="$1" cur="$2" rec="$3" desc="$4"
    if [ "$cur" = "<unknown>" ]; then
        row "$name" "<unknown>" "$rec" INFO "$desc"
        return
    fi
    if [ "$cur" = "$rec" ]; then
        row "$name" "$cur" "$rec" OK "Aligned"
    else
        row "$name" "$cur" "$rec" FIX "$desc"
    fi
}
compare_huge_pages "$CUR_huge_pages" "$rec_huge_pages"
compare_flag "jit" "$CUR_jit" "$rec_jit" "Disable for OLTP/web to save CPU; enable for DW"
compare_flag "track_io_timing" "$CUR_track_io_timing" "$rec_track_io_timing" "Mandatory for diagnosing storage read/write latencies"
compare_flag "data_sync_retry" "$CUR_data_sync_retry" "off" "Must be set to off to prevent silent data corruption on fsync failure"
compare_num "autovacuum_max_workers" "$CUR_autovacuum_max_workers" "$rec_autovacuum_max_workers" "Simultaneous autovacuum processes"

hr
echo "${C_BOLD}Audit Alert Flags Summary${C_RST}"
hr
if [ ${#WARN_FLAGS[@]} -eq 0 ]; then
    echo "${C_GRN}[PASS]${C_RST} Active configuration aligns perfectly with workload specifications."
else
    echo "${C_YEL}[WARN/FIX Flags Raised]${C_RST}"
    for flag in "${WARN_FLAGS[@]}"; do
        if [[ "$flag" =~ ^FIX: ]]; then
            echo "  ${C_RED}[FIX]${C_RST} ${flag#FIX: }"
        else
            echo "  ${C_YEL}[WARN]${C_RST} ${flag#WARN: }"
        fi
    done
fi
echo
echo "${C_BOLD}Legend:${C_RST} [${C_GRN}OK${C_RST}] healthy  [${C_YEL}WARN${C_RST}] potential issue  [${C_RED}FIX${C_RST}] recommendations  [${C_BLU}INFO${C_RST}] specs info"
hr

# ============================================================================
# RECOMMENDED ACTION PLAN
# ============================================================================
echo
echo "${C_BOLD}Recommended Action Plan${C_RST}"
hr
echo "To apply these changes, you can execute the following SQL commands"
echo "inside the database using pg_admin or psql (requires superuser)."
echo "These will write to your postgresql.auto.conf file."
echo

echo "  -- [ONLINE - Reloadable changes]"
echo "  -- Can be applied immediately without interrupting active connections"
echo "  ALTER SYSTEM SET effective_cache_size = '$(from_mb "$rec_effective_cache_size")';"
echo "  ALTER SYSTEM SET maintenance_work_mem = '$(from_mb "$rec_maintenance_work_mem")';"
echo "  ALTER SYSTEM SET work_mem = '$(from_mb "$rec_work_mem")';"
echo "  ALTER SYSTEM SET random_page_cost = $rec_random_page_cost;"
echo "  ALTER SYSTEM SET effective_io_concurrency = $rec_effective_io_concurrency;"
echo "  ALTER SYSTEM SET max_parallel_workers_per_gather = $rec_max_parallel_workers_per_gather;"
echo "  ALTER SYSTEM SET max_parallel_maintenance_workers = $rec_max_parallel_maintenance_workers;"
echo "  ALTER SYSTEM SET jit = '$rec_jit';"
echo "  ALTER SYSTEM SET track_io_timing = '$rec_track_io_timing';"
echo "  -- Command to reload online:"
echo "  -- SELECT pg_reload_conf();"
echo

echo "  -- [OFFLINE - Restart Required]"
echo "  -- Applying these changes requires scheduling a server restart"
echo "  ALTER SYSTEM SET shared_buffers = '$(from_mb "$rec_shared_buffers")';"
echo "  ALTER SYSTEM SET max_connections = $CONNS;"
echo "  ALTER SYSTEM SET wal_buffers = '$(from_mb "$rec_wal_buffers")';"
echo "  ALTER SYSTEM SET min_wal_size = '$(from_mb "$rec_min_wal_size")';"
echo "  ALTER SYSTEM SET max_wal_size = '$(from_mb "$rec_max_wal_size")';"
echo "  ALTER SYSTEM SET max_worker_processes = $rec_max_worker_processes;"
echo "  ALTER SYSTEM SET max_parallel_workers = $rec_max_parallel_workers;"
echo "  ALTER SYSTEM SET huge_pages = '$rec_huge_pages';"
echo "  ALTER SYSTEM SET autovacuum_max_workers = $rec_autovacuum_max_workers;"
echo "  ALTER SYSTEM SET data_sync_retry = 'off';"
echo

# Determine if we need to print Linux kernel huge page commands
req_pages=$(( (rec_shared_buffers * 1024) / LINUX_HUGEPAGE_SIZE_KB ))
cur_sb_mb=0
if [ "$CUR_shared_buffers" != "<unknown>" ]; then
    cur_sb_mb=$(to_mb "$CUR_shared_buffers")
fi
cur_req_pages=$(( (cur_sb_mb * 1024) / LINUX_HUGEPAGE_SIZE_KB ))
[ "$cur_req_pages" -le 0 ] && cur_req_pages="$req_pages"

show_sysctl=0
if [ "$rec_huge_pages" = "on" ] || [ "$CUR_huge_pages" = "on" ]; then
    if [ "$LINUX_NR_HUGEPAGES" -lt "$cur_req_pages" ] || [ "$LINUX_NR_HUGEPAGES" -lt "$req_pages" ]; then
        show_sysctl=1
    fi
fi

if [ "$show_sysctl" -eq 1 ]; then
    echo "  -- [SYSTEM - Linux kernel sysctl changes]"
    echo "  -- Run on the host as root or sudo to allocate required huge pages:"
    echo "  -- sysctl -w vm.nr_hugepages=$req_pages"
    echo "  -- echo \"vm.nr_hugepages = $req_pages\" >> /etc/sysctl.conf"
    echo
fi

echo "Note: Always back up your configuration files before editing!"
echo "      e.g. cp \$(psql -At -c 'show config_file') \$(psql -At -c 'show config_file').bak.\$(date +%s)"
hr
echo
