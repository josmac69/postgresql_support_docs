#!/bin/bash
# ============================================================================
# SCRIPT: pg_backup_audit.sh
# DESCRIPTION:
#   Zero-dependency, portable diagnostics script that connects to a target
#   PostgreSQL database and scans the local system to audit backup readiness,
#   WAL archiver health, installed backup tools, data checksums, recovery parameters,
#   and PITR viability.
#
# PARAMETERS CHECKED:
#   - WAL archiving GUCs: wal_level, archive_mode, archive_command, archive_library.
#   - Archiver runtime statistics (pg_stat_archiver, failed vs archived counts).
#   - WAL queue backlog: Count of unarchived .ready segments in pg_wal/archive_status.
#   - Disk consumption: Size of pg_wal directory compared to max_wal_size GUC.
#   - Installed backup engines: Presence of pgBackRest, Barman, or WAL-G and their configs.
#   - Scheduled backup tasks: Cron entries and systemd timers containing backup keywords.
#   - Data integrity settings: data_checksums GUC, pg_stat_database checksum_failures count.
#   - Recovery configuration: restore_command, recovery_target_time, checkpoint_timeout.
#
# RECOMMENDATIONS & RATIONALE:
#   - If wal_level is minimal: Recommends setting wal_level = replica. Rationale:
#     Minimal logging does not write enough WAL details to perform physical backups or PITR.
#   - If archive_mode is off: Recommends setting archive_mode = on. Rationale:
#     WAL archiving is required to reconstruct changes between the base backup and crash event.
#   - If archive_mode is on but archive_command is empty or a no-op (e.g. true): Recommends
#     specifying a real command. Rationale: Empty commands queue WAL files indefinitely, filling
#     the disk, while no-op commands silently discard WALs, breaking recovery chains.
#   - If archiver is failing or backlog > 50 segments: Recommends diagnosing command as the postgres
#     user. Rationale: Unarchived segments clog the pg_wal folder, risking sudden disk full crashes.
#   - If data_checksums = off: Recommends enabling (requires offline cluster). Rationale:
#     Allows early detection of page-level corruption (bit rot, hardware failure) before it spreads.
#   - If checksum_failures > 0: Recommends immediate recovery. Rationale: Confirms active data corruption.
#
# USAGE:
#   ./pg_backup_audit.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>]
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

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --host <host>       PostgreSQL host (default: localhost or PGHOST)
  -p, --port <port>       PostgreSQL port (scans 5432-5435 if not set)
  -U, --user <user>       PostgreSQL user (default: postgres or PGUSER)
  -d, --dbname <db>       PostgreSQL database (default: postgres or PGDATABASE)
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
        --help) show_help ;;
        *) echo "Unknown option: $1" >&2; show_help ;;
    esac
done

if ! have psql; then
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
q() {
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -At -F'|' -c "$1" 2>/dev/null || echo ""
}

echo
echo "${C_BOLD}PostgreSQL Backup & WAL Archiving Audit${C_RST}"
hr
echo "Host            : $PG_HOST"
echo "Port            : $CONNECTED_PORT"
echo "Database        : $PG_DBNAME"
hr

ISSUES=()
REMEDS=()
warn() { echo "${C_YEL}[WARN]${C_RST} $1"; ISSUES+=("WARN: $1"); }
crit() { echo "${C_RED}[CRIT]${C_RST} $1"; ISSUES+=("CRIT: $1"); }
ok()   { echo "${C_GRN}[OK]${C_RST} $1"; }
remed() { REMEDS+=("$1"); }

# ============================================================================
# 1. WAL ARCHIVING CONFIGURATION
# ============================================================================
echo
echo "${C_BOLD}1. WAL Archiving Configuration${C_RST}"
hr

ARCHIVE_MODE=$(q "SHOW archive_mode;")
ARCHIVE_CMD=$(q "SHOW archive_command;")
ARCHIVE_LIB=$(q "SELECT coalesce(setting,'') FROM pg_settings WHERE name = 'archive_library';")
WAL_LEVEL=$(q "SHOW wal_level;")

echo "wal_level       : $WAL_LEVEL"
echo "archive_mode    : $ARCHIVE_MODE"
echo "archive_command : ${ARCHIVE_CMD:-<empty>}"
[ -n "$ARCHIVE_LIB" ] && echo "archive_library : $ARCHIVE_LIB"
echo

if [ "$WAL_LEVEL" = "minimal" ]; then
    crit "wal_level=minimal — physical base backups and PITR are IMPOSSIBLE."
    remed "Set wal_level: ALTER SYSTEM SET wal_level = 'replica'; then restart PostgreSQL (requires outage — justify in report)."
fi

if [ "$ARCHIVE_MODE" = "off" ]; then
    crit "archive_mode=off — no WAL archiving. Point-in-time recovery is NOT possible; only crash recovery from last base backup."
    remed "Enable archiving (restart required): ALTER SYSTEM SET archive_mode = 'on'; ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=main archive-push %p'; systemctl restart postgresql"
elif [ "$ARCHIVE_MODE" != "off" ] && [ -z "$ARCHIVE_CMD" ] && [ -z "$ARCHIVE_LIB" ]; then
    crit "archive_mode is on but archive_command/archive_library is EMPTY — WAL segments accumulate as .ready files and pg_wal can fill the disk!"
    remed "Set an archive command (reload only): ALTER SYSTEM SET archive_command = '<tool command>'; SELECT pg_reload_conf();"
elif echo "$ARCHIVE_CMD" | grep -qE '^(/bin/true|true|cd \.|:)'; then
    warn "archive_command is a no-op ('$ARCHIVE_CMD') — WAL is being discarded, not archived. PITR impossible."
    remed "Replace no-op archive_command with a real one (pgBackRest/barman/WAL-G) and reload: SELECT pg_reload_conf();"
elif [ "$ARCHIVE_MODE" != "off" ]; then
    ok "Archiving configured: mode=$ARCHIVE_MODE, command present."
fi

# ============================================================================
# 2. ARCHIVER RUNTIME HEALTH
# ============================================================================
echo
echo "${C_BOLD}2. WAL Archiver Runtime Health${C_RST}"
hr

arch_stats=$(q "
SELECT archived_count, failed_count,
       coalesce(last_archived_wal, 'none'),
       coalesce(to_char(last_archived_time, 'YYYY-MM-DD HH24:MI:SS'), 'never'),
       coalesce(last_failed_wal, 'none'),
       coalesce(to_char(last_failed_time, 'YYYY-MM-DD HH24:MI:SS'), 'never'),
       CASE WHEN failed_count > 0 AND last_failed_time > coalesce(last_archived_time, 'epoch'::timestamptz) THEN 'FAILING' ELSE 'OK' END
FROM pg_stat_archiver;
")

if [ -n "$arch_stats" ]; then
    IFS='|' read -r a_cnt f_cnt last_wal last_time fail_wal fail_time status <<< "$arch_stats"
    echo "Archived count      : $a_cnt"
    echo "Failed count        : $f_cnt"
    echo "Last archived WAL   : $last_wal at $last_time"
    echo "Last failed WAL     : $fail_wal at $fail_time"
    if [ "$status" = "FAILING" ]; then
        crit "Archiver is ACTIVELY FAILING (last failure is newer than last success)."
        echo "Debug steps:"
        echo "   1. Test the command manually as postgres user with a real segment path."
        echo "   2. Check permissions/credentials of the archive destination."
        echo "   3. Watch logs: journalctl -u postgresql | grep -i archi  (or PostgreSQL log)"
        remed "Fix failing archive_command — test it manually as the postgres OS user, check destination permissions, then watch pg_stat_archiver.failed_count stop growing."
    elif [ "${f_cnt:-0}" -gt 0 ] 2>/dev/null; then
        warn "Archiver had $f_cnt historical failures but currently succeeds."
    else
        ok "Archiver healthy — no recorded failures."
    fi
fi

# Check .ready backlog in pg_wal/archive_status (needs FS access)
DATA_DIR=$(q "SHOW data_directory;")
if [ -n "$DATA_DIR" ]; then
    STATUS_DIR="$DATA_DIR/pg_wal/archive_status"
    READY_CNT=""
    if [ -r "$STATUS_DIR" ]; then
        READY_CNT=$(find "$STATUS_DIR" -name '*.ready' 2>/dev/null | wc -l)
    elif have sudo && sudo -n true 2>/dev/null; then
        READY_CNT=$(sudo -n find "$STATUS_DIR" -name '*.ready' 2>/dev/null | wc -l || echo "")
    fi
    if [ -n "$READY_CNT" ]; then
        echo "Unarchived .ready segments in pg_wal: $READY_CNT"
        if [ "$READY_CNT" -gt 50 ]; then
            crit "$READY_CNT WAL segments waiting for archival — pg_wal will grow until the disk fills!"
            remed "Resolve archiver backlog immediately (fix archive_command); check pg_wal disk usage: du -sh $DATA_DIR/pg_wal"
        elif [ "$READY_CNT" -gt 10 ]; then
            warn "$READY_CNT WAL segments pending archival — monitor pg_wal growth."
        else
            ok "Archive backlog minimal ($READY_CNT pending)."
        fi
    else
        echo "(pg_wal/archive_status not readable as current user — run with sudo for backlog check)"
    fi
    # pg_wal size vs max_wal_size
    PGWAL_SIZE=$(du -sm "$DATA_DIR/pg_wal" 2>/dev/null | cut -f1 || echo "")
    [ -z "$PGWAL_SIZE" ] && have sudo && sudo -n true 2>/dev/null && PGWAL_SIZE=$(sudo -n du -sm "$DATA_DIR/pg_wal" 2>/dev/null | cut -f1 || echo "")
    MAX_WAL=$(q "SELECT setting::bigint * CASE unit WHEN 'MB' THEN 1 WHEN 'kB' THEN 0 ELSE 1 END FROM pg_settings WHERE name='max_wal_size';")
    if [ -n "$PGWAL_SIZE" ] && [ -n "$MAX_WAL" ] && [ "$MAX_WAL" -gt 0 ] 2>/dev/null; then
        echo "pg_wal size: ${PGWAL_SIZE}MB (max_wal_size: ${MAX_WAL}MB)"
        if [ "$PGWAL_SIZE" -gt $((MAX_WAL * 2)) ]; then
            crit "pg_wal is more than 2x max_wal_size — WAL retention is stuck (failed archiving, inactive slot, or wal_keep_size). Run pg_repl_triage.sh for slots."
        fi
    fi
fi
hr

# ============================================================================
# 3. INSTALLED BACKUP TOOLING & REPOSITORIES
# ============================================================================
echo
echo "${C_BOLD}3. Backup Tooling & Existing Repositories${C_RST}"
hr

FOUND_TOOL=0

# pgBackRest
if have pgbackrest; then
    FOUND_TOOL=1
    ok "pgBackRest installed: $(pgbackrest version 2>/dev/null | head -1)"
    if [ -r /etc/pgbackrest.conf ] || [ -r /etc/pgbackrest/pgbackrest.conf ]; then
        CONF=$( [ -r /etc/pgbackrest/pgbackrest.conf ] && echo /etc/pgbackrest/pgbackrest.conf || echo /etc/pgbackrest.conf )
        echo "  Config: $CONF; stanzas defined:"
        grep -E '^\[' "$CONF" | grep -v ':\|global' | sed 's/^/    /' || echo "    (none)"
        # Show backup info if any stanza responds
        STANZA=$(grep -E '^\[' "$CONF" | grep -v ':\|global' | head -1 | tr -d '[]')
        if [ -n "$STANZA" ]; then
            echo "  Latest backups for stanza '$STANZA':"
            pgbackrest --stanza="$STANZA" info 2>/dev/null | sed 's/^/    /' | head -25 || echo "    info command failed (check repo access)"
        fi
    else
        warn "pgBackRest binary present but no /etc/pgbackrest.conf — not configured."
        remed "Configure pgBackRest: create /etc/pgbackrest.conf with [global] repo1-path and a stanza; then pgbackrest --stanza=main stanza-create; pgbackrest --stanza=main backup"
    fi
fi

# barman
if have barman; then
    FOUND_TOOL=1
    ok "Barman installed: $(barman --version 2>/dev/null | head -1)"
    echo "  Servers status:"
    barman list-servers 2>/dev/null | sed 's/^/    /' || echo "    (no servers configured or insufficient rights)"
fi

# WAL-G
if have wal-g; then
    FOUND_TOOL=1
    ok "WAL-G installed: $(wal-g --version 2>/dev/null | head -1)"
    echo "  Verify backups (needs env/config): wal-g backup-list"
fi

# systemd timers / cron jobs mentioning backup tools or pg_dump
echo
echo "Scheduled backup jobs (cron + systemd timers):"
CRON_HITS=""
for cf in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/* /var/spool/cron/*; do
    [ -r "$cf" ] || continue
    hits=$(grep -HnE 'pg_dump|pg_basebackup|pgbackrest|barman|wal-g' "$cf" 2>/dev/null || true)
    [ -n "$hits" ] && CRON_HITS="$CRON_HITS$hits"$'\n'
done
if have systemctl; then
    TIMER_HITS=$(systemctl list-timers --all 2>/dev/null | grep -iE 'backup|pgbackrest|barman|walg' || true)
else
    TIMER_HITS=""
fi
if [ -n "$CRON_HITS$TIMER_HITS" ]; then
    [ -n "$CRON_HITS" ] && echo "$CRON_HITS" | sed 's/^/  /'
    [ -n "$TIMER_HITS" ] && echo "$TIMER_HITS" | sed 's/^/  /'
else
    warn "No scheduled backup jobs found in cron or systemd timers."
fi

if [ "$FOUND_TOOL" = 0 ]; then
    crit "NO dedicated backup tool (pgBackRest/barman/WAL-G) is installed on this host."
    if [ -r /etc/debian_version ]; then
        remed "Install pgBackRest: sudo apt-get update && sudo apt-get install -y pgbackrest"
    else
        remed "Install pgBackRest: sudo dnf install -y pgbackrest"
    fi
    remed "Minimum viable backup NOW (no tool needed): sudo -u postgres pg_basebackup -D /backup/base_\$(date +%Y%m%d) -Ft -z -X stream -P"
    remed "Logical fallback per database: sudo -u postgres pg_dump -Fc -d <db> -f /backup/<db>_\$(date +%Y%m%d).dump"
fi
hr

# ============================================================================
# 4. DATA CHECKSUMS & CORRUPTION DETECTION READINESS
# ============================================================================
echo
echo "${C_BOLD}4. Data Checksums & Corruption Detection${C_RST}"
hr

CHECKSUMS=$(q "SHOW data_checksums;")
echo "data_checksums  : $CHECKSUMS"
if [ "$CHECKSUMS" = "off" ]; then
    warn "Data checksums are OFF — silent page corruption cannot be detected by backups or reads."
    echo "Enabling requires the cluster OFFLINE (justify outage) :"
    echo "   systemctl stop postgresql"
    echo "   pg_checksums --enable --progress -D $DATA_DIR"
    echo "   systemctl start postgresql"
    remed "Consider enabling checksums during a maintenance window: pg_checksums --enable -D $DATA_DIR (cluster must be cleanly stopped)."
else
    ok "Data checksums enabled."
    CKSUM_FAILS=$(q "SELECT coalesce(sum(checksum_failures),0) FROM pg_stat_database;")
    if [ "${CKSUM_FAILS:-0}" -gt 0 ] 2>/dev/null; then
        crit "pg_stat_database reports $CKSUM_FAILS checksum FAILURES — data corruption present! Investigate immediately."
        remed "Investigate corruption: identify affected DB via SELECT datname, checksum_failures FROM pg_stat_database; verify hardware/dmesg; restore affected relations from backup."
    else
        ok "No checksum failures recorded."
    fi
fi

if have pg_amcheck; then
    ok "pg_amcheck available for logical corruption checks: pg_amcheck -d $PG_DBNAME --heapallindexed"
else
    echo "pg_amcheck not in PATH (ships with server packages PG14+; check /usr/lib/postgresql/*/bin or /usr/pgsql-*/bin)."
fi
hr

# ============================================================================
# 5. RECOVERY & RETENTION SETTINGS
# ============================================================================
echo
echo "${C_BOLD}5. Recovery-Related Settings${C_RST}"
hr
run_query "
SELECT name AS \"Parameter\", setting AS \"Value\",
  CASE
    WHEN name = 'restore_command' AND setting = '' THEN 'Set for PITR restores'
    WHEN name = 'recovery_target_time' AND setting <> '' THEN 'ACTIVE recovery target!'
    ELSE ''
  END AS \"Note\"
FROM pg_settings
WHERE name IN ('restore_command','recovery_target_time','recovery_target_action',
               'wal_keep_size','max_slot_wal_keep_size','checkpoint_timeout')
ORDER BY name;
"
BACKUP_IN_PROGRESS=$(q "SELECT count(*) FROM pg_stat_progress_basebackup;" 2>/dev/null || echo "0")
if [ "${BACKUP_IN_PROGRESS:-0}" -gt 0 ] 2>/dev/null; then
    echo "${C_BLU}[INFO]${C_RST} A pg_basebackup is currently RUNNING (see pg_stat_progress_basebackup)."
fi
hr

# ============================================================================
# 6. SUMMARY & VERDICT
# ============================================================================
echo
echo "${C_BOLD}6. Backup Readiness Summary${C_RST}"
hr
if [ ${#ISSUES[@]} -eq 0 ]; then
    echo "${C_GRN}Backup and recovery posture looks healthy. Remember: a backup is only real once a RESTORE has been tested.${C_RST}"
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
