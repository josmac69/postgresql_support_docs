# PostgreSQL Extensions

## TL;DR
- **Install `pg_stat_statements` first** (it needs `shared_preload_libraries` + a restart, and stats must accumulate) and also install **`pg_stat_monitor`** — an advanced bucket-based replacement (compatible with PostgreSQL 13–18 per Percona's docs) for time-series query profiling; use `auto_explain` via `session_preload_libraries`/`LOAD` as the no-restart alternative for query-optimization tasks.
- **Confirm platform and PG major version in the first few minutes** (`psql -c "SELECT version()"`, `/etc/os-release`, `pg_lsclusters` on Debian) because everything downstream — package names (`postgresql-16-<ext>` on Debian vs `<ext>_16` on RHEL), config-file layout, and restart commands — branches on those two facts.
- **On a "production" server every restart needs justification in your documentation**: issue an explicit `CHECKPOINT` before restarting to shorten the shutdown checkpoint, use the default fast-shutdown mode, and document why the extension's benefit outweighs the brief outage.

## Key Findings
1. `pg_stat_statements` and `pg_stat_monitor` both require `shared_preload_libraries` (restart). `auto_explain` is the only performance module here that can be loaded per-session without a restart; `pg_stat_kcache`, `pg_wait_sampling`, `pg_squeeze`, and `pg_cron` all require preload + restart.
2. Debian ships all core contrib in `postgresql-contrib` (a metapackage tracking the default server version); RHEL ships it as `postgresqlNN-contrib`. On a fresh installation, contrib may not be installed at all — check before assuming `pg_stat_statements` files exist.
3. Package naming diverges sharply: Debian `postgresql-16-<ext>` (hyphens, `pg_` often dropped) vs RHEL `<ext>_16` (upstream name with underscores intact + version suffix). This is the single most common time-waster.
4. Amazon Linux is NOT an officially supported PGDG platform; `postgresqlNN-contrib` from PGDG can fail on a Python `.so` dependency on AL2. AL2023 ships PostgreSQL in its own repos.
5. PG13+ trusted extensions (`pg_trgm`, `hstore`, `citext`, `btree_gin/gist`, `pgcrypto`, `unaccent`, `fuzzystrmatch`, `intarray`, `cube`, `tablefunc`, `"uuid-ossp"`, etc.) can be created by any user with CREATE on the database — no superuser needed.

## Details

### 1. DISCOVERY QUERIES (run these first)

**(a) Which extensions are installed in the current database**
```sql
\dx
\dx+ pg_stat_statements          -- objects belonging to an extension
SELECT e.extname, e.extversion, n.nspname AS schema
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY 1;
```

**(b) Which extensions are AVAILABLE on the machine (files present on disk)**
```sql
SELECT name, default_version, installed_version, comment
FROM pg_available_extensions ORDER BY name;

SELECT name, version, installed
FROM pg_available_extension_versions ORDER BY name, version;
```
`pg_available_extensions` reflects the `.control` files present on the filesystem — i.e. what the server *can* install, not what is installed. If an extension is missing here, you need to install its OS package first.

**(c) Check versions / available updates**
```sql
-- rows where an update is available:
SELECT name, installed_version, default_version
FROM pg_available_extensions
WHERE installed_version IS NOT NULL AND installed_version <> default_version;

ALTER EXTENSION pg_stat_statements UPDATE;              -- to default_version
ALTER EXTENSION pg_stat_statements UPDATE TO '1.11';    -- to a specific version
```

**(d) Preload libraries and other relevant settings**
```sql
SHOW shared_preload_libraries;
SHOW session_preload_libraries;
SHOW local_preload_libraries;
SHOW config_file;                 -- exact postgresql.conf path
SHOW data_directory;
SHOW hba_file;
SELECT name, setting, source, pending_restart
FROM pg_settings WHERE name LIKE '%preload%' OR name LIKE 'pg_stat_statements.%';
-- what's set where, including bad lines, across all conf files:
SELECT sourcefile, seqno, name, setting, applied, error FROM pg_file_settings
WHERE name = 'shared_preload_libraries';
SELECT * FROM pg_hba_file_rules;   -- sanity-check auth as well
```
`pg_settings.pending_restart = true` tells you a `shared_preload_libraries` change is staged but not yet active — a fast way to see if someone edited config but hasn't restarted.

**(e) Extensions installed in OTHER databases in the cluster**
Extensions are per-database. To see them cluster-wide, loop over databases:
```sql
SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate;
```
```bash
for db in $(psql -At -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate"); do
  echo "== $db =="; psql -d "$db" -c "SELECT extname, extversion FROM pg_extension ORDER BY 1";
done
```

**(f) Filesystem-level checks (control files and .so libraries)**
```bash
pg_config --sharedir      # e.g. /usr/share/postgresql/16  (Debian) or /usr/pgsql-16/share (RHEL)
pg_config --pkglibdir     # e.g. /usr/lib/postgresql/16/lib or /usr/pgsql-16/lib
ls $(pg_config --sharedir)/extension/*.control
ls $(pg_config --sharedir)/extension/ | sort           # every available extension
ls $(pg_config --pkglibdir)/*.so                       # loadable modules (auto_explain.so etc.)
grep -l 'trusted = true' $(pg_config --sharedir)/extension/*.control   # list trusted extensions
```
Note: `auto_explain` has a `.so` in pkglibdir but **no `.control` file** — it is a loadable module, not a CREATE EXTENSION extension.

### 2. IDENTIFY PLATFORM + VERSION, THEN FIND/INSTALL PACKAGES

**Identify quickly:**
```bash
cat /etc/os-release                 # ID=debian/ubuntu/rhel/rocky/almalinux/amzn, VERSION_ID
psql -c "SELECT version();"         # PG major + build
pg_lsclusters                       # Debian/Ubuntu: version, cluster name, port, status, data & log dirs
ls /etc/apt/sources.list.d/ /etc/yum.repos.d/ 2>/dev/null   # which repos are configured
```
Debian clusters are named `<version>-<name>` (e.g. `16-main`); RHEL uses a single data dir per version.

**Debian / Ubuntu (apt, PGDG at apt.postgresql.org):**
```bash
# which package provides an extension:
apt-cache search postgresql-16          # list add-on packages for PG16
apt list --installed 2>/dev/null | grep postgresql
apt-file search pg_repack.control       # which package provides a file (needs apt-file update)
dpkg -L postgresql-16-repack            # files an installed package owns
dpkg -S /usr/lib/postgresql/16/lib/pg_repack.so   # which package owns a file

# contrib (all core contrib extensions incl. pg_stat_statements, pg_trgm, pgcrypto, hstore, uuid-ossp):
sudo apt-get install -y postgresql-contrib          # metapackage tracking default server version
sudo apt-get install -y postgresql-16-<ext>         # e.g. postgresql-16-repack, postgresql-16-cron
```
Naming convention: `postgresql-<major>-<ext>` with hyphens; `pg_` is often dropped or hyphenated (see table). To add the PGDG repo: `sudo apt install -y postgresql-common && sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh`.

**RHEL / Rocky / Alma / (Amazon) (dnf/yum, PGDG at yum.postgresql.org):**
```bash
# which package provides an extension (via its .control or .so):
dnf provides '*/pg_repack.control'
dnf repoquery --whatprovides '*/pg_repack.control'
dnf repoquery --repoid=pgdg16 'pg_*'            # everything in the PG16 repo
dnf list available 'pg_repack_16*'
dnf repoquery -l pg_repack_16                    # files a (not-yet-installed) package installs
rpm -ql pg_repack_16                             # files an installed package owns
rpm -qf /usr/pgsql-16/share/extension/pg_repack.control   # which package owns a file

# contrib:
sudo dnf install -y postgresql16-contrib
sudo dnf install -y <ext>_16                      # e.g. pg_repack_16, hypopg_16, pg_cron_16
```
Repo setup + the critical AppStream gotcha:
```bash
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql            # otherwise RHEL's AppStream module shadows PGDG packages
```
Naming convention: `<extname>_<major>` with underscores preserved and a `_16`/`_17` suffix. Files land in `/usr/pgsql-16/{share/extension,lib}`.

**Package name cross-reference (external extensions):**

| Extension | Debian/Ubuntu (PG16) | RHEL/Rocky/Alma (PG16) |
|---|---|---|
| pg_repack | `postgresql-16-repack` | `pg_repack_16` |
| hypopg | `postgresql-16-hypopg` | `hypopg_16` |
| pg_hint_plan | `postgresql-16-pg-hint-plan` | `pg_hint_plan_16` |
| pg_stat_kcache | `postgresql-16-pg-stat-kcache` | `pg_stat_kcache_16` |
| pg_squeeze | `postgresql-16-squeeze` | `pg_squeeze_16` |
| pg_wait_sampling | `postgresql-16-pg-wait-sampling` | `pg_wait_sampling_16` |
| pg_cron | `postgresql-16-cron` | `pg_cron_16` |
| system_stats | `postgresql-16-system-stats` | `system_stats_16` |
| pg_stat_monitor | `percona-pg-stat-monitorNN` / `postgresql-16-pg-stat-monitor` | `pg_stat_monitor_16` / `percona-pg-stat-monitor16` |

(Substitute `17` for PG17. RHEL is uniform: `<upstream_name>_NN`. Debian is irregular — `pg_repack`→`-repack`, `pg_squeeze`→`-squeeze`, `pg_cron`→`-cron` drop the `pg_`, while `pg-hint-plan`, `pg-stat-kcache`, `pg-wait-sampling`, `system-stats` keep the full hyphenated name. Never derive one convention from the other — check with the discovery commands.)

**Amazon Linux specifics (environments running on EC2):**
- Amazon Linux is **not** an officially supported PGDG target. On **AL2**, installing `postgresqlNN-contrib` from PGDG commonly fails on a `libpython3.x.so` dependency; the workaround is to enable EPEL via `amazon-linux-extras install epel` and install a matching Python from `amazon-linux-extras` (`--disablerepo=amzn2-core`).
- On **AL2023**, PostgreSQL 15 (and 16/17 depending on release) is available directly from the default `dnf` repos (`sudo dnf install postgresql15 postgresql15-server postgresql15-contrib`) — often the path of least resistance; check `dnf list available 'postgresql1*'` first.
- Percona Distribution provides its own repos via `percona-release` (`sudo percona-release setup ppg-16`) and is a clean way to get `pg_stat_monitor` on supported distros.

### 3. USEFUL EXTENSIONS BY CATEGORY

Legend: **[C]** = core contrib (in `postgresql-contrib`/`postgresqlNN-contrib`); **[X]** = external package; **[SPL]** = needs `shared_preload_libraries` + restart; **[SES]** = can be loaded per-session; **[CE]** = just `CREATE EXTENSION`.

#### Query performance analysis
- **pg_stat_statements [C][SPL]** — the single most important extension. Tracks normalized query stats cluster-wide. Config (all in postgresql.conf; restart needed for the first three):
  - `shared_preload_libraries = 'pg_stat_statements'`
  - `pg_stat_statements.max` (default 5000) — max distinct statements tracked
  - `pg_stat_statements.track` = `top`(default)/`all`/`none` — `all` includes nested (function) statements; changeable by reload
  - `pg_stat_statements.track_utility` (default on) — track non-DML utility commands
  - `pg_stat_statements.track_planning` (default off) — track planning time (PG13+); minor overhead
  - `compute_query_id = auto` (default) must be on/auto or the view stays empty.
  - Top-queries examples:
    ```sql
    SELECT (total_exec_time+total_plan_time)::int AS total_ms, calls,
           mean_exec_time::int AS mean_ms, query
    FROM pg_stat_statements ORDER BY total_ms DESC LIMIT 20;

    SELECT query, calls, mean_exec_time::int AS mean_ms,
           100.0*shared_blks_hit/nullif(shared_blks_hit+shared_blks_read,0) AS hit_pct
    FROM pg_stat_statements WHERE calls > 50 ORDER BY mean_exec_time DESC LIMIT 20;
    ```
  - Reset: `SELECT pg_stat_statements_reset();` (optionally by userid/dbid/queryid). Reset *after* schema/index changes to get a clean baseline. `pg_stat_statements_info.dealloc` shows how often entries were evicted (raise `.max` if high).
- **pg_stat_monitor [X][SPL]** — **Percona's extension for time-series statistics.** Compatible with PostgreSQL 13–18 (per Percona's pgsm-docs). Superset of pg_stat_statements adding time-based *bucket* aggregation, multi-dimensional grouping (adds client IP, application_name, etc.), per-query histograms, captured query plans and actual parameters, and error/warning tracking. Load *after* pg_stat_statements: `shared_preload_libraries = 'pg_stat_statements, pg_stat_monitor'`. Key GUCs (most require restart): `pgsm_max` (shared mem MB), `pgsm_max_buckets`, `pgsm_bucket_time` (default 300 seconds per bucket, restart to change), `pgsm_query_max_len`, `pgsm_normalized_query`, `pgsm_enable_query_plan` (keep **off** — it multiplies records and skews timings), `pgsm_track` (top/all/none), `pgsm_histogram_min/max/buckets`, `pgsm_enable_overflow` (note: `pgsm_overflow_target` is deprecated since v2.0.0 — use `pgsm_enable_overflow` instead). Usage: `SELECT bucket, query, calls, mean_exec_time FROM pg_stat_monitor ORDER BY ...;` and settings via `SELECT * FROM pg_settings WHERE name LIKE 'pg_stat_monitor.%';`. Create in the `postgres` DB to get cluster-wide visibility.
- **auto_explain [C, module][SES or SPL]** — logs execution plans of slow queries automatically. **Not a CREATE EXTENSION extension — it's a loadable module** (no `.control`; you `LOAD` it or preload it). Loading options: (1) `LOAD 'auto_explain';` in a single superuser session (no restart); (2) `session_preload_libraries = 'auto_explain'` (reload; applies to new sessions, can be scoped with `ALTER ROLE ... SET`); (3) `shared_preload_libraries` (restart; every session). Key GUCs: `auto_explain.log_min_duration` (ms; -1 disables, 0 logs all), `.log_analyze`, `.log_buffers`, `.log_format`, `.log_nested_statements`, `.log_timing`. **This is the no-restart way to get plan data when you can't afford a restart for pg_stat_statements.** Beware `log_analyze` overhead on hot paths.
- **pg_stat_kcache [X][SPL]** — real filesystem-layer reads/writes and CPU (user/system) time per query; enables a *true* cache hit ratio. Requires pg_stat_statements. Preload after it: `shared_preload_libraries = 'pg_stat_statements, pg_stat_kcache'`.

#### Index & bloat analysis (all core contrib, mostly CREATE EXTENSION only)
- **pgstattuple [C][CE]** — tuple-level bloat stats: `SELECT * FROM pgstattuple('mytable');`, `SELECT * FROM pgstatindex('myindex');`, `pgstattuple_approx()` for a fast estimate.
- **pg_visibility [C][CE]** — visibility-map diagnostics: `SELECT * FROM pg_visibility_map_summary('t');`; find pages not all-visible (impacts index-only scans).
- **amcheck [C][CE]** — verify index/heap consistency: `SELECT bt_index_check('idx');` / `bt_index_parent_check('idx')`; heapallindexed and (PG14+) heap checks via `verify_heapam()`.
- **pageinspect [C][CE]** — raw page inspection (`heap_page_items`, `bt_page_stats`, etc.) — deep forensics.
- **pg_buffercache [C][CE]** — what's in shared_buffers. `SELECT * FROM pg_buffercache_summary();` and `pg_buffercache_usage_counts()` — both **added in PostgreSQL 16** (16.0 Release Notes: "Add pg_buffercache function pg_buffercache_usage_counts() to report usage totals" and "Add pg_buffercache function pg_buffercache_summary() to report summarized buffer statistics") and much cheaper than scanning the full view. `pg_buffercache_evict()` was added in **PG17** and is "intended for developer testing only" / "restricted to superusers only" (PG18 docs). `pg_buffercache_evict_relation()`, `pg_buffercache_evict_all()`, and the `pg_buffercache_numa` view were added in **PG18** (commits dcf7e169 / ba2a3c23). Dirty-buffer count (useful before a restart):
  ```sql
  SELECT count(*), pg_size_pretty(count(*)*8*1024) FROM pg_buffercache WHERE isdirty;
  ```

#### Query optimization helpers
- **pg_trgm [C][CE, trusted]** — trigram indexes to accelerate `LIKE '%x%'`/`ILIKE`/similarity. Very likely relevant. `CREATE EXTENSION pg_trgm; CREATE INDEX ON t USING gin (col gin_trgm_ops);` (or `gist`). `SELECT similarity(a,b);`, `a % b`.
- **btree_gin [C][CE, trusted]** / **btree_gist [C][CE, trusted]** — B-tree semantics inside GIN/GiST; enables multicolumn GIN mixing scalar + array/jsonb, and GiST exclusion constraints.
- **bloom [C][CE]** — bloom-filter index AM for multi-column equality filtering.
- **hypopg [X][CE]** — **hypothetical indexes without build cost — ideal under time pressure.** `SELECT * FROM hypopg_create_index('CREATE INDEX ON t(col)');` then plain `EXPLAIN` (not ANALYZE — hypothetical indexes are invisible to ANALYZE). `hypopg_list_indexes`, `hypopg_relation_size(oid)`, `hypopg_reset()`. Backend-local, in-memory, no restart, doesn't disturb other sessions.
- **pg_hint_plan [X][SPL/SES]** — force planner decisions via `/*+ ... */` hints; typically loaded via shared/session preload. Use to prove a plan hypothesis when you can't change stats.

#### Maintenance / administration
- **pg_repack [X][CE + client binary]** — **online table/index rebuild to remove bloat without the long ACCESS EXCLUSIVE lock of VACUUM FULL/CLUSTER.** Builds a shadow copy, captures changes via triggers, replays them, then swaps with only a brief exclusive lock. Needs `CREATE EXTENSION pg_repack;` plus the matching-version client binary and free disk ≈ 2× table size; the target needs a PK or NOT NULL unique index. Run: `pg_repack -d mydb --table orders`, `--only-indexes`, `--no-order`, `-j N` (parallel index builds). Supports PG 9.5–18. Contrast in your report: VACUUM FULL = fast but blocks all reads/writes; pg_repack = online but needs disk + time.
- **pg_squeeze [X][SPL]** — automated background bloat removal via logical decoding; alternative to pg_repack; needs preload.
- **pg_cron [X][SPL]** — in-database cron. `shared_preload_libraries='pg_cron'`, `cron.database_name='postgres'` (metadata lives in one DB only), optional `cron.timezone` (defaults to GMT). `SELECT cron.schedule('nightly-vacuum','0 3 * * *','VACUUM');`, `cron.schedule_in_database(...)`, `cron.unschedule(...)`; history in `cron.job_run_details`.

#### Data / utility (all core contrib; trusted ones creatable by non-superusers)
- **uuid-ossp [C][CE, trusted]** — **must be double-quoted:** `CREATE EXTENSION "uuid-ossp";` then `uuid_generate_v4()`. (On PG13+ prefer built-in `gen_random_uuid()` — no extension needed.)
- **pgcrypto [C][CE, trusted]** — `crypt()`, `gen_salt()`, `digest()`, `pgp_sym_encrypt()`, `gen_random_bytes()`.
- **tablefunc [C][CE, trusted]** — `crosstab()` pivot tables, `normal_rand()`.
- **intarray [C][CE, trusted]**, **hstore [C][CE, trusted]**, **citext [C][CE, trusted]**, **unaccent [C][CE, trusted]**, **fuzzystrmatch [C][CE, trusted]** (soundex/levenshtein/metaphone), **cube [C][CE, trusted]** + **earthdistance [C][CE]** (great-circle distance; depends on cube).
- **postgres_fdw [C][CE]**, **file_fdw [C][CE]**, **dblink [C][CE]** — external/foreign data access (not trusted; superuser to create).

#### Monitoring / diagnostics
- **pg_wait_sampling [X][SPL]** — samples wait events to profile where time is spent; needs preload.
- **pg_proctab [X][CE]** — OS process/table stats from within SQL.
- **system_stats [X][CE]** — EnterpriseDB extension exposing OS-level CPU/memory/disk metrics via SQL.

#### PL languages
- **plpgsql [C]** — installed by default.
- **plpython3u [C][CE]** — untrusted; superuser only; needs `postgresql-plpython3-NN`/`postgresqlNN-plpython3`.
- **plperl [C][CE, trusted for plperl]** — `postgresql-plperl-NN`/`postgresqlNN-plperl`.

### 4. CONFIGURATION CHANGES — both methods

**Method A — ALTER SYSTEM (writes postgresql.auto.conf):**
```sql
-- GOTCHA: ALTER SYSTEM SET shared_preload_libraries OVERWRITES, it does NOT append.
-- 1) read the current value first:
SHOW shared_preload_libraries;
-- 2) set the FULL list you want:
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements, pg_stat_monitor, auto_explain';
-- 3) restart (see per-platform commands). Verify pending change:
SELECT name, setting, pending_restart FROM pg_settings WHERE name='shared_preload_libraries';
```
Reset a bad entry: `ALTER SYSTEM RESET shared_preload_libraries;`. `postgresql.auto.conf` overrides `postgresql.conf` and always wins.

**Method B — edit postgresql.conf directly:**
- Find it: `SHOW config_file;`
- Debian/Ubuntu layout: `/etc/postgresql/<ver>/main/postgresql.conf` (+ `conf.d/`), data in `/var/lib/postgresql/<ver>/main`.
- RHEL layout: `/var/lib/pgsql/<ver>/data/postgresql.conf` (config lives in the data dir).
- Many setups `include_dir 'conf.d'` — dropping a `10-perf.conf` there is cleaner than editing the main file. Last setting wins.

**Reload vs restart:**
- `shared_preload_libraries` (and `pg_stat_statements.max`, `pgsm_*` memory settings) → **restart required.**
- `pg_stat_statements.track`, `auto_explain.*`, `log_min_duration_statement`, `session_preload_libraries` → **reload** (`SELECT pg_reload_conf();` or `systemctl reload`).

**Restart / reload commands:**

| | Debian/Ubuntu | RHEL/Rocky/Alma |
|---|---|---|
| restart | `sudo systemctl restart postgresql@16-main` or `sudo pg_ctlcluster 16 main restart` | `sudo systemctl restart postgresql-16` |
| reload | `sudo systemctl reload postgresql@16-main` / `SELECT pg_reload_conf();` | `sudo systemctl reload postgresql-16` / `SELECT pg_reload_conf();` |

Note `postgresql.service` on Debian is a wrapper acting on all clusters; target the specific `postgresql@16-main` instance.

**Consultant framing of a restart on "production":** Before restarting, run an explicit `CHECKPOINT;` (optionally twice) to flush dirty buffers so the shutdown checkpoint is light and downtime is short and predictable. Use the **fast** shutdown mode (default for `pg_ctl stop`/systemd) — it rolls back active transactions and disconnects clients cleanly, then checkpoints; avoid **smart** (waits for clients — can hang indefinitely) and **immediate** (crash-like, forces WAL recovery on restart and zeroes unlogged tables). In the report: state the outage window, that a checkpoint was issued first to minimize it, that fast mode was used, and why the extension benefit justifies a one-time brief restart.

### 5. VERIFICATION AFTER INSTALL
```sql
-- library actually loaded:
SHOW shared_preload_libraries;
SELECT * FROM pg_stat_statements LIMIT 1;         -- returns rows once active
SELECT * FROM pg_stat_monitor LIMIT 1;
-- extension registered + schema placement:
\dx
SELECT extname, extnamespace::regnamespace FROM pg_extension;
```
- **Schema placement:** `CREATE EXTENSION pg_stat_statements SCHEMA monitoring;` for relocatable extensions; check `search_path` so objects are reachable. Some extensions are not relocatable.
- **Logs:** check for load errors — Debian `/var/log/postgresql/postgresql-16-main.log`; RHEL `/var/lib/pgsql/16/data/log/`. A typo in `shared_preload_libraries` (missing/mis-typed library) will **prevent startup** — the most dangerous mistake on a production box.
- **Access:** grant read of stats views to non-superusers with the `pg_read_all_stats` role: `GRANT pg_read_all_stats TO app_ro;` (also gates the query text/queryid columns in pg_stat_statements).

## 6. DIAGNOSTIC STRATEGY
- **Sequence:** (1) identify OS + PG version + config paths; (2) if query optimization is expected, get `pg_stat_statements` in `shared_preload_libraries` and restart **early** so stats accumulate while you work; add `pg_stat_monitor` in the same restart to capture time-bucketed metrics; (3) do other tasks; (4) return to analyze accumulated stats.
- **No-restart fallback:** if you cannot justify a restart yet, use `LOAD 'auto_explain'; SET auto_explain.log_min_duration = 0;` in a session, or `session_preload_libraries` via `ALTER ROLE` — plan capture with zero restart.
- **Contrib may be absent on a fresh system** — verify with `pg_available_extensions`/filesystem check before assuming `pg_stat_statements` exists; install `postgresql-contrib`/`postgresqlNN-contrib` if missing.
- **No internet?** Check whether packages are cached (`/var/cache/apt/archives`, `/var/cache/dnf`) or already on disk; check if the `.control`/`.so` files are present even if the extension isn't created (then just `CREATE EXTENSION`). Don't burn time fighting a repo that can't reach the internet — pivot to `auto_explain`/built-ins and document the constraint.
- **Document per change:** why installed, exact config changed, reload vs restart (and restart justification/window), verification performed, and rollback (`ALTER SYSTEM RESET ...` / `DROP EXTENSION`).
- **Vendor Distribution:** If using Percona Distribution for PostgreSQL, utilize the `percona-release` repo tool (`sudo percona-release setup ppg-16`) to install `pg_stat_monitor` easily.

### 7. OTHER RELEVANT ASPECTS
- **Upgrades:** `ALTER EXTENSION ... UPDATE [TO 'x']`; some extensions (e.g. hypopg) ship no upgrade scripts — DROP then CREATE. Changing a shared-memory extension's version may need a restart before the new `.so` functions resolve.
- **DROP + dependencies:** `DROP EXTENSION x;` fails if objects depend on it; `DROP EXTENSION x CASCADE;` drops dependents too — check first:
  ```sql
  SELECT e.extname, d.refobjid::regclass FROM pg_depend d
  JOIN pg_extension e ON e.oid=d.refobjid WHERE d.deptype='e';
  ```
- **pg_dump/restore:** dumps emit `CREATE EXTENSION` (not the extension's member objects), so the extension's OS package must be present at restore time or restore fails; objects users add *into* an extension's schema are dumped normally.
- **Version compatibility:** the extension package major version must match the server major version (`pg_repack_16` for PG16). Mismatched client/server versions of the pg_repack binary won't work.
- **Trusted vs untrusted (PG13+):** trusted extensions (pg_trgm, hstore, citext, btree_gin/gist, pgcrypto, unaccent, fuzzystrmatch, intarray, cube, tablefunc, uuid-ossp, ltree, isn, seg, plperl, and more) are creatable by any user with CREATE on the DB; untrusted (postgres_fdw, file_fdw, dblink, plpython3u, and modules loaded via preload) need superuser. Verify with `grep -l 'trusted = true' $(pg_config --sharedir)/extension/*.control`.
- **Common pitfalls:** forgetting the restart after editing `shared_preload_libraries`; forgetting to quote `"uuid-ossp"`; contrib package not installed; wrong package version for the PG major; `ALTER SYSTEM SET shared_preload_libraries` clobbering an existing list; `compute_query_id=off` leaving pg_stat_statements empty; expecting hypothetical indexes to appear under `EXPLAIN ANALYZE` (they don't).

## Recommendations
1. **Phase 1 (Discovery):** SSH in; run the platform/version block and the discovery queries; note config paths, current `shared_preload_libraries`, and whether contrib is present. Save output for reference.
2. **Phase 2 (Setup, if query tuning is in scope):** install contrib if needed, set `shared_preload_libraries = '<existing>, pg_stat_statements, pg_stat_monitor'` via ALTER SYSTEM (after reading current value), `CHECKPOINT;`, restart the specific cluster, verify with `SELECT * FROM pg_stat_statements LIMIT 1;`. Let stats accumulate while you do other tasks.
3. **If a restart isn't yet justifiable:** use `auto_explain` via session/role preload for immediate plan capture; add `pg_trgm`/`hypopg` (no restart) for index work.
4. **For bloat/maintenance tasks:** prefer `pg_repack` over `VACUUM FULL` on a live table; if pg_repack isn't installable, document the trade-off and schedule VACUUM FULL in a stated window.
5. **Documentation:** for every change record purpose, config diff, reload-vs-restart + justification, verification, and rollback. Explicitly flag any assumptions (e.g. no internet, unsupported Amazon Linux).
- **Thresholds that change the plan:** if there is *no* query-optimization task, skip the restart entirely and rely on `auto_explain`/`pg_stat_activity`. If the box is Amazon Linux and PGDG contrib won't install, switch to the distro's own `postgresqlNN` packages or Percona's repo. If there's no PK on a bloated table, pg_repack is unavailable — fall back to VACUUM FULL in a window.

## Caveats
- Package names were verified against PGDG repo listings and vendor docs; a few RHEL PG17 names (`system_stats_17`, `pg_squeeze_17`) were confirmed from catalog sources and the uniform `_NN` convention rather than a captured live index line — verify on-box with `dnf provides`/`dnf repoquery`.
- Amazon Linux is not an officially supported PGDG platform; behavior of PGDG RPMs there (especially contrib's Python dependency) can vary by release — treat as a known risk and document.
- Exact log paths, cluster names, and data directories vary by install; always confirm via `SHOW config_file`, `SHOW data_directory`, and `pg_lsclusters` rather than assuming.
- `pg_stat_monitor` GUC names and defaults have changed across its 1.x/2.x releases (e.g. `pgsm_overflow_target` deprecated in favor of `pgsm_enable_overflow` since v2.0.0; `pgsm_bucket_time` default 300s); check `SELECT * FROM pg_settings WHERE name LIKE 'pg_stat_monitor.%';` on the actual version present.