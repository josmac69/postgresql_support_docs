# Patroni PostgreSQL HA Field Runbook

**Author target:** Josef Machytka, Senior PostgreSQL Specialist. **Scope:** Patroni 3.x/4.x + etcd v3 DCS. Treat all servers as production; justify every outage in writing. Suggested shell alias for this whole document: `alias patronictl='patronictl -c /etc/patroni/patroni.yml'`.

---

## GLOSSARY

- **DCS** — Distributed Configuration Store (etcd/Consul/ZooKeeper/Kubernetes). Holds cluster state and the leader lock.
- **TTL** — Time To Live. Leader-lock lifetime in DCS. Per Patroni Dynamic Configuration docs, `ttl` "the TTL to acquire the leader lock (in seconds)... Default value: 30, minimum possible value: 20." Lock not renewed within TTL → lock expires → leader race.
- **loop_wait** — Seconds Patroni sleeps between HA cycles (default 10).
- **retry_timeout** — Timeout for DCS/PostgreSQL operation retries (default 10). DCS/network blips shorter than this must NOT demote the leader.
- **Timing rule** — `ttl ≥ 2*(loop_wait + retry_timeout)`. Violating it causes spurious failovers.
- **LSN** — Log Sequence Number. Byte position in the WAL stream.
- **WAL** — Write-Ahead Log (the `pg_wal` directory).
- **HA** — High Availability.
- **REST API** — Patroni's HTTP API (default port 8008).
- **GUC** — Grand Unified Configuration; a PostgreSQL parameter.
- **PITR** — Point-In-Time Recovery.
- **TLI / TL** — Timeline (increments on each promotion).
- **pg_rewind** — Tool to resync a diverged ex-primary without a full basebackup.
- **basebackup** — `pg_basebackup` full clone of a data directory.
- **STONITH** — Shoot The Other Node In The Head (fencing).
- **Watchdog / softdog** — Kernel timer that hard-resets a node if not pinged; last-line split-brain guard.
- **Failsafe mode** — Patroni 3.0+ feature: keep primary up during a DCS outage if it can reach all members via REST.
- **Standby cluster / standby leader** — A cluster that replicates from an external source; its leader is read-only by design.
- **Scope** — Cluster name (a DCS namespace path component).
- **Quorum** — Majority of DCS nodes needed for consensus. 3 nodes → 2; losing 2 = no quorum.
- **VIP** — Virtual IP.
- **Spilo** — Zalando's Patroni+PostgreSQL Docker image.
- **maximum_lag_on_failover** — Max bytes a replica may lag and still be a failover candidate (default `1048576` = 1MB).
- **synchronous_mode / _strict** — Guarantees committed txns survive failover; strict blocks writes when no sync standby exists. `synchronous_mode` values are `off`, `on`, `quorum`.
- **pending_restart** — Flag: a restart-requiring GUC changed but PostgreSQL not yet restarted.

---

## TRIAGE FLOWCHART (start here)

```
WRITES FAILING?
 └─ patronictl list  → is there a Leader with State=running?
     ├─ NO LEADER ──────────────► go to §1 (leaderless). Then check DCS (§9).
     ├─ Leader shown but writes fail?
     │    ├─ curl :8008/primary returns 200 but INSERT says "read-only" ──► standby-cluster/orphan (§18, §20)
     │    ├─ commits hang, no error ──► synchronous_mode blocking (§14)
     │    └─ "read-only": DCS lost + no failsafe (§9, §17)
     ├─ TWO leaders / two nodes answer /primary ──► SPLIT BRAIN (§3) — STOP, fence first
     └─ Leader healthy, a replica is broken ──► §4/§5/§6 (replica states)

CLUSTER "looks" fine but nothing fails over?
 └─ patronictl list footer says "Maintenance mode: on" ──► PAUSED (§10)
 └─ scheduled switchover in footer ──► §8

DCS HEALTH (always verify early):
 ETCDCTL_API=3 etcdctl endpoint health --cluster
 ETCDCTL_API=3 etcdctl endpoint status -w table --cluster
 ETCDCTL_API=3 etcdctl alarm list        # NOSPACE? → §9
```

**First three commands on any Patroni incident:**
```
patronictl list -e                                  # topology + Pending restart column
curl -s http://localhost:8008/cluster | jq .  # authoritative per-node state
ETCDCTL_API=3 etcdctl endpoint health --cluster
```

---

## §1 — No leader / leaderless cluster

**SYMPTOM:** `patronictl list` shows all nodes as Replica or `start failed`; no Leader. Writes fail; `curl :8008/primary` → 503 everywhere.

**LIKELY CAUSES (ranked):**
1. All candidates lag beyond `maximum_lag_on_failover` → nobody eligible.
2. DCS unreachable / leader key can't be acquired (§9).
3. `synchronous_mode` + no eligible sync standby → Patroni refuses to promote.
4. All nodes genuinely down / crashed (disk full §19, start failure §4).
5. Manual failover with a candidate that can't take the lock.

**DIAGNOSIS:**
```
patronictl list -e
curl -s http://localhost:8008/cluster | jq .
journalctl -u patroni -n 200 --no-pager        # look for "following a leader" vs "no action"
ETCDCTL_API=3 etcdctl get /service/<scope>/leader   # empty/absent = no lock held
patronictl history                                    # last timeline events
```
Look for: `following a leader (None)`, `Could not take out TTL lock`, `my wal position exceeds maximum_lag_on_failover`.

**REPAIR:**
- If DCS is the cause → fix DCS first (§9); leader usually re-appears automatically.
- If all replicas lag: pick the node with the highest LSN and force-failover to it (accepts data loss beyond the lagging window):
```
curl -s http://localhost:8008/cluster | jq '.members[]|{name,lsn:.lsn,state}'   # pick highest LSN
patronictl failover <scope> --candidate <highest_lsn_node> --force
```
⚠️ **Destructive:** manual failover in a lagging cluster loses unreplicated transactions. Note that even in a healthy async cluster the RPO is "worst case bounded by `maximum_lag_on_failover` bytes... plus the amount that is written in the last `ttl` seconds (`loop_wait/2` seconds in the average case)" (Patroni Replication modes docs). Document the promoted node's LSN vs. the ex-primary's last LSN to quantify the RPO gap.
- If the cluster is bad and no node starts, restart the *most recent leader first* (per Patroni logs) so unreplicated writes survive.

**PREVENTION:** Keep `maximum_lag_on_failover` realistic; monitor replica lag; use `synchronous_mode` if zero-loss is required but understand the availability trade-off.

---

## §2 — Primary demoted unexpectedly / spurious failovers

**SYMPTOM:** Leader flips with no hardware fault; logs show `demoting self because DCS is not accessible and I was a leader`.

**LIKELY CAUSES:**
1. **Timing rule violation:** `ttl` too small relative to `loop_wait + retry_timeout`, or DCS latency > `retry_timeout`.
2. DCS slow/overloaded (etcd on same disk as PGDATA, fsync latency).
3. Network blips between node and DCS longer than `retry_timeout`.
4. failsafe REST check timing out on high-latency links (§17).

**DIAGNOSIS:**
```
patronictl show-config | grep -E 'ttl|loop_wait|retry_timeout|failsafe'
journalctl -u patroni --since "1 hour ago" | grep -iE 'demot|DCS|timeout|lock'
ETCDCTL_API=3 etcdctl endpoint status -w table --cluster    # check RAFT term churn, DB SIZE
curl -s http://localhost:8008/patroni | jq .dcs_last_seen
```
Per Patroni Dynamic Configuration docs: "Worst case failover time for primary failure is: `loop_wait + primary_start_timeout + loop_wait`, unless `primary_start_timeout` is zero, in which case it's just `loop_wait`." (`primary_start_timeout` default 300s.)

**REPAIR:** Enforce the timing rule and widen tolerances:
```
patronictl edit-config
# set e.g.:  ttl: 30   loop_wait: 10   retry_timeout: 10   (ttl >= 2*(loop_wait+retry_timeout))
# apply, no restart needed for these DCS params
```
⚠️ Increasing `ttl` lengthens the no-leader window during real failures — justify the durability/availability trade-off in the report.

**PREVENTION:** Put etcd on dedicated fast disks separate from PGDATA; monitor etcd fsync/commit latency; keep the timing invariant.

---

## §3 — Split brain (two primaries)

**SYMPTOM:** Two nodes answer `curl :8008/primary` with 200, or `patronictl list` shows two Leaders, or an orphaned ex-primary still accepts writes.

**LIKELY CAUSES:**
1. Patroni process died but PostgreSQL kept running as primary (§20) with no watchdog.
2. Network partition + no watchdog + no failsafe.
3. External process (systemd `postgresql.service`) restarted Postgres outside Patroni.
4. LB-level: HAProxy still routes to a stale node whose `/primary` briefly returns 200.

**DIAGNOSIS (do this before touching anything):**
```
# On every node:
curl -s http://<each-node>:8008/primary -o /dev/null -w "%{http_code}\n"
psql -h <node> -tAc "select pg_is_in_recovery()"   # false = it thinks it's primary
ETCDCTL_API=3 etcdctl get /service/<scope>/leader   # the ONE true leader per DCS
patronictl history                                        # diverged timelines?
```
The node named in `/service/<scope>/leader` is the legitimate primary.

**REPAIR (order matters):**
1. Identify the legit leader from the DCS leader key.
2. **Fence the rogue primary immediately** — stop writes there:
```
# On the ROGUE node:
systemctl stop patroni          # Patroni-managed stop
pg_ctl -D <PGDATA> stop -m fast  # if Postgres still up
```
⚠️ **Destructive / data-loss:** transactions committed only on the rogue primary are lost. Capture them first if possible: `pg_waldump`, compare LSNs, export rows. Document the divergence LSN and estimated lost rows in the report.
3. Rejoin the ex-rogue as a replica via pg_rewind (§7) or reinit (§4).
4. Verify HAProxy: only one backend healthy on the primary (5000) port.

**PREVENTION:** Enable **watchdog/softdog** (§13); never enable systemd `postgresql.service` (Patroni must be the only thing that starts/stops Postgres); enable `failsafe_mode` (§17); use a quorum-correct DCS.

---

## §4 — Replica won't start / "start failed" / "crashed"

**SYMPTOM:** `patronictl list` shows a member `State=start failed` or `crashed`.

**LIKELY CAUSES:**
1. Timeline divergence — replica can't follow new leader (`requested timeline N does not contain minimum recovery point`).
2. Missing/corrupt WAL, corrupted data dir.
3. pg_hba/replication auth failure.
4. Disk full (§19) / permissions (container §16).
5. Stale rogue postmaster PID (§20).

**DIAGNOSIS:**
```
patronictl list -e
journalctl -u patroni -n 100 --no-pager
tail -n 100 <PGDATA>/log/postgresql-*.log       # look for FATAL lines
curl -s http://localhost:8008/patroni | jq .
```
Common FATAL: `requested timeline X does not contain minimum recovery point ... on timeline Y` → divergence; pg_rewind or reinit needed.

**REPAIR:**
- Try Patroni-managed restart first:
```
patronictl restart <scope> <member>
```
- If the timeline diverged and pg_rewind is eligible (§7), Patroni auto-rewinds on the next loop. Otherwise reinitialize (rebuild from leader — **destroys local data dir**):
```
patronictl reinit <scope> <member>
# if stuck in a recover loop:
patronictl reinit <scope> <member> --force
# fetch directly from leader if all replicas failed:
curl -s http://localhost:8008/reinitialize -XPOST -d '{"force":true,"from-leader":true}'
```
⚠️ `reinit` deletes the member's PGDATA and re-clones. On large DBs this is long; document the expected clone duration/outage.

**PREVENTION:** Enable `wal_log_hints`/checksums so pg_rewind works instead of a full reinit; monitor disk; use `create_replica_methods` (pgBackRest) to offload cloning from the leader.

---

## §5 — Replica stuck "creating replica"

**SYMPTOM:** Member sits at `State=creating replica` for a long time.

**LIKELY CAUSES:**
1. basebackup/clone slow on a large DB or slow network.
2. Clone source (pgBackRest/basebackup) failing partway.
3. `clonefrom` tag causing a clone from a busy/wrong node.
4. Disk fills during the clone.

**DIAGNOSIS:**
```
patronictl list                             # watch progress
journalctl -u patroni -f              # "replica has been created using basebackup" on success
du -sh <PGDATA>                        # is it growing?
ls -la /var/log/pgbackrest/           # if using pgBackRest method
top -u postgres                        # pg_basebackup / pgbackrest running?
```

**REPAIR:**
- If genuinely progressing, wait (don't interrupt a 30-min clone at minute 28).
- If stalled/failed, restart the clone:
```
patronictl reinit <scope> <member> --force
```
- Switch to a backup-based method to spare the leader:
```
patronictl edit-config
# postgresql: create_replica_methods: [pgbackrest, basebackup]
```

**PREVENTION:** Use pgBackRest `--delta` restore for reinit; ensure enough disk headroom; set `clonefrom` tags deliberately.

---

## §6 — Replica lagging / stuck "in archive recovery" not streaming

**SYMPTOM:** Replica applies WAL slowly, or `patroni_postgres_in_archive_recovery=1` and `patroni_postgres_streaming=0`.

**LIKELY CAUSES:**
1. Streaming connection failing → falls back to `restore_command` (archive) only.
2. Required WAL missing on the primary (recycled) → replica behind retention.
3. `nostream` tag set.
4. Long `restore_command` recovery being reset by Patroni's ~30s restart loop (issue #3459).
5. Network/auth to primary broken.

**DIAGNOSIS:**
```
psql -h <replica> -xc "select * from pg_stat_wal_receiver"      # empty = not streaming
psql -h <primary> -xc "select * from pg_stat_replication"       # replica listed?
curl -s http://localhost:8008/metrics | grep -E 'archive_recovery|streaming'
tail -n 50 <PGDATA>/log/postgresql-*.log | grep -iE 'stream|restore|recovery'
```

**REPAIR:**
- If WAL is missing on the primary → reinit the replica (§4).
- Fix replication auth in pg_hba (must allow `replication` from the replica IP).
- If streaming should work, restart the replica:
```
patronictl restart <scope> <replica>
```

**PREVENTION:** Configure permanent physical slots or raise `wal_keep_size`/`member_slots_ttl` so WAL is retained while replicas are briefly down.

---

## §7 — pg_rewind fails when ex-primary rejoins

**SYMPTOM:** Ex-primary won't rejoin; logs: `servers diverged at WAL location ... no rewind required` then start fails, or `could not find previous WAL location`.

**LIKELY CAUSES:**
1. `wal_log_hints` off AND data checksums off → pg_rewind impossible.
2. Timeline missing on the new primary (issue #2118) — divergence Patroni can't rewind.
3. WAL back to the divergence point already recycled and no archive (`-c`/`restore_command`).
4. New primary needs a CHECKPOINT post-promote for its control file to reflect the timeline.

**DIAGNOSIS:**
```
pg_controldata <PGDATA> | grep -E 'wal_log_hints|checksum|Latest checkpoint.*TimeLineID'
patronictl history
journalctl -u patroni | grep -i rewind
```
`wal_log_hints setting: off` + `Data page checksum version: 0` → rewind cannot work.

**REPAIR:**
- If rewind is ineligible, the pragmatic fix is reinit (full rebuild):
```
patronictl reinit <scope> <ex_primary> --force
```
- To enable auto-recovery going forward, set `remove_data_directory_on_rewind_failure: true` and/or `remove_data_directory_on_diverged_timelines: true` so Patroni auto-rebuilds when rewind can't run:
```
patronictl edit-config    # postgresql: { use_pg_rewind: true, remove_data_directory_on_diverged_timelines: true }
```
⚠️ These options let Patroni **delete the data directory automatically** — acceptable for replicas, but document it.

**PREVENTION:** Initialize clusters with `initdb: [data-checksums]` and/or `wal_log_hints: on`. Both must be present cluster-wide before you ever need rewind.

---

## §8 — Scheduled switchover nobody knows about

**SYMPTOM:** `patronictl list` footer shows `Switchover scheduled at: <timestamp>`; an unexpected role change is pending.

**DIAGNOSIS:**
```
patronictl list                                    # footer shows scheduled switchover
curl -s http://localhost:8008/cluster | jq .scheduled_switchover
```

**REPAIR — cancel it:**
```
patronictl flush <scope> switchover
# REST equivalent:
curl -s http://localhost:8008/switchover -XDELETE
```

**PREVENTION:** Audit scheduled actions before maintenance windows; document all planned switchovers.

---

## §9 — DCS (etcd) unreachable / quorum loss / NOSPACE

**SYMPTOM:** Cluster read-only; logs `Error communicating with DCS`; `etcdctl` returns `context deadline exceeded`; or writes fail with `mvcc: database space exceeded`.

**LIKELY CAUSES:**
1. etcd quorum lost (2 of 3 members down).
2. NOSPACE alarm — etcd DB exceeded quota. Default quota is **2 GiB** (`--quota-backend-bytes`, etcd v3.3 Maintenance docs); no auto-compaction configured.
3. Network/TLS/cert failure to etcd.
4. etcd on a slow disk → timeouts.

**Patroni DCS key layout** under `/service/<scope>/` (default namespace `/service`): `leader` (leader lock), `initialize` (system-ID marker), `config` (dynamic config JSON), `members/<name>` (per-node state, ephemeral), `failsafe` (failsafe topology), `sync` (sync-replication state), `status` (leader LSN; Patroni ≥ 2.1.0), `optime/leader` (legacy LSN key), `failover` (manual failover request), `history` (timeline events).

### Diagnosis

Run the following commands from **any node** with connectivity to the etcd cluster (ensure `ETCDCTL_API=3` and proper certs/endpoints are passed via parameters or env vars):

```bash
# 1. Check endpoints health
ETCDCTL_API=3 etcdctl --endpoints=https://IP1:2379,https://IP2:2379,https://IP3:2379 endpoint health --write-out=table

# 2. Check cluster status (Raft leader, database size, and revisions)
ETCDCTL_API=3 etcdctl --endpoints=https://IP1:2379,https://IP2:2379,https://IP3:2379 endpoint status --write-out=table

# 3. List configured member IDs and state
ETCDCTL_API=3 etcdctl --endpoints=https://IP1:2379,https://IP2:2379,https://IP3:2379 member list --write-out=table

# 4. Check for active alarms (specifically NOSPACE)
ETCDCTL_API=3 etcdctl --endpoints=https://IP1:2379,https://IP2:2379,https://IP3:2379 alarm list

# 5. Inspect Patroni active cluster keys
ETCDCTL_API=3 etcdctl --endpoints=https://IP1:2379,https://IP2:2379,https://IP3:2379 get --prefix /service/<scope>/
```
*Note:* `context deadline exceeded` indicates a node is unresponsive or has lost connectivity. If `IS LEADER` is `false` for all endpoints, the cluster has no Raft consensus leader.

---

### Step-by-Step Repair Workflows

#### Scenario A: NOSPACE Alarm (etcd Database Quota Exhausted)
When database space exceeds the quota, etcd locks itself to read-only. Compaction alone does NOT shrink the database file size; you **must** run `defrag` to release space. Since `defrag` blocks write and read operations on the target node, you must perform this task in a rolling manner (followers first, leader last).

*   **Step 1: Retrieve the latest revision ID** (Run on **any active etcd member**):
    ```bash
    # Option 1: using jq (preferred)
    rev=$(ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 endpoint status --write-out=json | jq '.[].status.header.revision' | head -1)
    
    # Option 2: grep/sed fallback if jq is missing
    rev=$(ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 endpoint status --write-out=json | grep -oE '"revision":[0-9]+' | head -1 | cut -d: -f2)
    
    echo "Current database revision is: $rev"
    ```
*   **Step 2: Compact the database history** (Run on **any single active etcd member**):
    ```bash
    ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 compact "$rev"
    ```
*   **Step 3: Rolling Defragmentation** (Run locally on **each etcd instance individually**, followers first, leader last):
    1.  Determine the current Raft leader:
        ```bash
        ETCDCTL_API=3 etcdctl --endpoints=https://IP1:2379,https://IP2:2379,https://IP3:2379 endpoint status -w table
        ```
    2.  Execute `defrag` on the **follower instances** (e.g. `node2` and `node3`):
        ```bash
        # Log into follower node2 and run:
        ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 defrag
        
        # Log into follower node3 and run:
        ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 defrag
        ```
    3.  Execute `defrag` on the **leader instance** (e.g. `node1`):
        ```bash
        # Log into leader node1 and run:
        ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 defrag
        ```
*   **Step 4: Disarm the quota alarm** (Run on **any single active etcd member**):
    ```bash
    ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 alarm disarm
    ```
*   **Step 5: Verify health and quota space**:
    ```bash
    ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 endpoint status --write-out=table
    ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 alarm list
    ```

#### Scenario B: Partial Quorum Loss (1 of 3 nodes permanently failed)
If a single member has permanently crashed, the etcd cluster retains a quorum of 2 nodes but lacks redundancy. You must remove the bad member before re-adding a new replacement to prevent the cluster from attempting to contact the dead IP address.

*   **Step 1: Get the Hex ID of the failed member** (Run on **any surviving healthy node**):
    ```bash
    ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 member list
    # Look for the hex ID (e.g., a82a7bb848f70096) of the offline member.
    ```
*   **Step 2: Remove the failed member** (Run on **any surviving healthy node**):
    ```bash
    ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 member remove <hexID>
    ```
*   **Step 3: Add the replacement member configuration** (Run on **any surviving healthy node**):
    ```bash
    ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 member add <new-node-name> --peer-urls=https://<new-node-ip>:2380
    
    # This command outputs environment variables that must be applied to the new node.
    # Note the ETCD_INITIAL_CLUSTER_STATE="existing" and updated ETCD_INITIAL_CLUSTER list.
    ```
*   **Step 4: Configure and start the new node** (Run on the **new etcd node**):
    Update its configuration file (`/etc/etcd/etcd.yml` or `/etc/default/etcd`) using the output variables. Crucially set:
    - `initial-cluster-state: 'existing'`
    - Include the new node in the `initial-cluster` line.
    ```bash
    # Start the service
    sudo systemctl daemon-reload
    sudo systemctl start etcd
    ```
*   **Step 5: Verify the member list**:
    ```bash
    ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 member list --write-out=table
    ```

#### Scenario C: Total Quorum Loss (2 of 3 nodes permanently failed / majority lost)
When a majority of nodes are permanently lost, etcd cannot establish a quorum to process writes. The remaining node is locked. You must recover by backing up the surviving node's database and forcing a new, single-member cluster.

*   **Step 1: Backup database on the surviving instance** (Run on the **surviving node**, e.g., `node1`):
    ```bash
    sudo systemctl stop etcd
    ETCDCTL_API=3 etcdctl snapshot save /var/lib/etcd/backup.db
    ```
*   **Step 2: Re-initialize as a new single-node cluster** (Run on the **surviving node**, e.g., `node1`):
    Use `snapshot restore` with the `--force-new-cluster` flag.
    ```bash
    # Restore metadata to a clean path
    ETCDCTL_API=3 etcdctl snapshot restore /var/lib/etcd/backup.db \
      --name node1 \
      --initial-cluster node1=https://<node1-ip>:2380 \
      --initial-advertise-peer-urls https://<node1-ip>:2380 \
      --data-dir /var/lib/etcd/new.etcd
      
    # Swap the old directory with the newly restored one
    sudo rm -rf /var/lib/etcd/member
    sudo mv /var/lib/etcd/new.etcd/member /var/lib/etcd/
    sudo chown -R etcd:etcd /var/lib/etcd/member
    ```
*   **Step 3: Start the service and verify** (Run on the **surviving node**, e.g., `node1`):
    ```bash
    sudo systemctl start etcd
    ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 member list --write-out=table
    ```
*   **Step 4: Add new members** (Run on **node1**):
    Once `node1` is operating as the cluster leader, follow the steps in **Scenario B** to join the newly provisioned `node2` and `node3` hosts (having stopped `etcd` and wiped `/var/lib/etcd/member/*` on those hosts before joining).

⚠️ **WARNING:** Restoring with `--force-new-cluster` overwrites membership history. Verify metadata values before applying. If a total DCS loss occurs, Patroni will rebuild `/config` from local `patroni.dynamic.json` configurations stored in `PGDATA`.

---

### Alternative DCS Backends reference

While `etcd` is the standard DCS backend, you may encounter deployments utilizing Consul, ZooKeeper, or native Kubernetes resources.

#### 1. HashiCorp Consul
Consul stores cluster configurations under key-value prefixes (default: `service/<scope>/`).

*   **View Members & Node Health**:
    ```bash
    consul members
    consul monitor
    ```
*   **Inspect Patroni Metadata**:
    ```bash
    # Recursively view all keys under the cluster scope
    consul kv get -recurse service/<scope>/
    
    # View the current cluster configuration JSON
    consul kv get service/<scope>/config
    ```
*   **Clear/Reset Cluster State (Emergency purge)**:
    If nodes are stuck or configurations are corrupted, stop all Patroni services and delete the KV path:
    ```bash
    consul kv delete -recurse service/<scope>/
    ```
*   **HTTP API Fallbacks (If consul CLI is missing)**:
    ```bash
    # Read Keys
    curl -s http://127.0.0.1:8500/v1/kv/service/<scope>/?recurse | jq .
    
    # Delete Keys
    curl -s -X DELETE "http://127.0.0.1:8500/v1/kv/service/<scope>/?recurse"
    ```

#### 2. Apache ZooKeeper
ZooKeeper stores Patroni cluster metadata under hierarchical znodes (default: `/service/<scope>`).

*   **Access the ZooKeeper CLI**:
    ```bash
    /usr/share/zookeeper/bin/zkCli.sh -server 127.0.0.1:2181
    ```
*   **CLI Commands for Patroni Inspection**:
    ```text
    # List active nodes (members, leader, sync)
    ls /service/<scope>
    ls /service/<scope>/members
    
    # Read the current leader lock owner
    get /service/<scope>/leader
    ```
*   **Delete Keys / Force Demotion**:
    ```text
    # Force delete the leader lock node (triggers demotion/failover)
    delete /service/<scope>/leader
    
    # Recursively wipe all Patroni cluster configurations
    deleteall /service/<scope>
    ```
    *Note:* On old ZooKeeper versions, use `rmr /service/<scope>` in place of `deleteall`.

#### 3. Kubernetes API (endpoints or configmaps)
In Kubernetes deployments, Patroni uses Kubernetes native resources to store leader locks and dynamic configurations via metadata annotations. It runs in either `Endpoints` (recommended) or `ConfigMap` mode.

*   **Inspect Leader Locks & Annotations**:
    ```bash
    # If using Endpoints mode:
    kubectl get endpoints <scope> -n <namespace> -o yaml
    
    # If using ConfigMap mode:
    kubectl get configmap <scope> -n <namespace> -o yaml
    ```
*   **Extract Leader Annotation Directly**:
    ```bash
    kubectl get endpoints <scope> -n <namespace> -o jsonpath='{.metadata.annotations.leader}'
    ```
*   **Reset/Clear Cluster Metadata**:
    Deleting the resource clears the DCS metadata and forces Patroni to perform auto-discovery and config recreation on service boot.
    ```bash
    # Stop/scale down all postgres pods to 0 first!
    kubectl scale statefulset <postgresql-statefulset> --replicas=0 -n <namespace>
    
    # Delete the DCS resource
    kubectl delete endpoints <scope> -n <namespace>
    # Or:
    kubectl delete configmap <scope> -n <namespace>
    
    # Scale back up to restart the cluster
    kubectl scale statefulset <postgresql-statefulset> --replicas=3 -n <namespace>
    ```

---

**PREVENTION:** 3 or 5 dedicated etcd nodes on fast disks; set `--auto-compaction-retention`; monitor DB size and alarms; enable `failsafe_mode` (§17) so a DCS blip doesn't take the primary read-only.
```

---

## §10 — Cluster paused and forgotten

**SYMPTOM:** No automatic failover; `patronictl list` footer shows `Maintenance mode: on`; logs say `PAUSE: no action`.

**DIAGNOSIS:**
```
patronictl list                                    # footer "Maintenance mode: on"
curl -s http://localhost:8008/patroni | jq .pause
```

**REPAIR:**
```
patronictl resume --wait
```
Verify failover works again with `patronictl list`.

**PREVENTION:** Always `pause --wait` before maintenance and `resume --wait` after; alert on `patroni_is_paused=1` for longer than the maintenance window.

---

## §11 — pending_restart never applied

**SYMPTOM:** `patronictl list -e` shows `*` in the Pending restart column; a postmaster-context GUC change hasn't taken effect.

**DIAGNOSIS:**
```
patronictl list -e                                 # Pending restart column
psql -xc "select name,setting,pending_restart from pg_settings where pending_restart"
curl -s http://localhost:8008/patroni | jq .pending_restart
```

**REPAIR — rolling restart (replicas first, primary last):**
```
patronictl restart <scope> <replica1>
patronictl restart <scope> <replica2>
patronictl restart <scope> <primary>       # causes a brief blip / possible switchover
# or restart only nodes that need it:
curl -s http://localhost:8008/restart -XPOST -d '{"restart_pending":true}'
```
⚠️ Restarting the primary interrupts writes; schedule and document it. **Never `systemctl restart patroni` on the primary to apply a GUC** — Patroni docs state plainly: "An attempt to restart PostgreSQL by restarting the Patroni daemon, e.g. by executing `systemctl restart patroni`, can cause a failover to occur in the cluster, if you are restarting the primary node." Use `patronictl restart`.

**PREVENTION:** Apply restart-requiring changes during maintenance windows; use `patronictl restart`, not systemd, to avoid unintended failovers.

---

## §12 — System ID mismatch ("belongs to a different cluster")

**SYMPTOM:** Patroni exits: `CRITICAL: system ID mismatch, node <x> belongs to a different cluster: <A> != <B>`.

**LIKELY CAUSES:**
1. Wrong restore (e.g. a PROD backup restored into a cluster whose DCS `initialize` key holds a different system ID).
2. A node reinitialized as a standalone DB rather than cloned from the leader.
3. Stale DCS metadata under a reused scope name.

**DIAGNOSIS:**
```
pg_controldata <PGDATA> | grep "Database system identifier"
ETCDCTL_API=3 etcdctl get /service/<scope>/initialize      # DCS-recorded system ID
```
Compare the two values.

**REPAIR:**
- If the DCS holds stale metadata for a cluster you are replacing, remove it, then let nodes re-clone:
```
systemctl stop patroni        # all nodes
patronictl -c /etc/patroni/patroni.yml remove <scope>
# prompts (verbatim from docs):
#   Please confirm the cluster name to remove: <scope>
#   You are about to remove all information in DCS for <scope>, please type: "Yes I am aware": Yes I am aware
#   (if cluster is still healthy) This cluster currently is healthy. Please specify the leader name to continue: <leader>
ETCDCTL_API=3 etcdctl get /service/<scope>/initialize      # should be key-not-found
# start the intended leader first, then reinit replicas
```
⚠️ **Destructive:** `remove` wipes ALL DCS state for the cluster (it does not stop Postgres or delete data). Only do this when you intend to re-establish the cluster. On replicas holding wrong data, remove/rename PGDATA so they re-clone. There is no `--force` for `remove`; the prompts cannot be bypassed.

**PREVENTION:** Use distinct scope names per environment (prod/uat/stage); always clean DCS metadata before reusing a scope; verify system IDs before restoring across environments.

---

## §13 — Watchdog issues (required but device missing / refuses promotion)

**SYMPTOM:** A node refuses to become leader; logs: `Watchdog device is not usable`/`watchdog activation failed`; or `Watchdog not supported because leader TTL N is less than 2x loop_wait`.

**LIKELY CAUSES:**
1. `watchdog.mode: required` but `/dev/watchdog` missing/not writable.
2. softdog module not loaded (blacklisted) or wrong ownership.
3. TTL/loop_wait math invalidates the watchdog safety margin.
4. In containers, `/dev/watchdog` not passed in.

**DIAGNOSIS:**
```
ls -l /dev/watchdog
lsmod | grep softdog
journalctl -u patroni | grep -i watchdog
patronictl show-config | grep -A3 watchdog
```
Background: by default Patroni sets the watchdog to expire 5s before TTL; with `loop_wait=10, ttl=30` this leaves the HA loop ≥15s (`ttl - safety_margin - loop_wait`) before a forced reset.

**REPAIR:**
```
modprobe softdog
chown postgres /dev/watchdog          # user Patroni runs as
# remove any blacklist line:
grep -rl 'blacklist softdog' /etc/modprobe.d/ && sed -i '/blacklist softdog/d' /etc/modprobe.d/*.conf
systemctl restart patroni             # on a REPLICA first, or during maintenance
```
If you must bring a leader up urgently and watchdog can't be fixed, temporarily set `watchdog.mode: automatic` (not `required`) via edit-config — **document the reduced split-brain protection**.

**PREVENTION:** Bake `modprobe softdog` + chown into boot (systemd `ExecStartPre=-+/sbin/modprobe softdog` and `ExecStartPre=-+/bin/chown postgres /dev/watchdog`); keep `ttl ≥ 2*loop_wait`; in containers pass `--device /dev/watchdog`.

---

## §14 — Synchronous mode blocking commits

**SYMPTOM:** Commits hang with no error (`wait_event = SyncRep`); writes frozen though the primary is up.

**LIKELY CAUSES:**
1. `synchronous_mode_strict: true` + the sole sync standby is down → the primary blocks ALL writes by design ("blocking all client write requests until at least one synchronous replica comes up").
2. A briefly-reconnected standby left in `synchronous_standby_names` then dropped (issue #3468).
3. `synchronous_node_count` higher than available healthy sync standbys.

Note the non-strict behavior for comparison: "When `synchronous_mode` is on and a standby crashes, commits will block until the next iteration of Patroni runs and switches the primary to standalone mode (worst case delay for writes `ttl` seconds, average case `loop_wait/2` seconds)."

**DIAGNOSIS:**
```
psql -xc "show synchronous_standby_names"
psql -xc "select application_name,sync_state,state from pg_stat_replication"
psql -xc "select pid,wait_event,state from pg_stat_activity where wait_event='SyncRep'"
patronictl show-config | grep -i synchronous
```

**REPAIR:**
- Bring a sync standby back (preferred): fix/reinit the standby (§4).
- Emergency unblock (accepts loss of the strict guarantee): disable strict mode:
```
patronictl edit-config
# synchronous_mode_strict: false      (keep synchronous_mode: true)
```
⚠️ Turning off strict mode means the primary will commit without a sync copy — **document the durability downgrade and the window**.

**PREVENTION:** Run ≥2 sync-eligible standbys; set `synchronous_node_count` ≤ healthy sync standbys; understand strict = availability sacrificed for durability.

---

## §15 — Failed switchover / switchover hangs

**SYMPTOM:** `patronictl switchover` errors or hangs; brief downtime; wrong candidate promoted.

**LIKELY CAUSES:**
1. Candidate lagging / not caught up / tagged `nofailover`.
2. Empty candidate on a 3-node async cluster → picks an async replica (issue #2074).
3. Cluster unhealthy — should have used `failover` not `switchover`.
4. Node names with hyphens/special chars mishandled in sync config (Palark case: PostgreSQL requires hyphenated names quoted).

**DIAGNOSIS:**
```
patronictl list -e
curl -s http://localhost:8008/cluster | jq '.members[]|{name,role,state,lag}'
journalctl -u patroni | grep -iE 'switchover|failover'
```

**REPAIR:**
- Always name the candidate explicitly:
```
patronictl switchover <scope> --leader <current_leader> --candidate <target> --force
```
- If the cluster is unhealthy, use failover instead:
```
patronictl failover <scope> --candidate <target> --force
```
- For safe switchover, ensure the target is a Sync Standby first (temporarily set `synchronous_mode` + `synchronous_standby_names='*'`).

**PREVENTION:** Never switchover to a lagging/async node; verify a caught-up sync standby exists; avoid special chars in member names.

---

## §16 — Docker/container (Spilo) issues

**SYMPTOM:** Spilo container crash-loops; `FATAL: data directory "..." has invalid permissions`; or REST/psql unreachable.

**LIKELY CAUSES:**
1. PGDATA volume UID/GID mismatch (postgres inside container ≠ host owner). Perms must be `u=rwx (0700)` or `u=rwx,g=rx (0750)`.
2. `/dev/watchdog` not passed into the container (§13).
3. Port 8008 (REST) or 5432 not published.
4. No restart policy → the container doesn't come back.
5. Spilo cloud-provider probe to `169.254.169.254` hangs → set `SPILO_PROVIDER=local`.

**DIAGNOSIS:**
```
docker logs <container> --tail 100
docker exec <container> ls -la /home/postgres/pgdata/pgroot/data
docker exec <container> id
docker inspect <container> --format '{{json .HostConfig.RestartPolicy}}'
docker port <container>
```

**REPAIR:**
```
# fix volume ownership/perms to match container's postgres UID:
docker exec -u root <container> chown -R postgres:postgres /home/postgres/pgdata/pgroot/data
docker exec -u root <container> chmod 700 /home/postgres/pgdata/pgroot/data
# run with correct publish/devices/restart:
docker run -d --restart=unless-stopped -p 8008:8008 -p 5432:5432 --device /dev/watchdog ... spilo
```
⚠️ Don't `chmod 777`; PostgreSQL rejects loose perms. Match the UID rather than widening perms.

**PREVENTION:** Use named volumes; pin UID/GID; publish 8008+5432; set a restart policy; pass `/dev/watchdog`; `SPILO_PROVIDER=local` off-cloud.

---

## §17 — DCS failsafe_mode considerations (Patroni 3.0+)

**WHAT IT DOES:** If the leader loses DCS but can reach **all** members via `POST /failsafe`, it keeps running as primary instead of demoting to read-only. Prevents needless outages during short DCS blips. Behavior without it: "Primary demotes itself to standby when DCS is not reachable, failsafe mode is not active and leader key expires."

**DIAGNOSIS / VERIFY:**
```
patronictl show-config | grep failsafe
curl -s http://localhost:8008/patroni | jq '.failsafe_mode_is_active, .dcs_last_seen'
ETCDCTL_API=3 etcdctl get /service/<scope>/failsafe
```

**ENABLE:**
```
patronictl edit-config      # add:  failsafe_mode: true   (global dynamic config only)
```

**CAVEATS (call out in report):**
- Primary must reach **ALL** members (not quorum) — one unreachable replica → primary still demotes.
- The failsafe REST check uses a **hardcoded 2s timeout** (issue #3550): "The `POST /failsafe` check in `call_failsafe_member()` uses a hardcoded `timeout=2`, so with e.g. 5s of network latency the TCP handshake times out" — so on stretched/high-latency links (>2s) the primary demotes anyway even though replicas are healthy.
- Auth must be consistent — if one node needs REST auth that others don't send (`no auth header received`), the failsafe check fails and the primary demotes.
- Ensure **all members run the same up-to-date Patroni version** before enabling.

**PREVENTION:** Enable on clusters where short DCS outages shouldn't cause read-only; test it by killing DCS in staging.

---

## §18 — Standby cluster confusion (standby leader is read-only by design)

**SYMPTOM:** The "leader" of a standby cluster rejects writes; `curl :8008/standby-leader` → 200; apps expecting writes fail.

**KEY POINT:** A **standby cluster** replicates from an external source; its **standby leader is intentionally read-only**. This is not a fault.

**DIAGNOSIS:**
```
patronictl list                                    # Role shows "Standby Leader"
curl -s http://localhost:8008/cluster | jq .
curl -s http://localhost:8008/standby-leader -o /dev/null -w "%{http_code}\n"   # 200 = healthy standby leader
psql -tAc "select pg_is_in_recovery()"       # true — expected for a standby leader
```

**REPAIR:** If this cluster is *supposed* to be a live primary (misconfiguration), remove the standby config and let it promote:
```
patronictl edit-config     # remove the standby_cluster / standby section
```
Otherwise no repair — route writes to the real source cluster. For Zalando-operator standby clusters, align secrets with the source or the standby won't start and WAL piles up on the standby leader.

**PREVENTION:** Document which clusters are standby clusters; point HAProxy `/standby-leader` health checks appropriately; don't expect writes on a standby leader.

---

## §19 — Disk full on PGDATA or pg_wal

**SYMPTOM:** PostgreSQL PANICs `could not write to file ... No space left on device`; node crashes; replicas stop applying.

**LIKELY CAUSES:**
1. WAL accumulation from an inactive replication slot (replica down, slot retaining WAL).
2. `archive_command` failing → WAL not recycled.
3. Long transaction / large restore generating WAL faster than recycle.

**DIAGNOSIS:**
```
df -hP <PGDATA> <pg_wal mount>
du -sh <PGDATA>/pg_wal
psql -xc "select slot_name,active,restart_lsn,pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn)) retained from pg_replication_slots"
tail -n 50 <PGDATA>/log/postgresql-*.log | grep -iE 'space|archive'
```

**REPAIR (buy space, then fix the root cause):**
```
# 1. Free a little space to start Postgres (pre-placed dummy file, or clear old logs):
rm <PGDATA>/log/old-file.log
# 2. Fix the failing archive_command; verify WAL recycles.
# 3. If an inactive slot is the culprit and its owner is gone:
psql -c "select pg_drop_replication_slot('<slot_name>')"   # only if that replica will be reinit'd
```
⚠️ Dropping a slot that a recoverable replica still needs forces a reinit of that replica. Never `rm` WAL files by hand from `pg_wal` — use `pg_archivecleanup` only when certain.

**PREVENTION:** Alert on disk at 70/85%; use `member_slots_ttl`; keep a pre-created dummy ballast file in `pg_wal` for emergencies; monitor `archive_command` success.

---

## §20 — Patroni process dead but PostgreSQL still running (orphan)

**SYMPTOM:** `patronictl list` can't reach a node / shows it stale; but `ps` shows postmaster running; HAProxy may still route to it.

**LIKELY CAUSES:**
1. Patroni crashed (OOM, bug, killed) leaving Postgres up.
2. Rogue old postmaster (`Process NNN is not postmaster, too much difference between PID file start time`).

**DIAGNOSIS:**
```
systemctl status patroni
ps aux | grep -E 'patroni|postgres: '
curl -s http://localhost:8008/patroni      # connection refused = Patroni down
psql -tAc "select pg_is_in_recovery()"     # is this orphan a primary?
```

**REPAIR:**
- If this orphan is a **primary** and DCS has already elected a new leader → **split-brain risk** (§3): fence this Postgres first, then restart Patroni:
```
pg_ctl -D <PGDATA> stop -m fast
systemctl start patroni
```
- If the DCS leader is still this node, just restart Patroni:
```
systemctl start patroni
```
- Kill a stale postmaster blocking startup only after confirming it's not serving clients.

**PREVENTION:** Enable watchdog (§13); run Patroni under systemd with `Restart=on-failure`; monitor `up{job=patroni}`.

---

## §21 — Timeline divergence after failover

**SYMPTOM:** Rejoining node: `requested starting point ... is ahead of the WAL flush position` or `highest timeline N of the primary is behind recovery timeline M`.

**DIAGNOSIS:**
```
patronictl history                         # timeline events + LSNs
pg_controldata <PGDATA> | grep TimeLineID
cat <PGDATA>/pg_wal/*.history | tail
```

**REPAIR:** pg_rewind (§7) if eligible, else reinit:
```
patronictl reinit <scope> <member> --force
```

**PREVENTION:** `wal_log_hints`/checksums on; enable `remove_data_directory_on_diverged_timelines`; avoid double failovers by fixing DCS/timing (§2).

---

## §22 — Config precedence & edit-config not taking effect

**SYMPTOM:** You changed a param but nothing happened.

**PRECEDENCE (highest → lowest):**
1. `PATRONI_*` **environment variables** (and `PATRONI_CONFIGURATION`, which overrides everything — "any other environment variables will not be considered").
2. **Local `patroni.yml`** (`postgresql.parameters` here take precedence over dynamic config for that node; reload via SIGHUP/`/reload`).
3. **Dynamic config in DCS** (`patronictl edit-config`) — the cluster-wide source of truth.
4. `bootstrap.dcs` in YAML — **only used at first init; ignored forever after**: "Once Patroni has initialized the cluster for the first time... all future changes to the `bootstrap.dcs` section of the YAML configuration will not take any effect!"

**Key trap:** editing `bootstrap.dcs` in `patroni.yml` on a running cluster does nothing. Use `edit-config`.

**DIAGNOSIS:**
```
patronictl show-config                              # effective DCS dynamic config
curl -s http://localhost:8008/config | jq .
psql -xc "select name,setting,source,pending_restart from pg_settings where name='<guc>'"
```

**REPAIR:**
```
patronictl edit-config                              # change dynamic config
patronictl reload <scope>                           # apply reloadable changes
# restart-requiring GUCs → §11
```
If a local `patroni.yml` `postgresql.parameters` entry is overriding your DCS change, remove it there and reload.

**PREVENTION:** Manage GUCs in one place (DCS via edit-config); reserve local YAML for node-specific/connection settings.

---

## §23 — Certificate / authentication failures (member ↔ member, or ↔ DCS)

**SYMPTOM:** `patronictl` fails with SSL errors; failover/failsafe checks fail; `no auth header received`; etcd calls fail with cert errors; mixed HTTP/HTTPS causes patronictl failures.

**LIKELY CAUSES:**
1. Mixed HTTP/HTTPS across nodes' REST APIs ("Mix and match of protocols can result in patronictl failures").
2. Different REST basic-auth credentials across nodes → cross-node calls fail.
3. `verify_client: required` (mTLS) without valid client certs for patronictl/HAProxy.
4. etcd TLS: missing/expired `--cacert/--cert/--key`.

**DIAGNOSIS:**
```
curl -vk https://localhost:8008/patroni       # TLS handshake / auth
patronictl show-config | grep -A5 -iE 'restapi|authentication|ctl'
journalctl -u patroni | grep -iE 'ssl|cert|auth|verify'
ETCDCTL_API=3 etcdctl --cacert=... --cert=... --key=... endpoint health
```

**REPAIR:**
- Standardize protocol + credentials cluster-wide (all HTTP or all HTTPS; same REST user/pass — "it is safe to use the same credentials across all nodes").
- For mTLS, provide `PATRONI_CTL_CERTFILE/KEYFILE/CACERT` so patronictl and members authenticate.
- Renew expired certs; restart Patroni on a replica first.

**PREVENTION:** Automate cert rotation with alerts before expiry; keep REST auth identical across nodes; test the failsafe auth path before relying on it (§17).

---

## §24 — Patroni after a major PostgreSQL upgrade

**SYMPTOM:** After a major PG upgrade, replicas fail to start/bootstrap: `pg_basebackup: incompatible server version`, or the leader upgraded but replicas are stuck.

**LIKELY CAUSES:**
1. Leader on the new major version; replicas still trying to clone with old binaries.
2. `bin_dir` still points to the old version.
3. Data dir left on the old catalog version.

**DIAGNOSIS:**
```
patronictl list
psql -tAc "show server_version"
pg_controldata <PGDATA> | grep "Catalog version"
journalctl -u patroni | grep -iE 'incompatible|version'
```

**REPAIR (typical: leader upgraded in place, rebuild replicas on new version):**
```
# point Patroni at new binaries (bin_dir) on the replica, then:
patronictl reinit <scope> <replica> --force
```
For Spilo/operator, set the new `PGVERSION` and let the in-place upgrade script run from the primary pod; replicas reinit into the new cluster.
⚠️ Major upgrades are high-risk — take a verified backup first; document downtime and a rollback plan.

**PREVENTION:** Use a tested upgrade runbook (pg_upgrade or Spilo in-place); upgrade Patroni to ≥3.1 before jumping to 4.x; keep `bin_dir`/PATH consistent.

---

## PATRONI 3.x vs 4.x — troubleshooting-relevant differences

- **master → primary terminology.** 4.x completes the rename. Callback scripts get `role=primary` (not `master`). On Kubernetes, the default role label is now `primary` (set `kubernetes.leader_label_value: master` to keep old behavior and avoid downtime/migration). Use endpoint `/primary`.
- **`patronictl failover --leader` removed** (deprecated since 3.2). Use `--candidate`; for switchover use `--leader`.
- **`bootstrap.users` section removed** (deprecated 3.2).
- **`patronictl scaffold` and `patronictl configure` removed.**
- **RAFT DCS deprecated** (since 3.0) — avoid for new deployments; migrate to etcd. Known issues remain around removing raft nodes.
- **Quorum-based synchronous replication** — Patroni supports it starting from PostgreSQL v10, exposed as `synchronous_mode: quorum` (values: `off`, `on`, `quorum`); it reduces worst-case latency and picks a failover candidate based on the latest received transaction.
- **failsafe_mode** available since 3.0 (§17); improved etcd3 exception handling for failsafe in 4.0.x ("Patroni was not always properly handling etcd3 exceptions, which resulted in failsafe mode not being triggered").
- **Upgrade path:** to reach 4.x reliably, run **≥3.1.0** first. Direct jumps from older versions may misbehave if the primary fails mid-upgrade with mixed versions.
- **etcd v2 vs v3 keys are not interchangeable** — "Keys created with protocol version 2 are not visible with protocol version 3 and the other way around." Ensure `ETCDCTL_API=3` matches the `etcd3:` config section.

---

## APPENDIX — command & endpoint cheat sheet

**patronictl:** `list [-e]`, `show-config`, `edit-config`, `history`, `restart <c> <m>`, `reinit <c> <m> [--force]`, `switchover <c> --leader <l> --candidate <t> [--scheduled TS] [--force]`, `failover <c> --candidate <t> --force`, `pause [--wait]`, `resume [--wait]`, `reload <c>`, `flush <c> switchover|restart`, `remove <c>`.

**REST API (port 8008):** GET `/patroni` `/cluster` `/config` `/history` `/metrics` `/health`; role health GETs returning 200 only when applicable: `/primary` `/replica` `/read-only` `/standby-leader` `/synchronous` (and `/replica?lag=<max-lag>`); POST `/switchover` `/failover` `/restart` `/reload` `/reinitialize` `/failsafe`; DELETE `/switchover` `/restart`; PATCH/PUT `/config`.

**etcdctl v3:** prefix every command with `ETCDCTL_API=3` (or export it) — `endpoint health --cluster`, `endpoint status -w table --cluster`, `member list -w table`, `member remove <id>`, `alarm list`, `alarm disarm`, `compact <rev>`, `defrag --cluster`, `get --prefix /service/<scope>/`.

**Always in the incident report:** what you observed, the DCS leader-key value, LSNs before/after, the exact command you ran, the justification for any outage/data-loss, and prevention follow-ups.

---

## RECOMMENDATIONS (staged, decision-ready)

**Pre-incident checklist:**
1. Set `alias patronictl='patronictl -c /etc/patroni/patroni.yml'` and confirm the config path/scope with `patronictl list`.
2. Note the real `scope`, DCS type, and etcd endpoints (with any TLS cert flags) — you will need them during incident resolution.
3. Verify baseline health: `patronictl list -e`, `curl -s :8008/cluster | jq`, `ETCDCTL_API=3 etcdctl endpoint health --cluster`.

**During any incident (fixed order):**
1. **Observe** — run the "first three commands" (triage box). Do NOT act on `patronictl list` alone; corroborate with `/cluster` and the DCS leader key.
2. **Classify** via the flowchart: writes-failing vs. replica-broken vs. nothing-failing-over.
3. **Fence before you fix** any suspected split brain (§3/§20) — stopping a rogue primary is always safe relative to letting two primaries diverge.
4. **Prefer least-destructive repair:** `restart` → `reload` → targeted `reinit` → `failover`/DCS rebuild. Escalate only when the cheaper action is proven insufficient.
5. **Write it down as you go:** observed symptom, DCS leader value, LSNs, command run, and the justification for any outage or data loss.

**Thresholds that change the action:**
- Replica lag **≤ `maximum_lag_on_failover` (1MB)** → safe automatic/switchover candidate; **above it** → only manual `failover --force` with documented RPO.
- etcd **quorum present** → `member remove` to heal; **quorum permanently lost (2/3 down)** → snapshot-restore `--force-new-cluster` (major outage, needs sign-off).
- DCS blip **< retry_timeout** → no action, self-heals; **sustained** → failsafe keeps primary up only if it reaches ALL members within 2s.
- pg_rewind eligible (`wal_log_hints`/checksums on) → let Patroni rewind; **ineligible** → `reinit` (full rebuild).
- Primary restart needed for `pending_restart` → do it **in a maintenance window via `patronictl restart`**, never `systemctl restart patroni`.

**Post-incident hardening:** enable watchdog everywhere; enforce the timing rule; put etcd on dedicated fast disks with auto-compaction; enable `failsafe_mode` after version-aligning all nodes; initialize with checksums + `wal_log_hints`; disable systemd `postgresql.service`.

---

## CAVEATS

- **Version drift:** Command flags and defaults verified against Patroni 4.1.x docs and etcd v3.x. On 3.x clusters, confirm `/primary` vs `/master` endpoints and that `patronictl failover --leader` is unavailable (removed in 4.x). Always `patronictl show-config` to see *this* cluster's live values rather than trusting defaults.
- **Namespace/scope are configurable:** all `etcdctl` key paths assume the default namespace `/service`; confirm the actual `namespace` and `scope` from `patroni.yml` before running `get --prefix`.
- **etcd disaster-recovery flags** (`--force-new-cluster`, snapshot restore) are etcd-version-dependent; verify against your etcd version's official disaster-recovery guide before running in production. The `member remove` + snapshot-restore recovery for total quorum loss is corroborated by vendor docs (Rancher, Red Hat, Broadcom) rather than a single primary source.
- **failsafe 2s timeout** (§17) is drawn from open GitHub issue #3550 and reflects current behavior on stretched clusters; treat it as a known limitation, not documented tunable behavior.
- **Destructive commands** (`reinit`, `patronictl remove`, `pg_drop_replication_slot`, `--force-new-cluster`, dropping strict sync) can cause data loss or extended outage. In a production environment, every one of these requires a written justification, an estimated RPO/RTO, and ideally a verified backup taken first.
- **Container specifics** (§16) are Spilo/Zalando-operator oriented; plain Docker/Kubernetes deployments may differ in paths (`/home/postgres/pgdata/pgroot/data` vs `/var/lib/postgresql/data`) and user (postgres UID 999 vs 101) — check `docker exec id` and the image's PGDATA.
- This is a **field runbook, not a design document**: it optimizes for fast, safe recovery under time pressure. For architecture decisions (node counts, DC topology, sync policy) consult the full Patroni docs and post-mortems referenced by scenario.