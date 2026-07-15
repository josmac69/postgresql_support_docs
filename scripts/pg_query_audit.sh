#!/bin/bash
# ============================================================================
# SCRIPT: pg_query_audit.sh
# DESCRIPTION:
#   Zero-dependency database diagnostic script that connects to a PostgreSQL instance
#   to audit query performance and index optimization. Identifies slow queries, missing
#   or duplicate indexes, invalid indexes, primary key omissions, stale stats, and cache hits.
#
# PARAMETERS CHECKED:
#   - Slow queries: pg_stat_statements extension presence, calls, execution time, and shared block reads.
#   - Scan patterns: Large tables dominated by sequential scans (seq_scan vs idx_scan).
#   - Index health: Unused indexes, duplicate index definitions, and invalid indexes (failed concurrent builds).
#   - Schema: Tables missing primary keys.
#   - Planner stats: Analyzer age (last_analyze / last_autoanalyze) and modified rows counter.
#   - Buffer cache: Heap and index block cache hit ratios.
#
# RECOMMENDATIONS & RATIONALE:
#   - If pg_stat_statements is missing: Recommends preloading the library and creating the extension.
#     Rationale: Without query tracking, finding resource-hogging or slow-executing queries is impossible.
#   - If large tables have high sequential scans: Recommends analyzing queries and creating indexes concurrently.
#     Rationale: Sequential scans read entire tables from disk, consuming CPU and disk I/O, slowing queries.
#   - If unused or duplicate indexes exist: Recommends dropping them via DROP INDEX CONCURRENTLY.
#     Rationale: Redundant indexes increase write amplification (slowing down DML) and waste disk storage.
#   - If invalid indexes are found: Recommends rebuilding or dropping them. Rationale: Failed concurrent builds
#     leave broken index mappings that are ignored by the planner but still updated on DML writes.
#   - If tables lack primary keys: Recommends adding surrogate key fields. Rationale: Essential for logical
#     replication, indexing, and row deduplication.
#   - If planner stats are stale: Recommends executing ANALYZE. Rationale: Outdated table statistics lead the
#     query planner to select sub-optimal execution plans.
#
# USAGE:
#   ./pg_query_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] [--min-size <MB>] [--min-scans <n>] [--top <n>]
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

hr() { printf '%s\n' "--------------------------------------------------------------------------------"; }

# Peer login wrapper when running under postgres user
if [ "$(id -un)" = "postgres" ]; then
    psql() {
        local args=()
        local i=1
        while [ $i -le $# ]; do
            local arg="${!i}"
            if [ "$arg" = "-h" ]; then
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
SEQSCAN_MIN_MB=10          # only flag seq scans on tables larger than this
SEQSCAN_MIN_COUNT=1000     # ...and scanned sequentially at least this often
TOP_N=10                   # rows shown in "top queries" sections
STALE_STATS_DAYS=7         # analyze older than this = stale

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --host <host>       PostgreSQL host (default: localhost or PGHOST)
  -p, --port <port>       PostgreSQL port (scans 5432-5435 if not set)
  -U, --user <user>       PostgreSQL user (default: postgres or PGUSER)
  -d, --dbname <db>       PostgreSQL database to audit (default: postgres or PGDATABASE)
  --min-size <MB>         Min table size for seq-scan analysis (default: 10)
  --min-scans <n>         Min seq_scan count to flag (default: 1000)
  --top <n>               Rows in top-query listings (default: 10)
  --help                  Show this help menu

Connection env variables (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE) are respected.
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--host) PG_HOST="$2"; shift 2 ;;
        -p|--port) PG_PORT="$2"; shift 2 ;;
        -U|--user) PG_USER="$2"; shift 2 ;;
        -d|--dbname) PG_DBNAME="$2"; shift 2 ;;
        --min-size) SEQSCAN_MIN_MB="$2"; shift 2 ;;
        --min-scans) SEQSCAN_MIN_COUNT="$2"; shift 2 ;;
        --top) TOP_N="$2"; shift 2 ;;
        --help) show_help ;;
        *) echo "Unknown option: $1" >&2; show_help ;;
    esac
done

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

run_query() {
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -c "$1"
}
run_query_at() {
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "$1" 2>/dev/null || echo ""
}

PG_MAJOR=$(run_query_at "SHOW server_version_num;" | cut -c1-2)
[ -z "$PG_MAJOR" ] && PG_MAJOR=14

echo
echo "${C_BOLD}PostgreSQL Query Performance & Index Audit${C_RST}"
hr
echo "Host            : $PG_HOST"
echo "Port            : $CONNECTED_PORT"
echo "Database        : $PG_DBNAME"
echo "Server Major    : $PG_MAJOR"
echo "Triage Rules    : SeqScan tables > ${SEQSCAN_MIN_MB}MB & > ${SEQSCAN_MIN_COUNT} scans | Stale stats > ${STALE_STATS_DAYS}d"
hr

REMEDS=()
remed() { REMEDS+=("$1"); }

# ============================================================================
# 1. PG_STAT_STATEMENTS AVAILABILITY & TOP QUERIES
# ============================================================================
echo
echo "${C_BOLD}1. Top Resource-Consuming Queries (pg_stat_statements)${C_RST}"
hr

PSS_AVAILABLE=$(run_query_at "SELECT count(*) FROM pg_extension WHERE extname = 'pg_stat_statements';")
PSS_IN_LIBS=$(run_query_at "SELECT CASE WHEN setting LIKE '%pg_stat_statements%' THEN 1 ELSE 0 END FROM pg_settings WHERE name = 'shared_preload_libraries';")

if [ "$PSS_AVAILABLE" = "1" ]; then
    # Column names changed in PG13: total_time -> total_exec_time
    if [ "$PG_MAJOR" -ge 13 ]; then
        TT="total_exec_time"; MT="mean_exec_time"
    else
        TT="total_time"; MT="mean_time"
    fi

    echo "${C_GRN}[OK]${C_RST} pg_stat_statements extension is installed. Top $TOP_N by total execution time:"
    echo
    run_query "
    SELECT
      round(($TT)::numeric, 1) AS \"Total ms\",
      calls AS \"Calls\",
      round(($MT)::numeric, 2) AS \"Mean ms\",
      rows AS \"Rows\",
      round((100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0))::numeric, 1) AS \"Cache Hit %\",
      substring(query from 1 for 60) AS \"Query Preview\"
    FROM pg_stat_statements
    WHERE query NOT ILIKE '%pg_stat_statements%'
    ORDER BY $TT DESC
    LIMIT $TOP_N;
    "
    echo "Top $TOP_N by mean execution time (slowest individual executions, min 5 calls):"
    run_query "
    SELECT
      round(($MT)::numeric, 2) AS \"Mean ms\",
      calls AS \"Calls\",
      round(($TT)::numeric, 1) AS \"Total ms\",
      substring(query from 1 for 60) AS \"Query Preview\"
    FROM pg_stat_statements
    WHERE calls >= 5 AND query NOT ILIKE '%pg_stat_statements%'
    ORDER BY $MT DESC
    LIMIT $TOP_N;
    "
    echo "Top $TOP_N by shared block reads (I/O-heavy queries):"
    run_query "
    SELECT
      shared_blks_read AS \"Blocks Read\",
      calls AS \"Calls\",
      round(($TT)::numeric, 1) AS \"Total ms\",
      substring(query from 1 for 60) AS \"Query Preview\"
    FROM pg_stat_statements
    WHERE query NOT ILIKE '%pg_stat_statements%'
    ORDER BY shared_blks_read DESC
    LIMIT $TOP_N;
    "
else
    echo "${C_YEL}[WARN] pg_stat_statements extension is NOT installed in database '$PG_DBNAME'.${C_RST}"
    if [ "$PSS_IN_LIBS" = "1" ]; then
        echo "The library IS preloaded — only the extension is missing. Fix without restart:"
        echo "   CREATE EXTENSION pg_stat_statements;"
        remed "Enable query statistics: CREATE EXTENSION pg_stat_statements; (library already preloaded, no restart needed)"
    else
        echo "The library is not in shared_preload_libraries. Enabling requires a RESTART:"
        echo "   ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';"
        echo "   -- then: systemctl restart postgresql (justify the outage in your report!)"
        echo "   CREATE EXTENSION pg_stat_statements;"
        remed "Enable pg_stat_statements (requires restart): ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements'; systemctl restart postgresql; CREATE EXTENSION pg_stat_statements;"
    fi
fi
hr

# ============================================================================
# 2. SEQUENTIAL SCANS ON LARGE TABLES (MISSING INDEX CANDIDATES)
# ============================================================================
echo
echo "${C_BOLD}2. Sequential Scans on Large Tables (Missing Index Candidates)${C_RST}"
hr

seqscan_list=$(run_query_at "
SELECT
  schemaname || '.' || relname,
  seq_scan,
  coalesce(idx_scan, 0),
  pg_size_pretty(pg_total_relation_size(relid)),
  n_live_tup
FROM pg_stat_user_tables
WHERE seq_scan > $SEQSCAN_MIN_COUNT
  AND pg_total_relation_size(relid) > $SEQSCAN_MIN_MB * 1024 * 1024
  AND seq_scan > coalesce(idx_scan, 0)
ORDER BY seq_scan * pg_total_relation_size(relid) DESC
LIMIT $TOP_N;
")

if [ -n "$seqscan_list" ]; then
    echo "${C_RED}[WARN] Large tables dominated by sequential scans — likely missing indexes!${C_RST}"
    printf "%-35s %-12s %-12s %-12s %-12s\n" "Table" "Seq Scans" "Idx Scans" "Total Size" "Live Rows"
    hr
    while IFS='|' read -r tbl seq idx size rows; do
        printf "%-35.35s %-12s %-12s %-12s %-12s\n" "$tbl" "$seq" "$idx" "$size" "$rows"
    done <<< "$seqscan_list"
    echo
    echo "To find WHICH columns need indexing, capture a representative query and run:"
    echo "   EXPLAIN (ANALYZE, BUFFERS) <query>;"
    echo "Then create the index without blocking writes:"
    echo "   CREATE INDEX CONCURRENTLY idx_<table>_<col> ON <table> (<col>);"
    remed "Investigate seq-scanned tables with EXPLAIN (ANALYZE, BUFFERS) and add indexes via CREATE INDEX CONCURRENTLY."
else
    echo "${C_GRN}[PASS]${C_RST} No large tables with dominant sequential scan patterns found."
fi
hr

# ============================================================================
# 3. UNUSED INDEXES (WASTED WRITE AMPLIFICATION & DISK)
# ============================================================================
echo
echo "${C_BOLD}3. Unused Indexes (Never/Rarely Scanned)${C_RST}"
hr

unused_list=$(run_query_at "
SELECT
  s.schemaname || '.' || s.indexrelname,
  s.schemaname || '.' || s.relname,
  s.idx_scan,
  pg_size_pretty(pg_relation_size(s.indexrelid))
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisprimary
  AND NOT i.indisunique
  AND pg_relation_size(s.indexrelid) > 1024 * 1024
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT $TOP_N;
")

if [ -n "$unused_list" ]; then
    echo "${C_YEL}[WARN] Indexes with ZERO scans since last stats reset (excluding PK/unique):${C_RST}"
    printf "%-40s %-30s %-10s %-10s\n" "Index" "Table" "Scans" "Size"
    hr
    while IFS='|' read -r idx tbl scans size; do
        printf "%-40.40s %-30.30s %-10s %-10s\n" "$idx" "$tbl" "$scans" "$size"
    done <<< "$unused_list"
    echo
    echo "CAUTION: verify stats have been collected long enough (check pg_stat_reset time)"
    echo "and that the index is not used only by rare jobs (month-end reports)."
    echo "Drop safely without blocking:"
    echo "   DROP INDEX CONCURRENTLY <schema>.<index_name>;"
    remed "Review and drop unused indexes with DROP INDEX CONCURRENTLY (verify against stats-reset age and periodic workloads first)."
else
    echo "${C_GRN}[PASS]${C_RST} No sizeable unused non-unique indexes detected."
fi

STATS_RESET=$(run_query_at "SELECT coalesce(to_char(stats_reset, 'YYYY-MM-DD HH24:MI'), 'never (since initdb)') FROM pg_stat_database WHERE datname = current_database();")
echo "Statistics last reset for this database: ${STATS_RESET:-unknown}"
hr

# ============================================================================
# 4. DUPLICATE INDEXES (IDENTICAL COLUMN DEFINITIONS)
# ============================================================================
echo
echo "${C_BOLD}4. Duplicate Indexes${C_RST}"
hr

dup_list=$(run_query_at "
SELECT
  pg_size_pretty(sum(pg_relation_size(idx))::bigint),
  array_agg(idx::text ORDER BY idx) AS dup_group
FROM (
  SELECT indexrelid::regclass AS idx,
         (indrelid::text || E'\n' || indclass::text || E'\n' || indkey::text || E'\n' ||
          coalesce(indexprs::text,'') || E'\n' || coalesce(indpred::text,'')) AS key
  FROM pg_index
) sub
GROUP BY key
HAVING count(*) > 1;
")

if [ -n "$dup_list" ]; then
    echo "${C_RED}[WARN] Duplicate index groups found (identical definitions):${C_RST}"
    while IFS='|' read -r size grp; do
        echo "  Wasted size: $size  ->  Group: $grp"
    done <<< "$dup_list"
    echo
    echo "Keep one index per group and drop the rest:"
    echo "   DROP INDEX CONCURRENTLY <redundant_index_name>;"
    remed "Drop redundant duplicate indexes with DROP INDEX CONCURRENTLY (keep one per duplicate group)."
else
    echo "${C_GRN}[PASS]${C_RST} No exact duplicate indexes found."
fi
hr

# ============================================================================
# 5. INVALID INDEXES (FAILED CONCURRENT BUILDS)
# ============================================================================
echo
echo "${C_BOLD}5. Invalid Indexes (Broken CONCURRENTLY Builds)${C_RST}"
hr

invalid_list=$(run_query_at "
SELECT n.nspname || '.' || c.relname, pg_size_pretty(pg_relation_size(c.oid))
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT i.indisvalid;
")

if [ -n "$invalid_list" ]; then
    echo "${C_RED}[CRIT] Invalid indexes found! They consume disk and write overhead but are NEVER used by the planner:${C_RST}"
    while IFS='|' read -r idx size; do
        echo "  - $idx ($size)"
        echo "    Fix option A (rebuild): REINDEX INDEX CONCURRENTLY $idx;"
        echo "    Fix option B (remove) : DROP INDEX CONCURRENTLY $idx;"
    done <<< "$invalid_list"
    remed "Rebuild or drop invalid indexes: REINDEX INDEX CONCURRENTLY <idx>; or DROP INDEX CONCURRENTLY <idx>;"
else
    echo "${C_GRN}[PASS]${C_RST} No invalid indexes present."
fi
hr

# ============================================================================
# 6. TABLES WITHOUT PRIMARY KEYS
# ============================================================================
echo
echo "${C_BOLD}6. Tables Without Primary Keys${C_RST}"
hr

nopk_list=$(run_query_at "
SELECT n.nspname || '.' || c.relname, pg_size_pretty(pg_total_relation_size(c.oid))
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND NOT EXISTS (SELECT 1 FROM pg_constraint con WHERE con.conrelid = c.oid AND con.contype = 'p')
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT $TOP_N;
")

if [ -n "$nopk_list" ]; then
    echo "${C_YEL}[WARN] Tables lacking a primary key (hurts logical replication, dedup, ORM use):${C_RST}"
    while IFS='|' read -r tbl size; do
        echo "  - $tbl ($size)"
    done <<< "$nopk_list"
    echo
    echo "Add a surrogate key without a long lock window (two-step approach):"
    echo "   ALTER TABLE <table> ADD COLUMN id bigint GENERATED ALWAYS AS IDENTITY;"
    echo "   CREATE UNIQUE INDEX CONCURRENTLY <table>_pk_idx ON <table>(id);"
    echo "   ALTER TABLE <table> ADD CONSTRAINT <table>_pkey PRIMARY KEY USING INDEX <table>_pk_idx;"
    remed "Add primary keys to PK-less tables (identity column + CREATE UNIQUE INDEX CONCURRENTLY + PRIMARY KEY USING INDEX)."
else
    echo "${C_GRN}[PASS]${C_RST} All user tables have primary keys."
fi
hr

# ============================================================================
# 7. STALE OR MISSING PLANNER STATISTICS
# ============================================================================
echo
echo "${C_BOLD}7. Stale/Missing Planner Statistics (ANALYZE Age)${C_RST}"
hr

stale_list=$(run_query_at "
SELECT
  schemaname || '.' || relname,
  coalesce(to_char(greatest(last_analyze, last_autoanalyze), 'YYYY-MM-DD HH24:MI'), 'NEVER'),
  n_mod_since_analyze,
  n_live_tup
FROM pg_stat_user_tables
WHERE (greatest(last_analyze, last_autoanalyze) IS NULL AND n_live_tup > 1000)
   OR (greatest(last_analyze, last_autoanalyze) < now() - interval '$STALE_STATS_DAYS days' AND n_mod_since_analyze > n_live_tup * 0.1)
ORDER BY n_mod_since_analyze DESC
LIMIT $TOP_N;
")

if [ -n "$stale_list" ]; then
    echo "${C_YEL}[WARN] Tables with stale or missing statistics (planner may pick bad plans):${C_RST}"
    printf "%-35s %-18s %-15s %-12s\n" "Table" "Last Analyze" "Mods Since" "Live Rows"
    hr
    while IFS='|' read -r tbl last mods rows; do
        printf "%-35.35s %-18s %-15s %-12s\n" "$tbl" "$last" "$mods" "$rows"
    done <<< "$stale_list"
    echo
    echo "Refresh statistics immediately (cheap, non-blocking):"
    echo "   ANALYZE VERBOSE <table>;    -- per table"
    echo "   vacuumdb --analyze-only -d $PG_DBNAME   -- whole database, CLI"
    remed "Refresh stale planner statistics: ANALYZE <table>; or vacuumdb --analyze-only -d $PG_DBNAME"
else
    echo "${C_GRN}[PASS]${C_RST} Planner statistics are reasonably fresh on all active tables."
fi
hr

# ============================================================================
# 8. CACHE HIT RATIOS (BUFFER EFFICIENCY)
# ============================================================================
echo
echo "${C_BOLD}8. Buffer Cache Hit Ratios${C_RST}"
hr
run_query "
SELECT
  'Tables' AS \"Object Type\",
  round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2) AS \"Hit Ratio %\"
FROM pg_statio_user_tables
UNION ALL
SELECT
  'Indexes',
  round(100.0 * sum(idx_blks_hit) / nullif(sum(idx_blks_hit) + sum(idx_blks_read), 0), 2)
FROM pg_statio_user_indexes;
"
echo "Interpretation: OLTP workloads should stay above ~99%. Persistently lower"
echo "ratios mean the working set exceeds shared_buffers — run pg_tune_audit.sh"
echo "for shared_buffers sizing before adding indexes blindly."
hr

# ============================================================================
# 9. SUMMARY REMEDIATION PLAN
# ============================================================================
echo
echo "${C_BOLD}9. Actionable Optimization Plan${C_RST}"
hr
if [ ${#REMEDS[@]} -eq 0 ]; then
    echo "${C_GRN}[PASS]${C_RST} No query-layer anomalies flagged. Schema and statistics look healthy."
else
    i=1
    for r in "${REMEDS[@]}"; do
        printf "  %2d. %s\n" "$i" "$r"
        i=$((i+1))
    done
fi
hr
echo
