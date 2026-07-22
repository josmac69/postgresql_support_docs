# pg_ha_stack_triage.sh — Cheat Sheet

**Purpose:** Zero-dependency, read-only triage of the entire PostgreSQL high-availability middleware stack — Patroni, etcd, HAProxy, pgBouncer, and keepalived — across both native (systemd/process) and Dockerized deployments.

**Usage:**
```bash
sudo ./pg_ha_stack_triage.sh \
  [--patroni-url http://127.0.0.1:8008] \
  [--etcd http://127.0.0.1:2379] \
  [--pgb-port 6432] \
  [--pgb-user pgbouncer] \
  [--help]
```
(Also honors env vars `PATRONI_URL`, `ETCDCTL_ENDPOINTS`, `PGBOUNCER_USER`, and `PGBOUNCER_PASSWORD`/`PGPASSWORD` for the pgBouncer console.)
- **Privileges:** Runs as a normal user but "runs best with sudo" — it uses passwordless `sudo -n` (when available) to read root/postgres-only configs (`patroni.yml`, `haproxy.cfg`, `pgbouncer.ini`, `keepalived.conf`) and query the HAProxy stats socket; without it, config audits are skipped/limited.
- **Read-only:** Yes — it only queries services, REST APIs, DCS, sockets, and configs. It runs `haproxy -c` (validate-only), read `etcdctl`/`patronictl list`/pgBouncer `SHOW` queries, and never starts, edits, compacts, or restarts anything; all fixes are printed as suggested commands.

## What it tests
- **Component discovery** — which of Patroni, etcd, HAProxy, pgBouncer, keepalived exist, and whether each is native (`host`) or `docker`.
- **Patroni service & role** — process/service state, node role and member `state` (must be running/streaming), config file location.
- **Patroni pause status** — whether cluster management is PAUSED (automated failover disabled).
- **Patroni timing rule** — the golden rule `ttl >= loop_wait + 2*retry_timeout`.
- **Patroni replication lag** — per-member lag from the `/cluster` endpoint, plus stopped/failed/crashed members and timeline (failover) history.
- **Patroni config flags** — `synchronous_mode`, `nofailover`, `maximum_lag_on_failover`.
- **etcd quorum & health** — endpoint health/status, member list, and whether the member count is odd vs even.
- **etcd alarms** — active alarms, especially NOSPACE (writes disabled, Patroni loses its lock).
- **etcd DCS keys** — presence of Patroni keys under the `/service/` prefix.
- **HAProxy config validity** — `haproxy -c` validation pass/fail.
- **HAProxy health-check pattern** — Patroni-aware `httpchk` on role endpoints vs role-blind `pgsql-check`.
- **HAProxy backend state** — DOWN servers reported via the runtime stats socket.
- **pgBouncer config** — `pool_mode` (session vs transaction), `max_client_conn`, `default_pool_size`, `listen_port`, `auth_type`.
- **pgBouncer saturation** — waiting clients (`cl_waiting > 0`) and traffic stats from the admin console.
- **keepalived / VIP** — service state, configured virtual IP(s), and whether this node currently holds the VIP (MASTER vs BACKUP).
- **Stack cross-checks** — remote-DCS reachability hints, HAProxy↔pgBouncer chain ordering, and standalone-node detection.

## How it tests
- **Docker autodetection:** `docker ps` container names matched with `grep -Ei` (patroni/etcd/haproxy/pgbouncer); Patroni leader found by `docker exec ... curl localhost:8008/patroni` and inspecting `role`.
- **Native detection:** `command -v`, `pgrep`, and raw TCP probes via `/dev/tcp` (`timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/<port>"`) for ports 8008/2379/6432.
- **Service state:** `systemctl is-active`/`is-enabled` (falls back to `pgrep` when no systemd).
- **HTTP fetch abstraction:** tries `curl`, then `wget`, then a raw `/dev/tcp` HTTP GET — so REST checks work with no HTTP client installed.
- **Patroni:** `patronictl -c <cfg> list` for the overview; REST endpoints `/patroni`, `/cluster`, `/history` parsed with `grep -oE`/`cut` (no `jq`); config parsed with `grep` (no YAML parser).
- **Lag thresholds:** `>104857600` bytes (>100 MB) → CRIT, `>10485760` bytes (>10 MB) → WARN.
- **etcd:** `etcdctl` with `ETCDCTL_API=3` (`endpoint health`, `endpoint status -w table`, `member list`, `alarm list`, `get --prefix /service/`), run on host or via `docker exec`; falls back to the `/health` HTTP endpoint when `etcdctl` is absent. Member count via `grep -c 'started'`; even → WARN.
- **HAProxy:** `haproxy -c -f <cfg>` to validate; config grepped for frontends/backends and check type; runtime state pulled with `echo 'show stat' | socat stdio <stats-socket>` (field 18 = server status, `DOWN` counted).
- **pgBouncer:** `.ini` grepped for settings; admin console via `psql -d pgbouncer -At -F'|' -c 'SHOW POOLS;'/'SHOW STATS;'` (host or `docker exec`); waiting clients summed from the `cl_waiting` column.
- **keepalived:** VIPs extracted from `keepalived.conf`, cross-checked against `ip addr` to determine MASTER/BACKUP.
- **Reporting:** findings accumulate into `ISSUES`/`REMEDS` arrays and print severity-tagged lines (`OK`/`INFO`/`WARN`/`CRIT`) plus a final summary and remediation-command list.

## Recommendations
- **Patroni PAUSED** → resume auto-failover (`patronictl ... resume`). *Rationale:* paused mode disables automated failover, so a primary crash leaves the cluster read-only.
- **Timing rule violated (`ttl < loop_wait + 2*retry_timeout`)** → `patronictl edit-config` to satisfy the rule (e.g. ttl 30 / loop_wait 10 / retry_timeout 10). *Rationale:* prevents transient DCS/network hiccups from expiring the leader key and triggering spurious demotions.
- **Member not running/streaming or stopped/failed/crashed** → inspect logs; `patronictl reinit` a broken replica. *Rationale:* a failed member reduces redundancy and can block promotions.
- **High replication lag (>10 MB warn / >100 MB crit)** → investigate the lagging member, network, and WAL volume. *Rationale:* a lagging replica risks data loss on failover.
- **etcd stopped** → start etcd. *Rationale:* Patroni cannot hold its leader lock without the DCS, demoting the cluster to read-only.
- **Even etcd member count** → add/remove one member to reach an odd count (3 or 5). *Rationale:* even counts raise the quorum requirement without adding fault tolerance.
- **etcd alarm active (NOSPACE)** → `etcdctl compact`, `defrag`, then `alarm disarm` (and raise `quota-backend-bytes`). *Rationale:* disk-quota exhaustion makes etcd reject writes, forcing Patroni to self-demote the primary.
- **HAProxy config fails validation** → fix errors and re-validate before reload. *Rationale:* a bad config breaks the load balancer on the next restart/reload.
- **HAProxy uses `pgsql-check`** → switch to `option httpchk GET /primary` (write pool) / `/replica` (read pool) against port 8008 with `http-check expect status 200`. *Rationale:* `pgsql-check` only proves PostgreSQL answers, not the Patroni role, so post-failover traffic can hit a read-only ex-primary (split-brain routing).
- **HAProxy backend DOWN** → verify each node's Patroni role endpoint (`curl http://<node>:8008/primary`). *Rationale:* down backends drop capacity or break primary routing.
- **pgBouncer `pool_mode=session`** → consider `transaction` pooling for OLTP (after confirming no session-state dependencies), then reload. *Rationale:* session pooling ties one client to one server connection, minimizing the pooling benefit.
- **pgBouncer clients waiting (`cl_waiting > 0`)** → raise `default_pool_size` (within PostgreSQL `max_connections`) or find/kill long transactions. *Rationale:* waiting clients mean the pool is exhausted and connections are blocked.
- **pgBouncer `auth_type=trust`/`any`** → set `auth_type = scram-sha-256` with `userlist.txt`/`auth_query`, then reload. *Rationale:* trust/any lets anyone reaching the port connect as any user.
- **keepalived not active** → start the service. *Rationale:* without it the virtual IP has no failover, so the VIP entry point can go dark.
- **Service not running (Patroni/HAProxy/pgBouncer)** → start (and enable) via systemd. *Rationale:* a down component breaks its layer of the client-to-database path.
