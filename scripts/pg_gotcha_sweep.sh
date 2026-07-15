#!/bin/bash
# ============================================================================
# SCRIPT: pg_gotcha_sweep.sh
# DESCRIPTION:
#   Zero-dependency diagnostics script that sweeps for classic configuration
#   gotchas, shadowing options, timezone drifts, and scheduled administrative
#   jobs that could act as operational landmines or break reboot survival.
#
# PARAMETERS CHECKED:
#   - GUCs pending restart (pending_restart state in pg_settings).
#   - ALTER SYSTEM GUC shadowing (sourcefile matching postgresql.auto.conf).
#   - Hand-edited comment counts in postgresql.auto.conf.
#   - Duplicate key conflicts in postgresql.conf and postgresql.auto.conf.
#   - pg_hba.conf client authentication rule order (first-match-wins shadowing).
#   - Filesystem mount points of PG directories against fstab/systemd mount units.
#   - NTP synchronization, system time vs PG time, and timezone configurations.
#   - Scheduled background jobs (systemd timers, cron entries, at jobs).
#   - Logrotate configuration settings (checking for copytruncate or postrotate).
#   - data_sync_retry GUC value (should be off to prevent silent data corruption on fsync failure).
#
# RECOMMENDATIONS & RATIONALE:
#   - If GUCs are pending restart: Recommends restarting PostgreSQL. Rationale:
#     Unapplied configuration changes can cause unexpected behaviors on subsequent reboots.
#   - If ALTER SYSTEM overrides exist: Recommends ALTER SYSTEM RESET <param>. Rationale:
#     GUCs modified via ALTER SYSTEM override postgresql.conf, making manual edits there ineffective.
#   - If duplicate keys exist: Recommends cleaning up duplicate entries. Rationale:
#     In postgresql.conf, only the last uncommented parameter line is applied, which confuses administrators.
#   - If global pg_hba.conf reject/trust rule shadows more specific rules: Recommends reordering rules.
#     Rationale: pg_hba.conf matches in sequential order. A broad rule at the top makes subsequent rules unreachable.
#   - If active mounts are missing from fstab: Recommends writing them to /etc/fstab. Rationale:
#     If the data directory mount is not persisted, a system reboot will start PG with a missing directory or cause startup failures.
#   - If system clock is not NTP synchronized: Recommends enabling systemd-timesyncd or chrony.
#     Rationale: Clock drift breaks cluster leasing mechanisms (like Patroni DCS), logs timestamp correlation, and SSL/TLS validation.
#   - If heavy jobs fire during the work window: Recommends pausing or planning around them to avoid resource contention.
#   - If data_sync_retry is set to on: Recommends setting it to off. Rationale:
#     On Linux, retrying fsync on failure can discard dirty pages, leading to silent corruption; setting it to off panics PG to trigger WAL recovery.
#
# USAGE:
#   ./pg_gotcha_sweep.sh [-h <host>] [-p <port>] [-U <user>] [-d <dbname>]
#   ./pg_gotcha_sweep.sh --lookahead 4  # Flag jobs firing in the next 4 hours
# ============================================================================

set -o nounset

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

parse_cron_line() {
    local line="$1"
    local file=""
    local content=""
    local user="unknown"
    local is_job=0

    if [[ "$line" =~ ^/etc/crontab: ]]; then
        file="/etc/crontab"
        content="${line#*:}"
    elif [[ "$line" =~ ^/etc/cron.d/ ]]; then
        file="${line%%:*}"
        content="${line#*:}"
    elif [[ "$line" =~ ^([^:]+): ]]; then
        user="${BASH_REMATCH[1]}"
        content="${line#*:}"
        is_job=1
    else
        echo "  $line"
        return
    fi

    # Trim leading/trailing whitespace
    content="$(echo "$content" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    # Check if it's an env definition (e.g. SHELL=...)
    if [[ "$content" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        echo "  [File: $file] $content"
        return
    fi

    # Check if it starts with cron schedule characters: [0-9], *, @
    if [[ "$content" =~ ^([0-9\*@/,-]) ]]; then
        is_job=1
        if [ -n "$file" ]; then
            if [[ "$content" =~ ^@[a-zA-Z]+[[:space:]]+([^[:space:]]+) ]]; then
                user="${BASH_REMATCH[1]}"
            else
                # Extract 6th field
                user=$(echo "$content" | awk '{print $6}')
            fi
        fi
    fi

    if [ "$is_job" -eq 1 ]; then
        if [ -n "$file" ]; then
            echo "  [User: $user] [$file] $content"
        else
            echo "  [User: $user] [crontab] $content"
        fi
    else
        if [ -n "$file" ]; then
            echo "  [File: $file] $content"
        else
            echo "  $line"
        fi
    fi
}

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

PG_HOST="${PGHOST:-localhost}"
PG_PORT="${PGPORT:-}"
PG_USER="${PGUSER:-postgres}"
PG_DBNAME="${PGDATABASE:-postgres}"
LOOKAHEAD_HOURS=4

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --host <host>       PostgreSQL host (default: localhost or PGHOST)
  -p, --port <port>       PostgreSQL port (scans 5432-5435 if not set)
  -U, --user <user>       PostgreSQL user (default: postgres or PGUSER)
  -d, --dbname <db>       PostgreSQL database (default: postgres or PGDATABASE)
  --lookahead <hours>     Flag scheduled jobs firing within N hours (default: 4)
  --help                  Show this help menu

Runs best with sudo. DB connection is optional; FS checks run regardless.
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--host) PG_HOST="$2"; shift 2 ;;
        -p|--port) PG_PORT="$2"; shift 2 ;;
        -U|--user) PG_USER="$2"; shift 2 ;;
        -d|--dbname) PG_DBNAME="$2"; shift 2 ;;
        --lookahead) LOOKAHEAD_HOURS="$2"; shift 2 ;;
        --help) show_help ;;
        *) echo "Unknown option: $1" >&2; show_help ;;
    esac
done

# Optional DB connection
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
run_query() {
    psql -h "$PG_HOST" -p "$CONNECTED_PORT" -U "$PG_USER" -d "$PG_DBNAME" -c "$1"
}

ISSUES=()
REMEDS=()
warn() { echo "${C_YEL}[WARN]${C_RST} $1"; ISSUES+=("WARN: $1"); }
crit() { echo "${C_RED}[CRIT]${C_RST} $1"; ISSUES+=("CRIT: $1"); }
ok()   { echo "${C_GRN}[OK]${C_RST} $1"; }
info() { echo "${C_BLU}[INFO]${C_RST} $1"; }
remed() { REMEDS+=("$1"); }

echo
echo "${C_BOLD}PostgreSQL Config Gotchas & Time-Landmine Sweep${C_RST}"
hr
echo "DB connection   : $([ "$DB_CONNECTED" = 1 ] && echo "OK (port $CONNECTED_PORT)" || echo "UNAVAILABLE (filesystem checks only)")"
echo "Job lookahead   : ${LOOKAHEAD_HOURS}h"
echo "Sudo available  : $([ -n "$SUDO" ] && echo yes || echo NO)"
hr

# ============================================================================
# 1. SETTINGS PENDING A RESTART
# ============================================================================
echo
echo "${C_BOLD}1. GUCs Changed but Pending Restart${C_RST}"
hr
if [ "$DB_CONNECTED" = 1 ]; then
    PENDING=$(q "SELECT name || ' (file: ' || coalesce(setting,'?') || ', running: unknown-until-restart)' FROM pg_settings WHERE pending_restart;")
    if [ -n "$PENDING" ]; then
        crit "Settings were changed but the server was NEVER RESTARTED — running values differ from config files:"
        echo "$PENDING" | sed 's/^/    /'
        remed "Either restart to apply (justify outage: sudo systemctl restart postgresql) or revert the config change if it was unintended. List again after: SELECT name FROM pg_settings WHERE pending_restart;"
    else
        ok "No settings pending restart — running config matches files."
    fi
else
    info "DB unreachable — cannot check pending_restart."
fi
hr

# ============================================================================
# 2. POSTGRESQL.AUTO.CONF SHADOWING & TAMPERING
# ============================================================================
echo
echo "${C_BOLD}2. postgresql.auto.conf Overrides & Tampering${C_RST}"
hr
if [ "$DB_CONNECTED" = 1 ]; then
    DATA_DIR=$(q "SHOW data_directory;")
    CONF_FILE=$(q "SHOW config_file;")
    AUTOCONF="$DATA_DIR/postgresql.auto.conf"

    # Settings whose live source is the auto.conf (ALTER SYSTEM)
    OVERRIDES=$(q "
    SELECT name || ' = ' || setting
    FROM pg_settings
    WHERE sourcefile LIKE '%postgresql.auto.conf'
    ORDER BY name;
    ")
    if [ -n "$OVERRIDES" ]; then
        info "Settings currently controlled by ALTER SYSTEM (postgresql.auto.conf) — these SILENTLY OVERRIDE postgresql.conf:"
        echo "$OVERRIDES" | sed 's/^/    /'
        echo
        echo "  ${C_YEL}Trap:${C_RST} editing postgresql.conf for any of the above has NO effect."
        remed "To hand control back to postgresql.conf for a parameter: ALTER SYSTEM RESET <name>; SELECT pg_reload_conf();"
    else
        ok "No ALTER SYSTEM overrides active."
    fi

    # Hand-editing fingerprint: header comment says do not edit; comments beyond it = tampering
    AC_CONTENT=$($SUDO cat "$AUTOCONF" 2>/dev/null || cat "$AUTOCONF" 2>/dev/null || true)
    if [ -n "$AC_CONTENT" ]; then
        EXTRA_COMMENTS=$(echo "$AC_CONTENT" | grep -cE '^\s*#' || true)
        # The standard file has exactly one comment line ("# Do not edit this file manually!")
        if [ "${EXTRA_COMMENTS:-0}" -gt 1 ] 2>/dev/null; then
            warn "postgresql.auto.conf contains $EXTRA_COMMENTS comment lines — the standard file has 1. Someone likely edited it BY HAND (values may not match what ALTER SYSTEM recorded)."
            remed "Review $AUTOCONF manually; migrate intended settings into postgresql.conf or re-apply via ALTER SYSTEM, then clean the file through ALTER SYSTEM RESET."
        fi
        # Duplicated keys inside auto.conf (last wins, earlier ones are dead)
        DUPES=$(echo "$AC_CONTENT" | grep -vE '^\s*(#|$)' | cut -d= -f1 | tr -d ' ' | sort | uniq -d || true)
        [ -n "$DUPES" ] && warn "Duplicate keys inside postgresql.auto.conf (only the LAST wins): $DUPES"
    fi

    # Include directives in postgresql.conf — settings may hide in include files
    CF_CONTENT=$($SUDO cat "$CONF_FILE" 2>/dev/null || cat "$CONF_FILE" 2>/dev/null || true)
    if [ -n "$CF_CONTENT" ]; then
        INCLUDES=$(echo "$CF_CONTENT" | grep -E '^\s*include' | grep -v '^\s*#' || true)
        if [ -n "$INCLUDES" ]; then
            info "postgresql.conf uses include directives — settings may live elsewhere:"
            echo "$INCLUDES" | sed 's/^/    /'
        fi
        # Duplicated keys in postgresql.conf itself
        CDUPES=$(echo "$CF_CONTENT" | grep -vE '^\s*(#|$)' | grep '=' | cut -d= -f1 | tr -d ' \t' | sort | uniq -d || true)
        if [ -n "$CDUPES" ]; then
            warn "Duplicate uncommented keys in postgresql.conf (LAST occurrence wins — earlier lines are decoys): $CDUPES"
            remed "Deduplicate keys in $CONF_FILE — keep one authoritative line per parameter; verify live value with: SHOW <param>;"
        fi
    fi

    # The definitive truth table
    echo
    echo "Authoritative source per non-default setting (pg_settings):"
    run_query "
    SELECT source AS \"Source\", count(*) AS \"Settings\"
    FROM pg_settings
    WHERE source NOT IN ('default','client')
    GROUP BY source ORDER BY 2 DESC;
    "
else
    info "DB unreachable — grep configs manually: postgresql.auto.conf shadows postgresql.conf; ALTER SYSTEM RESET to clean."
fi
hr

# ============================================================================
# 3. DATA_SYNC_RETRY RELIABILITY GOTCHA
# ============================================================================
echo
echo "${C_BOLD}3. data_sync_retry Reliability Gotcha${C_RST}"
hr
if [ "$DB_CONNECTED" = 1 ]; then
    DSR=$(q "SHOW data_sync_retry;")
    if [ "$DSR" = "on" ]; then
        crit "data_sync_retry is set to ON! On fsync failure, PostgreSQL will attempt to retry syncing, which on Linux can lead to silent data corruption because the OS page cache may have already discarded the dirty pages."
        remed "Set data_sync_retry = off in postgresql.conf (or postgresql.auto.conf via ALTER SYSTEM) and restart PostgreSQL. Rationale: Keeping it off causes PostgreSQL to panic immediately on fsync failure, which triggers WAL recovery and preserves data integrity."
    else
        ok "data_sync_retry is off (safe on fsync failure)."
    fi
else
    info "DB unreachable — cannot check data_sync_retry."
fi
hr

# ============================================================================
# 4. PG_HBA.CONF ORDERING TRAPS (FIRST MATCH WINS)
# ============================================================================
echo
echo "${C_BOLD}4. pg_hba.conf Ordering Traps${C_RST}"
hr
if [ "$DB_CONNECTED" = 1 ]; then
    HBA=$(q "SELECT line_number, type, array_to_string(database,','), array_to_string(user_name,','), coalesce(address,''), auth_method FROM pg_hba_file_rules WHERE error IS NULL ORDER BY line_number;")
    if [ -n "$HBA" ]; then
        echo "Effective rules in match order (FIRST match wins — later rules never fire if shadowed):"
        printf "  %-5s %-9s %-15s %-15s %-20s %-15s\n" "Line" "Type" "Database" "User" "Address" "Method"
        FOUND_TRAP=0
        SEEN_BROAD_ALL=""
        while IFS='|' read -r ln type dbs users addr method; do
            MARK=""
            # A broad all/all rule earlier shadows everything after it for that address space
            if [ -n "$SEEN_BROAD_ALL" ]; then
                MARK="  <- possibly SHADOWED by line $SEEN_BROAD_ALL"
            fi
            if [ "$dbs" = "all" ] && [ "$users" = "all" ] && { [ "$addr" = "0.0.0.0/0" ] || [ "$addr" = "::/0" ]; }; then
                if [ "$method" = "reject" ]; then
                    crit "line $ln REJECTS all/all from $addr — every network rule BELOW it is dead!"
                    remed "Move the reject line below specific allow rules, or delete it; then SELECT pg_reload_conf(); Verify: psql 'host=<ip> ...' from a client."
                    FOUND_TRAP=1
                elif [ "$method" = "trust" ]; then
                    crit "line $ln TRUSTS all/all from $addr — the entire internet connects without a password AND shadows stricter rules below!"
                    remed "Replace the global trust with scram-sha-256 and narrow CIDRs; SELECT pg_reload_conf();"
                    FOUND_TRAP=1
                fi
                [ -z "$SEEN_BROAD_ALL" ] && SEEN_BROAD_ALL="$ln"
            fi
            printf "  %-5s %-9s %-15.15s %-15.15s %-20.20s %-15.15s%s\n" "$ln" "$type" "$dbs" "$users" "$addr" "$method" "$MARK"
        done <<< "$HBA"
        [ "$FOUND_TRAP" = 0 ] && ok "No global reject/trust shadowing traps detected."
    else
        info "pg_hba_file_rules not readable — review manually with match-order in mind: sudo grep -vE '^\s*(#|$)' \$(psql -Atc 'SHOW hba_file;')"
    fi
else
    info "DB unreachable — cannot audit pg_hba rules."
fi
hr

# ============================================================================
# 5. MOUNTS MISSING FROM /ETC/FSTAB (REBOOT DATA LOSS)
# ============================================================================
echo
echo "${C_BOLD}5. Mounted Volumes vs /etc/fstab (Reboot Survival)${C_RST}"
hr
FSTAB_OK=1
if [ -r /etc/fstab ]; then
    # Interesting mountpoints: anything under paths where PG data commonly lives + any non-root data mounts
    while read -r src mnt fstype _; do
        case "$fstype" in
            ext4|xfs|btrfs|ext3|zfs) : ;;
            *) continue ;;
        esac
        [ "$mnt" = "/" ] && continue
        case "$mnt" in
            /boot*|/snap*) continue ;;
        esac
        # Is this mountpoint or its device in fstab (by path, UUID, or LABEL)?
        UUID=$(lsblk -no UUID "$src" 2>/dev/null | head -1 || true)
        if grep -qsE "^[^#]*[[:space:]]$mnt[[:space:]]" /etc/fstab; then
            IN_FSTAB=1
        elif [ -n "$UUID" ] && grep -qs "$UUID" /etc/fstab; then
            IN_FSTAB=1
        else
            IN_FSTAB=0
        fi
        # systemd mount units also count
        if [ "$IN_FSTAB" = 0 ] && have systemctl; then
            UNIT=$(systemd-escape -p --suffix=mount "$mnt" 2>/dev/null || true)
            if [ -n "$UNIT" ] && systemctl is-enabled "$UNIT" >/dev/null 2>&1; then
                IN_FSTAB=1
            fi
        fi
        if [ "$IN_FSTAB" = 0 ]; then
            FSTAB_OK=0
            crit "Mount $mnt ($src, $fstype) is ACTIVE but NOT in /etc/fstab (nor a systemd mount unit) — it will NOT come back after reboot!"
            if [ -n "$UUID" ]; then
                remed "Persist the mount: echo 'UUID=$UUID $mnt $fstype defaults,noatime 0 2' | sudo tee -a /etc/fstab; validate WITHOUT reboot: sudo findmnt --verify"
            else
                remed "Persist the mount: add '$src $mnt $fstype defaults,noatime 0 2' to /etc/fstab; validate: sudo findmnt --verify"
            fi
            # Is PG data on it?
            if [ "$DB_CONNECTED" = 1 ]; then
                DD=$(q "SHOW data_directory;")
                case "$DD" in
                    "$mnt"*) crit "...and the PostgreSQL data_directory ($DD) LIVES ON THIS MOUNT. A reboot would start PG with an empty/missing datadir!" ;;
                esac
            fi
        fi
    done < <(awk '{print $1, $2, $3}' /proc/mounts)
    [ "$FSTAB_OK" = 1 ] && ok "All persistent data mounts are covered by fstab/systemd units."
else
    warn "/etc/fstab not readable."
fi
hr

# ============================================================================
# 6. CLOCK & TIMEZONE SANITY
# ============================================================================
echo
echo "${C_BOLD}6. Clock Sync & Timezone Sanity${C_RST}"
hr
if have timedatectl; then
    TD=$(timedatectl 2>/dev/null || true)
    echo "$TD" | sed 's/^/  /' | head -8
    if echo "$TD" | grep -qE 'System clock synchronized:\s*yes'; then
        ok "System clock is NTP-synchronized."
    else
        crit "System clock NOT synchronized — breaks Patroni TTL math, log correlation, and cert validity checks!"
        remed "Enable time sync: sudo timedatectl set-ntp true; verify service: systemctl status systemd-timesyncd chronyd 2>/dev/null; check: chronyc tracking (if chrony)"
    fi
else
    DATE_OUT=$(date)
    info "timedatectl unavailable; system date: $DATE_OUT"
    if have chronyc; then
        chronyc tracking 2>/dev/null | sed 's/^/  /' | head -5 || true
    elif have ntpq; then
        ntpq -p 2>/dev/null | sed 's/^/  /' | head -5 || true
    else
        warn "No NTP client tooling found (chrony/ntp/timesyncd) — clock drift undetectable."
        remed "Install chrony: sudo apt-get install -y chrony  (or: sudo dnf install -y chrony); enable: sudo systemctl enable --now chronyd"
    fi
fi
if [ "$DB_CONNECTED" = 1 ]; then
    PG_TZ=$(q "SHOW timezone;")
    PG_NOW=$(q "SELECT now()::text;")
    echo "  PostgreSQL timezone: $PG_TZ | now(): $PG_NOW"
    OS_EPOCH=$(date +%s)
    PG_EPOCH=$(q "SELECT extract(epoch FROM now())::bigint;")
    if [ -n "$PG_EPOCH" ]; then
        DRIFT=$(( OS_EPOCH - PG_EPOCH )); [ "$DRIFT" -lt 0 ] && DRIFT=$(( -DRIFT ))
        if [ "$DRIFT" -gt 2 ]; then
            warn "OS vs PostgreSQL clock differ by ${DRIFT}s — investigate (should be near zero on the same host)."
        fi
    fi
fi
hr

# ============================================================================
# 7. SCHEDULED JOBS FIRING SOON (CRON / AT / SYSTEMD TIMERS)
# ============================================================================
echo
echo "${C_BOLD}7. Scheduled Jobs Within the Next ${LOOKAHEAD_HOURS}h${C_RST}"
hr
NOW_H=$(date +%H | sed 's/^0//'); NOW_H=${NOW_H:-0}
FOUND_JOBS=0

# systemd timers with NEXT within window (easiest to evaluate precisely)
if have systemctl; then
    TIMERS=$(systemctl list-timers --no-pager 2>/dev/null | head -30 || true)
    if [ -n "$TIMERS" ]; then
        echo "systemd timers (verify 'NEXT' column against your working window):"
        echo "$TIMERS" | sed 's/^/  /' | head -20
        # Highlight obviously dangerous ones
        DANGER=$(echo "$TIMERS" | grep -iE 'backup|vacuum|reindex|dump|apt|dnf|unattended|update' || true)
        if [ -n "$DANGER" ]; then
            FOUND_JOBS=1
            warn "Timers that could impact the DB or the system during your window:"
            echo "$DANGER" | sed 's/^/    /'
            remed "If a heavy job would collide with your work, note it in the report; to delay ONE run (document it!): sudo systemctl stop <name>.timer (and start it again after) — do not disable permanently without customer approval."
        fi
    fi
fi

# cron entries — list all, highlight hour proximity
echo
echo "cron entries mentioning DB/system-heavy work:"
CRON_ALL=""
for cf in /etc/crontab /etc/cron.d/*; do
    [ -r "$cf" ] || continue
    C=$($SUDO grep -HvE '^\s*(#|$)' "$cf" 2>/dev/null || grep -HvE '^\s*(#|$)' "$cf" 2>/dev/null || true)
    [ -n "$C" ] && CRON_ALL="$CRON_ALL$C"$'\n'
done
for user in root postgres; do
    C=$($SUDO crontab -l -u "$user" 2>/dev/null | grep -vE '^\s*(#|$)' | sed "s/^/${user}: /" || true)
    [ -n "$C" ] && CRON_ALL="$CRON_ALL$C"$'\n'
done
if [ -n "${CRON_ALL// }" ]; then
    echo "$CRON_ALL" | while read -r line; do
        [ -n "$line" ] && parse_cron_line "$line"
    done | head -20
    HEAVY=$(echo "$CRON_ALL" | grep -iE 'pg_dump|vacuum|reindex|backup|rsync|find /|dd |restart|reboot' || true)
    if [ -n "$HEAVY" ]; then
        FOUND_JOBS=1
        warn "cron jobs with potential DB/system impact — check their hour fields against the current time ($(date '+%H:%M %Z')):"
        echo "$HEAVY" | while read -r line; do
            [ -n "$line" ] && parse_cron_line "$line"
        done
    fi
    # crude imminent check: hour field == current or next hour
    NEXT_H=$(( (NOW_H + 1) % 24 ))
    IMMINENT=$(echo "$CRON_ALL" | awk -v h1="$NOW_H" -v h2="$NEXT_H" '{f=$1; hh=$2; if ($0 ~ /^[a-z]+: /) {f=$2; hh=$3}} hh==h1 || hh==h2 || hh=="*" {print}' 2>/dev/null | grep -iE 'pg_dump|vacuum|reindex|backup|restart|reboot' || true)
    if [ -n "$IMMINENT" ]; then
        crit "Heavy cron job(s) scheduled to fire THIS or NEXT hour:"
        echo "$IMMINENT" | while read -r line; do
            [ -n "$line" ] && parse_cron_line "$line"
        done
        remed "Decide consciously: let it run and account for the load, or comment it out temporarily WITH customer approval and a note in the report."
    fi
else
    info "No active cron entries found (or not readable without sudo)."
fi

# at jobs
if have atq; then
    ATJOBS=$($SUDO atq 2>/dev/null || atq 2>/dev/null || true)
    if [ -n "$ATJOBS" ]; then
        FOUND_JOBS=1
        warn "Pending 'at' jobs exist (one-shot scheduled commands — a favorite hiding spot):"
        echo "$ATJOBS" | sed 's/^/    /'
        remed "Inspect each at-job's payload: sudo at -c <jobid>; remove ONLY if malicious/mistaken: sudo atrm <jobid> (document it)."
    fi
fi
[ "$FOUND_JOBS" = 0 ] && ok "No obviously dangerous scheduled jobs detected in the lookahead window."
hr

# ============================================================================
# 8. LOGROTATE TOUCHING POSTGRESQL LOGS
# ============================================================================
echo
echo "${C_BOLD}8. Logrotate Configs Affecting PostgreSQL${C_RST}"
hr
LR_HITS=""
for lrf in /etc/logrotate.conf /etc/logrotate.d/*; do
    [ -r "$lrf" ] || continue
    if grep -qsiE 'postgres|pgbouncer|patroni|haproxy' "$lrf"; then
        LR_HITS="$LR_HITS$lrf"$'\n'
    fi
done
if [ -n "$LR_HITS" ]; then
    info "Logrotate configs covering the PG stack:"
    for f in $LR_HITS; do
        echo "  == $f =="
        grep -vE '^\s*(#|$)' "$f" | sed 's/^/    /' | head -15
        # copytruncate vs postrotate reload nuance
        if grep -qs 'copytruncate' "$f"; then
            info "  Uses copytruncate — safe for PG logging_collector, but a tail -f you have open may appear to stop; reopen it after rotation."
        fi
    done
else
    info "No logrotate configs mention the PG stack. If logging_collector=on, PostgreSQL rotates its own logs (log_rotation_age/size) — check those GUCs instead."
fi
hr

# ============================================================================
# 9. SUMMARY & VERDICT
# ============================================================================
echo
echo "${C_BOLD}9. Gotcha Sweep Summary${C_RST}"
hr
if [ ${#ISSUES[@]} -eq 0 ]; then
    echo "${C_GRN}No planted traps or silent misconfigurations detected.${C_RST}"
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
