# disk_fill_forecast.sh — Cheat Sheet

**Purpose:** Continuously polls disk usage and fits a least-squares linear trend over a rolling sample window to project each filesystem's ETA to 100% full.

**Usage:**
```bash
./disk_fill_forecast.sh                          # default 60s interval, 10-sample window
INTERVAL=30 WINDOW=20 ./disk_fill_forecast.sh    # env overrides (also ALERT=<seconds>)
./disk_fill_forecast.sh -i 30 -w 20 -m /var/lib/pgsql -m /pg_wal
./disk_fill_forecast.sh -1                        # -1 = single one-shot pass (no ETA, needs 2+ samples)
```
Flags: `-i <sec>` interval, `-w <n>` window size, `-a <sec>` alert threshold, `-m <mount>` limit to mount(s) (repeatable), `-1` one-shot, `-h`/`--help` prints the header block.
- **Privileges:** Runs as a normal user; `df -P -k` needs no sudo.
- **Read-only:** Yes — only reads `df`; keeps all history in memory and deliberately writes nothing to disk (writing would accelerate the very fill it monitors).

## What it tests
- **Filesystem capacity** — current USE% and used KiB per real mount.
- **Growth direction** — classifies each mount as `up`, `flat`, or `down`.
- **Growth rate** — slope converted to a human MiB/hour figure.
- **ETA to full** — projected time until the filesystem reaches 100%, color-coded by urgency.

## How it tests
- Samples usage with `df -P -k` (POSIX one-line-per-fs, 1024-byte blocks), `tail -n +2` drops the header, `awk` extracts Filesystem / blocks / used / capacity% / mount.
- Skips pseudo/special filesystems (`tmpfs`, `devtmpfs`, `udev`, `overlay`, `none`, `shm`) and system mounts (`/dev*`, `/proc*`, `/sys*`, `/run*`); with `-m` given, keeps only listed mounts.
- Timestamps each poll with `date +%s`; stores parallel epoch/used-KiB series in associative arrays, trimmed to the last `WINDOW` entries via `awk`.
- Fits a least-squares regression `slope = (n·Σxy − Σx·Σy)/(n·Σxx − Σx²)` in KiB/sec over the window (needs ≥2 points; time normalized to the first sample).
- Direction thresholds: slope `> 0.01` = up, `< -0.01` = down, else flat; ETA = `(blocks − used) / slope`.
- Color thresholds: red when ETA `< ALERT` (default 86400s / 24h), yellow when ETA `< ALERT×3` (72h), green otherwise; colors disabled when stdout is not a TTY.
- Main loop calls `render` then `sleep $INTERVAL`; `-1` runs one pass; `trap` on INT/TERM prints "stopped." and exits cleanly.

## Recommendations
- **ETA < 24h (red alert)** → intervene immediately: extend storage, drop bloat/logs, or run vacuum now. *Rationale:* a full disk crashes PostgreSQL into a PANIC and can corrupt active WAL and data files.
- **ETA < 72h (yellow warning)** → plan ahead: provision storage, schedule vacuum, or clean up logs before it becomes critical. *Rationale:* gives operators lead time to act before the emergency window.
- **Growth trend `up` with rising rate** → investigate the source (WAL accumulation, unrotated logs, table bloat). *Rationale:* the MiB/h rate pinpoints how fast headroom is disappearing.
- **State kept in memory only** → keep it that way; do not redirect history to files on the monitored volume. *Rationale:* writing history to disk would speed up the fill the script is trying to forecast.
