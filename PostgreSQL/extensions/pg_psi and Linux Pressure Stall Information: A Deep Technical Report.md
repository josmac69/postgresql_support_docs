# pg_psi and Linux Pressure Stall Information: A Deep Technical Report

## TL;DR
- **pg_psi is authored by Cédric Villemain of Data Bene — not Joe Conway/Crunchy Data.** It is an early-stage (v0.1, October 2024) PostgreSQL C extension, licensed under the PostgreSQL License, hosted on Data Bene's Forgejo instance at `git.data-bene.io/cedric/pg_psi`. It exposes two functions: `pg_psi_read(text)` (a set-returning parser of `/proc/pressure/{cpu,memory,io}`) and `pg_psi_poll(...)` (a blocking poll()-based PSI trigger monitor), plus a `psi_trigger` config table. It does NOT currently support per-cgroup granularity — it hardcodes the system-wide `/proc/pressure/*` paths.
- **The Linux kernel PSI feature (Johannes Weiner, Facebook, with polling support by Suren Baghdasaryan, Google; merged in 4.20) is the real substance.** It quantifies resource *saturation* (lost work due to contention) rather than *utilization*, computing "some"/"full" stall percentages as EMAs over 10/60/300-second windows plus a monotonic total stall time in microseconds, exposed system-wide via `/proc/pressure/*` and per-cgroup via cgroup v2 `{cpu,memory,io}.pressure` files, with writable trigger/poll support.
- **For production Postgres monitoring today, pgnodemx (Joe Conway/Crunchy Data) or node_exporter's PSI collector are the more mature choices;** pg_psi's genuinely novel contribution is *in-database reactive triggering* (via `pg_psi_poll`) that lets Postgres itself react to pressure — the "admission control" idea from Villemain's POSETTE 2025 talk. Treat pg_psi as experimental/proof-of-concept, not production-ready.

## Key Findings

### 1. Authorship correction
The task brief hypothesized Joe Conway / Crunchy Data authorship. This is **incorrect and should be corrected in any downstream use**. pg_psi is written and maintained by **Cédric Villemain** (founder/CEO of Data Bene, formerly 2ndQuadrant France; long-time PostgreSQL contributor, author of pgfincore). The likely source of the confusion is that Joe Conway *does* maintain a conceptually adjacent Crunchy Data extension, **pgnodemx**, which reads cgroup and `/proc` metrics (including PSI files) via SQL. Both are covered below.

Repository: `https://git.data-bene.io/cedric/pg_psi` (a self-hosted Forgejo forge, version 15.0.2). As of the latest commit (`8355b72103`, "Support multiple triggers to poll", 2024-10-24), the repo has 6 commits, 1 branch, 0 tags, ~26 KiB, and language breakdown C 82.2% / PLpgSQL 16.5% / Makefile 1.3%. License: PostgreSQL License. Current version: **0.1** (first tagged in `pg_psi--0.1.sql`). There is no packaged/PGXN release; it must be built from source.

### 2. PSI is a saturation metric, not a utilization metric
This is the conceptual crux for a senior DBA. Load average, `vmstat`, and `iostat` measure *how much* work is happening or *how many* tasks are runnable — they cannot cleanly tell you *how much potential work was lost* to contention. PSI measures exactly that: the percentage of wall-clock time during which tasks were stalled waiting for CPU, memory, or I/O. Per the kernel's own FAQ, load average is a raw count of active tasks that requires you to know CPU count and allowed CPU quota to interpret; PSI reports a normalized 0–100% "quality of life" figure independent of core count, which is why it is far superior for detecting resource saturation. As a mnemonic: memory pressure of 20% means the workload could have run ~20% faster with more memory.

## Details

### A. pg_psi extension — complete API and implementation

**Files in the repo:** `pg_psi.c` (440 lines), `pg_psi--0.1.sql`, `pg_psi.control`, `Makefile` (PGXS), `README.pg_psi.md`, `sql/` and `expected/` regression directories.

**SQL API surface (from `pg_psi--0.1.sql`):**

The installer sets `SET search_path to '@extschema@';` — the default schema is `psi` (the README notes "default schema: psi (probably to change)").

1. **`pg_psi_read(text) RETURNS TABLE(scope text, avg10 real, avg60 real, avg300 real, total bigint)`** — `LANGUAGE C STRICT`, C symbol `pg_psi_read`. The argument is the resource: `'cpu'`, `'memory'`, or `'io'`. Returns one row per scope line in the file (i.e., `some` and `full`; `cpu` returns only `some` on most kernels). Columns: `scope` (some/full), `avg10`/`avg60`/`avg300` (REAL — the kernel's percentage EMAs), `total` (BIGINT — cumulative stall microseconds since boot).

2. **`pg_psi_poll(resource text, scope text, threshold int, "window" int) RETURNS void`** — `LANGUAGE SQL STRICT`; a thin SQL wrapper that constructs a single-element array and calls the C variant: `SELECT pg_psi_poll(ARRAY[ROW(resource, scope, threshold, "window")])`.

3. **`pg_psi_poll(params anyarray) RETURNS void`** — `LANGUAGE C STRICT`, C symbol `pg_psi_poll`, `AS 'MODULE_PATHNAME'`. Accepts an array of `(resource, scope, threshold, window)` records so multiple triggers can be polled simultaneously.

4. **`psi_trigger` table** — a config table (not a function): `id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, scenario text, resource text, scope text, threshold int, "window" int, comment text`. It is seeded with nine rows across three scenarios (`light`, `moderate`, `high`) × three resources. The seeded defaults (thresholds/windows in microseconds):
   - light/cpu/some/100000/2000000; light/io/some/100000/2000000; light/memory/some/150000/2000000
   - moderate/cpu/some/200000/2000000; moderate/io/full/200000/2000000; moderate/memory/full/300000/2000000
   - high/cpu/some/500000/2000000; high/io/full/300000/2000000; high/memory/full/500000/2000000

   Intended usage pattern (from README):
   ```sql
   SELECT psi.pg_psi_poll((SELECT array_agg((resource, scope, threshold, "window"))
                           FROM psi.psi_trigger WHERE scenario = 'light'));
   ```

**C implementation details (`pg_psi.c`):**

- Includes `postgres.h`, `funcapi.h`, `utils/array.h`, `utils/builtins.h`, `utils/timestamp.h`, and `<poll.h>`. Declares `PG_MODULE_MAGIC`. `#define BUFFER_SISE 1024` (note the typo in the identifier).
- **Two structs:** `PSI { char scope[16]; float avg10, avg60, avg300; int64 total; }` and `PSITrigger { char filepath[MAXPGPATH]; const char *resource; const char *scope; int threshold; int window; }`.
- **`get_psi_filepath()`** maps `"io"|"memory"|"cpu"` to the hardcoded system paths `/proc/pressure/io`, `/proc/pressure/memory`, `/proc/pressure/cpu`. Any other value raises `ereport(ERROR, ...)` "Invalid argument. Expected 'io', 'memory', or 'cpu'." **This hardcoding is why pg_psi has no per-cgroup granularity** — it cannot point at `/sys/fs/cgroup/.../{cpu,memory,io}.pressure`.
- **`read_psi_file()`** uses raw POSIX `open(O_RDONLY)` / `read()` / `close()` into a stack buffer, null-terminates, and `ereport(ERROR)` on open/read failure. It does not use PostgreSQL's VFS — direct syscalls.
- **`parse_psi_line()`** uses `strtok_r` to split on spaces; validates the first token is exactly `some` or `full` (else ERROR); then for each subsequent token does prefix matches `avg10=`/`avg60=`/`avg300=`/`total=` with `atof`/`atoll` on the offset pointer. Robust to token ordering but not to unexpected keys (silently ignored).
- **`pg_psi_read()`** is a classic SRF using `SRF_IS_FIRSTCALL()` / `SRF_FIRSTCALL_INIT()` / `SRF_PERCALL_SETUP()`. On first call it reads the whole file into a buffer, builds a 5-column TupleDesc (`TEXTOID, FLOAT4OID, FLOAT4OID, FLOAT4OID, INT8OID`) via `CreateTemplateTupleDesc`/`TupleDescInitEntry`/`BlessTupleDesc`, and stashes the buffer in `funcctx->user_fctx` after `pstrdup` in the `multi_call_memory_ctx`. Per-call it `strtok_r`s the next `\n` line, parses it, forms a HeapTuple with `heap_form_tuple`, and `SRF_RETURN_NEXT`; `SRF_RETURN_DONE` when lines are exhausted. Memory-context discipline is correct (switches to `multi_call_memory_ctx` for persistent allocations).
- **`pg_psi_poll()` (C):** `deconstruct_array()` on a `RECORDOID` array (non-pass-by-value, alignment `'d'`), `palloc`s parallel `PSITrigger[]` and `struct pollfd[]` arrays. For each record it extracts fields via `GetAttributeByNum`, `pstrdup`s strings, and **validates**: scope must be `some|full`; window ≥ 500000µs; threshold > 0 and < window; **window must be a multiple of 2000000µs (2s)**. The 2-second-multiple constraint is significant: it matches the kernel rule that *unprivileged* users may only create monitors with window sizes that are multiples of 2s, so pg_psi is designed to run as an unprivileged trigger.
- **`setup_psi_trigger()`** opens each file `O_RDWR | O_NONBLOCK`, writes the kernel trigger string `snprintf(trigger, ..., "%s %d %d", scope, threshold, window)` (e.g., `"some 500000 2000000"`), sets `fds.events = POLLPRI`, and `ereport(NOTICE)`s the registered trigger. Errors are translated to SQLSTATE via `errcode_for_file_access()` with `strerror(save_errno)` detail — good error hygiene.
- **Event loop:** `while(1) { poll(fds_array, num_elements, -1); ... }` blocks indefinitely. On each `POLLPRI` it timestamps with `timestamptz_to_str(GetCurrentTimestamp())`, re-reads the file, and `ereport(NOTICE, ...)` the event with the current PSI snapshot. `POLLERR` → ERROR ("event source is gone"). `EINTR` (e.g., query cancel / Ctrl-C) → NOTICE "Polling interrupted by user request" and clean fd close.

**Architectural critique for a senior audience:**
- `pg_psi_poll` **occupies the calling backend indefinitely** in a blocking `poll()`. There is **no background worker, no hook usage, no shared memory, and no shared_preload_libraries requirement** — it is a plain SRF/void-function extension. This means a `pg_psi_poll` call ties up one connection/backend for the lifetime of monitoring; it cannot asynchronously drive autovacuum tuning or admission control on its own. The NOTICE-based event reporting means events surface only to the client that issued the call (or the log). This is clearly proof-of-concept scaffolding for the "react to PSI inside Postgres" idea, not a finished control loop.
- Reading is cheap and safe; `pg_psi_read` is the part you would actually use in monitoring today.

**Build/install:** Standard PGXS. Clone the repo, ensure `pg_config` is on PATH, `make && sudo make install`, then `CREATE EXTENSION pg_psi;`. No GUCs are defined. Kernel requirement: `CONFIG_PSI=y` and, if `CONFIG_PSI_DEFAULT_DISABLED=y`, boot with `psi=1` (see §B). Writable triggers additionally require the kernel to accept the write (CAP_SYS_RESOURCE for privileged windows, or 2s-multiple windows for unprivileged — which pg_psi enforces).

### B. Linux PSI — kernel deep dive

**Origin and interface.** PSI was written by Johannes Weiner (`hannes@cmpxchg.org`) at Facebook — `kernel/sched/psi.c` carries the header "Pressure stall information for CPU, memory and IO / Copyright (c) 2018 Facebook, Inc. / Author: Johannes Weiner", with "Polling support by Suren Baghdasaryan `<surenb@google.com>`, Copyright (c) 2018 Google, Inc." The base feature merged in **Linux 4.20**; the monitor/trigger series ("psi: pressure stall monitors") was developed against 4.20-rc7 and landed subsequently. Supporting files: `include/linux/psi.h`, `include/linux/psi_types.h`, `init/Kconfig`, and hooks in `mm/compaction.c`, `mm/filemap.c`, `mm/page_alloc.c`, `mm/vmscan.c`, `kernel/sched/core.c`, `kernel/fork.c`.

The file format (`/proc/pressure/cpu` etc.):
```
some avg10=0.00 avg60=0.00 avg300=0.00 total=0
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```
- **"some"** = share of time in which *at least one* task is stalled on the resource (early warning of contention).
- **"full"** = share of time in which *all non-idle* tasks are stalled simultaneously — no productive work is possible; sustained "full" indicates thrashing and severe performance impact.
- `avg10/60/300` are percentages over trailing 10s/60s/300s windows; `total` is cumulative stall time in microseconds (lets you detect brief latency spikes too short to move the averages).
- **CPU "full" is undefined at the system level.** It was accidentally reported starting 5.13 (from the `PSI_CPU_FULL` state added for cgroups), then deliberately forced to zero at the system level since the 5.15.y backport of commit `890d550d7dba` ("sched/psi: report zeroes for CPU full at the system level"). At the cgroup level cpu.pressure *can* show meaningful "full" (e.g., when all tasks in a cgroup are CPU-throttled).

**Averaging internals (confirmed at source level from `kernel/sched/psi.c`):**
- The running averages are recomputed on a fixed **2-second cadence**: `#define PSI_FREQ (2*HZ+1UL)` ("2 sec intervals"; the `+1` tick keeps it higher-resolution than loadavg and avoids tick aliasing). `psi_init()` sets `psi_period = jiffies_to_nsecs(PSI_FREQ)`.
- Function chain: the delayed-work handler **`psi_avgs_work()`** calls **`collect_percpu_times()`** (folds per-CPU buckets into one wall-clock-normalized sample, weighting each CPU by its non-idle time), then **`update_averages()`** (computes `missed_periods` if the tick was delayed, avoiding drift by scheduling the next update at fixed `psi_period` multiples), which calls **`calc_avgs()`** per state; the work re-arms via `schedule_delayed_work(&group->avgs_work, PSI_FREQ)`.
- **EMA decay constants** (fixed-point, `FIXED_1 = 1<<11 = 2048`, analogous to loadavg's `EXP_1/EXP_5/EXP_15`): `#define EXP_10s 1677`, `#define EXP_60s 1981`, `#define EXP_300s 2034` — i.e., `1/e^(2s/window)` scaled by 2048. `calc_avgs` applies `calc_load(load, exp, active)` = `(load*exp + active*(FIXED_1-exp)) / FIXED_1`, with the current period's stall percentage `pct = div_u64(time*100, period)` scaled to fixed-point as `active`; `calc_load_n()` handles catch-up over multiple idle missed periods.
- **Per-CPU accounting.** State lives in `struct psi_group_cpu` (`group->pcpu`): `times[]` (per-state accumulated stall time in ns), `times_prev[]` (last snapshot), `state_start`, `state_mask`, and task counters (`NR_RUNNING`, `NR_IOWAIT`, `NR_MEMSTALL`, `NR_MEMSTALL_RUNNING`). `record_times()` computes `delta = now - state_start` and adds it to `times[s]` for each active state, protected by a per-CPU seqcount. `get_recent_time()` reads under the seqcount, adds the in-flight interval for still-active states, and returns the **growth** `time - times_prev[state]` — pressure is the delta of total stall time between samples, normalized to wall-clock in `collect_percpu_times()`.

**Trigger/poll internals:**
- Userspace registers a trigger by writing `<some|full> <stall_us> <window_us>` to an fd opened on the pressure file, then `poll()`/`epoll()` for `POLLPRI`. Parsing is via `sscanf(buf, "some %u %u", ...)` / `"full %u %u"` in **`psi_trigger_create()`**; `WINDOW_MIN_US = 500000` (500 ms), `WINDOW_MAX_US = 10000000` (10 s); threshold must be nonzero and ≤ window; values stored as ns. A second write to an fd with an existing trigger fails with **EBUSY**. Example: writing `"some 150000 1000000"` into `/proc/pressure/memory` adds a 150 ms partial-stall threshold over a 1 s window.
- Privileged triggers spawn an RT kthread **"psimon"** (`kthread_create(psi_rtpoll_worker, group, "psimon")`, priority `MAX_RT_PRIO-1`, SCHED_FIFO); `poll_timer_fn` wakes it, `psi_rtpoll_work()` collects times (PSI_POLL aggregator) and calls `update_triggers()`, which signals via `cmpxchg(&t->event, 0, 1)` + `wake_up_interruptible(&t->event_wait)` when `growth >= threshold`. While stalled, growth is sampled **10× per window** (`UPDATES_PER_WINDOW = 10`), so the min update interval is 50 ms and max 1 s; notifications are rate-limited to one per window.
- **Privilege model:** Writing system-wide `/proc/pressure/*` triggers requires **CAP_SYS_RESOURCE**. As of the 6.3-era rework (Domenico Cerasuolo's "Allow unprivileged PSI polling"), unprivileged users may create triggers/monitors only with window sizes that are **multiples of 2s** (to bound resource use) — this is exactly the constraint pg_psi enforces in `pg_psi_poll`. Commit `6db12ee0456d` allowed unprivileged CAP_SYS_RESOURCE writes; a follow-up (`cgroup_pressure_open`) extended the same CAP_SYS_RESOURCE requirement to per-cgroup pressure-file writes.

**irq pressure (kernel 6.1+):** Chengming Zhou's series ("[PATCH] sched/psi: add PSI_IRQ to track IRQ/SOFTIRQ pressure", 21 Jul 2022) added `PSI_IRQ`, merged in **Linux 6.1**, requiring **CONFIG_IRQ_TIME_ACCOUNTING** (and controllable via the `psi_irq=` kernel cmdline parameter). It tracks **only "full"** — the patch states: "we don't use PSI_IRQ_SOME since IRQ/SOFTIRQ always happen in the current task on the CPU, [making] nothing productive could run even if it were runnable, so we only use PSI_IRQ_FULL." `/proc/pressure/irq` therefore has only a `full` line — e.g., per Chris Siebenmann's University of Toronto CS wiki, "it only has a 'full' line: `full avg10=0.00 avg60=0.00 avg300=0.00 total=3753500244`." A corollary: irq pressure only materializes to the extent the system is otherwise busy. Linux 6.1 also added per-cgroup enable/disable of PSI. node_exporter added an `irq` PSI resource (skipping it gracefully when `/proc/pressure/irq` is absent).

**Kernel config / enablement:**
- `CONFIG_PSI=y` is required (Linux ≥ 4.20).
- `CONFIG_PSI_DEFAULT_DISABLED=y` (a vendor-kernel option, added because PSI adds measurable overhead only in artificial scheduler stress tests like hackbench, not in real workloads such as Facebook's webservers/memcache) means PSI is compiled in but off; enable with the **`psi=1`** kernel command-line parameter (the option was renamed from `psi_enable=1` to `psi=1` early on). Check with `zgrep PSI /proc/config.gz`; if `/proc/pressure/cpu` returns "Operation not supported", PSI is disabled.
- Distro defaults vary: Ubuntu 22.04 ships cgroup v2 + PSI **enabled**; RHEL/Rocky/Alma 8 ship cgroup v2 but PSI **not enabled by default** (needs `psi=1`).

**cgroup v2 integration:** With `CONFIG_CGROUPS=y` and cgroup2 mounted, each cgroup subdirectory exposes `cpu.pressure`, `memory.pressure`, `io.pressure` (same format), aggregating stalls for tasks in that cgroup. Per-cgroup PSI monitors work the same way as system-wide ones. This maps directly to containers/Kubernetes pods: each pod/container is a cgroup, so `/sys/fs/cgroup/<path>/memory.pressure` gives that pod's memory pressure. Container CPU "full" can be nonzero (unlike system level) because CFS throttling stalls all tasks in the cgroup.

### C. Practical usage in a PostgreSQL context

**Reading PSI from SQL (pg_psi):**
```sql
CREATE EXTENSION pg_psi;
SELECT * FROM pg_psi_read('cpu');
-- scope | avg10 | avg60 | avg300 |   total
--  some  | 29.01 | 29.10 | 28.82  | 1843235106
SELECT * FROM pg_psi_read('io');
SELECT * FROM pg_psi_read('memory');
```
A real observed `/proc/pressure/*` snapshot under pgbench load (from Franck Pachot's YugabyteDB PSI walkthrough, `select-only` pgbench at ~13k tps):
```
==> /proc/pressure/cpu <==   some avg10=29.01 avg60=29.10 avg300=28.82 total=1843235106
==> /proc/pressure/io  <==   some avg10=0.00 avg60=0.00 avg300=0.16 total=30467826
                             full avg10=0.00 avg60=0.00 avg300=0.00 total=16404190
==> /proc/pressure/memory <== some avg10=0.00 ... full avg10=0.00 ...
```

**Interpretation thresholds (rules of thumb):** `avg10` is the live-triage number; `avg60` filters noise. As one cgroup-v2 operations guide puts it, "anything sustained above 10 on some.avg60 is real pressure worth investigating"; `full.avg10` climbing above a few percent on memory/io indicates thrashing (unproductive time). For CPU, note only "some" is meaningful at system level; a `some.cpu` steadily near your core-oversubscription point indicates run-queue saturation.

**Correlating PSI with Postgres symptoms:**
- **memory.pressure ↔ shared_buffers/work_mem/swapping.** Rising memory `some`/`full` means the page cache is being reclaimed under pressure and/or anonymous memory is being swapped. For Postgres this correlates with over-large `work_mem` × high connection count (sort/hash spills + anon allocation), oversized `shared_buffers` relative to container `memory.max`, and the double-buffering interaction with page cache. Memory `full` is the strongest leading indicator of an impending OOM kill of a backend or the postmaster.
- **io.pressure ↔ checkpoints/WAL/autovacuum.** Spikes in io `some`/`full` align with checkpoint storms (`checkpoint_completion_target` too aggressive, or `max_wal_size` too small forcing frequent checkpoints), WAL fsync bursts, and autovacuum I/O (especially with `autovacuum_vacuum_cost_delay` low / cost limit high). Because the block layer attributes stall to all I/O delays, io.pressure catches backend read stalls (cold cache) as well as background write pressure.
- **cpu.pressure ↔ connection storms / parallel query.** cpu `some` rising toward saturation correlates with connection storms (more active backends than cores — the classic case for a pooler), and with parallel query fan-out (`max_parallel_workers_per_gather`) overcommitting cores. PSI cpu pressure is a cleaner signal than load average here because it is core-count-normalized. As Pachot notes, CPU *usage* measures what is running on the CPU while CPU *pressure* measures what is waiting to run — they look similar under load but mean different things.

**Reactive use (the pg_psi thesis):** Villemain's POSETTE 2025 talk "Resource Control Admission – I have a date with my PSI" (video: `https://youtu.be/9saQfX-lLSY`) frames `pg_psi_poll` as a way to be notified when the server slows down. In his words: "we will define system triggers so we're notified when the server is slowing down. This gives us the chance to adjust the workload before it's too late, or give more resources to background tasks like autovacuum when it's possible." This is genuinely novel — an admission-control / dynamic-tuning loop driven from inside Postgres — but the v0.1 implementation (blocking poll in a backend, NOTICE output) is a demonstrator, not a shipping control plane.

### D. Monitoring integration

**node_exporter PSI collector.** The `pressure` collector reads `/proc/pressure/*` and exposes counters (seconds):
- `node_pressure_cpu_waiting_seconds_total` (cpu some)
- `node_pressure_memory_waiting_seconds_total` (memory some), `node_pressure_memory_stalled_seconds_total` (memory full)
- `node_pressure_io_waiting_seconds_total` (io some), `node_pressure_io_stalled_seconds_total` (io full)
- `node_pressure_irq_stalled_seconds_total` (irq full, newer kernels)

The elegant identity (from the node_exporter design discussion): the kernel's `avg10/60/300` are simply `rate()` of the totals — `avg300 ≈ rate(..._seconds_total[5m]) * 100`, `avg60 ≈ rate([1m])`, `avg10 ≈ rate([10s])`. So exporting only the totals is sufficient; you reconstruct the averages in PromQL:
```promql
rate(node_pressure_cpu_waiting_seconds_total[5m]) * 100   # ≈ cpu some avg300 (%)
```
Note node_exporter 1.8.1 had a regression (issue #3051) where kernels not exposing CPU "full" (e.g., Debian 11) aborted the whole pressure collection; be on a patched version.

**Exposing pg_psi via postgres_exporter.** Since pg_psi exposes SQL, you can feed `pg_psi_read` through postgres_exporter's custom-queries YAML (`PG_EXPORTER_EXTEND_QUERY_PATH`), though note that custom queries via `--extend.query-path` are deprecated as of postgres_exporter 0.13.0 (the project recommends `sql_exporter` for arbitrary SQL, and pgMonitor 5.0.0 deprecated postgres_exporter in favor of sql_exporter). Example custom query:
```yaml
pg_psi_cpu:
  query: "SELECT scope, avg10, avg60, avg300, total FROM psi.pg_psi_read('cpu')"
  metrics:
    - scope:  {usage: "LABEL",  description: "some/full"}
    - avg10:  {usage: "GAUGE",  description: "CPU pressure avg over 10s (%)"}
    - avg60:  {usage: "GAUGE",  description: "CPU pressure avg over 60s (%)"}
    - avg300: {usage: "GAUGE",  description: "CPU pressure avg over 300s (%)"}
    - total:  {usage: "COUNTER", description: "cumulative CPU stall microseconds"}
```
Because you must run pg_psi as a monitoring role, grant `pg_monitor` (or `pg_read_all_stats`) and `EXECUTE` on the functions.

**Example alerting rules (PromQL, on node_exporter PSI):**
```yaml
groups:
- name: psi.rules
  rules:
  - alert: HighCPUPressure
    expr: rate(node_pressure_cpu_waiting_seconds_total[5m]) * 100 > 20
    for: 10m
    labels: {severity: warning}
    annotations: {summary: "CPU saturation >20% (some) for 10m on {{ $labels.instance }}"}
  - alert: MemoryFullPressure
    expr: rate(node_pressure_memory_stalled_seconds_total[1m]) * 100 > 5
    for: 2m
    labels: {severity: critical}
    annotations: {summary: "Memory FULL stall >5% — OOM risk on {{ $labels.instance }}"}
  - alert: IOFullPressure
    expr: rate(node_pressure_io_stalled_seconds_total[5m]) * 100 > 10
    for: 5m
    labels: {severity: warning}
```

**PSI-driven OOM prevention (oomd / systemd-oomd) and Postgres.** systemd-oomd (and Facebook's original oomd) is a userspace OOM killer that uses cgroup v2 + PSI to act *before* the kernel OOM killer. Configuration is via `ManagedOOMMemoryPressure=kill` and `ManagedOOMMemoryPressureLimit=<pct>` on a slice/unit (the limit is compared against the cgroup's memory "full avg10"; the Fedora rollout default sends SIGKILLs when total memory pressure exceeds 50% for 20 seconds), plus swap-based killing via `ManagedOOMSwap=kill`. This matters for Postgres because the **kernel** OOM killer is a blunt instrument that can kill the postmaster (crash-restart of the whole cluster) or a random backend; PSI-based early action lets you target a noisy neighbor cgroup instead. Two Postgres-specific cautions: (1) explicitly protect the Postgres unit from being an oomd victim where appropriate (`ManagedOOMPreference=omit`) or, conversely, ensure `OOMPolicy` on the Postgres unit is set so a single backend OOM doesn't take down the postmaster; (2) systemd-oomd is not a substitute for correctly sizing `shared_buffers`/`work_mem` × connections against the cgroup memory limit.

### E. Kubernetes / CloudNativePG considerations
- **Reading pod-level pressure:** inside a pod on a cgroup v2 host, `cat /sys/fs/cgroup/<...>/memory.pressure` (the pod's own cgroup, thanks to cgroup namespacing which typically presents the pod cgroup as the root) gives that pod's pressure. **Kubernetes v1.36 graduated PSI metrics to GA** — per the Kubernetes blog (12 May 2026, "Kubernetes v1.36: PSI Metrics for Kubernetes Graduates to GA") and KEP-4205, "starting in v1.36 where this feature graduates to GA, the KubeletPSI feature gate will be locked to true and can no longer be disabled." PSI is exposed at node/pod/container level via the kubelet Summary API and `/metrics/cadvisor` (Prometheus format: `container_pressure_cpu_waiting_seconds_total`, `container_pressure_cpu_stalled_seconds_total`, and memory/io equivalents). Requirements: kernel ≥ 4.20, `CONFIG_PSI=y`, and cgroup v2 on the node.
- **pg_psi's limitation here is decisive:** because it hardcodes `/proc/pressure/*`, on a Kubernetes node `pg_psi_read` reports **node-wide** pressure, not the Postgres pod's cgroup pressure. For per-pod granularity you need pgnodemx (which reads cgroup files) or the kubelet/cAdvisor PSI metrics. This is the single biggest functional gap for CloudNativePG/PGO deployments.
- **cgroup namespace caveats:** what a process sees under `/sys/fs/cgroup` depends on the cgroup namespace and how the cgroupfs is mounted into the container; `/proc/self/cgroup` is virtualized. Writing per-cgroup PSI triggers requires CAP_SYS_RESOURCE, which containers usually lack. Also note the cardinality problem flagged by Red Hat/OpenShift: enabling container-level PSI across a large cluster materially increases Prometheus memory (many `container_pressure_*` series, including pause/POD cgroups you may want to relabel-drop).

### F. Related / alternative tooling and where pg_psi fits

| Tool | Author/Owner | Mechanism | PSI support | Per-cgroup | Best for |
|---|---|---|---|---|---|
| **pg_psi** | Cédric Villemain / Data Bene | SQL SRF + blocking poll() trigger | Reads `/proc/pressure/*`; writable triggers | **No** (hardcoded system paths) | Experimental in-DB *reactive* PSI |
| **pgnodemx** | Joe Conway / Crunchy Data | SQL functions over `/proc` + cgroup v1/v2 files | Yes, via cgroup/`/proc` file readers | **Yes** (cgroup-aware, containerized mode) | Production node/pod metrics via SQL; used by pgMonitor |
| **system_stats** | EnterpriseDB | C extension, OS syscalls | No direct PSI parsing | N/A | Cross-platform CPU/mem/disk/net (Linux/macOS/Windows) |
| **pg_proctab** | Mark Wong (compat shim shipped in pgnodemx) | OS process table | No | No | `pg_cputime/loadavg/memusage/diskusage/proctab` |
| **node_exporter** (pressure collector) | Prometheus community | Go, reads `/proc/pressure` | Yes (totals) | Node-level only (container_* via cAdvisor) | Standard Prometheus PSI metrics |
| **below** | Facebook (facebookincubator) | Rust, cgroup2 + PSI, time-travel recording | Yes, first-class | Yes (cgroup hierarchy) | Interactive/historical cgroup+PSI forensics (no cgroup v1) |
| **oomd / systemd-oomd** | Facebook / systemd | Userspace OOM killer | Yes (PSI thresholds) | Yes | Proactive OOM prevention |

**pgnodemx specifics** (the extension most likely confused with pg_psi): it requires `shared_preload_libraries = 'pgnodemx'`, has GUCs `pgnodemx.cgroup_enabled`, `pgnodemx.containerized`, `pgnodemx.cgrouproot` (default `/sys/fs/cgroup`), and exposes "General Access Functions" that read/parse cgroup virtual files plus context-detection functions. It handles cgroup v1 and v2, provides a `pg_proctab` v0.0.10-compat shim (`pg_cputime/pg_loadavg/pg_memusage/pg_diskusage/pg_proctab`), and in Kubernetes reads pod limits from the DownwardAPI. It is the extension pgMonitor's embedded postgres_exporter uses to surface node/pod metrics via SQL. In CloudNativePG/PGO you can auto-create it via a ConfigMap init SQL.

**file_fdw alternative (no extension build required):** Franck Pachot (Yugabyte) documented reading PSI purely with contrib `file_fdw` + a `PROGRAM` option that awk-formats `/proc/pressure/*` into columns (resource, tasks, avg10, avg60, avg300, total, uptime, host) — a zero-C-code way to get PSI into SQL, and cgroup-path-flexible if you point PROGRAM at the right files. Worth knowing as the pragmatic fallback.

**Where pg_psi fits:** it is the *only* option that puts writable PSI **triggers** behind a SQL interface, enabling the "Postgres reacts to its own resource pressure" pattern. For pure observability, pgnodemx (cgroup-aware, production-hardened, integrated with pgMonitor/CloudNativePG) or node_exporter are the right tools today. Recommend pg_psi only for experimentation with reactive control, and contribute upstream (per-cgroup path support, background-worker execution) if you intend to rely on it.

## Recommendations

1. **Correct the authorship attribution** in any internal docs: pg_psi = Cédric Villemain / Data Bene; the Crunchy Data / Joe Conway extension you may be thinking of is **pgnodemx**.
2. **For production monitoring now:** deploy **node_exporter's pressure collector** (node-level) and, for containerized/CloudNativePG deployments where you need per-pod pressure via SQL, **pgnodemx** (it is cgroup-aware and already wired into pgMonitor). Reconstruct avg10/60/300 in PromQL via `rate(*_seconds_total)`. Set alerts at: cpu `some` >20% for 10m (warning), memory `full` >5% for 2m (critical, OOM-imminent), io `full` >10% for 5m (warning). Tune thresholds to your baseline.
3. **Enable the kernel feature** where missing: verify `zgrep PSI /proc/config.gz`; if `CONFIG_PSI_DEFAULT_DISABLED=y` (common on RHEL/Rocky/Alma 8), add `psi=1` to the kernel command line and reboot. Ensure cgroup v2 for per-cgroup pressure. For irq pressure, you need kernel ≥ 6.1 with `CONFIG_IRQ_TIME_ACCOUNTING`.
4. **For OOM safety:** adopt systemd-oomd with `ManagedOOMMemoryPressure=kill` on the appropriate slice and a sane `ManagedOOMMemoryPressureLimit` (e.g., 50–60% for less-latency-sensitive slices), keep some swap available, and set an explicit `OOMPolicy`/`ManagedOOMPreference` for the Postgres unit so the postmaster is protected. This is strictly better than relying on the kernel OOM killer.
5. **Evaluate pg_psi only in a lab** for the reactive-control use case (e.g., pausing/throttling workload or boosting autovacuum on sustained pressure). Before any production reliance, it needs: per-cgroup path support (critical for Kubernetes), execution in a background worker rather than a blocking client backend, and a signalling mechanism richer than NOTICE. Consider contributing these upstream.
6. **Thresholds that change the recommendation:** if you are bare-metal (not containerized), pg_psi_read's system-wide view is adequate and node_exporter alone likely suffices — skip pgnodemx. If you run cgroup v1 (legacy), `below` won't help (no v1 support) and pgnodemx's cgroup v1 path or `file_fdw` are your options. If kernel < 6.1, expect no irq pressure and no per-cgroup PSI enable/disable.

## Caveats
- **pg_psi is v0.1, ~6 commits, single author, no tags/releases, no PGXN package, self-hosted forge.** Treat as pre-alpha. The identifier `BUFFER_SISE` (typo) and README notes ("default schema … probably to change") confirm its early stage. There is no stated explicit PostgreSQL version-compatibility matrix; the code uses standard SRF/array APIs compatible with modern PostgreSQL (it uses `CreateTemplateTupleDesc(5)` single-arg form, which is the PostgreSQL 12+ signature), so assume PG ≥ 12 and test.
- **No independent third-party verification of pg_psi in production** was found; the only substantial public discussion is Villemain's own POSETTE 2025 talk and the Data Bene positioning. Claims about its behavior here are derived directly from reading the source in the repo.
- **CPU "full" semantics** are a known source of confusion: undefined/zeroed at system level, meaningful only per-cgroup. Don't alert on system-level cpu full.
- **PSI overhead** is negligible for real workloads (Weiner's own note: not measurable on Facebook webservers/memcache; only visible in hackbench), which is why the default-disabled option exists — but some vendor kernels still ship it off.
- **Kernel function/field names evolved** across versions (`poll_*`→`rtpoll_*`, `psi_clock`→`psi_avgs_work` + `collect_percpu_times`/`update_averages`) during the 6.3-era unprivileged-polling rework; the names above reflect current (6.x) source with historical notes. The EMA constants (1677/1981/2034), `PSI_FREQ` (2*HZ+1), `WINDOW_MIN/MAX_US` (500ms/10s), and `UPDATES_PER_WINDOW` (10) are stable and confirmed from source.
- Distro/K8s specifics (Ubuntu 22.04 on, RHEL 8 off, Kubernetes 1.36 KubeletPSI locked-on) are current as of mid-2026 but change release-to-release — verify on your exact images.