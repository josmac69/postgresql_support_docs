# pg_machine_audit.sh — Cheat Sheet

**Purpose:** Read-only diagnostic audit of host machine specs — CPU topology, memory & page tables, huge pages/THP, storage devices and PostgreSQL data-partition mounts, plus cloud/hypervisor metadata and an optional disk I/O benchmark.

**Usage:**
```bash
./pg_machine_audit.sh              # full diagnostic (read-only)
./pg_machine_audit.sh --benchmark  # also run 64MB sequential write/read tests
```
- **Privileges:** Runs as a normal user; no sudo required. Warns when not root because some kernel/hardware parameters are restricted, and un-privileged read benchmarks may reflect buffer cache rather than disk.
- **Read-only:** Yes in default mode — only reads `/proc`, `/sys`, `/etc`, and cloud metadata. `--benchmark` mode writes a temporary 64MB `dd` file to each PostgreSQL data dir, the current dir, and `/tmp`, then deletes it (via `EXIT`/`INT`/`TERM` trap).

## What it tests
- **Host & hypervisor** — hostname, OS, kernel, uptime, run-as user, and AWS EC2 vs local VM detection.
- **CPU topology** — model, logical CPUs, sockets, cores/socket, threads/core (hyperthreading), load average, scaling governor.
- **Memory** — total/used/available RAM.
- **Swap** — whether swap exists and how heavily it is used.
- **Page tables** — kernel PageTables overhead (MB and % of RAM) plus top-5 processes by `VmPTE+VmPMD`.
- **Huge Pages** — reserved/free huge pages and their size.
- **Transparent Huge Pages (THP)** — enabled/madvise/never state.
- **In-memory filesystems** — tmpfs/devtmpfs mounts (`/dev/shm`, `/tmp`, `/run`, etc.) and `/dev/zero` node health.
- **Storage devices** — physical disk type (SSD/NVMe vs rotational HDD), size, and I/O scheduler.
- **PostgreSQL partitions** — data-dir device, size, usage %, filesystem type, and `noatime`/`relatime`/`atime` mount options.
- **Live disk I/O** — per-device read/write MB/s, IOPS, and utilization over a 1-second sample.
- **Storage benchmark** *(optional)* — sequential write/read throughput per target directory.

## How it tests
- Host facts from `/etc/os-release`, `hostname -f`, `uname`, `uptime`, `id`.
- Cloud detection via `curl` to `169.254.169.254` (IMDSv2 token first, then IMDSv1) for instance type/ID/AZ; falls back to `systemd-detect-virt`.
- CPU via `lscpu` (fallback `/proc/cpuinfo`), `nproc`/`getconf`, `/proc/loadavg`, and `/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`.
- Memory, swap, page tables, and huge pages parsed from `/proc/meminfo`; THP read from `/sys/kernel/mm/transparent_hugepage/enabled` (and RedHat variant).
- Top page-table consumers via `awk` over `/proc/[0-9]*/status` summing `VmPTE`+`VmPMD`, sorted and headed.
- Mounts from `/proc/mounts` with sizes from `df -h -P`; `/dev/zero` checked as a character device.
- Disks enumerated from `/sys/block/*` (skipping loop/ram/dm/md) using `queue/rotational`, `size`, and `queue/scheduler`.
- PostgreSQL data dirs discovered from running processes (`pgrep`/`ps`, then `/proc/PID/cmdline` `-D`/`--data-directory` and `/proc/PID/environ` `PGDATA`), falling back to `/var/lib/postgresql`, `/var/lib/pgsql`, `/var/lib/postgres/data`, then `/`.
- Live I/O from two 1-second `/proc/diskstats` snapshots diffed in `awk` (sectors×512, `io_ms/10` for util%).
- Benchmark via `dd if=/dev/zero ... bs=1M count=64 conv=fdatasync` (write) and `dd ... of=/dev/null` (read), warning when the target is RAM-backed tmpfs.
- Findings accumulate into a `WARN_FLAGS` array and print a triage summary tagged `OK`/`WARN`/`FIX`/`INFO`.

## Recommendations
- **CPU governor not `performance`** → set the scaling governor to `performance`. *Rationale:* prevents latency spikes from dynamic frequency scaling.
- **No swap configured** → add a swap area. *Rationale:* provides a paging safety net that prevents sudden OOM kills.
- **Active swapping (≥10% used)** → review `shared_buffers`/`work_mem`. *Rationale:* swapping database memory causes severe latency.
- **Page tables >2 GB or >5% RAM** → set `huge_pages = on` in PostgreSQL and reserve OS Huge Pages. *Rationale:* 4KB mappings for large `shared_buffers` create heavy CPU overhead for address translation.
- **No Huge Pages with ≥16 GB RAM** → reserve Huge Pages sized to `shared_buffers`. *Rationale:* large shared memory benefits from fewer, larger page mappings.
- **THP not `never`** → disable Transparent Huge Pages. *Rationale:* dynamic huge-page allocation causes transaction latency spikes and RAM fragmentation.
- **Partition without `noatime`** → remount with `noatime`. *Rationale:* stops access-time writes during read queries, reducing write amplification.
- **Partition ≥85% (≥95% critical)** → free or expand disk space. *Rationale:* a full data partition halts writes and risks corruption.
- **`/dev/zero` missing** → recreate the node with `mknod`. *Rationale:* it is a required character device for normal operation.
