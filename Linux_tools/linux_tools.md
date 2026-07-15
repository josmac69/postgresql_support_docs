These five all peek inside a running system, but they sit at very different layers and use fundamentally different mechanisms. Let me walk through them along a few axes.

**What they observe**

- **gdb** — a *debugger*: it takes control of a single process, letting you stop it, inspect memory, variables, stack frames, set breakpoints, and step through code. It's about *program state*, not performance.
- **perf** — a *profiler*: it answers "where is time (or cache misses, branch mispredictions, context switches) being spent?" It works via CPU performance counters (PMU) and sampling, either system-wide or per-process.
- **strace** — a *syscall tracer*: it shows every system call a process makes (open, read, futex, sendto...), with arguments, return values, and timing. It only sees the user↔kernel boundary, nothing inside the process or inside the kernel.
- **bpftrace** — a *programmable tracing language* on top of eBPF: you can attach probes to kernel functions (kprobes), tracepoints, user-space functions (uprobes/USDT), and aggregate data in-kernel (histograms, counts). It's the most flexible of the five — it can emulate much of what strace, perf, and tcpdump do.
- **tcpdump** — a *packet capturer*: it observes network traffic at the interface level via AF_PACKET/BPF filters. It sees wire-level reality, not what the application thinks it sent.

**Mechanism and overhead**

This is where they differ most dramatically. strace uses `ptrace`, which stops the process twice per syscall — overhead can be 10–100x on syscall-heavy workloads, so it's dangerous on a busy production PostgreSQL backend. gdb also uses ptrace and fully halts the process at breakpoints (attaching gdb to a backend holding spinlocks can freeze the whole cluster — the classic warning in the PG community). perf is sampling-based, typically 1–5% overhead, safe in production. bpftrace runs verified bytecode inside the kernel with in-kernel aggregation, so overhead stays low even when tracing millions of events — this is why tools like `biolatency` or tracing `LWLock` waits via USDT probes are production-viable. tcpdump's overhead depends on traffic volume and filter selectivity; the BPF filter runs in-kernel, so a tight filter is cheap.

**Intrusiveness**

gdb and strace *perturb* the target (stop-the-world vs. syscall slowdown). perf, bpftrace, and tcpdump are passive observers — they change timing only marginally.

**Scope**

gdb and strace are per-process. perf and bpftrace can be per-process or whole-system. tcpdump is per-interface, effectively system-wide for network traffic.

**When you'd reach for each (PostgreSQL-flavored examples)**

- Backend segfaults or is stuck → `gdb -p <pid>`, `bt` to get the stack, inspect the `PGPROC` or executor state.
- Query is slow and CPU-bound → `perf top` / `perf record -g` to see if it's hashing, sorting, `heap_hot_search`, or spinlock contention.
- Backend seems hung on I/O or IPC → `strace -p <pid>` to see if it's blocked in `epoll_wait`, `read`, or a `futex` (or on PG 18, `io_uring_enter` with AIO).
- "How is fsync latency distributed during checkpoints?" or "which backends wait longest on WALWriteLock?" → bpftrace one-liner with a histogram, possibly on PG's built-in USDT probes.
- Replication connection flapping, suspected TCP retransmits or MTU issues between primary and standby → tcpdump/Wireshark on port 5432.

**Overlaps worth noting**

The boundaries blur: `perf trace` is a lower-overhead strace alternative; bpftrace can trace syscalls (strace-like), sample stacks (perf-like), and hook `tcp_retransmit_skb` (tcpdump-adjacent, though it sees kernel TCP state rather than raw packets); gdb can script inspection non-interactively. A useful mental model is a spectrum from **state inspection** (gdb) → **event tracing** (strace, bpftrace, tcpdump) → **statistical sampling** (perf), crossed with **layer**: application memory (gdb), CPU (perf), syscall boundary (strace), anywhere kernel+user (bpftrace), wire (tcpdump).

If you're building this into a talk, the perturbation-vs-passivity axis tends to resonate — it maps nicely onto why some tools are "safe in production" and others are career-limiting on a customer's primary.