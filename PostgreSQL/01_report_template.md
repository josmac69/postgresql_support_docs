# REPORT TEMPLATE


## HEADER (write first, ~60 seconds)
```
Dear [Name of the Customer],

As requested, I have [one-line summary of the engagement].
Below is a per-task account of the work performed, decisions made,
and recommendations. Where a change carried outage or production risk,
I have justified it explicitly.

Environment: [OS/version, PG version, RAM, cores, disk layout]
  from: hostnamectl · free -h · nproc · df -h · SELECT version();
```

---

## PER-TASK BLOCK  *(copy this block for each task)*

### Task N — [what the customer asked]

**Symptom / request**
> [What was reported, or what I was asked to do. Quote the customer if relevant.]

**What I found** *(evidence — paste real command output, trimmed)*
```
$ [command]
[output]
```
> [One sentence interpreting the evidence.]

**Root cause**
> [The actual cause, stated plainly. If uncertain: say so + best hypothesis + how I'd confirm.]

**What I did** *(exact commands / config changes)*
```
[commands run, files edited, before -> after values]
```

**Why** *(the mechanism — this is the graded part, à la Example Report #2)*
> [Explain WHY this fix, HOW it works, quantified impact where possible.
>  e.g. "shared_buffers was 128MB on a 32GB host; raising to 8GB (~25% RAM)
>  keeps the hot working set in the buffer cache, cutting disk reads on the
>  app's read path."]

**Production impact / outage**
> [ "No outage — applied online via pg_reload_conf()."  OR
>   "Required a ~5s restart. I recommend a maintenance window because Z.
>    With the customer's confirmation I proceeded at HH:MM UTC." ]

**Verification** *(prove it worked)*
```
$ [command showing the fix took effect — before vs after]
```

**Recommendations / follow-up**
> [Monitoring to add, further tuning, prevention. What I'd do next with more time.]

---

## THINGS I DID NOT COMPLETE  *(honesty scores points — list them)*
> [ "Task 4 (query rewrite) — partial. Missing index identified and applied;
>    the recursive-CTE rewrite is drafted below but not yet benchmarked.
>    Next step would be to compare EXPLAIN ANALYZE on both forms." ]

---

## CLOSING
```
All changes are documented above with verification steps. I have left the
server in a stable, running state. Configuration files modified (backups
saved as *.bak.<timestamp>):
  - /etc/postgresql/.../postgresql.conf
  - /etc/sysctl.conf
  - ...

Sincerely,
Josef Machytka, Consultant
```

---
---

# QUICK REFERENCE — paste-ready diagnostics

## System snapshot (run first; feeds the Environment line)
```bash
hostnamectl; uname -r; free -h; nproc; df -h; lsblk
uptime; cat /proc/loadavg
```

## Who/what is hurting
```bash
top -b -n1 | head -25
iostat -xz 1 3          # disk saturation: %util near 100, high await
vmstat 1 5              # si/so=swap, wa=io-wait, r/b=run/blocked queues
dmesg -T | grep -iE "oom|killed process|error|I/O" | tail
journalctl -u postgresql* --since "1 hour ago" --no-pager | tail -50
```

## Disk filling up (classic sysadmin task)
```bash
df -h
du -xhd1 /var | sort -rh | head
du -xhd1 "$PGDATA" | sort -rh | head          # pg_wal? log? base?
ls -1 "$PGDATA/pg_wal" | wc -l                # WAL piling up = archiving broken
```

## PostgreSQL health / config
```sql
SELECT version();
SHOW data_directory; SHOW config_file;
SELECT name,setting,unit,source FROM pg_settings
 WHERE name IN ('shared_buffers','work_mem','maintenance_work_mem',
   'effective_cache_size','max_connections','wal_level','archive_mode',
   'archive_command','autovacuum','max_wal_size','checkpoint_timeout');
```

## Connections ("too many clients" / app down)
```sql
SELECT count(*), state FROM pg_stat_activity GROUP BY state;
SELECT pid, now()-xact_start AS xact_age, state,
       wait_event_type, wait_event, left(query,60)
FROM pg_stat_activity WHERE state <> 'idle'
ORDER BY xact_start LIMIT 20;
-- 'idle in transaction' = danger: holds locks, blocks vacuum
```

## Locks / blocking
```sql
SELECT blocked.pid AS blocked_pid, blocking.pid AS blocking_pid,
       left(blocked.query,50)  AS blocked_q,
       left(blocking.query,50) AS blocking_q
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid));
-- resolve: SELECT pg_cancel_backend(pid);     (gentle, cancels query)
--          SELECT pg_terminate_backend(pid);  (needed for idle-in-txn)
```

## Bloat / vacuum / wraparound
```sql
SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, last_analyze
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 15;

SELECT datname, age(datfrozenxid) AS xid_age
FROM pg_database ORDER BY 2 DESC;   -- watch vs autovacuum_freeze_max_age
```

## Slow-query workflow
```sql
-- if pg_stat_statements is available:
SELECT calls,
       round(total_exec_time::numeric,1) AS total_ms,
       round(mean_exec_time::numeric,2)  AS mean_ms,
       left(query,70)
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;

EXPLAIN (ANALYZE, BUFFERS, VERBOSE) <query>;
-- read: estimated vs actual rows (mismatch -> stale stats -> ANALYZE)
--       Seq Scan on big table, Sort spilling to disk (raise work_mem)
--       Buffers: shared read=high (cache misses)
CREATE INDEX CONCURRENTLY idx ON tbl (col);   -- online, no ACCESS EXCLUSIVE lock
```

## Replication
```sql
-- on primary:
SELECT client_addr, state, sync_state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;
-- on standby:
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
       pg_last_xact_replay_timestamp();
SELECT slot_name, active, wal_status FROM pg_replication_slots;
-- inactive slot = WAL retained forever = disk fills
```

## Archiving health
```sql
SELECT archived_count, failed_count, last_failed_wal, last_failed_time
FROM pg_stat_archiver;
```

## OS / kernel tuning (Example Report #2 territory)
```bash
sysctl -a 2>/dev/null | egrep "vm.dirty.*_ratio|overcommit|swappiness"
grep -i huge /proc/meminfo
# typical DB recommendations — JUSTIFY per host RAM in the report:
#   vm.dirty_ratio=15   vm.dirty_background_ratio=5   (lower on big-RAM hosts)
#   vm.overcommit_memory=2   vm.overcommit_ratio=80
#   vm.swappiness=1
#   HugePages sized to shared_buffers (SHOW huge_pages;)
```

---
## GOLDEN RULES (glance before every action)
1. **Snapshot before you change** — capture state to show before/after.
2. **Back up every config file:** `cp f f.bak.$(date +%s)` before editing.
3. **No casual restarts.** Use `SELECT pg_reload_conf();` for reloadable params. Restart only if required, justified, and announced to Leonardo.
4. **Online over locking:** `CREATE INDEX CONCURRENTLY`, `pg_repack` not `VACUUM FULL`.
5. **Tell the "customer" before disruptive actions**, and log the time.
6. **Write each task's report block as you finish it** — never batch at the end.
7. **Last ~35 min = report only.** Stop starting new work.
