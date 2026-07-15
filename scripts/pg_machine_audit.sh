#!/usr/bin/env bash
# ============================================================================
# SCRIPT: pg_machine_audit.sh
# DESCRIPTION:
#   Detailed diagnostic audit of host machine specifications, memory allocation tables,
#   disk throughput, and hardware configurations relevant to PostgreSQL. Discovers cloud
#   instance metadata (AWS EC2), checks virtualized mounts, and includes a sequential I/O
#   benchmark mode. Read-only diagnostic script.
#
# PARAMETERS CHECKED:
#   - Hypervisor: Cloud metadata (AWS EC2 type, ID, AZ) or VM hypervisor.
#   - CPU: Model, logical counts, sockets, cores/socket, threads/core, load avg, governor.
#   - Memory: RAM total/used/available, swap size & active usage, Page Table overhead (PTE/PMD),
#     Huge Pages count/size, Transparent Huge Pages (THP) state.
#   - Memory mounts: tmpfs, devtmpfs, POSIX SHM (/dev/shm), /dev/zero device node status.
#   - Storage specs: Device types (SSD/NVMe vs HDD), block I/O schedulers, partition size/usage,
#     and mount flags (noatime).
#   - Performance: Live disk I/O throughput (1s sample of /proc/diskstats) and write/read benchmark.
#
# RECOMMENDATIONS & RATIONALE:
#   - If CPU governor is not performance: Recommends performance governor. Rationale: Prevents
#     latency spikes due to dynamic frequency adjustments.
#   - If swap space is missing: Recommends configuring swap. Rationale: Prevents sudden system
#     out-of-memory crashes by offering a temporary paging safety net.
#   - If Page Table size is high (>2GB or >5% RAM): Recommends configuring OS Huge Pages. Rationale:
#     Standard 4KB page size mappings for large shared_buffers create huge CPU overhead for address translation.
#   - If THP is enabled: Recommends disabling THP. Rationale: Dynamic huge page allocation causes severe
#     transaction latency spikes and RAM fragmentation.
#   - If database partition is missing noatime: Recommends remounting with noatime. Rationale: Stops
#     the OS from writing file-access times during read queries, reducing storage write amplification.
#
# USAGE:
#   ./pg_machine_audit.sh
#   ./pg_machine_audit.sh --benchmark  # Run sequential write/read tests on PostgreSQL partitions
# ============================================================================

set -u
LC_ALL=C

WANT_BENCHMARK=0
[ "${1:-}" = "--benchmark" ] && WANT_BENCHMARK=1

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

# ============================================================================
echo
echo "${C_BOLD}PostgreSQL Machine & Resources Audit${C_RST}"
hr
printf "Host        : %s\n" "$(hostname -f 2>/dev/null || hostname)"
OS_ID="unknown"; OS_PRETTY="unknown"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
fi
printf "OS          : %s\n" "$OS_PRETTY"
printf "Kernel      : %s (%s)\n" "$(uname -r)" "$(uname -m)"
printf "Uptime      : %s\n" "$(uptime -p 2>/dev/null || uptime)"
printf "Run as      : %s\n" "$(id -un)"

# Cloud / Hypervisor facts
AWS_INSTANCE_TYPE=""
if have curl; then
    # Try IMDSv2 token request first
    token=$(curl -s -S -m 1 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 10" 2>/dev/null)
    if [ -n "$token" ]; then
        AWS_INSTANCE_TYPE=$(curl -s -S -m 1 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)
        AWS_INSTANCE_ID=$(curl -s -S -m 1 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
        AWS_AZ=$(curl -s -S -m 1 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null)
    else
        AWS_INSTANCE_TYPE=$(curl -s -S -m 1 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)
        AWS_INSTANCE_ID=$(curl -s -S -m 1 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
        AWS_AZ=$(curl -s -S -m 1 http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null)
    fi
fi

if [ -n "${AWS_INSTANCE_TYPE:-}" ]; then
    printf "Hypervisor  : AWS EC2 (Instance Type: %s, ID: %s, AZ: %s)\n" "$AWS_INSTANCE_TYPE" "$AWS_INSTANCE_ID" "$AWS_AZ"
else
    VIRT=$(systemd-detect-virt 2>/dev/null)
    if [ $? -eq 0 ] && [ "$VIRT" != "none" ]; then
        printf "Hypervisor  : %s\n" "$VIRT"
    fi
fi

[ "$(id -u)" -ne 0 ] && printf "%sNote:%s Not running as root; some kernel/hardware parameters might be restricted.\n" "$C_YEL" "$C_RST"
hr

# ============================================================================
echo "${C_BOLD}CPU Topology & Configuration${C_RST}"

# Model Name
CPU_MODEL=$(lscpu 2>/dev/null | awk -F: '/Model name:/{sub(/^[ \t]+/, "", $2); print $2}')
[ -z "$CPU_MODEL" ] && CPU_MODEL=$(awk -F: '/model name/{sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)
echo "CPU Model   : ${CPU_MODEL:-Unknown}"

# Cores and Sockets
CPUS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo "?")
SOCKETS=$(lscpu 2>/dev/null | awk -F: '/Socket\(s\):/{sub(/^[ \t]+/, "", $2); print $2}')
CORES_PER_SOCKET=$(lscpu 2>/dev/null | awk -F: '/Core\(s\) per socket:/{sub(/^[ \t]+/, "", $2); print $2}')
THREADS_PER_CORE=$(lscpu 2>/dev/null | awk -F: '/Thread\(s\) per core:/{sub(/^[ \t]+/, "", $2); print $2}')

row "Logical CPUs" "$CPUS" "-" INFO "Total processing units available"
[ -n "$SOCKETS" ] && row "CPU Sockets" "$SOCKETS" "-" INFO
[ -n "$CORES_PER_SOCKET" ] && row "Cores per Socket" "$CORES_PER_SOCKET" "-" INFO
[ -n "$THREADS_PER_CORE" ] && row "Threads per Core" "$THREADS_PER_CORE" "-" INFO "$( [ "${THREADS_PER_CORE:-1}" -gt 1 ] && echo 'Hyperthreading enabled' || echo 'No hyperthreading' )"

# Load Average
LOAD_AVG=$(cat /proc/loadavg 2>/dev/null || echo "? ? ?")
row "Load Average" "$(echo "$LOAD_AVG" | awk '{print $1", "$2", "$3}')" "<= CPUs" INFO "1, 5, 15 min queues"

# CPU Governor
GOV="n/a"
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    if [ "$GOV" = "performance" ]; then
        row "CPU Governor" "$GOV" "performance" OK "Optimized for database latencies"
    else
        row "CPU Governor" "$GOV" "performance" WARN "Set scaling governor to performance to avoid CPU throttling"
    fi
else
    row "CPU Governor" "Not Exposed" "performance" INFO "Governor details not exposed in sysfs (common in VMs)"
fi

hr

# ============================================================================
echo "${C_BOLD}Memory & Page Tables Diagnostics${C_RST}"

MEM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
[ -z "$MEM_AVAIL_KB" ] && MEM_AVAIL_KB=$(awk '/^MemFree:/{print $2}' /proc/meminfo) # fallback
MEM_USED_KB=$(( MEM_KB - MEM_AVAIL_KB ))

MEM_GB=$(awk -v k="$MEM_KB" 'BEGIN{printf "%.1f", k/1024/1024}')
MEM_USED_GB=$(awk -v k="$MEM_USED_KB" 'BEGIN{printf "%.1f", k/1024/1024}')
MEM_AVAIL_GB=$(awk -v k="$MEM_AVAIL_KB" 'BEGIN{printf "%.1f", k/1024/1024}')

row "Total RAM" "${MEM_GB} GB" "-" INFO
row "Used RAM" "${MEM_USED_GB} GB" "-" INFO
row "Available RAM" "${MEM_AVAIL_GB} GB" "-" INFO

# Swap check
SWAP_TOTAL=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SWAP_FREE=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
if [ -n "$SWAP_TOTAL" ]; then
    SWAP_TOTAL_GB=$(awk -v k="$SWAP_TOTAL" 'BEGIN{printf "%.1f", k/1024/1024}')
    SWAP_USED_KB=$(( SWAP_TOTAL - SWAP_FREE ))
    SWAP_USED_GB=$(awk -v k="$SWAP_USED_KB" 'BEGIN{printf "%.1f", k/1024/1024}')
    
    if [ "$SWAP_TOTAL" -eq 0 ]; then
        row "Swap Configured" "0.0 GB" ">0" WARN "No swap space configured; risk of sudden OOM kills"
    else
        # check swap usage percentage
        SWAP_PCT=$(awk -v u="$SWAP_USED_KB" -v t="$SWAP_TOTAL" 'BEGIN{printf "%.1f", (u/t)*100}')
        if ge "$SWAP_PCT" 10.0; then
            row "Swap Usage" "${SWAP_USED_GB} GB (${SWAP_PCT}%)" "<10%" WARN "Active swapping detected; review shared_buffers/work_mem"
        else
            row "Swap Usage" "${SWAP_USED_GB} GB (${SWAP_PCT}%)" "<10%" OK "Swap space healthy"
        fi
    fi
fi

# Linux Memory Allocation Tables (Page Tables)
# On system level
PGTABLES_KB=$(awk '/^PageTables:/{print $2}' /proc/meminfo)
if [ -n "$PGTABLES_KB" ]; then
    PGTABLES_MB=$(awk -v k="$PGTABLES_KB" 'BEGIN{printf "%.1f", k/1024}')
    PGTABLES_PCT=$(awk -v p="$PGTABLES_KB" -v t="$MEM_KB" 'BEGIN{printf "%.2f", (p/t)*100}')
    
    # Recommendations: page tables shouldn't exceed 2GB or 5% of total memory
    if ge "$PGTABLES_MB" 2048.0 || ge "$PGTABLES_PCT" 5.0; then
        row "Page Tables Size" "${PGTABLES_MB} MB (${PGTABLES_PCT}% RAM)" "<2048 MB / <5%" FIX "High PageTables overhead! Set huge_pages = on in PG and reserve Huge Pages in OS"
    else
        row "Page Tables Size" "${PGTABLES_MB} MB (${PGTABLES_PCT}% RAM)" "<2048 MB / <5%" OK "PageTables overhead is within normal bounds"
    fi
fi

# Huge Pages Status
HP_TOTAL=$(awk '/HugePages_Total/{print $2}' /proc/meminfo)
HP_FREE=$(awk '/HugePages_Free/{print $2}' /proc/meminfo)
HP_SIZE_KB=$(awk '/Hugepagesize/{print $2}' /proc/meminfo)
if [ -n "$HP_TOTAL" ] && [ "$HP_TOTAL" -gt 0 ]; then
    HP_SIZE_GB=$(awk -v t="$HP_TOTAL" -v s="$HP_SIZE_KB" 'BEGIN{printf "%.1f", (t*s)/1024/1024}')
    row "Huge Pages Reserved" "${HP_TOTAL} (${HP_SIZE_GB} GB)" "sized to shared_buffers" OK "Huge pages configured"
    row "Huge Pages Free" "${HP_FREE:-0}" "-" INFO
else
    # If shared buffers is likely large (>8GB), recommend Huge Pages
    if ge "$MEM_GB" 16.0; then
        row "Huge Pages Reserved" "0" "shared_buffers sized" WARN "No Huge Pages reserved. Recommend using Huge Pages for large shared_buffers"
    else
        row "Huge Pages Reserved" "0" "shared_buffers sized" INFO "No Huge Pages reserved (optional for <16GB RAM)"
    fi
fi

# THP (Transparent Huge Pages) - should be 'never'
THP="unknown"
for f in /sys/kernel/mm/transparent_hugepage/enabled \
         /sys/kernel/mm/redhat_transparent_hugepage/enabled; do
    if [ -r "$f" ]; then
        THP=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$f")
        break
    fi
done
if [ "$THP" = "never" ]; then
    row "Transparent Huge Pages" "$THP" "never" OK
elif [ "$THP" != "unknown" ]; then
    row "Transparent Huge Pages" "$THP" "never" FIX "Disable THP (causes memory fragmentation and latency spikes in PG)"
fi

# Top 5 processes consuming page table memory
echo
echo "Top 5 Processes consuming Page Table memory (VmPTE + VmPMD):"
awk '
FNR == 1 {
    if (pid != "") {
        val = pte + pmd
        if (val > 0) {
            print val, pid, name
        }
    }
    name = ""; pid = ""; pte = 0; pmd = 0
}
/^Name:/ { name = $2 }
/^Pid:/ { pid = $2 }
/^VmPTE:/ { pte = $2 }
/^VmPMD:/ { pmd = $2 }
END {
    if (pid != "") {
        val = pte + pmd
        if (val > 0) {
            print val, pid, name
        }
    }
}
' /proc/[0-9]*/status 2>/dev/null | sort -rn | head -n 5 | while read -r val pid name; do
    mb=$(awk -v k="$val" 'BEGIN{printf "%.2f", k/1024}')
    printf "  - PID %-7s: %-25s size = %-8s MB\n" "$pid" "$name" "$mb"
done

hr

# ============================================================================
echo "${C_BOLD}Virtual Memory Filesystems (tmpfs/devtmpfs) & /dev/zero${C_RST}"
if [ -r /proc/mounts ]; then
    while read -r dev mnt fstype opts rest; do
        if [ "$fstype" = "tmpfs" ] || [ "$fstype" = "devtmpfs" ]; then
            # Skip noise systemd credentials / cgroup mounts
            [[ "$mnt" =~ ^/run/credentials ]] && continue
            [[ "$mnt" =~ ^/sys/fs ]] && continue
            
            df_line=$(df -h -P "$mnt" 2>/dev/null | tail -n 1)
            [ -z "$df_line" ] && continue
            size=$(echo "$df_line" | awk '{print $2}')
            used=$(echo "$df_line" | awk '{print $3}')
            avail=$(echo "$df_line" | awk '{print $4}')
            pct=$(echo "$df_line" | awk '{print $5}')
            
            purpose="In-memory storage"
            case "$mnt" in
                /dev) purpose="Kernel device node manager (devtmpfs)" ;;
                /dev/shm) purpose="POSIX Shared Memory (Used for PG dynamic_shared_memory_type=posix)" ;;
                /run) purpose="System daemon run state (PIDs, sockets)" ;;
                /run/lock) purpose="Process lock files" ;;
                /tmp) purpose="Temporary directory (RAM-backed, fast, volatile)" ;;
                /run/user/*) purpose="User session state runtime" ;;
            esac
            
            row "Mount $mnt" "${used}/${size} (${pct} used)" "-" INFO "$purpose"
        fi
    done < /proc/mounts
fi

# Check /dev/zero device node
if [ -c /dev/zero ]; then
    dev_mnt_type=$(grep -E "[[:space:]]/dev[[:space:]]" /proc/mounts 2>/dev/null | head -n 1 | awk '{print $3}')
    if [ "${dev_mnt_type:-}" = "devtmpfs" ]; then
        row "/dev/zero node" "Active" "-" OK "Character device backed by devtmpfs (RAM speed)"
    else
        row "/dev/zero node" "Active" "-" INFO "Character device, backed by: ${dev_mnt_type:-unknown}"
    fi
else
    row "/dev/zero node" "Missing!" "Character device" FIX "Recreate /dev/zero node using mknod"
fi

hr

# ============================================================================
echo "${C_BOLD}Storage & Disk Partition Diagnostics${C_RST}"

# Discover physical disks
echo "Physical Disk Devices:"
for dev_path in /sys/block/*; do
    [ -e "$dev_path" ] || continue
    dev=$(basename "$dev_path")
    # Skip virtual loop/ram/dm/md devices
    [[ "$dev" =~ ^loop ]] && continue
    [[ "$dev" =~ ^ram ]] && continue
    [[ "$dev" =~ ^dm- ]] && continue
    [[ "$dev" =~ ^md ]] && continue
    [ -f "$dev_path/queue/rotational" ] || continue
    
    rot=$(cat "$dev_path/queue/rotational" 2>/dev/null)
    size_blocks=$(cat "$dev_path/size" 2>/dev/null)
    size_gb=$(awk -v b="$size_blocks" 'BEGIN{printf "%.1f", b*512/1024/1024/1024}')
    
    type="SSD/NVMe"
    [ "$rot" = "1" ] && type="HDD (Rotational)"
    
    sched=$(cat "$dev_path/queue/scheduler" 2>/dev/null)
    # clean scheduler output (e.g. "[mq-deadline] none" -> "mq-deadline")
    sched_clean=$(echo "$sched" | sed -n 's/.*\[\(.*\)\].*/\1/p')
    [ -z "$sched_clean" ] && sched_clean=$(echo "$sched" | awk '{print $1}')
    
    printf "  - Device %-10s Size = %-8s Type = %-16s Scheduler = %s\n" \
        "/dev/$dev" "${size_gb} GB" "$type" "${sched_clean:-none}"
done
echo

# PostgreSQL directory analysis
PG_DIRS=()
# check running PG processes
pids=$(pgrep -d, -f 'postgres|postmaster' 2>/dev/null || ps -ef | grep -E 'postgres|postmaster' | grep -v grep | awk '{print $2}' | tr '\n' ',')
if [ -n "$pids" ]; then
    for pid in $(echo "$pids" | tr ',' ' '); do
        cmd=$(cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ')
        if [[ "$cmd" =~ -D[[:space:]]*([^[:space:]]+) ]]; then
            PG_DIRS+=("${BASH_REMATCH[1]}")
        elif [[ "$cmd" =~ --data-directory[=[:space:]]*([^[:space:]]+) ]]; then
            PG_DIRS+=("${BASH_REMATCH[1]}")
        fi
        env_dir=$(cat /proc/"$pid"/environ 2>/dev/null | tr '\0' '\n' | awk -F= '/^PGDATA=/{print $2}')
        [ -n "$env_dir" ] && PG_DIRS+=("$env_dir")
    done
fi

# Default fallback search paths if no running postgres instances detected
if [ ${#PG_DIRS[@]} -eq 0 ]; then
    for d in /var/lib/postgresql /var/lib/pgsql /var/lib/postgres/data; do
        [ -d "$d" ] && PG_DIRS+=("$d")
    done
fi

# unique
if [ ${#PG_DIRS[@]} -gt 0 ]; then
    UNIQUE_PG_DIRS=($(printf '%s\n' "${PG_DIRS[@]}" | sort -u))
else
    # default to root filesystem if absolutely nothing found
    UNIQUE_PG_DIRS=("/")
fi

# Check paths mount info and options
for pg_dir in "${UNIQUE_PG_DIRS[@]}"; do
    if [ ! -d "$pg_dir" ] && [ "$pg_dir" != "/" ]; then
        continue
    fi
    echo "Directory Target: ${pg_dir}"
    
    # get df details safely
    df_line=$(df -h -P "$pg_dir" 2>/dev/null | tail -n 1)
    dev_name=$(echo "$df_line" | awk '{print $1}')
    size_str=$(echo "$df_line" | awk '{print $2}')
    used_str=$(echo "$df_line" | awk '{print $3}')
    avail_str=$(echo "$df_line" | awk '{print $4}')
    use_pct_str=$(echo "$df_line" | awk '{print $5}' | tr -d '%')
    mount_point=$(echo "$df_line" | awk '{print $6}')
    
    row "  Device Mounted" "$dev_name" "-" INFO "Mount point: $mount_point"
    row "  Partition Size" "${size_str} (Avail: ${avail_str})" "-" INFO
    
    # Check space warnings
    if [ -n "$use_pct_str" ]; then
        if ge "$use_pct_str" 95; then
            row "  Partition Usage" "${use_pct_str}%" "<85%" FIX "Disk space critically low (<5% free)!"
        elif ge "$use_pct_str" 85; then
            row "  Partition Usage" "${use_pct_str}%" "<85%" WARN "Disk space filling up (>85% used)"
        else
            row "  Partition Usage" "${use_pct_str}%" "<85%" OK "Disk space within normal bounds"
        fi
    fi
    
    # Mount options check
    if [ -n "$mount_point" ] && [ -r /proc/mounts ]; then
        mount_entry=$(grep -E "[[:space:]]${mount_point}[[:space:]]" /proc/mounts | head -n 1)
        fstype=$(echo "$mount_entry" | awk '{print $3}')
        opts=$(echo "$mount_entry" | awk '{print $4}')
        
        row "  Filesystem Type" "${fstype:-unknown}" "-" INFO
        
        if [[ "$opts" =~ noatime ]]; then
            row "  Mount Options" "noatime" "noatime" OK "Writes suppressed on file reads"
        elif [[ "$opts" =~ relatime ]]; then
            row "  Mount Options" "relatime" "noatime" INFO "relatime is OK, but noatime is preferred for high-write databases"
        else
            row "  Mount Options" "atime" "noatime" WARN "Enable noatime to avoid unnecessary write operations on file access"
        fi
    fi
    echo
done

hr

# ============================================================================
echo "${C_BOLD}Live Disk I/O Throughput & Load (1-second sampling)${C_RST}"

read_stats() {
    # Extract dev, reads, read_sectors, writes, write_sectors, and total io time
    # Focus on sd*, nvme*, dm-*, xvd*, vd* (physical, LVM, partition, and VM drives)
    awk '{print $3, $4, $6, $8, $10, $13}' /proc/diskstats 2>/dev/null | grep -E '^(sd[a-z][0-9]*|nvme[0-9]+n[0-9]+(p[0-9]+)?|dm-[0-9]+|xvd[a-z][0-9]*|vd[a-z][0-9]*)'
}

s1=$(read_stats)
sleep 1
s2=$(read_stats)

# Parse stats in Awk
echo -e "$s1\n---\n$s2" | awk '
BEGIN {
    in_second = 0
}
/^---$/ {
    in_second = 1
    next
}
!in_second {
    dev = $1
    r_cnt[dev] = $2
    r_sec[dev] = $3
    w_cnt[dev] = $4
    w_sec[dev] = $5
    io_ms[dev] = $6
    next
}
in_second {
    dev = $1
    if (dev in r_cnt) {
        dr_cnt = $2 - r_cnt[dev]
        dr_sec = $3 - r_sec[dev]
        dw_cnt = $4 - w_cnt[dev]
        dw_sec = $5 - w_sec[dev]
        dio_ms = $6 - io_ms[dev]
        
        rmbs = (dr_sec * 512) / 1024 / 1024
        wmbs = (dw_sec * 512) / 1024 / 1024
        util = dio_ms / 10
        if (util > 100) util = 100
        if (util < 0) util = 0
        
        # Only print active devices (some read/write operations or utilization)
        if (dr_cnt > 0 || dw_cnt > 0 || util > 0.0) {
            if (!header_printed) {
                print "Active Devices:"
                printf "  %-12s %-12s %-12s %-12s %-12s %-10s\n", "Device", "Read MB/s", "Read IOPS", "Write MB/s", "Write IOPS", "Util %"
                print "  ----------------------------------------------------------------------"
                header_printed = 1
            }
            printf "  %-12s %-12.2f %-12d %-12.2f %-12d %.1f%%\n", dev, rmbs, dr_cnt, wmbs, dw_cnt, util
        }
    }
}
'
if [ $? -ne 0 ] || [ -z "$s1" ]; then
    echo "No active disk I/O measured during sampling interval."
fi

# ============================================================================
if [ "$WANT_BENCHMARK" -eq 1 ]; then
    echo
    echo "${C_BOLD}Active Storage Performance Benchmark (64MB Sequential Test)${C_RST}"
    hr
    
    # Identify directories to test
    test_targets=()
    for d in "${UNIQUE_PG_DIRS[@]}"; do
        [ -d "$d" ] && test_targets+=("$d")
    done
    
    # Append current directory (.) to test local disk where script resides
    test_targets+=(".")
    
    # Append /tmp for comparison/reference
    has_tmp=0
    for target in "${test_targets[@]}"; do
        [ "$target" = "/tmp" ] && has_tmp=1
    done
    if [ "$has_tmp" -eq 0 ] && [ -d "/tmp" ]; then
        test_targets+=("/tmp")
    fi
    
    # Run tests on each writable target directory
    for target in "${test_targets[@]}"; do
        if [ ! -w "$target" ]; then
            echo "Skipping benchmark on target directory '${target}' (No write access)."
            continue
        fi
        
        # Get mount details
        df_line=$(df -h -P "$target" 2>/dev/null | tail -n 1)
        dev_name=$(echo "$df_line" | awk '{print $1}')
        mount_point=$(echo "$df_line" | awk '{print $6}')
        
        fstype="unknown"
        if [ -n "$mount_point" ] && [ -r /proc/mounts ]; then
            fstype=$(grep -E "[[:space:]]${mount_point}[[:space:]]" /proc/mounts | head -n 1 | awk '{print $3}')
        fi
        
        echo "Benchmarking target: ${target}"
        echo "  - Backing Device: ${dev_name}"
        echo "  - Mount Point   : ${mount_point} (${fstype})"
        
        # Warning if tmpfs
        if [ "$fstype" = "tmpfs" ] || [ "$fstype" = "devtmpfs" ]; then
            echo "  ${C_YEL}* WARNING: RAM-backed ${fstype} mount! Measures RAM speed, NOT physical disk speed! *${C_RST}"
        fi
        
        test_file="${target}/.pg_speed_test_$$"
        trap 'rm -f "${test_file}" >/dev/null 2>&1' EXIT INT TERM
        
        # Write test
        echo "  Running write test..."
        write_out=$(dd if=/dev/zero of="${test_file}" bs=1M count=64 conv=fdatasync 2>&1)
        if [ $? -eq 0 ]; then
            write_speed=$(echo "$write_out" | tr '\r' '\n' | tail -n 1 | awk -F, '{print $NF}' | sed 's/^[[:space:]]*//')
            row "  Sequential Write Speed" "$write_speed" "-" OK "fdatasync enabled"
        else
            row "  Sequential Write Speed" "Failed" "-" FIX "Write permission issue or dd command error"
        fi
        
        # Read test
        echo "  Running read test..."
        read_out=$(dd if="${test_file}" of=/dev/null bs=1M count=64 2>&1)
        if [ $? -eq 0 ]; then
            read_speed=$(echo "$read_out" | tr '\r' '\n' | tail -n 1 | awk -F, '{print $NF}' | sed 's/^[[:space:]]*//')
            row "  Sequential Read Speed" "$read_speed" "-" INFO "May include buffer cache if not run as root"
        else
            row "  Sequential Read Speed" "Failed" "-" FIX "Read command error"
        fi
        
        rm -f "${test_file}"
        trap - EXIT INT TERM
        echo
    done
else
    echo
    echo "Note: Active disk sequential read/write benchmarks can be run by executing:"
    echo "      ./pg_machine_audit.sh --benchmark"
fi

hr

# ============================================================================
echo "${C_BOLD}System Audit Alert Flags Summary${C_RST}"
hr
if [ ${#WARN_FLAGS[@]} -eq 0 ]; then
    echo "${C_GRN}[PASS]${C_RST} No machine resources issues or problematic configurations detected."
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
echo
