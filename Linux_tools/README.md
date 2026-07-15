# Linux Diagnostics & Performance Tools for Databases

This directory contains resources, guides, and playbooks for debugging, profiling, and tuning PostgreSQL database environments on Linux systems.

## Directory Contents

*   **[Linux Kernel & OS Tuning Guide](file:///home/josef/github.com/josmac69/postgresql_support_docs/Linux_tools/postgresql_linux_tuning.md)**: A deep reference on system tuning parameters, memory limits, transparent huge pages (THP), filesystems, and virtual memory.
*   **[GDB Debugging Deep-Dive (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/Linux_tools/GDB_for_Linux_Database_Debugging__A_Deep-Dive_Reference_for_PostgreSQL_and_MySQL_MariaDB_Backends.pdf)**: An expert guide on attaching GDB to database backend processes, reading call stacks, resolving symbols, and tracing execution paths without crashing the database.
*   **[Linux perf Profiling Guide (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/Linux_tools/Linux_perf_for_Database_Performance_Engineering__A_Deep-Dive_on_PostgreSQL_and_MySQL_Profiling.pdf)**: Explains stack-sampling database execution hotspots, compiling with debug symbols, generating flame graphs, and running uprobe/kprobe tracing.

---

## Technical Reference: GDB, perf, strace, bpftrace, and tcpdump

These five tools inspect a running system, but they sit at very different layers and use fundamentally different mechanisms. Below is a structured comparison of their roles, overhead, and production safety.

### 1. What They Observe

*   **gdb** — a *debugger*: It takes control of a single process, letting you stop it, inspect memory, variables, stack frames, set breakpoints, and step through code. It is about *program state*, not performance.
*   **perf** — a *profiler*: It answers "where is time (or cache misses, branch mispredictions, context switches) being spent?" It works via CPU performance counters (PMU) and sampling, either system-wide or per-process.
*   **strace** — a *syscall tracer*: It shows every system call a process makes (open, read, futex, sendto...), with arguments, return values, and timing. It only sees the user↔kernel boundary, nothing inside the process or inside the kernel.
*   **bpftrace** — a *programmable tracing language* on top of eBPF: You can attach probes to kernel functions (kprobes), tracepoints, user-space functions (uprobes/USDT), and aggregate data in-kernel (histograms, counts). It is the most flexible of the five — it can emulate much of what strace, perf, and tcpdump do.
*   **tcpdump** — a *packet capturer*: It observes network traffic at the interface level via AF_PACKET/BPF filters. It sees wire-level reality, not what the application thinks it sent.

### 2. Mechanism and Overhead

This is where they differ most dramatically:
*   **strace** uses `ptrace`, which stops the process twice per syscall — overhead can be **10x–100x** on syscall-heavy workloads, so it is extremely dangerous on a busy production PostgreSQL backend.
*   **gdb** also uses ptrace and fully halts the process at breakpoints. Attaching gdb to a backend holding spinlocks can freeze the whole cluster — a classic warning in the PostgreSQL community.
*   **perf** is sampling-based, typically adding only **1%–5%** overhead, making it safe to run in production.
*   **bpftrace** runs verified bytecode inside the kernel with in-kernel aggregation. Its overhead remains low even when tracing millions of events, which is why tools like `biolatency` or tracing `LWLock` waits via USDT probes are viable in production.
*   **tcpdump** overhead depends on traffic volume and filter selectivity. Since the BPF filter runs in-kernel, a tight filter is inexpensive.

### 3. Intrusiveness & Scope

*   **gdb** and **strace** *perturb* the target (stop-the-world vs. syscall slowdown). **perf**, **bpftrace**, and **tcpdump** are passive observers that change timing only marginally.
*   **gdb** and **strace** are strictly per-process. **perf** and **bpftrace** can be per-process or system-wide. **tcpdump** is per-interface, effectively system-wide for network traffic.

### 4. Database-Specific Examples

*   **Backend segfaults or is stuck**: Run `gdb -p <pid>` and type `bt` to get the stack trace to inspect the `PGPROC` or executor state.
*   **Query is slow and CPU-bound**: Run `perf top` or `perf record -g` to see if CPU cycles are spent on hashing, sorting, `heap_hot_search`, or spinlock contention.
*   **Backend is hung on I/O or IPC**: Run `strace -p <pid>` to see if it is blocked in `epoll_wait`, `read`, or a `futex` (or on PostgreSQL 18, `io_uring_enter` with AIO).
*   **Identify fsync latency distributions during checkpoints**: Run a `bpftrace` one-liner to generate a histogram of WAL or data write latencies.
*   **Replication connection flapping / TCP issues**: Run `tcpdump` or Wireshark on port 5432 to capture packets.

---

| Tool | Intrusion Level | Safe in Production? | Primary Scope | PostgreSQL Context |
| :--- | :--- | :--- | :--- | :--- |
| **gdb** | High (halts process) | **No** (except for crash debugging) | Per-Process | Stack inspection, stuck process analysis |
| **strace** | High (ptrace intercept) | **No** (extremely slow) | Per-Process | Syscall auditing, block tracking |
| **perf** | Low (sampling-based) | **Yes** (1-5% overhead) | System/Process | CPU hot-spot analysis, flame graphs |
| **bpftrace** | Low (eBPF verification) | **Yes** (in-kernel aggregation) | System/Process | Disk I/O latency, lock wait-time tracing |
| **tcpdump** | Medium (traffic dependent) | **Yes** (with narrow filters) | Interface | Replication socket debugging, wire issues |