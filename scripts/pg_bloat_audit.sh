#!/bin/bash
# ============================================================================
# SCRIPT: pg_bloat_audit.sh
# DESCRIPTION:
#   Zero-dependency, portable diagnostics script that connects to a target
#   PostgreSQL database to estimate table and B-Tree index bloat, audits
#   global/table-level autovacuum parameters, and generates a recovery plan.
#
# PARAMETERS CHECKED:
#   - Database sizes: Real table size vs estimated physical size (reltuples & fillfactor).
#   - Index sizing: B-Tree index physical size vs estimated size based on column widths.
#   - Global Autovacuum settings: autovacuum status, autovacuum_max_workers, autovacuum_work_mem,
#     autovacuum_vacuum_cost_limit, autovacuum_vacuum_cost_delay, autovacuum_vacuum_scale_factor.
#   - Custom table overrides: Table reloptions in pg_class.
#   - Large tables (> 1GB) lacking specific table-level vacuum scale factors.
#
# RECOMMENDATIONS & RATIONALE:
#   - If autovacuum is disabled: Recommends enabling immediately. Rationale:
#     Autovacuum is critical to reclaim dead tuples. Disabling it leads to severe bloat and
#     Transaction ID wraparound, which forces database shutdown.
#   - If autovacuum_work_mem is inherited from high maintenance_work_mem: Recommends setting
#     autovacuum_work_mem to 512MB. Rationale: Prevent parallel workers from causing OOM crashes.
#   - If autovacuum_vacuum_cost_limit is too low (e.g. 200): Recommends raising to 1000. Rationale:
#     Prevents autovacuum from being throttled, allowing it to keep up with intensive write loads.
#   - If autovacuum_vacuum_scale_factor is too high (default 20%): Recommends lowering to 5-10% globally
#     and even lower for large tables. Rationale: Large tables should not wait to accumulate massive
#     dead tuples before triggering a vacuum run, as it results in severe disk wasting and slow scans.
#   - If high bloat is detected: Recommends REINDEX INDEX CONCURRENTLY (no write blocks) or VACUUM/pg_repack.
#     Rationale: Physical rebuilding shrinks files and restores optimal index page fill ratios.
#
# USAGE:
#   ./pg_bloat_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>]
#   ./pg_bloat_audit.sh -t 30 -s 10  # 30% bloat, 10MB min size filters
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

# Formatting row helper
row() {
    local label="$1" cur="$2" status="$3" desc="$4"
    local color=""
    case "$status" in
        OK)   color="$C_GRN[OK   ]$C_RST" ;;
        WARN) color="$C_YEL[WARN ]$C_RST" ;;
        FIX)  color="$C_RED[FIX  ]$C_RST" ;;
        INFO) color="$C_BLU[INFO ]$C_RST" ;;
    esac
    printf "%s %-35s %-18s %s\n" "$color" "$label" "$cur" "$desc"
}

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
THRESHOLD=30
MIN_SIZE_MB=10

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --host <host>       PostgreSQL host (default: localhost or PGHOST)
  -p, --port <port>       PostgreSQL port (scans 5432-5435 if not set)
  -U, --user <user>       PostgreSQL user (default: postgres or PGUSER)
  -d, --dbname <db>       PostgreSQL database to audit (default: postgres or PGDATABASE)
  -t, --threshold <pct>   Bloat percentage threshold to report (default: 30)
  -s, --min-size <mb>     Minimum table/index size in MB to report (default: 10)
  --help                  Show this help menu

Connection env variables (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE) are respected.
EOF
    exit 0
}

# Parse CLI arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--host)
            PG_HOST="$2"
            shift 2
            ;;
        -p|--port)
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
        -t|--threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        -s|--min-size)
            MIN_SIZE_MB="$2"
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

MIN_SIZE_BYTES=$(( MIN_SIZE_MB * 1024 * 1024 ))

# Verify psql is installed
if ! command -v psql >/dev/null 2>&1; then
    echo "${C_RED}Error: psql utility is required but not found in PATH.${C_RST}" >&2
    exit 1
fi

# Auto-discover system RAM
RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
if [ "$RAM_KB" -gt 0 ]; then
    RAM_MB=$(( RAM_KB / 1024 ))
else
    RAM_MB=4096
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
    # Verify connection
    res=$(psql -h "$PG_HOST" -p "$port" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT 1;" 2>/dev/null || echo "failed")
    if [ "$res" = "1" ]; then
        DB_CONNECTED=1
        CONNECTED_PORT="$port"
        break
    fi
done

if [ "$DB_CONNECTED" -eq 0 ]; then
    echo "${C_RED}Error: Could not connect to target database at ${PG_HOST} on ports [${PORTS_TO_TRY[*]}].${C_RST}" >&2
    echo "Please check connection variables or pass the correct port/credentials." >&2
    exit 1
fi

echo
echo "${C_BOLD}PostgreSQL Bloat & Autovacuum Audit${C_RST}"
hr
echo "Host            : $PG_HOST"
echo "Port            : $CONNECTED_PORT"
echo "Database        : $PG_DBNAME"
echo "Min Size Filter : $MIN_SIZE_MB MB"
echo "Bloat Threshold : $THRESHOLD %"
hr

# ============================================================================
# 1. DATABASE SIZING & ESTIMATED BLOAT SUMMARY
# ============================================================================
echo
echo "${C_BOLD}Database Sizing & Bloat Summary${C_RST}"
hr

# Query summary stats
summary_res=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
WITH table_bloat AS (
  SELECT
    coalesce(sum(pg_relation_size(c.oid)), 0) AS real_size,
    coalesce(sum(CASE
      WHEN pg_relation_size(c.oid) > 0 THEN
        (CASE WHEN est_tblpages > 0 THEN est_tblpages ELSE 1 END)::bigint * 8192
      ELSE 0
    END), 0) AS est_size
  FROM (
    SELECT
      gp.schemaname,
      gp.tblname,
      ceil( (reltuples / ( (8192 - 24) / (24 + 4 + fillfactor + header_width)::numeric ) ) ) AS est_tblpages
    FROM (
      SELECT
        s.schemaname,
        s.tablename AS tblname,
        coalesce(substring(array_to_string(c.reloptions, ','), 'fillfactor=([0-9]+)')::integer, 100) AS fillfactor,
        coalesce(sum(st.avg_width), 0) AS header_width,
        c.reltuples
      FROM pg_tables s
      JOIN pg_class c ON (c.relname = s.tablename)
      JOIN pg_namespace n ON (n.oid = c.relnamespace AND n.nspname = s.schemaname)
      LEFT JOIN pg_stats st ON (st.schemaname = s.schemaname AND st.tablename = s.tablename)
      WHERE s.schemaname NOT IN ('pg_catalog', 'information_schema')
      GROUP BY s.schemaname, s.tablename, c.reloptions, c.reltuples
    ) gp
  ) s2
  JOIN pg_class c ON (c.relname = s2.tblname)
  JOIN pg_namespace n ON (n.oid = c.relnamespace AND n.nspname = s2.schemaname)
  WHERE c.relkind = 'r'
),
index_bloat AS (
  SELECT
    coalesce(sum(real_size), 0) AS real_size,
    coalesce(sum(est_pages * 8192), 0) AS est_size
  FROM (
    SELECT
      pg_relation_size(c.oid) AS real_size,
      coalesce(ceil(c.reltuples / ( (8192 - 120) / (8 + coalesce(col_width.w, 12) + 4) )), 0) AS est_pages
    FROM pg_indexes i
    JOIN pg_class c ON (c.relname = i.indexname)
    JOIN pg_namespace n ON (n.oid = c.relnamespace AND n.nspname = i.schemaname)
    LEFT JOIN (
      SELECT 
        indrelid, 
        indexrelid, 
        sum(coalesce(st.avg_width, 8)) AS w
      FROM pg_index idx
      JOIN pg_attribute att ON (att.attrelid = idx.indrelid AND att.attnum = ANY(idx.indkey))
      LEFT JOIN pg_stats st ON (st.schemaname = (SELECT nspname FROM pg_namespace n2 JOIN pg_class c2 ON (c2.relnamespace=n2.oid) WHERE c2.oid=idx.indrelid)
                                AND st.tablename = (SELECT relname FROM pg_class WHERE oid=idx.indrelid)
                                AND st.attname = att.attname)
      GROUP BY indrelid, indexrelid
    ) col_width ON (col_width.indexrelid = c.oid)
    WHERE i.schemaname NOT IN ('pg_catalog', 'information_schema')
  ) s_idx
)
SELECT 
  t.real_size AS tbl_real,
  t.real_size - t.est_size AS tbl_bloat,
  i.real_size AS idx_real,
  i.real_size - i.est_size AS idx_bloat
FROM table_bloat t, index_bloat i;
" 2>/dev/null)

if [ -n "$summary_res" ]; then
    IFS='|' read -r tbl_real tbl_bloat idx_real idx_bloat <<< "$summary_res"
    # Ensure they are numeric
    tbl_real=${tbl_real:-0}
    tbl_bloat=${tbl_bloat:-0}
    idx_real=${idx_real:-0}
    idx_bloat=${idx_bloat:-0}
    
    # Calculate totals
    [ "$tbl_bloat" -lt 0 ] && tbl_bloat=0
    [ "$idx_bloat" -lt 0 ] && idx_bloat=0
    
    total_real=$(( tbl_real + idx_real ))
    total_bloat=$(( tbl_bloat + idx_bloat ))
    
    tbl_bloat_pct=0
    [ "$tbl_real" -gt 0 ] && tbl_bloat_pct=$(awk -v b="$tbl_bloat" -v r="$tbl_real" 'BEGIN{printf "%.1f", (b*100)/r}')
    idx_bloat_pct=0
    [ "$idx_real" -gt 0 ] && idx_bloat_pct=$(awk -v b="$idx_bloat" -v r="$idx_real" 'BEGIN{printf "%.1f", (b*100)/r}')
    total_bloat_pct=0
    [ "$total_real" -gt 0 ] && total_bloat_pct=$(awk -v b="$total_bloat" -v r="$total_real" 'BEGIN{printf "%.1f", (b*100)/r}')
    
    # Format sizes pretty
    tbl_real_p=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT pg_size_pretty($tbl_real::bigint)")
    tbl_bloat_p=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT pg_size_pretty($tbl_bloat::bigint)")
    idx_real_p=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT pg_size_pretty($idx_real::bigint)")
    idx_bloat_p=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT pg_size_pretty($idx_bloat::bigint)")
    total_real_p=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT pg_size_pretty($total_real::bigint)")
    total_bloat_p=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT pg_size_pretty($total_bloat::bigint)")
    
    printf "Total Table Size     : %-15s (Estimated Bloat: %s, %s%%)\n" "$tbl_real_p" "$tbl_bloat_p" "$tbl_bloat_pct"
    printf "Total B-Tree Index   : %-15s (Estimated Bloat: %s, %s%%)\n" "$idx_real_p" "$idx_bloat_p" "$idx_bloat_pct"
    printf "Total Database Size  : %-15s (Total Wasted Space: %s, %s%%)\n" "$total_real_p" "$total_bloat_p" "$total_bloat_pct"
else
    echo "Failed to calculate sizing summary."
fi
hr

# ============================================================================
# 2. TOP TABLE BLOAT DETAILS
# ============================================================================
echo
echo "${C_BOLD}Bloated Tables (Top tables > ${MIN_SIZE_MB}MB with >= ${THRESHOLD}% bloat)${C_RST}"
hr
printf "%-10s %-30s %-12s %-12s %-8s %-10s %-15s\n" "Schema" "Table Name" "Real Size" "Bloat Size" "Bloat %" "Dead Tuples" "Last Auto/Vacuum"
hr

# Query table bloat details
table_list=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT
  s2.schemaname,
  s2.tblname AS tablename,
  pg_relation_size(c.oid) AS real_size,
  CASE WHEN pg_relation_size(c.oid) - (CASE WHEN est_tblpages > 0 THEN est_tblpages ELSE 1 END * 8192) > 0 
       THEN pg_relation_size(c.oid) - (CASE WHEN est_tblpages > 0 THEN est_tblpages ELSE 1 END * 8192) 
       ELSE 0 
  END AS bloat_size,
  round((100.0 * (pg_relation_size(c.oid) - CASE WHEN est_tblpages > 0 THEN est_tblpages ELSE 1 END * 8192) / pg_relation_size(c.oid))::numeric, 1) AS bloat_ratio,
  coalesce(st.n_dead_tup, 0) AS dead_tuples,
  coalesce(to_char(greatest(st.last_vacuum, st.last_autovacuum), 'YYYY-MM-DD HH24:MI'), 'never') AS last_vac
FROM (
  SELECT
    gp.schemaname,
    gp.tblname,
    ceil( (reltuples / ( (8192 - 24) / (24 + 4 + fillfactor + header_width)::numeric ) ) ) AS est_tblpages
  FROM (
    SELECT
      s.schemaname,
      s.tablename AS tblname,
      coalesce(substring(array_to_string(c.reloptions, ','), 'fillfactor=([0-9]+)')::integer, 100) AS fillfactor,
      coalesce(sum(st.avg_width), 0) AS header_width,
      c.reltuples
    FROM pg_tables s
    JOIN pg_class c ON (c.relname = s.tablename)
    JOIN pg_namespace n ON (n.oid = c.relnamespace AND n.nspname = s.schemaname)
    LEFT JOIN pg_stats st ON (st.schemaname = s.schemaname AND st.tablename = s.tablename)
    WHERE s.schemaname NOT IN ('pg_catalog', 'information_schema')
    GROUP BY s.schemaname, s.tablename, c.reloptions, c.reltuples
  ) gp
) s2
JOIN pg_class c ON (c.relname = s2.tblname)
JOIN pg_namespace n ON (n.oid = c.relnamespace AND n.nspname = s2.schemaname)
LEFT JOIN pg_stat_user_tables st ON (st.schemaname = s2.schemaname AND st.relname = s2.tblname)
WHERE c.relkind = 'r'
  AND pg_relation_size(c.oid) >= $MIN_SIZE_BYTES
  AND round((100.0 * (pg_relation_size(c.oid) - CASE WHEN est_tblpages > 0 THEN est_tblpages ELSE 1 END * 8192) / pg_relation_size(c.oid))::numeric, 1) >= $THRESHOLD
ORDER BY bloat_size DESC
LIMIT 15;
" 2>/dev/null)

declare -a BLOATED_TABLES=()

if [ -n "$table_list" ]; then
    while IFS='|' read -r schema tablename real_size bloat_size bloat_ratio dead_tuples last_vac; do
        real_p=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT pg_size_pretty($real_size::bigint)")
        bloat_p=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT pg_size_pretty($bloat_size::bigint)")
        printf "%-10.10s %-30.30s %-12s %-12s %-8s %-10s %-15s\n" \
            "$schema" "$tablename" "$real_p" "$bloat_p" "${bloat_ratio}%" "$dead_tuples" "$last_vac"
        
        # Save for Action Plan
        BLOATED_TABLES+=("${schema}.${tablename}|${bloat_ratio}")
    done <<< "$table_list"
else
    echo "No tables exceed size and bloat threshold filters."
fi
hr

# ============================================================================
# 3. TOP B-TREE INDEX BLOAT DETAILS
# ============================================================================
echo
echo "${C_BOLD}Bloated B-Tree Indexes (Top indexes > ${MIN_SIZE_MB}MB with >= ${THRESHOLD}% bloat)${C_RST}"
hr
printf "%-10s %-25s %-25s %-12s %-12s %-8s\n" "Schema" "Table Name" "Index Name" "Real Size" "Bloat Size" "Bloat %"
hr

index_list=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT
  schemaname,
  tablename AS tblname,
  indexname AS idxname,
  real_size,
  bloat_size,
  round(bloat_ratio::numeric, 1) AS bloat_ratio
FROM (
  SELECT
    schemaname,
    tablename,
    indexname,
    real_size,
    est_pages * 8192 AS est_size,
    CASE WHEN real_size - est_pages * 8192 > 0 THEN real_size - est_pages * 8192 ELSE 0 END AS bloat_size,
    CASE WHEN real_size > 0 THEN 100.0 * (real_size - est_pages * 8192) / real_size ELSE 0.0 END AS bloat_ratio
  FROM (
    SELECT
      i.schemaname,
      i.tablename,
      i.indexname,
      pg_relation_size(c.oid) AS real_size,
      coalesce(ceil(c.reltuples / ( (8192 - 120) / (8 + coalesce(col_width.w, 12) + 4) )), 0) AS est_pages
    FROM pg_indexes i
    JOIN pg_class c ON (c.relname = i.indexname)
    JOIN pg_namespace n ON (n.oid = c.relnamespace AND n.nspname = i.schemaname)
    LEFT JOIN (
      SELECT 
        indrelid, 
        indexrelid, 
        sum(coalesce(st.avg_width, 8)) AS w
      FROM pg_index idx
      JOIN pg_attribute att ON (att.attrelid = idx.indrelid AND att.attnum = ANY(idx.indkey))
      LEFT JOIN pg_stats st ON (st.schemaname = (SELECT nspname FROM pg_namespace n2 JOIN pg_class c2 ON (c2.relnamespace=n2.oid) WHERE c2.oid=idx.indrelid)
                                AND st.tablename = (SELECT relname FROM pg_class WHERE oid=idx.indrelid)
                                AND st.attname = att.attname)
      GROUP BY indrelid, indexrelid
    ) col_width ON (col_width.indexrelid = c.oid)
    WHERE i.schemaname NOT IN ('pg_catalog', 'information_schema')
  ) s1
) s2
WHERE real_size >= $MIN_SIZE_BYTES
  AND bloat_ratio >= $THRESHOLD
ORDER BY bloat_size DESC
LIMIT 15;
" 2>/dev/null)

declare -a BLOATED_INDEXES=()

if [ -n "$index_list" ]; then
    while IFS='|' read -r schema tablename indexname real_size bloat_size bloat_ratio; do
        real_p=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT pg_size_pretty($real_size::bigint)")
        bloat_p=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -c "SELECT pg_size_pretty($bloat_size::bigint)")
        printf "%-10.10s %-25.25s %-25.25s %-12s %-12s %-8s\n" \
            "$schema" "$tablename" "$indexname" "$real_p" "$bloat_p" "${bloat_ratio}%"
        
        # Save for Action Plan
        BLOATED_INDEXES+=("${schema}.${indexname}|${bloat_ratio}")
    done <<< "$index_list"
else
    echo "No indexes exceed size and bloat threshold filters."
fi
hr

# ============================================================================
# 4. AUTOVACUUM GLOBAL & TABLE OVERRIDES AUDIT
# ============================================================================
echo
echo "${C_BOLD}Autovacuum Activity & Parameter Audit${C_RST}"
hr

# Query global autovacuum settings
autovacuum_settings=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT name, setting 
FROM pg_settings 
WHERE name IN (
  'autovacuum', 'autovacuum_max_workers', 'autovacuum_vacuum_scale_factor',
  'autovacuum_vacuum_threshold', 'autovacuum_vacuum_cost_limit', 'autovacuum_vacuum_cost_delay',
  'autovacuum_analyze_scale_factor', 'autovacuum_analyze_threshold',
  'maintenance_work_mem', 'autovacuum_work_mem', 'vacuum_cost_limit', 'vacuum_cost_delay'
);
" 2>/dev/null)

# Store settings globally
declare -A G_SETTINGS
if [ -n "$autovacuum_settings" ]; then
    while IFS='|' read -r name setting; do
        G_SETTINGS["$name"]="$setting"
    done <<< "$autovacuum_settings"
fi

# Compare parameters
autovacuum_active="${G_SETTINGS[autovacuum]:-off}"
if [ "$autovacuum_active" = "on" ]; then
    row "autovacuum" "on" OK "Autovacuum daemon is active (Crucial for preventing table/index bloat)"
else
    row "autovacuum" "off" FIX "Autovacuum is DISABLED! Database will experience severe bloat and freeze wrap risks!"
fi

workers="${G_SETTINGS[autovacuum_max_workers]:-3}"
if [ "$workers" -ge 5 ]; then
    row "autovacuum_max_workers" "$workers" OK "Sufficient parallel workers for vacuuming operations"
elif [ "$workers" -ge 3 ]; then
    row "autovacuum_max_workers" "$workers" WARN "Default workers; consider increasing to 5+ for databases with 100+ tables"
else
    row "autovacuum_max_workers" "$workers" FIX "Very few workers; risk of autovacuum queue congestion"
fi

# autovacuum_work_mem vs maintenance_work_mem dependency check
maint_mem_kb="${G_SETTINGS[maintenance_work_mem]:-65536}"
auto_mem_kb="${G_SETTINGS[autovacuum_work_mem]:--1}"
effective_auto_mem_kb=$auto_mem_kb
auto_mem_inherited=0
if [ "$auto_mem_kb" -eq -1 ] 2>/dev/null; then
    effective_auto_mem_kb=$maint_mem_kb
    auto_mem_inherited=1
fi
effective_auto_mem_mb=$(( effective_auto_mem_kb / 1024 ))
maint_mem_mb=$(( maint_mem_kb / 1024 ))

max_potential_auto_mem=$(( workers * effective_auto_mem_mb ))
auto_mem_pct_of_ram=$(( max_potential_auto_mem * 100 / RAM_MB ))

declare -a AUTOVACUUM_RECS=()

if [ "$auto_mem_inherited" -eq 1 ]; then
    if [ "$auto_mem_pct_of_ram" -gt 15 ]; then
        row "autovacuum_work_mem" "-1 (uses ${maint_mem_mb}MB)" FIX "Inherits high maintenance_work_mem. Workers can consume up to ${max_potential_auto_mem}MB (${auto_mem_pct_of_ram}% of RAM)!"
        AUTOVACUUM_RECS+=("ALTER SYSTEM SET autovacuum_work_mem = '512MB'; -- Safeguards memory against parallel workers OOM")
    elif [ "$maint_mem_mb" -gt 1024 ]; then
        row "autovacuum_work_mem" "-1 (uses ${maint_mem_mb}MB)" WARN "Inherits large maintenance_work_mem. Total worker cap is ${max_potential_auto_mem}MB."
        AUTOVACUUM_RECS+=("ALTER SYSTEM SET autovacuum_work_mem = '512MB'; -- Prevents excessive memory spikes")
    else
        row "autovacuum_work_mem" "-1 (uses ${maint_mem_mb}MB)" OK "Inherits maintenance_work_mem (${maint_mem_mb}MB); total worker cap is safe (${max_potential_auto_mem}MB)"
    fi
else
    auto_mem_mb_val=$(( auto_mem_kb / 1024 ))
    if [ "$auto_mem_pct_of_ram" -gt 15 ]; then
        row "autovacuum_work_mem" "${auto_mem_mb_val}MB" FIX "Explicitly high. Workers can consume up to ${max_potential_auto_mem}MB (${auto_mem_pct_of_ram}% of RAM)!"
        AUTOVACUUM_RECS+=("ALTER SYSTEM SET autovacuum_work_mem = '512MB'; -- Reduces target worker memory limit")
    else
        row "autovacuum_work_mem" "${auto_mem_mb_val}MB" OK "Dedicated worker memory allocation is safe"
    fi
fi

# autovacuum_vacuum_cost_limit vs vacuum_cost_limit dependency check
auto_cost_limit="${G_SETTINGS[autovacuum_vacuum_cost_limit]:--1}"
vac_cost_limit="${G_SETTINGS[vacuum_cost_limit]:-200}"
effective_cost_limit=$auto_cost_limit
cost_limit_inherited=0
if [ "$auto_cost_limit" -eq -1 ] 2>/dev/null; then
    effective_cost_limit=$vac_cost_limit
    cost_limit_inherited=1
fi

share_limit=$(( effective_cost_limit / workers ))
if [ "$effective_cost_limit" -le 200 ]; then
    if [ "$cost_limit_inherited" -eq 1 ]; then
        row "autovacuum_cost_limit" "-1 (uses ${vac_cost_limit})" FIX "Inherited cost limit is low. Effective limit per worker is only ${share_limit} units (highly throttles autovacuum)."
    else
        row "autovacuum_cost_limit" "${effective_cost_limit}" FIX "Explicit cost limit is low. Effective limit per worker is only ${share_limit} units (highly throttles autovacuum)."
    fi
    AUTOVACUUM_RECS+=("ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 1000; -- Increases total autovacuum I/O throughput limit")
    AUTOVACUUM_RECS+=("ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 2;   -- Keep low sleep delay (2ms)")
else
    row "autovacuum_cost_limit" "${effective_cost_limit}" OK "Sufficient total cost limit. Effective limit per worker: ${share_limit} units."
fi

# autovacuum_vacuum_cost_delay vs vacuum_cost_delay dependency check
auto_cost_delay="${G_SETTINGS[autovacuum_vacuum_cost_delay]:--1}"
vac_cost_delay="${G_SETTINGS[vacuum_cost_delay]:-0}"
effective_cost_delay=$auto_cost_delay
cost_delay_inherited=0
if [ "$auto_cost_delay" -eq -1 ] 2>/dev/null; then
    effective_cost_delay=$vac_cost_delay
    cost_delay_inherited=1
fi

if [ "$effective_cost_delay" -ge 20 ]; then
    if [ "$cost_delay_inherited" -eq 1 ]; then
        row "autovacuum_cost_delay" "-1 (uses ${vac_cost_delay}ms)" FIX "Inherited delay is too slow (sleeps ${effective_cost_delay}ms). Restricts autovacuum completion rate."
    else
        row "autovacuum_cost_delay" "${effective_cost_delay}ms" FIX "Explicit delay is too slow (sleeps ${effective_cost_delay}ms). Restricts autovacuum completion rate."
    fi
    AUTOVACUUM_RECS+=("ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 2;   -- Accelerates I/O cycles by reducing sleep delay")
else
    row "autovacuum_cost_delay" "${effective_cost_delay}ms" OK "Low cost delay enables fast autovacuum sweeps"
fi

scale_factor="${G_SETTINGS[autovacuum_vacuum_scale_factor]:-0.2}"
if [ "$(awk -v sf="$scale_factor" 'BEGIN{print (sf > 0.10) ? 1 : 0}')" -eq 1 ]; then
    row "autovacuum_vacuum_scale_factor" "$scale_factor" WARN "Default is high (20%); large tables will accumulate excessive bloat before vacuuming"
else
    row "autovacuum_vacuum_scale_factor" "$scale_factor" OK "Optimal scale factor for timely autovacuum triggering"
fi

hr

# ============================================================================
# 5. ALL VACUUM & AUTOVACUUM SETTINGS REFERENCE
# ============================================================================
echo
echo "${C_BOLD}All Vacuum & Autovacuum Settings Reference & Evaluation${C_RST}"
hr
settings_sql="
SELECT
  name AS \"Parameter Name\",
  setting AS \"Current Value\",
  coalesce(unit, '') AS \"Unit\",
  CASE WHEN setting = boot_val THEN 'default' ELSE 'custom' END AS \"Status\",
  CASE
    WHEN name = 'autovacuum' AND setting = 'off' THEN 'FIX: Autovacuum should ALWAYS be enabled!'
    WHEN name = 'autovacuum' AND setting = 'on' THEN 'OK: Enabled'
    
    WHEN name = 'autovacuum_max_workers' AND setting::integer < 3 THEN 'FIX: Too low! Recommend at least 3, ideally 5+'
    WHEN name = 'autovacuum_max_workers' AND setting::integer = 3 THEN 'WARN: Default. Consider increasing to 5+ for large schemas'
    WHEN name = 'autovacuum_max_workers' THEN 'OK'
    
    WHEN name = 'autovacuum_vacuum_scale_factor' AND setting::numeric > 0.1 THEN 'WARN: High (20%). Recommend 0.05-0.10 for large databases'
    WHEN name = 'autovacuum_vacuum_scale_factor' THEN 'OK'
    WHEN name = 'autovacuum_analyze_scale_factor' AND setting::numeric > 0.05 THEN 'WARN: High (10%). Recommend 0.02-0.05 for large databases'
    WHEN name = 'autovacuum_analyze_scale_factor' THEN 'OK'
    
    WHEN name = 'autovacuum_vacuum_cost_delay' AND setting::numeric >= 20 THEN 'FIX: Very slow (20ms+). Recommend 2ms to prevent autovacuum lag'
    WHEN name = 'autovacuum_vacuum_cost_delay' AND setting::numeric = 2 THEN 'OK: Default fast delay (2ms)'
    WHEN name = 'autovacuum_vacuum_cost_delay' THEN 'OK'
    
    WHEN name = 'autovacuum_vacuum_cost_limit' AND setting::integer = -1 THEN 'WARN: Defaults to vacuum_cost_limit (usually 200, shared)'
    WHEN name = 'autovacuum_vacuum_cost_limit' AND setting::integer <= 200 THEN 'WARN: Low cost limit restricts worker throughput. Recommend 500-1000'
    WHEN name = 'autovacuum_vacuum_cost_limit' THEN 'OK'
    
    WHEN name = 'log_autovacuum_min_duration' AND setting::integer = -1 THEN 'WARN: Logging is disabled. Highly recommend 0 (all) or 1000ms'
    WHEN name = 'log_autovacuum_min_duration' THEN 'OK: Logging enabled'
    
    ELSE 'INFO: Standard setting description'
  END AS \"Evaluation\"
FROM pg_settings 
WHERE name LIKE '%vacuum%' OR name LIKE '%autovacuum%' OR name LIKE '%freeze%'
ORDER BY name;
"

if [ -t 1 ]; then
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -c "$settings_sql" | sed \
        -e "s/OK:/${C_GRN}OK${C_RST}:/g" \
        -e "s/WARN:/${C_YEL}WARN${C_RST}:/g" \
        -e "s/FIX:/${C_RED}FIX${C_RST}:/g" \
        -e "s/INFO:/${C_BLU}INFO${C_RST}:/g"
else
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -c "$settings_sql"
fi
hr


# Query Custom Table Overrides
echo "Custom Table Autovacuum Overrides (from pg_class.reloptions):"
custom_tables=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT
  n.nspname || '.' || c.relname AS tablename,
  array_to_string(c.reloptions, ', ') AS options
FROM pg_class c
JOIN pg_namespace n ON (n.oid = c.relnamespace)
WHERE c.reloptions IS NOT NULL AND c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1;
" 2>/dev/null)

if [ -n "$custom_tables" ]; then
    while IFS='|' read -r table options; do
        printf "  %-40s : %s\n" "$table" "$options"
    done <<< "$custom_tables"
else
    echo "  No custom table overrides found."
fi

# Query large tables needing scale factor tuning
echo
echo "Large Tables (> 1 GB) with Default Autovacuum Scale Factor:"
large_tables_default=$(psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "
SELECT
  n.nspname || '.' || c.relname AS tablename,
  pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_namespace n ON (n.oid = c.relnamespace)
WHERE c.relkind = 'r'
  AND pg_relation_size(c.oid) > 1024*1024*1024
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND (c.reloptions IS NULL OR array_to_string(c.reloptions, ',') NOT LIKE '%autovacuum_vacuum_scale_factor%')
ORDER BY pg_relation_size(c.oid) DESC;
" 2>/dev/null)

declare -a LARGE_TABLES_NEEDING_TUNE=()

if [ -n "$large_tables_default" ]; then
    while IFS='|' read -r tablename size; do
        printf "  %-40s : %s (Requires specific table-level vacuum scale factor!)\n" "$tablename" "$size"
        LARGE_TABLES_NEEDING_TUNE+=("$tablename")
    done <<< "$large_tables_default"
else
    echo "  No large tables with default scale factors found."
fi
hr

# ============================================================================
# RECOMMENDED ACTION PLAN
# ============================================================================
echo
echo "${C_BOLD}Recommended Action Plan${C_RST}"
hr

# Check if anything needs to be recommended
has_recs=0

if [ "$autovacuum_active" = "off" ]; then
    echo "  -- [CRITICAL] Enable Autovacuum in your postgresql.conf file:"
    echo "  -- ALTER SYSTEM SET autovacuum = 'on';"
    echo
    has_recs=1
fi

if [ ${#AUTOVACUUM_RECS[@]} -gt 0 ]; then
    echo "  -- [OPTIMIZATION - Vacuum & Autovacuum Dependency Tuning]"
    echo "  -- Adjust settings to prevent memory exhaustion and accelerate autovacuum rates"
    for rec in "${AUTOVACUUM_RECS[@]}"; do
        echo "  $rec"
    done
    echo
    has_recs=1
fi

if [ ${#BLOATED_INDEXES[@]} -gt 0 ]; then
    echo "  -- [ONLINE - Reindex Bloated Indexes]"
    echo "  -- Rebuilds indexes concurrently without blocking active reads/writes"
    for item in "${BLOATED_INDEXES[@]}"; do
        IFS='|' read -r index pct <<< "$item"
        echo "  REINDEX INDEX CONCURRENTLY $index; -- Bloat ratio: ${pct}%"
    done
    echo
    has_recs=1
fi

if [ ${#BLOATED_TABLES[@]} -gt 0 ]; then
    echo "  -- [MAINTENANCE - Rebuild/Clean Bloated Tables]"
    echo "  -- WARNING: VACUUM FULL locks the table. Use pg_repack for zero-downtime rebuilds."
    for item in "${BLOATED_TABLES[@]}"; do
        IFS='|' read -r table pct <<< "$item"
        echo "  VACUUM (ANALYZE, VERBOSE) $table; -- Run light-weight vacuum"
        echo "  -- VACUUM FULL $table; -- Rebuilds table (requires Exclusive Lock! Wasted space: ${pct}%)"
    done
    echo
    has_recs=1
fi

if [ ${#LARGE_TABLES_NEEDING_TUNE[@]} -gt 0 ]; then
    echo "  -- [OPTIMIZATION - Table-Specific Autovacuum Thresholds]"
    echo "  -- Tune autovacuum to trigger sooner on large tables to prevent bloat"
    for table in "${LARGE_TABLES_NEEDING_TUNE[@]}"; do
        echo "  ALTER TABLE $table SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_vacuum_threshold = 100);"
    done
    echo
    has_recs=1
fi

if [ "$has_recs" -eq 0 ]; then
    echo "${C_GRN}[PASS]${C_RST} No action required. Bloat is below thresholds and autovacuum is optimal."
fi

hr
echo
