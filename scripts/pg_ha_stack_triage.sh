#!/bin/bash
# ============================================================================
# SCRIPT: pg_ha_stack_triage.sh
# DESCRIPTION:
#   Zero-dependency, portable diagnostics script that audits the entire PostgreSQL
#   High-Availability middleware stack: Patroni (REST API & timings), etcd (Raft quorum
#   and alarms), HAProxy (backends & health checks), pgBouncer (pool saturation),
#   and keepalived (Virtual IP status). Works in both native and containerized environments.
#
# PARAMETERS CHECKED:
#   - Middleware components discovery: Patroni, etcd, HAProxy, pgBouncer, keepalived.
#   - Patroni Cluster details: REST API response, node state/role, paused status, timelines,
#     replication lag, and timings (ttl, loop_wait, retry_timeout).
#   - etcd Store parameters: Raft member counts, endpoint health, active alarms, key prefixes.
#   - HAProxy Configuration: config validity, stats socket backend status, health check endpoints (/primary).
#   - pgBouncer Connection Pooler: pool_mode, default_pool_size, auth_type, client wait queues.
#   - keepalived Virtual IP: service status, VIP presence, host state (MASTER vs BACKUP).
#
# RECOMMENDATIONS & RATIONALE:
#   - If Patroni is paused: Recommends resuming. Rationale: Paused mode disables automated failover.
#   - If timing rule (ttl >= loop_wait + 2 * retry_timeout) is violated: Recommends adjusting timings.
#     Rationale: Prevents transient network spikes or garbage collection cycles from causing spurious demotions.
#   - If etcd member count is even: Recommends adjusting count to odd. Rationale: Even member counts
#     increase quorum size requirements without offering additional failure tolerance.
#   - If etcd NOSPACE alarm is active: Recommends compacting and defragmenting etcd. Rationale:
#     Disk quota exhaustion blocks all DCS updates, forcing Patroni to self-demote the primary node.
#   - If HAProxy uses pgsql-check: Recommends switching to option httpchk GET /primary. Rationale:
#     pgsql-check cannot distinguish between primary and replica roles, leading to split-brain routing.
#   - If pgBouncer has waiting clients (cl_waiting > 0): Recommends increasing default_pool_size or
#     investigating long-running queries. Rationale: Indicates clients are blocked waiting for DB slots.
#   - If pgBouncer auth_type is trust/any: Recommends changing to scram-sha-256. Rationale: Prevents
#     unauthorized login attempts.
#
# USAGE:
#   ./pg_ha_stack_triage.sh [--patroni-url <url>] [--etcd <endpoints>] [--pgb-port <port>]
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

# Docker detection variables
IS_DOCKER=0
DOCKER_PATRONI_CONTS=""
DOCKER_PATRONI_LEADER=""
DOCKER_ETCD_CONTS=""
DOCKER_HAPROXY_CONTS=""
DOCKER_PGB_CONTS=""

if have docker && docker ps >/dev/null 2>&1; then
    RUNNING_CONTS=$(docker ps --format "{{.Names}}" --filter "status=running" 2>/dev/null)
    if [ -n "$RUNNING_CONTS" ]; then
        DOCKER_PATRONI_CONTS=$(echo "$RUNNING_CONTS" | grep -Ei 'patroni[0-9]*$' | grep -vE 'client|haproxy|etcd')
        if [ -z "$DOCKER_PATRONI_CONTS" ]; then
            DOCKER_PATRONI_CONTS=$(echo "$RUNNING_CONTS" | grep -Ei 'patroni' | grep -vE 'client|haproxy|etcd')
        fi
        DOCKER_ETCD_CONTS=$(echo "$RUNNING_CONTS" | grep -Ei 'etcd')
        DOCKER_HAPROXY_CONTS=$(echo "$RUNNING_CONTS" | grep -Ei 'haproxy')
        DOCKER_PGB_CONTS=$(echo "$RUNNING_CONTS" | grep -Ei 'pgbouncer')
        
        # Check if we actually found any relevant HA stack containers
        if [ -n "$DOCKER_PATRONI_CONTS" ] || [ -n "$DOCKER_ETCD_CONTS" ] || [ -n "$DOCKER_HAPROXY_CONTS" ] || [ -n "$DOCKER_PGB_CONTS" ]; then
            IS_DOCKER=1
            
            # Find the Patroni leader container
            for c in $DOCKER_PATRONI_CONTS; do
                api_resp=$(docker exec "$c" curl -s http://localhost:8008/patroni 2>/dev/null)
                if [ -n "$api_resp" ]; then
                    role=$(echo "$api_resp" | grep -o '"role"[^,]*' | head -1 | cut -d'"' -f4)
                    if [ "$role" = "master" ] || [ "$role" = "primary" ] || [ "$role" = "leader" ]; then
                        DOCKER_PATRONI_LEADER="$c"
                        break
                    fi
                fi
            done
        fi
    fi
fi

PATRONI_MODE="none"
if [ "$IS_DOCKER" = 1 ] && [ -n "$DOCKER_PATRONI_CONTS" ]; then
    PATRONI_MODE="docker"
elif have patroni || have patronictl || pgrep -f 'bin/patroni' >/dev/null 2>&1 || (timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/8008" >/dev/null 2>&1); then
    PATRONI_MODE="host"
fi

ETCD_MODE="none"
if [ "$IS_DOCKER" = 1 ] && [ -n "$DOCKER_ETCD_CONTS" ]; then
    ETCD_MODE="docker"
elif have etcd || have etcdctl || pgrep -x etcd >/dev/null 2>&1 || (timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/2379" >/dev/null 2>&1); then
    ETCD_MODE="host"
fi

HAPROXY_MODE="none"
if [ "$IS_DOCKER" = 1 ] && [ -n "$DOCKER_HAPROXY_CONTS" ]; then
    HAPROXY_MODE="docker"
elif have haproxy || pgrep -x haproxy >/dev/null 2>&1; then
    HAPROXY_MODE="host"
fi

PGB_MODE="none"
if [ "$IS_DOCKER" = 1 ] && [ -n "$DOCKER_PGB_CONTS" ]; then
    PGB_MODE="docker"
elif have pgbouncer || pgrep -x pgbouncer >/dev/null 2>&1 || (timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/6432" >/dev/null 2>&1); then
    PGB_MODE="host"
fi

KEEPALIVED_MODE="none"
if have keepalived || pgrep -x keepalived >/dev/null 2>&1; then
    KEEPALIVED_MODE="host"
fi

SUDO=""
if have sudo && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
fi

# HTTP fetch abstraction: curl, then wget, then bash /dev/tcp raw GET
http_get() {
    # $1 = url (http only for /dev/tcp fallback)
    local url="$1"
    if have curl; then
        curl -s --max-time 3 "$url" 2>/dev/null
    elif have wget; then
        wget -q -T 3 -O - "$url" 2>/dev/null
    else
        local hostport="${url#http://}"
        local host="${hostport%%/*}"; host="${host%%:*}"
        local port="${hostport%%/*}"; port="${port##*:}"; [ "$port" = "$host" ] && port=80
        local path="/${hostport#*/}"; [ "$path" = "/$hostport" ] && path="/"
        exec 9<>"/dev/tcp/$host/$port" 2>/dev/null || return 1
        printf 'GET %s HTTP/1.0\r\nHost: %s\r\n\r\n' "$path" "$host" >&9
        # strip headers
        sed '1,/^\r*$/d' <&9
        exec 9<&- 9>&-
    fi
}

patroni_api_get() {
    # $1 = path (e.g. /patroni or /cluster or /history)
    if [ "$PATRONI_MODE" = "docker" ]; then
        local probe_cont="${DOCKER_PATRONI_LEADER:-$(echo "$DOCKER_PATRONI_CONTS" | awk '{print $1}')}"
        docker exec "$probe_cont" curl -s "http://localhost:8008$1" 2>/dev/null || true
    else
        http_get "$PATRONI_URL$1" || true
    fi
}

tcp_open() {
    (timeout 1 bash -c "echo > /dev/tcp/$1/$2") >/dev/null 2>&1
}

PATRONI_URL="${PATRONI_URL:-http://127.0.0.1:8008}"
ETCD_ENDPOINTS="${ETCDCTL_ENDPOINTS:-http://127.0.0.1:2379}"
PGB_HOST="127.0.0.1"
PGB_PORT="6432"
PGB_USER="${PGBOUNCER_USER:-pgbouncer}"

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --patroni-url <url>     Patroni REST API base (default: http://127.0.0.1:8008)
  --etcd <endpoints>      etcd endpoint(s), comma-separated (default: http://127.0.0.1:2379)
  --pgb-port <port>       pgBouncer port (default: 6432)
  --pgb-user <user>       pgBouncer admin console user (default: pgbouncer)
  --help                  Show this help menu

Runs best with sudo (configs are often root/postgres-only readable).
All components are optional; missing ones are reported and skipped.
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --patroni-url) PATRONI_URL="$2"; shift 2 ;;
        --etcd) ETCD_ENDPOINTS="$2"; shift 2 ;;
        --pgb-port) PGB_PORT="$2"; shift 2 ;;
        --pgb-user) PGB_USER="$2"; shift 2 ;;
        --help) show_help ;;
        *) echo "Unknown option: $1" >&2; show_help ;;
    esac
done

ISSUES=()
REMEDS=()
warn() { echo "${C_YEL}[WARN]${C_RST} $1"; ISSUES+=("WARN: $1"); }
crit() { echo "${C_RED}[CRIT]${C_RST} $1"; ISSUES+=("CRIT: $1"); }
ok()   { echo "${C_GRN}[OK]${C_RST} $1"; }
info() { echo "${C_BLU}[INFO]${C_RST} $1"; }
remed() { REMEDS+=("$1"); }

svc_state() {
    # $1 = unit name; echoes "active/enabled" style summary or "not-found"
    if have systemctl; then
        local a e
        a=$(systemctl is-active "$1" 2>/dev/null || true)
        e=$(systemctl is-enabled "$1" 2>/dev/null || true)
        echo "${a:-unknown}/${e:-unknown}"
    else
        echo "no-systemd"
    fi
}

echo
echo "${C_BOLD}PostgreSQL HA Stack Triage (Patroni / etcd / HAProxy / pgBouncer)${C_RST}"
hr
echo "Host           : $(hostname -f 2>/dev/null || hostname)"
echo "Sudo available : $([ -n "$SUDO" ] && echo yes || echo NO — config access may be limited)"
hr

# ============================================================================
# 1. COMPONENT DISCOVERY
# ============================================================================
echo
echo "${C_BOLD}1. Component Discovery${C_RST}"
hr
HAS_PATRONI=0; HAS_ETCD=0; HAS_HAPROXY=0; HAS_PGB=0; HAS_KEEPALIVED=0
[ "$PATRONI_MODE" != "none" ] && HAS_PATRONI=1
[ "$ETCD_MODE" != "none" ] && HAS_ETCD=1
[ "$HAPROXY_MODE" != "none" ] && HAS_HAPROXY=1
[ "$PGB_MODE" != "none" ] && HAS_PGB=1
[ "$KEEPALIVED_MODE" != "none" ] && HAS_KEEPALIVED=1

print_discovery() {
    local label="$1"
    local mode="$2"
    local svc_name="$3"
    local docker_conts="$4"
    if [ "$mode" = "docker" ]; then
        local clean_conts=$(echo "$docker_conts" | tr '\r\n' '  ' | sed 's/  */ /g' | sed 's/^ //;s/ $//')
        printf "  %-12s : %s\n" "$label" "${C_GRN}detected${C_RST} (Docker: $clean_conts)"
    elif [ "$mode" = "host" ]; then
        printf "  %-12s : %s\n" "$label" "${C_GRN}detected${C_RST} ($(svc_state "$svc_name"))"
    else
        printf "  %-12s : %s\n" "$label" "not present"
    fi
}

print_discovery "Patroni"    "$PATRONI_MODE"    "patroni"    "$DOCKER_PATRONI_CONTS"
print_discovery "etcd"       "$ETCD_MODE"       "etcd"       "$DOCKER_ETCD_CONTS"
print_discovery "HAProxy"    "$HAPROXY_MODE"    "haproxy"    "$DOCKER_HAPROXY_CONTS"
print_discovery "pgBouncer"  "$PGB_MODE"        "pgbouncer"  "$DOCKER_PGB_CONTS"
print_discovery "keepalived" "$KEEPALIVED_MODE" "keepalived" ""
hr

# ============================================================================
# 2. PATRONI
# ============================================================================
if [ "$PATRONI_MODE" != "none" ]; then
    echo
    echo "${C_BOLD}2. Patroni Cluster State${C_RST}"
    hr

    # Service state
    if [ "$PATRONI_MODE" = "docker" ]; then
        ok "patroni service: running in Docker container(s)"
        for c in $DOCKER_PATRONI_CONTS; do
            echo "  Container: $c"
        done
    else
        PSVC=$(svc_state patroni)
        case "$PSVC" in
            active/*) ok "patroni service: $PSVC" ;;
            no-systemd) info "No systemd — checking process directly." ;;
            *) if pgrep -f 'bin/patroni' >/dev/null 2>&1; then
                   warn "patroni process running but service state is '$PSVC'."
               else
                   crit "Patroni installed but service is '$PSVC' and no process running."
                   remed "Start Patroni: sudo systemctl start patroni && sudo systemctl enable patroni; then: journalctl -u patroni -n 50"
               fi ;;
        esac
    fi

    # Locate config
    PATRONI_CFG=""
    if [ "$PATRONI_MODE" = "docker" ]; then
        probe_cont="${DOCKER_PATRONI_LEADER:-$(echo "$DOCKER_PATRONI_CONTS" | awk '{print $1}')}"
        for pf in /etc/patroni/patroni.yml /etc/patroni/*.yml /etc/patroni.yml /etc/patroni/config.yml; do
            if docker exec "$probe_cont" test -r "$pf" 2>/dev/null; then PATRONI_CFG="$pf"; break; fi
        done
        [ -n "$PATRONI_CFG" ] && echo "Config file    : $PATRONI_CFG (inside container $probe_cont)"
    else
        for pf in /etc/patroni/patroni.yml /etc/patroni/*.yml /etc/patroni.yml /etc/patroni/config.yml; do
            if $SUDO test -r "$pf" 2>/dev/null || [ -r "$pf" ]; then PATRONI_CFG="$pf"; break; fi
        done
        # From process cmdline if not found
        if [ -z "$PATRONI_CFG" ]; then
            PATRONI_CFG=$(pgrep -af 'bin/patroni' 2>/dev/null | grep -oE '[^ ]+\.ya?ml' | head -1 || true)
        fi
        [ -n "$PATRONI_CFG" ] && echo "Config file    : $PATRONI_CFG"
    fi

    # patronictl view (best structured overview)
    if [ "$PATRONI_MODE" = "docker" ]; then
        probe_cont="${DOCKER_PATRONI_LEADER:-$(echo "$DOCKER_PATRONI_CONTS" | awk '{print $1}')}"
        if [ -n "$probe_cont" ] && [ -n "$PATRONI_CFG" ]; then
            echo
            echo "patronictl cluster overview (inside container $probe_cont):"
            docker exec "$probe_cont" patronictl -c "$PATRONI_CFG" list 2>/dev/null | sed 's/^/  /' || \
                echo "  (patronictl list failed inside container)"
        fi
    else
        if have patronictl && [ -n "$PATRONI_CFG" ]; then
            echo
            echo "patronictl cluster overview:"
            $SUDO patronictl -c "$PATRONI_CFG" list 2>/dev/null | sed 's/^/  /' || \
                patronictl -c "$PATRONI_CFG" list 2>/dev/null | sed 's/^/  /' || \
                echo "  (patronictl list failed — check DCS connectivity below)"
        fi
    fi

    # REST API checks
    echo
    if [ "$PATRONI_MODE" = "docker" ]; then
        probe_cont="${DOCKER_PATRONI_LEADER:-$(echo "$DOCKER_PATRONI_CONTS" | awk '{print $1}')}"
        echo "REST API (inside container $probe_cont):"
    else
        echo "REST API ($PATRONI_URL):"
    fi
    
    P_STATUS=$(patroni_api_get "/patroni")
    if [ -n "$P_STATUS" ]; then
        # Extract key fields without jq
        P_ROLE=$(echo "$P_STATUS" | grep -oE '"role":\s*"[^"]+"' | head -1 | cut -d'"' -f4)
        P_STATE=$(echo "$P_STATUS" | grep -oE '"state":\s*"[^"]+"' | head -1 | cut -d'"' -f4)
        P_TL=$(echo "$P_STATUS" | grep -oE '"timeline":\s*[0-9]+' | head -1 | grep -oE '[0-9]+')
        P_PAUSED=$(echo "$P_STATUS" | grep -oE '"pause":\s*(true|false)' | head -1 | grep -oE 'true|false')
        echo "  role=$P_ROLE state=$P_STATE timeline=${P_TL:-?} paused=${P_PAUSED:-false}"

        if [ "$P_STATE" != "running" ] && [ "$P_STATE" != "streaming" ]; then
            crit "Patroni member state is '$P_STATE' (expected running/streaming)."
            if [ "$PATRONI_MODE" = "docker" ]; then
                remed "Inspect Patroni container logs: docker logs $probe_cont"
            else
                remed "Inspect Patroni logs: journalctl -u patroni -n 100 --no-pager; and PostgreSQL logs for startup errors."
            fi
        else
            ok "Member state: $P_STATE (role: $P_ROLE)"
        fi
        if [ "$P_PAUSED" = "true" ]; then
            crit "Patroni cluster management is PAUSED — no automatic failover will happen!"
            if [ "$PATRONI_MODE" = "docker" ]; then
                remed "Resume auto-failover: docker exec -it $probe_cont patronictl -c $PATRONI_CFG resume"
            else
                remed "Resume auto-failover when appropriate: patronictl -c $PATRONI_CFG resume <cluster_name>"
            fi
        fi

        # Replication lag from cluster endpoint
        P_CLUSTER=$(patroni_api_get "/cluster")
        if [ -n "$P_CLUSTER" ]; then
            LAGS=$(echo "$P_CLUSTER" | grep -oE '"lag":\s*[0-9]+' | grep -oE '[0-9]+' || true)
            for lag in $LAGS; do
                if [ "$lag" -gt 104857600 ] 2>/dev/null; then
                    crit "A cluster member reports replication lag of $lag bytes (>100MB)."
                    remed "Check the lagging member: run pg_repl_triage.sh there; verify network and WAL volume."
                elif [ "$lag" -gt 10485760 ] 2>/dev/null; then
                    warn "A cluster member reports replication lag of $lag bytes (>10MB)."
                fi
            done
            # Unhealthy members
            if echo "$P_CLUSTER" | grep -qE '"state":\s*"(stopped|start failed|crashed|creating replica)"'; then
                crit "Cluster contains members in stopped/failed/crashed state (see /cluster output)."
                echo "$P_CLUSTER" | sed 's/^/    /' | head -10
                if [ "$PATRONI_MODE" = "docker" ]; then
                    remed "On the failed container: docker logs <container>; to reinit: docker exec -it $probe_cont patronictl -c $PATRONI_CFG reinit <cluster> <member>"
                else
                    remed "On the failed member: journalctl -u patroni -n 100; if replica is broken beyond repair: patronictl -c $PATRONI_CFG reinit <cluster> <member>"
                fi
            fi
        fi

        # Failover history
        P_HISTORY=$(patroni_api_get "/history")
        if [ -n "$P_HISTORY" ] && [ "$P_HISTORY" != "[]" ]; then
            TL_COUNT=$(echo "$P_HISTORY" | grep -oE '\[[0-9]+,' | wc -l)
            info "Timeline history has $TL_COUNT entries (failovers/switchovers occurred). Last entries:"
            echo "$P_HISTORY" | tail -c 500 | sed 's/^/    /'
        fi
    else
        if [ "$PATRONI_MODE" = "docker" ]; then
            crit "Patroni REST API not answering inside container $probe_cont."
            remed "Verify patroni is running inside container $probe_cont; run: docker logs $probe_cont"
        else
            crit "Patroni REST API not answering at $PATRONI_URL."
            remed "Verify restapi listen address in $PATRONI_CFG; test: curl -s $PATRONI_URL/patroni; check: journalctl -u patroni -n 50"
        fi
    fi

    # Config sanity (grep-based, no yaml parser)
    if [ -n "$PATRONI_CFG" ]; then
        echo
        echo "Config sanity checks:"
        if [ "$PATRONI_MODE" = "docker" ]; then
            probe_cont="${DOCKER_PATRONI_LEADER:-$(echo "$DOCKER_PATRONI_CONTS" | awk '{print $1}')}"
            CFG_CONTENT=$(docker exec "$probe_cont" cat "$PATRONI_CFG" 2>/dev/null || true)
        else
            CFG_CONTENT=$($SUDO cat "$PATRONI_CFG" 2>/dev/null || cat "$PATRONI_CFG" 2>/dev/null || true)
        fi
        
        if [ -n "$CFG_CONTENT" ]; then
            TTL=$(echo "$CFG_CONTENT" | grep -E '^\s*ttl:' | head -1 | grep -oE '[0-9]+' || true)
            LOOP=$(echo "$CFG_CONTENT" | grep -E '^\s*loop_wait:' | head -1 | grep -oE '[0-9]+' || true)
            RETRY=$(echo "$CFG_CONTENT" | grep -E '^\s*retry_timeout:' | head -1 | grep -oE '[0-9]+' || true)
            echo "  ttl=${TTL:-<dcs default 30>} loop_wait=${LOOP:-<dcs default 10>} retry_timeout=${RETRY:-<dcs default 10>}"
            # Golden rule: ttl >= loop_wait + 2*retry_timeout
            if [ -n "$TTL" ] && [ -n "$LOOP" ] && [ -n "$RETRY" ]; then
                if [ "$TTL" -lt $((LOOP + 2 * RETRY)) ]; then
                    crit "ttl ($TTL) < loop_wait + 2*retry_timeout ($((LOOP + 2*RETRY))) — leader key can expire during normal DCS hiccups, causing spurious demotions!"
                    if [ "$PATRONI_MODE" = "docker" ]; then
                        remed "Fix timing rule: docker exec -it $probe_cont patronictl -c $PATRONI_CFG edit-config  and set ttl >= loop_wait + 2*retry_timeout."
                    else
                        remed "Fix timing rule: patronictl -c $PATRONI_CFG edit-config  and set ttl >= loop_wait + 2*retry_timeout (e.g. ttl:30 loop_wait:10 retry_timeout:10)."
                    fi
                else
                    ok "Timing rule satisfied: ttl >= loop_wait + 2*retry_timeout."
                fi
            fi
            if echo "$CFG_CONTENT" | grep -qE '^\s*synchronous_mode:\s*true'; then
                info "synchronous_mode is enabled — verify sync standby exists (patronictl list shows 'Sync Standby')."
            fi
            if echo "$CFG_CONTENT" | grep -qE '^\s*nofailover:\s*true'; then
                warn "This member has nofailover: true — it can never be promoted."
            fi
            MAXLAG=$(echo "$CFG_CONTENT" | grep -E 'maximum_lag_on_failover' | grep -oE '[0-9]+' | head -1 || true)
            [ -n "$MAXLAG" ] && echo "  maximum_lag_on_failover=$MAXLAG bytes"
        else
            warn "Patroni config $PATRONI_CFG not readable — run with sudo for config audit."
        fi
    fi
    hr
else
    echo
    echo "${C_BOLD}2. Patroni${C_RST} — not present on this host, skipping."
    hr
fi

# ============================================================================
# 3. ETCD (DCS)
# ============================================================================
if [ "$ETCD_MODE" != "none" ]; then
    echo
    echo "${C_BOLD}3. etcd Distributed Configuration Store${C_RST}"
    hr
    if [ "$ETCD_MODE" = "docker" ]; then
        ok "etcd service: running in Docker container(s)"
        for c in $DOCKER_ETCD_CONTS; do
            echo "  Container: $c"
        done
    else
        ESVC=$(svc_state etcd)
        case "$ESVC" in
            active/*) ok "etcd service: $ESVC" ;;
            no-systemd) : ;;
            *) if pgrep -x etcd >/dev/null 2>&1; then
                   info "etcd process running (service state: $ESVC)."
               else
                   crit "etcd installed but not running — Patroni cannot hold leader lock; cluster will demote to read-only!"
                   remed "Start etcd: sudo systemctl start etcd; inspect: journalctl -u etcd -n 50 --no-pager"
               fi ;;
        esac
    fi

    # Check if we can run etcdctl
    run_etcdctl=""
    if [ "$ETCD_MODE" = "docker" ]; then
        etcd_cont=$(echo "$DOCKER_ETCD_CONTS" | awk '{print $1}')
        if [ -n "$etcd_cont" ] && docker exec "$etcd_cont" etcdctl version >/dev/null 2>&1; then
            run_etcdctl="docker exec $etcd_cont etcdctl"
        fi
    else
        if have etcdctl; then
            run_etcdctl="etcdctl"
        fi
    fi

    if [ -n "$run_etcdctl" ]; then
        export ETCDCTL_API=3
        echo
        if [ "$ETCD_MODE" = "docker" ]; then
            etcd_cont=$(echo "$DOCKER_ETCD_CONTS" | awk '{print $1}')
            echo "Endpoint health (inside container $etcd_cont):"
            $run_etcdctl endpoint health 2>&1 | sed 's/^/  /' || true
            echo "Endpoint status (leader, raft term, DB size):"
            $run_etcdctl endpoint status -w table 2>/dev/null | sed 's/^/  /' || \
                $run_etcdctl endpoint status 2>&1 | sed 's/^/  /' || true
            echo "Member list:"
            MEMBERS=$($run_etcdctl member list 2>/dev/null || true)
            echo "$MEMBERS" | sed 's/^/  /'
        else
            echo "Endpoint health ($ETCD_ENDPOINTS):"
            $run_etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint health 2>&1 | sed 's/^/  /' || true
            echo "Endpoint status (leader, raft term, DB size):"
            $run_etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint status -w table 2>/dev/null | sed 's/^/  /' || \
                $run_etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint status 2>&1 | sed 's/^/  /' || true
            echo "Member list:"
            MEMBERS=$($run_etcdctl --endpoints="$ETCD_ENDPOINTS" member list 2>/dev/null || true)
            echo "$MEMBERS" | sed 's/^/  /'
        fi

        MEMBER_COUNT=$(echo "$MEMBERS" | grep -c 'started' || true)
        if [ "${MEMBER_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            if [ $((MEMBER_COUNT % 2)) -eq 0 ]; then
                warn "etcd has an EVEN number of members ($MEMBER_COUNT) — no better than N-1, worse quorum math. Use odd counts (3 or 5)."
                if [ "$ETCD_MODE" = "docker" ]; then
                    remed "Plan to add/remove one etcd member to reach an odd count."
                else
                    remed "Plan to add/remove one etcd member to reach an odd count: etcdctl member add/remove <id>"
                fi
            else
                ok "etcd member count is odd ($MEMBER_COUNT) — proper quorum topology."
            fi
        fi

        # Alarms (NOSPACE = writes disabled!)
        if [ "$ETCD_MODE" = "docker" ]; then
            ALARMS=$($run_etcdctl alarm list 2>/dev/null || true)
        else
            ALARMS=$($run_etcdctl --endpoints="$ETCD_ENDPOINTS" alarm list 2>/dev/null || true)
        fi

        if [ -n "$ALARMS" ]; then
            crit "etcd ALARMS ACTIVE: $ALARMS — if NOSPACE, etcd rejects writes and Patroni loses its lock!"
            if [ "$ETCD_MODE" = "docker" ]; then
                remed "Clear NOSPACE inside container: docker exec -it $etcd_cont etcdctl compact <rev>; etcdctl defrag; etcdctl alarm disarm"
            else
                remed "Clear NOSPACE: etcdctl compact <rev>; etcdctl defrag; etcdctl alarm disarm (understand root cause: quota-backend-bytes too small?)"
            fi
        else
            ok "No etcd alarms active."
        fi

        # Patroni keys present?
        if [ "$ETCD_MODE" = "docker" ]; then
            PKEYS=$($run_etcdctl get --prefix /service/ --keys-only 2>/dev/null | head -10 || true)
        else
            PKEYS=$($run_etcdctl --endpoints="$ETCD_ENDPOINTS" get --prefix /service/ --keys-only 2>/dev/null | head -10 || true)
        fi

        if [ -n "$PKEYS" ]; then
            echo "Patroni keys in DCS (namespace /service/):"
            echo "$PKEYS" | sed 's/^/  /'
        fi
    else
        # No etcdctl: use HTTP health endpoint
        if [ "$ETCD_MODE" = "docker" ]; then
            for c in $DOCKER_ETCD_CONTS; do
                H=$(docker exec "$c" curl -s http://localhost:2379/health || true)
                if echo "$H" | grep -q '"health"\s*:\s*"\?true'; then
                    ok "etcd container $c health endpoint reports healthy."
                else
                    crit "etcd container $c health endpoint is NOT healthy (response: ${H:-none})."
                    remed "Check etcd logs: docker logs $c"
                fi
            done
        else
            for ep in ${ETCD_ENDPOINTS//,/ }; do
                H=$(http_get "$ep/health" || true)
                if echo "$H" | grep -q '"health"\s*:\s*"\?true'; then
                    ok "etcd endpoint $ep reports healthy."
                else
                    crit "etcd endpoint $ep is NOT healthy (response: ${H:-none})."
                    remed "Check etcd on $ep: journalctl -u etcd -n 50; verify 2379/2380 reachable between peers (pg_repl_triage.sh section 6)."
                fi
            done
        fi
        info "etcdctl not installed — deeper checks (member list, alarms) unavailable."
    fi
    hr
else
    echo
    echo "${C_BOLD}3. etcd${C_RST} — not present on this host, skipping."
    hr
fi

# ============================================================================
# 4. HAPROXY
# ============================================================================
if [ "$HAPROXY_MODE" != "none" ]; then
    echo
    echo "${C_BOLD}4. HAProxy Load Balancer${C_RST}"
    hr
    if [ "$HAPROXY_MODE" = "docker" ]; then
        ok "haproxy service: running in Docker container(s)"
        for c in $DOCKER_HAPROXY_CONTS; do
            echo "  Container: $c"
        done
    else
        HSVC=$(svc_state haproxy)
        case "$HSVC" in
            active/*) ok "haproxy service: $HSVC" ;;
            no-systemd) : ;;
            *) if pgrep -x haproxy >/dev/null 2>&1; then
                   info "haproxy running (service state: $HSVC)."
               else
                   crit "HAProxy installed but NOT running — clients cannot reach the cluster through the LB!"
                   remed "Validate config then start: haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl start haproxy"
               fi ;;
        esac
    fi

    HCFG="/etc/haproxy/haproxy.cfg"
    CFG=""
    if [ "$HAPROXY_MODE" = "docker" ]; then
        hap_cont=$(echo "$DOCKER_HAPROXY_CONTS" | awk '{print $1}')
        c_hcfg=""
        for f in /usr/local/etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg; do
            if docker exec "$hap_cont" test -r "$f" 2>/dev/null; then
                c_hcfg="$f"
                break
            fi
        done
        
        if [ -n "$c_hcfg" ]; then
            HCFG="$c_hcfg"
            # Config validation
            if docker exec "$hap_cont" haproxy -c -f "$c_hcfg" >/dev/null 2>&1; then
                ok "HAProxy config $c_hcfg inside container passes validation (haproxy -c)."
            else
                crit "HAProxy config $c_hcfg inside container FAILS validation!"
                echo "  Details:"
                docker exec "$hap_cont" haproxy -c -f "$c_hcfg" 2>&1 | sed 's/^/    /' | head -10
                remed "Fix config errors shown above inside the HAProxy container."
            fi
            CFG=$(docker exec "$hap_cont" cat "$c_hcfg" 2>/dev/null || true)
        fi
    else
        if $SUDO test -r "$HCFG" 2>/dev/null || [ -r "$HCFG" ]; then
            # Config validation (read-only -c flag)
            if have haproxy; then
                if $SUDO haproxy -c -f "$HCFG" >/dev/null 2>&1 || haproxy -c -f "$HCFG" >/dev/null 2>&1; then
                    ok "haproxy.cfg passes configuration validation (haproxy -c)."
                else
                    crit "haproxy.cfg FAILS validation! A restart/reload would break the LB."
                    echo "  Details:"
                    ($SUDO haproxy -c -f "$HCFG" 2>&1 || haproxy -c -f "$HCFG" 2>&1) | sed 's/^/    /' | head -10
                    remed "Fix haproxy.cfg errors shown above, re-validate with: haproxy -c -f $HCFG; then: sudo systemctl reload haproxy"
                fi
            fi
            CFG=$($SUDO cat "$HCFG" 2>/dev/null || cat "$HCFG" 2>/dev/null)
        fi
    fi

    if [ -n "$CFG" ]; then
        if [ "$HAPROXY_MODE" = "docker" ]; then
            echo "PostgreSQL-related frontends/backends (inside container):"
        else
            echo "PostgreSQL-related frontends/backends:"
        fi
        echo "$CFG" | grep -nE '^\s*(listen|frontend|backend|server|bind|option httpchk|http-check|default-server)' | sed 's/^/  /'
        # Patroni-aware health checks?
        if echo "$CFG" | grep -qE 'httpchk.*(GET\s+)?/(primary|leader|master|replica|read-only|health)'; then
            ok "HAProxy uses Patroni REST health checks (httpchk on role endpoints) — correct HA pattern."
        elif echo "$CFG" | grep -q 'pgsql-check'; then
            warn "HAProxy uses pgsql-check — this only verifies PostgreSQL answers, NOT the Patroni role. After failover, traffic can hit a read-only ex-primary."
            remed "Switch to Patroni-aware checks: option httpchk GET /primary (write pool) or GET /replica (read pool) against port 8008, with 'http-check expect status 200'."
        elif echo "$CFG" | grep -qE '^\s*server\s' ; then
            warn "HAProxy backends have no role-aware health check visible — verify how the primary is selected."
        fi

        # Stats socket discovery
        STATS_SOCK=$(echo "$CFG" | grep -E '^\s*stats socket' | awk '{print $3}' | head -1 || true)
        STATS_BIND=$(echo "$CFG" | grep -B3 'stats enable' | grep -E '^\s*bind' | grep -oE '[0-9.]+:[0-9]+|:[0-9]+' | head -1 || true)
        if [ -n "$STATS_SOCK" ]; then
            if [ "$HAPROXY_MODE" = "docker" ]; then
                hap_cont=$(echo "$DOCKER_HAPROXY_CONTS" | awk '{print $1}')
                if docker exec "$hap_cont" command -v socat >/dev/null 2>&1; then
                    echo
                    echo "Backend/server states via stats socket ($STATS_SOCK) in container $hap_cont:"
                    docker exec -i "$hap_cont" sh -c "echo 'show stat' | socat stdio '$STATS_SOCK'" 2>/dev/null | \
                        awk -F, 'NR==1{next} $1!~/^#/ && $2!="" {printf "  %-20s %-20s %-8s\n", $1, $2, $18}' | head -20 || \
                        echo "  (socket query failed)"
                    DOWN=$(docker exec -i "$hap_cont" sh -c "echo 'show stat' | socat stdio '$STATS_SOCK'" 2>/dev/null | awk -F, '$18=="DOWN"' | wc -l || echo 0)
                    if [ "${DOWN:-0}" -gt 0 ] 2>/dev/null; then
                        crit "$DOWN HAProxy backend server(s) are DOWN."
                        remed "For each DOWN server: verify the node's Patroni role endpoint manually."
                    fi
                else
                    info "Stats socket configured at $STATS_SOCK but 'socat' not installed inside container $hap_cont."
                fi
            else
                if have socat; then
                    echo
                    echo "Backend/server states via stats socket ($STATS_SOCK):"
                    echo "show stat" | $SUDO socat stdio "$STATS_SOCK" 2>/dev/null | \
                        awk -F, 'NR==1{next} $1!~/^#/ && $2!="" {printf "  %-20s %-20s %-8s\n", $1, $2, $18}' | head -20 || \
                        echo "  (socket query failed)"
                    DOWN=$(echo "show stat" | $SUDO socat stdio "$STATS_SOCK" 2>/dev/null | awk -F, '$18=="DOWN"' | wc -l || echo 0)
                    if [ "${DOWN:-0}" -gt 0 ] 2>/dev/null; then
                        crit "$DOWN HAProxy backend server(s) are DOWN."
                        remed "For each DOWN server: verify the node's Patroni role endpoint manually: curl -s -o /dev/null -w '%{http_code}' http://<node>:8008/primary (or /replica)."
                    fi
                else
                    info "Stats socket configured at $STATS_SOCK but 'socat' not installed."
                    remed "Install socat to query HAProxy runtime state: sudo apt-get install -y socat  (or: sudo dnf install -y socat)"
                fi
            fi
        fi
        [ -n "$STATS_BIND" ] && info "Stats web page bound at $STATS_BIND — check visually: curl -s http://$STATS_BIND/ (or configured uri)."
    else
        if [ "$HAPROXY_MODE" = "docker" ]; then
            warn "HAProxy config inside container not readable."
        else
            warn "HAProxy config $HCFG not readable — run with sudo."
        fi
    fi
    hr
else
    echo
    echo "${C_BOLD}4. HAProxy${C_RST} — not present on this host, skipping."
    hr
fi

# ============================================================================
# 5. PGBOUNCER
# ============================================================================
if [ "$PGB_MODE" != "none" ]; then
    echo
    echo "${C_BOLD}5. pgBouncer Connection Pooler${C_RST}"
    hr
    if [ "$PGB_MODE" = "docker" ]; then
        ok "pgbouncer service: running in Docker container(s)"
        for c in $DOCKER_PGB_CONTS; do
            echo "  Container: $c"
        done
    else
        BSVC=$(svc_state pgbouncer)
        case "$BSVC" in
            active/*) ok "pgbouncer service: $BSVC" ;;
            no-systemd) : ;;
            *) if pgrep -x pgbouncer >/dev/null 2>&1; then
                   info "pgbouncer running (service state: $BSVC)."
               else
                   crit "pgBouncer installed but NOT running — pooled clients cannot connect!"
                   remed "Start pgBouncer: sudo systemctl start pgbouncer; logs: journalctl -u pgbouncer -n 50"
               fi ;;
        esac
    fi

    # Config audit
    BCFG=""
    CFG=""
    if [ "$PGB_MODE" = "docker" ]; then
        pgb_cont=$(echo "$DOCKER_PGB_CONTS" | awk '{print $1}')
        for f in /etc/pgbouncer/pgbouncer.ini /etc/pgbouncer.ini /etc/opt/pgbouncer/pgbouncer.ini; do
            if docker exec "$pgb_cont" test -r "$f" 2>/dev/null; then BCFG="$f"; break; fi
        done
        if [ -n "$BCFG" ]; then
            echo "Config: $BCFG (inside container $pgb_cont)"
            CFG=$(docker exec "$pgb_cont" cat "$BCFG" 2>/dev/null || true)
        fi
    else
        for f in /etc/pgbouncer/pgbouncer.ini /etc/pgbouncer.ini; do
            if $SUDO test -r "$f" 2>/dev/null || [ -r "$f" ]; then BCFG="$f"; break; fi
        done
        if [ -n "$BCFG" ]; then
            echo "Config: $BCFG"
            CFG=$($SUDO cat "$BCFG" 2>/dev/null || cat "$BCFG" 2>/dev/null)
        fi
    fi

    if [ -n "$CFG" ]; then
        POOL_MODE=$(echo "$CFG" | grep -E '^\s*pool_mode' | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        MAX_CLIENT=$(echo "$CFG" | grep -E '^\s*max_client_conn' | tail -1 | grep -oE '[0-9]+' || true)
        DEF_POOL=$(echo "$CFG" | grep -E '^\s*default_pool_size' | tail -1 | grep -oE '[0-9]+' || true)
        LISTEN_PORT=$(echo "$CFG" | grep -E '^\s*listen_port' | tail -1 | grep -oE '[0-9]+' || true)
        [ -n "$LISTEN_PORT" ] && PGB_PORT="$LISTEN_PORT"
        echo "  pool_mode=${POOL_MODE:-session(default)} max_client_conn=${MAX_CLIENT:-100(default)} default_pool_size=${DEF_POOL:-20(default)} listen_port=${PGB_PORT}"
        if [ "${POOL_MODE:-session}" = "session" ]; then
            warn "pool_mode=session — pooling benefit is minimal (1 client = 1 server conn for the whole session)."
            if [ "$PGB_MODE" = "docker" ]; then
                remed "Consider transaction pooling for OLTP: set pool_mode = transaction in config and reload pgbouncer."
            else
                remed "Consider transaction pooling for OLTP: set pool_mode = transaction in $BCFG (verify app does not rely on session state: prepared statements pre-1.21, advisory locks, SET commands), then: systemctl reload pgbouncer"
            fi
        else
            ok "pool_mode=$POOL_MODE"
        fi
        AUTH_TYPE=$(echo "$CFG" | grep -E '^\s*auth_type' | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        if [ "${AUTH_TYPE:-}" = "trust" ] || [ "${AUTH_TYPE:-}" = "any" ]; then
            crit "pgBouncer auth_type=$AUTH_TYPE — anyone reaching the port can connect as any user!"
            remed "Harden auth: set auth_type = scram-sha-256 in config and populate userlist.txt / auth_query; then reload."
        fi
    else
        warn "pgbouncer.ini not found/readable at standard paths."
    fi

    # Admin console (SHOW commands)
    # Check if we have psql on host or inside container
    run_psql=""
    if [ "$PGB_MODE" = "docker" ]; then
        pgb_cont=$(echo "$DOCKER_PGB_CONTS" | awk '{print $1}')
        if docker exec "$pgb_cont" command -v psql >/dev/null 2>&1; then
            run_psql="docker exec -i $pgb_cont psql"
        elif have psql; then
            run_psql="psql"
        fi
    else
        if have psql; then
            run_psql="psql"
        fi
    fi

    if [ -n "$run_psql" ]; then
        pgb_q() {
            if [ "$PGB_MODE" = "docker" ]; then
                pgb_cont=$(echo "$DOCKER_PGB_CONTS" | awk '{print $1}')
                docker exec -i "$pgb_cont" sh -c "PGPASSWORD=\"${PGBOUNCER_PASSWORD:-${PGPASSWORD:-}}\" psql -h 127.0.0.1 -p \"$PGB_PORT\" -U \"$PGB_USER\" -d pgbouncer -At -F'|' -c \"$1\"" 2>/dev/null || \
                docker exec -i "$pgb_cont" sh -c "psql -h 127.0.0.1 -p \"$PGB_PORT\" -U \"$PGB_USER\" -d pgbouncer -At -F'|' -c \"$1\"" 2>/dev/null || echo ""
            else
                PGPASSWORD="${PGBOUNCER_PASSWORD:-${PGPASSWORD:-}}" psql -h "$PGB_HOST" -p "$PGB_PORT" -U "$PGB_USER" -d pgbouncer -At -F'|' -c "$1" 2>/dev/null || \
                $SUDO -u postgres psql -h "$PGB_HOST" -p "$PGB_PORT" -U "$PGB_USER" -d pgbouncer -At -F'|' -c "$1" 2>/dev/null || echo ""
            fi
        }
        POOLS=$(pgb_q "SHOW POOLS;")
        if [ -n "$POOLS" ]; then
            echo
            ok "Admin console reachable. Pool states (db|user|cl_active|cl_waiting|sv_active|sv_idle|sv_used):"
            echo "$POOLS" | awk -F'|' '{printf "  %-15s %-12s cl_act=%-5s cl_wait=%-5s sv_act=%-5s sv_idle=%-5s\n", $1, $2, $3, $4, $5, $6}' | head -15
            # cl_waiting > 0 = saturation
            WAITING=$(echo "$POOLS" | awk -F'|' '{s+=$4} END{print s+0}')
            if [ "${WAITING:-0}" -gt 0 ] 2>/dev/null; then
                crit "Clients are WAITING for a server connection (cl_waiting=$WAITING) — pool exhausted!"
                remed "Raise default_pool_size (mind PostgreSQL max_connections budget) or find/kill long transactions hogging server conns (pg_activity_audit.sh)."
            fi
            echo
            echo "Traffic stats (SHOW STATS — db|total_xact|total_query|avg_xact_us|avg_query_us):"
            pgb_q "SHOW STATS;" | awk -F'|' '{printf "  %-15s xact=%-10s query=%-10s\n", $1, $2, $3}' | head -8
        else
            warn "pgBouncer admin console not reachable as user '$PGB_USER' on port $PGB_PORT."
            remed "Grant console access: add your user to admin_users/stats_users; connect: psql -h 127.0.0.1 -p $PGB_PORT -U <admin_user> pgbouncer -c 'SHOW POOLS;'"
        fi
    fi
    hr
else
    echo
    echo "${C_BOLD}5. pgBouncer${C_RST} — not present on this host, skipping."
    hr
fi

# ============================================================================
# 6. KEEPALIVED / VIP
# ============================================================================
if [ $HAS_KEEPALIVED = 1 ]; then
    echo
    echo "${C_BOLD}6. keepalived / Virtual IP${C_RST}"
    hr
    KSVC=$(svc_state keepalived)
    case "$KSVC" in
        active/*) ok "keepalived service: $KSVC" ;;
        *) warn "keepalived present but service state is '$KSVC'."
           remed "Start keepalived: sudo systemctl start keepalived; logs: journalctl -u keepalived -n 50" ;;
    esac
    KCFG="/etc/keepalived/keepalived.conf"
    if $SUDO test -r "$KCFG" 2>/dev/null || [ -r "$KCFG" ]; then
        VIPS=$($SUDO grep -A5 'virtual_ipaddress' "$KCFG" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u || true)
        if [ -n "$VIPS" ]; then
            echo "Configured VIP(s): $VIPS"
            for vip in $VIPS; do
                if ip addr 2>/dev/null | grep -q "$vip"; then
                    info "VIP $vip is currently HELD by this node (MASTER)."
                else
                    info "VIP $vip is NOT on this node (BACKUP state or held elsewhere)."
                fi
            done
        fi
    fi
    hr
fi

# ============================================================================
# 7. STACK-LEVEL CONSISTENCY CHECKS
# ============================================================================
echo
echo "${C_BOLD}7. Stack Consistency Cross-Checks${C_RST}"
hr
if [ $HAS_PATRONI = 1 ] && [ $HAS_ETCD = 0 ]; then
    # Is DCS remote? check config for hosts
    if [ -n "${CFG_CONTENT:-}" ] && echo "${CFG_CONTENT:-}" | grep -qE '^\s*(etcd3?|consul|zookeeper|kubernetes):'; then
        DCS_HOSTS=$(echo "$CFG_CONTENT" | grep -A5 -E '^\s*(etcd3?|consul|zookeeper):' | grep -E 'host' | head -3)
        info "Patroni uses a remote DCS: $DCS_HOSTS"
        echo "  Verify reachability with pg_repl_triage.sh section 6 or: timeout 1 bash -c 'echo > /dev/tcp/<dcs_ip>/2379'"
    else
        warn "Patroni present but no local etcd and DCS config not readable — verify DCS connectivity manually."
    fi
fi
if [ $HAS_HAPROXY = 1 ] && [ $HAS_PGB = 1 ]; then
    info "Both HAProxy and pgBouncer present — confirm the intended chain (app -> pgBouncer -> HAProxy -> PG, or app -> HAProxy -> pgBouncer -> PG) and that ports match the configs above."
fi
if [ $HAS_PATRONI = 0 ] && [ $HAS_ETCD = 0 ] && [ $HAS_HAPROXY = 0 ] && [ $HAS_PGB = 0 ] && [ $HAS_KEEPALIVED = 0 ]; then
    info "No HA middleware found on this host — it is likely a standalone PostgreSQL node or a plain replica. Use pg_repl_triage.sh for replication-level checks."
fi
hr

# ============================================================================
# 8. SUMMARY & VERDICT
# ============================================================================
echo
echo "${C_BOLD}8. HA Stack Triage Summary${C_RST}"
hr
if [ ${#ISSUES[@]} -eq 0 ]; then
    echo "${C_GRN}No HA stack anomalies flagged on this host.${C_RST}"
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
