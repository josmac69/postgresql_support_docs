# PostgreSQL Support Diagnostics Directory

This directory contains production-ready, read-only diagnostic and auditing scripts to verify host hardware, kernel parameters, PostgreSQL configurations, and database bloat.

## Recommended Run Order

For a systematic host and database audit, run the utilities in the following order:
1.  **`pkg_audit.sh`** (Package Discovery & Conflicts)
2.  **`pg_env_triage.sh`** (Topology & Cluster State)
3.  **`pg_gotcha_sweep.sh`** (Config Gotchas & Time-Landmine Sweep)
4.  **`pg_repl_triage.sh`** (Replication & Peer Port Scan)
5.  **`pg_ha_stack_triage.sh`** (HA Middleware Triage)
6.  **`patroni_deep_triage.sh`** (Patroni Deep Triage & Audit)
7.  **`pg_backup_audit.sh`** (WAL Archiving & Backup Readiness)
8.  **`pg_machine_audit.sh`** (Hardware Resources)
9.  **`pg_kernel_audit.sh`** (OS Kernel / Sysctl Settings)
10. **`pg_server_audit.sh`** (Systemd, HBA Rules & Limits)
11. **`pg_log_audit.sh`** (Server Logs & System dmesg Forensics)
12. **`pg_ssl_ext_audit.sh`** (SSL/TLS & Extension Health)
13. **`pg_tune_audit.sh`** (PostgreSQL Parameter Heuristics)
14. **`pg_lock_triage.sh`** (Sessions, Wait Events & Lock Trees)
15. **`pg_activity_audit.sh`** (Sessions Capacity, Slow Queries & Prepared Transactions)
16. **`pg_query_audit.sh`** (Query latency, missing/unused indexes & stale stats)
17. **`pg_bloat_audit.sh`** (Database Relation Bloat & Autovacuum)

## Quick Reference / How to Run

### 1. Package Auditor
Checks for multi-version package conflicts, competing engines, and missing debugging tools.
```bash
bash pkg_audit.sh | tee pkg_audit_$(hostname).log
```

### 2. Environment Triager
Rapidly fingerprints the system architecture (VM vs Patroni vs Kubernetes) and identifies cluster/replication issues.
```bash
bash pg_env_triage.sh | tee env_triage_$(hostname).log
```

### 3. Config Gotchas & Time-Landmine Sweeper
Sweeps for GUCs pending restart, auto.conf shadows, pg_hba order issues, active mounts missing from /etc/fstab, NTP sync, and scheduled job conflicts.
```bash
# Runs best with sudo to audit fstab and systemd timers:
sudo bash pg_gotcha_sweep.sh | tee gotcha_sweep_$(hostname).log

# Audit with a custom scheduled jobs lookahead (e.g. 12 hours):
sudo bash pg_gotcha_sweep.sh --lookahead 12 | tee gotcha_sweep_$(hostname).log
```

### 4. Replication & Network Auditor
Audits standby/primary replication logs, parameters, replication slots, and performs TCP socket sweeps on peer hosts to identify network connectivity blocks.
```bash
# Autodetect hosts and test connections:
bash pg_repl_triage.sh | tee repl_triage_$(hostname).log

# Scan explicit target peer IP addresses:
bash pg_repl_triage.sh --peers 10.0.0.10,10.0.0.11 | tee repl_triage_$(hostname).log
```

### 5. HA Middleware Triager
Audits high-availability middleware: Patroni REST APIs, etcd member quorums & alarms, HAProxy backends & validation, and keepalived VIP status.
```bash
# Runs best with sudo to read configurations:
sudo bash pg_ha_stack_triage.sh | tee ha_triage_$(hostname).log

# Specify custom endpoints/ports:
sudo bash pg_ha_stack_triage.sh --patroni-url http://127.0.0.1:8008 --etcd http://10.0.0.10:2379 --pgb-port 6432 | tee ha_triage_$(hostname).log
```

### 6. Patroni Deep Auditor
Conducts a node-level and cluster-wide check of Patroni service status, Docker/Podman deployments, static YAML configuration overrides, REST role matching, DCS quorums, hardware watchdog devices, and log forensics signatures.
```bash
# Runs best with sudo to read YAML configurations and unit logs:
sudo bash patroni_deep_triage.sh | tee patroni_deep_$(hostname).log

# Probe a custom Patroni REST API URL and config file:
sudo bash patroni_deep_triage.sh --url http://10.0.0.10:8008 --config /etc/patroni/patroni.yml | tee patroni_deep_$(hostname).log
```

### 7. Backup & WAL Auditor
Audits WAL archiving metrics, backup software (pgBackRest/Barman/WAL-G) configuration, scheduled backup jobs, page checksums, and recovery settings.
```bash
bash pg_backup_audit.sh | tee backup_audit_$(hostname).log
```

### 8. Machine Resources Auditor
Audits CPU governor, RAM page table size, disk speed, and mount options.
```bash
bash pg_machine_audit.sh | tee machine_audit_$(hostname).log

# Run with sequential disk read/write benchmarking:
bash pg_machine_audit.sh --benchmark | tee machine_benchmark_$(hostname).log
```

### 9. Kernel sysctl Auditor
Audits VM, IPC, and thread limits. Can output ready-to-use sysctl snippets.
```bash
bash pg_kernel_audit.sh | tee kernel_audit_$(hostname).log

# Generate and apply a sysctl configuration snippet (Debian & RedHat):
bash pg_kernel_audit.sh --sysctl | sudo tee /etc/sysctl.d/99-postgresql.conf
```

### 10. Systems & Instance Auditor
Runs a deep systems health audit (dmesg, OOM, limit caps, systemd, HBA rules, replication status).
```bash
sudo bash pg_server_audit.sh | tee server_audit_$(hostname).log
```

### 11. Log Forensics Auditor
Locates server log files and scans for PANIC, FATAL crashes, OOM failures, disk space warnings, deadlocks, and checks logging parameters.
```bash
# Requires sudo to read postgres log directories:
sudo bash pg_log_audit.sh | tee log_audit_$(hostname).log

# Audit logs with custom hours back and line limits:
sudo bash pg_log_audit.sh --hours 12 --lines 10 | tee log_audit_$(hostname).log
```

### 12. SSL/TLS & Extensions Health Auditor
Audits SSL configurations, certificate expiration dates, pg_hba plaintext transport vulnerabilities, stale extension versions, and preload libraries.
```bash
# Run with default database connection settings:
sudo bash pg_ssl_ext_audit.sh | tee ssl_ext_audit_$(hostname).log

# Set custom certificate warnings threshold (e.g., 60 days):
sudo bash pg_ssl_ext_audit.sh --port 5432 --dbname postgres --cert-warn 60 | tee ssl_ext_audit_$(hostname).log
```

### 13. Configuration Tuner
Compares active configurations or a `.conf` file against host hardware capacity under target workloads.
```bash
# Audits running local database:
bash pg_tune_audit.sh | tee tune_audit_$(hostname).log

# Audit custom profile:
bash pg_tune_audit.sh --profile oltp --connections 200 | tee tune_audit_$(hostname).log

# Audit offline config (Debian/Ubuntu):
bash pg_tune_audit.sh --conf /etc/postgresql/17/main/postgresql.conf | tee tune_audit_$(hostname).log

# Audit offline config (RHEL/Rocky/Alma):
bash pg_tune_audit.sh --conf /var/lib/pgsql/17/data/postgresql.conf | tee tune_audit_$(hostname).log
```

### 14. Lock Contention & Session Triager
Summarizes active sessions, wait events, highlights long-running or idle-in-transaction queries, and prints hierarchical lock blocker wait tree.
```bash
# Run with default database connection settings:
bash pg_lock_triage.sh | tee lock_triage_$(hostname).log

# Customize query timeout threshold (e.g. alerts on > 10 seconds):
bash pg_lock_triage.sh --timeout 10 | tee lock_triage_$(hostname).log
```

### 15. Activity & Process Auditor
Audits connection limits capacity, skew by client IP address and database user, idle-in-transaction blocks, slow active queries, blocked locking sessions, runaway autovacuum processes, and old prepared transactions.
```bash
# Run with default database connection settings:
bash pg_activity_audit.sh | tee activity_audit_$(hostname).log

# Customize alert thresholds (e.g. idle-in-tx > 10s, queries > 20s, prepared > 10m):
bash pg_activity_audit.sh --idle-tx 10 --long-query 20 --prepared 10 | tee activity_audit_$(hostname).log
```

### 16. Query Performance & Index Auditor
Audits slow queries, index hit/read efficiency, large tables experiencing high sequential scans, duplicate/invalid indexes, missing primary keys, and stats age.
```bash
# Run with default database connection settings:
bash pg_query_audit.sh | tee query_audit_$(hostname).log

# Customize thresholds (minimum table size for sequential scans in MB, top N queries):
bash pg_query_audit.sh --min-size 20 --min-scans 5000 --top 15 | tee pg_query_audit_$(hostname).log
```

### 17. Bloat & Autovacuum Auditor
Estimates database table/index bloat, checks autovacuum cost settings, and generates a rebuild/tuning action plan.
```bash
bash pg_bloat_audit.sh | tee bloat_audit_$(hostname).log

# Customize reporting thresholds (e.g. 20% bloat, 5MB minimum relation size):
bash pg_bloat_audit.sh --threshold 20 --min-size 5 | tee pg_bloat_audit_$(hostname).log
```

---
*For a detailed overview of what each script checks, refer to the root [README.md](../README.md).*