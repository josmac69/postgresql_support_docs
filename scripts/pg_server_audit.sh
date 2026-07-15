#!/usr/bin/env bash
# ============================================================================
# SCRIPT: pg_server_audit.sh
# DESCRIPTION:
#   Comprehensive system and database diagnostics script that checks OS resources,
#   disk space, memory allocation, sysctl parameters, ulimits, service health, and
#   PostgreSQL server configurations (memory, WALs, vacuum, security, replications,
#   and indexes). Identifies anomalies and outputs actionable copy-paste remediation commands.
#
# PARAMETERS CHECKED:
#   - System Identity: OS type, kernel details, CPU count, cloud metadata (AWS EC2).
#   - Disk Space: Filesystem usage, inode counts, mount parameters (noatime).
#   - Memory & Swap: Memory specifications, swap sizes and usage, kernel dirty ratios,
#     swappiness, overcommit memory limits, Transparent Huge Pages (THP) state.
#   - Core OS: Device IO schedulers, postmaster ulimits (LimitNOFILE), postmaster oom_score_adj,
#     timedatectl NTP synchronizations.
#   - System Health: memory consumers, systemd failed units, dmesg OOM killer warnings, cron jobs.
#   - Database Config: Version, directories, shared_buffers, effective_cache_size, work_mem,
#     maintenance_work_mem, fsync, full_page_writes, data_sync_retry, synchronous_commit, random_page_cost,
#     max_connections, autovacuum parameters, and logging GUCs.
#   - Database Security: pg_hba rules (trust, open IP access), superusers, listen_addresses.
#   - Database Health: bloated/never-analyzed tables, transaction ID wraparound ages,
#     pg_wal directory size, active/inactive replication slots, replication lag, archiver status,
#     invalid/unused indexes, and idle-in-transaction connections.
#
# RECOMMENDATIONS & RATIONALE:
#   - If dirty page ratios are at default: Recommends vm.dirty_ratio=15, vm.dirty_background_ratio=5.
#     Rationale: Prevents long system-wide I/O pauses when dirty pages flush to storage.
#   - If overcommit_memory != 2: Recommends 2. Rationale: Stops the kernel from overallocating memory
#     and having the OOM killer terminate the postmaster.
#   - If fsync / full_page_writes are off: Recommends enabling them. Rationale: Crucial for protecting
#     against database corruption and data loss on server crash.
#   - If data_sync_retry is on: Recommends disabling it. Rationale: Avoids silent data corruption on
#     fsync failure by forcing a crash/recovery.
#   - If random_page_cost is set to 4.0: Recommends 1.1 on SSD/EBS storage. Rationale: Prevents the
#     planner from avoiding index scans in favor of slow sequential scans.
#   - If autovacuum is disabled: Recommends enabling. Rationale: Essential to prevent database bloat,
#     refresh planner statistics, and avoid transaction ID wraparound.
#   - If inactive replication slots exist: Recommends dropping them. Rationale: Prevents orphaned slots
#     from locking WAL retention and filling up pg_wal storage.
#
# USAGE:
#   sudo ./pg_server_audit.sh
# ============================================================================

set -u
LC_ALL=C
export PAGER=cat

#------------------------------------------------------------------------------
# Output helpers
#------------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'
    C_BLU=$'\033[1;34m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_OFF=""
fi

WARN_COUNT=0
CRIT_COUNT=0

hdr()  { printf '\n%s========== %s ==========%s\n' "$C_BLU" "$*" "$C_OFF"; }
ok()   { printf '%s[OK]  %s%s\n'   "$C_GRN" "$*" "$C_OFF"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_YEL" "$C_OFF" "$*"; WARN_COUNT=$((WARN_COUNT+1)); }
crit() { printf '%s[CRIT]%s %s\n'  "$C_RED" "$C_OFF" "$*"; CRIT_COUNT=$((CRIT_COUNT+1)); }
info() { printf '[INFO] %s\n' "$*"; }
rec()  { printf '       %s->%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
cmd()  { printf '       %s$%s %s\n' "$C_BLU" "$C_OFF" "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

#------------------------------------------------------------------------------
# OS detection
#------------------------------------------------------------------------------
OS_FAMILY="unknown"
OS_PRETTY="unknown"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-unknown}"
    case "${ID:-} ${ID_LIKE:-}" in
        *debian*|*ubuntu*) OS_FAMILY="debian" ;;
        *rhel*|*fedora*|*centos*|*rocky*|*alma*) OS_FAMILY="redhat" ;;
    esac
fi

PKG_LIST_PG=""
if [ "$OS_FAMILY" = "debian" ]; then
    PKG_LIST_PG="dpkg -l | grep -Ei 'postgres'"
elif [ "$OS_FAMILY" = "redhat" ]; then
    PKG_LIST_PG="rpm -qa | grep -Ei 'postgres'"
fi

#------------------------------------------------------------------------------
# psql wrapper: run SQL as postgres OS user (peer auth) against default cluster
#------------------------------------------------------------------------------
PSQL_OK=0
run_psql() {
    # $1 = SQL; returns unaligned tuples-only output
    if [ "$IS_ROOT" -eq 1 ]; then
        su - postgres -c "psql -XAtq -c \"$1\"" 2>/dev/null
    elif [ "$(id -un)" = "postgres" ]; then
        psql -XAtq -c "$1" 2>/dev/null
    else
        sudo -n -u postgres psql -XAtq -c "$1" 2>/dev/null
    fi
}

run_psql_table() {
    # $1 = SQL; aligned table output for readability
    if [ "$IS_ROOT" -eq 1 ]; then
        su - postgres -c "psql -Xq -c \"$1\"" 2>/dev/null
    elif [ "$(id -un)" = "postgres" ]; then
        psql -Xq -c "$1" 2>/dev/null
    else
        sudo -n -u postgres psql -Xq -c "$1" 2>/dev/null
    fi
}

pg_setting() { run_psql "SHOW $1;"; }

#===============================================================================
printf '%s' "$C_BLU"
echo "==============================================================================="
echo " PostgreSQL Server Audit  -  $(hostname)  -  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo " Run as: $(id -un) (root: $IS_ROOT)"
echo "==============================================================================="
printf '%s' "$C_OFF"
[ "$IS_ROOT" -eq 0 ] && warn "Not running as root: some checks (dmesg, ulimits, cron, oom_score_adj) will be limited."

#===============================================================================
hdr "1. SYSTEM IDENTITY"
#===============================================================================
info "OS:        $OS_PRETTY (family: $OS_FAMILY)"
info "Kernel:    $(uname -r)"
info "Arch:      $(uname -m)"
info "Uptime:    $(uptime -p 2>/dev/null || uptime)"
info "Load:      $(cut -d' ' -f1-3 /proc/loadavg)"
CPUS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)
info "CPUs:      $CPUS"

# EC2 metadata (IMDSv2 with fallback to v1)
if have curl; then
    TOKEN=$(curl -s -m 1 -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
    ITYPE=""
    if [ -n "$TOKEN" ]; then
        ITYPE=$(curl -s -m 1 -H "X-aws-ec2-metadata-token: $TOKEN" \
                http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)
    else
        ITYPE=$(curl -s -m 1 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)
    fi
    [ -n "$ITYPE" ] && info "EC2 type:  $ITYPE" || info "EC2 metadata not reachable (may not be EC2, or IMDS blocked)."
fi

#===============================================================================
hdr "2. DISK SPACE AND INODES"
#===============================================================================
df -hP | grep -vE '^(tmpfs|devtmpfs|overlay|shm)' | sed 's/^/       /'
echo
# Flag any filesystem above thresholds
df -P | grep -vE '^(Filesystem|tmpfs|devtmpfs|overlay|shm)' | while read -r fs blocks used avail pct mnt; do
    p=${pct%%%}
    case "$p" in (*[!0-9]*|'') continue;; esac
    if [ "$p" -ge 90 ]; then
        crit "Filesystem $mnt is ${p}% full."
    elif [ "$p" -ge 80 ]; then
        warn "Filesystem $mnt is ${p}% full."
    fi
done
# Because the while runs in a subshell, re-count flags for the summary:
DISK_CRIT=$(df -P | grep -vE '^(Filesystem|tmpfs|devtmpfs|overlay|shm)' | awk '{gsub("%","",$5)} $5>=90' | wc -l)
DISK_WARN=$(df -P | grep -vE '^(Filesystem|tmpfs|devtmpfs|overlay|shm)' | awk '{gsub("%","",$5)} $5>=80 && $5<90' | wc -l)
CRIT_COUNT=$((CRIT_COUNT+DISK_CRIT)); WARN_COUNT=$((WARN_COUNT+DISK_WARN))
if [ "$DISK_CRIT" -gt 0 ]; then
    rec "Find what fills the disk before deleting anything:"
    cmd "du -xh --max-depth=2 /var 2>/dev/null | sort -rh | head -20"
    rec "Typical culprits: pg_wal growth (abandoned replication slot!), logs, core dumps, old backups."
fi

INODE_ISSUE=$(df -iP | grep -vE '^(Filesystem|tmpfs|devtmpfs|overlay|shm)' | awk '{gsub("%","",$5)} $5>=80' | wc -l)
if [ "$INODE_ISSUE" -gt 0 ]; then
    warn "One or more filesystems above 80% inode usage:"
    df -iP | awk '{gsub("%","",$5)} NR==1 || $5>=80' | sed 's/^/       /'
    WARN_COUNT=$((WARN_COUNT))
else
    ok "Inode usage healthy on all filesystems."
fi

info "Block devices and mounts:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE 2>/dev/null | sed 's/^/       /'
if mount | grep -E ' / | /var| /data| /pgdata' | grep -q noatime; then
    ok "noatime present on at least one data-relevant mount."
else
    info "No 'noatime' seen on common data mounts. Minor optimization for PGDATA volume:"
    cmd "add 'noatime' to the mount options in /etc/fstab and remount"
fi

#===============================================================================
hdr "3. MEMORY AND SWAP"
#===============================================================================
free -h | sed 's/^/       /'
MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_TOTAL_GB=$((MEM_TOTAL_KB/1024/1024))
info "Total memory: ~${MEM_TOTAL_GB} GB"

SWAP_TOTAL=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
SWAP_USED_KB=$(free -k | awk '/Swap/{print $3}')
if [ "$SWAP_TOTAL" -eq 0 ]; then
    info "No swap configured. Acceptable on cloud DB servers, but note it in the report."
elif [ "${SWAP_USED_KB:-0}" -gt 262144 ]; then
    warn "Swap in use: $(free -h | awk '/Swap/{print $3}'). Check what got swapped and why (memory pressure / OOM risk)."
    cmd "vmstat 1 5   # watch si/so columns for active swapping"
else
    ok "Swap configured but essentially unused."
fi

#===============================================================================
hdr "4. KERNEL / SYSCTL TUNING FOR DATABASES"
#===============================================================================
get_sysctl() { sysctl -n "$1" 2>/dev/null; }

# --- dirty ratios ---
DR=$(get_sysctl vm.dirty_ratio)
DBR=$(get_sysctl vm.dirty_background_ratio)
info "vm.dirty_ratio=$DR  vm.dirty_background_ratio=$DBR"
if [ "${DR:-0}" -gt 15 ] || [ "${DBR:-0}" -gt 5 ]; then
    DIRTY_GB=$(( MEM_TOTAL_GB * ${DR:-20} / 100 ))
    warn "Dirty page ratios at/near defaults. On a ${MEM_TOTAL_GB}GB host, up to ~${DIRTY_GB}GB of dirty pages can accumulate before a hard flush pause."
    rec "Recommended for DB servers: vm.dirty_ratio=15 (or 10), vm.dirty_background_ratio=5 (or 3)."
    cmd "echo 'vm.dirty_ratio = 15' >> /etc/sysctl.d/99-postgresql.conf"
    cmd "echo 'vm.dirty_background_ratio = 5' >> /etc/sysctl.d/99-postgresql.conf"
    cmd "sysctl --system"
else
    ok "Dirty ratios already tuned for database workload."
fi

# --- swappiness ---
SW=$(get_sysctl vm.swappiness)
if [ "${SW:-60}" -gt 10 ]; then
    warn "vm.swappiness=$SW (default-ish). DB servers should avoid swapping working memory."
    cmd "echo 'vm.swappiness = 1' >> /etc/sysctl.d/99-postgresql.conf && sysctl --system"
else
    ok "vm.swappiness=$SW."
fi

# --- overcommit ---
OC=$(get_sysctl vm.overcommit_memory)
OCR=$(get_sysctl vm.overcommit_ratio)
if [ "${OC:-0}" -ne 2 ]; then
    warn "vm.overcommit_memory=$OC. PostgreSQL docs recommend 2 (no heuristic overcommit) to keep the OOM killer away from the postmaster."
    rec "Pair with an overcommit_ratio sized to RAM+swap (commonly 80-100 on swapless hosts; verify CommitLimit afterwards)."
    cmd "echo 'vm.overcommit_memory = 2' >> /etc/sysctl.d/99-postgresql.conf"
    cmd "echo 'vm.overcommit_ratio = 90'  >> /etc/sysctl.d/99-postgresql.conf && sysctl --system"
else
    ok "vm.overcommit_memory=2 (overcommit_ratio=$OCR)."
fi

# --- Transparent Huge Pages ---
THP_FILE=/sys/kernel/mm/transparent_hugepage/enabled
if [ -r "$THP_FILE" ]; then
    THP=$(cat "$THP_FILE")
    case "$THP" in
        *'[always]'*)
            warn "Transparent Huge Pages = always. Known to cause latency stalls/memory bloat for PostgreSQL."
            rec "Set to 'never' (or at least 'madvise'):"
            cmd "echo never > /sys/kernel/mm/transparent_hugepage/enabled   # runtime"
            rec "Persist via kernel cmdline 'transparent_hugepage=never' (grubby on RHEL / update-grub on Debian) or a systemd unit."
            ;;
        *) ok "THP: $THP" ;;
    esac
fi

# --- explicit huge pages vs shared_buffers (checked later once we know SB) ---
HP_TOTAL=$(awk '/HugePages_Total/{print $2}' /proc/meminfo)
info "Explicit HugePages_Total=$HP_TOTAL (evaluated against shared_buffers in section 8)."

#===============================================================================
hdr "5. I/O SCHEDULER, LIMITS, TIME SYNC"
#===============================================================================
for d in /sys/block/*/queue/scheduler; do
    [ -r "$d" ] || continue
    dev=$(echo "$d" | cut -d/ -f4)
    case "$dev" in loop*|ram*|sr*) continue;; esac
    sched=$(cat "$d")
    case "$sched" in
        *'[none]'*|*'[mq-deadline]'*|*'[noop]'*|*'[deadline]'*) ok "I/O scheduler on $dev: $sched" ;;
        *)
            warn "I/O scheduler on $dev: $sched. On EBS/NVMe prefer 'none' or 'mq-deadline'."
            cmd "echo mq-deadline > /sys/block/$dev/queue/scheduler   # runtime; persist via udev rule"
            ;;
    esac
done

# ulimits of the running postmaster (more truthful than 'su - postgres')
PM_PID=$(pgrep -o -x postgres 2>/dev/null || pgrep -o -f 'postgres.*-D' 2>/dev/null)
if [ -n "${PM_PID:-}" ] && [ -r "/proc/$PM_PID/limits" ]; then
    NOFILE=$(awk '/Max open files/{print $4}' "/proc/$PM_PID/limits")
    info "Postmaster (pid $PM_PID) max open files: $NOFILE"
    if [ "${NOFILE:-1024}" -lt 4096 ] 2>/dev/null; then
        warn "Open-files limit for postmaster is low ($NOFILE)."
        cmd "systemctl edit postgresql   # add: [Service] LimitNOFILE=65536, then daemon-reload + restart"
    fi
fi

# OOM protection of postmaster
if [ -n "${PM_PID:-}" ] && [ -r "/proc/$PM_PID/oom_score_adj" ]; then
    OOM_ADJ=$(cat "/proc/$PM_PID/oom_score_adj")
    if [ "$OOM_ADJ" -gt -500 ] 2>/dev/null; then
        info "Postmaster oom_score_adj=$OOM_ADJ (not explicitly protected)."
        rec "Consider OOMScoreAdjust=-1000 in the systemd unit for the postmaster (packaged units often do this already)."
    else
        ok "Postmaster protected from OOM killer (oom_score_adj=$OOM_ADJ)."
    fi
fi

# time sync
if have timedatectl; then
    SYNCED=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || timedatectl 2>/dev/null | awk -F': ' '/synchronized/{print $2}')
    case "$SYNCED" in
        yes) ok "System clock is NTP-synchronized." ;;
        *)  warn "Clock not confirmed NTP-synchronized. Matters for logs, replication, and monitoring."
            cmd "timedatectl set-ntp true   # or install/enable chrony" ;;
    esac
fi

#===============================================================================
hdr "6. PROCESSES, SERVICES, LOGS, CRON"
#===============================================================================
info "Top memory consumers:"
ps aux --sort=-%mem 2>/dev/null | head -6 | sed 's/^/       /'

FAILED=$(systemctl list-units --failed --no-legend 2>/dev/null | wc -l)
if [ "${FAILED:-0}" -gt 0 ]; then
    warn "$FAILED failed systemd unit(s):"
    systemctl list-units --failed --no-legend 2>/dev/null | sed 's/^/       /'
else
    ok "No failed systemd units."
fi

# OOM killer / kernel errors
if [ "$IS_ROOT" -eq 1 ]; then
    OOM_HITS=$(dmesg -T 2>/dev/null | grep -ci 'out of memory\|oom-kill' || true)
    if [ "${OOM_HITS:-0}" -gt 0 ]; then
        crit "OOM killer events found in kernel log ($OOM_HITS lines). If PostgreSQL was the victim, this is a headline finding."
        dmesg -T 2>/dev/null | grep -i 'oom' | tail -5 | sed 's/^/       /'
    else
        ok "No OOM killer events in kernel ring buffer."
    fi
    ERRS=$(journalctl -p err -b --no-pager 2>/dev/null | tail -8)
    [ -n "$ERRS" ] && { info "Recent journal errors (this boot):"; echo "$ERRS" | sed 's/^/       /'; }
fi

# cron
info "Cron entries (root + postgres + /etc/cron.d):"
{ crontab -l 2>/dev/null; crontab -l -u postgres 2>/dev/null; ls -1 /etc/cron.d/ 2>/dev/null; } \
    | grep -v '^\s*#' | grep -v '^\s*$' | sed 's/^/       /' || info "       (none readable)"

#===============================================================================
hdr "7. POSTGRESQL: INSTALLATION AND SERVICE"
#===============================================================================
if have psql; then
    info "psql client: $(psql -V)"
else
    warn "psql not in PATH for this user. On RHEL check /usr/pgsql-*/bin, on Debian /usr/lib/postgresql/*/bin."
fi

# Multiple clusters / postmasters — a classic decoy
PM_COUNT=$(pgrep -c -f 'postgres.* -D|postmaster.* -D' 2>/dev/null || echo 0)
pgrep -x postgres >/dev/null 2>&1 && PM_COUNT=$(pgrep -x postgres | xargs -r -n1 ps -o ppid= -p 2>/dev/null | grep -c '^ *1$' || echo "$PM_COUNT")
info "Postmaster-like process count heuristic: $PM_COUNT (verify below)"
ps -ef | grep -E '[p]ostgres.*-D|[p]ostmaster' | sed 's/^/       /'

if [ "$OS_FAMILY" = "debian" ] && have pg_lsclusters; then
    info "Debian clusters:"
    pg_lsclusters 2>/dev/null | sed 's/^/       /'
    DOWN=$(pg_lsclusters 2>/dev/null | awk 'NR>1 && $4=="down"' | wc -l)
    [ "$DOWN" -gt 0 ] && warn "$DOWN cluster(s) reported down. Decide deliberately whether they should run."
fi

# service enabled at boot?
PG_UNIT=""
for u in postgresql postgresql@ postgresql-17 postgresql-16 postgresql-15 postgresql-14 postgresql-13; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then PG_UNIT=$(systemctl list-unit-files 2>/dev/null | grep "^${u}" | head -1 | awk '{print $1}'); break; fi
done
if [ -n "$PG_UNIT" ]; then
    EN=$(systemctl is-enabled "$PG_UNIT" 2>/dev/null || true)
    if echo "$EN" | grep -qE 'enabled|indirect|static'; then
        ok "Service $PG_UNIT enabled at boot ($EN)."
    else
        warn "Service $PG_UNIT is '$EN' — will NOT start on reboot."
        cmd "systemctl enable $PG_UNIT"
    fi
fi

#===============================================================================
hdr "8. POSTGRESQL: SERVER VERSION AND KEY CONFIGURATION"
#===============================================================================
PGVER=$(run_psql "SELECT version();")
if [ -n "$PGVER" ]; then
    PSQL_OK=1
    info "$PGVER"
    SERVER_NUM=$(run_psql "SHOW server_version_num;")
    rec "Check whether this minor release is current for its major branch; if behind, recommend a minor upgrade (needs restart -> justify outage in report)."
else
    crit "Cannot connect to PostgreSQL as postgres (peer). Fix connectivity first — everything below is skipped."
    rec "Try: sudo -u postgres psql   /   check service status, port, unix_socket_directories, pg_hba.conf."
fi

if [ "$PSQL_OK" -eq 1 ]; then
    DATADIR=$(pg_setting data_directory)
    info "data_directory: $DATADIR"
    CONF=$(run_psql "SHOW config_file;")
    HBA=$(run_psql "SHOW hba_file;")
    info "config_file:    $CONF"
    info "hba_file:       $HBA"

    check_setting() {  # name current expected_expr message fix_hint
        local name="$1" val
        val=$(pg_setting "$1")
        printf '       %-32s = %s\n' "$name" "$val"
        echo "$val"
    }

    echo
    info "--- Memory ---"
    SB=$(check_setting shared_buffers)
    ECS=$(check_setting effective_cache_size)
    WM=$(check_setting work_mem)
    MWM=$(check_setting maintenance_work_mem)
    HPST=$(pg_setting huge_pages); printf '       %-32s = %s\n' huge_pages "$HPST"

    # shared_buffers sanity: default 128MB on a big box is a finding
    SB_BYTES=$(run_psql "SELECT setting::bigint * 8192 FROM pg_settings WHERE name='shared_buffers';")
    SB_GB=$(( ${SB_BYTES:-0} / 1024 / 1024 / 1024 ))
    if [ "${SB_BYTES:-0}" -le $((256*1024*1024)) ] && [ "$MEM_TOTAL_GB" -ge 4 ]; then
        warn "shared_buffers=$SB on a ${MEM_TOTAL_GB}GB host — likely untouched default."
        rec "Starting point: ~25% of RAM (here ~$((MEM_TOTAL_GB/4))GB). Requires restart — justify the outage."
        cmd "ALTER SYSTEM SET shared_buffers = '$((MEM_TOTAL_GB/4))GB';  -- then: systemctl restart <unit>"
    else
        ok "shared_buffers=$SB (~${SB_GB}GB) appears deliberately sized (verify vs ${MEM_TOTAL_GB}GB RAM)."
    fi
    if [ "$HP_TOTAL" -eq 0 ] && [ "$SB_GB" -ge 8 ]; then
        info "shared_buffers >= 8GB but no explicit huge pages configured. Optional TLB win:"
        cmd "postgres -D $DATADIR -C shared_memory_size_in_huge_pages   # PG15+; set vm.nr_hugepages accordingly"
    fi

    echo
    info "--- WAL / checkpoints ---"
    check_setting wal_level >/dev/null
    MAXWAL=$(check_setting max_wal_size)
    check_setting checkpoint_timeout >/dev/null
    CCT=$(check_setting checkpoint_completion_target)
    FS=$(check_setting fsync)
    SC=$(check_setting synchronous_commit)
    FPW=$(check_setting full_page_writes)
    DSR=$(check_setting data_sync_retry)
    if [ "$FS" != "on" ]; then
        crit "fsync=$FS — data-loss risk on crash. Almost never acceptable in production."
        cmd "ALTER SYSTEM SET fsync = on; SELECT pg_reload_conf();"
    fi
    if [ "$FPW" != "on" ]; then
        crit "full_page_writes=$FPW — torn-page corruption risk unless the filesystem guarantees atomic 8k writes."
        cmd "ALTER SYSTEM SET full_page_writes = on; SELECT pg_reload_conf();"
    fi
    if [ "$DSR" = "on" ]; then
        crit "data_sync_retry=$DSR — silent data corruption risk on fsync failure. On Linux, retrying fsync after failure can result in lost data because the kernel discards dirty pages."
        cmd "ALTER SYSTEM SET data_sync_retry = off;   -- RESTART required, justify it"
    fi
    [ "$SC" != "on" ] && info "synchronous_commit=$SC — legitimate trade-off, but confirm the customer accepts bounded loss window."
    if [ "$MAXWAL" = "1GB" ]; then
        info "max_wal_size at default 1GB. If log shows frequent 'checkpoints occurring too frequently', raise it:"
        cmd "ALTER SYSTEM SET max_wal_size='4GB'; SELECT pg_reload_conf();"
    fi

    echo
    info "--- Planner / IO ---"
    RPC=$(check_setting random_page_cost)
    check_setting effective_io_concurrency >/dev/null
    if awk "BEGIN{exit !($RPC>=3.9)}" 2>/dev/null; then
        warn "random_page_cost=$RPC on what is almost certainly SSD/EBS. Planner will unfairly penalize index scans."
        cmd "ALTER SYSTEM SET random_page_cost = 1.1; SELECT pg_reload_conf();"
    else
        ok "random_page_cost=$RPC."
    fi

    echo
    info "--- Connections ---"
    MC=$(check_setting max_connections)
    ACT=$(run_psql "SELECT count(*) FROM pg_stat_activity;")
    info "current backends: $ACT / max_connections: $MC"
    if [ "${MC:-100}" -gt 500 ] && [ "$MEM_TOTAL_GB" -lt 32 ]; then
        warn "max_connections=$MC on a ${MEM_TOTAL_GB}GB host — each backend can claim work_mem multiples; OOM risk. Consider pgbouncer instead."
    fi

    echo
    info "--- Autovacuum ---"
    AV=$(check_setting autovacuum)
    check_setting autovacuum_max_workers >/dev/null
    check_setting autovacuum_naptime >/dev/null
    check_setting autovacuum_vacuum_cost_limit >/dev/null
    if [ "$AV" != "on" ]; then
        crit "AUTOVACUUM IS OFF. Bloat and wraparound risk. Classic planted fault."
        cmd "ALTER SYSTEM SET autovacuum = on; SELECT pg_reload_conf();"
    else
        ok "autovacuum is on."
    fi

    echo
    info "--- Logging (turn the lights on early so evidence accumulates) ---"
    LOGC=$(check_setting logging_collector)
    LMDS=$(check_setting log_min_duration_statement)
    LCHK=$(check_setting log_checkpoints)
    LAVM=$(check_setting log_autovacuum_min_duration)
    check_setting log_line_prefix >/dev/null
    if [ "$LMDS" = "-1" ]; then
        info "Slow-query logging disabled."
        cmd "ALTER SYSTEM SET log_min_duration_statement='500ms'; SELECT pg_reload_conf();"
    fi
    [ "$LCHK" = "off" ] && cmd "ALTER SYSTEM SET log_checkpoints=on; SELECT pg_reload_conf();"
    [ "$LAVM" = "-1" ] && cmd "ALTER SYSTEM SET log_autovacuum_min_duration='1s'; SELECT pg_reload_conf();"

    # settings changed from default (fast way to spot sabotage)
    echo
    info "--- All non-default settings (spot deliberate sabotage quickly) ---"
    run_psql_table "SELECT name, setting, unit, source FROM pg_settings WHERE source NOT IN ('default','override') ORDER BY name;" | sed 's/^/       /'

    # pending restart?
    PEND=$(run_psql "SELECT count(*) FROM pg_settings WHERE pending_restart;")
    [ "${PEND:-0}" -gt 0 ] && warn "$PEND setting(s) pending restart — someone changed config without applying it."
fi

#===============================================================================
hdr "9. POSTGRESQL: SECURITY (pg_hba, roles)"
#===============================================================================
if [ "$PSQL_OK" -eq 1 ]; then
    if run_psql "SELECT 1 FROM pg_views WHERE viewname='pg_hba_file_rules';" | grep -q 1; then
        info "pg_hba rules:"
        run_psql_table "SELECT line_number, type, database, user_name, address, auth_method FROM pg_hba_file_rules;" | sed 's/^/       /'
        TRUST=$(run_psql "SELECT count(*) FROM pg_hba_file_rules WHERE auth_method='trust' AND type<>'local';")
        OPEN=$(run_psql "SELECT count(*) FROM pg_hba_file_rules WHERE address IN ('0.0.0.0/0','::/0');")
        [ "${TRUST:-0}" -gt 0 ] && crit "Non-local 'trust' entries in pg_hba.conf — unauthenticated network access."
        [ "${OPEN:-0}" -gt 0 ]  && warn "pg_hba rules open to 0.0.0.0/0 — verify security groups actually restrict this."
        [ "${TRUST:-0}" -eq 0 ] && [ "${OPEN:-0}" -eq 0 ] && ok "No trust-over-network or world-open pg_hba entries."
    fi
    info "Superuser roles:"
    run_psql_table "SELECT rolname, rolcanlogin, rolvaliduntil FROM pg_roles WHERE rolsuper;" | sed 's/^/       /'
    LA=$(pg_setting listen_addresses); info "listen_addresses = $LA"
fi

#===============================================================================
hdr "10. POSTGRESQL: VACUUM HEALTH, BLOAT, WRAPAROUND"
#===============================================================================
if [ "$PSQL_OK" -eq 1 ]; then
    info "Top tables by dead tuples:"
    run_psql_table "SELECT schemaname||'.'||relname AS table, n_live_tup, n_dead_tup, round(100.0*n_dead_tup/nullif(n_live_tup+n_dead_tup,0),1) AS dead_pct, last_autovacuum, last_autoanalyze FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;" | sed 's/^/       /'
    BLOATED=$(run_psql "SELECT count(*) FROM pg_stat_user_tables WHERE n_dead_tup > 100000 AND n_dead_tup > n_live_tup*0.2;")
    if [ "${BLOATED:-0}" -gt 0 ]; then
        warn "$BLOATED table(s) with heavy dead-tuple accumulation. VACUUM (and check why autovacuum didn't cope)."
        cmd "VACUUM (VERBOSE, ANALYZE) <table>;   -- online; VACUUM FULL only with justified lock/outage"
    fi
    NEVER_ANALYZED=$(run_psql "SELECT count(*) FROM pg_stat_user_tables WHERE last_analyze IS NULL AND last_autoanalyze IS NULL AND n_live_tup > 10000;")
    [ "${NEVER_ANALYZED:-0}" -gt 0 ] && warn "$NEVER_ANALYZED sizeable table(s) never analyzed — planner is flying blind. Run ANALYZE; before optimizing any query."

    info "Transaction ID age per database (wraparound check):"
    run_psql_table "SELECT datname, age(datfrozenxid) AS xid_age, round(age(datfrozenxid)/2000000000.0*100,1) AS pct_to_wraparound FROM pg_database ORDER BY 2 DESC;" | sed 's/^/       /'
    MAXAGE=$(run_psql "SELECT max(age(datfrozenxid)) FROM pg_database;")
    if [ "${MAXAGE:-0}" -gt 1500000000 ]; then
        crit "XID age ${MAXAGE} — approaching wraparound. Aggressive VACUUM (FREEZE) needed NOW."
    elif [ "${MAXAGE:-0}" -gt 500000000 ]; then
        warn "XID age ${MAXAGE} — elevated; verify autovacuum freeze is keeping up."
    else
        ok "XID age healthy (${MAXAGE:-?})."
    fi
fi

#===============================================================================
hdr "11. POSTGRESQL: WAL, REPLICATION, SLOTS"
#===============================================================================
if [ "$PSQL_OK" -eq 1 ]; then
    WALDIR_SIZE=$(run_psql "SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir();")
    WALDIR_BYTES=$(run_psql "SELECT coalesce(sum(size),0) FROM pg_ls_waldir();")
    info "pg_wal size: ${WALDIR_SIZE:-unknown}"
    if [ "${WALDIR_BYTES:-0}" -gt $((10*1024*1024*1024)) ]; then
        crit "pg_wal exceeds 10GB. Prime suspects: abandoned replication slot, failing archive_command, huge max_wal_size."
    fi

    SLOTS=$(run_psql "SELECT count(*) FROM pg_replication_slots;")
    if [ "${SLOTS:-0}" -gt 0 ]; then
        info "Replication slots:"
        run_psql_table "SELECT slot_name, slot_type, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal FROM pg_replication_slots;" | sed 's/^/       /'
        INACTIVE=$(run_psql "SELECT count(*) FROM pg_replication_slots WHERE NOT active;")
        if [ "${INACTIVE:-0}" -gt 0 ]; then
            crit "$INACTIVE INACTIVE replication slot(s) retaining WAL — will eventually fill the disk. THE classic planted fault."
            cmd "SELECT pg_drop_replication_slot('<slot_name>');   -- confirm with 'customer' that the consumer is truly gone"
        fi
    else
        info "No replication slots."
    fi

    ISREPLICA=$(run_psql "SELECT pg_is_in_recovery();")
    info "pg_is_in_recovery: $ISREPLICA"
    if [ "$ISREPLICA" = "f" ]; then
        run_psql_table "SELECT client_addr, state, sync_state, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag FROM pg_stat_replication;" | sed 's/^/       /'
    else
        LAG=$(run_psql "SELECT round(extract(epoch from (now()-pg_last_xact_replay_timestamp()))) ;")
        info "This is a STANDBY. Apparent replay lag: ${LAG:-?}s (0 or small = fine if primary is idle)."
    fi

    AM=$(pg_setting archive_mode); AC=$(pg_setting archive_command)
    info "archive_mode=$AM"
    if [ "$AM" = "on" ]; then
        FAILC=$(run_psql "SELECT failed_count FROM pg_stat_archiver;")
        LASTFAIL=$(run_psql "SELECT last_failed_wal FROM pg_stat_archiver;")
        if [ "${FAILC:-0}" -gt 0 ] && [ -n "$LASTFAIL" ]; then
            crit "WAL archiving failures: failed_count=$FAILC (last: $LASTFAIL). Failing archive_command blocks WAL recycling -> disk fills."
            info "archive_command = $AC"
        else
            ok "Archiver: no recorded failures."
        fi
    fi
fi

#===============================================================================
hdr "12. POSTGRESQL: INDEXES AND QUERY-OPT READINESS"
#===============================================================================
if [ "$PSQL_OK" -eq 1 ]; then
    INVALID=$(run_psql "SELECT count(*) FROM pg_index WHERE NOT indisvalid;")
    if [ "${INVALID:-0}" -gt 0 ]; then
        warn "$INVALID INVALID index(es) — failed CREATE INDEX CONCURRENTLY leftovers; they cost writes but serve no reads."
        run_psql_table "SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;" | sed 's/^/       /'
        cmd "REINDEX INDEX CONCURRENTLY <idx>;   -- or DROP INDEX"
    else
        ok "No invalid indexes."
    fi

    info "Largest unused indexes (candidates to question, on primary only):"
    run_psql_table "SELECT s.indexrelname, s.relname, pg_size_pretty(pg_relation_size(s.indexrelid)) AS size, s.idx_scan FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid=s.indexrelid WHERE s.idx_scan=0 AND NOT i.indisunique AND NOT i.indisprimary ORDER BY pg_relation_size(s.indexrelid) DESC LIMIT 5;" | sed 's/^/       /'

    PSS=$(run_psql "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements';")
    if [ "${PSS:-0}" -eq 0 ]; then
        info "pg_stat_statements not installed. If query work is assigned, it's the fastest evidence source."
        cmd "ALTER SYSTEM SET shared_preload_libraries='pg_stat_statements';  -- RESTART required, justify it"
        cmd "CREATE EXTENSION pg_stat_statements;"
        rec "If restart is not justified, work from EXPLAIN (ANALYZE, BUFFERS) + log_min_duration_statement instead."
    else
        ok "pg_stat_statements installed. Top offenders:"
        run_psql_table "SELECT round(total_exec_time::numeric,0) AS total_ms, calls, round(mean_exec_time::numeric,1) AS mean_ms, left(query,80) AS query FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 5;" | sed 's/^/       /'
    fi

    DST=$(pg_setting default_statistics_target)
    info "default_statistics_target = $DST"

    info "Database sizes:"
    run_psql_table "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate=false ORDER BY pg_database_size(datname) DESC;" | sed 's/^/       /'

    info "Long-running / idle-in-transaction sessions:"
    run_psql_table "SELECT pid, usename, state, round(extract(epoch from (now()-xact_start))) AS xact_secs, left(query,60) AS query FROM pg_stat_activity WHERE state<>'idle' AND xact_start IS NOT NULL AND now()-xact_start > interval '1 minute' ORDER BY xact_start;" | sed 's/^/       /'
    IIT=$(run_psql "SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction' AND now()-xact_start > interval '5 minutes';")
    [ "${IIT:-0}" -gt 0 ] && warn "$IIT session(s) idle-in-transaction >5min — blocks vacuum, holds locks. Consider idle_in_transaction_session_timeout."
fi

#===============================================================================
hdr "SUMMARY"
#===============================================================================
echo
printf '   %sCritical findings: %d%s\n' "$C_RED" "$CRIT_COUNT" "$C_OFF"
printf '   %sWarnings:          %d%s\n' "$C_YEL" "$WARN_COUNT" "$C_OFF"
echo
info "Report-writing reminders:"
rec "For every change: what you found -> why it matters (numbers!) -> what you changed -> how to verify."
rec "Any restart/outage must be explicitly justified in the report."
rec "Reserve the final 30-40 minutes for writing. Unfinished-but-documented beats finished-but-undocumented."
rec "Ask the 'customer' (interviewer) before destructive/disruptive actions: dropping slots, restarts, VACUUM FULL."
echo
info "Audit complete: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
