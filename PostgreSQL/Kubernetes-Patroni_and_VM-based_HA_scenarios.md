# Kubernetes/Patroni and VM-based HA Scenario Reference

## TL;DR
- High-availability PostgreSQL topologies typically consist of either (a) a Kubernetes cluster running a Patroni-based operator — such as the **Percona Operator for PostgreSQL v2** (CRD `perconapgclusters`/`pg`, API group `pgv2.percona.com`) — or (b) a VM-based **Patroni + etcd + HAProxy** cluster. Use the identification runbook in Part 1 to determine the configuration.
- The single most important operational rule in both HA scenarios: **never fight the automation**. In Kubernetes, change PostgreSQL parameters through the Custom Resource (`spec.patroni.dynamicConfiguration`), not `postgresql.conf`; the operator reverts direct edits. On VMs, change parameters through `patronictl edit-config` (dynamic, stored in DCS), restart via `patronictl restart` (never `systemctl restart patroni` on the primary — that triggers a failover), and use `patronictl pause` before any manual PostgreSQL maintenance.
- Treat every machine as production: take a timestamped backup of any file before editing it, plan any restart or outage in advance, keep a running command log in a scratch file, and structure tasks systematically starting with discovery, then execution, and finally documentation.

## Key Findings

1. **Environment identification is fast and deterministic.** Three or four commands (`ps aux`, `ss -tlnp`, `ls /etc/kubernetes /etc/patroni`, `which kubectl patronictl crictl`) unambiguously separate the three worlds. Listening ports are the quickest tell: 8008 = Patroni REST API; 2379/2380 = etcd; 6443 = kube-apiserver; 10250 = kubelet; 5000/5001 = HAProxy; 6432 = PgBouncer.

2. **The Percona_Operator is Patroni-based.** It uses Patroni 4.x — Percona_Operator for PostgreSQL 2.8.0 (released 13 November 2025) standardised on Patroni 4 as the only supported version and dropped the `pgv2.percona.com/custom-patroni-version` override, detecting the version automatically through `patronictl` (later builds ship Patroni 4.1.2). It uses pgBackRest for backups and PgBouncer for pooling. Patroni runs *inside* the database pods; you reach it via `kubectl exec … -- patronictl`. Configuration lives in operator-managed ConfigMaps that the operator rewrites unless you set an override annotation.

3. **CloudNativePG is architecturally different** — no Patroni, no StatefulSets, the instance manager is PID 1 in each pod, and the operator itself (talking to the Kubernetes API as the DCS) performs failover. Operational entry point is the `kubectl cnpg` plugin.

4. **The classic VM stack is Patroni/etcd/HAProxy/(keepalived).** The diagnostic spine is `patronictl list`/`topology`, the Patroni REST API on :8008, `etcdctl endpoint health/status`, and the HAProxy stats page on :7000. The defining failure signature of DCS loss is **all nodes read-only** with "demoted self because failed to update leader lock in DCS" in the Patroni log.

5. **The most stageable breakages** on throwaway EC2 are: a stopped/killed Patroni or etcd process, a full `pg_wal` disk from an inactive replication slot or failing `archive_command`, a `pg_hba.conf` line blocking replication, an oversized `shared_buffers` causing OOM, a bloated/unvacuumed table, a mis-routed HAProxy backend, a broken replica needing `reinit`, and wrong kernel settings (dirty ratios, THP, overcommit).

## Details

---

# PART 1 — RAPID ENVIRONMENT-IDENTIFICATION RUNBOOK (first 15 minutes)

Run these immediately on login. Keep output in a scratch file: `script /tmp/session_$(date +%s).log` or paste into notes.

### 1.1 First 60 seconds — who/where am I

```bash
hostname -f; whoami; id
cat /etc/os-release
uname -r                      # kernel; RHEL vs Debian family matters for paths
uptime; nproc; free -h
lscpu | grep -E 'Model name|Socket|NUMA'
# Cloud/instance metadata (IMDSv2)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type
```

### 1.2 Process and service sweep

```bash
ps aux | grep -Ei 'postgres|patroni|etcd|consul|zookeeper|haproxy|keepalived|pgbouncer|kubelet|containerd|dockerd|k3s|crio' | grep -v grep
systemctl list-units --type=service --state=running | grep -Ei 'postgre|patroni|etcd|haproxy|keepal|pgbouncer|kubelet|containerd|docker|k3s|crio'
```

### 1.3 Listening-port fingerprint (the fastest single discriminator)

```bash
ss -tlnp | sort -t: -k2 -n
```

**Port reference table:**

| Port | Service | Implies |
|------|---------|---------|
| 5432 | PostgreSQL | DB present (native or container) |
| 6432 | PgBouncer | Connection pooling in front of PG |
| 8008 | **Patroni REST API** | Patroni-managed cluster (VM or K8s) |
| 2379 | etcd client | etcd DCS present |
| 2380 | etcd peer | etcd cluster member |
| 8500 | Consul | Consul used as DCS |
| 5000 | HAProxy → primary (rw) | VM HAProxy front-end |
| 5001 | HAProxy → replicas (ro) | VM HAProxy read pool |
| 7000 | HAProxy stats | HAProxy present |
| 6443 | kube-apiserver | Kubernetes control plane node |
| 10250 | kubelet API | Kubernetes node (any) |
| 10259/10257 | kube-scheduler/controller | control-plane node |
| 2379/2380 | (also) K8s etcd | kubeadm control plane |

### 1.4 Kubernetes-or-not

```bash
which kubectl crictl ctr docker k3s kubeadm kubelet 2>/dev/null
ls -la /etc/kubernetes/ 2>/dev/null            # manifests/, admin.conf, kubelet.conf → kubeadm/EKS control plane
ls -la /var/lib/kubelet/ 2>/dev/null
ls -la ~/.kube/config /etc/rancher/k3s/k3s.yaml 2>/dev/null
# Container runtime present?
sudo crictl ps 2>/dev/null | head        # containerd/CRI-O via CRI
sudo ctr -n k8s.io containers list 2>/dev/null | head
docker ps 2>/dev/null | head
# If kubectl works, what is this?
kubectl get nodes -o wide 2>/dev/null
kubectl config current-context 2>/dev/null
```
- `/etc/rancher/k3s/k3s.yaml` present → **k3s** (kubectl often symlinked; etcd may be embedded/SQLite). Set `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`.
- `/etc/kubernetes/manifests/` present → **kubeadm** self-managed control plane (etcd static pod on :2379).
- Node names ending in `.compute.internal`, `aws-node`/`vpc-cni` pods, no `/etc/kubernetes/manifests` → **EKS** (control plane is managed/hidden).
- If `crictl`/`ctr` work but `kubectl` does not, you are on a **worker node** — inspect containers directly and look for a kubeconfig.

### 1.5 PostgreSQL: native or containerised, and where is PGDATA

```bash
# Native?
sudo -u postgres psql -c "SELECT version();" 2>/dev/null
ps -o pid,cmd -C postgres | grep -- -D          # -D shows data directory
sudo -u postgres psql -tAc "SHOW data_directory; SHOW config_file; SHOW hba_file;"
# Config file locations (Debian vs RHEL differ)
ls /etc/postgresql/*/main/postgresql.conf 2>/dev/null      # Debian
ls /var/lib/pgsql/*/data/postgresql.conf 2>/dev/null       # RHEL
find / -name postgresql.conf 2>/dev/null | head
# Containerised? (inside pod the data dir is typically /pgdata)
mount | grep -Ei 'pgdata|pgsql|postgres|pv'
df -h | grep -Ei 'pgdata|pgsql|postgres'
```

### 1.6 DECISION TREE

```
Q1. Does `kubectl get nodes` or `crictl ps` work, or does /etc/kubernetes exist?
   ├─ YES → KUBERNETES PATH (Part 2)
   │        Q1a. kubectl get crd | grep -Ei 'pgv2.percona|crunchydata|cnpg|zalan|stackgres'
   │             → identifies operator (see 2.1). Go to that operator's section.
   │        Q1b. No PG CRD but postgres pods exist → raw StatefulSet+Patroni; use kubectl exec patronictl.
   └─ NO → is Patroni running (ps shows patroni; :8008 listening)?
            ├─ YES → VM PATRONI CLUSTER PATH (Part 3)
            │         Check DCS: etcd (:2379) / consul (:8500). Check HAProxy (:5000/:7000).
            └─ NO → is postgres running natively?
                     ├─ YES → PLAIN VM POSTGRESQL (the "normal" scenario you prepared)
                     └─ NO → nothing running: check systemctl --failed, journalctl, disk full, then Part 5.
```

### 1.7 Rapid topology mapping (once path is known)

**VM Patroni:**
```bash
export PATRONICTL="patronictl -c /etc/patroni/patroni.yml"   # confirm path first: ls /etc/patroni/
$PATRONICTL list; $PATRONICTL topology; $PATRONICTL history
curl -s http://localhost:8008/cluster | jq .
# etcd
export ETCDCTL_API=3
etcdctl member list -w table
etcdctl endpoint status --cluster -w table
etcdctl endpoint health --cluster
```

**Kubernetes:**
```bash
kubectl get pods,svc,endpoints,pvc -A -o wide | grep -Ei 'pg|postgre|patroni'
kubectl get pg,pxc,cluster,postgresql -A 2>/dev/null        # try each CRD short name
# For Patroni-based operators:
kubectl exec -it <primary-pod> -c database -- patronictl list
```

---

# PART 2 — KUBERNETES SCENARIO DEEP DIVE

## 2.1 Identify the operator (run first)

```bash
kubectl get crd | grep -Ei 'postgres|pg'
```

**Operator identification table:**

| CRD (kubectl get crd) | Short name | Operator | HA engine |
|---|---|---|---|
| `perconapgclusters.pgv2.percona.com` | `pg` | **Percona_Operator for PostgreSQL v2** | Patroni |
| `postgresclusters.postgres-operator.crunchydata.com` | `postgrescluster` | Crunchy PGO | Patroni |
| `clusters.postgresql.cnpg.io` | `cluster` | CloudNativePG | instance manager (no Patroni) |
| `postgresqls.acid.zalan.do` | `postgresql` | Zalando postgres-operator | Patroni (Spilo) |
| `sgclusters.stackgres.io` | `sgcluster` | StackGres | Patroni |

Confirm operator pod and namespace:
```bash
kubectl get pods -A | grep -Ei 'operator|pgo|cnpg|postgres'
kubectl get pods -A -L app.kubernetes.io/name
```

The Percona_Operator for PostgreSQL is a fork of CrunchyData's PGO (confirmed in Percona's own docs: "The Operator is based on CrunchyData's PostgreSQL Operator"), so you may see BOTH `pgv2.percona.com` CRDs and `postgres-operator.crunchydata.com` CRDs/labels/annotations present — that combination confirms **Percona**. Labels/annotations to look for: `postgres-operator.crunchydata.com/cluster`, `pgv2.percona.com/version`, `pgv2.percona.com/override-config`.

## 2.2 Percona Operator for PostgreSQL v2 — Specifics

**Architecture:** Patroni-based HA (leader election + failover via Kubernetes API as DCS), pgBackRest for backups/PITR/replica creation, PgBouncer for pooling. Instances run as pods (via StatefulSets under the hood, one per instance set); typical pod naming `cluster1-instance1-xxxx-0`. Containers in a DB pod include `database` (postgres+patroni), `replication-cert-copy`, `pgbackrest`, `pgbackrest-config`.

**Inspect the cluster:**
```bash
kubectl get pg                                      # PerconaPGCluster objects
kubectl describe pg cluster1
kubectl get pods -l postgres-operator.crunchydata.com/cluster=cluster1 \
  -L postgres-operator.crunchydata.com/instance \
  -L postgres-operator.crunchydata.com/role          # role = master / replica
```

**Run patronictl / reach the REST API inside a pod:**
```bash
kubectl exec -it cluster1-instance1-xxxx-0 -c database -- patronictl list
kubectl exec -it cluster1-instance1-xxxx-0 -c database -- patronictl show-config
kubectl exec cluster1-instance1-xxxx-0 -c database -- curl -s localhost:8008/cluster | jq .
kubectl exec cluster1-instance1-xxxx-0 -c database -- cat /etc/patroni/~postgres-operator_cluster.yaml
```

**pgBackRest inspection:**
```bash
kubectl exec -it cluster1-repo-host-0 -c pgbackrest -- pgbackrest info
# or from the DB pod:
kubectl exec cluster1-instance1-xxxx-0 -c pgbackrest -- pgbackrest info
kubectl get pg-backup 2>/dev/null; kubectl get perconapgbackup -A 2>/dev/null
```

**Correct way to change PostgreSQL parameters** — via the Custom Resource, NOT `postgresql.conf`:
```yaml
spec:
  patroni:
    dynamicConfiguration:
      postgresql:
        parameters:
          shared_buffers: 2GB
          work_mem: 16MB
          max_connections: 200
```
Apply with `kubectl apply -f deploy/cr.yaml` (or `kubectl edit pg cluster1`). Parameters are applied dynamically except those with `context=postmaster`, which cause Patroni to do a rolling restart of instances one by one. Verify context with `SELECT name, context FROM pg_settings WHERE name='<param>';`.

**Correct switchover** — through the CR, not raw patronictl:
```bash
kubectl -n <ns> patch pg cluster1 --type=merge --patch \
  '{"spec":{"patroni":{"switchover":{"enabled":true,"targetInstance":"cluster1-instance1-bmdp"}}}}'
kubectl annotate --overwrite -n <ns> pg cluster1 \
  postgres-operator.crunchydata.com/trigger-switchover="$(date)"
# after completion set switchover.enabled back to false
```

**Common pitfalls (document these if you touch them):**
- Editing the per-pod ConfigMap `<pod>-config` directly → the operator immediately rewrites it. To make a manual change stick temporarily: `kubectl annotate cm cluster1-instance1-xxxx-config pgv2.percona.com/override-config=true`, edit, then **remove the annotation afterwards** (`…/override-config-`). Not recommended except for short maintenance.
- After changing the Patroni ConfigMap you must `kubectl exec … -- patronictl reload <cluster> <pod>`; the operator does not auto-reload Patroni.
- To do manual maintenance without the operator interfering, set `spec.unmanaged: true` (stops reconciliation but leaves pods running) or `spec.pause: true` (gracefully stops the whole cluster — this IS an outage, justify it). A running backup job blocks pause; delete the job first.
- Finalizers (`finalizers.percona.com/delete-pvc`, `delete-ssl`, `delete-backups`) control whether PVCs/secrets/backups are removed on cluster deletion — never delete a cluster casually.
- Operator 2.8+ standardises on Patroni 4 and detects the version via `patronictl` rather than a temporary version-check pod.

## 2.3 CloudNativePG contrast (brief — you know the architecture)

No Patroni; the **instance manager** is PID 1 in each pod and the operator uses the **Kubernetes API server** as the source of truth. **No StatefulSets** — the operator creates Pods directly and manages one PVC per instance. Services: `<cluster>-rw` (primary), `<cluster>-ro` (replicas round-robin), `<cluster>-r` (any). Pod role label: `cnpg.io/cluster` + `role`.

Operational commands (install plugin: `curl -sSfL .../install-cnpg-plugin.sh | sudo sh -s -- -b /usr/local/bin`):
```bash
kubectl cnpg status <cluster> -n <ns>            # add -v / -v -v for config, HBA, certs
kubectl cnpg promote <cluster> <cluster>-2       # controlled promotion
kubectl cnpg restart <cluster>                   # rollout restart
kubectl cnpg reload <cluster>
kubectl cnpg backup <cluster>
kubectl cnpg logs cluster <cluster> -f
kubectl get cluster <cluster> -o yaml            # status.conditions: ContinuousArchiving, LastBackupSucceeded, Ready
kubectl get pod -l cnpg.io/cluster=<cluster> -L role -n <ns>
```
Change parameters declaratively in `spec.postgresql.parameters`; the operator rolls out restarts (replica-first, switchover last) when a postmaster-context parameter changes. `primaryUpdateStrategy: unsupervised` (default) auto-switches over; `supervised` requires manual `kubectl cnpg promote`.

## 2.4 Kubernetes-level diagnostics for a PostgreSQL health check

```bash
kubectl get pods -o wide -n <ns>                 # STATUS, RESTARTS, node placement
kubectl get pvc,pv -n <ns>                        # Bound? capacity? storageclass
kubectl get svc,endpoints -n <ns>                 # do endpoints have addresses?
kubectl describe pod <pod> -n <ns>                # Events: OOMKilled, FailedMount, probe failures, scheduling
kubectl logs <pod> -c database -n <ns>            # current
kubectl logs <pod> -c database -n <ns> --previous # after a crash/restart
kubectl top pod -n <ns>; kubectl top node
kubectl get pdb -n <ns>                            # pod disruption budgets
kubectl describe node <node>                       # Conditions: MemoryPressure/DiskPressure/PIDPressure; allocatable
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -40
```

Check resource requests/limits and **QoS class** (`kubectl get pod <pod> -o jsonpath='{.status.qosClass}'` → Guaranteed/Burstable/BestEffort). Confirm anti-affinity spreads instances across nodes (`kubectl get pods -o wide` — they should be on different nodes). Inspect the readiness/liveness probes for Patroni pods — they hit the REST API on :8008. Per the Patroni docs, `GET /readiness` returns HTTP 200 when the node is running as the leader or when PostgreSQL is up and running; `GET /liveness` returns 200 if the Patroni heartbeat loop is running properly and 503 if the last run was more than `ttl` seconds ago on the primary (or `2*ttl` on a replica). Probe `failureThreshold` is typically `leaderLeaseDurationSeconds / syncPeriodSeconds`.

**Confirm OOMKilled explicitly:**
```bash
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'   # → OOMKilled (exit 137)
```

## 2.5 Kubernetes + PostgreSQL failure modes

| Symptom | Diagnostic | Safe production fix | Report note |
|---|---|---|---|
| `CrashLoopBackOff` on PG pod | `kubectl logs --previous`; `describe` events | Fix root cause (config, missing PVC/secret, corrupt PGDATA); do not just delete pod repeatedly | Root cause, backoff observed, action |
| `OOMKilled` (137) | `lastState.terminated.reason`; compare `shared_buffers` vs memory limit | Raise memory limit *or* lower `shared_buffers`/`work_mem` via CR; keep `shared_buffers` well under the limit (leave room for work_mem × connections + OS) | old/new limit, param change, restart type |
| PVC full (pg_wal/PGDATA) | `kubectl exec -- df -h`; `describe pvc` | If storageclass `allowVolumeExpansion: true`, patch PVC `spec.resources.requests.storage`; else clear WAL cause (slot/archive). `FileSystemResizePending` → pod restart to finish resize | before/after size, expansion path |
| WAL archiving failing to object store | operator: `status.conditions ContinuousArchiving=False`; `pgbackrest info`; PG log | Fix S3 creds/secret, connectivity, stanza; re-run archive-push | error, cause, verification |
| Stuck failover / no leader | `patronictl list` all replica/read-only; operator/Patroni logs | Check DCS reachability (K8s API), probes, quorum; reinit broken replica; escalate before force | timeline, cause, action |
| Operator reconciliation reverts change | change reappears after edit | Use the CR / override annotation / unmanaged mode instead of direct edits | why direct edit was wrong |
| Service has no endpoints | `kubectl get endpoints`; pod readiness | Fix failing readiness probe (:8008), label selectors | which probe, why failing |
| Certificate expiry (REST API TLS / operator certs) | probe/patroni TLS errors in logs; check secret `notAfter` | Rotate via cert-manager / operator-managed secret; operator regenerates | cert, expiry, rotation |
| DCS (K8s API/etcd) unavailable → all read-only | Patroni "failed to update leader lock in DCS"; nodes read-only | Restore API/etcd; consider DCS failsafe mode design | symptom recognition, cause |

---

# PART 3 — VM-BASED PATRONI / etcd / HAProxy CLUSTER

## 3.1 Full health-check sequence

```bash
# confirm config path first
ls -l /etc/patroni/*.yml /etc/patroni/*.yaml 2>/dev/null
alias p='patronictl -c /etc/patroni/patroni.yml'
p list            # Cluster, Member, Host, Role, State, TL (timeline), Lag in MB
p topology        # shows cascading replication hierarchy
p history         # past failovers/switchovers with timelines
p show-config     # effective dynamic config from DCS

# Patroni REST API (per-node; use each node's IP)
curl -s localhost:8008/patroni | jq .        # role, state, xlog location, timeline, replication[]
curl -s localhost:8008/cluster | jq .
curl -s localhost:8008/health ; echo         # 200 = PG up
curl -s -o /dev/null -w '%{http_code}\n' localhost:8008/primary   # 200 only on leader
curl -s -o /dev/null -w '%{http_code}\n' localhost:8008/replica   # 200 only on streaming replica

journalctl -u patroni --no-pager -n 200
```

Interpreting `patronictl list`: **Role** (Leader / Replica / Sync Standby / Standby Leader), **State** (running / streaming / stopped / start failed / creating replica), **TL** (timeline — all healthy nodes should share the same number; a lower TL means a node is behind or diverged), **Lag in MB**, and **Pending restart** (`*` means a postmaster-context change awaits `patronictl restart`).

**etcd health (the DCS):**
```bash
export ETCDCTL_API=3
etcdctl member list -w table
etcdctl endpoint status --cluster -w table   # DB SIZE, IS LEADER, RAFT TERM/INDEX, ERRORS (e.g. alarm:NOSPACE)
etcdctl endpoint health --cluster
etcdctl alarm list                            # NOSPACE alarm blocks all writes
# TLS clusters need --cacert/--cert/--key and https:// endpoints
```
If etcd shows `alarm:NOSPACE` and DB SIZE near the quota (etcd's default storage-size limit is 2 GB, configurable with `--quota-backend-bytes`; 8 GB is the suggested maximum and etcd warns at startup if the configured value exceeds it): use `etcdctl endpoint status` to get the revision, `etcdctl compact <rev>`, `etcdctl defrag` (blocks the member while running — do one member at a time, prefer offline `etcdutl defrag`), then `etcdctl alarm disarm`. Root cause is usually no `--auto-compaction-retention` set.

**HAProxy:**
```bash
cat /etc/haproxy/haproxy.cfg
# stats page: http://<host>:7000/  (bind *:7000, stats uri /)
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18   # pxname,svname,status
```
The Patroni/HAProxy pattern: `listen primary bind *:5000 option httpchk /primary` (only the leader answers 200) and `listen standbys bind *:5001 ... httpchk /replica balance roundrobin`. Modern HAProxy (≥2.2) uses `http-check send meth OPTIONS uri /primary`. Note that Patroni 4.0.x removed the legacy `/master` path (and `role=master` in REST requests, and `patronictl --master`) in favour of `/primary`/`--leader`/`--primary`, so old configs found online may health-check the wrong path. `[WARNING]` messages about backends being DOWN for the opposite role are harmless and expected. `on-marked-down shutdown-sessions` drops connections to a demoted primary immediately.

**keepalived (if a VIP is present):**
```bash
systemctl status keepalived; cat /etc/keepalived/keepalived.conf
ip a | grep -A2 <iface>          # which node currently holds the VIP
```

## 3.2 Patroni configuration deep points likely to be tested

- **`bootstrap.dcs` / dynamic config:** `ttl` (leader-lock lease; Patroni default 30, minimum 20), `loop_wait` (HA cycle; default 10, minimum 1), `retry_timeout` (10s), `maximum_lag_on_failover` (bytes; a replica lagging more than this cannot be promoted in a healthy failover). Rule: `ttl > loop_wait + 2*retry_timeout`. The watchdog warns if `ttl < 2*loop_wait`.
- **Synchronous:** `synchronous_mode: true` and `synchronous_mode_strict: true` (never fall back to async even if no sync standby is available — trades availability for zero data loss). `synchronous_node_count` sets how many sync standbys.
- **`use_pg_rewind: true`** lets a demoted old primary rejoin without a full basebackup after divergence. **`use_slots: true`** uses physical replication slots for members.
- **Tags** (per node in patroni.yml): `nofailover: true` (never promote this node), `noloadbalance: true` (exclude from `/replica`), `clonefrom: true` (prefer as basebackup source), `nosync: true` (never a sync standby).
- **`pg_hba` is managed by Patroni** (in dynamic config / bootstrap); editing `pg_hba.conf` directly may be overwritten. Change it through `patronictl edit-config`.
- **Dynamic vs local config:** dynamic config (in DCS, edited by `patronictl edit-config`) applies cluster-wide; local `patroni.yml` options take precedence on that node and are reloaded with SIGHUP / `patronictl reload` / `POST /reload`. Parameter precedence (highest last): `postgresql.base.conf` → dynamic config → `ALTER SYSTEM` (`postgresql.auto.conf`) → Patroni-enforced params.
- **Params Patroni enforces / needs care:** `max_connections`, `max_worker_processes`, `max_wal_senders`, `max_prepared_transactions`, `max_locks_per_transaction`, `wal_level`, `listen_addresses`, `port`. The shared-memory ones cannot be smaller on a standby than on the primary; when **increasing**, restart replicas first then primary; when **decreasing**, restart primary first. If you decrease and restart all at once, Patroni ignores the change on standbys and you must restart them again.
- **`pending_restart` flag** appears when a postmaster-context change is pending; clear it with `patronictl restart <cluster> [<member>]`.

## 3.3 Controlled operations (with production justification)

| Operation | Command | When / justification |
|---|---|---|
| **Switchover** (planned, no data loss) | `p switchover --candidate <node> [--scheduled <t>]` | Maintenance on primary. Requires healthy candidate; brief write interruption (seconds). Preferred for anything planned. |
| **Failover** (emergency) | `p failover --candidate <node>` | Only when primary is down/unrecoverable. May lose unsynced data. |
| **Pause** (maintenance mode) | `p pause` | Before manual PostgreSQL work / `systemctl restart patroni` so Patroni does not fight you or fail over. Automatic failover disabled while paused. |
| **Resume** | `p resume` | Re-enable automation after maintenance. |
| **Reinit** broken replica | `p reinit <cluster> <member>` | Replica with corrupt/diverged data; rebuilds from primary/backup. Add `{"force":true}` via API if stuck in a recovery loop. |
| **Restart** (apply pending_restart) | `p restart <cluster> [<member>]` | Never `systemctl restart patroni` on the primary — that can trigger a failover. Restart replicas first for increases. |
| **Reload** | `p reload <cluster>` | Apply reload-context param changes (SIGHUP). |

**Critical rule:** to restart PostgreSQL, use `patronictl restart` or the REST `/restart`, NOT `systemctl restart patroni` on the primary.

## 3.4 VM failure modes and diagnosis

| Failure | Signature | Diagnosis / fix |
|---|---|---|
| Replication lag | `patronictl list` Lag in MB grows; `pg_stat_replication` write/flush/replay lag | Check network, disk I/O on replica, long-running query blocking replay; `wal_keep_size`/slots |
| Replica not streaming | `pg_stat_wal_receiver` empty; State not `streaming` | Check `primary_conninfo`, slot existence, `pg_hba` replication line, `restore_command`; `reinit` if diverged |
| **DCS down → all read-only** | Every node read-only; log "demoted self because failed to update leader lock in DCS"; "Loop time exceeded" | Restore etcd quorum; then Patroni recovers. Recognise the pattern immediately. DCS failsafe mode mitigates. |
| etcd quorum loss (2 of 3 down) | `etcdctl endpoint health` fails; no leader elected | Restore members; cluster cannot elect a PG leader without DCS quorum |
| Timeline divergence | different TL in `patronictl list`; old primary won't rejoin | `use_pg_rewind`, or `reinit` the diverged node |
| WAL disk full | `df -h` on pg_wal 100%; PG stops accepting writes | Find cause: inactive slot or failing archive; free space carefully; never `rm` WAL manually |
| `archive_command` failing | `pg_stat_archiver` `failed_count` climbing, `last_failed_wal` | Fix pgBackRest/archive target; WAL accumulates until fixed |
| Stale/inactive replication slot | `pg_replication_slots` `active=f`, growing `restart_lsn` distance | If slot obsolete: `pg_drop_replication_slot()`; set `max_slot_wal_keep_size` as a guard |

**Key diagnostic queries:**
```sql
-- replication (on primary)
SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)  AS sent_lag,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag
FROM pg_stat_replication;
-- on replica
SELECT status, sender_host, latest_end_lsn FROM pg_stat_wal_receiver;
-- slots retaining WAL
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots ORDER BY 3 DESC;
-- archiver
SELECT archived_count, failed_count, last_failed_wal, last_failed_time FROM pg_stat_archiver;
```

## 3.5 pgBackRest integration checks

```bash
sudo -iu postgres pgbackrest info                       # stanza status, backup list, wal min/max
sudo -iu postgres pgbackrest --stanza=<name> check      # verifies archive_command + config end-to-end
grep -E 'archive_command|restore_command' $PGDATA/postgresql.*conf
```
- `archive_command = 'pgbackrest --stanza=<name> archive-push %p'`; `restore_command = 'pgbackrest --stanza=<name> archive-get %f "%p"'`.
- Check **last backup age** in `pgbackrest info` (timestamp stop) and stanza `status: ok`.
- **Backup from standby** (offload the primary): `backup-standby=y` in config; pgBackRest still touches the primary briefly for the start/stop backup but reads data from the replica. Throttle with `process-max` and `compress-type`.
- **PITR concept** (high level, do not run casually): restore then recover to a target — `pgbackrest --stanza=<name> --type=time --target="2026-07-08 12:00:00" restore`. In a Patroni cluster, PITR means bootstrapping/reinit, not a live restore over a running primary — justify and coordinate.

---

# PART 4 — CROSS-CUTTING LINUX & POSTGRESQL CHECKS (framed for HA/K8s)

## 4.1 Linux quick health

```bash
free -h; cat /proc/meminfo | grep -i huge
sysctl vm.overcommit_memory vm.overcommit_ratio vm.swappiness vm.dirty_ratio vm.dirty_background_ratio
cat /sys/kernel/mm/transparent_hugepage/enabled     # want [never] for DB
df -h; df -i                                         # space AND inodes; check pg_wal + PGDATA mounts
iostat -xz 1 3                                        # %util, await; EBS latency
mpstat -P ALL 1 3                                     # %steal (noisy neighbour), %iowait
uptime                                                # load vs nproc
ulimit -n -u                                          # open files, procs
numactl --hardware 2>/dev/null                        # NUMA on large instances
```

**Tuning guidance (for the report):**
- `vm.overcommit_memory=2` (+ `vm.overcommit_ratio`) recommended for dedicated DB servers to reduce OOM-killer risk to the postmaster; on containers/K8s this is a node-level setting and shared_buffers must fit within cgroup limits instead. Alternative: set the postmaster OOM score to -1000.
- `vm.swappiness` low (1–10, not 0) for DB servers.
- **THP disabled** (`never`) — THP causes latency stalls for PostgreSQL.
- **Dirty ratios:** the email's own example (`vm.dirty_ratio=15`, `vm.dirty_background_ratio=5`) is the standard large-memory DB recommendation — lowering from defaults (typically 20/10) so background flushing starts earlier and foreground stalls are rarer. On a large-RAM box the default 10% can represent tens of GB of dirty pages, producing huge checkpoint-time I/O spikes; the dirty_ratio×RAM figure (e.g. ~38.4 GB on a 256 GB box at 15%) is the concrete number to cite. Explicit `*_bytes` variants can be used instead of ratios on very large memory.
- **Huge pages:** compute pages needed from `VmPeak` of the postmaster and `Hugepagesize`; set `vm.nr_hugepages`, then `huge_pages=on`. In containers, huge pages must be exposed to the pod and interact with cgroup memory limits — usually left `off` in operator defaults.
- **EBS:** prefer **gp3** (provisioned baseline IOPS/throughput independent of size) or **io2** for latency-sensitive; **gp2** burst-balance exhaustion is a classic staged trap — check CloudWatch `BurstBalance` / latency. `iostat` await climbing with %util at 100% on gp2 points to burst exhaustion.

## 4.2 PostgreSQL health sweep

```sql
SELECT version();
SELECT pg_postmaster_start_time(), now()-pg_postmaster_start_time() AS uptime;
-- activity
SELECT pid, state, wait_event_type, wait_event, now()-xact_start AS xact_age, left(query,60)
FROM pg_stat_activity WHERE state<>'idle' ORDER BY xact_age DESC NULLS LAST;
SELECT count(*), state FROM pg_stat_activity GROUP BY state;   -- vs max_connections
-- idle in transaction (blockers)
SELECT pid, now()-state_change AS idle_age FROM pg_stat_activity
WHERE state='idle in transaction' ORDER BY idle_age DESC;
-- autovacuum / bloat signals
SELECT schemaname, relname, n_dead_tup, n_live_tup, last_autovacuum, last_analyze
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 20;
-- wraparound
SELECT datname, age(datfrozenxid),
       round(100*age(datfrozenxid)/2000000000.0,1) AS pct_emergency
FROM pg_database ORDER BY 2 DESC;
SELECT relname, age(relfrozenxid) FROM pg_class WHERE relkind='r' ORDER BY 2 DESC LIMIT 10;
-- checkpoints (PG16: pg_stat_bgwriter; PG17+: pg_stat_checkpointer)
SELECT * FROM pg_stat_bgwriter;   -- checkpoints_timed vs checkpoints_req (many _req = checkpoint pressure)
-- top queries
SELECT queryid, calls, round(total_exec_time::numeric,1) AS total_ms,
       round(mean_exec_time::numeric,2) AS mean_ms, rows
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 15;
-- missing-index signal
SELECT relname, seq_scan, idx_scan, seq_tup_read
FROM pg_stat_user_tables WHERE seq_scan>0 ORDER BY seq_tup_read DESC LIMIT 15;
-- memory sanity vs instance RAM
SHOW shared_buffers; SHOW work_mem; SHOW effective_cache_size; SHOW maintenance_work_mem;
```

Sanity heuristics: `shared_buffers` ≈ 25% RAM (but must fit under a container limit), `effective_cache_size` ≈ 50–75% RAM, `work_mem` sized so `work_mem × max_connections × (parallel workers)` cannot exhaust RAM. Many `checkpoints_req` relative to `checkpoints_timed` → raise `max_wal_size`. `datfrozenxid` age approaching 200M → autovacuum falling behind; approaching 2B → emergency (PostgreSQL refuses new XIDs once fewer than ~3M remain, warns from ~40M remaining).

## 4.3 Query optimisation workflow under time pressure

1. `EXPLAIN (ANALYZE, BUFFERS)` the query — look for Seq Scan on large tables, high `rows removed by filter`, misestimated row counts, external sort/hash (spilling to disk → raise `work_mem` for the session), nested loops over large sets.
2. Common rewrites: replace functions on indexed columns (`WHERE lower(col)=…` → expression index or store normalised), turn `OR` into `UNION`/`IN`, fix correlated subqueries into joins, use keyset (seek) pagination instead of large `OFFSET`.
3. `CREATE INDEX CONCURRENTLY` on production (no long lock) — **cannot run inside a transaction block**, and leaves an INVALID index if it fails (drop and retry). In a Patroni cluster the index replicates to standbys automatically.
4. `ANALYZE <table>` after large data change or before trusting a plan; check `pg_stat_user_tables.last_analyze`.
5. Document before/after plan cost and timing.

---

# PART 5 — FAILURE-MODE ANALYSIS AND RUNBOOKS

The following failure modes are commonly encountered in highly available PostgreSQL environments. For each: signature → safe fix → risk/justification.

| Subsystem | Staged failure | Diagnostic signature | Safe production fix | Risk / justification |
|---|---|---|---|---|
| **pg_hba** | replication line missing/`reject` | replica can't connect; log "no pg_hba.conf entry for replication"; `pg_stat_wal_receiver` empty | Add `hostssl replication …` via `patronictl edit-config` (VM) or CR; reload | Reload only, no outage; note the exact line |
| **Disk/WAL** | pg_wal full from inactive slot | `df -h` 100% on pg_wal; slot `active=f` with huge retained WAL | Drop obsolete slot; set `max_slot_wal_keep_size`; never rm WAL | Dropping a needed slot breaks that replica — verify first |
| **Slot** | leftover slot from removed replica | `pg_replication_slots` inactive, restart_lsn far behind | `pg_drop_replication_slot('name')` after confirming unused | Confirm no live consumer before drop |
| **Patroni** | daemon stopped/killed on a node | `patronictl list` node missing/stopped; `systemctl status patroni` inactive | `systemctl start patroni` (on a *replica* it's safe); if it was primary, cluster already failed over | On primary, starting brings it back as replica; explain expected role change |
| **etcd/DCS** | one member stopped | `etcdctl endpoint health` one unhealthy but quorum holds; or NOSPACE alarm | Restart member / compact+defrag+disarm; restore quorum | If 2/3 down, no writes anywhere — highest priority |
| **HAProxy** | wrong backend / stale `/master` path | writes hit a replica (read-only errors); stats page shows wrong UP node | Fix `httpchk` path to `/primary`, reload HAProxy | Reload is graceful; justify |
| **Query** | pathological query, no index | one query dominating `pg_stat_statements`; Seq Scan in EXPLAIN | `CREATE INDEX CONCURRENTLY`; rewrite | Concurrently = no lock; note build time |
| **Kernel** | THP on / overcommit 0 / high dirty ratios | `/sys/.../transparent_hugepage`=[always]; sysctl values | `sysctl -w` + persist in `/etc/sysctl.d/`; THP via tuned/grub | THP change may need restart to fully clear; document |
| **shared_buffers** | oversized → OOM / won't start | postmaster OOM in dmesg/log; pod OOMKilled | Lower via `ALTER SYSTEM`/CR; restart | Restart required (postmaster context) — justify short outage or rolling |
| **Bloat/vacuum** | large unvacuumed table | high `n_dead_tup`, stale `last_autovacuum`, wraparound age climbing | `VACUUM (ANALYZE)` / `VACUUM FREEZE`; tune autovacuum per-table | VACUUM is online; FREEZE heavier I/O — schedule/justify |
| **Replica** | diverged/broken standby | different TL, `start failed`, won't stream | `patronictl reinit <cluster> <member>` | Reinit rebuilds from primary — I/O + time; justify |

**General reasoning to show:** always identify the *customer-visible* impact first (is the app down, degraded, or fine?), triage by priority, take a config backup, make the minimal safe change, verify, and communicate any restart/outage before doing it.

---

# PART 6 — CONSULTANT REPORT-WRITING FRAMEWORK

A consultant report emphasizes that the **process and reasoning matter more than the specific tools/commands**, and that independent problem-solving and clear written English communication are core criteria. An audit should be written as if to a paying customer, detailing findings and prioritized suggestions.

## 6.1 Report structure

Address it to the customer. For each task: what was requested → what was found (with evidence/numbers) → what was done (exact before/after values) → why (rationale with numbers) → verification → what was NOT done and why → recommendations → risks & any outage justification.

## 6.2 Template skeleton (adapt live)

```
Dear Customer,

EXECUTIVE SUMMARY
- 2–4 sentences: environment type discovered, headline findings, what was fixed,
  current health status, top residual risks.

ENVIRONMENT OVERVIEW (topology discovered)
- Deployment model: <bare VM | VM Patroni/etcd/HAProxy | K8s operator: Percona/CNPG/…>
- Nodes/pods, roles, PostgreSQL version, instance type/resources, storage (EBS type).
- How HA/failover and backups are implemented (Patroni + DCS; pgBackRest stanza).

TASKS PERFORMED  (repeat per task)
  Task N: <title>
   - Request:        <what the customer asked>
   - Findings:       <evidence: command output, query result, metric>
   - Actions:        <exact change: param old→new, file, method (reload vs restart)>
   - Verification:   <query/command proving success>
   - Rollback plan:  <how to revert; backup file path/timestamp>
   - Impact/risk:    <outage? justified? expected performance effect>

ISSUES ENCOUNTERED & RESOLUTIONS
- Anything unexpected, how diagnosed, how resolved or worked around.

RECOMMENDATIONS (prioritised)
- P1/P2/P3 follow-ups with rationale and thresholds.

APPENDIX
- Commands run, key outputs, config diffs, scratch-log excerpts.

Kind regards,
Josef Machytka
```

## 6.3 What to document per check (one line each)

- **Parameter change:** old value → new value, context (reload vs restart), method (edit-config/CR/ALTER SYSTEM), verification query, expected impact.
- **Environment discovery:** deployment type, node/pod inventory, versions, roles, DCS, backup tool — the topology map.
- **Linux/kernel:** sysctl before/after, why (workload/RAM figures), persistence (`/etc/sysctl.d/`), whether restart needed.
- **Disk/WAL:** mount, %used before/after, root cause (slot/archive), guard added (`max_slot_wal_keep_size`).
- **Replication fix:** symptom, `pg_stat_replication`/`wal_receiver` evidence, action, post-fix lag.
- **Switchover/restart:** why, method (`patronictl`/CR annotation, not systemctl), which node first, downtime window, verification with `patronictl list`.
- **Query optimisation:** before/after `EXPLAIN` cost+timing, index created (CONCURRENTLY), ANALYZE run.
- **Backup:** stanza status, last backup age, `pgbackrest check` result, any action.

## 6.4 Work Phase Allocation

- **Phase 1: Environment Discovery.** Start session recording or a scratch log. Clarify the scope, constraints, and whether restarts are permitted early.
- **Phase 2: Execution.** Work highest-impact/customer-visible issues first. Before **every** file edit, take a backup: `cp file file.bak.$(date +%F_%H%M%S)`. Log every command and every before/after value as you go to aid report preparation. Flag any restart/outage before doing it, with technical justification.
- **Phase 3: Documentation.** Draft the report from your notes; fill before/after numbers and verification.
- **Phase 4: Review.** Proofread, ensure no task is left unfinished (or explicitly note what remains and why).
- **Throughout:** proactive customer communication — announce risks, confirm assumptions, never restart a production primary silently. If something is out of scope or too risky for the time budget, say so and recommend it as follow-up rather than leaving it half-done.

## Recommendations

1. **First 15 minutes, no exceptions:** run the Part 1 runbook and write down the topology before changing anything. The single biggest risk is acting on a wrong mental model (e.g. editing `postgresql.conf` in an operator-managed pod that reverts it).
2. **Confirm the deployment type, then commit to the matching path:** Assume the Percona Operator (Patroni-based) if it's Kubernetes; otherwise the VM Patroni/etcd/HAProxy stack. Keep the CloudNativePG commands handy only as a fallback.
3. **Always change config through the automation's interface** (CR `dynamicConfiguration` / `patronictl edit-config`), know reload-vs-restart per parameter (`SELECT name,context FROM pg_settings`), and drive restarts replica-first via the tool, never `systemctl restart patroni` on a primary.
4. **Triage by customer-visible impact and justify every outage in advance.** For a "live web application," a read-only cluster or a mis-routed HAProxy is P1; a bloated table or suboptimal kernel setting is P2/P3.
5. **Keep a running scratch log and take timestamped backups before edits** — this is both a best practice and the raw material for the report.
6. **Budget the report explicitly.** A complete, well-structured report covering fewer tasks beats more fixes with no write-up.

**Thresholds that change the plan:**
- If `patronictl list` shows all nodes read-only → stop everything, this is DCS loss (etcd quorum / K8s API); restoring the DCS is the only fix and top priority.
- If a disk is >90% full on pg_wal → find the WAL retention cause (slot/archive) before it hits 100% and stops writes.
- If `age(datfrozenxid)` > 1B → wraparound risk becomes urgent; remove blockers (idle-in-transaction, inactive slots) and run targeted `VACUUM FREEZE`.
- If a postmaster-context parameter must change on the primary → it requires a restart/switchover; schedule and justify rather than doing it silently.

## Caveats

- **Percona's PMM** (Percona Monitoring and Management) is their primary monitoring tool; if a monitoring task appears, PMM is more likely than Nagios today, though the example report referenced Nagios. Be ready for either.
- **Version drift:** commands assume Patroni 3.x/4.x, PostgreSQL 14–17, Percona Operator 2.x. Confirm versions on login (`patronictl version`, `SELECT version()`, `kubectl get pg -o yaml | grep -i version`) since paths and defaults shift (e.g. `pg_stat_bgwriter` checkpoint columns moved to `pg_stat_checkpointer` in PG17; Patroni `/master` → `/primary` in 4.0.x).
- **etcd defrag online is risky** — the official etcd docs note a known issue where etcd "might run into data inconsistency issue if it crashes in the middle of an online defragmentation operation using etcdctl or clientv3 API." Prefer offline `etcdutl defrag` one member at a time. Only do this if etcd NOSPACE is genuinely the staged problem and quorum allows.
- **Destructive operations** (`reinit`, dropping slots, `spec.pause`, cluster deletion with finalizers) can cause data loss or outage — verify and justify before running, and prefer the least destructive option that resolves the customer's issue within the time budget.