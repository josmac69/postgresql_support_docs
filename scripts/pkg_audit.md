# pkg_audit.sh — Cheat Sheet

**Purpose:** Multi-distro, read-only audit of database-related packages — finds version conflicts, outdated software, competing database engines, and missing diagnostic/HA/backup tooling.

**Usage:**
```bash
bash pkg_audit.sh | tee pkg_audit_$(hostname).log
```
- **Privileges:** Runs as a normal user; detects passwordless `sudo` only to advise on later installs.
- **Read-only:** Yes — only queries package databases, never installs or removes anything.

## What it tests
- **Distro family** — Debian/Ubuntu vs RHEL/CentOS/Rocky/Alma/Amazon.
- **Package inventory** — installed PostgreSQL, pgBouncer, Patroni, repmgr, pgBackRest, wal-g, Barman, etcd, consul.
- **Outdated packages** — installed versions vs the candidate/available version in the repos.
- **Multiple server/client versions** — more than one `postgresql-N` server or client package co-installed.
- **Competing engines** — MySQL/MariaDB, MongoDB, Redis installed alongside PostgreSQL.
- **Diagnostic tooling** — presence of `sysbench`, `strace`, `tcpdump`, `gdb`, `perf`, `bpftrace`.
- **HA/backup integration** — whether pgBouncer and pgBackRest are present on a server node.

## How it tests
- Reads `/etc/os-release` (falls back to `dpkg`/`rpm` presence) to pick the OS family.
- Debian: `dpkg-query -W` with package globs, filtered to `install ok installed`.
- RHEL: `rpm -qa` filtered by a package-name regex.
- Outdated check: Debian parses `apt-cache policy` (Installed vs Candidate); RHEL uses `dnf`/`yum check-update` cross-referenced with `rpm -q`.
- Counts server/client packages and greps the inventory for competing engines and diagnostic tools.
- Accumulates findings into `ISSUES`/`REMEDS` arrays and prints a triage summary with severities (`OK`/`WARN`/`CRIT`).

## Recommendations
- **Outdated packages** → upgrade them. *Rationale:* protects against known bugs, security fixes, and stability issues.
- **Multiple server versions** → remove obsolete packages. *Rationale:* prevents path confusion, port-binding conflicts, and wrong-instance restarts.
- **Multiple client versions** → align client utilities (`psql`, `pg_dump`) with the active server. *Rationale:* avoids feature/format mismatches.
- **Database co-habitation** → isolate engines onto dedicated instances / disable non-essential auto-start. *Rationale:* prevents CPU/RAM/I/O contention and OOM risk.
- **Missing diagnostic tools** → install `strace`, `gdb`, `tcpdump`, `perf`, etc. *Rationale:* essential for troubleshooting system-level hangs and network issues.
- **Missing pgBouncer / pgBackRest** → install them. *Rationale:* connection-pooling safety and reliable point-in-time recovery.
