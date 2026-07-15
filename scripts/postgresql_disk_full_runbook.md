# Runbook: PostgreSQL Host Disk Almost Full

A triage-first playbook for responding to a nearly-full disk on a production PostgreSQL server. Golden rules: **assess before you act**, and remember that the single most common real-world cause of a mysteriously full PG disk is a **stale replication slot** or a **failing `archive_command`** — check those early.

---

## Phase 1 — Triage (assess before acting)

### 1. Confirm scope and severity

```bash
df -h                    # human-readable, all mounts — which one is full?
df -i                    # INODE usage — a full-inode disk shows 100% with free bytes
du -x -d1 -h / | sort -rh | head    # top-level offenders, stay on one filesystem
```

Note which mount is full: PGDATA volume, WAL (`pg_wal`), logs, `/tmp`, or root FS. The response differs completely for each.

### 2. Check whether PostgreSQL is still up and writable

```bash
pg_isready
psql -c "SELECT pg_is_in_recovery();"
```

If `pg_wal` fills to 100%, PostgreSQL will **PANIC and shut down** to protect data integrity. This is the emergency case — handle WAL first (Phase 3).

### 3. Identify the biggest consumers inside PGDATA

```bash
psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname))
         FROM pg_database ORDER BY pg_database_size(datname) DESC;"

# Largest relations in the current DB
psql -c "SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS total
         FROM pg_class ORDER BY pg_total_relation_size(oid) DESC LIMIT 20;"
```

---

## Phase 2 — Safe, immediate space recovery (no data loss, no restart)

Do these first — they buy time without risk. Confirm deletions with the customer.

- **Rotate / compress / remove old logs.** Check `log_directory` (often `PGDATA/log`) plus `/var/log`. Old server logs are usually safe to compress or delete.
- **Clear stale temp files.** Files under `PGDATA/base/pgsql_tmp/` are query spill files; they self-clean, but orphaned ones left after a crash can be removed while PostgreSQL is stopped or if clearly stale. Check `/tmp` too.
- **Old backups / dumps** left on the box (`*.sql`, `*.dump`, `*.tar.gz`) — a frequent culprit. Move or delete with sign-off.
- **Archived WAL** if `archive_command` copies to a local dir that isn't being drained.
- **OS package cache:** `apt-get clean` / `dnf clean all`.

---

## Phase 3 — WAL-specific emergencies

If `pg_wal` is the problem, find the *retention cause*. **Never `rm` files in `pg_wal` manually** — that corrupts the cluster.

### Common causes, in order of likelihood

**1. Stale replication slot** — an inactive slot pins WAL forever. The #1 cause of unbounded WAL growth.

```sql
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots ORDER BY retained DESC;
```

Drop only slots confirmed abandoned: `SELECT pg_drop_replication_slot('name');` — **justify in the report**, since it breaks that replica.

**2. Archiving failing** — if `archive_command` returns non-zero, WAL accumulates until archiving succeeds.

```sql
SELECT * FROM pg_stat_archiver;   -- check failed_count, last_failed_wal
```

Fix the archive target (its disk, permissions, network), then WAL drains automatically.

**3. `max_wal_size` / `wal_keep_size` too high**, or checkpoints too infrequent. A manual `CHECKPOINT;` lets the server recycle WAL sooner.

**If the DB has already PANIC'd on a full pg_wal:** free a little space elsewhere on that mount (a log or temp file), *or* grow the volume (Phase 5), then start PostgreSQL — it recovers cleanly. Do **not** delete WAL by hand.

---

## Phase 4 — Reclaiming bloat (only if time allows and it is the real cause)

If space is consumed by table/index bloat (dead tuples not returned to disk):

- Check dead tuples: `pg_stat_user_tables` (`n_dead_tup`, `last_autovacuum`).
- Plain `VACUUM` returns space to the OS **only** for empty trailing pages; it mostly marks space reusable internally. It is safe and non-blocking.
- `VACUUM FULL` **does** shrink the file on disk but takes an **ACCESS EXCLUSIVE lock** (full table outage) and needs free space equal to the table size — dangerous on a nearly-full disk. Prefer **`pg_repack`** (online, no long lock) if installed.
- Investigate *why* autovacuum fell behind: long transactions holding `xmin`, replication slots, or tuning that is too conservative.

---

## Phase 5 — Inode exhaustion

Disk space and inodes are two separate limits. **`df -h` can show free space while `df -i` shows 100% used** — the filesystem cannot create a single new file even though bytes are available. PostgreSQL will fail to create new relation segments, WAL files, or temp files, producing "No space left on device" errors that look baffling when `df -h` says otherwise. This is why **`df -i` belongs in Phase 1**.

### Why it happens

Each file consumes one inode, allocated at filesystem creation time (fixed pool on ext4; dynamic on XFS, so ext4 is the usual victim). Millions of *tiny* files exhaust inodes long before they exhaust bytes. Typical sources on a PG host:

- A huge number of small **WAL or archive files** in a directory that isn't drained.
- **Session/temp file** floods from a misbehaving app, or millions of files under `/tmp`.
- Application or extension logging that writes enormous numbers of small files.
- Very large numbers of relations/partitions — each table and index is at least one on-disk file (plus a segment file per 1 GB), so tens of thousands of partitions multiply file counts fast.

### How to diagnose

```bash
df -i                                        # confirm which mount is at ~100% inodes

# Find directories holding the most files (this can be slow — scope it to the full mount)
for d in /var/* /tmp /var/lib/pgsql /path/to/pgdata; do
  printf "%8s  %s\n" "$(find "$d" -xdev 2>/dev/null | wc -l)" "$d";
done | sort -rn | head

# Drill into the worst offender
find /suspect/dir -xdev -type f | wc -l
find /suspect/dir -xdev -maxdepth 1 -type d -exec sh -c \
  'echo "$(find "$1" | wc -l) $1"' _ {} \; | sort -rn | head
```

### What to do

- **Delete the small-file source, not random data.** Clear stale temp files, drain or rotate over-accumulated log/archive files, purge the app's orphaned session files. Deleting even a modest number of tiny files frees inodes immediately.
- **Fix the generator.** If an app or archive process is producing files faster than they're cleaned, correct that process — otherwise inodes refill.
- If PGDATA itself is out of inodes because of an extreme partition/relation count, that is a **schema design problem**: consolidate partitions or move a tablespace to a filesystem with more inodes (Phase 6).
- **ext4 cannot add inodes after creation** — the pool is fixed at `mkfs` time. The permanent fix is to recreate the filesystem with a higher inode density (`mkfs.ext4 -N <count>` or a smaller `-i bytes-per-inode`) on a new volume and migrate, or switch to **XFS**, which allocates inodes dynamically. Flag this as a follow-up; it is not something to do live during the incident.
- **`rm -rf` on a directory with millions of files is itself slow and I/O-heavy** — on a production box, delete in batches (e.g. `find ... -delete` with a scope, or `rsync` an empty dir over it) so you don't spike disk I/O and hurt live queries.

---

## Phase 6 — If nothing safe is left to delete

The right production answer is usually to **grow the volume**, not delete data:

- **EC2 / EBS:** extend the volume in AWS, then `growpart` + `resize2fs` (ext4) or `xfs_growfs` (XFS) — online, no downtime.
- **Add a tablespace** on a new mount and move large relations or indexes there.

---

## Report checklist

Document all of the following:

- Which mount was full and the **root cause** (space vs. inodes — state which).
- What you deleted or changed, and **why it was safe**.
- Anything requiring an outage, **with justification** (e.g. `VACUUM FULL`, a restart, dropping a slot that breaks a replica).
- The **permanent fix** recommended: monitoring/alerting on both disk % *and* inode %, fixing the archive/slot, right-sizing the volume, or filesystem/schema changes.
- What you deliberately **did not** do, to avoid risk.
