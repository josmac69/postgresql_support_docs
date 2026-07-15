#!/usr/bin/env bash
# ============================================================================
# SCRIPT: pg_kernel_audit.sh
# DESCRIPTION:
#   Comprehensive diagnostic tool that audits Linux kernel parameters, memory
#   settings, CPU frequency governors, I/O schedulers, file limits, and network
#   options for PostgreSQL dedicated database hosts. Discovers both native and
#   dockerized PostgreSQL instances and correlates kernel metrics with database health.
#
# PARAMETERS CHECKED:
#   - Memory: vm.swappiness, vm.overcommit_memory, vm.overcommit_ratio,
#     vm.dirty_background_ratio, vm.dirty_ratio, vm.min_free_kbytes,
#     vm.zone_reclaim_mode, vm.max_map_count, swap space availability.
#   - Huge Pages: HugePages_Total, HugePages_Free, Transparent Huge Pages (THP) and defrag.
#   - SHM / SysV IPC: kernel.shmmax, kernel.shmall, kernel.shmmni, kernel.sem.
#   - Limits: fs.file-max, fs.nr_open, fs.aio-max-nr, kernel.pid_max, kernel.threads-max,
#     ulimit values (open files, max procs, memlock).
#   - Network: net.core.somaxconn, net.ipv4.tcp_max_syn_backlog, net.ipv4.tcp_tw_reuse,
#     net.ipv4.tcp_keepalive_*, net.ipv4.tcp_slow_start_after_idle, net.ipv4.tcp_congestion_control.
#   - CPU & Storage: cpufreq scaling governor, NUMA balance, kernel.sched_autogroup_enabled,
#     kernel.sched_migration_cost_ns, block device rq_affinity, I/O scheduler, read_ahead_kb,
#     and filesystem mount options (noatime).
#   - Database: Version, data directory, active backups, replication/replica slots, GUCs.
#   - Logs: dmesg memory events (OOM killer, segfaults), systemd postgresql service status.
#
# RECOMMENDATIONS & RATIONALE:
#   - If vm.swappiness > 10: Recommends lowering to 1-10. Rationale: Minimizes swap space page-out of
#     PostgreSQL shared buffers, preventing heavy performance drops.
#   - If vm.overcommit_memory != 2: Recommends 2. Rationale: Prevents overcommitting RAM, protecting the
#     main postmaster process from sudden termination by the OOM killer.
#   - If vm.dirty_ratio is high: Recommends lowering to 15 (background 5). Rationale: Prevents large dirty page
#     flushes that stall disk operations and cause transaction stalls.
#   - If vm.zone_reclaim_mode != 0: Recommends 0. Rationale: Reclaim loop overhead on NUMA nodes causes
#     severe performance degradation for the database buffer cache.
#   - If THP is enabled: Recommends disabling. Rationale: THP page allocation and background memory
#     compaction cause severe query execution latency spikes.
#   - If sched_autogroup_enabled = 1: Recommends 0. Rationale: Prevents database server CPU starvation
#     by other user shell tasks.
#   - If mount atime is enabled: Recommends noatime. Rationale: Eliminates unnecessary disk write operations
#     for recording read access times.
#
# USAGE:
#   ./pg_kernel_audit.sh
#   ./pg_kernel_audit.sh --sysctl  # Emitter ready-to-apply sysctl.d configuration
# ============================================================================

set -u
LC_ALL=C

WANT_SYSCTL_OUT=0
[ "${1:-}" = "--sysctl" ] && WANT_SYSCTL_OUT=1

# ---------- colours (disabled if not a tty) ----------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""; C_RST=""
fi

FIX_LINES=()   # collected sysctl fixes for --sysctl output

# ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

get_sysctl() {
    # echo current value of a sysctl key, or empty if absent
    local cmd="sysctl"
    if ! command -v sysctl >/dev/null 2>&1; then
        if [ -x /sbin/sysctl ]; then
            cmd="/sbin/sysctl"
        elif [ -x /usr/sbin/sysctl ]; then
            cmd="/usr/sbin/sysctl"
        fi
    fi
    $cmd -n "$1" 2>/dev/null
}

# print one audit line
# args: label current recommended status detail
row() {
    local label="$1" cur="$2" rec="$3" status="$4" detail="${5:-}"
    local mark col
    case "$status" in
        OK)   mark="OK   "; col="$C_GRN" ;;
        WARN) mark="WARN "; col="$C_YEL" ;;
        FIX)  mark="FIX  "; col="$C_RED" ;;
        INFO) mark="INFO "; col="$C_BLU" ;;
        *)    mark="?    "; col="$C_RST" ;;
    esac
    printf "%s[%s]%s %-34s cur=%-14s rec=%-14s %s\n" \
        "$col" "$mark" "$C_RST" "$label" "${cur:-<unset>}" "${rec:--}" "$detail"
}

# numeric compare: is $1 >= $2 ?
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0<=b+0)}'; }

# collect a sysctl fix line for --sysctl output
addfix() { FIX_LINES+=("$1 = $2"); }

hr() { printf '%s\n' "----------------------------------------------------------------------------"; }

# ---------- system facts ----------
OS_ID="unknown"; OS_PRETTY="unknown"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
fi
FAMILY="other"
case "$OS_ID" in
    rhel|centos|rocky|almalinux|fedora|ol|amzn) FAMILY="rhel" ;;
    debian|ubuntu|linuxmint)                    FAMILY="debian" ;;
esac

KERNEL=$(uname -r)
ARCH=$(uname -m)
CPUS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo "?")
PAGESIZE=$(getconf PAGE_SIZE 2>/dev/null || echo 4096)

MEM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
MEM_BYTES=$(( MEM_KB * 1024 ))
MEM_GB=$(awk -v k="$MEM_KB" 'BEGIN{printf "%.1f", k/1024/1024}')

# ============================================================================
echo
echo "${C_BOLD}PostgreSQL Linux Kernel Audit${C_RST}"
hr
printf "Host        : %s\n" "$(hostname -f 2>/dev/null || hostname)"
printf "OS          : %s  (family: %s)\n" "$OS_PRETTY" "$FAMILY"
printf "Kernel      : %s   Arch: %s\n" "$KERNEL" "$ARCH"
printf "CPUs        : %s   Page size: %s bytes\n" "$CPUS" "$PAGESIZE"
printf "RAM         : %s GB (%s bytes)\n" "$MEM_GB" "$MEM_BYTES"
printf "Run as      : %s\n" "$(id -un)"
[ "$(id -u)" -ne 0 ] && printf "%sNote:%s not root, some values may be unreadable.\n" "$C_YEL" "$C_RST"
hr

# ============================================================================
echo "${C_BOLD}Memory management${C_RST}"

# --- vm.swappiness ---
v=$(get_sysctl vm.swappiness)
if [ -n "$v" ]; then
    if le "$v" 10; then row "vm.swappiness" "$v" "1-10" OK
    else row "vm.swappiness" "$v" "1" FIX "reduce swapping of DB pages"; addfix vm.swappiness 1; fi
fi

# --- vm.overcommit_memory / ratio ---
v=$(get_sysctl vm.overcommit_memory)
if [ "$v" = "2" ]; then row "vm.overcommit_memory" "$v" "2" OK "strict, avoids OOM-killing postmaster"
else row "vm.overcommit_memory" "$v" "2" WARN "consider 2 to prevent OOM killer on postmaster"; fi
v=$(get_sysctl vm.overcommit_ratio)
[ -n "$v" ] && row "vm.overcommit_ratio" "$v" "80-90" INFO "only relevant when overcommit_memory=2"

# --- dirty ratios (SSD/NVMe: keep low so flushes are smooth) ---
v=$(get_sysctl vm.dirty_background_ratio)
if [ -n "$v" ]; then
    if le "$v" 10; then row "vm.dirty_background_ratio" "$v" "3-5" OK
    else row "vm.dirty_background_ratio" "$v" "5" FIX "lower for smoother checkpoints"; addfix vm.dirty_background_ratio 5; fi
fi
v=$(get_sysctl vm.dirty_ratio)
if [ -n "$v" ]; then
    if le "$v" 20; then row "vm.dirty_ratio" "$v" "10-15" OK
    else row "vm.dirty_ratio" "$v" "15" FIX "avoid large write stalls"; addfix vm.dirty_ratio 15; fi
fi
# byte-based alternative (preferred on large-RAM boxes)
vb=$(get_sysctl vm.dirty_background_bytes)
vr=$(get_sysctl vm.dirty_bytes)
[ "${vb:-0}" != "0" ] && row "vm.dirty_background_bytes" "$vb" "-" INFO "byte-based override in use"
[ "${vr:-0}" != "0" ] && row "vm.dirty_bytes" "$vr" "-" INFO "byte-based override in use"

# --- min_free_kbytes ---
v=$(get_sysctl vm.min_free_kbytes)
[ -n "$v" ] && row "vm.min_free_kbytes" "$v" "~1-2% RAM" INFO "keeps reserve for atomic allocs"

# --- zone_reclaim_mode (must be 0 on NUMA DB hosts) ---
v=$(get_sysctl vm.zone_reclaim_mode)
if [ -n "$v" ]; then
    if [ "$v" = "0" ]; then row "vm.zone_reclaim_mode" "$v" "0" OK
    else row "vm.zone_reclaim_mode" "$v" "0" FIX "NUMA reclaim hurts PG buffer cache"; addfix vm.zone_reclaim_mode 0; fi
fi

# --- max_map_count (needed for many connections / extensions) ---
v=$(get_sysctl vm.max_map_count)
if [ -n "$v" ]; then
    if ge "$v" 262144; then row "vm.max_map_count" "$v" ">=262144" OK
    else row "vm.max_map_count" "$v" "262144" WARN "raise for high mmap usage"; addfix vm.max_map_count 262144; fi
fi

# --- swap check ---
SWAP_TOTAL=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
if [ -n "$SWAP_TOTAL" ]; then
    SWAP_GB=$(awk -v k="$SWAP_TOTAL" 'BEGIN{printf "%.1f", k/1024/1024}')
    if [ "$SWAP_TOTAL" -eq 0 ]; then
        row "Swap space" "0.0 GB" ">0" WARN "no swap space; risk of sudden OOM kills"
    else
        row "Swap space" "${SWAP_GB} GB" ">0" OK "swap configured"
    fi
fi

# --- vm.dirty_*_bytes on large-RAM systems (>64GB) ---
if ge "$MEM_GB" 64.0; then
    vb=$(get_sysctl vm.dirty_background_bytes)
    vr=$(get_sysctl vm.dirty_bytes)
    if [ "${vb:-0}" = "0" ] && [ "${vr:-0}" = "0" ]; then
        row "vm.dirty_ratio on >64GB RAM" "ratios in use" "bytes rec" WARN "set dirty_*_bytes to prevent flush spikes"
    fi
fi

hr

# ============================================================================
echo "${C_BOLD}Huge pages${C_RST}"
HP_TOTAL=$(awk '/HugePages_Total/{print $2}' /proc/meminfo)
HP_FREE=$(awk '/HugePages_Free/{print $2}' /proc/meminfo)
HP_SIZE=$(awk '/Hugepagesize/{print $2}' /proc/meminfo)
row "HugePages_Total" "${HP_TOTAL:-0}" "sized to shared_buffers" \
    "$( [ "${HP_TOTAL:-0}" -gt 0 ] && echo INFO || echo WARN )" \
    "$( [ "${HP_TOTAL:-0}" -gt 0 ] && echo "reserved (${HP_SIZE} kB pages)" || echo "none reserved; set vm.nr_hugepages after knowing shared_buffers" )"
[ "${HP_TOTAL:-0}" -gt 0 ] && row "HugePages_Free" "${HP_FREE:-0}" "-" INFO

# Transparent Huge Pages should be 'never' for PostgreSQL
THP="unknown"
for f in /sys/kernel/mm/transparent_hugepage/enabled \
         /sys/kernel/mm/redhat_transparent_hugepage/enabled; do
    if [ -r "$f" ]; then
        THP=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$f")
        break
    fi
done
if [ "$THP" = "never" ]; then row "THP (transparent_hugepage)" "$THP" "never" OK
elif [ "$THP" = "unknown" ]; then row "THP (transparent_hugepage)" "$THP" "never" INFO "sysfs not readable"
else row "THP (transparent_hugepage)" "$THP" "never" FIX "disable: THP causes latency spikes in PG"; fi

# THP defrag
for f in /sys/kernel/mm/transparent_hugepage/defrag \
         /sys/kernel/mm/redhat_transparent_hugepage/defrag; do
    if [ -r "$f" ]; then
        d=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$f")
        [ "$d" = "never" ] && row "THP defrag" "$d" "never" OK \
            || row "THP defrag" "$d" "never" WARN "set to never with THP"
        break
    fi
done

hr

# ============================================================================
echo "${C_BOLD}Kernel SHM / SysV IPC${C_RST}"
# Modern PG uses mmap POSIX shm mostly, but SysV limits still matter for some setups.
v=$(get_sysctl kernel.shmmax)
if [ -n "$v" ]; then
    if ge "$v" "$MEM_BYTES"; then row "kernel.shmmax" "$v" ">=RAM" OK
    else row "kernel.shmmax" "$v" "$MEM_BYTES" WARN "usually fine on modern kernels (default ~ULONG_MAX)"; fi
fi
v=$(get_sysctl kernel.shmall)
REC_SHMALL=$(( MEM_BYTES / PAGESIZE ))
if [ -n "$v" ]; then
    if ge "$v" "$REC_SHMALL"; then row "kernel.shmall" "$v" ">=RAM/pagesz" OK
    else row "kernel.shmall" "$v" "$REC_SHMALL" WARN "pages: RAM/pagesize"; fi
fi
v=$(get_sysctl kernel.shmmni); [ -n "$v" ] && row "kernel.shmmni" "$v" "4096" INFO
v=$(get_sysctl kernel.sem);    [ -n "$v" ] && row "kernel.sem" "$v" "250 32000 100 128" INFO "SEMMSL SEMMNS SEMOPM SEMMNI"

hr

# ============================================================================
echo "${C_BOLD}Process / file limits${C_RST}"
v=$(get_sysctl fs.file-max)
if [ -n "$v" ]; then
    if ge "$v" 2000000; then row "fs.file-max" "$v" ">=2000000" OK
    else row "fs.file-max" "$v" "2000000" WARN "raise for many connections"; addfix fs.file-max 2000000; fi
fi
v=$(get_sysctl fs.nr_open); [ -n "$v" ] && row "fs.nr_open" "$v" ">=1048576" INFO
v=$(get_sysctl fs.aio-max-nr)
if [ -n "$v" ]; then
    if ge "$v" 1048576; then row "fs.aio-max-nr" "$v" ">=1048576" OK
    else row "fs.aio-max-nr" "$v" "1048576" WARN "raise for PG18 AIO / io_uring workloads"; addfix fs.aio-max-nr 1048576; fi
fi
v=$(get_sysctl kernel.pid_max); [ -n "$v" ] && row "kernel.pid_max" "$v" ">=4194304" INFO
v=$(get_sysctl kernel.threads-max); [ -n "$v" ] && row "kernel.threads-max" "$v" "-" INFO

# ulimits for current shell (postgres user should mirror these in limits.conf)
row "ulimit -n (open files)"   "$(ulimit -n)"   "65536+"  INFO "set in security/limits.d for postgres"
row "ulimit -u (max procs)"    "$(ulimit -u)"   "high"    INFO
row "ulimit -l (memlock kB)"   "$(ulimit -l)"   "unlimited" INFO "needed for huge pages memlock"

hr

# ============================================================================
echo "${C_BOLD}Network (relevant to connection-heavy PG)${C_RST}"
declare -A NETREC=(
    [net.core.somaxconn]="1024"
    [net.core.netdev_max_backlog]="16384"
    [net.ipv4.tcp_max_syn_backlog]="8192"
    [net.ipv4.tcp_tw_reuse]="1"
    [net.ipv4.tcp_fin_timeout]="10"
    [net.ipv4.tcp_keepalive_time]="120"
    [net.ipv4.tcp_keepalive_intvl]="30"
    [net.ipv4.tcp_keepalive_probes]="5"
    [net.ipv4.ip_local_port_range]="1024 65535"
)
for k in net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog \
         net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time \
         net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes net.ipv4.ip_local_port_range; do
    v=$(get_sysctl "$k")
    rec="${NETREC[$k]}"
    [ -z "$v" ] && continue
    case "$k" in
        net.core.somaxconn)
            if ge "$v" 1024; then row "$k" "$v" "$rec" OK
            else row "$k" "$v" "$rec" WARN "raise to accept connection bursts"; addfix "$k" 1024; fi ;;
        net.ipv4.tcp_tw_reuse)
            [ "$v" = "1" ] && row "$k" "$v" "$rec" OK || row "$k" "$v" "$rec" INFO ;;
        *)
            row "$k" "$v" "$rec" INFO ;;
    esac
done

# --- tcp_slow_start_after_idle & tcp_congestion_control ---
v=$(get_sysctl net.ipv4.tcp_slow_start_after_idle)
if [ -n "$v" ]; then
    if [ "$v" = "0" ]; then row "net.ipv4.tcp_slow_start_after_idle" "$v" "0" OK
    else row "net.ipv4.tcp_slow_start_after_idle" "$v" "0" WARN "disable slow start after idle"; addfix net.ipv4.tcp_slow_start_after_idle 0; fi
fi
v=$(get_sysctl net.ipv4.tcp_congestion_control)
[ -n "$v" ] && row "net.ipv4.tcp_congestion_control" "$v" "bbr/cubic" INFO "BBR preferred for high network throughput"

hr

# ============================================================================
echo "${C_BOLD}Scheduler / CPU / storage${C_RST}"

# CPU governor
GOV="n/a"
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    if [ "$GOV" = "performance" ]; then row "CPU governor" "$GOV" "performance" OK
    else row "CPU governor" "$GOV" "performance" WARN "set performance for consistent latency"; fi
else
    row "CPU governor" "$GOV" "performance" INFO "cpufreq not exposed (VM?)"
fi

# NUMA
if have numactl; then
    NODES=$(numactl --hardware 2>/dev/null | awk '/available:/{print $2}')
    row "NUMA nodes" "${NODES:-?}" "-" INFO "$( [ "${NODES:-1}" -gt 1 ] && echo 'multi-node: consider numa balancing / interleave' || echo 'single node' )"
    nb=$(get_sysctl kernel.numa_balancing)
    [ -n "$nb" ] && row "kernel.numa_balancing" "$nb" "0 (dedicated DB)" \
        "$( [ "$nb" = "0" ] && echo OK || echo WARN )" "auto-balancing can hurt PG"
else
    row "NUMA" "numactl absent" "-" INFO "install numactl to inspect topology"
fi

# --- CPU scheduler tweaks ---
v=$(get_sysctl kernel.sched_autogroup_enabled)
if [ -n "$v" ]; then
    if [ "$v" = "0" ]; then row "kernel.sched_autogroup_enabled" "$v" "0" OK
    else row "kernel.sched_autogroup_enabled" "$v" "0" WARN "disable autogrouping to avoid PG starvation"; addfix kernel.sched_autogroup_enabled 0; fi
fi
v=$(get_sysctl kernel.sched_migration_cost_ns)
if [ -n "$v" ]; then
    if ge "$v" 1000000; then row "kernel.sched_migration_cost_ns" "$v" ">=1000000" OK
    else row "kernel.sched_migration_cost_ns" "$v" "1000000" INFO "raise on high-core systems to avoid cache bounces"; fi
fi

# I/O scheduler for block devices (recommend none/noop/mq-deadline on SSD/NVMe)
for dev in /sys/block/sd? /sys/block/nvme?n? /sys/block/vd?; do
    [ -e "$dev/queue/scheduler" ] || continue
    d=$(basename "$dev")
    sched=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$dev/queue/scheduler")
    rot=$(cat "$dev/queue/rotational" 2>/dev/null)
    if [ "$rot" = "0" ]; then
        case "$sched" in
            none|noop|mq-deadline) row "ioscheduler $d (SSD)" "$sched" "none/mq-deadline" OK ;;
            *) row "ioscheduler $d (SSD)" "$sched" "none/mq-deadline" WARN "change for SSD/NVMe" ;;
        esac
    else
        row "ioscheduler $d (HDD)" "$sched" "mq-deadline" INFO
    fi
    ra=$(cat "$dev/queue/read_ahead_kb" 2>/dev/null)
    [ -n "$ra" ] && row "read_ahead_kb $d" "$ra" "128-4096" INFO
    
    aff=$(cat "$dev/queue/rq_affinity" 2>/dev/null)
    [ -n "$aff" ] && row "rq_affinity $d" "$aff" "2" "$( [ "$aff" = "2" ] && echo OK || echo INFO )" "2 binds I/O completion to initiating CPU"
done

# Filesystem mounts (check for noatime on ext4/xfs)
if [ -r /proc/mounts ]; then
    while read -r dev mp fstype opts rest; do
        if [ "$fstype" = "ext4" ] || [ "$fstype" = "xfs" ]; then
            # Skip docker/overlay/container virtual mounts
            [[ "$dev" =~ ^/dev/ ]] || continue
            if [[ "$opts" =~ noatime ]]; then
                row "mount $mp ($fstype)" "noatime" "noatime" OK
            elif [[ "$opts" =~ relatime ]]; then
                row "mount $mp ($fstype)" "relatime" "noatime" INFO "relatime is OK, but noatime is better for DB"
            else
                row "mount $mp ($fstype)" "atime" "noatime" WARN "disable atime writes for performance"
            fi
        fi
    done < /proc/mounts
fi

hr

# ============================================================================
echo "${C_BOLD}Time / misc${C_RST}"
# clocksource
if [ -r /sys/devices/system/clocksource/clocksource0/current_clocksource ]; then
    cs=$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)
    if [ "$cs" = "tsc" ]; then row "clocksource" "$cs" "tsc" OK
    else row "clocksource" "$cs" "tsc" WARN "tsc gives cheaper gettimeofday for PG timing"; fi
fi
# NTP/chrony sync
if have timedatectl; then
    sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    row "time sync (NTP)" "${sync:-unknown}" "yes" \
        "$( [ "$sync" = "yes" ] && echo OK || echo WARN )" "clock drift breaks replication/PITR reasoning"
fi
# SELinux / AppArmor
if [ "$FAMILY" = "rhel" ] && have getenforce; then
    row "SELinux" "$(getenforce)" "Enforcing/Permissive" INFO "ensure PG contexts correct if Enforcing"
elif [ "$FAMILY" = "debian" ] && have aa-status; then
    aa-status --enabled 2>/dev/null && row "AppArmor" "enabled" "-" INFO || row "AppArmor" "disabled" "-" INFO
fi

hr

# ============================================================================
echo "${C_BOLD}PostgreSQL Instance & Replication Discovery${C_RST}"
hr

# SQL Runner that handles native local connection, password-less postgres local, and Docker instances
run_sql_native() {
    local port="$1"
    local db="$2"
    local query="$3"
    local out
    
    # Try local socket/TCP connections with different methods
    out=$(psql -h 127.0.0.1 -p "$port" -U postgres -d "$db" -t -A -c "$query" 2>/dev/null)
    if [ $? -eq 0 ]; then echo "$out"; return 0; fi
    
    out=$(psql -p "$port" -d "$db" -t -A -c "$query" 2>/dev/null)
    if [ $? -eq 0 ]; then echo "$out"; return 0; fi
    
    out=$(sudo -n -u postgres psql -p "$port" -d "$db" -t -A -c "$query" 2>/dev/null)
    if [ $? -eq 0 ]; then echo "$out"; return 0; fi
    
    return 1
}

run_sql_docker() {
    local container="$1"
    local db="$2"
    local query="$3"
    local out
    
    out=$(docker exec -i "$container" psql -U postgres -d "$db" -t -A -c "$query" 2>/dev/null)
    if [ $? -eq 0 ]; then echo "$out"; return 0; fi
    
    return 1
}

# Helper to find a database we can connect to
find_db_native() {
    local port="$1"
    for db in tuning_lab postgres template1; do
        if run_sql_native "$port" "$db" "SELECT 1;" >/dev/null 2>&1; then
            echo "$db"
            return 0
        fi
    done
    return 1
}

find_db_docker() {
    local container="$1"
    for db in tuning_lab postgres template1; do
        if run_sql_docker "$container" "$db" "SELECT 1;" >/dev/null 2>&1; then
            echo "$db"
            return 0
        fi
    done
    return 1
}

# 1. Discover dockerized postgres instances
DOCKER_TARGETS=()
if have docker; then
    for c in $(docker ps --format "{{.Names}}" 2>/dev/null); do
        if docker exec -i "$c" psql -V >/dev/null 2>&1; then
            DOCKER_TARGETS+=("$c")
        fi
    done
fi

# 2. Discover native postgres ports
ports_ss=$(ss -ltn 2>/dev/null | awk '{print $4}' | awk -F':' '{print $NF}' | grep -E '^[0-9]+$')
ports_ps=$(ps -ef 2>/dev/null | grep -E 'postgres|postmaster' | grep -o -E '(\-p|\-\-port)[= ]*[0-9]+' | grep -o -E '[0-9]+')
ports_sockets=""
if [ -d /var/run/postgresql ]; then
    ports_sockets=$(find /var/run/postgresql/ -name ".s.PGSQL.*" 2>/dev/null | awk -F'.' '{print $NF}' | grep -E '^[0-9]+$')
fi
ALL_PORTS=$(echo -e "${ports_ss:-}\n${ports_ps:-}\n${ports_sockets:-}\n5432" | grep -E '^[0-9]+$' | sort -u)

NATIVE_TARGETS=()
for port in $ALL_PORTS; do
    # Skip ports that are mapped by running Docker containers (since we'll query them directly via Docker)
    if have docker; then
        mapped=$(docker ps --format "{{.Ports}}" 2>/dev/null | grep -E "0\.0\.0\.0:$port|\[::\]:$port")
        [ -n "$mapped" ] && continue
    fi
    # Filter to likely postgres candidate ports
    if [ "$port" -eq 5432 ] || { [ "$port" -ge 5400 ] && [ "$port" -le 5499 ]; } || echo "${ports_ps} ${ports_sockets}" | grep -q -w "$port"; then
        NATIVE_TARGETS+=("$port")
    fi
done

found_any=0

# Perform audit on Docker targets
for c in "${DOCKER_TARGETS[@]}"; do
    db=$(find_db_docker "$c")
    [ -z "$db" ] && continue
    found_any=1
    
    version=$(run_sql_docker "$c" "$db" "SELECT version();")
    in_recovery=$(run_sql_docker "$c" "$db" "SELECT pg_is_in_recovery();")
    role="Primary"
    [ "$in_recovery" = "t" ] && role="Replica/Standby"
    
    data_dir=$(run_sql_docker "$c" "$db" "SHOW data_directory;")
    hba_file=$(run_sql_docker "$c" "$db" "SHOW hba_file;")
    
    wal_size_bytes=$(run_sql_docker "$c" "$db" "SELECT sum(size) FROM pg_ls_waldir();")
    wal_size_pretty="n/a"
    if [ -n "$wal_size_bytes" ] && [ "$wal_size_bytes" -ne 0 ] 2>/dev/null; then
        wal_size_pretty=$(run_sql_docker "$c" "$db" "SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir();")
    fi
    
    shared_buffers=$(run_sql_docker "$c" "$db" "SHOW shared_buffers;")
    max_connections=$(run_sql_docker "$c" "$db" "SHOW max_connections;")
    work_mem=$(run_sql_docker "$c" "$db" "SHOW work_mem;")
    maintenance_work_mem=$(run_sql_docker "$c" "$db" "SHOW maintenance_work_mem;")
    archive_mode=$(run_sql_docker "$c" "$db" "SHOW archive_mode;")
    archive_command=$(run_sql_docker "$c" "$db" "SHOW archive_command;")
    
    printf "%s%-25s%s: %s (DB: %s)\n" "$C_BOLD" "Docker Container: $c" "$C_RST" "$role" "$db"
    echo "  [Version]     : $version"
    echo "  [Data Dir]    : $data_dir"
    
    # Check if backup_label is present in container data directory
    if docker exec -i "$c" [ -f "$data_dir/backup_label" ] 2>/dev/null; then
        echo "  [Backup State]: Active base backup currently running (backup_label exists)!"
    else
        echo "  [Backup State]: No active base backup detected"
    fi
    
    # Check archiver stats
    archiver_stats=$(run_sql_docker "$c" "$db" "SELECT failed_count || ' failures, last failed at ' || COALESCE(last_failed_time::text, 'never') FROM pg_stat_archiver;")
    if [ -n "$archiver_stats" ]; then
        echo "  [Archiver Stat]: $archiver_stats"
    fi
    
    echo "  [WAL Size]    : $wal_size_pretty"
    echo "  [Config GUCs] : shared_buffers=$shared_buffers, max_connections=$max_connections, work_mem=$work_mem, maintenance_work_mem=$maintenance_work_mem"
    echo "  [Archiving]   : archive_mode=$archive_mode, archive_command='$archive_command'"
    
    if [ "$role" = "Primary" ]; then
        replicas=$(run_sql_docker "$c" "$db" "SELECT client_addr, state, sync_state FROM pg_stat_replication;")
        if [ -n "$replicas" ]; then
            echo "  [Replicas]    :"
            echo "$replicas" | sed 's/^/    - /'
        else
            echo "  [Replicas]    : None active"
        fi
        slots=$(run_sql_docker "$c" "$db" "SELECT slot_name, plugin, active FROM pg_replication_slots;")
        if [ -n "$slots" ]; then
            echo "  [Repl Slots]  :"
            echo "$slots" | sed 's/^/    - /'
        fi
    else
        receiver=$(run_sql_docker "$c" "$db" "SELECT status, receive_start_lsn FROM pg_stat_wal_receiver;")
        [ -n "$receiver" ] && echo "  [Receiver]    : $receiver"
    fi
    
    users=$(run_sql_docker "$c" "$db" "SELECT rolname, rolsuper, rolreplication FROM pg_roles LIMIT 10;")
    if [ -n "$users" ]; then
        echo "  [Roles (10)]  :"
        echo "$users" | sed 's/^/    - /'
    fi
    
    if [ -n "$hba_file" ]; then
        hba_lines=$(docker exec -i "$c" cat "$hba_file" 2>/dev/null | grep -vE '^#|^$')
        if [ -n "$hba_lines" ]; then
            echo "  [Auth Rules]  :"
            echo "$hba_lines" | head -n 5 | sed 's/^/    - /'
        fi
    fi
    echo
done

# Perform audit on Native targets
for port in "${NATIVE_TARGETS[@]}"; do
    db=$(find_db_native "$port")
    [ -z "$db" ] && continue
    found_any=1
    
    version=$(run_sql_native "$port" "$db" "SELECT version();")
    in_recovery=$(run_sql_native "$port" "$db" "SELECT pg_is_in_recovery();")
    role="Primary"
    [ "$in_recovery" = "t" ] && role="Replica/Standby"
    
    data_dir=$(run_sql_native "$port" "$db" "SHOW data_directory;")
    hba_file=$(run_sql_native "$port" "$db" "SHOW hba_file;")
    
    wal_size_bytes=$(run_sql_native "$port" "$db" "SELECT sum(size) FROM pg_ls_waldir();")
    wal_size_pretty="n/a"
    if [ -n "$wal_size_bytes" ] && [ "$wal_size_bytes" -ne 0 ] 2>/dev/null; then
        wal_size_pretty=$(run_sql_native "$port" "$db" "SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir();")
    fi
    
    shared_buffers=$(run_sql_native "$port" "$db" "SHOW shared_buffers;")
    max_connections=$(run_sql_native "$port" "$db" "SHOW max_connections;")
    work_mem=$(run_sql_native "$port" "$db" "SHOW work_mem;")
    maintenance_work_mem=$(run_sql_native "$port" "$db" "SHOW maintenance_work_mem;")
    archive_mode=$(run_sql_native "$port" "$db" "SHOW archive_mode;")
    archive_command=$(run_sql_native "$port" "$db" "SHOW archive_command;")
    
    printf "%s%-25s%s: %s (DB: %s)\n" "$C_BOLD" "Native Instance (Port $port)" "$C_RST" "$role" "$db"
    echo "  [Version]     : $version"
    echo "  [Data Dir]    : $data_dir"
    
    if [ -n "$data_dir" ]; then
        df_info=$(df -h "$data_dir" 2>/dev/null | tail -n 1 | awk '{printf "%s size, %s used (%s free)", $2, $3, $4}')
        [ -n "$df_info" ] && echo "  [Disk Usage]  : $df_info"
        if [ -f "$data_dir/backup_label" ]; then
            echo "  [Backup State]: Active base backup currently running (backup_label exists)!"
        else
            echo "  [Backup State]: No active base backup detected"
        fi
    fi
    
    # Check archiver stats
    archiver_stats=$(run_sql_native "$port" "$db" "SELECT failed_count || ' failures, last failed at ' || COALESCE(last_failed_time::text, 'never') FROM pg_stat_archiver;")
    if [ -n "$archiver_stats" ]; then
        echo "  [Archiver Stat]: $archiver_stats"
    fi
    
    echo "  [WAL Size]    : $wal_size_pretty"
    echo "  [Config GUCs] : shared_buffers=$shared_buffers, max_connections=$max_connections, work_mem=$work_mem, maintenance_work_mem=$maintenance_work_mem"
    echo "  [Archiving]   : archive_mode=$archive_mode, archive_command='$archive_command'"
    
    if [ "$role" = "Primary" ]; then
        replicas=$(run_sql_native "$port" "$db" "SELECT client_addr, state, sync_state FROM pg_stat_replication;")
        if [ -n "$replicas" ]; then
            echo "  [Replicas]    :"
            echo "$replicas" | sed 's/^/    - /'
        else
            echo "  [Replicas]    : None active"
        fi
        slots=$(run_sql_native "$port" "$db" "SELECT slot_name, plugin, active FROM pg_replication_slots;")
        if [ -n "$slots" ]; then
            echo "  [Repl Slots]  :"
            echo "$slots" | sed 's/^/    - /'
        fi
    else
        receiver=$(run_sql_native "$port" "$db" "SELECT status, receive_start_lsn FROM pg_stat_wal_receiver;")
        [ -n "$receiver" ] && echo "  [Receiver]    : $receiver"
    fi
    
    users=$(run_sql_native "$port" "$db" "SELECT rolname, rolsuper, rolreplication FROM pg_roles LIMIT 10;")
    if [ -n "$users" ]; then
        echo "  [Roles (10)]  :"
        echo "$users" | sed 's/^/    - /'
    fi
    
    if [ -n "$hba_file" ] && [ -r "$hba_file" ]; then
        echo "  [Auth Rules]  :"
        grep -vE '^#|^$' "$hba_file" | head -n 5 | sed 's/^/    - /'
    fi
    echo
done

if [ "$found_any" -eq 0 ]; then
    echo "No responsive PostgreSQL instances detected."
fi

# Diagnostic checks (dmesg / OOMs / PostgreSQL processes)
echo
echo "${C_BOLD}System Diagnostic Log & Process Recon${C_RST}"
hr
echo "  [Running DB processes (max 5)]:"
ps aux | grep -E 'postgres|postmaster' | grep -v grep | head -n 5 | sed 's/^/    /'
echo
echo "  [System Resources (free -m)]:"
free -m | sed 's/^/    /'
echo
echo "  [System Resources (nproc / lscpu)]:"
echo "    nproc: $(nproc 2>/dev/null)"
if have lscpu; then
    lscpu | grep -E 'Architecture|CPU\\(s\\)|Thread\\(s\\) per core|Core\\(s\\) per socket|Socket\\(s\\)|Model name' | sed 's/^/    /'
fi
echo
echo "  [Systemd Service Status (postgresql*)]:"
if have systemctl; then
    systemctl status "postgresql*" --no-pager 2>/dev/null | head -n 15 | sed 's/^/    /'
else
    echo "    systemctl not available"
fi
echo
echo "  [Recent OOM / Crash logs in dmesg (last 5)]:"
dmesg -T 2>/dev/null | grep -iE 'oom[-_]killer|out of memory|segfault|postgresql' | tail -n 5 | sed 's/^/    /'

hr
# Optional: emit a ready-to-apply sysctl.d snippet for all collected FIXes
if [ "$WANT_SYSCTL_OUT" -eq 1 ]; then
    echo
    echo "${C_BOLD}Suggested /etc/sysctl.d/99-postgresql.conf (review before applying)${C_RST}"
    hr
    if [ "${#FIX_LINES[@]}" -eq 0 ]; then
        echo "# No sysctl FIXes detected. System already within recommended ranges."
    else
        echo "# Generated by pg_kernel_audit.sh on $(date -u +%FT%TZ)"
        echo "# Review each line. Apply with: sudo sysctl --system"
        printf '%s\n' "${FIX_LINES[@]}" | sort -u
    fi
    hr
else
    echo
    echo "${C_BOLD}Instructions for Applying & Persisting OS Settings:${C_RST}"
    hr
    echo "1. Sysctl Settings (vm.swappiness, vm.overcommit_*, vm.dirty_*, net.*, kernel.*, fs.aio-max-nr)"
    echo "   - Apply instantly:    sudo sysctl -w <key>=<value> (e.g., sudo sysctl -w vm.swappiness=1)"
    echo "   - Persist on boot:    Run with '--sysctl' to generate snippet, save to /etc/sysctl.d/99-postgresql.conf"
    echo "                         Reload with: sudo sysctl --system"
    echo "   - Reboot required:    No"
    echo
    echo "2. Transparent Huge Pages (THP)"
    echo "   - Apply instantly:    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/{enabled,defrag}"
    echo "   - Persist on boot:    Add 'transparent_hugepage=never' to GRUB_CMDLINE_LINUX_DEFAULT"
    echo "                         in /etc/default/grub, and run grub config generator:"
    echo "                           Debian/Ubuntu: sudo update-grub"
    echo "                           RedHat/CentOS: sudo grub2-mkconfig -o /boot/grub2/grub.cfg"
    echo "   - Reboot required:    Yes (to fully apply bootloader parameter and reclaim fragmented pages)"
    echo
    echo "3. CPU Governor"
    echo "   - Apply instantly:    sudo cpupower frequency-set -g performance"
    echo "                         (or: echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)"
    echo "   - Persist on boot:    Install 'cpupower' package and enable systemd service (systemctl enable --now cpupower)"
    echo "   - Reboot required:    No"
    echo
    echo "4. I/O Scheduler & Block Device (rq_affinity, read_ahead_kb)"
    echo "   - Apply instantly:    echo mq-deadline | sudo tee /sys/block/<dev>/queue/scheduler"
    echo "                         echo 2 | sudo tee /sys/block/<dev>/queue/rq_affinity"
    echo "                         blockdev --setra 4096 /dev/<dev>"
    echo "   - Persist on boot:    Create udev rule (e.g. /etc/udev/rules.d/99-postgresql-io.rules):"
    echo "                           ACTION==\"add|change\", KERNEL==\"sd[a-z]|nvme[0-9]n[0-9]|vd[a-z]\", ATTR{queue/scheduler}=\"mq-deadline\", ATTR{queue/rq_affinity}=\"2\""
    echo "                         Re-trigger rules: sudo udevadm trigger"
    echo "   - Reboot required:    No"
    echo
    echo "5. Filesystem Mounts (noatime)"
    echo "   - Apply instantly:    sudo mount -o remount,noatime <mountpoint>"
    echo "   - Persist on boot:    Add 'noatime' to mount options in /etc/fstab"
    echo "   - Reboot required:    No"
    echo
    echo "6. Process and File limits (ulimit)"
    echo "   - Persist on boot:    Add limits to /etc/security/limits.d/99-postgresql.conf:"
    echo "                           postgres soft nofile 65536"
    echo "                           postgres hard nofile 65536"
    echo "                         Or via systemd override: sudo systemctl edit postgresql"
    echo "                           [Service]"
    echo "                           LimitNOFILE=65536"
    echo "   - Reboot required:    No (requires restarting PostgreSQL service to inherit limits: sudo systemctl restart postgresql)"
    hr
fi

echo
echo "${C_BOLD}Legend:${C_RST} [${C_GRN}OK${C_RST}] within range  [${C_YEL}WARN${C_RST}] review  [${C_RED}FIX${C_RST}] change recommended  [${C_BLU}INFO${C_RST}] context only"
echo "This script is read-only. It applies nothing. Tune to your workload and RAM."
echo
