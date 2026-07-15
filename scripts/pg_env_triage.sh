#!/usr/bin/env bash
# ============================================================================
# SCRIPT: pg_env_triage.sh
# DESCRIPTION:
#   Rapid environment identification and system-wide health triage script.
#   Designed to auto-discover deployment architectures (native VMs, Docker containers,
#   or Kubernetes pods) and audit host-level, kernel, and database parameters.
#
# PARAMETERS CHECKED:
#   - System details: OS family, CPU cores, memory limits, load average, EC2 metadata.
#   - Processes & Ports: Running services (postgres, patroni, etcd, haproxy, pgbouncer, etc.)
#     and their respective listening ports.
#   - Kubernetes: PG operators (Percona, Crunchy, CNPG, Zalando), pod states, PVC status, OOM restarts.
#   - Docker: Running containers, Patroni leader identity, container health REST APIs.
#   - Patroni & DCS: patronictl status, etcd cluster health, raft alarms, Consul states.
#   - Load Balancer: HAProxy config checks, keepalived VIP status, stats socket metrics.
#   - PostgreSQL database: Recovery state, active connections, replication lag, inactive slots,
#     archiver health, XID wraparound age, vacuum backlog, GUC memory configurations.
#   - Linux Host: Disk and inode capacities, vm.overcommit_memory, vm.swappiness, vm.dirty_ratio,
#     THP (Transparent Huge Pages) state, dmesg OOM messages, CPU steal, systemd failures.
#
# RECOMMENDATIONS & RATIONALE:
#   - If K8s pods are not Ready / PVCs not Bound: Warns/crits to prevent database outages.
#   - If etcd alarms are active (e.g. NOSPACE): Recommends compaction. Rationale: DCS writes are blocked,
#     causing Patroni to lose its leader lock and demote the primary node.
#   - If HAProxy uses /master check: Recommends upgrading health-check path to /primary. Rationale:
#     The /master endpoint was deprecated and is removed in Patroni 4.x.
#   - If inactive replication slots > 1GB exist: Recommends dropping the slots. Rationale:
#     Inactive slots pin WAL segments, causing pg_wal to grow indefinitely until disk space is exhausted.
#   - If datfrozenxid age > 1B: Recommends urgent VACUUM FREEZE to avoid transaction ID wraparound shutdown.
#   - If vm.overcommit_memory = 0: Recommends setting to 2 (with overcommit_ratio). Rationale:
#     Protects the main postmaster process from being killed by the Linux kernel OOM killer.
#   - If Transparent Huge Pages (THP) is enabled: Recommends disabling. Rationale: THP allocation
#     and defragmentation cause severe latency spikes and performance degradation in PostgreSQL.
#
# USAGE:
#   ./pg_env_triage.sh
#   ./pg_env_triage.sh | tee triage_report.log
# ============================================================================
set -o pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'
    C_BLU=$'\033[1;36m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_OFF=""
fi

ISSUES=()
NOTES=()

# Docker detection variables
IS_DOCKER=0
DOCKER_PATRONI_CONTS=""
DOCKER_PATRONI_LEADER=""
DOCKER_ETCD_CONTS=""
DOCKER_HAPROXY_CONTS=""


hdr()  { printf '\n%s================ %s ================%s\n' "$C_BLU" "$1" "$C_OFF"; }
ok()   { printf '%s[ OK ]%s %s\n'   "$C_GRN" "$C_OFF" "$1"; }
warn() { printf '%s[WARN]%s %s\n'   "$C_YEL" "$C_OFF" "$1"; ISSUES+=("WARN: $1"); }
crit() { printf '%s[CRIT]%s %s\n'   "$C_RED" "$C_OFF" "$1"; ISSUES+=("CRIT: $1"); }
info() { printf '[info] %s\n' "$1"; }
note() { NOTES+=("$1"); }

have() { command -v "$1" >/dev/null 2>&1; }

# sudo wrapper: use sudo -n if available and permitted, otherwise run plain
if have sudo && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
    HAVE_SUDO=1
else
    SUDO=""
    HAVE_SUDO=0
fi

CURL="curl -s -m 3"

# psql access: try inside docker leader first, then as current user, then via sudo -u postgres
PSQL=""
psql_probe() {
    if [ "$IS_DOCKER" = 1 ] && [ -n "$DOCKER_PATRONI_LEADER" ]; then
        if docker exec -u postgres "$DOCKER_PATRONI_LEADER" psql -XtAc "SELECT 1" >/dev/null 2>&1; then
            PSQL="docker exec -u postgres $DOCKER_PATRONI_LEADER psql -X"
        fi
    elif have psql && psql -XtAc "SELECT 1" >/dev/null 2>&1; then
        PSQL="psql -X"
    elif [ "$HAVE_SUDO" = 1 ] && $SUDO -u postgres psql -XtAc "SELECT 1" >/dev/null 2>&1; then
        PSQL="$SUDO -u postgres psql -X"
    fi
}
pq() { # pq "SQL" -> tuples-only output, or empty on failure
    [ -n "$PSQL" ] && $PSQL -tAc "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 0. Basic system identity
# ---------------------------------------------------------------------------
hdr "SYSTEM IDENTITY"
info "host: $(hostname -f 2>/dev/null || hostname)   user: $(id -un) (uid $(id -u))   sudo: $([ "$HAVE_SUDO" = 1 ] && echo yes || echo NO)"

OS_FAMILY="unknown"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    info "os: ${PRETTY_NAME:-$NAME}   kernel: $(uname -r)"
    case " ${ID:-} ${ID_LIKE:-} " in
        *debian*|*ubuntu*) OS_FAMILY="debian" ;;
        *rhel*|*fedora*|*centos*|*rocky*|*alma*) OS_FAMILY="rhel" ;;
    esac
fi
info "os family: $OS_FAMILY"
info "cpu: $(nproc 2>/dev/null) cores   mem: $(free -h 2>/dev/null | awk '/^Mem:/{print $2" total, "$7" available"}')"
info "uptime/load:$(uptime | sed 's/.*load average/ load average/')"

# EC2 metadata (IMDSv2 then IMDSv1 fallback)
TOKEN=$($CURL -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
if [ -n "$TOKEN" ] && [ "${#TOKEN}" -lt 200 ] && ! echo "$TOKEN" | grep -q ' '; then
    ITYPE=$($CURL -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)
    AZ=$($CURL -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null)
    # sanity: instance types look like m5.large / t3a.xlarge — no spaces
    if echo "$ITYPE" | grep -Eq '^[a-z0-9]+\.[a-z0-9]+$'; then
        info "EC2 instance: $ITYPE in ${AZ:-?}"
    fi
fi

# ---------------------------------------------------------------------------
# 1. Process / port fingerprint
# ---------------------------------------------------------------------------
hdr "PROCESS & PORT FINGERPRINT"

PS_OUT=$(ps -eo pid,user,comm,args 2>/dev/null)

has_proc() { echo "$PS_OUT" | grep -Ei "$1" | grep -vq grep && echo 1 || echo 0; }

P_POSTGRES=$(has_proc '[p]ostgres|[p]ostmaster')
P_PATRONI=$(has_proc  '[p]atroni')
P_ETCD=$(has_proc     '[e]tcd( |$)')
P_CONSUL=$(has_proc   '[c]onsul')
P_ZK=$(has_proc       '[z]ookeeper|QuorumPeerMain')
P_HAPROXY=$(has_proc  '[h]aproxy')
P_KEEPAL=$(has_proc   '[k]eepalived')
P_PGB=$(has_proc      '[p]gbouncer')
P_KUBELET=$(has_proc  '[k]ubelet')
P_K3S=$(has_proc      '[k]3s')
P_CONTAINERD=$(has_proc '[c]ontainerd')
P_DOCKERD=$(has_proc  '[d]ockerd')
P_CRIO=$(has_proc     '[c]rio')

for pair in "postgres:$P_POSTGRES" "patroni:$P_PATRONI" "etcd:$P_ETCD" "consul:$P_CONSUL" \
            "zookeeper:$P_ZK" "haproxy:$P_HAPROXY" "keepalived:$P_KEEPAL" "pgbouncer:$P_PGB" \
            "kubelet:$P_KUBELET" "k3s:$P_K3S" "containerd:$P_CONTAINERD" "dockerd:$P_DOCKERD" "crio:$P_CRIO"; do
    name=${pair%%:*}; val=${pair##*:}
    [ "$val" = 1 ] && info "process present: $name"
done

# listening ports
if have ss; then LSN=$($SUDO ss -tlnp 2>/dev/null || ss -tln 2>/dev/null)
elif have netstat; then LSN=$($SUDO netstat -tlnp 2>/dev/null || netstat -tln 2>/dev/null)
else LSN=""; fi

port_open() { echo "$LSN" | grep -Eq "[:.]$1[[:space:]]" && echo 1 || echo 0; }

PT_5432=$(port_open 5432);  PT_6432=$(port_open 6432)
PT_8008=$(port_open 8008);  PT_2379=$(port_open 2379); PT_2380=$(port_open 2380)
PT_8500=$(port_open 8500);  PT_5000=$(port_open 5000); PT_5001=$(port_open 5001)
PT_7000=$(port_open 7000);  PT_6443=$(port_open 6443); PT_10250=$(port_open 10250)

printf '[info] ports: '
for pp in "5432:PG:$PT_5432" "6432:PgBouncer:$PT_6432" "8008:PatroniAPI:$PT_8008" \
          "2379:etcd-client:$PT_2379" "2380:etcd-peer:$PT_2380" "8500:Consul:$PT_8500" \
          "5000:HAProxy-rw:$PT_5000" "5001:HAProxy-ro:$PT_5001" "7000:HAProxy-stats:$PT_7000" \
          "6443:kube-apiserver:$PT_6443" "10250:kubelet:$PT_10250"; do
    p=${pp%%:*}; rest=${pp#*:}; label=${rest%%:*}; v=${rest##*:}
    [ "$v" = 1 ] && printf '%s(%s) ' "$p" "$label"
done
printf '\n'

# ---------------------------------------------------------------------------
# 2. Kubernetes detection
# ---------------------------------------------------------------------------
hdr "KUBERNETES DETECTION"

K8S=0; K8S_ROLE="none"; K8S_FLAVOR=""
KUBECTL=""

# find a usable kubectl + kubeconfig
if have kubectl; then KUBECTL="kubectl"; fi
if [ -z "$KUBECTL" ] && have k3s; then KUBECTL="k3s kubectl"; fi
for kc in "$HOME/.kube/config" /etc/kubernetes/admin.conf /etc/rancher/k3s/k3s.yaml; do
    if [ -n "$KUBECTL" ] && [ -r "$kc" ] && ! $KUBECTL get nodes >/dev/null 2>&1; then
        export KUBECONFIG="$kc"
    fi
done
# last resort: sudo for admin.conf / k3s.yaml
if [ -n "$KUBECTL" ] && ! $KUBECTL get nodes >/dev/null 2>&1 && [ "$HAVE_SUDO" = 1 ]; then
    for kc in /etc/kubernetes/admin.conf /etc/rancher/k3s/k3s.yaml; do
        [ -e "$kc" ] && $SUDO test -r "$kc" && KUBECTL="$SUDO KUBECONFIG=$kc kubectl" && break
    done
fi

[ -d /etc/kubernetes ]           && { K8S=1; info "/etc/kubernetes present"; }
[ -d /etc/kubernetes/manifests ] && { K8S_FLAVOR="kubeadm"; K8S_ROLE="control-plane"; }
[ -e /etc/rancher/k3s/k3s.yaml ] && { K8S=1; K8S_FLAVOR="k3s"; }
[ "$P_KUBELET" = 1 ] || [ "$P_K3S" = 1 ] && K8S=1
[ "$PT_6443" = 1 ] && K8S_ROLE="control-plane"
[ "$K8S" = 1 ] && [ "$K8S_ROLE" = "none" ] && [ "$PT_10250" = 1 ] && K8S_ROLE="worker"

PG_OPERATOR="none"
if [ "$K8S" = 1 ]; then
    info "Kubernetes detected: flavor=${K8S_FLAVOR:-unknown} role=$K8S_ROLE"
    if [ -n "$KUBECTL" ] && $KUBECTL get nodes >/dev/null 2>&1; then
        ok "kubectl works ($($KUBECTL get nodes --no-headers 2>/dev/null | wc -l) nodes)"
        $KUBECTL get nodes -o wide 2>/dev/null | head -10

        NOTREADY=$($KUBECTL get nodes --no-headers 2>/dev/null | grep -cv ' Ready')
        [ "$NOTREADY" -gt 0 ] && crit "$NOTREADY node(s) NOT Ready — check kubectl describe node"

        CRDS=$($KUBECTL get crd 2>/dev/null)
        echo "$CRDS" | grep -q 'perconapgclusters.pgv2.percona.com' && PG_OPERATOR="percona-pg-v2"
        [ "$PG_OPERATOR" = none ] && echo "$CRDS" | grep -q 'postgresclusters.postgres-operator.crunchydata.com' && PG_OPERATOR="crunchy-pgo"
        [ "$PG_OPERATOR" = none ] && echo "$CRDS" | grep -q 'clusters.postgresql.cnpg.io' && PG_OPERATOR="cloudnativepg"
        [ "$PG_OPERATOR" = none ] && echo "$CRDS" | grep -q 'postgresqls.acid.zalan.do' && PG_OPERATOR="zalando"
        [ "$PG_OPERATOR" = none ] && echo "$CRDS" | grep -q 'sgclusters.stackgres.io' && PG_OPERATOR="stackgres"
        # Percona v2 is a Crunchy fork: both CRD sets present => Percona
        echo "$CRDS" | grep -q 'pgv2.percona.com' && PG_OPERATOR="percona-pg-v2"
        info "PostgreSQL operator detected: $PG_OPERATOR"

        info "postgres-related pods:"
        $KUBECTL get pods -A -o wide 2>/dev/null | grep -Ei 'pg|postgre|patroni|cnpg' | head -20

        BADPODS=$($KUBECTL get pods -A --no-headers 2>/dev/null | grep -Ei 'pg|postgre|patroni|cnpg' \
                  | awk '$4!="Running" && $4!="Completed"{print $1"/"$2" ("$4")"}')
        [ -n "$BADPODS" ] && crit "unhealthy PG-related pod(s): $(echo "$BADPODS" | tr '\n' ' ')"

        # OOMKilled / restarts on PG pods
        while read -r ns pod; do
            [ -z "$pod" ] && continue
            R=$($KUBECTL get pod -n "$ns" "$pod" -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null | tr ' ' '\n' | sort -rn | head -1)
            LR=$($KUBECTL get pod -n "$ns" "$pod" -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}' 2>/dev/null)
            [ -n "$R" ] && [ "$R" -gt 0 ] && warn "pod $ns/$pod has $R restart(s)${LR:+, last termination: $LR}"
            echo "$LR" | grep -q OOMKilled && crit "pod $ns/$pod was OOMKilled — check memory limits vs shared_buffers"
        done < <($KUBECTL get pods -A --no-headers 2>/dev/null | grep -Ei 'pg|postgre|patroni|cnpg' | awk '{print $1" "$2}')

        # PVC status
        PVC_BAD=$($KUBECTL get pvc -A --no-headers 2>/dev/null | grep -Ei 'pg|postgre' | awk '$3!="Bound"{print $1"/"$2" ("$3")"}')
        [ -n "$PVC_BAD" ] && crit "PVC not Bound: $(echo "$PVC_BAD" | tr '\n' ' ')"

        note "K8s: inspect cluster with 'kubectl get pg -A' (Percona), 'kubectl cnpg status' (CNPG), or exec patronictl in a database pod"
    else
        warn "Kubernetes artifacts present but kubectl not usable from here (worker node or missing kubeconfig) — try crictl/ctr to inspect containers"
        if have crictl; then $SUDO crictl ps 2>/dev/null | grep -Ei 'postgre|patroni' | head; fi
    fi
else
    info "no Kubernetes detected on this host"
fi


# ---------------------------------------------------------------------------
# 2.5. Docker detection
# ---------------------------------------------------------------------------
hdr "DOCKER DETECTION"

if have docker && docker ps >/dev/null 2>&1; then
    RUNNING_CONTS=$(docker ps --format "{{.Names}}" --filter "status=running" 2>/dev/null)
    if [ -n "$RUNNING_CONTS" ]; then
        IS_DOCKER=1
        info "Docker running containers detected:"
        docker ps --format "  - {{.Names}} (image: {{.Image}}, status: {{.Status}})" --filter "status=running" 2>/dev/null
        
        DOCKER_PATRONI_CONTS=$(echo "$RUNNING_CONTS" | grep -Ei 'patroni' | grep -vE 'client|haproxy|etcd')
        DOCKER_ETCD_CONTS=$(echo "$RUNNING_CONTS" | grep -Ei 'etcd')
        DOCKER_HAPROXY_CONTS=$(echo "$RUNNING_CONTS" | grep -Ei 'haproxy')
        
        for c in $DOCKER_PATRONI_CONTS; do
            api_resp=$(docker exec "$c" curl -s http://localhost:8008/patroni 2>/dev/null)
            if [ -n "$api_resp" ]; then
                role=$(echo "$api_resp" | grep -o '"role"[^,]*' | head -1 | cut -d'"' -f4)
                if [ "$role" = "master" ] || [ "$role" = "primary" ] || [ "$role" = "leader" ]; then
                    DOCKER_PATRONI_LEADER="$c"
                fi
            fi
        done
        
        if [ -n "$DOCKER_PATRONI_LEADER" ]; then
            ok "Patroni leader container identified: $DOCKER_PATRONI_LEADER"
        elif [ -n "$DOCKER_PATRONI_CONTS" ]; then
            warn "Patroni containers running but no leader found via REST API"
        fi
    else
        info "no running Docker containers detected"
    fi
else
    info "Docker daemon not running or not accessible"
fi

# ---------------------------------------------------------------------------
# 3. Patroni checks
# ---------------------------------------------------------------------------
hdr "PATRONI CHECKS"

if [ "$IS_DOCKER" = 1 ] && [ -n "$DOCKER_PATRONI_CONTS" ]; then
    info "Patroni indicators found (running in Docker)"
    
    # Check REST API for each database container
    for c in $DOCKER_PATRONI_CONTS; do
        API=$(docker exec "$c" curl -s http://localhost:8008/patroni 2>/dev/null)
        if [ -n "$API" ]; then
            ROLE=$(echo "$API" | grep -o '"role"[^,]*'  | head -1 | cut -d'"' -f4)
            STATE=$(echo "$API" | grep -o '"state"[^,}]*' | head -1 | cut -d'"' -f4)
            TL=$(echo "$API" | grep -o '"timeline"[^,}]*' | head -1 | grep -o '[0-9]*')
            info "container $c via REST API: role=$ROLE state=$STATE timeline=$TL"
            docker exec "$c" curl -s http://localhost:8008/cluster 2>/dev/null | grep -q '"pause":true' && warn "cluster is in PAUSE (maintenance) mode — automatic failover disabled"
        else
            warn "Patroni REST API on container $c :8008 not answering"
        fi
    done
    
    # patronictl summary
    PROBE_CONT="${DOCKER_PATRONI_LEADER:-$(echo "$DOCKER_PATRONI_CONTS" | head -n 1)}"
    if [ -n "$PROBE_CONT" ]; then
        PL=$(docker exec "$PROBE_CONT" patronictl -c /etc/patroni/patroni.yml list 2>/dev/null)
        if [ -n "$PL" ]; then
            echo "$PL"
            echo "$PL" | grep -Eq 'Leader.*running' || crit "NO running Leader in patronictl list — cluster may be read-only"
            echo "$PL" | grep -Eiq 'stopped|start failed|crashed|creating replica' && warn "member(s) in abnormal state in patronictl list"
            echo "$PL" | grep -q '\*' && warn "pending_restart flag (*) on member(s) — postmaster-context change awaits patronictl restart"
            TLS=$(echo "$PL" | awk -F'|' 'NR>3 {print $6}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Ev '^$|^TL$' | sort -u | wc -l)
            [ "$TLS" -gt 1 ] && warn "members on DIFFERENT timelines — possible divergence"
            echo "$PL" | grep -Eo '\|[[:space:]]*[0-9]{3,}[[:space:]]*\|[[:space:]]*$' >/dev/null 2>&1 && warn "replication lag >=100MB on some member"
        else
            warn "patronictl list failed inside container $PROBE_CONT"
        fi
    fi
    
    # DCS demotion signature in logs
    for c in $DOCKER_PATRONI_CONTS; do
        if docker logs "$c" --tail 300 2>/dev/null | grep -qi 'failed to update leader lock'; then
            crit "Patroni container $c log shows 'failed to update leader lock' — DCS (etcd) problem, primary demotes to read-only"
        fi
    done
    
    note "Docker: inspect cluster with 'docker exec -it $PROBE_CONT patronictl -c /etc/patroni/patroni.yml list'"
else
    PATRONI_YML=""
    for f in /etc/patroni/patroni.yml /etc/patroni/*.yml /etc/patroni/*.yaml /etc/patroni.yml /opt/patroni/patroni.yml; do
        [ -r "$f" ] && PATRONI_YML="$f" && break
    done

    if [ "$P_PATRONI" = 1 ] || [ "$PT_8008" = 1 ] || [ -n "$PATRONI_YML" ]; then
        info "Patroni indicators found (process=$P_PATRONI port8008=$PT_8008 config=${PATRONI_YML:-not-found})"

        if [ "$P_PATRONI" = 0 ] && [ -n "$PATRONI_YML" ]; then
            crit "Patroni config exists but the patroni process is NOT running — check 'systemctl status patroni' / journalctl -u patroni"
        fi

        # REST API
        API=$($CURL http://localhost:8008/patroni 2>/dev/null)
        if [ -n "$API" ]; then
            ROLE=$(echo "$API" | grep -o '"role"[^,]*'  | head -1 | cut -d'"' -f4)
            STATE=$(echo "$API" | grep -o '"state"[^,}]*' | head -1 | cut -d'"' -f4)
            TL=$(echo "$API" | grep -o '"timeline"[^,}]*' | head -1 | grep -o '[0-9]*')
            info "this node via REST API: role=$ROLE state=$STATE timeline=$TL"
            PAUSED=$(echo "$API" | grep -c '"pause"')
            $CURL http://localhost:8008/cluster 2>/dev/null | grep -q '"pause":true' && warn "cluster is in PAUSE (maintenance) mode — automatic failover disabled"
        else
            warn "Patroni REST API on :8008 not answering"
        fi

        # patronictl summary
        if have patronictl && [ -n "$PATRONI_YML" ]; then
            PL=$(patronictl -c "$PATRONI_YML" list 2>/dev/null)
            if [ -n "$PL" ]; then
                echo "$PL"
                echo "$PL" | grep -Eq 'Leader.*running' || crit "NO running Leader in patronictl list — cluster may be read-only (check DCS health below)"
                echo "$PL" | grep -Eiq 'stopped|start failed|crashed|creating replica' && warn "member(s) in abnormal state in patronictl list"
                echo "$PL" | grep -q '\*' && warn "pending_restart flag (*) on member(s) — postmaster-context change awaits 'patronictl restart'"
                TLS=$(echo "$PL" | awk -F'|' 'NR>3 {print $6}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Ev '^$|^TL$' | sort -u | wc -l)
                [ "$TLS" -gt 1 ] && warn "members on DIFFERENT timelines — possible divergence, may need pg_rewind/reinit"
                # crude lag flag: any lag column value >= 100 (MB)
                echo "$PL" | grep -Eo '\|[[:space:]]*[0-9]{3,}[[:space:]]*\|[[:space:]]*$' >/dev/null 2>&1 && warn "replication lag >=100MB on some member (verify with pg_stat_replication)"
            else
                warn "patronictl list failed with config $PATRONI_YML"
            fi
        fi

        # DCS demotion signature in logs
        if have journalctl; then
            $SUDO journalctl -u patroni --no-pager -n 300 2>/dev/null | grep -qi 'failed to update leader lock' \
                && crit "Patroni log shows 'failed to update leader lock' — DCS (etcd) problem, primary demotes to read-only"
        fi
    else
        info "no Patroni on this host"
    fi
fi

# ---------------------------------------------------------------------------
# 4. DCS: etcd / consul
# ---------------------------------------------------------------------------
hdr "DCS (etcd/consul) CHECKS"

if [ "$IS_DOCKER" = 1 ] && [ -n "$DOCKER_ETCD_CONTS" ]; then
    ETCD_CONT=$(echo "$DOCKER_ETCD_CONTS" | head -n 1)
    info "etcd present in Docker container: $ETCD_CONT"
    EH=$(docker exec "$ETCD_CONT" etcdctl endpoint health 2>&1)
    echo "$EH"
    echo "$EH" | grep -q 'is unhealthy' && crit "etcd endpoint(s) UNHEALTHY — quorum at risk; if quorum lost, Patroni demotes all primaries"
    ES=$(docker exec "$ETCD_CONT" etcdctl endpoint status -w table 2>/dev/null)
    [ -n "$ES" ] && echo "$ES"
    AL=$(docker exec "$ETCD_CONT" etcdctl alarm list 2>/dev/null)
    [ -n "$AL" ] && crit "etcd ALARM active: $AL (NOSPACE blocks all writes — compact/defrag/disarm needed)"
    MISSING_LEADER=$(echo "$ES" | grep -c 'true')
    [ -n "$ES" ] && [ "$MISSING_LEADER" -eq 0 ] && crit "no etcd Raft leader visible"
else
    if [ "$P_ETCD" = 1 ] || [ "$PT_2379" = 1 ]; then
        info "etcd present"
        if have etcdctl; then
            export ETCDCTL_API=3
            EH=$(etcdctl endpoint health --cluster 2>&1 || etcdctl endpoint health 2>&1)
            echo "$EH"
            echo "$EH" | grep -q 'is unhealthy' && crit "etcd endpoint(s) UNHEALTHY — quorum at risk; if quorum lost, Patroni demotes all primaries"
            ES=$(etcdctl endpoint status --cluster -w table 2>/dev/null || etcdctl endpoint status -w table 2>/dev/null)
            [ -n "$ES" ] && echo "$ES"
            AL=$(etcdctl alarm list 2>/dev/null)
            [ -n "$AL" ] && crit "etcd ALARM active: $AL (NOSPACE blocks all writes — compact/defrag/disarm needed)"
            MISSING_LEADER=$(echo "$ES" | grep -c 'true')
            [ -n "$ES" ] && [ "$MISSING_LEADER" -eq 0 ] && crit "no etcd Raft leader visible"
        else
            warn "etcd running but etcdctl not in PATH (TLS cluster may also need --cacert/--cert/--key)"
        fi
    elif [ "$P_CONSUL" = 1 ] || [ "$PT_8500" = 1 ]; then
        info "Consul present as DCS"
        have consul && consul members 2>/dev/null | head
    else
        info "no local DCS process (DCS may be remote, or Kubernetes API is the DCS)"
    fi
fi

# ---------------------------------------------------------------------------
# 5. HAProxy / keepalived / pgbouncer
# ---------------------------------------------------------------------------
hdr "LOAD BALANCING LAYER"

if [ "$IS_DOCKER" = 1 ] && [ -n "$DOCKER_HAPROXY_CONTS" ]; then
    HAP_CONT=$(echo "$DOCKER_HAPROXY_CONTS" | head -n 1)
    info "HAProxy running in Docker container: $HAP_CONT"
    docker exec "$HAP_CONT" grep -E 'listen|bind|server|httpchk|http-check' /usr/local/etc/haproxy/haproxy.cfg 2>/dev/null | sed 's/^/    /' | head -30
    docker exec "$HAP_CONT" grep -q '/master' /usr/local/etc/haproxy/haproxy.cfg 2>/dev/null \
        && warn "HAProxy health-check uses /master — removed in Patroni 4.x, must be /primary"
else
    if [ "$P_HAPROXY" = 1 ]; then
        info "HAProxy running; config:"
        grep -E 'listen|bind|server|httpchk|http-check' /etc/haproxy/haproxy.cfg 2>/dev/null | sed 's/^/    /' | head -30
        grep -q '/master' /etc/haproxy/haproxy.cfg 2>/dev/null \
            && warn "HAProxy health-check uses /master — removed in Patroni 4.x, must be /primary"
        # runtime state via admin socket
        SOCK=$(grep -Eo 'stats socket [^ ]+' /etc/haproxy/haproxy.cfg 2>/dev/null | awk '{print $3}' | head -1)
        if [ -n "$SOCK" ] && have socat; then
            STAT=$(echo "show stat" | $SUDO socat stdio "$SOCK" 2>/dev/null | awk -F, 'NR>1 && $2!="FRONTEND" && $2!="BACKEND" {print $1"/"$2" "$18}')
            echo "$STAT" | sed 's/^/    /'
            echo "$STAT" | grep -q ' DOWN' && info "note: backends DOWN for the opposite role are EXPECTED in the Patroni pattern; verify the right node is UP in each pool"
        fi
    fi
    [ "$P_KEEPAL" = 1 ] && { info "keepalived running — VIP location:"; ip -brief addr 2>/dev/null | grep -v 'lo ' | sed 's/^/    /'; }
    [ "$P_PGB" = 1 ] && info "pgbouncer running on :6432"
    [ "$P_HAPROXY" = 0 ] && [ "$P_KEEPAL" = 0 ] && [ "$P_PGB" = 0 ] && info "no local LB layer"
fi

# ---------------------------------------------------------------------------
# 6. PostgreSQL checks (native)
# ---------------------------------------------------------------------------
hdr "POSTGRESQL CHECKS"

psql_probe
if [ "$P_POSTGRES" = 1 ] && [ -z "$PSQL" ]; then
    if [ "$IS_DOCKER" = 1 ]; then
        warn "PostgreSQL running in container but psql access failed"
    else
        warn "postgres process running but psql access failed (try: sudo -u postgres psql; or PG runs in a container)"
    fi
fi
if [ "$P_POSTGRES" = 0 ] && [ "$K8S" = 0 ] && [ "$IS_DOCKER" = 0 ]; then
    if [ "$P_PATRONI" = 1 ]; then
        crit "Patroni running but NO postgres process — PostgreSQL failed to start; check patroni/postgres logs"
    else
        warn "no postgres process on this host (DB may be on another node)"
    fi
fi

if [ -n "$PSQL" ]; then
    V=$(pq "SELECT version()"); info "version: ${V%% on *}"
    info "data_directory: $(pq 'SHOW data_directory')"
    RECOVERY=$(pq "SELECT pg_is_in_recovery()")
    info "role by pg_is_in_recovery: $([ "$RECOVERY" = t ] && echo 'REPLICA (or read-only!)' || echo PRIMARY)"
    info "uptime: $(pq "SELECT now()-pg_postmaster_start_time()")"

    # connections
    MAXC=$(pq "SHOW max_connections"); CURC=$(pq "SELECT count(*) FROM pg_stat_activity")
    info "connections: $CURC / $MAXC"
    [ -n "$MAXC" ] && [ "$CURC" -gt $((MAXC*8/10)) ] && warn "connection usage above 80% of max_connections"

    # idle in transaction
    IIT=$(pq "SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction' AND now()-state_change > interval '5 min'")
    [ -n "$IIT" ] && [ "$IIT" -gt 0 ] && warn "$IIT session(s) idle in transaction >5min — blocks vacuum and locks"

    # long running queries
    LRQ=$(pq "SELECT count(*) FROM pg_stat_activity WHERE state='active' AND now()-query_start > interval '10 min'")
    [ -n "$LRQ" ] && [ "$LRQ" -gt 0 ] && warn "$LRQ query(ies) running >10min"

    if [ "$RECOVERY" = f ]; then
        # replication from primary side
        NREP=$(pq "SELECT count(*) FROM pg_stat_replication")
        info "streaming replicas connected: ${NREP:-?}"
        pq "SELECT application_name||' state='||state||' sync='||sync_state||' replay_lag='||coalesce(pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn)),'?') FROM pg_stat_replication" | sed 's/^/    /'
        BIGLAG=$(pq "SELECT count(*) FROM pg_stat_replication WHERE pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn) > 100*1024*1024")
        [ -n "$BIGLAG" ] && [ "$BIGLAG" -gt 0 ] && warn "replica(s) with replay lag >100MB"
        if [ "$P_PATRONI" = 1 ] && [ "${NREP:-0}" = 0 ]; then
            warn "Patroni cluster but primary has NO connected replicas"
        fi
    else
        WR=$(pq "SELECT status FROM pg_stat_wal_receiver")
        if [ "$WR" = streaming ]; then ok "wal receiver: streaming"
        else
            crit "replica is NOT streaming (pg_stat_wal_receiver: '${WR:-empty}') — check primary_conninfo, slot, pg_hba"
        fi
        if [ "$P_PATRONI" = 0 ] && [ "$K8S" = 0 ]; then
            note "node is in recovery with no Patroni — either a plain streaming replica or a demoted/read-only ex-primary; verify intent"
        fi
    fi

    # replication slots retaining WAL
    pq "SELECT slot_name||' active='||active||' wal_status='||coalesce(wal_status,'?')||' retained='||coalesce(pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn)),'?') FROM pg_replication_slots" 2>/dev/null | sed 's/^/    slot: /'
    BADSLOT=$(pq "SELECT count(*) FROM pg_replication_slots WHERE active='f' AND pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn) > 1024*1024*1024")
    [ -n "$BADSLOT" ] && [ "$BADSLOT" -gt 0 ] && crit "INACTIVE replication slot(s) retaining >1GB WAL — pg_wal will fill; verify and drop if obsolete"
    LOSTSLOT=$(pq "SELECT count(*) FROM pg_replication_slots WHERE wal_status IN ('lost','unreserved')")
    [ -n "$LOSTSLOT" ] && [ "$LOSTSLOT" -gt 0 ] && warn "slot(s) with wal_status lost/unreserved"

    # archiver
    AF=$(pq "SELECT failed_count FROM pg_stat_archiver")
    LFW=$(pq "SELECT coalesce(last_failed_wal,'') FROM pg_stat_archiver")
    if [ -n "$AF" ] && [ "$AF" -gt 0 ] && [ -n "$LFW" ]; then
        LFT=$(pq "SELECT last_failed_time > coalesce(last_archived_time,'epoch') FROM pg_stat_archiver")
        [ "$LFT" = t ] && crit "archive_command CURRENTLY FAILING (last_failed_wal=$LFW) — WAL accumulating" \
                       || info "archiver had $AF past failures but is archiving again"
    fi

    # wraparound
    MAXAGE=$(pq "SELECT max(age(datfrozenxid)) FROM pg_database")
    info "max datfrozenxid age: ${MAXAGE:-?}"
    if [ -n "$MAXAGE" ]; then
        [ "$MAXAGE" -gt 1000000000 ] && crit "XID age >1B — wraparound risk, urgent VACUUM FREEZE needed" \
        || { [ "$MAXAGE" -gt 500000000 ] && warn "XID age >500M — autovacuum falling behind"; }
    fi

    # dead tuples / vacuum
    pq "SELECT relname||' dead='||n_dead_tup||' last_autovac='||coalesce(last_autovacuum::text,'never') FROM pg_stat_user_tables WHERE n_dead_tup>100000 ORDER BY n_dead_tup DESC LIMIT 5" | sed 's/^/    bloat-signal: /'

    # checkpoints (PG<=16 vs PG17+)
    CKPT=$(pq "SELECT num_requested||'/'||num_timed FROM pg_stat_checkpointer" 2>/dev/null)
    [ -z "$CKPT" ] && CKPT=$(pq "SELECT checkpoints_req||'/'||checkpoints_timed FROM pg_stat_bgwriter" 2>/dev/null)
    [ -n "$CKPT" ] && info "checkpoints requested/timed: $CKPT (many requested => raise max_wal_size)"

    # memory sanity
    SB=$(pq "SHOW shared_buffers"); WM=$(pq "SHOW work_mem"); ECS=$(pq "SHOW effective_cache_size")
    info "shared_buffers=$SB work_mem=$WM effective_cache_size=$ECS (RAM: $(free -h | awk '/^Mem:/{print $2}'))"

    # pg_wal size on disk
    PGD=$(pq "SHOW data_directory")
    if [ -n "$PGD" ]; then
        if [ "$IS_DOCKER" = 1 ] && [ -n "$DOCKER_PATRONI_LEADER" ]; then
            WALSZ=$(docker exec -u postgres "$DOCKER_PATRONI_LEADER" du -sh "$PGD/pg_wal" 2>/dev/null | awk '{print $1}')
            [ -n "$WALSZ" ] && info "pg_wal size (in container): $WALSZ"
        elif [ "$HAVE_SUDO" = 1 ]; then
            WALSZ=$($SUDO du -sh "$PGD/pg_wal" 2>/dev/null | awk '{print $1}')
            [ -n "$WALSZ" ] && info "pg_wal size: $WALSZ"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 7. pgBackRest
# ---------------------------------------------------------------------------
hdr "PGBACKREST"
if have pgbackrest; then
    BR=$($SUDO -u postgres pgbackrest info 2>/dev/null || pgbackrest info 2>/dev/null)
    if [ -n "$BR" ]; then
        echo "$BR" | head -25
        echo "$BR" | grep -q 'status: ok' || warn "pgbackrest stanza status is NOT ok"
        echo "$BR" | grep -q 'no valid backups' && crit "pgBackRest: NO valid backups exist"
    else
        warn "pgbackrest installed but 'info' failed (config/permissions?)"
    fi
else
    info "pgbackrest not installed on this host"
fi

# ---------------------------------------------------------------------------
# 8. Linux health flags
# ---------------------------------------------------------------------------
hdr "LINUX HEALTH FLAGS"

# disk
df -h 2>/dev/null | awk 'NR==1 || /pgdata|pgsql|postgres|pg_wal|\/$|\/var/' | sed 's/^/    /'
while read -r pct mnt; do
    p=${pct%\%}
    if [ "$p" -ge 95 ]; then crit "filesystem $mnt at ${p}% — imminent outage risk"
    elif [ "$p" -ge 85 ]; then warn "filesystem $mnt at ${p}%"
    fi
done < <(df -h --output=pcent,target 2>/dev/null | tail -n +2 | grep -Ev 'tmpfs|overlay|/boot|/run|/snap')

# inodes
while read -r pct mnt; do
    p=${pct%\%}
    [ "$p" -ge 90 ] 2>/dev/null && warn "inodes on $mnt at ${p}%"
done < <(df -i --output=ipcent,target 2>/dev/null | tail -n +2 | grep -Ev 'tmpfs|overlay|/boot|/run|/snap')

# memory / swap
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
[ -n "$SWAP_USED" ] && [ "$SWAP_USED" -gt 512 ] && warn "swap in use: ${SWAP_USED}MB"

# kernel settings
OV=$(sysctl -n vm.overcommit_memory 2>/dev/null)
SW=$(sysctl -n vm.swappiness 2>/dev/null)
DR=$(sysctl -n vm.dirty_ratio 2>/dev/null)
DBR=$(sysctl -n vm.dirty_background_ratio 2>/dev/null)
info "sysctl: overcommit_memory=$OV swappiness=$SW dirty_ratio=$DR dirty_background_ratio=$DBR"
[ "$P_POSTGRES" = 1 ] && [ "$OV" = 0 ] && warn "vm.overcommit_memory=0 on a DB server — recommend 2 (with overcommit_ratio) to protect postmaster from OOM killer"
[ -n "$SW" ] && [ "$SW" -gt 10 ] && [ "$P_POSTGRES" = 1 ] && warn "vm.swappiness=$SW — recommend 1-10 for DB servers"
[ -n "$DR" ] && [ "$DR" -gt 15 ] && [ "$P_POSTGRES" = 1 ] && warn "vm.dirty_ratio=$DR — recommend 15 (background 5) on large-memory DB servers (this exact tuning is standard practice for large-memory workloads)"

# THP
THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
case "$THP" in
    *'[never]'*) ok "THP disabled" ;;
    '') : ;;
    *) [ "$P_POSTGRES" = 1 ] && warn "Transparent Huge Pages NOT disabled ($THP) — causes latency stalls for PostgreSQL" ;;
esac

# OOM killer history
if have dmesg; then
    OOM=$($SUDO dmesg -T 2>/dev/null | grep -ci 'killed process\|out of memory')
    [ -n "$OOM" ] && [ "$OOM" -gt 0 ] && crit "OOM killer events found in dmesg ($OOM) — check what was killed and memory sizing"
fi

# CPU steal / iowait snapshot
if have mpstat; then
    read -r STEAL IOW < <(mpstat 1 1 2>/dev/null | awk '/Average/ && $2=="all"{print $9, $6}')
    [ -n "$STEAL" ] && awk "BEGIN{exit !($STEAL>5)}" && warn "CPU steal ${STEAL}% — noisy neighbour / undersized burstable instance"
    [ -n "$IOW" ] && awk "BEGIN{exit !($IOW>20)}" && warn "iowait ${IOW}% — storage bottleneck (gp2 burst exhaustion?)"
fi

# failed units
FAILED=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -n "${FAILED// }" ] && warn "failed systemd units: $FAILED"

# ---------------------------------------------------------------------------
# 9. VERDICT
# ---------------------------------------------------------------------------
hdr "VERDICT"

ENVIRONMENT="UNKNOWN"
if [ "$K8S" = 1 ]; then
    case "$PG_OPERATOR" in
        percona-pg-v2) ENVIRONMENT="KUBERNETES + PERCONA OPERATOR FOR POSTGRESQL v2 (Patroni-based)" ;;
        crunchy-pgo)   ENVIRONMENT="KUBERNETES + CRUNCHY PGO (Patroni-based)" ;;
        cloudnativepg) ENVIRONMENT="KUBERNETES + CLOUDNATIVEPG (no Patroni; use kubectl cnpg)" ;;
        zalando)       ENVIRONMENT="KUBERNETES + ZALANDO OPERATOR (Spilo/Patroni)" ;;
        stackgres)     ENVIRONMENT="KUBERNETES + STACKGRES (Patroni-based)" ;;
        *)             ENVIRONMENT="KUBERNETES (${K8S_FLAVOR:-unknown} / $K8S_ROLE) — operator not identified from this node" ;;
    esac
elif [ "$IS_DOCKER" = 1 ]; then
    DCS="unknown"
    [ -n "$DOCKER_ETCD_CONTS" ] && DCS="etcd"
    LB=""
    [ -n "$DOCKER_HAPROXY_CONTS" ] && LB="+HAProxy"
    ENVIRONMENT="DOCKER PATRONI CLUSTER (DCS: $DCS$LB)"
elif [ "$P_PATRONI" = 1 ] || [ -n "$PATRONI_YML" ]; then
    DCS="unknown"
    { [ "$P_ETCD" = 1 ] || [ "$PT_2379" = 1 ]; } && DCS="etcd"
    { [ "$P_CONSUL" = 1 ] || [ "$PT_8500" = 1 ]; } && DCS="consul"
    [ "$P_ZK" = 1 ] && DCS="zookeeper"
    LB=""
    [ "$P_HAPROXY" = 1 ] && LB="+HAProxy"
    [ "$P_KEEPAL" = 1 ] && LB="$LB+keepalived"
    [ "$P_PGB" = 1 ] && LB="$LB+pgbouncer"
    ENVIRONMENT="VM PATRONI CLUSTER (DCS: $DCS$LB)"
elif [ "$P_POSTGRES" = 1 ]; then
    ENVIRONMENT="PLAIN POSTGRESQL ON VM (standard VM-based deployment)"
elif [ "$P_HAPROXY" = 1 ] || [ "$P_PGB" = 1 ]; then
    ENVIRONMENT="LOAD-BALANCER / PROXY NODE (DB is elsewhere — check haproxy.cfg for backend IPs)"
elif [ "$P_ETCD" = 1 ]; then
    ENVIRONMENT="DEDICATED DCS (etcd) NODE (DB is elsewhere)"
fi

printf '\n%sENVIRONMENT: %s%s\n' "$C_BLU" "$ENVIRONMENT" "$C_OFF"

if [ ${#ISSUES[@]} -eq 0 ]; then
    printf '%sNo issues flagged by automated checks.%s Verify manually per runbook.\n' "$C_GRN" "$C_OFF"
else
    printf '\n%sFLAGGED ISSUES (%d):%s\n' "$C_RED" "${#ISSUES[@]}" "$C_OFF"
    i=1
    for it in "${ISSUES[@]}"; do printf '  %2d. %s\n' "$i" "$it"; i=$((i+1)); done
fi

if [ ${#NOTES[@]} -gt 0 ]; then
    printf '\nNEXT STEPS:\n'
    for n in "${NOTES[@]}"; do printf '  - %s\n' "$n"; done
fi

case "$ENVIRONMENT" in
    *PERCONA\ OPERATOR*)
        cat <<'EOF'

SUGGESTED NEXT COMMANDS:
  kubectl get pg -A
  kubectl describe pg <cluster>
  kubectl exec -it <db-pod> -c database -- patronictl list
  kubectl exec <db-pod> -c pgbackrest -- pgbackrest info
EOF
        ;;
    *CLOUDNATIVEPG*)
        cat <<'EOF'

SUGGESTED NEXT COMMANDS:
  kubectl get cluster -A
  kubectl cnpg status <cluster> -n <ns> -v
  kubectl get pod -l cnpg.io/cluster=<cluster> -L role
EOF
        ;;
    *DOCKER\ PATRONI*)
        cat <<EOF

SUGGESTED NEXT COMMANDS:
  docker exec -it ${DOCKER_PATRONI_LEADER:-patroni1} patronictl -c /etc/patroni/patroni.yml list
  docker exec -it ${DOCKER_PATRONI_LEADER:-patroni1} patronictl -c /etc/patroni/patroni.yml history
  docker exec -it ${DOCKER_PATRONI_LEADER:-patroni1} patronictl -c /etc/patroni/patroni.yml show-config
  docker exec -it ${ETCD_CONT:-patroni-etcd} etcdctl endpoint status --cluster -w table
EOF
        ;;
    *VM\ PATRONI*)
        cat <<EOF

SUGGESTED NEXT COMMANDS:
  patronictl -c ${PATRONI_YML:-/etc/patroni/patroni.yml} list
  patronictl -c ${PATRONI_YML:-/etc/patroni/patroni.yml} history
  patronictl -c ${PATRONI_YML:-/etc/patroni/patroni.yml} show-config
  ETCDCTL_API=3 etcdctl endpoint status --cluster -w table
EOF
        ;;
esac

printf '\nDone. Read-only triage complete — nothing was modified.\n'
exit 0
