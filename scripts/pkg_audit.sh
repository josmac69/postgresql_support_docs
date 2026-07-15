#!/usr/bin/env bash
# ============================================================================
# SCRIPT: pkg_audit.sh
# DESCRIPTION:
#   Multi-distro database package auditing tool that scans for PostgreSQL, high availability,
#   backup, and systems diagnostics packages. Performs read-only checks to identify package
#   version conflicts, outdated software, and engine co-habitation risks.
#
# PARAMETERS CHECKED:
#   - Distro family: Debian/Ubuntu vs RHEL/CentOS/Rocky/Alma.
#   - Database inventory: Installed packages matching PostgreSQL, pgBouncer, Patroni, repmgr,
#     pgBackRest, wal-g, barman.
#   - Competing engines: Co-installed databases (MySQL/MariaDB, MongoDB, Redis).
#   - Troubleshooting tools: Status of diagnostics packages (sysbench, strace, tcpdump, gdb,
#     perf, bpftrace).
#   - Upgrades: Queries apt-cache or dnf/yum check-update to discover outdated target packages.
#   - Anomaly checks: Multi-version server/client coexistence, missing HA/backup integrations.
#
# RECOMMENDATIONS & RATIONALE:
#   - If database packages are outdated: Recommends running package upgrades. Rationale: Protects
#     against known bugs, security vulnerabilities, and stability problems.
#   - If multiple server versions are installed: Recommends removing obsolete packages. Rationale:
#     Prevents file path confusion, port binding conflicts, and incorrect instance restarts.
#   - If database co-habitation is found: Recommends isolating databases to dedicated instances.
#     Rationale: Prevents severe CPU, memory, and disk I/O resource contention between competing engines.
#   - If diagnostics utilities are missing: Recommends installing them. Rationale: Tools like strace,
#     gdb, and tcpdump are critical for troubleshooting system-level hangs and network issues.
#   - If pgBouncer/pgBackRest are missing: Recommends installation. Rationale: Crucial for query connection
#     pooling safety and reliable point-in-time backup recovery.
#
# USAGE:
#   ./pkg_audit.sh
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & Formatting
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'
    C_BLU=$'\033[1;36m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_OFF=""
fi

ISSUES=()
REMEDS=()

hdr()  { printf '\n%s================ %s ================%s\n' "$C_BLU" "$1" "$C_OFF"; }
ok()   { printf '%s[ OK ]%s %s\n'   "$C_GRN" "$C_OFF" "$1"; }
warn() { printf '%s[WARN]%s %s\n'   "$C_YEL" "$C_OFF" "$1"; ISSUES+=("WARN: $1"); }
crit() { printf '%s[CRIT]%s %s\n'   "$C_RED" "$C_OFF" "$1"; ISSUES+=("CRIT: $1"); }
info() { printf '[info] %s\n' "$1"; }
remed() { REMEDS+=("$1"); }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 1. OS & Distribution Discovery
# ---------------------------------------------------------------------------
hdr "SYSTEM IDENTITY & OS DISCOVERY"

OS_FAMILY="unknown"
PRETTY_OS="Unknown Linux"

if [ -r /etc/os-release ]; then
    . /etc/os-release
    PRETTY_OS="${PRETTY_NAME:-$NAME}"
    case " ${ID:-} ${ID_LIKE:-} " in
        *debian*|*ubuntu*|*mint*)
            OS_FAMILY="debian"
            ;;
        *rhel*|*fedora*|*centos*|*rocky*|*alma*|*amzn*)
            OS_FAMILY="redhat"
            ;;
    esac
fi

if [ "$OS_FAMILY" = "unknown" ]; then
    if [ -x /usr/bin/dpkg ]; then
        OS_FAMILY="debian"
    elif [ -x /usr/bin/rpm ]; then
        OS_FAMILY="redhat"
    else
        printf "%s[CRIT] Unsupported operating system family. Exiting.%s\n" "$C_RED" "$C_OFF"
        exit 1
    fi
fi

info "OS: $PRETTY_OS (Family: $OS_FAMILY)"
info "Kernel: $(uname -r)"

# Check if we have sudo power (read-only checks, but lets us know if we can install things later)
HAVE_SUDO=0
if have sudo && sudo -n true 2>/dev/null; then
    HAVE_SUDO=1
fi
info "Sudo privileges: $([ "$HAVE_SUDO" = 1 ] && echo yes || echo NO)"

# ---------------------------------------------------------------------------
# 2. Package Catalog Discovery
# ---------------------------------------------------------------------------
hdr "COLLECTING INSTALLED PACKAGE INVENTORY"

INSTALLED_PACKAGES=""

# We define a common target package list for both OS families
# Note: we use globs for dpkg-query and exact prefixes for rpm grep
if [ "$OS_FAMILY" = "debian" ]; then
    info "Querying dpkg-query..."
    INSTALLED_PACKAGES=$(dpkg-query -W -f='${binary:Package}|${Version}|${Status}\n' \
        "postgresql*" "pgbouncer" "patroni" "repmgr*" "pgbackrest" "wal-g" "barman" \
        "mysql-server*" "mariadb-server*" "redis-server*" "mongodb-org*" "sqlite3" \
        "sysbench" "strace" "tcpdump" "gdb" "perf" "linux-perf*" "bpftrace" "etcd" "consul" 2>/dev/null | \
        grep "install ok installed" | cut -d'|' -f1,2 || true)
else
    info "Querying rpm..."
    INSTALLED_PACKAGES=$(rpm -qa --qf "%{NAME}|%{VERSION}-%{RELEASE}\n" | grep -i -E \
        "^(postgresql|pgbouncer|patroni|repmgr|pgbackrest|wal-g|barman|mysql|mariadb|redis|mongodb|sqlite|sysbench|strace|tcpdump|gdb|perf|bpftrace|etcd|consul)" | sort || true)
fi

if [ -z "$INSTALLED_PACKAGES" ]; then
    info "No target database or system engineering utility packages found."
else
    # Display the collected inventory
    echo "$INSTALLED_PACKAGES" | while IFS='|' read -r name ver; do
        printf "  - %-32s : %s\n" "$name" "$ver"
    done
fi

# ---------------------------------------------------------------------------
# 3. Outdated Package Validation
# ---------------------------------------------------------------------------
hdr "OUTDATED PACKAGE AUDIT"

# Batch checker for Debian
check_outdated_debian_batch() {
    local pkgs=("$@")
    if [ ${#pkgs[@]} -eq 0 ]; then return; fi
    local current_pkg=""
    local installed=""
    local candidate=""
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^([^[:space:]:]+):$ ]]; then
            if [ -n "$current_pkg" ] && [ -n "$installed" ] && [ -n "$candidate" ] && [ "$installed" != "$candidate" ] && [ "$installed" != "(none)" ]; then
                echo "$current_pkg|$installed|$candidate"
            fi
            current_pkg="${BASH_REMATCH[1]}"
            installed=""
            candidate=""
        elif [[ "$line" =~ Installed:[[:space:]]*(.+) ]]; then
            installed="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ Candidate:[[:space:]]*(.+) ]]; then
            candidate="${BASH_REMATCH[1]}"
        fi
    done < <(apt-cache policy "${pkgs[@]}" 2>/dev/null)
    
    if [ -n "$current_pkg" ] && [ -n "$installed" ] && [ -n "$candidate" ] && [ "$installed" != "$candidate" ] && [ "$installed" != "(none)" ]; then
        echo "$current_pkg|$installed|$candidate"
    fi
}

# Batch checker for RedHat
check_outdated_redhat_batch() {
    local pkgs=("$@")
    if [ ${#pkgs[@]} -eq 0 ]; then return; fi
    local updates=""
    
    # Try dnf check-update, then fallback to yum
    updates=$(dnf check-update --quiet "${pkgs[@]}" 2>/dev/null || true)
    if [ -z "$updates" ]; then
        updates=$(yum check-update --quiet "${pkgs[@]}" 2>/dev/null || true)
    fi
    
    if [ -n "$updates" ]; then
        echo "$updates" | while read -r line; do
            if [[ "$line" =~ ^([a-zA-Z0-9_-]+)\.([a-zA-Z0-9_.-]+)[[:space:]]+([a-zA-Z0-9_.:-]+) ]]; then
                local name="${BASH_REMATCH[1]}"
                local new_ver="${BASH_REMATCH[3]}"
                local inst_ver
                inst_ver=$(rpm -q --qf "%{VERSION}-%{RELEASE}" "$name" 2>/dev/null || echo "")
                if [ -n "$inst_ver" ]; then
                    echo "$name|$inst_ver|$new_ver"
                fi
            fi
        done
    fi
}

# Collect package names to check
pkg_names_to_check=$(echo "$INSTALLED_PACKAGES" | cut -d'|' -f1 | tr '\n' ' ')

OUTDATED_OUTPUT=""
if [ -n "${pkg_names_to_check// }" ]; then
    if [ "$OS_FAMILY" = "debian" ]; then
        OUTDATED_OUTPUT=$(check_outdated_debian_batch $pkg_names_to_check || true)
    else
        OUTDATED_OUTPUT=$(check_outdated_redhat_batch $pkg_names_to_check || true)
    fi
fi

if [ -z "$OUTDATED_OUTPUT" ]; then
    ok "All target packages are up-to-date with available repositories."
else
    echo "$OUTDATED_OUTPUT" | while IFS='|' read -r name inst cand; do
        warn "Package '$name' is outdated (Installed: $inst, Available: $cand)"
        if [ "$OS_FAMILY" = "debian" ]; then
            remed "Upgrade package: sudo apt-get update && sudo apt-get install --only-upgrade -y $name"
        else
            remed "Upgrade package: sudo dnf upgrade -y $name"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 4. Anomaly & Conflict Detection
# ---------------------------------------------------------------------------
hdr "ANOMALY & CONFLICT DETECTION"

# A. Multiple PostgreSQL Server Versions
pg_servers=""
if [ "$OS_FAMILY" = "debian" ]; then
    pg_servers=$(echo "$INSTALLED_PACKAGES" | grep -E "^postgresql-[0-9]+\|" | cut -d'|' -f1 || true)
else
    pg_servers=$(echo "$INSTALLED_PACKAGES" | grep -E "^postgresql[0-9]*-server\||^postgresql-server\|" | cut -d'|' -f1 || true)
fi

pg_server_count=0
if [ -n "$pg_servers" ]; then
    pg_server_count=$(echo "$pg_servers" | wc -l)
fi

if [ "$pg_server_count" -gt 1 ]; then
    servers_list=$(echo "$pg_servers" | tr '\n' ' ')
    crit "Multiple PostgreSQL Server installations found: $servers_list"
    remed "Remove obsolete PostgreSQL server packages to prevent configuration confusion and port conflicts."
    if [ "$OS_FAMILY" = "debian" ]; then
        remed "  - Command: sudo apt-get remove --purge <obsolete-package>"
    else
        remed "  - Command: sudo dnf remove <obsolete-package>"
    fi
elif [ "$pg_server_count" -eq 1 ]; then
    ok "Single PostgreSQL server package version installed: $(echo "$pg_servers" | tr '\n' ' ')"
else
    info "No local PostgreSQL server package installed (this node may act as a dedicated client, proxy, or DCS node)."
fi

# B. Multiple Client Versions
pg_clients=""
if [ "$OS_FAMILY" = "debian" ]; then
    pg_clients=$(echo "$INSTALLED_PACKAGES" | grep -E "^postgresql-client-[0-9]+\|" | cut -d'|' -f1 || true)
else
    pg_clients=$(echo "$INSTALLED_PACKAGES" | grep -E "^postgresql[0-9]*-client\||^postgresql-client\|" | cut -d'|' -f1 || true)
fi

pg_client_count=0
if [ -n "$pg_clients" ]; then
    pg_client_count=$(echo "$pg_clients" | wc -l)
fi

if [ "$pg_client_count" -gt 1 ]; then
    clients_list=$(echo "$pg_clients" | tr '\n' ' ')
    warn "Multiple PostgreSQL client utility packages found: $clients_list"
    remed "Ensure that the active client utilities (e.g. pg_dump, psql) match your active server version to avoid feature mismatches."
fi

# C. Database Co-habitation (Resource Competitions)
co_dbs=""
if echo "$INSTALLED_PACKAGES" | grep -q -i -E "mysql-server|mariadb-server"; then
    co_dbs="$co_dbs MySQL/MariaDB"
fi
if echo "$INSTALLED_PACKAGES" | grep -q -i -E "mongodb-org-server|mongodb-server|^mongodb$"; then
    co_dbs="$co_dbs MongoDB"
fi
if echo "$INSTALLED_PACKAGES" | grep -q -i -E "redis-server|^redis$"; then
    co_dbs="$co_dbs Redis"
fi

if [ -n "$co_dbs" ] && [ "$pg_server_count" -ge 1 ]; then
    crit "Database co-habitation detected: PostgreSQL is co-installed with:$co_dbs"
    remed "Co-habitation can lead to extreme CPU/RAM/IO contention and OOM risks. Consider segregating database workloads onto dedicated instances."
    remed "Disable auto-start of non-essential database services (e.g. sudo systemctl disable --now mysql / redis-server)."
elif [ -n "$co_dbs" ]; then
    info "Other database engines installed (No local PostgreSQL server detected):$co_dbs"
else
    ok "No competing database engines (MySQL/MariaDB, MongoDB, Redis) are installed."
fi

# D. Diagnostic Tool Verification
tools_to_check=("sysbench" "strace" "tcpdump" "gdb" "perf" "bpftrace")
missing_tools=()

# Translate names for checks
for tool in "${tools_to_check[@]}"; do
    if [ "$tool" = "perf" ]; then
        if [ "$OS_FAMILY" = "debian" ]; then
            # On Debian it is named linux-perf
            if ! echo "$INSTALLED_PACKAGES" | grep -q "^linux-perf"; then
                missing_tools+=("perf")
            fi
        else
            if ! echo "$INSTALLED_PACKAGES" | grep -q "^perf\|"; then
                missing_tools+=("perf")
            fi
        fi
    else
        if ! echo "$INSTALLED_PACKAGES" | grep -q "^$tool\|"; then
            missing_tools+=("$tool")
        fi
    fi
done

if [ ${#missing_tools[@]} -gt 0 ]; then
    missing_str=$(printf "%s " "${missing_tools[@]}")
    warn "Missing diagnostic / troubleshooting utilities: $missing_str"
    if [ "$OS_FAMILY" = "debian" ]; then
        # Map perf to linux-perf-$(uname -r) or linux-perf
        debian_tools=()
        for mt in "${missing_tools[@]}"; do
            if [ "$mt" = "perf" ]; then
                debian_tools+=("linux-perf")
            else
                debian_tools+=("$mt")
            fi
        done
        install_cmd="sudo apt-get update && sudo apt-get install -y $(printf "%s " "${debian_tools[@]}")"
    else
        install_cmd="sudo dnf install -y $(printf "%s " "${missing_tools[@]}")"
    fi
    remed "Install missing troubleshooting utilities to prepare for deep diagnostics:"
    remed "  - Command: $install_cmd"
else
    ok "All critical diagnostic tools (sysbench, strace, tcpdump, gdb, perf, bpftrace) are installed."
fi

# E. High Availability / Backup Integration Best Practices
if [ "$pg_server_count" -ge 1 ]; then
    has_pgb=$(echo "$INSTALLED_PACKAGES" | grep -q "^pgbouncer\|" && echo 1 || echo 0)
    has_backrest=$(echo "$INSTALLED_PACKAGES" | grep -q "^pgbackrest\|" && echo 1 || echo 0)
    
    if [ "$has_pgb" = 0 ]; then
        warn "PostgreSQL server is installed, but pgBouncer is missing."
        if [ "$OS_FAMILY" = "debian" ]; then
            remed "Install pgBouncer: sudo apt-get install -y pgbouncer"
        else
            remed "Install pgBouncer: sudo dnf install -y pgbouncer"
        fi
    fi
    
    if [ "$has_backrest" = 0 ]; then
        warn "PostgreSQL server is installed, but pgBackRest is missing."
        if [ "$OS_FAMILY" = "debian" ]; then
            remed "Install pgBackRest: sudo apt-get install -y pgbackrest"
        else
            remed "Install pgBackRest: sudo dnf install -y pgbackrest"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 5. Summary & Verdict
# ---------------------------------------------------------------------------
hdr "TRIAGE SUMMARY"

if [ ${#ISSUES[@]} -eq 0 ]; then
    printf "%sNo anomalies or outdated packages flagged by automated package checks.%s\n" "$C_GRN" "$C_OFF"
else
    printf "%sFLAGGED ISSUES (%d):%s\n" "$C_RED" "${#ISSUES[@]}" "$C_OFF"
    i=1
    for issue in "${ISSUES[@]}"; do
        printf "  %2d. %s\n" "$i" "$issue"
        i=$((i+1))
    done
fi

if [ ${#REMEDS[@]} -gt 0 ]; then
    printf "\n%sRECOMMENDATIONS & REMEDIATION ACTIONS:%s\n" "$C_YEL" "$C_OFF"
    for r in "${REMEDS[@]}"; do
        printf "  - %s\n" "$r"
    done
fi

printf "\nPackage audit complete.\n"
exit 0
