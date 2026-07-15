#!/bin/bash
# ============================================================================
# SCRIPT: patroni_deep_triage.sh
# DESCRIPTION:
#   Exhaustive, read-only diagnostic and triage tool for Patroni-supervised
#   PostgreSQL high-availability nodes and clusters. Evaluates the local state,
#   DCS status, load balancer routing, logs, and configurations.
#
# PARAMETERS CHECKED:
#   - Patroni & Patronicl presence, versions, and running state.
#   - Container context: Docker/Podman status, restart policies, sibling states.
#   - Service details: systemd enablement/activity, orphan PostgreSQL running processes.
#   - Config structure: Scope/name, DCS backend, timing variables (ttl, loop_wait, retry_timeout).
#   - Tags settings: nofailover, nosync, noloadbalance.
#   - Credentials & file permissions: Read permissions and owner of YAML files.
#   - Local REST API status: GET /patroni, /primary, /replica, /cluster, /config.
#   - Watchdog/fencing status: /dev/watchdog visibility, watchdog daemon.
#   - DCS connectivity: Endpoint health (etcd/consul/etc.).
#   - Logs: journalctl or docker logs for OOMs, exceptions, and loops.
#
# RECOMMENDATIONS & RATIONALE:
#   - If Paused mode is true: Recommends resuming via patronictl resume. Rationale:
#     Paused mode completely halts automatic failovers and config convergence.
#   - If Orphan PostgreSQL process found (running without Patroni): Recommends stopping it.
#     Rationale: Orphan primaries continue writing data but are decoupled from the DCS,
#     presenting a severe split-brain hazard if a failover occurred.
#   - If Timing Rule (ttl >= loop_wait + 2 * retry_timeout) is violated: Recommends fixing.
#     Rationale: Ensures transient network jitter doesn't cause spurious demotions.
#   - If etcd (v2 API) is used: Recommends switching to etcd3. Rationale: The v2 API
#     is deprecated and removed in modern etcd releases.
#   - If Config mode > 600: Recommends chmod 600. Rationale: Contains cleartext DB passwords.
#   - If Watchdog is disabled: Recommends enabling it. Rationale: Watchdog/softdog provides
#     hardware-level fencing (kernel reset) to prevent split-brain on frozen nodes.
#
# USAGE:
#   ./patroni_deep_triage.sh [--url http://127.0.0.1:8008] [--config <path>]
# ============================================================================

set -o nounset
# NOTE: deliberately NO errexit — this script probes many optional things
# that legitimately fail (missing endpoints, unreadable files). Every probe
# handles its own failure; aborting mid-report would be worse than useless.

# ----------------------------------------------------------------------------
# Styling & helpers
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RST=$'\033[0m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'
    C_YEL=$'\033[1;33m'; C_BLU=$'\033[1;34m'; C_BOLD=$'\033[1m'
else
    C_RST="" C_RED="" C_GRN="" C_YEL="" C_BLU="" C_BOLD=""
fi

hr()   { printf '%s\n' "--------------------------------------------------------------------------------"; }
have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if have sudo && sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi

ISSUES=(); REMEDS=()
warn()  { echo "${C_YEL}[WARN]${C_RST} $1"; ISSUES+=("WARN: $1"); }
crit()  { echo "${C_RED}[CRIT]${C_RST} $1"; ISSUES+=("CRIT: $1"); }
ok()    { echo "${C_GRN}[OK]${C_RST} $1"; }
info()  { echo "${C_BLU}[INFO]${C_RST} $1"; }
remed() { REMEDS+=("$1"); }

# HTTP GET with three-level fallback: curl -> wget -> raw bash /dev/tcp.
# The /dev/tcp fallback matters on minimal EC2 images where neither curl
# nor wget is installed but bash is (it always is).
http_get() {
    local url="$1"
    if have curl; then
        curl -s --max-time 4 "$url" 2>/dev/null
    elif have wget; then
        wget -q -T 4 -O - "$url" 2>/dev/null
    else
        local hostport="${url#http://}"
        local host="${hostport%%/*}"; host="${host%%:*}"
        local port="${hostport%%/*}"; port="${port##*:}"; [ "$port" = "$host" ] && port=80
        local path="/${hostport#*/}"; [ "$path" = "/$hostport" ] && path="/"
        exec 9<>"/dev/tcp/$host/$port" 2>/dev/null || return 1
        printf 'GET %s HTTP/1.0\r\nHost: %s\r\n\r\n' "$path" "$host" >&9
        sed '1,/^\r*$/d' <&9
        exec 9<&- 9>&-
    fi
}

# HTTP status-code-only probe. Patroni role endpoints are DESIGNED for this:
# GET /primary returns 200 on the leader and 503 elsewhere. HAProxy health
# checks rely on exactly this; we use it to verify role claims independently.
http_code() {
    local url="$1"
    if have curl; then
        curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$url" 2>/dev/null
    else
        # wget exit code 8 = server error (5xx); crude but sufficient
        if have wget; then
            wget -q -T 4 -O /dev/null "$url" 2>/dev/null && echo 200 || echo 503
        else
            echo "n/a"
        fi
    fi
}

# JSON field extractor without jq: grep-based, works on Patroni's flat-ish
# JSON. For nested precision we use python3 when available.
jfield() {
    # $1 = json, $2 = key -> prints first scalar value of "key": ...
    echo "$1" | grep -oE "\"$2\":\s*(\"[^\"]*\"|[0-9]+|true|false|null)" | head -1 | \
        sed -E "s/\"$2\":\s*//; s/^\"//; s/\"$//"
}

PATRONI_URL="${PATRONI_URL:-http://127.0.0.1:8008}"
PATRONI_CFG_OVERRIDE=""

show_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --url <url>         Patroni REST API base (default: http://127.0.0.1:8008)
  --config <path>     Patroni YAML config path (default: auto-discover)
  --help              Show this help menu

Read-only deep audit of a Patroni node + cluster. Best run with sudo.
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --url) PATRONI_URL="$2"; shift 2 ;;
        --config) PATRONI_CFG_OVERRIDE="$2"; shift 2 ;;
        --help) show_help ;;
        *) echo "Unknown option: $1" >&2; show_help ;;
    esac
done

echo
echo "${C_BOLD}Patroni Deep Triage & Audit${C_RST}"
hr
echo "Host        : $(hostname -f 2>/dev/null || hostname)"
echo "REST target : $PATRONI_URL"
echo "Sudo        : $([ -n "$SUDO" ] && echo yes || echo NO — config/journal access limited)"
hr

# ============================================================================
# 0. CONTAINER RUNTIME DETECTION (Docker / Podman)
# ----------------------------------------------------------------------------
# Patroni frequently ships containerized: the Spilo image (Zalando) bundles
# patroni+postgres in ONE container configured almost purely via env vars
# (PATRONI_*/SPILO_*); compose stacks often run patroni, etcd, and haproxy
# as SEPARATE containers. Everything the host-path checks assume then fails:
#   - no host patroni process (pgrep sees only containerized ones as odd paths)
#   - no systemd unit (restart policy replaces enablement)
#   - YAML may not exist at all (env-only config) or lives inside the image
#   - logs go to `docker logs`, not journald
# Strategy: detect a Patroni container; if found, define exec wrappers so
# the SAME checks below run inside it, and switch log source to docker logs.
# The docker and podman CLIs are compatible for everything we use here.
# ============================================================================

DOCKER=""
for rt in docker podman; do
    if have "$rt"; then
        # Verify the daemon/socket actually answers, not just the CLI binary
        if $rt ps >/dev/null 2>&1; then DOCKER="$rt"; break
        elif [ -n "$SUDO" ] && $SUDO $rt ps >/dev/null 2>&1; then DOCKER="$SUDO $rt"; break
        fi
    fi
done

PATRONI_CONTAINER=""
CONTAINER_MODE=0
C_STATUS=""
STACK_CONTAINERS=""
if [ -n "$DOCKER" ]; then
    # Look for running containers and find the first one that runs the patroni process.
    # Skip known non-database containers first to avoid unnecessary exec calls.
    for c in $($DOCKER ps --format '{{.Names}}' 2>/dev/null); do
        case "$c" in
            *client*|*haproxy*|*etcd*|*proxy*|*nginx*|*pgbouncer*) continue ;;
        esac
        if $DOCKER exec "$c" pgrep -f 'bin/patroni' >/dev/null 2>&1; then
            PATRONI_CONTAINER="$c"
            break
        fi
    done

    # Fallback 1: check all running containers without skipping names
    if [ -z "$PATRONI_CONTAINER" ]; then
        for c in $($DOCKER ps --format '{{.Names}}' 2>/dev/null); do
            if $DOCKER exec "$c" pgrep -f 'bin/patroni' >/dev/null 2>&1; then
                PATRONI_CONTAINER="$c"
                break
            fi
        done
    fi

    # Fallback 2: image/name pattern matching (original logic)
    if [ -z "$PATRONI_CONTAINER" ]; then
        PATRONI_CONTAINER=$($DOCKER ps --format '{{.Names}} {{.Image}} {{.Ports}}' 2>/dev/null | \
            awk 'tolower($0) ~ /patroni|spilo/ {print $1; exit}')
    fi
    if [ -z "$PATRONI_CONTAINER" ]; then
        PATRONI_CONTAINER=$($DOCKER ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | \
            awk '/8008/ {print $1; exit}')
    fi

    if [ -n "$PATRONI_CONTAINER" ]; then
        CONTAINER_MODE=1
        # Restart policy + crash-loop counter: the container-world equivalents
        # of "systemd enabled" and "service keeps dying".
        C_STATUS=$($DOCKER inspect -f '{{.State.Status}} restarts={{.RestartCount}} policy={{.HostConfig.RestartPolicy.Name}}' "$PATRONI_CONTAINER" 2>/dev/null || true)
    fi
    # Sibling containers worth knowing about (etcd/haproxy in the same stack)
    STACK_CONTAINERS=$($DOCKER ps -a --format '{{.Names}}: {{.Image}} ({{.Status}})' 2>/dev/null | grep -iE 'etcd|consul|zookeeper|haproxy|pgbouncer|postgres|patroni|spilo' || true)
fi

# Exec wrapper: run a command inside the Patroni container. Containers may
# lack bash — use sh. Spilo already runs as postgres; no sudo inside.
cexec() {
    [ $CONTAINER_MODE = 1 ] || return 1
    $DOCKER exec "$PATRONI_CONTAINER" sh -c "$*" 2>/dev/null
}

# ============================================================================
# 1. PRESENCE, PROCESS & SERVICE STATE
# ----------------------------------------------------------------------------
# Patroni can run as a systemd unit, under supervisord, in a container, or
# hand-started. We check all signals: binary, process, unit, port 8008.
# A KEY subtlety: if the patroni PROCESS dies, PostgreSQL keeps running as
# an unmanaged orphan — clients still work, but there is NO failover and,
# worse, the leader key expires and another node may promote -> split brain
# risk if the orphan primary keeps accepting writes. We check for that.
# ============================================================================
echo
echo "${C_BOLD}1. Presence, Process & Service State${C_RST}"
hr

HAS_BIN=0; have patroni && HAS_BIN=1
HAS_CTL=0; have patronictl && HAS_CTL=1
PATRONI_PID=$(pgrep -f 'bin/patroni' | head -1 || true)
API_UP=0
API_TEST=$(http_get "$PATRONI_URL/patroni" || true)
[ -n "$API_TEST" ] && API_UP=1

# Container mode can substitute for every host-level signal: the binary and
# patronictl live inside the container, and the API may only be reachable
# on the container's own network. If host API probing failed but a container
# exists, retry against the container's internal IP before giving up.
if [ $CONTAINER_MODE = 1 ]; then
    if cexec "command -v patroni" >/dev/null; then HAS_BIN=1; fi
    if cexec "command -v patronictl" >/dev/null; then HAS_CTL=1; fi
    # Redefine PATRONI_PID to be the host PID of the container
    PATRONI_PID=$($DOCKER inspect -f '{{.State.Pid}}' "$PATRONI_CONTAINER" 2>/dev/null || true)
    if [ $API_UP = 0 ]; then
        # 8008 not published to the host: talk to the container IP directly,
        # or exec curl/wget inside the container as a last resort.
        C_IP=$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PATRONI_CONTAINER" 2>/dev/null | awk '{print $1}')
        if [ -n "$C_IP" ]; then
            ALT_URL="http://$C_IP:8008"
            API_TEST=$(http_get "$ALT_URL/patroni" || true)
            if [ -n "$API_TEST" ]; then
                info "REST API not on host $PATRONI_URL but reachable at container IP — switching target to $ALT_URL."
                PATRONI_URL="$ALT_URL"
                API_UP=1
            fi
        fi
        if [ $API_UP = 0 ]; then
            API_TEST=$(cexec "curl -s --max-time 4 http://localhost:8008/patroni || wget -q -T 4 -O - http://localhost:8008/patroni" || true)
            if [ -n "$API_TEST" ]; then
                info "REST API reachable only INSIDE the container (localhost:8008, port not published/attached network)."
                info "Host-side probes below will be skipped where needed; container-exec is used instead."
                API_UP=1
                # Redefine the HTTP helpers to go through the container for the
                # rest of the script — keeps every later section working unchanged.
                http_get()  { cexec "curl -s --max-time 4 ${1:-} || wget -q -T 4 -O - ${1:-}"; }
                http_code() { cexec "curl -s -o /dev/null -w '%{http_code}' --max-time 4 ${1:-}" || echo "n/a"; }
                PATRONI_URL="http://localhost:8008"
            fi
        fi
    fi
fi

if [ $HAS_BIN = 0 ] && [ -z "$PATRONI_PID" ] && [ $API_UP = 0 ] && [ $CONTAINER_MODE = 0 ]; then
    echo "Patroni is not installed and not running on this host (natively or in a container)."
    echo "If this cluster IS Patroni-managed, run this script on a cluster node,"
    echo "or point --url at a member's REST API."
    [ -n "$DOCKER" ] && echo "Container runtime present but no patroni/spilo container found: $DOCKER ps -a | grep -iE 'patroni|spilo'"
    exit 1
fi

if [ $CONTAINER_MODE = 1 ]; then
    info "CONTAINER MODE: Patroni runs in container '$PATRONI_CONTAINER' ($C_STATUS)."
    echo "Related stack containers:"
    echo "${STACK_CONTAINERS:-  (none found)}" | sed 's/^/  /'
    # Crash loop detection: RestartCount climbing = the container-world
    # equivalent of a service that keeps dying.
    RESTARTS=$(echo "$C_STATUS" | grep -oE 'restarts=[0-9]+' | grep -oE '[0-9]+')
    if [ "${RESTARTS:-0}" -gt 3 ] 2>/dev/null; then
        crit "Patroni container has restarted $RESTARTS times — crash loop!"
        remed "Read why: $DOCKER logs --tail 200 $PATRONI_CONTAINER; typical causes: bad env config, unreachable DCS, volume permissions (PGDATA must be owned by the container's postgres UID)."
    fi
    # Restart policy = boot survival, analogous to systemd 'enabled'
    POLICY=$(echo "$C_STATUS" | grep -oE 'policy=[a-z-]+' | cut -d= -f2)
    if [ "$POLICY" = "no" ] || [ -z "$POLICY" ]; then
        warn "Container restart policy is '${POLICY:-none}' — after a daemon/host restart, Patroni stays DOWN (equivalent of a disabled systemd unit)."
        remed "Set a policy: $DOCKER update --restart unless-stopped $PATRONI_CONTAINER (or fix restart: in docker-compose.yml and redeploy)."
    else
        ok "Container restart policy: $POLICY."
    fi
    # Stopped/exited siblings in the stack are a red flag (dead etcd kills HA)
    DEAD_SIBS=$(echo "$STACK_CONTAINERS" | grep -iE 'Exited|Created|Dead' || true)
    if [ -n "$DEAD_SIBS" ]; then
        crit "Stack containers NOT running:"
        echo "$DEAD_SIBS" | sed 's/^/    /'
        remed "Start them and read their exit reason: $DOCKER start <name>; $DOCKER logs --tail 100 <name>. A dead etcd container = Patroni demotes/read-only."
    fi
fi

if [ $CONTAINER_MODE = 1 ]; then
    echo "patroni binary   : $([ $HAS_BIN = 1 ] && cexec "command -v patroni" || echo 'not in PATH') (inside container)"
    echo "patronictl       : $([ $HAS_CTL = 1 ] && cexec "command -v patronictl" || echo 'not in PATH') (inside container)"
    [ $HAS_BIN = 1 ] && echo "patroni version  : $(cexec 'patroni --version' 2>/dev/null | head -1)"
    # Find container-internal PID
    C_PATRONI_PID=$(cexec "pgrep -f 'bin/patroni' | head -1" || true)
    echo "patroni process  : ${C_PATRONI_PID:-NOT RUNNING} (inside container) / host PID ${PATRONI_PID:-n/a}"
else
    echo "patroni binary   : $([ $HAS_BIN = 1 ] && command -v patroni || echo 'not in PATH')"
    echo "patronictl       : $([ $HAS_CTL = 1 ] && command -v patronictl || echo 'not in PATH')"
    [ $HAS_BIN = 1 ] && echo "patroni version  : $(patroni --version 2>/dev/null | head -1)"
    echo "patroni process  : ${PATRONI_PID:-NOT RUNNING}"
fi
echo "REST API         : $([ $API_UP = 1 ] && echo responding || echo 'NOT responding')"

if [ $CONTAINER_MODE = 1 ]; then
    echo "systemd unit     : n/a (container mode)"
elif have systemctl; then
    SVC_ACTIVE=$(systemctl is-active patroni 2>/dev/null || true)
    SVC_ENABLED=$(systemctl is-enabled patroni 2>/dev/null || true)
    echo "systemd unit     : active=$SVC_ACTIVE enabled=$SVC_ENABLED"
    if [ "$SVC_ACTIVE" = "active" ]; then
        ok "patroni.service is active."
    elif [ -n "$PATRONI_PID" ]; then
        warn "Patroni runs OUTSIDE systemd (PID $PATRONI_PID, unit=$SVC_ACTIVE) — it will not restart on crash/boot."
        remed "Migrate to the unit: stop the manual process cleanly, then: sudo systemctl enable --now patroni"
    else
        crit "patroni.service is '$SVC_ACTIVE' and no patroni process runs."
        remed "Start and inspect: sudo systemctl start patroni; journalctl -u patroni -n 100 --no-pager"
    fi
    if [ "$SVC_ENABLED" != "enabled" ] && [ "$SVC_ACTIVE" = "active" ]; then
        warn "patroni.service is active but NOT enabled — after a reboot this node stays down (cluster loses a member silently)."
        remed "Enable at boot: sudo systemctl enable patroni"
    fi
fi

# --- The orphaned-postgres check -------------------------------------------
# If PostgreSQL runs but Patroni does not, this node is unmanaged. If it is
# a PRIMARY, this is the single most dangerous state in the whole audit.
# CONTAINER CAVEAT: host pgrep DOES see processes inside containers (shared
# kernel), so a Spilo container's postgres would trigger a false positive
# here. In container mode we instead check INSIDE the container: postgres
# without patroni in the same container is the true orphan condition. A
# separate postgres container beside a dead patroni container is caught by
# the dead-siblings check in section 1.
if [ $CONTAINER_MODE = 1 ]; then
    PG_PID=$(cexec "pgrep -x postgres | head -1 || pgrep -x postmaster | head -1" || true)
    C_PATRONI_PID=$(cexec "pgrep -f 'bin/patroni' | head -1" || true)
    if [ -n "$PG_PID" ] && [ -z "$C_PATRONI_PID" ]; then
        crit "Inside container '$PATRONI_CONTAINER': PostgreSQL runs but the patroni process is GONE — unmanaged orphan instance!"
        remed "The container entrypoint should supervise patroni; if patroni died but postgres survived, the cleanest fix is a container restart at a safe moment: $DOCKER restart $PATRONI_CONTAINER (verify cluster role first via another member's /cluster endpoint)."
    fi
    PG_PID=""  # suppress the host-level check below
else
    PG_PID=$(pgrep -x postgres | head -1 || pgrep -x postmaster | head -1 || true)
fi
if [ -n "$PG_PID" ] && [ -z "$PATRONI_PID" ]; then
    crit "PostgreSQL is RUNNING (pid $PG_PID) but Patroni is NOT — unmanaged orphan instance!"
    echo "     If this node was the primary, the leader lease will expire and another"
    echo "     member may promote while this one still accepts writes => SPLIT BRAIN."
    remed "Decide FAST: (a) if cluster failed over already, STOP this postgres before apps write to it: sudo systemctl stop postgresql; (b) if not, start patroni to re-adopt it: sudo systemctl start patroni (Patroni adopts a running instance if system IDs match)."
fi

# Also flag postgres started via its own unit alongside patroni — a classic
# misconfiguration: two supervisors fighting over one instance.
if [ $CONTAINER_MODE = 0 ] && have systemctl && [ -n "$PATRONI_PID" ]; then
    for u in postgresql postgresql@14-main postgresql@15-main postgresql@16-main postgresql@17-main postgresql-14 postgresql-15 postgresql-16 postgresql-17; do
        if systemctl is-enabled "$u" >/dev/null 2>&1; then
            warn "systemd unit '$u' is ENABLED alongside Patroni — on reboot, systemd and Patroni will both try to manage PostgreSQL (port conflicts, wrong config)."
            remed "Disable the native unit; Patroni must be the only supervisor: sudo systemctl disable --now $u"
        fi
    done
fi
hr

# ============================================================================
# 2. CONFIG DISCOVERY & STATIC SEMANTICS
# ----------------------------------------------------------------------------
# Patroni config has THREE layers, and misunderstanding them is the #1
# source of "I changed the config but nothing happened" tickets:
#   (a) YAML file  -> local, read at start/reload (SIGHUP or POST /reload)
#   (b) DCS dynamic config (/config key) -> cluster-wide, edited via
#       'patronictl edit-config'; wins over (a) for the parameters it holds
#   (c) Environment variables PATRONI_* -> highest precedence of all
# The bootstrap: section of the YAML is applied ONLY at cluster creation —
# editing it later does nothing (extremely common trap).
# ============================================================================
echo
echo "${C_BOLD}2. Configuration Discovery & Static Semantics${C_RST}"
hr

PATRONI_CFG="$PATRONI_CFG_OVERRIDE"
if [ -z "$PATRONI_CFG" ]; then
    # Discovery order: process cmdline (authoritative — it is what the
    # running daemon actually loaded), then conventional paths.
    if [ -n "$PATRONI_PID" ] && [ $CONTAINER_MODE = 0 ]; then
        PATRONI_CFG=$(tr '\0' ' ' < "/proc/$PATRONI_PID/cmdline" 2>/dev/null | grep -oE '[^ ]+\.ya?ml' | head -1 || true)
    fi
    if [ -z "$PATRONI_CFG" ]; then
        for pf in /etc/patroni/patroni.yml /etc/patroni/config.yml /etc/patroni/*.yml /etc/patroni.yml /opt/patroni/patroni.yml; do
            if $SUDO test -r "$pf" 2>/dev/null || [ -r "$pf" ]; then PATRONI_CFG="$pf"; break; fi
        done
    fi
fi

CFG=""
CFG_IN_CONTAINER=0
if [ -n "$PATRONI_CFG" ] && [ $CONTAINER_MODE = 0 ]; then
    echo "Config file: $PATRONI_CFG"
    CFG=$($SUDO cat "$PATRONI_CFG" 2>/dev/null || cat "$PATRONI_CFG" 2>/dev/null || true)
    [ -z "$CFG" ] && warn "Config exists but is not readable as this user — re-run with sudo for full static analysis."
elif [ $CONTAINER_MODE = 1 ]; then
    # In container mode: the YAML may be (a) bind-mounted from the host (we
    # may have already found it above), (b) baked into the image, or —
    # Spilo's default — (c) GENERATED at container start from env vars into
    # /home/postgres/postgres.yml. Try inside-container paths.
    if [ -n "$PATRONI_CFG" ]; then
        # Host path found (bind mount case) — prefer it, it is editable.
        echo "Config file (host bind mount): $PATRONI_CFG"
        CFG=$($SUDO cat "$PATRONI_CFG" 2>/dev/null || cat "$PATRONI_CFG" 2>/dev/null || true)
    fi
    if [ -z "$CFG" ]; then
        # Find it inside the container: cmdline of PID 1 first, then Spilo
        # and conventional locations.
        IN_CFG=$(cexec "tr '\0' ' ' < /proc/1/cmdline" | grep -oE '[^ ]+\.ya?ml' | head -1 || true)
        for pf in "$IN_CFG" /home/postgres/postgres.yml /etc/patroni/patroni.yml /etc/patroni.yml /config/patroni.yml; do
            [ -z "$pf" ] && continue
            CFG=$(cexec "cat $pf" || true)
            if [ -n "$CFG" ]; then
                PATRONI_CFG="$pf"
                CFG_IN_CONTAINER=1
                echo "Config file (inside container): $pf"
                info "NOTE: this file lives IN the container. If it was generated from env vars (Spilo), editing it does not survive a container recreate — change the env/compose file instead."
                break
            fi
        done
    fi
    # Env-var config layer: in containers this is usually the REAL config.
    # Harvest PATRONI_*/SPILO_* from docker inspect (redact passwords).
    C_ENV=$($DOCKER inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$PATRONI_CONTAINER" 2>/dev/null | \
            grep -E '^(PATRONI_|SPILO_)' | grep -viE 'password|secret' || true)
    if [ -n "$C_ENV" ]; then
        info "Container env config (PATRONI_*/SPILO_* — overrides any YAML; passwords redacted):"
        echo "$C_ENV" | sed 's/^/    /'
        # Make key env values available to the same static checks below by
        # synthesizing YAML-ish lines and appending to CFG. Deliberately
        # simple: only the parameters our checks actually grep for.
        ENV_SCOPE=$(echo "$C_ENV" | grep -E '^(PATRONI_SCOPE|SPILO_SCOPE)=' | head -1 | cut -d= -f2)
        ENV_NAME=$(echo "$C_ENV" | grep -E '^PATRONI_NAME=' | head -1 | cut -d= -f2)
        ENV_ETCD=$(echo "$C_ENV" | grep -E '^PATRONI_ETCD3?_HOSTS?=' | head -1 | cut -d= -f2- | tr -d '"'"'"'[]')
        [ -n "$ENV_SCOPE" ] && CFG="$CFG"$'\n'"scope: $ENV_SCOPE"
        [ -n "$ENV_NAME" ]  && CFG="$CFG"$'\n'"name: $ENV_NAME"
        if [ -n "$ENV_ETCD" ]; then
            CFG="$CFG"$'\n'"etcd3:"$'\n'"  hosts: $ENV_ETCD"
        fi
    fi
    [ -z "$CFG" ] && warn "No Patroni config found on host, in container paths, or in env vars — static analysis limited (live REST checks below still authoritative)."
else
    warn "No Patroni YAML found on standard paths and none passed via --config."
fi

# PATRONI_* env vars override the file — if the unit file injects them,
# the YAML is partially decorative. Surface that.
if [ -n "$PATRONI_PID" ] && [ $CONTAINER_MODE = 0 ]; then
    ENV_OVERRIDES=$(tr '\0' '\n' < "/proc/$PATRONI_PID/environ" 2>/dev/null | grep -E '^PATRONI_' | grep -vE 'PASSWORD|password' || true)
    ENV_OVERRIDES_SUDO=$($SUDO tr '\0' '\n' < "/proc/$PATRONI_PID/environ" 2>/dev/null | grep -E '^PATRONI_' | grep -vE 'PASSWORD|password' || true)
    [ -z "$ENV_OVERRIDES" ] && ENV_OVERRIDES="$ENV_OVERRIDES_SUDO"
    if [ -n "$ENV_OVERRIDES" ]; then
        info "PATRONI_* environment variables override the YAML (highest precedence):"
        echo "$ENV_OVERRIDES" | sed 's/^/    /'
    fi
fi

if [ -n "$CFG" ]; then
    # --- scope / name sanity -------------------------------------------------
    SCOPE=$(echo "$CFG" | grep -E '^\s*scope:' | head -1 | sed 's/.*scope:\s*//' | tr -d '"'"'"' ')
    NAME=$(echo "$CFG"  | grep -E '^\s*name:'  | head -1 | sed 's/.*name:\s*//'  | tr -d '"'"'"' ')
    echo "scope (cluster name): ${SCOPE:-<missing!>}"
    echo "name  (member name) : ${NAME:-<missing!>}"
    [ -z "$SCOPE" ] && crit "No 'scope' in config — Patroni cannot know which cluster it belongs to."
    # Member name must be unique per cluster; equal to hostname is convention
    HN=$(hostname -s 2>/dev/null || hostname)
    if [ -n "$NAME" ] && [ "$NAME" != "$HN" ]; then
        info "Member name '$NAME' differs from hostname '$HN' — legal, but confirm it is unique across the cluster (duplicate names corrupt DCS member records)."
    fi

    # --- DCS backend detection ----------------------------------------------
    DCS_KIND=$(echo "$CFG" | grep -oE '^\s*(etcd3|etcd|consul|zookeeper|exhibitor|kubernetes|raft):' | head -1 | tr -d ' :' || true)
    echo "DCS backend: ${DCS_KIND:-<none declared!>}"
    if [ "$DCS_KIND" = "etcd" ]; then
        # etcd (v2 protocol) is long-deprecated; etcd3 is the supported one.
        warn "Config uses 'etcd:' (v2 API) — deprecated; etcd v2 API is removed in modern etcd builds."
        if [ $CONTAINER_MODE = 1 ]; then
            remed "Switch config section from etcd: to etcd3: (same hosts syntax) and restart the container: $DOCKER restart $PATRONI_CONTAINER"
        else
            remed "Switch config section from etcd: to etcd3: (same hosts syntax) and reload Patroni: sudo systemctl reload patroni"
        fi
    fi
    if [ "$DCS_KIND" = "raft" ]; then
        warn "Built-in Raft DCS is deprecated/removed in Patroni 4.x — plan migration to etcd3."
    fi

    # --- bootstrap-vs-dynamic trap --------------------------------------------
    if echo "$CFG" | grep -qE '^\s*bootstrap:'; then
        info "bootstrap: section present. REMINDER: it applies ONLY at cluster creation."
        echo "     Editing bootstrap.dcs values now changes NOTHING on a running cluster —"
        echo "     use: patronictl -c $PATRONI_CFG edit-config   (writes the DCS /config key)."
    fi

    # --- timing rule (the golden rule) ---------------------------------------
    # These may live in bootstrap.dcs (only initial) or in the DCS dynamic
    # config. We read the file values here and the LIVE values from the DCS
    # via the REST /config endpoint in section 4 — live wins.
    TTL=$(echo "$CFG"   | grep -E '^\s*ttl:'           | head -1 | grep -oE '[0-9]+' || true)
    LOOP=$(echo "$CFG"  | grep -E '^\s*loop_wait:'     | head -1 | grep -oE '[0-9]+' || true)
    RETRY=$(echo "$CFG" | grep -E '^\s*retry_timeout:' | head -1 | grep -oE '[0-9]+' || true)
    echo "file-level timings: ttl=${TTL:-?} loop_wait=${LOOP:-?} retry_timeout=${RETRY:-?} (live values checked in section 4)"

    # --- tags: the silent failover modifiers ---------------------------------
    # tags are per-member behavior switches. The dangerous ones:
    #   nofailover: true    -> member can NEVER be promoted
    #   nosync: true        -> excluded from synchronous replication
    #   noloadbalance: true -> /replica returns 503 (LB skips it)
    #   clonefrom: true     -> other members prefer cloning from it
    #   replicatefrom: X    -> cascading replication topology
    for tag in nofailover nosync noloadbalance; do
        if echo "$CFG" | grep -qE "^\s*${tag}:\s*true"; then
            warn "tag ${tag}: true on THIS member — verify this is intended (it silently changes failover/LB behavior)."
        fi
    done
    RF=$(echo "$CFG" | grep -E '^\s*replicatefrom:' | head -1 | sed 's/.*replicatefrom:\s*//' || true)
    [ -n "$RF" ] && info "Cascading replication: this member replicates from '$RF', not the leader. If '$RF' dies, this member stalls until reconfigured."

    # --- authentication material ----------------------------------------------
    # Patroni needs (at least) superuser + replication credentials. Missing
    # or wrong ones produce the infamous 'FATAL: password authentication
    # failed for user "replicator"' loop on replicas.
    for role in superuser replication rewind; do
        if ! echo "$CFG" | grep -qE "^\s*${role}:"; then
            [ "$role" = "rewind" ] && continue  # rewind user optional
            warn "No '${role}:' auth block found in YAML — Patroni may fail to manage/replicate."
        fi
    done
    if echo "$CFG" | grep -qE '^\s*use_pg_rewind:\s*true'; then
        ok "use_pg_rewind: true — failed ex-primaries can rejoin without a full re-clone (needs wal_log_hints=on or data checksums)."
    else
        info "use_pg_rewind not enabled — a demoted ex-primary with diverged timeline will need a FULL reinit (slow on big clusters)."
        remed "Consider enabling rewind: patronictl edit-config -> postgresql: {use_pg_rewind: true}; requires wal_log_hints=on (restart) or data checksums."
    fi

    # --- config file permissions (it contains passwords!) ---------------------
    if [ $CFG_IN_CONTAINER = 1 ]; then
        CFG_PERM=$(cexec "stat -c '%a %U' $PATRONI_CFG" 2>/dev/null || true)
    else
        CFG_PERM=$($SUDO stat -c '%a %U' "$PATRONI_CFG" 2>/dev/null || stat -c '%a %U' "$PATRONI_CFG" 2>/dev/null || true)
    fi
    if [ -n "$CFG_PERM" ]; then
        CMODE=${CFG_PERM%% *}
        if [ "${CMODE:-600}" -gt 640 ] 2>/dev/null; then
            warn "Patroni YAML mode is $CMODE — it contains DB passwords; should be 600 (owner postgres)."
            if [ $CFG_IN_CONTAINER = 1 ]; then
                remed "Tighten inside container: $DOCKER exec -u root $PATRONI_CONTAINER chown postgres:postgres $PATRONI_CFG && $DOCKER exec -u root $PATRONI_CONTAINER chmod 600 $PATRONI_CFG"
            else
                remed "Tighten: sudo chown postgres:postgres $PATRONI_CFG && sudo chmod 600 $PATRONI_CFG"
            fi
        fi
    fi
fi
hr

# ============================================================================
# 3. REST API — LOCAL MEMBER DEEP STATE
# ----------------------------------------------------------------------------
# GET /patroni is the member's self-report: role, state, timeline, xlog
# positions, pending_restart flag, pause flag, watchdog visibility.
# We also probe the ROLE endpoints (/primary /replica /read-only /health)
# with status codes, because that is what load balancers actually consume —
# a mismatch between self-report and role endpoint = LB routing bug.
# ============================================================================
echo
echo "${C_BOLD}3. REST API — Local Member State${C_RST}"
hr

MEMBER_JSON=$(http_get "$PATRONI_URL/patroni" || true)
IS_LEADER=0
if [ -n "$MEMBER_JSON" ]; then
    ROLE=$(jfield "$MEMBER_JSON" role)
    STATE=$(jfield "$MEMBER_JSON" state)
    TL=$(jfield "$MEMBER_JSON" timeline)
    PAUSED=$(jfield "$MEMBER_JSON" pause)
    PENDING=$(jfield "$MEMBER_JSON" pending_restart)
    SRV_VER=$(jfield "$MEMBER_JSON" server_version)
    echo "role=$ROLE state=$STATE timeline=${TL:-?} server_version=${SRV_VER:-?}"
    [ "$ROLE" = "master" ] || [ "$ROLE" = "primary" ] || [ "$ROLE" = "leader" ] && IS_LEADER=1

    case "$STATE" in
        running|streaming)
            ok "Member state '$STATE'." ;;
        "in archive recovery")
            warn "State 'in archive recovery' — replica is NOT streaming; it replays from archive only (streaming broken? slot missing? primary_conninfo wrong?)."
            if [ $CONTAINER_MODE = 1 ]; then
                remed "Check container logs: $DOCKER logs --tail 50 $PATRONI_CONTAINER; verify replication slot exists on the primary."
            else
                remed "Check on this node: journalctl -u patroni -n 50; and in PostgreSQL log: 'started streaming WAL' vs 'FATAL: could not connect'; verify replication slot exists on the primary."
            fi ;;
        "start failed"|crashed|stopped)
            crit "Member state '$STATE' — PostgreSQL is not serving here."
            if [ $CONTAINER_MODE = 1 ]; then
                remed "Read the actual error: $DOCKER logs --tail 100 $PATRONI_CONTAINER | grep -A3 -iE 'fatal|error'. Common causes: bad GUC after edit-config, missing WAL, wrong permissions on PGDATA."
            else
                remed "Read the actual error: journalctl -u patroni -n 100 --no-pager | grep -A3 -iE 'fatal|error'; then PostgreSQL's own log. Common causes: bad GUC after edit-config, missing WAL, wrong permissions on PGDATA."
            fi ;;
        creating\ replica|"creating replica")
            info "Member is being (re)cloned right now — expect it to be temporarily missing from the LB." ;;
        *)
            [ -n "$STATE" ] && info "Member state: $STATE" ;;
    esac

    # --- pause: the silent killer ---------------------------------------------
    if [ "$PAUSED" = "true" ]; then
        crit "Cluster is PAUSED — the HA loop is disabled: NO automatic failover, NO config convergence. Everything LOOKS healthy until the primary dies."
        if [ $CONTAINER_MODE = 1 ]; then
            remed "Resume when appropriate: $DOCKER exec -it $PATRONI_CONTAINER patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} resume ${SCOPE:-<cluster>}  (document WHY it was paused before resuming — maintenance may be in progress!)"
        else
            remed "Resume when appropriate: patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} resume ${SCOPE:-<cluster>}  (document WHY it was paused before resuming — maintenance may be in progress!)"
        fi
    else
        ok "Cluster management is active (not paused)."
    fi

    # --- pending restart -------------------------------------------------------
    # Patroni tracks restart-required GUC changes made via edit-config and
    # exposes them here. A pending_restart member runs with OLD values.
    if [ "$PENDING" = "true" ]; then
        warn "pending_restart=true — a restart-requiring parameter was changed but this member still runs OLD values."
        if [ $CONTAINER_MODE = 1 ]; then
            remed "Rolling, Patroni-orchestrated restart (replicas first, leader last, zero surprise): $DOCKER exec -it $PATRONI_CONTAINER patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} restart ${SCOPE:-<cluster>} --pending  (add a member name to do one at a time)"
        else
            remed "Rolling, Patroni-orchestrated restart (replicas first, leader last, zero surprise): patronictl -c ${PATRONI_CFG:-<cfg>} restart ${SCOPE:-<cluster>} --pending  (add a member name to do one at a time)"
        fi
    else
        ok "No pending restart on this member."
    fi

    # --- replication self-view (leader-side) -----------------------------------
    if [ $IS_LEADER = 1 ]; then
        REPL_COUNT=$(echo "$MEMBER_JSON" | grep -oE '"replication":\s*\[' | wc -l)
        if [ "$REPL_COUNT" -gt 0 ]; then
            SYNC_STANDBYS=$(echo "$MEMBER_JSON" | grep -oE '"sync_state":\s*"sync"' | wc -l)
            ASYNC_STANDBYS=$(echo "$MEMBER_JSON" | grep -oE '"sync_state":\s*"async"' | wc -l)
            echo "Leader sees standbys: sync=$SYNC_STANDBYS async=$ASYNC_STANDBYS"
            [ $((SYNC_STANDBYS + ASYNC_STANDBYS)) -eq 0 ] && warn "Leader reports NO connected standbys — single point of failure right now."
        fi
    fi
else
    crit "REST API $PATRONI_URL/patroni is not answering."
    echo "     Without the API: patronictl still works (talks to DCS directly), but"
    echo "     HAProxy health checks are DEAD -> LB marks this node down."
    if [ $CONTAINER_MODE = 1 ]; then
        remed "Check restapi: block in the YAML (listen address/port), container port publishing, local firewall, and container logs: $DOCKER logs --tail 50 $PATRONI_CONTAINER."
    else
        remed "Check restapi: block in the YAML (listen address/port), local firewall (ss -ltnp | grep 8008), and journalctl -u patroni -n 50."
    fi
fi

# --- Role endpoints as the LB sees them ------------------------------------
echo
echo "Role endpoints (what HAProxy actually consumes; 200=match, 503=no):"
for ep in primary replica "read-only" health liveness readiness; do
    CODE=$(http_code "$PATRONI_URL/$ep")
    printf "  GET /%-10s -> %s\n" "$ep" "$CODE"
done
# Cross-check: self-reported role vs role endpoint answers
if [ -n "$MEMBER_JSON" ]; then
    P_CODE=$(http_code "$PATRONI_URL/primary")
    if [ $IS_LEADER = 1 ] && [ "$P_CODE" != "200" ]; then
        crit "Self-report says LEADER but GET /primary returns $P_CODE — load balancers will NOT route writes here!"
        if [ $CONTAINER_MODE = 1 ]; then
            remed "Restart container after checking logs (member/DCS disagreement): $DOCKER restart $PATRONI_CONTAINER — Patroni re-syncs its published role."
        else
            remed "Restart patroni on this node after checking logs (member/DCS disagreement): sudo systemctl restart patroni — Patroni re-syncs its published role."
        fi
    elif [ $IS_LEADER = 0 ] && [ "$P_CODE" = "200" ]; then
        crit "Self-report says REPLICA but GET /primary returns 200 — TWO nodes may answer /primary: split-brain at the LB layer!"
        if [ $CONTAINER_MODE = 1 ]; then
            remed "Immediately compare all members' /primary responses; verify only one leader in DCS: $DOCKER exec -it $PATRONI_CONTAINER patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} list; investigate DCS health before touching PostgreSQL."
        else
            remed "Immediately compare all members' /primary responses; verify only one leader in DCS: patronictl -c <cfg> list; investigate DCS health before touching PostgreSQL."
        fi
    fi
fi
hr

# ============================================================================
# 4. CLUSTER-WIDE VIEW & DYNAMIC (DCS) CONFIG
# ----------------------------------------------------------------------------
# GET /cluster is the DCS-backed cluster truth: all members, their lag,
# any scheduled switchover, sync standby designation.
# GET /config is the LIVE dynamic configuration (the /config DCS key) —
# this is where ttl/loop_wait/retry_timeout ACTUALLY live on a running
# cluster (file values are only the bootstrap seed).
# ============================================================================
echo
echo "${C_BOLD}4. Cluster-Wide State & Dynamic Config (DCS truth)${C_RST}"
hr

CLUSTER_JSON=$(http_get "$PATRONI_URL/cluster" || true)
if [ -n "$CLUSTER_JSON" ]; then
    # Pretty print if python3 exists; raw otherwise
    if have python3; then
        echo "$CLUSTER_JSON" | python3 -m json.tool 2>/dev/null | head -60 || echo "$CLUSTER_JSON" | head -5
    else
        echo "$CLUSTER_JSON" | head -5
    fi

    # Leader count — the fundamental invariant: exactly one.
    LEADERS=$(echo "$CLUSTER_JSON" | grep -oE '"role":\s*"(leader|master|primary)"' | wc -l)
    if [ "$LEADERS" -eq 1 ]; then
        ok "Exactly one leader in the cluster view."
    elif [ "$LEADERS" -eq 0 ]; then
        crit "NO leader in cluster view — cluster is read-only / leaderless right now (DCS outage? failed election? all candidates lagging past maximum_lag_on_failover?)."
        if [ $CONTAINER_MODE = 1 ]; then
            remed "Check DCS health first (etcdctl endpoint health). If DCS is fine and no candidate qualifies: $DOCKER exec -it $PATRONI_CONTAINER patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} failover ${SCOPE:-<cluster>} --candidate <best_member> (accepts data-loss trade-off — document it!)."
        else
            remed "Check DCS health first (etcdctl endpoint health). If DCS is fine and no candidate qualifies: patronictl -c <cfg> failover ${SCOPE:-<cluster>} --candidate <best_member> (accepts data-loss trade-off — document it!)."
        fi
    else
        crit "$LEADERS members claim leadership — SPLIT BRAIN in the cluster metadata!"
        if [ $CONTAINER_MODE = 1 ]; then
            remed "Do NOT restart things blindly. Compare timelines ($DOCKER exec -it $PATRONI_CONTAINER patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} list), identify the stale claimant, stop ITS patroni+postgres, resolve DCS state, then rejoin it as replica (likely reinit)."
        else
            remed "Do NOT restart things blindly. Compare timelines (patronictl list), identify the stale claimant, stop ITS patroni+postgres, resolve DCS state, then rejoin it as replica (likely reinit)."
        fi
    fi

    # Per-member lag & state (lag is in BYTES here)
    if have python3; then
        echo
        echo "Members (name / role / state / TL / lag bytes):"
        echo "$CLUSTER_JSON" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for m in d.get("members", []):
    print("  %-20s %-10s %-18s TL=%-4s lag=%s" % (
        m.get("name","?"), m.get("role","?"), m.get("state","?"),
        m.get("timeline","?"), m.get("lag","-")))
' 2>/dev/null || true
    fi
    # Threshold flags without python: grep numeric lags
    for lag in $(echo "$CLUSTER_JSON" | grep -oE '"lag":\s*[0-9]+' | grep -oE '[0-9]+'); do
        if [ "$lag" -gt 1073741824 ] 2>/dev/null; then
            crit "A member lags $((lag / 1048576)) MiB (>1GiB) — failover to it would lose that much WAL; check maximum_lag_on_failover interplay."
        elif [ "$lag" -gt 104857600 ] 2>/dev/null; then
            warn "A member lags $((lag / 1048576)) MiB (>100MiB)."
        fi
    done
    if echo "$CLUSTER_JSON" | grep -qE '"state":\s*"(stopped|start failed|crashed)"'; then
        crit "Cluster contains failed/stopped members (see list above) — reduced redundancy."
        if [ $CONTAINER_MODE = 1 ]; then
            remed "On each failed member: check container logs; if data is unrecoverable: $DOCKER exec -it <container_name> patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} reinit ${SCOPE:-<cluster>} <member> (DESTRUCTIVE re-clone of that member; confirm twice)."
        else
            remed "On each failed member: journalctl -u patroni -n 100; if data is unrecoverable: patronictl -c <cfg> reinit ${SCOPE:-<cluster>} <member> (DESTRUCTIVE re-clone of that member; confirm twice)."
        fi
    fi

    # Scheduled switchover pending?
    if echo "$CLUSTER_JSON" | grep -q '"scheduled_switchover"'; then
        SS_AT=$(jfield "$CLUSTER_JSON" at)
        warn "A SWITCHOVER IS SCHEDULED (at: ${SS_AT:-?}) — the primary will move on its own at that time!"
        if [ $CONTAINER_MODE = 1 ]; then
            remed "If unintended, cancel it: $DOCKER exec -it $PATRONI_CONTAINER patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} flush ${SCOPE:-<cluster>} switchover"
        else
            remed "If unintended, cancel it: patronictl -c <cfg> flush ${SCOPE:-<cluster>} switchover"
        fi
    fi

    # Timeline divergence across members: all healthy members should share
    # the leader's timeline once caught up. Persistent mixed TLs => stuck
    # replicas replaying an old timeline (need rewind/reinit).
    TLS=$(echo "$CLUSTER_JSON" | grep -oE '"timeline":\s*[0-9]+' | grep -oE '[0-9]+' | sort -u | wc -l)
    [ "$TLS" -gt 1 ] 2>/dev/null && warn "Members are on DIFFERENT timelines — replicas may be stuck pre-failover; check their logs for 'requested timeline ... is not in this server''s history'."
fi

# --- Dynamic config: the LIVE ttl/loop_wait/retry_timeout -------------------
DCS_CFG=$(http_get "$PATRONI_URL/config" || true)
if [ -n "$DCS_CFG" ]; then
    L_TTL=$(jfield "$DCS_CFG" ttl)
    L_LOOP=$(jfield "$DCS_CFG" loop_wait)
    L_RETRY=$(jfield "$DCS_CFG" retry_timeout)
    L_MAXLAG=$(jfield "$DCS_CFG" maximum_lag_on_failover)
    L_SYNC=$(jfield "$DCS_CFG" synchronous_mode)
    echo
    echo "LIVE dynamic config: ttl=${L_TTL:-30} loop_wait=${L_LOOP:-10} retry_timeout=${L_RETRY:-10} maximum_lag_on_failover=${L_MAXLAG:-1048576} synchronous_mode=${L_SYNC:-false}"
    TTL_V=${L_TTL:-30}; LOOP_V=${L_LOOP:-10}; RETRY_V=${L_RETRY:-10}
    if [ "$TTL_V" -lt $((LOOP_V + 2 * RETRY_V)) ] 2>/dev/null; then
        crit "LIVE timing rule VIOLATED: ttl ($TTL_V) < loop_wait + 2*retry_timeout ($((LOOP_V + 2*RETRY_V))). One DCS hiccup can expire the lease -> spurious demotion of a healthy primary."
        if [ $CONTAINER_MODE = 1 ]; then
            remed "Fix live: $DOCKER exec -it $PATRONI_CONTAINER patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} edit-config ${SCOPE:-<cluster>} and set ttl >= loop_wait + 2*retry_timeout (defaults 30/10/10 are sane)."
        else
            remed "Fix live: patronictl -c <cfg> edit-config ${SCOPE:-<cluster>} and set ttl >= loop_wait + 2*retry_timeout (defaults 30/10/10 are sane)."
        fi
    else
        ok "LIVE timing rule satisfied: ttl >= loop_wait + 2*retry_timeout."
    fi
    if [ "$L_SYNC" = "true" ]; then
        info "synchronous_mode=true: leader will BLOCK commits if no sync standby is available (unless synchronous_mode_strict=false lets it degrade). Verify a Sync Standby exists in patronictl list."
    fi
    # Dangerous knobs that people set during incidents and forget:
    for knob in check_timeline master_start_timeout primary_start_timeout; do
        V=$(jfield "$DCS_CFG" "$knob")
        [ -n "$V" ] && [ "$V" != "null" ] && info "dynamic $knob=$V (non-default — confirm intent)"
    done
else
    info "GET /config not answering — dynamic config unverifiable via REST (patronictl show-config works via DCS)."
fi

# --- patronictl overview (independent path: talks to DCS, not local API) ----
if [ $HAS_CTL = 1 ]; then
    echo
    echo "patronictl list (DCS-direct view — survives local API death):"
    CTL_OUT=""
    if [ $CONTAINER_MODE = 1 ]; then
        # Inside the container: patronictl usually needs no -c flag there —
        # Spilo sets PATRONICTL_CONFIG_FILE / default paths correctly.
        CTL_OUT=$(cexec "patronictl list" || true)
        [ -z "$CTL_OUT" ] && [ $CFG_IN_CONTAINER = 1 ] && CTL_OUT=$(cexec "patronictl -c $PATRONI_CFG list" || true)
        # Remediation commands in container mode must be exec-prefixed:
        [ -n "$CTL_OUT" ] && info "In container mode, run patronictl via: $DOCKER exec -it $PATRONI_CONTAINER patronictl <cmd>"
    elif [ -n "$PATRONI_CFG" ]; then
        CTL_OUT=$($SUDO patronictl -c "$PATRONI_CFG" list 2>/dev/null || patronictl -c "$PATRONI_CFG" list 2>/dev/null || true)
    fi
    if [ -n "$CTL_OUT" ]; then
        echo "$CTL_OUT" | sed 's/^/  /'
    else
        warn "patronictl cannot reach the DCS — if the REST API above ALSO works, config in YAML vs live daemon may differ; if both fail, DCS is down."
    fi
fi
hr

# ============================================================================
# 5. DCS BACKEND HEALTH (from this node's perspective)
# ----------------------------------------------------------------------------
# Patroni is only as available as its DCS. We extract DCS endpoints from the
# YAML and probe each: TCP reachability + native health where possible.
# Remember the design consequence: DCS quorum loss => leader demotes =>
# READ-ONLY cluster. That is a feature (fencing), not a bug — but on
# operational systems it will manifest as the database suddenly rejecting writes.
# ============================================================================
echo
echo "${C_BOLD}5. DCS Backend Reachability${C_RST}"
hr

DCS_HOSTS=()
if [ -n "$CFG" ]; then
    # hosts: can be a YAML list, a comma string, or host:/port: pairs.
    # We harvest every ip:port and bare-ip pattern under the DCS section.
    while read -r hp; do
        DCS_HOSTS+=("$hp")
    done < <(echo "$CFG" | grep -A15 -E '^\s*(etcd3?|consul|zookeeper):' | \
             grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?|[a-zA-Z0-9._-]+:[0-9]{4,5}' | sort -u)
fi

if [ ${#DCS_HOSTS[@]} -gt 0 ]; then
    REACHABLE=0
    for hp in "${DCS_HOSTS[@]}"; do
        H="${hp%%:*}"; P="${hp##*:}"; [ "$P" = "$H" ] && P=2379
        if (timeout 1 bash -c "echo > /dev/tcp/$H/$P") 2>/dev/null; then
            printf "  %-25s ${C_GRN}%-10s${C_RST}" "$H:$P" "OPEN"
            REACHABLE=$((REACHABLE+1))
            # etcd native health if it looks like etcd
            if [ "$P" = "2379" ]; then
                EH=$(http_get "http://$H:$P/health" || true)
                echo "$EH" | grep -q 'true' && printf " health=true" || printf " health=%s" "${EH:-n/a}"
            fi
            echo
        else
            printf "  %-25s ${C_RED}%-10s${C_RST}\n" "$H:$P" "CLOSED"
        fi
    done
    if [ "$REACHABLE" -eq 0 ]; then
        crit "NO DCS endpoint reachable from this node — Patroni here cannot hold/see the leader lock. If this is the primary, it WILL self-demote within ttl (${L_TTL:-30}s)."
        remed "Fix DCS reachability first: firewall (2379/8500/2181), DCS service state on peers, DNS. Everything else is secondary."
    elif [ "$REACHABLE" -lt ${#DCS_HOSTS[@]} ]; then
        warn "Only $REACHABLE/${#DCS_HOSTS[@]} DCS endpoints reachable — quorum may still hold, but redundancy is degraded."
    else
        ok "All ${#DCS_HOSTS[@]} configured DCS endpoints reachable."
    fi
else
    info "Could not harvest DCS endpoints from YAML (kubernetes DCS, env-var config, or unreadable file)."
fi
hr

# ============================================================================
# 6. WATCHDOG (the last line of defense against split brain)
# ----------------------------------------------------------------------------
# Scenario the watchdog exists for: the patroni PROCESS freezes (not dies)
# while PostgreSQL keeps running as primary. The lease expires, another node
# promotes — but the frozen node's postgres still accepts writes: split
# brain. A kernel watchdog (/dev/watchdog) hard-resets the machine if
# patroni stops petting it. 'mode: required' refuses leadership without it;
# 'automatic' uses it if present; 'off' relies on luck.
# ============================================================================
echo
echo "${C_BOLD}6. Watchdog Configuration${C_RST}"
hr

WD_MODE=""
[ -n "$CFG" ] && WD_MODE=$(echo "$CFG" | grep -A4 -E '^\s*watchdog:' | grep -E '^\s*mode:' | head -1 | sed 's/.*mode:\s*//' | tr -d ' "'"'" || true)
echo "watchdog mode (file): ${WD_MODE:-<not configured => off>}"

# CONTAINER CAVEAT: /dev/watchdog is NOT visible inside a container unless
# explicitly passed with --device. The check below must therefore look inside
# the container in container mode; a host-side device is irrelevant to a
# containerized Patroni that cannot see it.
if [ $CONTAINER_MODE = 1 ]; then
    if cexec "test -e /dev/watchdog" ; then
        info "/dev/watchdog IS passed into the container — watchdog can function."
    else
        if [ "$WD_MODE" = "required" ]; then
            crit "watchdog mode 'required' but /dev/watchdog is NOT passed into container '$PATRONI_CONTAINER' — this member can NEVER become leader!"
            remed "Pass the device: add --device /dev/watchdog (docker run) or devices: [/dev/watchdog] (compose) and recreate the container; load softdog on the HOST first: sudo modprobe softdog"
        elif [ -n "$WD_MODE" ] && [ "$WD_MODE" != "off" ]; then
            warn "watchdog mode '$WD_MODE' but no /dev/watchdog inside the container — Patroni silently degrades (no fencing)."
            remed "Pass the device into the container (--device /dev/watchdog) or set mode: off explicitly to document the accepted risk."
        else
            info "No watchdog in container (mode=${WD_MODE:-off}) — common for containerized deployments; the orchestrator's health checks partially substitute."
        fi
    fi
    hr
    # Skip the host-side watchdog logic entirely in container mode:
    SKIP_HOST_WD=1
else
    SKIP_HOST_WD=0
fi
if [ "$SKIP_HOST_WD" = 0 ]; then :

if [ -e /dev/watchdog ]; then
    WD_PERM=$(stat -c '%U:%G %a' /dev/watchdog 2>/dev/null || true)
    echo "/dev/watchdog exists ($WD_PERM)"
    case "$WD_MODE" in
        required) ok "watchdog mode 'required' with device present — strongest fencing." ;;
        automatic) ok "watchdog 'automatic' with device present — will be used." ;;
        *) warn "Watchdog device EXISTS but Patroni does not use it (mode=${WD_MODE:-off}) — a frozen patroni process can cause split brain."
           remed "Enable: add to YAML -> watchdog: {mode: automatic, device: /dev/watchdog, safety_margin: 5}; ensure postgres user can write the device (udev rule or group), then: sudo systemctl restart patroni" ;;
    esac
    # Device must be writable by the patroni (postgres) user
    if [ -n "$WD_MODE" ] && [ "$WD_MODE" != "off" ]; then
        if ! $SUDO -u postgres test -w /dev/watchdog 2>/dev/null && ! sudo -n -u postgres test -w /dev/watchdog 2>/dev/null; then
            warn "Watchdog configured but /dev/watchdog may not be writable by postgres — Patroni logs 'watchdog device is not usable' and silently degrades."
            remed "Grant access via udev: echo 'KERNEL==\"watchdog\", OWNER=\"postgres\"' | sudo tee /etc/udev/rules.d/61-watchdog.rules; sudo udevadm trigger"
        fi
    fi
else
    if [ "$WD_MODE" = "required" ]; then
        crit "watchdog mode 'required' but /dev/watchdog is MISSING — this member REFUSES to become leader (it will never promote)!"
        remed "Load a watchdog module: sudo modprobe softdog && echo softdog | sudo tee /etc/modules-load.d/softdog.conf  (softdog is fine on VMs/EC2), or relax mode to 'automatic'."
    else
        info "No /dev/watchdog. On EC2/VMs: sudo modprobe softdog provides one. Optional but recommended for mode=automatic."
    fi
fi
fi  # end SKIP_HOST_WD guard
hr

# ============================================================================
# 7. LOG FORENSICS (journald patroni unit)
# ----------------------------------------------------------------------------
# The classic Patroni log signatures and what they REALLY mean:
#  "demoting self"                          -> lost/failed to refresh lease
#  "Lock owner: X; I am Y"                  -> normal follower heartbeat line
#  "does not have lock"                     -> normal on replicas; on a node
#                                              that SHOULD be leader => issue
#  "watchdog device is not usable"          -> silent fencing degradation
#  "waiting for standby leader"/"no action" -> standby cluster / paused
#  "Error communicating with DCS"           -> the root of most demotions
#  "CRITICAL: system ID mismatch"           -> node belongs to a DIFFERENT
#                                              cluster (restored wrong backup
#                                              /wrong PGDATA) — refuses to join
#  "pg_rewind" failures                     -> rejoin will need full reinit
# ============================================================================
echo
echo "${C_BOLD}7. Patroni Log Forensics (last 24h journal)${C_RST}"
hr

# Log source selection: container mode reads `docker logs` (Patroni logs to
# stdout/stderr in containers); host mode reads journald. Both feed the same
# signature scanner.
JLOG=""
if [ $CONTAINER_MODE = 1 ]; then
    JLOG=$($DOCKER logs --since 24h "$PATRONI_CONTAINER" 2>&1 | tail -2000 || true)
    [ -z "$JLOG" ] && info "No container logs in 24h window — widening: $DOCKER logs --tail 500 $PATRONI_CONTAINER"
    [ -z "$JLOG" ] && JLOG=$($DOCKER logs --tail 500 "$PATRONI_CONTAINER" 2>&1 || true)
elif have journalctl; then
    JLOG=$($SUDO journalctl -u patroni --since "-24h" --no-pager 2>/dev/null || journalctl -u patroni --since "-24h" --no-pager 2>/dev/null || true)
fi
if true; then
    if [ -n "$JLOG" ]; then
        scan_log() {
            local label="$1" pattern="$2" sev="$3"
            local hits cnt
            hits=$(echo "$JLOG" | grep -aiE "$pattern" | tail -5 || true)
            cnt=$(echo "$JLOG" | grep -aicE "$pattern" || true); cnt=${cnt:-0}
            if [ "$cnt" -gt 0 ]; then
                [ "$sev" = crit ] && crit "$label ($cnt in 24h):" || warn "$label ($cnt in 24h):"
                echo "$hits" | sed 's/^/    /'
                return 0
            fi; return 1
        }
        ANY=0
        scan_log "Self-demotions (lease loss)" "demot(ed|ing) self|releasing leader" crit && { ANY=1; remed "Demotions almost always trace to DCS latency/outage — correlate timestamps with etcd logs; verify live timing rule (section 4)."; }
        scan_log "DCS communication errors" "Error communicating with DCS|failed to update leader lock|RetryFailedError" crit && { ANY=1; remed "Stabilize DCS first: etcdctl endpoint health on all members; check network between node and DCS (section 5)."; }
        scan_log "System ID mismatch (WRONG CLUSTER data!)" "system ID mismatch|belongs to a different cluster" crit && { ANY=1;
            if [ $CONTAINER_MODE = 1 ]; then
                remed "PGDATA on this node is from another cluster (bad restore?). Do NOT force. Either restore correct data or fully reinit: $DOCKER exec -it $PATRONI_CONTAINER patronictl reinit ${SCOPE:-<cluster>} <member>."
            else
                remed "PGDATA on this node is from another cluster (bad restore?). Do NOT force. Either restore correct data or fully reinit: patronictl reinit <cluster> <member>."
            fi
        }
        scan_log "pg_rewind failures" "pg_rewind.*(fail|error)|rewind failed" warn && { ANY=1;
            if [ $CONTAINER_MODE = 1 ]; then
                remed "Rewind failed -> node needs full re-clone: $DOCKER exec -it $PATRONI_CONTAINER patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} reinit ${SCOPE:-<cluster>} <member> (destructive for that member)."
            else
                remed "Rewind failed -> node needs full re-clone: patronictl -c <cfg> reinit ${SCOPE:-<cluster>} <member> (destructive for that member)."
            fi
        }
        scan_log "Watchdog problems" "watchdog.*(not usable|error|fail)" warn && ANY=1
        scan_log "Leader elections/promotions" "promoted self to leader|acquired session lock|cleared rewind state" warn && { ANY=1; info "Promotions in the last 24h — reconstruct the failover timeline for your report (who, when, why)."; }
        scan_log "Repeated PostgreSQL start failures" "postmaster.*(failed to start|not running)|failed to start postgres" crit && ANY=1
        [ $ANY = 0 ] && ok "No pathological Patroni log signatures in the last 24h."
    else
        if [ $CONTAINER_MODE = 1 ]; then
            info "No container logs readable — check runtime logging driver: $DOCKER inspect -f '{{.HostConfig.LogConfig.Type}}' $PATRONI_CONTAINER (json-file/journald readable; awslogs/none are not, read at the destination instead)."
        else
            info "No patroni journal entries readable (journalctl missing, unit logs elsewhere, or need sudo) — check the log: section in the YAML or supervisor logs."
        fi
    fi
fi
hr

# ============================================================================
# 8. SPECIAL TOPOLOGIES & FINAL CROSS-CHECKS
# ----------------------------------------------------------------------------
# - standby_cluster: an entire Patroni cluster replicating from a REMOTE
#   primary (DR site). Its "leader" is a *standby leader* — read-only!
#   People page at 3am about "primary not accepting writes" when it is a
#   standby cluster working exactly as designed. Detect and label it.
# - DCS failsafe_mode (Patroni 3.0+): lets an isolated leader KEEP running
#   if all members confirm reachability over REST — trades split-brain
#   safety margin for availability during full DCS outages. Flag if on.
# ============================================================================
echo
echo "${C_BOLD}8. Special Topologies & Cross-Checks${C_RST}"
hr

if [ -n "$DCS_CFG" ] && echo "$DCS_CFG" | grep -q '"standby_cluster"'; then
    SC_HOST=$(echo "$DCS_CFG" | grep -oE '"host":\s*"[^"]*"' | head -1 | cut -d'"' -f4)
    warn "This is a STANDBY CLUSTER replicating from remote primary '${SC_HOST:-?}' — its leader is READ-ONLY by design. Writes belong on the source cluster!"
    if [ $CONTAINER_MODE = 1 ]; then
        remed "To PROMOTE this DR site to a real primary (site failover — irreversible without re-setup): $DOCKER exec -it $PATRONI_CONTAINER patronictl -c ${PATRONI_CFG:-/etc/patroni/patroni.yml} edit-config and REMOVE the standby_cluster section."
    else
        remed "To PROMOTE this DR site to a real primary (site failover — irreversible without re-setup): patronictl -c <cfg> edit-config and REMOVE the standby_cluster section."
    fi
fi
if [ -n "$DCS_CFG" ] && echo "$DCS_CFG" | grep -qE '"failsafe_mode":\s*true'; then
    info "DCS failsafe_mode is ON: leader survives total DCS outage if all members ACK via REST. Ensure member-to-member 8008 connectivity is guaranteed, or this is worse than fencing."
fi

# nofailover across the cluster: if EVERY member has it, no failover can
# ever occur — a cluster-shaped standalone.
if [ -n "$CLUSTER_JSON" ]; then
    M_TOTAL=$(echo "$CLUSTER_JSON" | grep -oE '"name":' | wc -l)
    NOFO=$(echo "$CLUSTER_JSON" | grep -oE '"nofailover":\s*true' | wc -l)
    if [ "$M_TOTAL" -gt 0 ] && [ "$NOFO" -ge $((M_TOTAL - 1)) ] && [ "$NOFO" -gt 0 ]; then
        crit "nofailover=true on $NOFO of $M_TOTAL members — automatic failover is effectively IMPOSSIBLE in this cluster."
        remed "Clear the tag on at least one healthy replica (YAML tags: section, then reload patroni) so a promotion candidate exists."
    fi
fi

# Single-member "cluster": all the Patroni overhead, none of the HA.
if [ -n "$CLUSTER_JSON" ]; then
    M_TOTAL=${M_TOTAL:-$(echo "$CLUSTER_JSON" | grep -oE '"name":' | wc -l)}
    [ "$M_TOTAL" = "1" ] && warn "Cluster has only ONE member — no failover target exists. Add a replica or document the risk." && \
        remed "Add a replica: install patroni+postgres on a second node with same scope + DCS, start patroni — it self-clones via basebackup/pgBackRest per config."
fi
hr

# ============================================================================
# 9. SUMMARY & VERDICT
# ============================================================================
echo
echo "${C_BOLD}9. Patroni Deep Triage Summary${C_RST}"
hr
if [ ${#ISSUES[@]} -eq 0 ]; then
    echo "${C_GRN}No Patroni anomalies flagged — supervisor, DCS, and cluster state look sound.${C_RST}"
else
    printf "%sFLAGGED ISSUES (%d):%s\n" "$C_RED" "${#ISSUES[@]}" "$C_RST"
    i=1
    for issue in "${ISSUES[@]}"; do printf "  %2d. %s\n" "$i" "$issue"; i=$((i+1)); done
fi
if [ ${#REMEDS[@]} -gt 0 ]; then
    printf "\n%sRECOMMENDATIONS & REMEDIATION COMMANDS:%s\n" "$C_YEL" "$C_RST"
    for r in "${REMEDS[@]}"; do printf "  - %s\n" "$r"; done
fi
hr
echo
