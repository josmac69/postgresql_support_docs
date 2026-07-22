# patroni_deep_triage.sh — Cheat Sheet

**Purpose:** Exhaustive, read-only diagnostic and triage of a Patroni-supervised PostgreSQL HA node and its cluster — probing local process/service state, config semantics, REST API, DCS-backed cluster truth, DCS reachability, watchdog fencing, and logs, with severity-ranked findings and remediation commands.

**Usage:**
```bash
# Default: probe the local node's REST API at http://127.0.0.1:8008 (best run with sudo)
sudo bash patroni_deep_triage.sh

# Point at a specific member's API and/or an explicit config path
sudo bash patroni_deep_triage.sh --url http://10.0.0.5:8008 --config /etc/patroni/patroni.yml

# Help
bash patroni_deep_triage.sh --help
```
Flags: `--url <url>` (default `http://127.0.0.1:8008`, also settable via `PATRONI_URL` env var), `--config <path>` (default: auto-discover), `--help`. Unknown options print help and exit.
- **Privileges:** Runs as any user but is designed for passwordless `sudo` (`sudo -n`); it needs root to read the root/postgres-owned Patroni YAML (contains passwords), run `journalctl -u patroni`, read `/proc/<pid>/environ`, and reach the Docker/Podman socket. Without sudo it prints "config/journal access limited" and relies on live REST checks.
- **Read-only:** Yes — only issues HTTP GETs, reads config/log/proc files, and inspects containers (`docker/podman ps|inspect|logs`). It never runs mutating `patronictl` commands, never restarts services, never edits config or files; every fix is printed as a suggested command only.

## What it tests
- **Container context** — detects a running Docker/Podman Patroni/Spilo container, its restart policy, crash-loop restart count, and sibling stack containers (etcd/consul/zookeeper/haproxy/pgbouncer/postgres); re-runs all checks inside the container when found.
- **Presence & process** — `patroni`/`patronictl` binaries, a running `bin/patroni` process, and whether the REST API on port 8008 responds (host, container IP, or container-internal).
- **Service supervision** — systemd unit `active`/`enabled`; Patroni running outside systemd; a native `postgresql*` unit enabled alongside Patroni (two supervisors fighting).
- **Orphan PostgreSQL** — PostgreSQL running while the Patroni process is gone (unmanaged instance; split-brain hazard if it was the primary).
- **Config semantics** — scope/name presence and uniqueness, DCS backend kind, the bootstrap-vs-dynamic-config trap, file-level timing values, per-member tags (nofailover/nosync/noloadbalance/replicatefrom), auth blocks (superuser/replication/rewind), `use_pg_rewind`, and YAML file permissions.
- **Local member REST state** — role/state/timeline/server_version, `pause` flag, `pending_restart`, leader-side sync/async standby counts, and role endpoints (`/primary /replica /read-only /health /liveness /readiness`) cross-checked against the self-reported role.
- **Cluster-wide DCS truth** — leader count (0 = leaderless, >1 = split brain), per-member byte lag thresholds, failed/stopped members, scheduled switchover, timeline divergence, and the LIVE dynamic `ttl`/`loop_wait`/`retry_timeout`/`maximum_lag_on_failover`/`synchronous_mode`.
- **Timing rule** — the golden rule `ttl >= loop_wait + 2 * retry_timeout` against the live DCS config.
- **DCS reachability** — TCP reachability of each configured etcd/consul/zookeeper endpoint plus etcd native `/health`.
- **Watchdog / fencing** — `/dev/watchdog` presence, configured `mode` (off/automatic/required), and writability by the postgres user.
- **Log forensics** — last 24h of Patroni logs scanned for self-demotions, DCS communication errors, system-ID mismatch, pg_rewind failures, watchdog problems, promotions/elections, and repeated PostgreSQL start failures.
- **Special topologies** — standby (DR) cluster with read-only leader, DCS `failsafe_mode`, cluster-wide `nofailover`, and single-member "clusters".

## How it tests
- HTTP probing with a three-level fallback: `curl` → `wget` → raw bash `/dev/tcp`; status-code-only probes (`http_code`) exploit Patroni role endpoints returning 200 on match / 503 otherwise (what HAProxy consumes).
- JSON parsing without jq: a grep/sed `jfield` scalar extractor, with `python3 -m json.tool` / a small python snippet for pretty-printing and per-member listing when available.
- Container detection: `docker/podman ps` + `exec pgrep -f bin/patroni`, then image/name/port(8008) pattern matching; `docker inspect` harvests state/restart policy/RestartCount, host PID, container IP, and `PATRONI_*`/`SPILO_*` env vars (passwords redacted); a `cexec` wrapper runs checks inside the container via `sh -c`.
- Config discovery: reads the loaded YAML path from `/proc/<pid>/cmdline`, then conventional paths (`/etc/patroni/*.yml`, `/etc/patroni.yml`, `/opt/patroni/...`), then in-container paths (Spilo `/home/postgres/postgres.yml`); env overrides read from `/proc/<pid>/environ`. Static checks are grep/sed over the YAML text.
- Process/service signals: `pgrep`, `systemctl is-active`/`is-enabled`, `stat -c '%a %U'` for file mode/owner.
- REST endpoints hit: `/patroni`, `/primary`, `/replica`, `/read-only`, `/health`, `/liveness`, `/readiness`, `/cluster`, `/config`.
- DCS reachability: harvests ip:port patterns from the YAML DCS section, opens each via `timeout 1 bash -c '/dev/tcp/host/port'`, and GETs etcd `/health`.
- Watchdog: `test -e /dev/watchdog`, `stat`, and `sudo -u postgres test -w` (in-container `test -e` in container mode).
- Logs: `docker logs --since 24h` (container) or `journalctl -u patroni --since -24h` (host), fed to a `scan_log` grep signature scanner.
- Findings accumulate in `ISSUES`/`REMEDS` bash arrays via `ok`/`info`/`warn`/`crit`/`remed` helpers; runs with `set -o nounset` but deliberately no `errexit` (probes fail independently); a final section prints the flagged-issue count and remediation commands.

## Recommendations
- **Cluster is PAUSED** → resume when appropriate via `patronictl resume <scope>` (document why it was paused first). *Rationale:* pause disables the HA loop — no automatic failover, no config convergence — so everything looks healthy until the primary dies.
- **Orphan PostgreSQL running without Patroni** → if a failover already happened, stop this postgres before apps write to it; otherwise start Patroni to re-adopt it. *Rationale:* an unmanaged ex-primary keeps accepting writes while its lease expires and another node promotes → split brain.
- **Live timing rule violated (`ttl < loop_wait + 2*retry_timeout`)** → `patronictl edit-config` to set `ttl >= loop_wait + 2*retry_timeout` (defaults 30/10/10). *Rationale:* one DCS hiccup can expire the lease and spuriously demote a healthy primary.
- **DCS backend `etcd:` (v2 API)** → switch the config section to `etcd3:` and reload/restart Patroni. *Rationale:* the etcd v2 API is deprecated and removed in modern etcd builds (built-in `raft:` is likewise deprecated in Patroni 4.x).
- **Config YAML mode > 640** → `chown postgres:postgres` and `chmod 600` the file. *Rationale:* it contains cleartext DB passwords.
- **Watchdog missing/disabled (or `required` with no device)** → `modprobe softdog`, pass `/dev/watchdog` into the container, or set `mode: automatic` and make the device writable by postgres. *Rationale:* the kernel watchdog hard-resets a frozen node to prevent split brain; with `mode: required` and no device the member can never become leader.
- **Zero or multiple leaders in the cluster view** → check DCS health first; if leaderless and no candidate qualifies use a documented `patronictl failover --candidate`, and for split brain compare timelines, stop the stale claimant, resolve DCS, then rejoin (likely reinit). *Rationale:* exactly one leader is the fundamental cluster invariant.
- **Role self-report vs `/primary` endpoint mismatch** → restart Patroni on the node so it re-syncs its published role. *Rationale:* load balancers route on the role endpoint, so a mismatch drops writes or exposes two writable nodes at the LB layer.
- **`pending_restart=true`** → do a rolling `patronictl restart <scope> --pending` (replicas first, leader last). *Rationale:* the member still runs OLD values for a restart-requiring parameter.
- **No DCS endpoint reachable** → fix firewall (2379/8500/2181), DCS service state on peers, and DNS before anything else. *Rationale:* on the primary, DCS quorum loss forces self-demotion within `ttl` → read-only cluster.
- **Standby (DR) cluster** → treat the read-only leader as expected; promote only by removing the `standby_cluster` section (irreversible site failover). *Rationale:* writes belong on the source cluster, not the DR replica.
- **Single-member cluster / cluster-wide `nofailover`** → add a replica, or clear `nofailover` on at least one healthy replica. *Rationale:* without a promotable candidate, automatic failover is impossible.
