# Linux Kernel & OS Tuning for PostgreSQL: An Expert Practitioner's Reference

*A deep reference for a dedicated PostgreSQL production server. Each parameter is treated across three dimensions: (1) **kernel mechanics** — what the kernel actually does internally; (2) **hands-on** — exactly where and how to set it, verify it, and make it persistent; and (3) **PostgreSQL linkage** — how the setting couples to a specific PostgreSQL subsystem (shared buffers, WAL, checkpointer, bgwriter, autovacuum, AIO, backends). Values through PostgreSQL 18 and modern kernels (6.x, EEVDF, io_uring).*

---

## How to read this document

For each setting you get: **Mechanics** (kernel internals), **Set / Verify / Persist** (commands), **PostgreSQL linkage** (why a DBA cares), **Recommended value**, and **Trade-offs**. A consolidated cheat-sheet sits at the end. Where the community genuinely disagrees, the disagreement is flagged rather than papered over.

A recurring theme underlies almost everything below: **PostgreSQL deliberately delegates to the kernel.** It uses buffered I/O through the page cache for data files, relies on the kernel's dirty-page writeback machinery to destage, uses POSIX shared memory (`mmap`) for its main shared-memory segment, and depends on the OOM killer *not* firing on the postmaster. Every kernel knob below is really a knob on one of those delegated responsibilities.

---

## 1. Memory Management (`vm.*`)

### 1.1 `vm.overcommit_memory` and `vm.overcommit_ratio` / `vm.overcommit_kbytes`

**Mechanics.** Linux lets processes reserve more virtual address space than there is physical RAM + swap, because most reservations are never fully faulted in. `vm.overcommit_memory` selects the accounting policy the kernel applies at `mmap`/`brk` time:

- `0` — *heuristic* (default). The kernel allows "reasonable" overcommit and rejects only allocations it deems wildly implausible. Reservations that later fault under memory pressure can trigger the OOM killer.
- `1` — *always overcommit*. Every allocation succeeds; the OOM killer is the only backstop. Used by workloads (e.g. some sparse-array scientific code) that legitimately map huge address spaces.
- `2` — *strict / never overcommit*. The kernel refuses any allocation that would push committed address space past `CommitLimit`, where `CommitLimit = swap_total + RAM * overcommit_ratio/100` (or `swap_total + overcommit_kbytes` if that is set). Under this policy `malloc()` returns `NULL` / `mmap()` returns `MAP_FAILED` (ENOMEM) instead of the kernel later killing a process. You can watch the accounting live in `/proc/meminfo` as `CommitLimit` and `Committed_AS`.

**Set / Verify / Persist.**

```bash
# inspect
sysctl vm.overcommit_memory vm.overcommit_ratio
grep -E 'Commit(Limit|ted_AS)' /proc/meminfo

# set at runtime
sudo sysctl -w vm.overcommit_memory=2
sudo sysctl -w vm.overcommit_ratio=80        # or vm.overcommit_kbytes for an absolute cap

# persist
cat <<'EOF' | sudo tee /etc/sysctl.d/30-postgresql-memory.conf
vm.overcommit_memory = 2
vm.overcommit_ratio  = 80
EOF
sudo sysctl --system
```

**PostgreSQL linkage.** This is the single most important *reliability* knob. Under the default heuristic policy, when the machine runs low on memory the kernel's OOM killer can select the **postmaster** (the parent `postgres` process). Killing the postmaster is catastrophic: PostgreSQL's shared-memory model means the postmaster's death forces the whole cluster into a crash-recovery cycle — every backend is terminated, every client connection is dropped, and the server replays WAL from the last checkpoint before accepting connections again. With `overcommit_memory=2`, a backend that asks for too much memory (e.g. a runaway query building a giant hash table with a reckless `work_mem`) instead receives ENOMEM and fails *that one query* with "out of memory" — the postmaster and every other session survive. The PostgreSQL documentation's "Linux Memory Overcommit" section explicitly recommends this policy for exactly this reason.

**Sizing `CommitLimit`.** With `overcommit_memory=2` you must budget deliberately. Peak committed memory ≈ `shared_buffers` + `wal_buffers` + `max_connections × work_mem × (concurrent sort/hash operators per query)` + `autovacuum_max_workers × maintenance_work_mem` + backend stacks + OS. If `CommitLimit` is too tight, ordinary queries fail with ENOMEM prematurely; if `overcommit_ratio` is set very high with little swap, you regain some overcommit risk. A common dedicated-server value is `overcommit_ratio = 80`, but the right number depends on how much of RAM you have already dedicated to `shared_buffers`.

**Trade-offs / caveats.** On swapless systems `overcommit_memory=2` bites harder — there is no swap term in `CommitLimit`, so the ceiling is purely `RAM × ratio/100`. Inside **cgroup v2 / Kubernetes**, `overcommit_memory` does *not* protect you: hitting the cgroup `memory.max` produces an immediate in-cgroup OOM kill (SIGKILL) with no ENOMEM grace period. In containers you must size the cgroup instead (see §6). Some practitioners leave `overcommit_memory=0` and rely purely on `oom_score_adj` protection (§1.9); the belt-and-braces approach uses both.

**Recommended:** `vm.overcommit_memory = 2`, `vm.overcommit_ratio ≈ 80` (tune to your memory budget), on bare-metal / VM dedicated servers.

---

### 1.2 `vm.swappiness`

**Mechanics.** During reclaim the kernel must choose between evicting **file-backed** pages (the page cache — cheap to drop, re-readable from disk) and **anonymous** pages (heap/stack — must be written to swap first). `vm.swappiness` (0–100, some newer kernels allow up to 200) biases that split. Lower values push the kernel to reclaim page cache and avoid touching anonymous memory; higher values make it more willing to swap anonymous pages out. It is a *bias*, not a hard switch — the kernel still swaps under genuine pressure even at low values, but only as a last resort.

**Set / Verify / Persist.**

```bash
cat /proc/sys/vm/swappiness
sudo sysctl -w vm.swappiness=1
echo 'vm.swappiness = 1' | sudo tee /etc/sysctl.d/30-postgresql-memory.conf >> /dev/null
```

**PostgreSQL linkage.** A database manages its own hot working set inside `shared_buffers` and expects backend private memory (parse trees, sort buffers, catalog caches) to stay resident. If the kernel swaps a backend's anonymous pages out to satisfy page-cache growth, the next access to that memory causes a major page fault and a synchronous disk read — a latency spike that shows up as unpredictable query stalls and, on replicas, as lag. Keeping `swappiness` low protects backend responsiveness.

**Why `1`, not `0`.** Setting `swappiness=0` on modern kernels (≥ 3.5-ish) means "do not swap anonymous memory until the watermark is critical," which in practice makes an OOM kill *more* likely under a sudden spike, because the kernel refuses swap as a pressure-relief valve. `swappiness=1` keeps swapping essentially off during normal operation while still permitting it as an emergency escape hatch before the OOM killer engages. This is the mainstream recommendation for latency-sensitive OLTP.

**The community disagreement (flagged).** Some experienced PostgreSQL people (e.g. Cybertec's Laurenz Albe) argue `swappiness=0` is defensible on a dedicated DB box precisely *because* PostgreSQL does its own memory management. Others argue for leaving the default `60` so that genuinely idle backends and rarely-touched pages *can* be pushed to swap, freeing RAM for page cache. For predictable commit latency the consensus lands on `1`. If you disable swap entirely (`swapoff`), `swappiness` is moot — but then you have removed the OOM safety valve, so pair it with strict overcommit and OOM-score protection.

**Recommended:** `vm.swappiness = 1`.

---

### 1.3 Dirty-page writeback: `vm.dirty_ratio` / `vm.dirty_background_ratio` vs `vm.dirty_bytes` / `vm.dirty_background_bytes`

**Mechanics.** When a process writes to a file through the page cache (which is how PostgreSQL writes data files by default), the modified page is marked **dirty** and is not immediately on disk. The kernel's writeback threads flush dirty pages to storage in the background. Four thresholds govern this:

- `vm.dirty_background_ratio` / `vm.dirty_background_bytes` — the **soft** threshold. When the volume of dirty pages crosses it, the kernel's flusher threads begin writing them back *asynchronously*, while applications continue unimpeded.
- `vm.dirty_ratio` / `vm.dirty_bytes` — the **hard** threshold. When dirty pages cross it, any process that dirties a new page is **throttled**: its `write()` blocks and it is made to do writeback synchronously until the level drops back. This is the classic "write stall."

The `*_ratio` forms express the threshold as a percentage of available memory; the `*_bytes` forms express it as an absolute byte count. Setting a `_bytes` knob zeroes its `_ratio` counterpart and vice-versa (they are two views of one control). Two related timers govern age-based flushing:

- `vm.dirty_expire_centisecs` (default 3000 = 30 s) — a dirty page older than this becomes eligible for writeback regardless of the volume thresholds.
- `vm.dirty_writeback_centisecs` (default 500 = 5 s) — how often the flusher threads wake up to do their work.

**Set / Verify / Persist.**

```bash
sysctl -a 2>/dev/null | grep dirty
# example: absolute limits tuned to a server with fast storage + BBU cache
sudo sysctl -w vm.dirty_background_bytes=134217728   # 128 MiB: start background flush early
sudo sysctl -w vm.dirty_bytes=536870912              # 512 MiB: hard throttle ceiling
# leave the timers at defaults unless latency-testing says otherwise
```

Persist in `/etc/sysctl.d/`. Verify the effect under load with `grep -E 'Dirty|Writeback' /proc/meminfo` and by watching `/proc/vmstat` (`nr_dirty`, `nr_writeback`).

**PostgreSQL linkage — the checkpoint-storm problem.** This is where kernel VM tuning meets the PostgreSQL checkpointer directly. During a checkpoint, the checkpointer writes every dirty shared buffer into the page cache and then issues `fsync()` on the underlying files to force durability. If the kernel has been permitted to hoard gigabytes of dirty pages (which the default `dirty_ratio=20` allows on a large-RAM server — 20% of, say, 256 GB is ~51 GB), that `fsync()` turns into a colossal synchronous flush that saturates the storage and stalls *every* backend doing normal I/O. The symptom is periodic, checkpoint-aligned latency cliffs.

Using **absolute** limits keeps the pool of dirty data bounded to something the storage can flush quickly, smoothing writeback into a steady trickle rather than a periodic tsunami. Size `dirty_background_bytes` near the write-back bandwidth the device (or its battery-backed cache) can absorb, and `dirty_bytes` a few times larger, always keeping `dirty_bytes > dirty_background_bytes` so background flushing starts before throttling does.

**Interaction with PostgreSQL's own flush controls.** Since 9.6 PostgreSQL mitigates this problem from its side with `checkpoint_flush_after` (default 256 kB), which tells the backend to hint the kernel (`sync_file_range`) to start writing recently dirtied ranges during the checkpoint rather than dumping them all at fsync time; `bgwriter_flush_after` (default 512 kB) and `backend_flush_after` do the same for the background writer and normal backends. These reduce — but do not eliminate — the need to tune the kernel knobs, because the kernel still controls the global dirty pool that non-PostgreSQL writes and the OS itself contribute to. Coordinate the whole picture: `checkpoint_completion_target` (default 0.9) spreads checkpoint writes across most of the interval; `max_wal_size` controls how often checkpoints fire; the `vm.dirty_*` knobs control how the kernel drains what the checkpointer produced.

**Workload dependence.** Write-heavy OLTP wants *tight* absolute limits for smooth, predictable latency. Bulk-load / OLAP / ETL wants *larger* limits so big sequential writes can batch for throughput. If you run both, tune for the latency-sensitive workload and let the batch jobs run slightly slower.

**Recommended:** switch to absolute limits, e.g. `vm.dirty_background_bytes` ≈ 64–256 MiB and `vm.dirty_bytes` ≈ 256 MiB–1 GiB, tuned to device bandwidth; keep timers at defaults unless testing indicates otherwise.

---

### 1.4 `vm.zone_reclaim_mode`

**Mechanics.** On a NUMA machine, RAM is partitioned into per-node *zones*. When memory is requested on a node whose local zone is full, the kernel can either (a) satisfy the request from a remote node's memory, or (b) aggressively reclaim (evict) pages from the *local* zone first to keep the allocation local. `zone_reclaim_mode` controls that choice; the kernel historically auto-enabled it (value `1`) when it detected large inter-node distances in the ACPI SLIT table.

**Set / Verify / Persist.**

```bash
cat /proc/sys/vm/zone_reclaim_mode        # 0 = off (desired)
sudo sysctl -w vm.zone_reclaim_mode=0
echo 'vm.zone_reclaim_mode = 0' | sudo tee -a /etc/sysctl.d/30-postgresql-memory.conf
numactl --hardware                        # inspect node layout and distances
```

**PostgreSQL linkage.** When zone reclaim is enabled, the kernel would rather throw away useful page-cache pages on the local node than "reach across" to plentiful free RAM on a remote node. For a database this is pathological: the page cache — which is caching your hot table and index blocks — gets evicted, forcing re-reads from disk, and in the worst case the machine starts swapping *despite having gigabytes of free remote RAM*. Greg Smith documented exactly this failure mode for PostgreSQL and the standing recommendation is to always disable it on database servers. This is arguably the most important single NUMA knob.

**Recommended:** `vm.zone_reclaim_mode = 0` (explicitly, everywhere — do not rely on the kernel's auto-detection).

---

### 1.5 `vm.min_free_kbytes`

**Mechanics.** The kernel keeps a reserve of free memory below which allocations trigger reclaim, and a smaller reserve for atomic (non-blocking, e.g. interrupt-context) allocations that cannot wait. `vm.min_free_kbytes` sets the size of that floor. If it is too low on a large-memory server, bursts of allocation can outrun reclaim and cause allocation stalls or, for atomic allocations, failures; too high simply wastes RAM that could be page cache.

**Set / Verify / Persist.**

```bash
cat /proc/sys/vm/min_free_kbytes
sudo sysctl -w vm.min_free_kbytes=1048576   # ~1 GiB on a large-RAM box
```

**PostgreSQL linkage.** Indirect but real: on servers with hundreds of GB of RAM and fast NICs/NVMe generating lots of atomic allocations, a slightly larger `min_free_kbytes` (order of 1–2 GiB) reduces the chance of reclaim-related latency spikes that would otherwise show up as sporadic query jitter. Do not over-tune; this is a fine-adjustment knob, not a first-line one.

**Recommended:** leave default on modest servers; consider `1–2 GiB` on very large-memory hosts.

---

### 1.6 Explicit Huge Pages: `vm.nr_hugepages`, `vm.hugetlb_shm_group`, and the `huge_pages` GUC

**Mechanics.** The CPU translates virtual addresses to physical ones via page tables, caching recent translations in the TLB (Translation Lookaside Buffer). With the standard 4 KiB page, a large shared-memory segment needs an enormous number of page-table entries, and the TLB — which has only a few thousand entries — thrashes, causing frequent expensive page walks. **Huge pages** (2 MiB, or 1 GiB "gigantic" pages on x86-64) let one TLB entry cover 512× or 262144× more memory, slashing TLB misses and shrinking the page tables themselves. Explicitly reserved huge pages (`HugeTLB`) are also **pinned**: they are never swapped and never split.

`vm.nr_hugepages` reserves a pool of huge pages at (or after) boot. `vm.hugetlb_shm_group` names a GID permitted to allocate from the SysV huge-page pool. The reserved pool is visible in `/proc/meminfo` as `HugePages_Total`, `HugePages_Free`, `HugePages_Rsvd`, and `Hugepagesize`.

**Set / Verify / Persist.**

```bash
# 1) Ask PostgreSQL exactly how many huge pages the shared segment needs:
sudo -u postgres /usr/lib/postgresql/18/bin/postgres -D /var/lib/postgresql/18/main \
     -C shared_memory_size_in_huge_pages
# -> e.g. 12800  (this is a read-only GUC computed from shared_buffers et al.)

# 2) Reserve that many + headroom. Runtime (works if memory isn't fragmented):
sudo sysctl -w vm.nr_hugepages=13000

# 3) Persist. Prefer boot-time reservation via kernel cmdline to avoid fragmentation:
#    edit /etc/default/grub -> GRUB_CMDLINE_LINUX="... hugepagesz=2M hugepages=13000"
sudo update-grub    # (Debian/Ubuntu) or grub2-mkconfig -o ... on RHEL
# OR persist via sysctl.d if reserving after boot is acceptable:
echo 'vm.nr_hugepages = 13000' | sudo tee /etc/sysctl.d/31-postgresql-hugepages.conf

# 4) Allow the postgres user to lock that memory (see §6, LimitMEMLOCK).
# 5) In postgresql.conf:
#    huge_pages = try        # default: use them if available, else fall back
#    huge_pages = on         # fail to start if they aren't available (fail-fast, preferred once stable)
```

Verify PostgreSQL actually took them:

```sql
SHOW huge_pages;            -- what you asked for
SHOW huge_pages_status;     -- PG18: 'on' / 'off' / 'unknown' — what actually happened
```

and at the OS level `watch -n1 grep Huge /proc/meminfo` while starting the server — `HugePages_Rsvd`/`HugePages_Free` should shift as the segment maps.

**PostgreSQL linkage.** `shared_buffers`, the WAL buffers, the lock tables, and the rest of the main shared-memory segment all live in one big mapping. Backing it with huge pages is one of the most reliable wins on servers with tens of GB of `shared_buffers`: fewer TLB misses across every backend, smaller kernel page tables (which also reduces `fork()` cost for new backends), and immunity from that memory ever being swapped. Use `shared_memory_size_in_huge_pages` (a runtime-computed, read-only GUC) to size the pool exactly rather than guessing.

**Trade-offs / caveats.** Reserved huge pages are removed from the general allocator — over-reserving strands RAM that nothing else can use, so size to the segment plus modest headroom, and reserve at **boot** (`hugepages=` on the kernel cmdline) on busy servers because post-boot reservation can fail when memory is fragmented. PostgreSQL reads only the first `Hugepagesize` from `/proc/meminfo`, so if you want 1 GiB pages you must set `huge_page_size = 1GB` in postgresql.conf and reserve `hugepagesz=1G` pages. Best confined to dedicated database hosts. **You must disable Transparent Huge Pages first** (next section) or the kernel may inconsistently back the segment with THP.

**Recommended:** reserve `shared_memory_size_in_huge_pages` + headroom via boot cmdline; set `huge_pages = on` once validated; grant `LimitMEMLOCK=infinity` in the unit.

---

### 1.7 Transparent Huge Pages (THP)

**Mechanics.** THP is a *different* mechanism from the explicit huge pages above. Instead of a pre-reserved pinned pool, THP transparently promotes ordinary anonymous 4 KiB pages into 2 MiB pages behind the application's back. A kernel thread, `khugepaged`, periodically scans memory and *compacts* fragmented small pages into huge ones; allocations can also trigger synchronous "direct compaction." The controls live in sysfs:

- `/sys/kernel/mm/transparent_hugepage/enabled` — `always` / `madvise` / `never`.
- `/sys/kernel/mm/transparent_hugepage/defrag` — `always` / `defer` / `defer+madvise` / `madvise` / `never`, controlling how hard the kernel works (and stalls the allocator) to assemble huge pages.

**Set / Verify / Persist.**

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled   # [always] madvise never
# runtime disable:
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag

# persist via GRUB (cleanest):
#   GRUB_CMDLINE_LINUX="... transparent_hugepage=never"
# OR a systemd oneshot ordered before postgresql:
cat <<'EOF' | sudo tee /etc/systemd/system/disable-thp.service
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=postgresql.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
sudo systemctl enable --now disable-thp.service
```

**PostgreSQL linkage.** THP hurts databases for two reasons. First, `khugepaged` and direct compaction burn CPU in kernel space and, worse, can **stall an allocating backend** while the kernel shuffles memory to form a 2 MiB page — a source of unpredictable, hard-to-diagnose latency spikes (visible as high `sys` CPU and time in compaction functions in a `perf` profile). Second, PostgreSQL's access to shared memory is sparse and irregular, so it captures little of THP's TLB benefit while paying its costs. Percona's benchmark study ("Settling the Myth of Transparent HugePages for Databases") ran pgbench (TPCB) and sysbench (TPCC) at 48 GB and 112 GB dataset sizes with 64/128/256 clients and found the with-THP and without-THP throughput curves essentially overlapping — no measurable gain — while the failure modes (latency spikes, memory bloat) are well documented across the ecosystem.

**`never` vs `madvise`.** On a *dedicated* database host, `never` is simplest and safest. On a *mixed-use* host where a JVM or another application genuinely benefits from THP, `madvise` is a compromise: THP is used only for memory ranges that explicitly `madvise(MADV_HUGEPAGE)`, which PostgreSQL does not, so PostgreSQL is effectively opted out while the other app can opt in.

**Recommended:** `transparent_hugepage=never` (dedicated) or `madvise` (mixed). Always disable **before** configuring explicit huge pages.

---

### 1.8 `vm.max_map_count`

**Mechanics.** Each process may have at most `vm.max_map_count` distinct memory-map areas (VMAs) — separate contiguous regions in its address space, each created by an `mmap`, a shared library load, a mapped file, etc. Default is 65530. Exceeding it makes the next `mmap()` fail with ENOMEM.

**Set / Verify / Persist.**

```bash
cat /proc/sys/vm/max_map_count
sudo sysctl -w vm.max_map_count=262144
```

**PostgreSQL linkage.** A single backend maps the shared-memory segment plus its libraries and per-file mappings. Deployments with very many partitions, many loaded extensions, high parallelism, or large numbers of mapped relations can approach the default ceiling; raising it to 262144 is cheap insurance and standard on large/parallel installations (it is also a well-known requirement for neighbours like Elasticsearch, for the same VMA reason).

**Recommended:** `vm.max_map_count = 262144` on large or highly-partitioned deployments.

---

### 1.9 The OOM killer: `oom_score_adj`, `oom_kill_allocating_task`, and protecting the postmaster

**Mechanics.** When the kernel genuinely cannot reclaim enough memory, the OOM killer selects a victim to SIGKILL. It scores every process (visible as `/proc/<pid>/oom_score`), roughly proportional to memory footprint, then adjusted by `/proc/<pid>/oom_score_adj` (range −1000…+1000). A score adjustment of −1000 makes a process effectively unkillable; +1000 volunteers it first. `vm.oom_kill_allocating_task` (default 0) controls whether the kernel kills the *process that triggered* the OOM (1) or the *highest-scoring* process (0).

**Set / Verify / Persist.**

```bash
# systemd unit drop-in for the postmaster:
sudo systemctl edit postgresql@18-main    # (Debian/Ubuntu name; adjust for your distro)
# add:
[Service]
OOMScoreAdjust=-1000
Environment=PG_OOM_ADJUST_FILE=/proc/self/oom_score_adj
Environment=PG_OOM_ADJUST_VALUE=0
```

`sudo systemctl daemon-reload && sudo systemctl restart postgresql@18-main`. Verify: `cat /proc/$(head -1 /var/lib/postgresql/18/main/postmaster.pid)/oom_score_adj` should be `-1000`, and a fresh backend's should be `0`.

**PostgreSQL linkage.** The design goal is: *if the OOM killer must fire, sacrifice a single backend, never the postmaster.* Setting the postmaster's `oom_score_adj = -1000` makes it the last thing the kernel will kill. But children inherit that protection through `fork()`, which is wrong — you do *not* want protected, unkillable backends, because then the OOM killer has nothing safe to kill and may take out something worse. PostgreSQL solves this with two environment variables it honours at backend startup: `PG_OOM_ADJUST_FILE` (usually `/proc/self/oom_score_adj`) and `PG_OOM_ADJUST_VALUE` (usually `0`), which tell each freshly-forked backend to *reset* its own score to killable. The result: postmaster unkillable, backends killable, so an OOM event costs you one query instead of the whole cluster. Crunchy Data's write-up "The Linux OOM Killer and PostgreSQL" ("The Linux Assassin") walks through exactly this configuration. Keep `oom_kill_allocating_task = 0` so the kernel picks the fattest backend rather than whichever process happened to fault at the wrong moment.

**Recommended:** postmaster `OOMScoreAdjust=-1000` + `PG_OOM_ADJUST_FILE`/`PG_OOM_ADJUST_VALUE=0` for children; `vm.oom_kill_allocating_task=0`; combine with strict overcommit (§1.1).

---

## 2. NUMA

Modern multi-socket (and even some single-socket chiplet) servers are NUMA: each CPU has "near" memory (low latency, high bandwidth) and "far" memory (higher latency, lower bandwidth) attached to other nodes. PostgreSQL's big shared-memory segment and its many backends interact with NUMA placement in ways that can silently halve throughput if mishandled.

### 2.1 `vm.zone_reclaim_mode` — covered in §1.4

The single most important NUMA setting; it belongs to both the memory and NUMA stories. Keep it `0`.

### 2.2 `kernel.numa_balancing`

**Mechanics.** "Automatic NUMA balancing" (AutoNUMA) is a kernel feature that periodically unmaps pages to trap the next access (a minor "NUMA hinting fault"), learns which node is touching each page, and then *migrates* pages toward the CPUs using them — and can migrate tasks toward their memory. The intent is to improve locality automatically for NUMA-naïve applications.

**Set / Verify / Persist.**

```bash
cat /proc/sys/kernel/numa_balancing     # 1 = on (default on many distros)
sudo sysctl -w kernel.numa_balancing=0
echo 'kernel.numa_balancing = 0' | sudo tee /etc/sysctl.d/32-postgresql-numa.conf
```

**PostgreSQL linkage.** For a shared-memory database this heuristic works *against* you. `shared_buffers` is touched by *every* backend regardless of which node it runs on, so the kernel sees the same pages accessed from all nodes and thrashes them back and forth, paying constant hinting-fault and page-migration overhead plus TLB shootdowns — pure cost, no locality win, because there is no single "correct" node for a globally-shared buffer pool. On a dedicated single-cluster host the standard advice (e.g. from Cybertec) is to disable it and instead pin placement deterministically (explicit huge pages help, since HugeTLB pages are exempt from AutoNUMA migration).

**Recommended:** `kernel.numa_balancing = 0` on a dedicated PostgreSQL host.

### 2.3 Interleaving and process placement (`numactl`)

**Mechanics.** By default the kernel allocates memory on the node local to whichever CPU first faults each page ("first-touch"). For a segment initialized by the postmaster and then used cluster-wide, first-touch can pile the whole shared segment onto one node, overloading that node's memory bandwidth. `numactl --interleave=all` instead spreads pages round-robin across all nodes, evening out bandwidth demand.

**Set / Verify.**

```bash
numactl --hardware                       # node sizes + distance matrix
numastat -p $(head -1 .../postmaster.pid)  # per-node memory of the postmaster
# historical approach: launch the whole cluster interleaved
numactl --interleave=all pg_ctl start ...
```

**PostgreSQL linkage & the modern nuance.** Interleaving the *shared* segment is usually beneficial: it balances bandwidth for the buffer pool that everyone hits. But `numactl --interleave=all` on the whole postmaster *also* interleaves every backend's **private** memory (its `work_mem` sorts/hashes, its stack), which for OLAP queries you would rather keep node-local for a single large query. Kevin Grittner's oft-cited tests showed interleaving OS cache + `shared_buffers` yielded roughly a couple of percent on read-only workloads, while a deliberately *mis*-placed database (forced onto a distant node) collapsed to about a fifth of balanced throughput — i.e. the big danger is gross mis-placement, not fine-tuning. The modern consensus among hackers (Andres Freund, Tomas Vondra) is that blunt whole-process interleaving is a crude tool; the cleaner path today is: **explicit huge pages** (reserved at boot, naturally spread, never migrated) + `zone_reclaim_mode=0` + `numa_balancing=0`, and let backends keep their private memory local.

**PostgreSQL 18 NUMA awareness.** PG18 adds build-time `--with-libnuma`, the SQL function `pg_numa_available()`, and two observability views — `pg_shmem_allocations_numa` and `pg_buffercache_numa` — that show how the shared segment and individual buffers are distributed across nodes. These are **observability only**: the docs explicitly warn that `pg_shmem_allocations_numa` is very slow and can itself allocate shared memory, so it must **not** be polled by monitoring. The actual placement GUCs (`numa`, buffer interleaving, `numa_localalloc`) are development work targeting PostgreSQL 19, not shipped in 18. In 18 you *observe* with these views and *act* with `numactl` / huge pages / the sysctls above.

**Recommended:** don't reflexively `--interleave=all`; prefer huge pages + `zone_reclaim_mode=0` + `numa_balancing=0`. Interleave only if measurement on your hardware shows a bandwidth imbalance that it fixes. Use PG18's NUMA views to measure, not monitor.

---

## 3. Storage / I/O and Filesystem

### 3.1 I/O scheduler

**Mechanics.** The block layer (blk-mq on all modern kernels) can reorder and merge I/O requests before dispatch. The available schedulers:

- `none` — no reordering; requests go straight to the device. Ideal when the device (NVMe firmware, a smart RAID controller) already schedules better than software can.
- `mq-deadline` — imposes deadlines to bound worst-case latency and prevent starvation; a good general-purpose choice for spinning disks and SATA SSDs.
- `bfq` — Budget Fair Queueing; strong fairness/interactivity for desktop-like mixed workloads, at some throughput/CPU cost.
- `kyber` — lightweight, latency-target-driven; occasionally used for fast multi-queue devices.

**Set / Verify / Persist.**

```bash
cat /sys/block/nvme0n1/queue/scheduler        # [none] mq-deadline kyber bfq
echo none | sudo tee /sys/block/nvme0n1/queue/scheduler   # runtime

# persist with a udev rule (the legacy elevator= cmdline is ignored under blk-mq):
cat <<'EOF' | sudo tee /etc/udev/rules.d/60-ioscheduler.rules
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
EOF
sudo udevadm control --reload && sudo udevadm trigger
```

**PostgreSQL linkage.** Scheduler choice mostly moves the **tail** (p99/p999) of I/O latency, not the median. On NVMe the firmware's internal parallelism is deeper and smarter than any software scheduler, so `none` gives the lowest overhead and best tail behavior — Red Hat's RHEL 9 guidance is explicit that `none` is the default and recommended choice for NVMe. For SATA/SAS SSD and HDD, `mq-deadline` bounds worst-case latency, which protects commit latency when a checkpoint flush and normal backend reads compete for the same device. On VM guests using virtio, or behind a hardware RAID controller with its own scheduling and battery-backed cache, `none` again avoids redundant work. Also tune `nr_requests` (queue depth — NVMe can profitably run deep, e.g. 1024–4096) and `read_ahead_kb` (next).

**Recommended:** NVMe → `none`; SATA/SAS SSD → `mq-deadline` (or `none`); HDD → `mq-deadline`; virtio / HW-RAID-with-cache → `none`.

### 3.2 Read-ahead (`read_ahead_kb` / `blockdev --setra`)

**Mechanics.** On a detected sequential read pattern the kernel prefetches upcoming blocks into the page cache. `read_ahead_kb` (per block device, in KiB) caps how much it reads ahead; `blockdev --setra` expresses the same thing in 512-byte sectors.

**Set / Verify / Persist.**

```bash
cat /sys/block/nvme0n1/queue/read_ahead_kb     # default often 128
blockdev --getra /dev/nvme0n1                   # in 512B sectors
# raise for sequential/OLAP:
echo 4096 | sudo tee /sys/block/nvme0n1/queue/read_ahead_kb   # 4 MiB
# persist via the same udev rule mechanism as the scheduler
```

**PostgreSQL linkage.** Large read-ahead accelerates sequential scans, `VACUUM`, `pg_dump`/base backups, and any bulk read; it does little for pure random OLTP index lookups and can even waste bandwidth there. In **PostgreSQL 18**, the new ReadStream + AIO machinery issues its own overlapping read requests for sequential scans, bitmap heap scans, and VACUUM, so PostgreSQL relies less on kernel read-ahead for those paths — but *plain index scans* still benefit from OS read-ahead when index order roughly tracks heap order. Tune per workload: OLAP/DW → 2–8 MiB; OLTP → leave near default.

**Recommended:** 128 KiB (default) for OLTP; 2–8 MiB for OLAP/analytics and backup volumes.

### 3.3 Filesystem choice and mount options

**Mechanics / choice.** The two mainstream, battle-tested choices for PostgreSQL are **XFS** and **ext4**. XFS scales well to large files and high parallelism and is frequently preferred for big clusters; ext4 is rock-solid and ubiquitous. **ZFS** brings checksums, snapshots, and compression but introduces double-caching (its ARC vs the PostgreSQL/page-cache) and needs deliberate tuning (`recordsize=8k` for the data directory to match the PostgreSQL page, ARC sizing, and — because ZFS never overwrites in place — you can safely set `full_page_writes=off`, recovering WAL bandwidth). Btrfs is generally avoided for busy write workloads due to CoW fragmentation.

**Mount options.**

```bash
# /etc/fstab examples
UUID=... /var/lib/postgresql xfs   noatime,nodiratime            0 0
UUID=... /var/lib/postgresql ext4  noatime,nodiratime,data=ordered 0 0
```

- `noatime` (and `nodiratime`) — suppress access-time metadata writes on every read; standard for databases.
- ext4 `data=ordered` (default) is the safe journaling mode; `data=writeback` is faster but weakens ordering guarantees on crash — not worth the risk for a database.
- **Barriers / `nobarrier`** — barriers (write cache flushes) are what make `fsync` durable across a power loss when the device has a *volatile* write cache. **Do not** mount `nobarrier` unless your storage has a **battery-backed or flash-backed write cache (BBU/FBWC)** that makes the cache effectively non-volatile — then, and only then, disabling barriers is a large, safe write-performance win. Getting this wrong risks silent corruption on power failure.
- **`discard` vs periodic `fstrim`** — the continuous `discard` mount option issues a TRIM on every block free, adding latency to deletes/updates; prefer a scheduled `fstrim` (e.g. the `fstrim.timer` systemd unit, weekly) which batches TRIM during quiet periods.

**PostgreSQL linkage.** The filesystem is the substrate for both the heap/index files and WAL. Journaling mode and barriers define the durability contract that PostgreSQL's `fsync`/`wal_sync_method` rely on; `noatime` removes a class of pointless writes; placing WAL on its own low-latency filesystem/device isolates the sequential WAL stream from random data-file I/O.

**Recommended:** XFS or ext4, `noatime,nodiratime`; keep barriers **on** unless you have a verified BBU/FBWC; use periodic `fstrim`, not continuous `discard`; put WAL on a separate device where possible.

### 3.4 `fsync`, `O_DIRECT`, `wal_sync_method`, write caches, and "fsyncgate"

**Mechanics & linkage.** `fsync` is PostgreSQL's fundamental durability primitive: at commit (and at checkpoint) it forces WAL — and eventually data — from the OS page cache and the device's volatile cache onto durable media. **Never disable `fsync`** on a system whose data you care about; Percona's guidance is blunt about leaving it on. `wal_sync_method` chooses *how* WAL is flushed:

- `fdatasync` (Linux default) — buffered `write()` followed by `fdatasync()`; robust and the recommended default.
- `open_datasync` / `open_sync` — open WAL with `O_DSYNC`/`O_SYNC` (often `O_DIRECT`), so each write is synchronous; can be faster on some hardware but has historically interacted badly with WAL-buffer fill patterns.

Validate empirically with `pg_test_fsync` (it reports per-method fsync rates for your exact storage) before deviating from the default. Note PostgreSQL 18's separate **Direct I/O** work (`debug_io_direct`) is a developer/testing feature, not a production tuning switch — production still uses buffered I/O + fsync, and the new AIO accelerates **reads**, not WAL or data-file writes.

**Write caches / BBU.** A volatile controller/disk cache must be flushed by barriers+fsync; with a battery/flash-backed cache the acknowledged write is already durable, so you may safely relax barriers (see §3.3) for a big gain. Audit BBU health regularly — a dead battery silently turns a "safe" `nobarrier` config into a corruption risk.

**"fsyncgate" (important reliability history).** Prior to 2018, on Linux an `fsync()` that failed could have its error consumed and the dirty page silently marked clean, so a *subsequent* `fsync()` returned success while data was actually lost — a data-durability hole across many databases. PostgreSQL's fix (authored by Craig Ringer, committed by Thomas Munro, November 2018) changed the checkpointer to **PANIC on the first `fsync()` failure** and force crash recovery from the last good checkpoint rather than trusting a later success; it shipped in the February 14 2019 minor releases (11.2, 10.7, 9.6.12, 9.5.16, 9.4.21). The behavior is governed by the GUC `data_sync_retry` (default `off` = PANIC-and-recover, which is the safe setting). The practical consequence for a DBA: ensure your HA/failover is solid, because a genuine storage-level fsync failure will (correctly) crash the node.

**Alignment / layout.** Align partitions to the device erase-block/stripe; make RAID stripe sizes multiples of the 8 KiB page; segregate WAL (sequential, latency-critical) from data (random) onto different devices when you can.

**Recommended:** `fsync=on` always; `wal_sync_method=fdatasync` unless `pg_test_fsync` proves otherwise; barriers on unless verified BBU; WAL on its own low-latency device.

---

## 4. Kernel Scheduler and CPU

### 4.1 CPU frequency governor and C-states

**Mechanics.** Modern CPUs run at variable frequency and enter deep idle (C-)states to save power. The `cpufreq` governor decides the operating frequency: `powersave`/`ondemand`/`schedutil` scale up reactively from a low base; `performance` pins the maximum. Deep C-states (C3/C6…) save power but add wake-up latency of tens of microseconds when a core must service a request.

**Set / Verify / Persist.**

```bash
cpupower frequency-info                      # driver + current governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
sudo cpupower frequency-set -g performance   # runtime, all CPUs
# persist: cpupower.service, a TuneD profile, or GRUB.
# Also limit idle depth for lowest latency:
#   GRUB_CMDLINE_LINUX="... intel_idle.max_cstate=1 processor.max_cstate=1"
# Or apply a TuneD profile that does all of this:
sudo tuned-adm profile throughput-performance   # (or latency-performance)
```

**PostgreSQL linkage.** OLTP is full of short transactions and idle-then-burst patterns. With a reactive governor, each burst pays a ramp-up penalty while the core climbs from a low P-state, and each wake from a deep C-state pays an exit-latency penalty — both inflate commit latency and add jitter to a workload that lives or dies on p99. Pinning `performance` and limiting C-states trades electricity for predictable low latency. (Microsoft's own tuned profile for SQL Server on Linux sets the governor and energy-performance bias identically, for the same reason.)

**Recommended:** governor `performance`; limit deep C-states on latency-critical OLTP; a `latency-performance`/`throughput-performance` TuneD profile packages this cleanly.

### 4.2 Scheduler class and tunables (CFS → EEVDF)

**Mechanics.** Kernels through 6.5 use CFS (Completely Fair Scheduler); 6.6+ replaces it with **EEVDF** (Earliest Eligible Virtual Deadline First). Relevant knobs:

- `kernel.sched_migration_cost_ns` — how "expensive" the scheduler assumes a cross-core migration is; a higher value makes it *less* eager to migrate a runnable task, preserving cache/TLB warmth. Raising it (e.g. to `5000000` = 5 ms) can help many-connection servers keep backends on warm cores.
- `kernel.sched_autogroup_enabled` — automatically groups tasks by session for desktop interactivity; on a server this can *deprioritize* database processes relative to unrelated activity, so it is commonly disabled (`0`).
- `kernel.sched_latency_ns`, `kernel.sched_min_granularity_ns` — CFS target-latency/granularity knobs (absent/renamed under EEVDF); test before touching.

**Set / Verify / Persist.**

```bash
sysctl kernel.sched_migration_cost_ns kernel.sched_autogroup_enabled
sudo sysctl -w kernel.sched_migration_cost_ns=5000000
sudo sysctl -w kernel.sched_autogroup_enabled=0
```

**PostgreSQL linkage.** These are *second-order* compared with memory and I/O tuning; the gains are modest and workload-specific. The clearest wins are disabling autogroup on a dedicated server and nudging `sched_migration_cost_ns` up on high-connection OLTP to reduce backend "core hopping" that cold-starts caches. Measure before and after; do not cargo-cult.

**Recommended:** `sched_autogroup_enabled=0` on servers; consider raising `sched_migration_cost_ns` on high-connection OLTP after measurement. Leave EEVDF/CFS internals alone unless profiling justifies a change.

### 4.3 CPU affinity / IRQ affinity

**Mechanics & linkage.** By default let the scheduler place backends; explicit pinning trades flexibility for locality and is worth it only in extreme, well-measured NUMA cases (e.g. pinning the postmaster and its children to the node whose memory holds the shared segment). Separately, keep `irqbalance` running — or manually pin NVMe/NIC interrupts across cores — so interrupt handling for storage and network is spread rather than hammering one core, which otherwise becomes a latency bottleneck under heavy I/O or high connection rates.

**Recommended:** default (unpinned) for most; pin only with measured NUMA justification; keep IRQs balanced.

---

## 5. Network Parameters

Relevant to connection-heavy front-ends, poolers, and streaming replication. On a quiet LAN the defaults are usually fine; these matter under connection storms, high fan-in, or long-fat replication links.

### 5.1 Listen and accept queues: `net.core.somaxconn`, `net.ipv4.tcp_max_syn_backlog`, `net.core.netdev_max_backlog`

**Mechanics.** A new TCP connection traverses two queues: the **SYN queue** (half-open, sized by `tcp_max_syn_backlog`) during the handshake, and the **accept queue** (fully established, waiting for the app to `accept()`, capped by the smaller of the app's `listen()` backlog and `net.core.somaxconn`). `net.core.netdev_max_backlog` is the per-CPU queue for packets the NIC has received but the stack hasn't yet processed.

**Set / Verify / Persist.**

```bash
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog
sudo sysctl -w net.core.somaxconn=4096
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=8192
sudo sysctl -w net.core.netdev_max_backlog=16384
ss -ltn                                   # Recv-Q vs Send-Q on the listener shows accept-queue pressure
```

**PostgreSQL linkage.** PostgreSQL passes a backlog to `listen()`; if the accept queue overflows during a burst of new connections (thundering herd after a failover, or a pooler reconnect storm), clients see resets / "connection refused." Raising `somaxconn` and the SYN backlog absorbs bursts. `netdev_max_backlog` matters on 10 GbE+ where packet arrival can outrun softirq processing. **But** the deeper fix for connection-heavy PostgreSQL is a **connection pooler** (PgBouncer/pgcat) rather than a very high `max_connections`, because each PostgreSQL backend is a process with real memory and scheduling cost — kernel queue tuning handles *bursts*, pooling handles *sustained* concurrency.

**Recommended:** `somaxconn=1024–4096+`, `tcp_max_syn_backlog=4096–8192`, `netdev_max_backlog≈16384` on fast NICs — alongside, not instead of, connection pooling.

### 5.2 TCP buffers: `net.core.rmem_max`/`wmem_max`, `net.ipv4.tcp_rmem`/`tcp_wmem`

**Mechanics.** TCP throughput on a link is bounded by (window size ÷ round-trip time). The `tcp_rmem`/`tcp_wmem` triples are `min default max` bytes for auto-tuned per-socket receive/send buffers; `rmem_max`/`wmem_max` cap what applications may request via `setsockopt`. Linux auto-tunes within these bounds when `tcp_moderate_rcvbuf=1` (default on).

**Set / Verify / Persist.**

```bash
sudo sysctl -w net.core.rmem_max=16777216
sudo sysctl -w net.core.wmem_max=16777216
sudo sysctl -w net.ipv4.tcp_rmem='4096 87380 16777216'
sudo sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216'
```

**PostgreSQL linkage.** Larger maxima help high bandwidth-delay-product paths — most notably **streaming replication** or base backups across a WAN/cross-AZ link, where small windows throttle WAL shipping and grow replica lag. On a low-latency LAN the defaults already saturate the link; don't inflate buffers without a BDP reason (over-buffering adds latency/bufferbloat).

**Recommended:** 16 MiB maxima on 1–10 GbE with meaningful RTT (replication/backup over distance); defaults on quiet LANs.

### 5.3 Port range and TIME_WAIT: `ip_local_port_range`, `tcp_tw_reuse`, `tcp_fin_timeout`

**Mechanics.** Outbound connections draw an ephemeral source port from `ip_local_port_range`; exhausting it blocks new outbound connections. Closed connections linger in `TIME_WAIT` for `2×MSL` to absorb stray packets; `tcp_fin_timeout` bounds the `FIN_WAIT_2` state, and `tcp_tw_reuse=1` lets the kernel safely reuse a `TIME_WAIT` socket for a *new outbound* connection when timestamps make it safe.

**Set / Verify / Persist.**

```bash
sudo sysctl -w net.ipv4.ip_local_port_range='1024 65535'
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
sudo sysctl -w net.ipv4.tcp_fin_timeout=30
```

**PostgreSQL linkage.** These matter on hosts that *originate* many short-lived connections: a **PgBouncer** in front of PostgreSQL, or an application tier, or a replica making many connections. Widening the port range and enabling `tcp_tw_reuse` prevents ephemeral-port exhaustion under churn. **Never** set the old `net.ipv4.tcp_tw_recycle` — it broke connections through NAT and behind load balancers and was *removed* in kernel 4.12; `tcp_tw_reuse` is the safe modern control.

**Recommended:** widen `ip_local_port_range` and set `tcp_tw_reuse=1` on connection-originating hosts; leave `tcp_tw_recycle` alone (gone).

### 5.4 Keepalives: kernel `tcp_keepalive_*` and PostgreSQL's `tcp_keepalives_*` / `client_connection_check_interval` / `tcp_user_timeout`

**Mechanics.** TCP keepalive probes detect a peer that has vanished *without* a clean close (crash, cable pull, dead NAT mapping). Kernel defaults are conservative: `net.ipv4.tcp_keepalive_time=7200` (first probe after 2 h idle), `tcp_keepalive_intvl=75` (75 s between probes), `tcp_keepalive_probes=9` (declare dead after 9 failures) — so by default a dead idle peer isn't noticed for over two hours.

**Set / Verify / Persist.**

Kernel (affects all sockets):

```bash
sudo sysctl -w net.ipv4.tcp_keepalive_time=60
sudo sysctl -w net.ipv4.tcp_keepalive_intvl=10
sudo sysctl -w net.ipv4.tcp_keepalive_probes=6
```

PostgreSQL-scoped (postgresql.conf — a value of `0` means "use the OS default"):

```
tcp_keepalives_idle = 60
tcp_keepalives_interval = 10
tcp_keepalives_count = 6
tcp_user_timeout = 0                       # ms; retransmit-based dead-peer detection
client_connection_check_interval = 10s     # PG14+, Linux-only
```

**PostgreSQL linkage.** Two distinct problems. (1) **Dead replication / dead idle clients**: without tuning, a crashed replica or a client that disappeared can hold a server-side backend and its resources (locks, an open transaction, a replication slot's attention) for hours. Tightening keepalives — kernel-wide or via PostgreSQL's per-server GUCs — makes the server reap those dead connections in minute(s). (2) **A client that vanishes mid-query**: keepalives only probe *idle* connections, so a backend running a long query for a now-dead client won't notice until it next writes to the socket. PostgreSQL 14 added `client_connection_check_interval` (Linux-only) which periodically checks whether the client is still there and *cancels the running query* if not — invaluable for killing expensive queries whose requester has gone. `tcp_user_timeout` bounds how long transmitted-but-unacked data waits before the connection is declared dead, catching cases keepalive misses. As Laurenz Albe quips, keepalive would be more honestly named "detect-dead." Keeping PostgreSQL's GUCs (rather than only the kernel knobs) lets you tune the database's connections without changing global TCP behavior for everything else on the host.

**Recommended:** set PostgreSQL's `tcp_keepalives_idle/interval/count` (e.g. 60/10/6) and `client_connection_check_interval≈10s` (PG14+); use `tcp_user_timeout` where retransmit-based detection is needed; tune kernel keepalives if you want the tighter behavior host-wide.

---

## 6. Process / Resource Limits, systemd, and cgroups

### 6.1 File descriptors: `nofile` / `LimitNOFILE` / `max_files_per_process`

**Mechanics & linkage.** Every connection socket, every open relation segment, and every WAL/temp file consumes a file descriptor. A busy PostgreSQL with many connections × many touched relations can need far more than the default 1024. Raise the limit for the postgres user (`limits.conf`) *and* in the systemd unit (systemd ignores PAM limits for services), or cap PostgreSQL's own appetite with `max_files_per_process` so it never exceeds what the OS grants.

```bash
# PAM (for shell/non-systemd starts): /etc/security/limits.d/postgresql.conf
postgres soft nofile 65536
postgres hard nofile 65536
# systemd unit drop-in (authoritative for service starts):
#   [Service]
#   LimitNOFILE=65536
```

Verify from inside a live backend's `/proc/<pid>/limits`, or `SHOW max_files_per_process;`.

**Recommended:** `LimitNOFILE=65536+`; set `max_files_per_process` conservatively if the OS ceiling is a concern.

### 6.2 Processes and locked memory: `nproc` / `LimitNPROC`, `memlock` / `LimitMEMLOCK`

**Mechanics & linkage.** Each backend, background worker, parallel worker, and autovacuum worker is a process — high `max_connections` plus parallelism needs `nproc`/`LimitNPROC` headroom or `fork()` fails. **`memlock`/`LimitMEMLOCK`** governs how much memory the process may *pin*; explicit huge pages require locking the whole shared segment, so if `LimitMEMLOCK` is too low, `huge_pages=on` fails to start (and `try` silently falls back to 4 KiB pages, quietly forfeiting the benefit). Setting `LimitMEMLOCK=infinity` in the unit is the standard fix.

```
# systemd unit drop-in
[Service]
LimitNPROC=infinity
LimitMEMLOCK=infinity
```

**Recommended:** `LimitNPROC` generous; `LimitMEMLOCK=infinity` when using huge pages.

### 6.3 systemd specifics: `OOMScoreAdjust`, `RemoveIPC`, core limits

**`OOMScoreAdjust=-1000`** in the unit is the systemd-native way to protect the postmaster (see §1.9). **`RemoveIPC`** in `/etc/systemd/logind.conf` is a notorious footgun: if `on`, systemd removes POSIX shared memory and semaphores belonging to a user when that user's last session ends — which can rip out PostgreSQL's shared-memory/semaphores from under a running server started outside a persistent session, causing "could not remove shared memory segment" errors and breaking parallel query. Set `RemoveIPC=no` on database hosts. For debugging, allow core dumps with `LimitCORE=infinity` in the unit plus a sane `kernel.core_pattern` (see §8).

```
# /etc/systemd/logind.conf
RemoveIPC=no
```

### 6.4 System V IPC: `kernel.shmmax`, `kernel.shmall`, `kernel.shmmni`, `kernel.sem`

**Mechanics.** These cap System V shared memory (max segment size, total pages, number of segments) and semaphores. Historically PostgreSQL needed large `shmmax`/`shmall` to start.

**PostgreSQL linkage — mostly historical for shm.** Since **9.3**, PostgreSQL allocates its main shared memory as **POSIX shared memory via `mmap`** (`shared_memory_type=mmap`, the default), so it now needs only a tiny (~48-byte) SysV segment as a startup interlock. Consequently `shmmax`/`shmall` almost never need raising on modern PostgreSQL — a common misconception when configuring modern database versions. They regain relevance only if you force `shared_memory_type=sysv`, or for huge-page accounting.

**Semaphores still matter.** PostgreSQL needs one semaphore per potential backend plus autovacuum workers, background workers, and WAL senders, allocated in sets of 16 (plus one "magic" semaphore per set). On Linux, PostgreSQL uses unnamed POSIX semaphores by default (no fixed kernel ceiling), but if using SysV semaphores you must ensure `SEMMNI ≥ ceil((max_connections + autovacuum_max_workers + max_worker_processes + 5) / 16)`, `SEMMSL ≥ 17`, and `SEMMNS` sized to match. A typical safe line covers hundreds of connections:

```
kernel.sem = 250 32000 100 128     # SEMMSL SEMMNS SEMOPM SEMMNI
```

The classic exhaustion symptom is the confusingly-worded `semget: No space left on device` at startup.

**Recommended:** leave `shmmax`/`shmall` at distro defaults for PostgreSQL ≥ 9.3; set `kernel.sem = 250 32000 100 128` (or larger `SEMMNI` for very high connection counts) if relying on SysV semaphores.

### 6.5 cgroup v2 (containers / Kubernetes): `MemoryMax`, `MemoryHigh`, `MemorySwapMax`, PSI

**Mechanics & linkage.** In containers the memory story shifts from overcommit to cgroups. `memory.max` (systemd `MemoryMax`) is a hard ceiling: crossing it triggers an in-cgroup OOM kill (SIGKILL, no ENOMEM grace) — so `vm.overcommit_memory=2` does **not** protect a containerized PostgreSQL; you must size the cgroup. `memory.high` (`MemoryHigh`) is a softer throttle that induces heavy reclaim before the hard kill, giving you a warning band. Set `MemorySwapMax=0` to forbid swap in the cgroup. Because the page cache counts against the cgroup, size `MemoryMax` roughly 20–30% above measured peak RSS to leave room for cache, and set `MemoryHigh` ~10–20% below `MemoryMax` as the reclaim throttle. Watch **PSI** (`memory.pressure`, the `some avg10` field) as an early-warning signal of memory stress. Caveat: inside a nested cgroup a child may report `max` while actually constrained by a parent — read *effective* limits, not just the local file.

```
# systemd unit or k8s-managed slice
[Service]
MemoryHigh=52G
MemoryMax=64G
MemorySwapMax=0
```

**Recommended (containers):** size `MemoryMax` ≈ peak + 25%, `MemoryHigh` ≈ 10–20% below that, `MemorySwapMax=0`; monitor `memory.pressure`.

---

## 7. Time / Clock

### 7.1 `clocksource` (tsc vs hpet vs acpi_pm)

**Mechanics.** The kernel reads wall-clock/monotonic time from a hardware clocksource. `tsc` (the CPU's timestamp counter) is read with a single cheap register instruction; `hpet` is a memory-mapped timer (much slower); `acpi_pm` is slower still. Modern CPUs have *invariant* TSC (constant rate regardless of frequency scaling), making `tsc` both fast and reliable — but the kernel falls back to a slower source if it distrusts the TSC (old CPUs, certain hypervisors, aggressive power management).

**Set / Verify / Persist.**

```bash
cat /sys/devices/system/clocksource/clocksource0/available_clocksource
cat /sys/devices/system/clocksource/clocksource0/current_clocksource
# force tsc where appropriate (validate stability first!):
#   GRUB_CMDLINE_LINUX="... clocksource=tsc tsc=reliable"
```

**PostgreSQL linkage.** `EXPLAIN ANALYZE`, `track_io_timing`, `pg_stat_statements` timing, and `log_duration` all call `clock_gettime`/`gettimeofday` — potentially *per plan node and per row*. On a slow clocksource this instrumentation overhead explodes. The PostgreSQL `pg_test_timing` docs illustrate the gap: on one Intel i7-860, per-loop timing including overhead was about 36 ns on TSC versus about 723 ns after switching to `acpi_pm` — a ~20× penalty — and a fully-timed `count(*)` ran roughly 70% longer purely from timing overhead, with a sample `EXPLAIN ANALYZE` ballooning to ~116 ms on the slow source. Practically: run `pg_test_timing` on every server; if `tsc` isn't selected, find out why before forcing it (an unstable TSC forced on can make the clock go backwards).

**Recommended:** `tsc` where the kernel deems it reliable; verify with `pg_test_timing`; investigate before overriding.

---

## 8. Debugging, HA, and Miscellaneous

### 8.1 `kernel.core_pattern` and `LimitCORE`

**Mechanics & linkage.** When a backend crashes, a core dump is invaluable for post-mortem `gdb` analysis. `kernel.core_pattern` sets where cores go (a path template, or a `|pipe` to a handler like `systemd-coredump`), and the process must be allowed a nonzero core size (`ulimit -c` / systemd `LimitCORE`). For a database, capturing a backend core after a segfault often distinguishes a data-corruption bug from a hardware fault.

```bash
cat /proc/sys/kernel/core_pattern
sudo sysctl -w kernel.core_pattern='/var/lib/postgresql/cores/core.%e.%p.%t'
# ensure LimitCORE=infinity in the unit, and the directory is writable by postgres
```

### 8.2 `kernel.yama.ptrace_scope`

**Mechanics & linkage.** Yama's `ptrace_scope=1` (common default) forbids attaching a debugger/tracer to a process that isn't your direct child — which blocks `gdb -p`, `strace -p`, and some `perf` attaches against a *running* backend. To live-debug a stuck backend you temporarily set it to `0`; revert afterwards, since it is a hardening control.

```bash
cat /proc/sys/kernel/yama/ptrace_scope
sudo sysctl -w kernel.yama.ptrace_scope=0     # temporary, for debugging
```

### 8.3 `kernel.perf_event_paranoid` (and `kptr_restrict`)

**Mechanics & linkage.** `perf_event_paranoid` gates how much unprivileged `perf` may see; the default (`2` or higher on hardened kernels) blocks the kernel-level sampling needed for CPU flame graphs of PostgreSQL backends. Lower it to `1` or `-1` (transiently, ideally on non-prod) to profile; pair with `kernel.kptr_restrict=0` to resolve kernel symbols. From kernel 5.9 you can instead grant `perf` `CAP_PERFMON` rather than relaxing the sysctl globally — the more secure route.

```bash
sudo sysctl -w kernel.perf_event_paranoid=-1
sudo sysctl -w kernel.kptr_restrict=0
# then: perf record -F 99 -p <backend_pid> -g -- sleep 30
```

### 8.4 `kernel.panic` / `kernel.panic_on_oops` (HA fencing)

**Mechanics & linkage.** In an HA cluster you often *want* a sick node to reboot fast so the cluster can fail over cleanly (a form of self-fencing). `kernel.panic=<seconds>` auto-reboots that many seconds after a panic; `kernel.panic_on_oops=1` escalates a kernel oops into a full panic (and thus reboot) rather than leaving the node in a half-dead, split-brain-prone state.

```bash
sudo sysctl -w kernel.panic=10
sudo sysctl -w kernel.panic_on_oops=1
```

Coordinate with your cluster manager (Patroni + watchdog, Pacemaker/STONITH) so the reboot behavior matches the fencing design.

### 8.5 Entropy / randomness for TLS

**Mechanics & linkage.** TLS handshakes and some auth paths need cryptographic randomness. On modern kernels `getrandom()` + hardware RDRAND rarely starve, but on old kernels or minimal VMs entropy exhaustion can stall the first connections after boot; `rng-tools`/`haveged` mitigate. Rarely an issue on current systems, but worth knowing if TLS connection setup mysteriously hangs on a fresh minimal VM.

### 8.6 PostgreSQL 18 asynchronous I/O and `kernel.io_uring_disabled`

**Mechanics.** PostgreSQL 18 introduces asynchronous I/O via a pluggable `io_method`:

- `worker` (**default**) — a pool of dedicated I/O worker processes (`io_workers`, default 3) performs I/O on behalf of backends; portable, needs no special kernel feature.
- `io_uring` — uses Linux's `io_uring` submission/completion rings for true async syscalls; requires a build `--with-liburing`, kernel ≥ 5.1, and that `io_uring` not be disabled by the sysctl below.
- `sync` — the classic synchronous behavior.

`kernel.io_uring_disabled` (kernel 6.6+) has three values: `0` = any process may create `io_uring` instances; `1` = restricted to privileged processes / a designated `io_uring_group`; `2` = disabled entirely.

**Set / Verify.**

```bash
cat /proc/sys/kernel/io_uring_disabled        # need 0 to use io_method=io_uring
sudo sysctl -w kernel.io_uring_disabled=0
# postgresql.conf:
#   io_method = worker        # default, safe
#   io_workers = 3
#   # or, if built with liburing and you accept the security posture:
#   io_method = io_uring
```

**PostgreSQL linkage.** AIO lets PostgreSQL issue overlapping reads and continue useful work while the kernel fetches data — a real win on high-latency storage (cloud EBS-class volumes), where sequential scans, bitmap heap scans, and `VACUUM`/`ANALYZE` can see multi-fold read-throughput improvements. AIO in 18 accelerates **reads only** — not writes and not WAL. `effective_io_concurrency` becomes an *active* control of read parallelism (its default was **raised from 1 to 16** in PG18); related knobs include `maintenance_io_concurrency` (16), `io_combine_limit`/`io_max_combine_limit` (128 kB), and `io_max_concurrency` (−1 = auto, capped at 64). Effective read-ahead depth ≈ `effective_io_concurrency × io_combine_limit`.

**Security note (why `worker` is the default).** `io_uring` has a significant kernel-exploit history — Google reported it featured in a majority of the Linux kernel exploits it found in a 2022 window, and, as credativ's deep-dive notes, it bypasses traditional syscall audit paths, complicating security monitoring. That is precisely why PostgreSQL ships `worker` as the default and treats `io_uring` as an opt-in for environments that have weighed the trade-off.

**Recommended:** start with `io_method=worker`; benchmark `io_uring` (set `kernel.io_uring_disabled=0`, ensure a liburing build) on high-latency cloud storage; tune `effective_io_concurrency`/`io_workers` from measurement.

---

## 9. Rollout Plan

Apply in stages, measuring between stages; keep prior values for rollback; manage everything via `/etc/sysctl.d/`, udev rules, and systemd drop-ins for auditability.

**Stage 1 — baseline (any dedicated host):**
`vm.swappiness=1`; `vm.overcommit_memory=2` (+ ratio/kbytes); postmaster `OOMScoreAdjust=-1000` with `PG_OOM_ADJUST_*` for children; disable THP; `vm.zone_reclaim_mode=0` and (NUMA) `kernel.numa_balancing=0`; I/O scheduler `none` on NVMe; `noatime` + periodic `fstrim`; CPU governor `performance`; `LimitNOFILE`/`LimitNPROC`/`LimitMEMLOCK` in the unit; `RemoveIPC=no`.

**Stage 2 — size to workload:**
explicit huge pages sized from `shared_memory_size_in_huge_pages`, `huge_pages=on` once stable (verify `huge_pages_status`); absolute `vm.dirty_*_bytes` tuned to device bandwidth (verify checkpoint smoothness via `pg_stat_bgwriter` / `pg_stat_io`); confirm `tsc` clocksource with `pg_test_timing`; tune `somaxconn`/backlogs/keepalives + `client_connection_check_interval` for the connection and replication topology; deploy a **connection pooler** rather than inflating `max_connections`.

**Stage 3 — advanced / version-specific:**
on PG18 benchmark `io_method=worker` vs `io_uring` (`kernel.io_uring_disabled=0`, liburing build) and tune `effective_io_concurrency`/`io_workers`; in containers set cgroup `MemoryMax`/`MemoryHigh` + `MemorySwapMax=0` and watch PSI.

**Diagnostic triggers that should send you back to a knob:**
- Rising backend writes / checkpoint I/O spikes in `pg_stat_io`/`pg_stat_bgwriter` → tighten `vm.dirty_*_bytes`, raise `max_wal_size`/`checkpoint_completion_target`.
- High `sys` CPU with memory-compaction functions in a `perf` profile → THP is still enabled somewhere.
- High p99 on NVMe under mixed load → test `mq-deadline` and measure tail latency (e.g. `blktrace`/`btt` Q2D vs D2C).
- OOM events in `dmesg` → re-budget memory / cgroup limits; confirm postmaster `oom_score_adj=-1000`.
- Replica lag on a distant link → raise TCP buffer maxima (BDP), check keepalives.

---

## 10. Caveats

- Kernel tuning is hardware- and workload-specific; there are **no universal values** for dirty limits, read-ahead, or TCP buffers — measure on your box. Percona notes plainly that OS tuning is harder to prescribe than database tuning and that beyond the high-impact knobs the extra gains are often small.
- Genuine community disagreements exist and are flagged above: `vm.swappiness` (0 vs 1 vs 60) and whether to `numactl --interleave`. This document takes the predictable-latency position but names the alternatives.
- The newest items — `kernel.io_uring_disabled`, PG18 AIO defaults, PG18/PG19 NUMA features — are evolving; verify against your exact PostgreSQL minor version and kernel.
- Do not paste third-party sysctl bundles blindly. The infamous example is `net.ipv4.tcp_tw_recycle=1`, which breaks NAT/load-balanced clients and was removed in kernel 4.12. Test on staging, keep rollback values, and persist changes through `/etc/sysctl.d/`, udev, and systemd drop-ins so they survive reboots and are auditable.

---

## 11. Cheat-Sheet: Recommended Values for a Dedicated PostgreSQL Production Server

| Parameter | Where set | Default | Recommended (dedicated) | One-line rationale |
|---|---|---|---|---|
| `vm.overcommit_memory` | sysctl | 0 | 2 | Backend gets ENOMEM instead of OOM-killing the postmaster |
| `vm.overcommit_ratio` | sysctl | 50 | ~80 (or `overcommit_kbytes`) | Sets `CommitLimit`; budget to shared_buffers+work_mem |
| `vm.swappiness` | sysctl | 60 | 1 | Keep backends resident; 1 (not 0) keeps swap as last resort |
| `vm.dirty_background_bytes` | sysctl | 0 (ratio 10) | 64–256 MiB | Start writeback early; avoid checkpoint fsync storms |
| `vm.dirty_bytes` | sysctl | 0 (ratio 20) | 256 MiB–1 GiB | Bound dirty pool; keep `> background` |
| `vm.dirty_expire_centisecs` | sysctl | 3000 | 500–3000 | Lower ages pages out faster on latency-sensitive OLTP |
| `vm.zone_reclaim_mode` | sysctl | auto (often 1) | 0 | Don't evict page cache instead of using remote RAM |
| `kernel.numa_balancing` | sysctl | 1 | 0 | Stop pointless migration of globally-shared buffers |
| `vm.nr_hugepages` | sysctl/GRUB | 0 | `shared_memory_size_in_huge_pages` + headroom | TLB efficiency; segment never swapped |
| THP `enabled`/`defrag` | /sys or GRUB | madvise/always | never (or madvise) | Avoid khugepaged latency spikes; enable before huge pages |
| `vm.max_map_count` | sysctl | 65530 | 262144 | Headroom for many partitions/extensions/parallelism |
| `vm.min_free_kbytes` | sysctl | auto | 1–2 GiB (big-RAM) | Reduce reclaim-stall jitter |
| postmaster `oom_score_adj` | systemd/proc | 0 | −1000 (children reset to 0) | OOM sacrifices a backend, never the postmaster |
| `vm.oom_kill_allocating_task` | sysctl | 0 | 0 | Kill fattest process, not whoever faulted |
| I/O scheduler (NVMe) | /sys + udev | none | none | Firmware schedules better than software |
| I/O scheduler (SSD/HDD) | /sys + udev | mq-deadline | mq-deadline | Bounded worst-case latency |
| `read_ahead_kb` | /sys / blockdev | 128 | 128 (OLTP) / 2–8 MiB (OLAP) | Prefetch helps sequential, not random |
| Mount options | fstab | relatime | `noatime,nodiratime` | Kill pointless atime writes |
| Barriers | fstab | on | on (off only w/ verified BBU/FBWC) | Durability contract for fsync |
| TRIM | systemd timer | — | periodic `fstrim` (not `discard`) | Avoid per-delete latency |
| `fsync` | postgresql.conf | on | on (never off) | Fundamental durability primitive |
| `wal_sync_method` | postgresql.conf | fdatasync | fdatasync (verify `pg_test_fsync`) | Robust default |
| `data_sync_retry` | postgresql.conf | off | off (PANIC-and-recover) | Correct post-fsyncgate behavior |
| CPU governor | /sys cpufreq | powersave/schedutil | performance | No ramp-up penalty on bursty OLTP |
| C-states | GRUB/TuneD | deep | limit on latency-critical OLTP | Cut wake-up latency |
| `kernel.sched_autogroup_enabled` | sysctl | 1 | 0 | Don't deprioritize DB on a server |
| `kernel.sched_migration_cost_ns` | sysctl | 500000 | ~5000000 (high-conn) | Keep backends on warm cores |
| `net.core.somaxconn` | sysctl | 128/4096 | 1024–4096+ | Absorb connection bursts |
| `net.ipv4.tcp_max_syn_backlog` | sysctl | varies | 4096–8192 | SYN-queue headroom |
| `net.core.netdev_max_backlog` | sysctl | 1000 | 16384 | 10 GbE+ ingress |
| `net.core.rmem_max`/`wmem_max` | sysctl | ~212 KiB | 16 MiB | High-BDP replication/backup links |
| `net.ipv4.tcp_rmem`/`tcp_wmem` | sysctl | 4096 87380 6291456 | max 16777216 | Same; keep autotuning on |
| `net.ipv4.ip_local_port_range` | sysctl | 32768 60999 | 1024 65535 | Ephemeral ports for poolers/replicas |
| `net.ipv4.tcp_tw_reuse` | sysctl | 2 | 1 | Reuse TIME_WAIT safely (never `tcp_tw_recycle`) |
| `tcp_keepalives_idle/interval/count` | postgresql.conf | 0 (OS: 7200/75/9) | 60/10/6 | Reap dead replicas/idle clients fast |
| `client_connection_check_interval` | postgresql.conf | 0 | ~10s (PG14+, Linux) | Cancel query when client vanished |
| `LimitNOFILE` | systemd | 1024 | 65536+ | FDs for connections + relation files |
| `LimitMEMLOCK` | systemd | 64K | infinity | Required to lock huge pages |
| `LimitNPROC` | systemd | varies | generous/infinity | Backends + parallel/autovacuum workers |
| `RemoveIPC` | logind.conf | on (some distros) | no | Stop systemd deleting PG shm/semaphores |
| `kernel.sem` | sysctl | varies | 250 32000 100 128 | Semaphores for connections + workers (if SysV) |
| `kernel.shmmax`/`shmall` | sysctl | large | distro default | POSIX mmap shm since PG 9.3 — rarely needs raising |
| `clocksource` | /sys + GRUB | tsc (usually) | tsc (verify `pg_test_timing`) | Fast `EXPLAIN ANALYZE`/timing |
| `kernel.yama.ptrace_scope` | sysctl | 1 | 0 (transient, for gdb/strace) | Allow attaching to running backends |
| `kernel.perf_event_paranoid` | sysctl | 2+ | −1 or 1 (transient/non-prod) | Allow `perf` profiling |
| `kernel.panic` / `panic_on_oops` | sysctl | 0 / varies | panic=10, panic_on_oops=1 | Fast self-fence for HA failover |
| `kernel.io_uring_disabled` | sysctl | 0 | 0 (only if using io_uring) | Kernel 6.6+; gate for PG18 `io_method=io_uring` |
| `io_method` (PG18) | postgresql.conf | worker | worker (test io_uring) | Safe default; io_uring opt-in |
| `effective_io_concurrency` (PG18) | postgresql.conf | 16 | 16–200 (SSD/NVMe, measure) | Read parallelism under AIO |
| `MemoryMax`/`MemoryHigh` (cgroup) | systemd | infinity | Max ≈ peak+25%, High ~10–20% below | Container memory ceiling + throttle band |
| `MemorySwapMax` (cgroup) | systemd | — | 0 | Forbid swap in the cgroup |

---

*End of reference.*
