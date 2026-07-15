# LINUX SYSADMIN CHEAT SHEET
*(Second-screen reference. The "basic systems administration tasks" phase.)*

Framing reminder: **this is a live production web-app server.** Diagnose before
you change. Back up before you edit. Justify anything disruptive in the report.
Every fix gets a *verification* command whose output you paste.

---
## 0. FIRST 3 MINUTES — the environment snapshot
Run these immediately; they feed the report's Environment line and orient you.

```bash
hostnamectl                      # OS, kernel, virtualization
uname -r                         # kernel version
cat /etc/os-release              # distro + version (drives apt vs dnf)
nproc; lscpu | head              # CPU count / model
free -h                          # RAM + swap (drives PG memory tuning)
df -hT                           # disk usage + filesystem types
lsblk                            # block devices / mounts
uptime; cat /proc/loadavg        # load averages vs core count
whoami; id; sudo -l              # who am I, what can I sudo
```

Interpretation cues:
- **Load avg >> nproc** → CPU or I/O saturation. Check with `top`/`iostat`.
- **swap used and si/so active** → memory pressure (see §3).
- Note distro family now: **Debian/Ubuntu → apt, systemctl, pg_lsclusters,
  /etc/postgresql/**. **RHEL/Rocky/Amazon → dnf/yum, data in /var/lib/pgsql/**.

---
## 1. DISK SPACE — the #1 "production down" sysadmin task
A full `/` or full PGDATA volume can stop PostgreSQL cold. Handle first.

**Find the pressure**
```bash
df -hT                                   # which mount is full?
du -xhd1 / 2>/dev/null | sort -rh | head # biggest dirs on / (-x = stay on one fs)
du -xhd1 /var 2>/dev/null | sort -rh | head
```

**Zoom into PostgreSQL's footprint**
```bash
# find PGDATA first:
sudo -u postgres psql -tAc "SHOW data_directory;"
PGDATA=$(sudo -u postgres psql -tAc "SHOW data_directory;")
sudo du -xhd1 "$PGDATA" | sort -rh | head
sudo ls -1 "$PGDATA/pg_wal" | wc -l      # WAL segment count — huge = archiving broken
sudo du -sh "$PGDATA/log" 2>/dev/null    # log dir ballooned?
```

**Common root causes & the RIGHT fix (never just `rm` blindly)**

| Symptom | Root cause | Correct action |
|---|---|---|
| `pg_wal` enormous | archive_command failing, or inactive replication slot retaining WAL | Fix archiving / drop dead slot. Let archiver drain. **Do NOT delete WAL files by hand** — breaks recovery/replication. |
| `log/` enormous | `log_statement=all` / `log_min_duration_statement=0` | Reduce logging, rotate logs, enable logrotate. Safe to remove *rotated* old logs. |
| base/ growing | bloat / genuine data growth | Vacuum/repack (see PG cheat sheet), or add storage. |
| `/tmp` or app dirs full | runaway app / core dumps | Investigate owner before deleting. |

**Check WAL/archiving cause from inside PG**
```sql
SELECT archived_count, failed_count, last_failed_wal, last_failed_time
FROM pg_stat_archiver;
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
```
- `failed_count` climbing → archive_command is broken (bad path/permissions).
- An **inactive** slot with large `retained` → a dead standby is pinning WAL;
  drop it: `SELECT pg_drop_replication_slot('name');` (justify — confirm the
  standby is truly gone first).

**Safe emergency relief if truly out of space**
```bash
sudo journalctl --vacuum-size=100M       # trim systemd journal
# remove only ROTATED/old logs, never active ones:
sudo find /var/log -name '*.gz' -mtime +7 -delete
```
> Report note: state exactly what you removed and why it was safe.

---
## 2. SERVICES / systemd — is PostgreSQL running & will it survive a reboot?

```bash
systemctl status postgresql*             # running now?
sudo systemctl is-enabled postgresql     # starts at boot? (JD example cares!)
# Debian/Ubuntu clusters:
pg_lsclusters                            # version, port, status, data dir
# what's actually listening:
sudo ss -ltnp | grep -E '5432|postgres'
```

**Enable at boot (a classic planted task)**
```bash
sudo systemctl enable postgresql         # or postgresql@17-main on Ubuntu
sudo systemctl enable --now <service>    # enable + start together
```

**Start/stop/reload — prefer reload, avoid restart**
```bash
sudo systemctl reload postgresql         # re-read config, NO downtime (SIGHUP)
sudo systemctl restart postgresql        # DOWNTIME — justify + announce first
```

**If it won't start — read WHY, don't guess**
```bash
systemctl status postgresql* -l --no-pager
sudo journalctl -u postgresql* --since "1 hour ago" --no-pager | tail -50
sudo tail -100 "$PGDATA/log/"*.log       # PG's own log = the real error
```
Typical causes: bad config edit (syntax), port already in use, permissions on
PGDATA, out of disk, stale `postmaster.pid`. Fix the cause named in the log.

---
## 3. MEMORY & OOM — "the DB keeps getting killed"

```bash
free -h                                  # available vs used; swap in use?
vmstat 1 5                               # si/so = swapping; high = trouble
cat /proc/meminfo | grep -Ei 'MemAvailable|Swap|Huge'
# was PG OOM-killed?
sudo dmesg -T | grep -iE 'out of memory|killed process|oom' | tail
sudo journalctl -k --since "2 hours ago" | grep -i oom
```

**Interpretation**
- OOM-killer hitting postgres → over-committed memory. Usually `work_mem` ×
  connections too high, or `shared_buffers` + everything else > RAM.
- Fix lives mostly in PostgreSQL config (see PG cheat sheet), but the OS side:

```bash
sysctl vm.overcommit_memory vm.overcommit_ratio vm.swappiness
# recommended for a dedicated DB host (justify per box):
#   vm.overcommit_memory = 2      (don't over-promise memory)
#   vm.overcommit_ratio  = 80
#   vm.swappiness        = 1      (avoid swapping the DB out)
```
Protect the postmaster from the OOM killer (systemd drop-in):
```bash
sudo systemctl edit postgresql
# add:
# [Service]
# OOMScoreAdjust=-1000
```

---
## 4. CPU & I/O — "server is slow / high load"

```bash
top -b -n1 | head -25                    # top consumers; %wa in header = io-wait
# or 'htop' if installed
iostat -xz 1 3                           # per-disk: %util (~100=saturated), await (ms)
# needs sysstat: sudo apt-get install -y sysstat  /  dnf install sysstat
pidstat -d 1 3                           # per-process disk I/O
sudo iotop -bon1 2>/dev/null | head      # top I/O processes (if available)
```
Cues: **%util near 100 + high await** → disk-bound (often bad queries or
checkpoints). High **%wa** in top → processes waiting on I/O. High **%sy** →
kernel/context-switch heavy (connection storms). Tie the finding back to a PG
cause where you can.

---
## 5. KERNEL / sysctl TUNING

```bash
sysctl -a 2>/dev/null | egrep 'vm.dirty.*ratio|overcommit|swappiness'
grep -i huge /proc/meminfo               # HugePages status
```

**Dirty page ratios (Report #2)** — on large-RAM DB hosts the defaults let too
much dirty data accumulate, causing write stalls:
```bash
# check current:
sysctl -a | egrep "vm.dirty.*_ratio"
# recommended for large-memory DB servers (justify with the box's RAM):
#   vm.dirty_ratio = 15
#   vm.dirty_background_ratio = 5     (RHEL suggests 10 / 3 on big hosts)
```

**Apply persistently (survives reboot) AND live**
```bash
# 1. persist:
echo -e "vm.dirty_ratio = 15\nvm.dirty_background_ratio = 5" | \
  sudo tee /etc/sysctl.d/99-postgres.conf
# 2. apply now without reboot:
sudo sysctl --system            # or: sudo sysctl -p /etc/sysctl.d/99-postgres.conf
# 3. verify:
sysctl vm.dirty_ratio vm.dirty_background_ratio
```

**HugePages (for shared_buffers)** — reduces page-table overhead on big buffers:
```bash
# figure out how many the running PG needs:
sudo -u postgres psql -tAc "SHOW shared_buffers;"
# PG can print the requirement; then set vm.nr_hugepages, and PG huge_pages=try/on.
```
> Always explain in the report: current value → recommended value → *why* (the
> mechanism) → the exact command → the verification output. That depth is what
> Example Report #2 is modelling.

---
## 6. FILE PERMISSIONS / OWNERSHIP
PGDATA must be owned by the postgres user, mode 700, or PG refuses to start.

```bash
sudo ls -ld "$PGDATA"                     # expect: drwx------ postgres postgres
sudo chown -R postgres:postgres "$PGDATA" # if wrong (justify)
sudo chmod 700 "$PGDATA"
```
Log ownership, archive dir ownership, and `.ssh` perms are common traps.

---
## 7. NETWORK / CONNECTIVITY
```bash
sudo ss -ltnp | grep 5432                 # is PG listening, on which addr?
sudo ss -s                                # socket summary (too many? storms)
ping -c2 <other_node>                     # replication reachability
# PG side: listen_addresses + pg_hba.conf govern who can connect
sudo -u postgres psql -tAc "SHOW listen_addresses;"
sudo cat "$PGDATA/pg_hba.conf" | grep -v '^#' | grep -v '^$'
```
Firewall (only touch if clearly in scope, and justify):
```bash
sudo iptables -L -n            # or: sudo ufw status  /  sudo firewall-cmd --list-all
```

---
## 8. LOGS — always read them, they name the cause
```bash
sudo journalctl -u postgresql* --since "2 hours ago" --no-pager | tail -80
sudo tail -f "$PGDATA/log/"*.log          # live tail while reproducing an issue
sudo dmesg -T | tail -40                  # kernel-level: OOM, I/O errors, disk faults
sudo grep -iE 'error|fatal|panic|killed' "$PGDATA/log/"*.log | tail
```

---
## 9. PACKAGE INSTALL (if a tool is missing — allowed from standard repos)
```bash
# Debian/Ubuntu:
sudo apt-get update && sudo apt-get install -y sysstat iotop
# RHEL/Rocky/Amazon:
sudo dnf install -y sysstat iotop
```
> Report note (à la Example Report #1): list any packages/repos you added.

---
---
## GOLDEN WORKFLOW FOR EVERY SYSADMIN TASK
1. **Observe** — capture current state (`df`, `free`, `top`, logs). Paste it.
2. **Diagnose** — name the ROOT cause from evidence, not the symptom.
3. **Back up** — `sudo cp file file.bak.$(date +%s)` before editing anything.
4. **Fix** — smallest correct change; online if possible.
5. **Persist AND apply** — make it survive reboot (sysctl file, systemd enable)
   *and* take effect now.
6. **Verify** — re-run the observe command; show before → after.
7. **Justify** — any downtime/disruption explained; announce to Leonardo first.
8. **Write the report block now**, while it's fresh.

## TOP GOTCHAS (that cost people the exercise)
- Deleting WAL files by hand to free space → breaks recovery. Fix the *cause*.
- Editing config but forgetting to reload/restart → "fix" never applied.
- Setting sysctl live but not persisting (or vice-versa) → half a fix.
- Restarting PostgreSQL casually on a "production" box → best-practice fail.
- Not enabling a service at boot after starting it → planted task missed.
- Forgetting `-x` on `du` so you chase mounted volumes → wasted time.
- Not reading PG's own log when it won't start → guessing instead of knowing.
