# pg_kernel_audit.sh — Cheat Sheet

**Purpose:** Read-only diagnostic that audits Linux kernel/memory/CPU/IO/network tunables against PostgreSQL best practices and correlates them with discovered native and dockerized PostgreSQL instances.

**Usage:**
```bash
./pg_kernel_audit.sh                # run the audit, print colourized OK/WARN/FIX/INFO report
./pg_kernel_audit.sh --sysctl       # same audit, then emit a ready-to-apply sysctl.d snippet of all FIXes
```
- **Privileges:** Runs as a normal user, but warns "not root, some values may be unreadable"; run as root (or with passwordless `sudo`) for full coverage — it uses `sudo -n -u postgres psql`, reads `hba_file`, and runs `dmesg`.
- **Read-only:** Yes — queries `/proc`, `/sys`, `sysctl -n`, and PostgreSQL `SHOW`/`SELECT` only; it applies nothing (the `--sysctl` mode just prints a suggested config for you to review and apply manually).

## What it tests
- **Memory management** — `vm.swappiness`, `vm.overcommit_memory`/`overcommit_ratio`, `vm.dirty_background_ratio`/`dirty_ratio` (and `dirty_*_bytes`), `vm.min_free_kbytes`, `vm.zone_reclaim_mode`, `vm.max_map_count`, and swap presence.
- **Huge pages** — `HugePages_Total`/`Free`, and Transparent Huge Pages `enabled` + `defrag` (want `never`).
- **SHM / SysV IPC** — `kernel.shmmax`, `kernel.shmall`, `kernel.shmmni`, `kernel.sem`.
- **Process / file limits** — `fs.file-max`, `fs.nr_open`, `fs.aio-max-nr`, `kernel.pid_max`, `kernel.threads-max`, and shell `ulimit -n/-u/-l`.
- **Network** — `net.core.somaxconn`/`netdev_max_backlog`, `tcp_max_syn_backlog`, `tcp_tw_reuse`, `tcp_fin_timeout`, TCP keepalive triplet, `ip_local_port_range`, `tcp_slow_start_after_idle`, `tcp_congestion_control`.
- **Scheduler / CPU / storage** — cpufreq governor, NUMA nodes + `numa_balancing`, `sched_autogroup_enabled`, `sched_migration_cost_ns`, per-device I/O scheduler / `read_ahead_kb` / `rq_affinity`, and ext4/xfs `noatime` mount option.
- **Time / misc** — clocksource (want `tsc`), NTP sync, SELinux/AppArmor state.
- **PostgreSQL discovery** — version, role (primary vs replica), data dir, disk usage, active base backup (`backup_label`), WAL size, key GUCs, archiver stats, replication (peers/slots/receiver), roles, and pg_hba rules.
- **Diagnostics** — running postgres processes, `free -m`, CPU topology, systemd `postgresql*` status, and recent OOM/segfault/crash lines from dmesg.

## How it tests
- Reads current sysctl values via a `get_sysctl` helper (`sysctl -n`, with `/sbin` and `/usr/sbin` fallbacks); numeric thresholds compared with `awk`-based `ge`/`le`.
- Facts from `/etc/os-release`, `uname`, `getconf`, and `/proc/meminfo` (MemTotal, SwapTotal, HugePages_*).
- THP/defrag, CPU governor, I/O scheduler, `read_ahead_kb`, `rq_affinity`, and clocksource read from `/sys/...` files (bracketed active value parsed with `sed`).
- Mount options parsed from `/proc/mounts` for `/dev/*` ext4/xfs only (skips overlay/container mounts).
- NUMA via `numactl --hardware`; time sync via `timedatectl`; MAC layer via `getenforce`/`aa-status`.
- Instance discovery: dockerized PG found with `docker ps` + `docker exec ... psql -V`; native ports gathered from `ss -ltn`, `ps -ef`, and `/var/run/postgresql/.s.PGSQL.*` sockets (plus default 5432), filtering out Docker-mapped ports and keeping 5432 / 5400–5499 candidates.
- SQL run through fallback chains — native tries `psql -h 127.0.0.1`, then local socket, then `sudo -n -u postgres psql`; docker uses `docker exec`; connects to first reachable of `tuning_lab`, `postgres`, `template1`.
- FIX-level findings are accumulated into a `FIX_LINES` array and, under `--sysctl`, printed sorted/deduped as an `/etc/sysctl.d/99-postgresql.conf` snippet.

## Recommendations
- **vm.swappiness > 10** → set to 1 (`addfix vm.swappiness 1`). *Rationale:* minimizes swapping out DB shared buffers, preventing heavy performance drops.
- **vm.overcommit_memory != 2** → set to 2. *Rationale:* strict accounting protects the postmaster from the OOM killer.
- **vm.dirty_background_ratio > 10** → set to 5; **vm.dirty_ratio > 20** → set to 15. *Rationale:* avoids large dirty-page flushes that stall disk I/O and transactions; on >64 GB RAM boxes prefer byte-based `dirty_*_bytes`.
- **vm.zone_reclaim_mode != 0** → set to 0. *Rationale:* NUMA reclaim overhead severely degrades the PG buffer cache.
- **vm.max_map_count < 262144** → raise to 262144. *Rationale:* supports high mmap usage from many connections/extensions.
- **No swap configured** → add swap. *Rationale:* zero swap risks sudden OOM kills.
- **THP not `never`** → disable THP (and set defrag to `never`). *Rationale:* THP allocation/compaction causes query latency spikes.
- **fs.file-max < 2000000 / fs.aio-max-nr < 1048576** → raise. *Rationale:* headroom for many connections and PG18 AIO / io_uring workloads.
- **net.core.somaxconn < 1024 / tcp_slow_start_after_idle != 0** → raise somaxconn to 1024, disable slow-start. *Rationale:* absorbs connection bursts and keeps warmed TCP windows for idle-then-active connections.
- **CPU governor != performance** → set `performance`. *Rationale:* consistent low latency for the database.
- **kernel.sched_autogroup_enabled = 1** → set 0. *Rationale:* prevents PG CPU starvation by other shell task groups.
- **SSD/NVMe I/O scheduler not none/mq-deadline** → switch to `none`/`mq-deadline`; set `rq_affinity=2`. *Rationale:* right scheduler for flash and I/O-completion locality.
- **ext4/xfs mounted with atime** → remount `noatime`. *Rationale:* eliminates disk writes just to record read-access times.
- **clocksource != tsc / NTP not synced** → prefer `tsc`, enable time sync. *Rationale:* cheaper `gettimeofday` for PG timing and clock drift breaks replication/PITR reasoning.
