# pg_env_triage.sh — Cheat Sheet

**Purpose:** Rapid, read-only environment identification and health triage that auto-discovers the PostgreSQL deployment architecture (native VM, Docker, or Kubernetes) and audits host, kernel, HA-stack, and database parameters.

**Usage:**
```bash
./pg_env_triage.sh
./pg_env_triage.sh | tee triage_report.log
```
- **Privileges:** Takes no flags or arguments. Runs as a normal user and auto-detects passwordless `sudo` (`sudo -n`); without it, privileged checks (`ss -tlnp`, `dmesg`, `journalctl -u patroni`, `sudo -u postgres psql`, `du` on `pg_wal`, root-only kubeconfigs, HAProxy stats socket) are skipped or degraded rather than failing.
- **Read-only:** Yes — only queries state and never installs, modifies, or fails over anything. Takes one live 1-second `mpstat` CPU sample; otherwise no benchmarking. Ends by confirming nothing was modified.

## What it tests
- **System identity** — OS family (Debian/RHEL), kernel, CPU cores, memory, load average, and EC2 instance type/AZ.
- **Process & port fingerprint** — presence of postgres, patroni, etcd, consul, zookeeper, haproxy, keepalived, pgbouncer, kubelet/k3s, containerd/dockerd/crio, and their listening ports.
- **Kubernetes** — cluster reachability, node readiness, PG operator flavor (Percona v2, Crunchy PGO, CloudNativePG, Zalando, StackGres), unhealthy pods, OOMKilled restarts, PVC bind status.
- **Docker** — running containers, Patroni leader identity via REST API, etcd/HAProxy containers.
- **Patroni & DCS** — REST API role/state/timeline, pause mode, `patronictl list` health, timeline divergence, lag, leader-lock loss, etcd endpoint health/alarms/raft leader, Consul membership.
- **Load balancing layer** — HAProxy config and runtime backend states, keepalived VIP location, pgbouncer presence.
- **PostgreSQL** — recovery role, connections vs `max_connections`, idle-in-transaction and long-running queries, replication lag and slot WAL retention, archiver failures, XID wraparound age, dead-tuple/vacuum backlog, checkpoints, memory GUCs, `pg_wal` size.
- **pgBackRest** — stanza status and existence of valid backups.
- **Linux health** — disk and inode usage, swap usage, `vm.overcommit_memory`/`swappiness`/`dirty_ratio`, THP state, dmesg OOM events, CPU steal/iowait, failed systemd units.
- **Verdict** — classifies the environment (K8s+operator, Docker Patroni, VM Patroni, plain VM, LB/DCS node) and prints flagged issues, next steps, and suggested follow-up commands.

## How it tests
- Parses `/etc/os-release` for OS family; reads `nproc`, `free`, `uptime`, `uname`.
- EC2 detection via `curl -s -m 3` to `169.254.169.254` (IMDSv2 token, then metadata) with sanity checks on the response.
- Process fingerprint from `ps -eo pid,user,comm,args` grepped per service; listening ports from `ss -tlnp` (fallback `netstat -tlnp`).
- Kubernetes via `kubectl` / `k3s kubectl` with kubeconfig discovery (`~/.kube/config`, `/etc/kubernetes/admin.conf`, `/etc/rancher/k3s/k3s.yaml`); `get nodes/crd/pods/pvc`, jsonpath for `restartCount` and `lastState.terminated.reason`; `crictl ps` fallback on workers.
- Docker via `docker ps` and `docker exec` into containers calling Patroni REST API (`:8008/patroni`, `/cluster`), `patronictl list`, and scanning `docker logs`.
- Native Patroni via `curl localhost:8008`, `patronictl -c <config> list`, and `journalctl -u patroni` grep for `failed to update leader lock`.
- DCS via `etcdctl` (`ETCDCTL_API=3`) `endpoint health`/`endpoint status -w table`/`alarm list`, and `consul members`.
- HAProxy by grepping `haproxy.cfg` for `/master` and querying the stats socket with `socat` (`show stat`); keepalived VIP from `ip -brief addr`.
- PostgreSQL via a `psql -X` probe (tries docker leader, current user, then `sudo -u postgres`) running catalog queries: `pg_stat_activity`, `pg_stat_replication`, `pg_replication_slots`, `pg_stat_archiver`, `pg_database` (`age(datfrozenxid)`), `pg_stat_user_tables`, `pg_stat_checkpointer` (fallback `pg_stat_bgwriter`), and `SHOW` for memory GUCs; `du -sh` for `pg_wal`.
- pgBackRest via `pgbackrest info`.
- Linux via `df -h` / `df -i`, `free -m`, `sysctl -n`, `/sys/kernel/mm/transparent_hugepage/enabled`, `dmesg -T`, `mpstat 1 1`, and `systemctl --failed`.
- Accumulates findings into `ISSUES`/`NOTES` arrays and prints a verdict with severities (`OK`/`WARN`/`CRIT`/`info`).

## Recommendations
- **K8s nodes not Ready, unhealthy/OOMKilled pods, or PVCs not Bound** → investigate `kubectl describe` and compare memory limits vs `shared_buffers`. *Rationale:* these precede or signal database outages.
- **etcd alarm active (e.g. NOSPACE) or no raft leader** → compact/defrag/disarm etcd. *Rationale:* DCS writes are blocked, so Patroni loses its leader lock and demotes the primary to read-only.
- **`failed to update leader lock` in Patroni logs** → fix DCS connectivity. *Rationale:* the primary demotes itself to read-only when it cannot renew the lock.
- **HAProxy health-check uses `/master`** → change the check path to `/primary`. *Rationale:* the `/master` endpoint was deprecated and removed in Patroni 4.x.
- **Inactive replication slot retaining >1GB WAL** → verify and drop obsolete slots. *Rationale:* inactive slots pin WAL, growing `pg_wal` until the disk fills. (Slots with `wal_status` lost/unreserved are also flagged.)
- **`datfrozenxid` age >1B (warn >500M)** → run urgent `VACUUM FREEZE`. *Rationale:* avoids transaction-ID wraparound and forced shutdown.
- **`vm.overcommit_memory=0` on a DB host** → set to `2` with an `overcommit_ratio`. *Rationale:* protects the postmaster from the Linux OOM killer.
- **Transparent Huge Pages not disabled** → disable THP. *Rationale:* THP allocation/defrag causes latency stalls and performance degradation for PostgreSQL.
- **`vm.swappiness>10` / `vm.dirty_ratio>15`** → lower swappiness to 1–10 and dirty_ratio to 15 (background 5). *Rationale:* standard tuning to reduce swap and write-stall latency on large-memory DB servers.
- **archive_command currently failing** → fix archiving. *Rationale:* WAL accumulates on disk until archiving recovers.
- **Connections >80% of max, idle-in-transaction >5min, or queries >10min** → address the offending sessions. *Rationale:* connection exhaustion and long transactions block vacuum and hold locks.
- **Disk ≥85% (crit ≥95%), inodes ≥90%, swap >512MB, CPU steal >5%, iowait >20%, OOM events in dmesg, or failed systemd units** → investigate capacity/sizing. *Rationale:* each is an imminent-outage or resource-contention signal for the database host.
