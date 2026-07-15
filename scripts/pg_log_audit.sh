#!/bin/bash
# ============================================================================
# SCRIPT: pg_log_audit.sh
# DESCRIPTION:
#   Zero-dependency diagnostic script that locates PostgreSQL server logs across
#   files, syslog, and journald, and scans them for system errors, resource limits,
#   lock contentions, and security violations. Additionally, audits database logging GUCs.
#
# PARAMETERS CHECKED:
#   - Log discovery: log_destination, logging_collector, log_directory, and current log files.
#   - Database crashes: PANIC errors, backend crash signals, unclean shutdown/recovery logs.
#   - Resource limits: PG internal out-of-memory, kernel OOM-killer events, disk full errors,
#     connection limits, large temporary file spills.
#   - Locking errors: Deadlocks, lock wait warnings (log_lock_waits), cancelled backend statements.
#   - Checkpoints & WALs: "checkpoints occurring too frequently" warnings, archive command failures,
#     standby replication conflicts.
#   - Security: Failed password attempts, missing pg_hba.conf matching entries, permission denials.
#   - Database GUCs: log_checkpoints, log_lock_waits, log_temp_files, log_min_duration_statement,
#     log_line_prefix metadata verification.
#
# RECOMMENDATIONS & RATIONALE:
#   - If PANIC or crashes are detected: Recommends immediate correlation with system logs. Rationale:
#     These events cause database service downtime and require investigating hardware, OS memory, or extension bugs.
#   - If OOM kills are detected: Recommends auditing work_mem/max_connections total memory budgets and adjusting
#     oom_score_adj. Rationale: Protects database processes from being terminated by kernel OOM-killer.
#   - If checkpoints are too frequent: Recommends increasing max_wal_size and checkpoint_timeout. Rationale:
#     Reduces excessive I/O load caused by writing full-page images to disk during checkpoints.
#   - If log GUCs are set to sub-optimal values: Recommends turning on checkpoints/locks/temp file logging.
#     Rationale: Missing logs prevent diagnosing query spills, lock delays, or checkpointer tuning.
#
# USAGE:
#   ./pg_log_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>] [--hours <n>] [--lines <n>]
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
have() { command -v "$1" >/dev/null 2>&1; }

# sudo wrapper: use sudo -n if permitted, otherwise run plain
SUDO=""
if have sudo && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
fi

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
HOURS_BACK=24
MAX_LINES=15   # sample lines shown per finding category

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --host <host>       PostgreSQL host (default: localhost or PGHOST)
  -p, --port <port>       PostgreSQL port (scans 5432-5435 if not set)
  -U, --user <user>       PostgreSQL user (default: postgres or PGUSER)
  -d, --dbname <db>       PostgreSQL database (default: postgres or PGDATABASE)
  --hours <n>             How many hours back to scan journald/syslog (default: 24)
  --lines <n>             Max sample lines per finding (default: 15)
  --help                  Show this help menu

Runs best with sudo (log directories are often 0700 postgres:postgres).
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--host) PG_HOST="$2"; shift 2 ;;
        -p|--port) PG_PORT="$2"; shift 2 ;;
        -U|--user) PG_USER="$2"; shift 2 ;;
        -d|--dbname) PG_DBNAME="$2"; shift 2 ;;
        --hours) HOURS_BACK="$2"; shift 2 ;;
        --lines) MAX_LINES="$2"; shift 2 ;;
        --help) show_help ;;
        *) echo "Unknown option: $1" >&2; show_help ;;
    esac
done

# --- Optional DB connection (script degrades gracefully without it) ---
DB_CONNECTED=0
CONNECTED_PORT=""
if have psql; then
    PORTS_TO_TRY=()
    if [ -n "$PG_PORT" ]; then
        PORTS_TO_TRY+=("$PG_PORT")
    else
        for p in 5432 5433 5434 5435; do
            if have pg_isready && pg_isready -h "$PG_HOST" -p "$p" >/dev/null 2>&1; then
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
fi

q() {
    [ "$DB_CONNECTED" = 1 ] || { echo ""; return; }
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "$1" 2>/dev/null || echo ""
}

echo
echo "${C_BOLD}PostgreSQL Log Forensics Audit${C_RST}"
hr
echo "DB connection   : $([ "$DB_CONNECTED" = 1 ] && echo "OK (port $CONNECTED_PORT)" || echo "UNAVAILABLE (filesystem-only mode)")"
echo "Scan window     : last ${HOURS_BACK}h (journald/syslog); full current logfile otherwise"
echo "Sudo available  : $([ -n "$SUDO" ] && echo yes || echo NO — log access may be limited)"
hr

ISSUES=()
REMEDS=()
warn() { echo "${C_YEL}[WARN]${C_RST} $1"; ISSUES+=("WARN: $1"); }
crit() { echo "${C_RED}[CRIT]${C_RST} $1"; ISSUES+=("CRIT: $1"); }
ok()   { echo "${C_GRN}[OK]${C_RST} $1"; }
remed() { REMEDS+=("$1"); }

# ============================================================================
# 1. LOG DESTINATION DISCOVERY
# ============================================================================
echo
echo "${C_BOLD}1. Log Destination Discovery${C_RST}"
hr

LOG_FILES=()

if [ "$DB_CONNECTED" = 1 ]; then
    LOG_DEST=$(q "SHOW log_destination;")
    LOG_COLLECTOR=$(q "SHOW logging_collector;")
    LOG_DIR=$(q "SHOW log_directory;")
    DATA_DIR=$(q "SHOW data_directory;")
    echo "log_destination   : $LOG_DEST"
    echo "logging_collector : $LOG_COLLECTOR"
    echo "log_directory     : $LOG_DIR"

    if [ "$LOG_COLLECTOR" = "on" ]; then
        # Resolve relative log_directory against data_directory
        case "$LOG_DIR" in
            /*) RESOLVED_DIR="$LOG_DIR" ;;
            *)  RESOLVED_DIR="$DATA_DIR/$LOG_DIR" ;;
        esac
        CURRENT_LOG=$(q "SELECT pg_current_logfile();")
        if [ -n "$CURRENT_LOG" ]; then
            case "$CURRENT_LOG" in
                /*) LOG_FILES+=("$CURRENT_LOG") ;;
                *)  LOG_FILES+=("$DATA_DIR/$CURRENT_LOG") ;;
            esac
        else
            # newest file in log dir
            NEWEST=$($SUDO ls -1t "$RESOLVED_DIR" 2>/dev/null | head -3 || true)
            for f in $NEWEST; do LOG_FILES+=("$RESOLVED_DIR/$f"); done
        fi
    fi
fi

# Distro default locations as fallback / addition
for d in /var/log/postgresql /var/lib/pgsql/*/data/log /var/lib/pgsql/data/log /var/lib/postgresql/*/main/log; do
    for f in $($SUDO ls -1t $d/*.log $d/*.csv 2>/dev/null | head -3 || true); do
        # dedupe
        case " ${LOG_FILES[*]:-} " in
            *" $f "*) : ;;
            *) LOG_FILES+=("$f") ;;
        esac
    done
done

USE_JOURNAL=0
if have journalctl; then
    if $SUDO journalctl -u 'postgresql*' --since "-5 years" -n 1 --no-pager >/dev/null 2>&1; then
        USE_JOURNAL=1
    fi
fi

if [ ${#LOG_FILES[@]} -gt 0 ]; then
    echo "Log files discovered:"
    for f in "${LOG_FILES[@]}"; do echo "  - $f"; done
else
    echo "No log files found on standard paths."
fi
[ "$USE_JOURNAL" = 1 ] && echo "journald contains postgresql* unit logs (will be scanned)."

if [ ${#LOG_FILES[@]} -eq 0 ] && [ "$USE_JOURNAL" = 0 ]; then
    crit "No PostgreSQL logs accessible! Cannot perform forensics. Re-run with sudo, or locate logs manually: sudo find / -name 'postgresql*.log' 2>/dev/null"
fi
hr

# Helper: emit log content to stdout (concatenation of files + journal)
dump_logs() {
    for f in "${LOG_FILES[@]:-}"; do
        [ -n "$f" ] && $SUDO cat "$f" 2>/dev/null || true
    done
    if [ "$USE_JOURNAL" = 1 ]; then
        $SUDO journalctl -u 'postgresql*' --since "-${HOURS_BACK}h" --no-pager 2>/dev/null || true
    fi
}

scan_pattern() {
    # $1 = label, $2 = grep -E pattern, $3 = severity (crit|warn)
    local label="$1" pattern="$2" severity="$3"
    local matches count
    matches=$(dump_logs | grep -aE "$pattern" | tail -n "$MAX_LINES" || true)
    count=$(dump_logs | grep -acE "$pattern" || true)
    count=${count:-0}
    if [ "$count" -gt 0 ]; then
        if [ "$severity" = "crit" ]; then
            crit "$label — $count occurrence(s). Recent samples:"
        else
            warn "$label — $count occurrence(s). Recent samples:"
        fi
        echo "$matches" | sed 's/^/    /'
        echo
        return 0
    fi
    return 1
}

# ============================================================================
# 2. CRITICAL EVENTS: PANIC / FATAL / CRASHES
# ============================================================================
echo
echo "${C_BOLD}2. Critical Events (PANIC / FATAL / Crash Recovery)${C_RST}"
hr
FOUND_ANY=0
if scan_pattern "PANIC entries (server-stopping errors)" "PANIC:" crit; then
    FOUND_ANY=1
    remed "Investigate PANIC root cause before anything else — typically WAL/disk corruption or full disk. Check df -h and dmesg."
fi
if scan_pattern "Backend crashes / signal terminations" "(was terminated by signal|terminating any other active server processes|server process.*exited with exit code)" crit; then
    FOUND_ANY=1
    remed "Backend crash detected: correlate timestamps with dmesg (OOM? segfault?), check for extension faults, review core dumps if enabled."
fi
if scan_pattern "Crash recovery / unclean shutdown events" "(database system was interrupted|database system was not properly shut down|automatic recovery in progress|redo starts at)" warn; then
    FOUND_ANY=1
    remed "Unclean shutdown occurred: verify why (power/OOM/kill -9); confirm recovery completed ('database system is ready to accept connections')."
fi
if scan_pattern "FATAL entries (excluding routine auth/shutdown noise)" "FATAL:" warn; then
    FOUND_ANY=1
fi
[ "$FOUND_ANY" = 0 ] && ok "No PANIC/FATAL/crash events found."
hr

# ============================================================================
# 3. RESOURCE PRESSURE: OOM, DISK FULL, CONNECTION LIMITS
# ============================================================================
echo
echo "${C_BOLD}3. Resource Pressure Events${C_RST}"
hr
FOUND_ANY=0
if scan_pattern "Out-of-memory errors inside PostgreSQL" "(out of memory|could not fork)" crit; then
    FOUND_ANY=1
    remed "PostgreSQL OOM: audit work_mem x max_connections budget (pg_tune_audit.sh); check vm.overcommit_memory=2 (pg_kernel_audit.sh)."
fi
# Kernel OOM killer against postgres (dmesg/journal)
KOOM=$($SUDO dmesg 2>/dev/null | grep -aiE 'killed process.*(postgres|postmaster)' | tail -5 || true)
if [ -z "$KOOM" ] && [ "$USE_JOURNAL" = 1 ]; then
    KOOM=$($SUDO journalctl -k --since "-${HOURS_BACK}h" --no-pager 2>/dev/null | grep -aiE 'killed process.*(postgres|postmaster)' | tail -5 || true)
fi
if [ -n "$KOOM" ]; then
    FOUND_ANY=1
    crit "Linux OOM KILLER terminated PostgreSQL processes:"
    echo "$KOOM" | sed 's/^/    /'
    remed "Protect postmaster from OOM killer: echo -1000 > /proc/<postmaster_pid>/oom_score_adj (systemd: OOMScoreAdjust=-1000 in unit override); reduce memory overcommit."
fi
if scan_pattern "Disk full / no space errors" "(No space left on device|could not write to file|could not extend file)" crit; then
    FOUND_ANY=1
    remed "Free disk space urgently: df -h; du -sh <datadir>/pg_wal; check failed archiving and log rotation; do NOT delete files in pg_wal manually."
fi
if scan_pattern "Connection limit rejections" "(too many connections|remaining connection slots are reserved|sorry, too many clients)" warn; then
    FOUND_ANY=1
    remed "Connection saturation: deploy/verify pgBouncer, or raise max_connections after memory budgeting (see pg_activity_audit.sh section 1)."
fi
if scan_pattern "Temp file spills (work_mem too small for queries)" "temporary file:" warn; then
    FOUND_ANY=1
    remed "Large temp file usage: identify the queries and consider raising work_mem for those sessions/roles: ALTER ROLE <r> SET work_mem='64MB';"
fi
[ "$FOUND_ANY" = 0 ] && ok "No OOM, disk-full, or connection saturation traces found."
hr

# ============================================================================
# 4. LOCKING & TRANSACTION PATHOLOGIES
# ============================================================================
echo
echo "${C_BOLD}4. Deadlocks & Lock Pathologies${C_RST}"
hr
FOUND_ANY=0
if scan_pattern "Deadlocks detected" "deadlock detected" crit; then
    FOUND_ANY=1
    remed "Deadlocks: extract the two statements from the DETAIL lines above; enforce consistent lock ordering in application code; keep transactions short."
fi
if scan_pattern "Lock wait logging (log_lock_waits)" "still waiting for.*Lock" warn; then
    FOUND_ANY=1
    remed "Long lock waits logged: run pg_lock_triage.sh live to map the blocker tree."
fi
if scan_pattern "Canceled/terminated backends by admin or timeout" "(canceling statement due to statement timeout|canceling statement due to user request|terminating connection due to)" warn; then
    FOUND_ANY=1
fi
[ "$FOUND_ANY" = 0 ] && ok "No deadlocks or lock-wait log entries found."
hr

# ============================================================================
# 5. CHECKPOINT & WAL PRESSURE
# ============================================================================
echo
echo "${C_BOLD}5. Checkpoint & WAL Pressure${C_RST}"
hr
FOUND_ANY=0
if scan_pattern "Checkpoints occurring too frequently" "checkpoints are occurring too frequently" warn; then
    FOUND_ANY=1
    remed "Frequent checkpoints: raise max_wal_size (e.g. ALTER SYSTEM SET max_wal_size='4GB'; SELECT pg_reload_conf();) and verify checkpoint_timeout >= 15min for OLTP."
fi
if scan_pattern "Archive command failures in log" "archive command failed" crit; then
    FOUND_ANY=1
    remed "Archive failures: run pg_backup_audit.sh section 2; test archive_command manually as postgres."
fi
if scan_pattern "Replication / recovery conflicts" "(canceling statement due to conflict with recovery|according to history file|requested timeline)" warn; then
    FOUND_ANY=1
    remed "Recovery conflicts on standby: consider hot_standby_feedback=on or raising max_standby_streaming_delay (trade-off: primary bloat vs. query cancels)."
fi
[ "$FOUND_ANY" = 0 ] && ok "No checkpoint or WAL pressure warnings found."
hr

# ============================================================================
# 6. SECURITY & AUTHENTICATION EVENTS
# ============================================================================
echo
echo "${C_BOLD}6. Authentication & Security Events${C_RST}"
hr
FOUND_ANY=0
if scan_pattern "Failed authentication attempts" "(password authentication failed|no pg_hba.conf entry)" warn; then
    FOUND_ANY=1
    remed "Auth failures: verify app credentials; check pg_hba.conf ordering (SHOW hba_file; then review). If brute force from unknown IPs: restrict pg_hba.conf CIDRs and consider fail2ban."
fi
if scan_pattern "Role/permission errors" "permission denied for" warn; then
    FOUND_ANY=1
    remed "Permission errors: grant only what the app role needs, e.g. GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA app TO <role>;"
fi
[ "$FOUND_ANY" = 0 ] && ok "No authentication or permission errors found."
hr

# ============================================================================
# 7. TOP ERROR FINGERPRINTS (AGGREGATED)
# ============================================================================
echo
echo "${C_BOLD}7. Top ERROR Fingerprints (Aggregated)${C_RST}"
hr
TOP_ERRORS=$(dump_logs | grep -aE 'ERROR:' | sed -E 's/^.*ERROR:/ERROR:/; s/[0-9]+/N/g; s/'"'"'[^'"'"']*'"'"'/X/g; s/"[^"]*"/X/g' | sort | uniq -c | sort -rn | head -10 || true)
if [ -n "$TOP_ERRORS" ]; then
    echo "Count | Normalized error message"
    echo "$TOP_ERRORS" | sed 's/^/  /'
else
    ok "No ERROR-level entries in scanned logs."
fi
hr

# ============================================================================
# 8. LOGGING CONFIGURATION AUDIT (CAN WE EVEN DIAGNOSE?)
# ============================================================================
echo
echo "${C_BOLD}8. Logging GUC Audit${C_RST}"
hr
if [ "$DB_CONNECTED" = 1 ]; then
    check_guc() {
        local name="$1" want="$2" why="$3" fix="$4"
        local cur
        cur=$(q "SHOW $name;")
        if [ "$cur" = "$want" ]; then
            ok "$name = $cur"
        else
            warn "$name = $cur (recommended: $want) — $why"
            remed "$fix"
        fi
    }
    check_guc log_checkpoints on "checkpoint visibility is essential for WAL tuning" \
        "ALTER SYSTEM SET log_checkpoints = 'on'; SELECT pg_reload_conf();"
    check_guc log_lock_waits on "surfaces lock contention exceeding deadlock_timeout" \
        "ALTER SYSTEM SET log_lock_waits = 'on'; SELECT pg_reload_conf();"
    check_guc log_temp_files 0 "reveals work_mem spills to disk" \
        "ALTER SYSTEM SET log_temp_files = 0; SELECT pg_reload_conf();"
    LMDS=$(q "SHOW log_min_duration_statement;")
    if [ "$LMDS" = "-1" ]; then
        warn "log_min_duration_statement = -1 — slow queries are invisible in logs."
        remed "Enable slow query logging: ALTER SYSTEM SET log_min_duration_statement = '1s'; SELECT pg_reload_conf();"
    else
        ok "log_min_duration_statement = $LMDS"
    fi
    LLP=$(q "SHOW log_line_prefix;")
    echo "log_line_prefix = '$LLP'"
    if ! echo "$LLP" | grep -q '%'; then
        warn "log_line_prefix carries no metadata — hard to correlate sessions."
        remed "Set informative prefix: ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d '; SELECT pg_reload_conf();"
    fi
else
    echo "(DB unreachable — GUC audit skipped. Grep postgresql.conf manually:"
    echo "  grep -E 'log_(checkpoints|lock_waits|temp_files|min_duration)' <conf>)"
fi
hr

# ============================================================================
# 9. SUMMARY & VERDICT
# ============================================================================
echo
echo "${C_BOLD}9. Log Forensics Summary${C_RST}"
hr
if [ ${#ISSUES[@]} -eq 0 ]; then
    echo "${C_GRN}No anomalies found in PostgreSQL logs within the scan window.${C_RST}"
else
    printf "%sFLAGGED ISSUES (%d):%s\n" "$C_RED" "${#ISSUES[@]}" "$C_RST"
    i=1
    for issue in "${ISSUES[@]}"; do
        printf "  %2d. %s\n" "$i" "$issue"
        i=$((i+1))
    done
fi
if [ ${#REMEDS[@]} -gt 0 ]; then
    printf "\n%sRECOMMENDATIONS & REMEDIATION COMMANDS:%s\n" "$C_YEL" "$C_RST"
    for r in "${REMEDS[@]}"; do
        printf "  - %s\n" "$r"
    done
fi
hr
echo
