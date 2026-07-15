# MySQL Since 5.7: A Comprehensive Technical Report for PostgreSQL Specialists

## TL;DR
- MySQL 8.0 (8.0.11 GA on 19 April 2018) was a generational rewrite—transactional InnoDB-backed data dictionary, atomic/crash-safe DDL, a Volcano iterator executor with hash joins, CTEs/window functions/LATERAL, roles, histograms, and utf8mb4 defaults—while the post-8.0 world split into a quarterly **Innovation** track and a biennial **LTS** track (8.4 LTS in April 2024; 9.7 LTS in April 2026). MySQL 8.0 reached End of Life in April 2026 with 8.0.46.
- The two migration landmines are the **authentication plugin change** (`caching_sha2_password` default; `mysql_native_password` deprecated 8.0.34, disabled by default 8.4, removed 9.0) and the **mandatory stepwise upgrade path** (5.7→8.0→8.4→9.x, no skipping), compounded by reserved-word additions, sql_mode strictness, utf8mb4 defaults, and removal of the query cache and `mysql_upgrade`.
- MariaDB is no longer a drop-in replacement (divergent optimizer, LONGTEXT-based JSON, sequences, system-versioned tables, built-in Galera, no Group Replication), while Percona Server for MySQL tracks Oracle closely and adds instrumentation, MyRocks, and the XtraBackup/PXC ecosystem.

## Key Findings

- **The data dictionary is the keystone change.** MySQL 8.0 replaced `.frm/.par/.trg/.trn/.opt` files and the nontransactional metadata tables with a single set of InnoDB tables, enabling atomic (though not fully transactional) DDL and eliminating filesystem-name/case-sensitivity metadata bugs.
- **The executor was rewritten** from a nested-loop-hardwired model to a Volcano/iterator model (WL#12074), which is what made hash join (8.0.18), `EXPLAIN ANALYZE` (8.0.18) and `EXPLAIN FORMAT=TREE` possible.
- **The SQL surface caught up with the standard**: CTEs and recursive CTEs, window functions, LATERAL, `INTERSECT`/`EXCEPT` (8.0.31), `VALUES`/`TABLE`, enforced CHECK constraints (8.0.16), functional indexes (8.0.13), multi-valued JSON indexes (8.0.17), `JSON_TABLE`, `JSON_VALUE` (8.0.21), and expressions as column DEFAULTs (8.0.13).
- **HA matured around Group Replication + InnoDB Cluster/ReplicaSet + MySQL Router + the clone plugin** (8.0.17), and the whole stack de-slaved its terminology (source/replica) with 8.4 removing the old SQL syntax entirely.
- **9.x Innovation releases** added the `VECTOR` type (9.0), JavaScript stored programs (9.0, Enterprise/HeatWave), and JSON Duality Views (9.4, DML in Community from 9.7). 9.7 (April 2026) is the second LTS.

## Details

### 1. Release model and versioning

Through 8.0.33, MySQL used a continuous-delivery model in which new features shipped inside patch releases (e.g., hash join in 8.0.18, INSTANT DROP COLUMN in 8.0.29). This was a persistent operational complaint: a "patch" upgrade could change query plans or SQL behaviour.

From July 2023 Oracle split development into two tracks:

- **Innovation releases** — quarterly, incrementing the minor version (8.1, 8.2, 8.3, then 9.0, 9.1, …). Production-grade, but supported only until the next release; may add features, deprecate, remove, and change behaviour. Intended for teams with strong CI and rapid upgrade cadence.
- **LTS releases** — roughly every two years; the last minor of a major series. 8.4.0 (April 2024) is the first LTS; features are added/removed only in the `.0` of an LTS, and never within the series. LTS gets Oracle's Lifetime Support Policy: 5 years premier + 3 years extended. For 8.4: Premier Support through 30 April 2029 and Extended Support through 30 April 2032.

Key timeline facts:
- **8.0.34** was the pivot: 8.0 transitioned to bug-fix-only.
- **8.1.0 / 8.2.0 / 8.3.0** were the three Innovation releases bridging to the 8.4 LTS. 8.1 added `EXPLAIN FORMAT=JSON ... INTO @var`, `SHOW PARSE_TREE`, and Group Replication diagnostics; 8.3 removed the InnoDB memcached plugin and a raft of deprecated replication options; 8.3 also introduced `explain_json_format_version=2` (access-path-based EXPLAIN JSON).
- **8.4.0** (April 2024) — first LTS.
- **9.0.0** (released 1 July 2024) — first post-LTS Innovation — was withdrawn from distribution per its own Release Notes: "This release is no longer available for download. It was removed due to a critical issue that could stop the server from restarting following the creation of a very large number of tables (8001 or more)" (Bug #36808732). Oracle shipped out-of-cycle 9.0.1 / 8.4.2 / 8.0.39 on 24 July 2024. Then 9.1, 9.2, 9.3 (April 2025), 9.4 (July 2025), 9.5 (October 2025), 9.6, and **9.7 (April 2026), the second LTS**.
- **MySQL 8.0 EOL:** the 8.0 Release Notes state, "As of April 2026, with version 8.0.46, MySQL 8.0 reaches End of Life (EoL)" (Oracle HeatWave docs give the community date as 30 April 2026; managed HeatWave 8.0 critical patches extend to April 2027). MySQL 8.0.46 shipped alongside 9.7.

Upgrade-path constraints under the new model: within an LTS series in-place upgrade **and downgrade** are supported (e.g., 8.4.0↔8.4.2). Across LTS series you may go 8.4→9.7 but not skip an LTS. Innovation-to-Innovation across major versions is not direct (8.3→9.0 is invalid); you must go 8.3→8.4→9.0. From 9.3 onward, downgrades between individual Innovation releases are no longer possible even within the same series. Innovation downgrades generally require logical dump and load.

### 2. Architecture and internals

**Transactional data dictionary (8.0.0).** All object metadata—tables, columns, indexes, triggers (formerly `.TRN/.TRG`), events, stored programs, privileges (formerly MyISAM tables), tablespaces, character sets, plugins—now lives in InnoDB tables in the `mysql` schema (stored in `mysql.ibd`). The `db.opt` file is gone; `.frm` files are gone. Serialized Dictionary Information (SDI) is embedded in tablespaces to permit metadata reconstruction. `INFORMATION_SCHEMA` tables are now views over these dictionary tables, which is dramatically faster than the old file-scanning implementation. Practically for a Postgres person: this is MySQL finally giving itself a `pg_catalog`-like transactional catalog instead of a filesystem-of-metadata.

**Atomic DDL (8.0).** An atomic DDL statement bundles the data-dictionary update, the storage-engine operation, and the binary-log write into one atomic unit that either fully commits or fully rolls back, even across a crash. InnoDB writes a DDL log to the hidden `mysql.innodb_ddl_log` table; on recovery the operation is rolled forward if the commit record is present in redo and binlog, otherwise rolled back. Note the crucial caveat: **this is atomic DDL, not transactional DDL**—you still cannot wrap DDL in a multi-statement transaction and roll it back at will (a difference the Postgres user will immediately feel; Postgres has true transactional DDL). Only InnoDB supports it. `DROP TABLE t1,t2`, `DROP DATABASE`, `CREATE USER`, `DROP USER`, `GRANT` now behave all-or-nothing.

**INSTANT DDL.** `ALGORITHM=INSTANT` (metadata-only change) became the default algorithm for supported operations:
- 8.0.12: INSTANT ADD COLUMN, trailing position only.
- 8.0.29: INSTANT ADD COLUMN at **any** position and INSTANT DROP COLUMN, via a row-versioning scheme (an info-bit flags rows carrying a version; `INFORMATION_SCHEMA.INNODB_TABLES.TOTAL_ROW_VERSIONS` tracks it). Limit of 64 row versions per table (raised to 255 in 9.1.0) before a rebuild (`OPTIMIZE TABLE`/`ALTER ... ENGINE=InnoDB`) is required to reset. Best practice: always name the algorithm explicitly so MySQL errors rather than silently falling back to a table rebuild. INSTANT operations are excluded on `ROW_FORMAT=COMPRESSED`, tables with FULLTEXT indexes, temporary tables, and the data-dictionary tablespace.

**Redo log (8.0.30).** `innodb_redo_log_capacity` (default 100 MB, min 8 MB, max 128 GB) supersedes `innodb_log_file_size` × `innodb_log_files_in_group` and is **dynamic**—resizable online with no restart. InnoDB maintains ~32 files under `#innodb_redo/`, treating the log as a queue rather than the old two-file circular buffer, with spare `_tmp` files. Adaptive flushing thresholds are expressed as fractions of a soft logical capacity (~30/32 of the total). New status variables (`Innodb_redo_log_resize_status`, `Innodb_redo_log_capacity_resized`) support monitoring; a redo-log consumer/archiving service exists. If capacity is insufficient, InnoDB logs `[MY-013865] Redo log writer is waiting for a new redo log file`.

**Other InnoDB storage changes since 5.7:**
- **Undo tablespaces** became independent of the system tablespace. `innodb_undo_log_truncate` defaults ON as of 8.0.2; as of 8.0.14 undo tablespaces can be created and dropped at runtime with `CREATE/DROP UNDO TABLESPACE`, and `innodb_undo_tablespaces` is deprecated and pinned at 2 (minimum two required to allow online truncation of one while the other serves). Undo logs no longer live in `ibdata`.
- **Doublewrite buffer (8.0.20)** moved out of the system tablespace into dedicated doublewrite files, configurable via `innodb_doublewrite_dir`, `innodb_doublewrite_files`, `innodb_doublewrite_pages`. 8.0.30 added `DETECT_ONLY`/`DETECT_AND_RECOVER` modes.
- **Temporary tablespaces:** session temporary tablespaces are drawn from a pool (8.0.13; `INNODB_SESSION_TEMP_TABLESPACES` I_S table added), allocated (max two per session) on first on-disk temp-table need and truncated back to the pool at disconnect; the global temp tablespace is `ibtmp1` (auto-extending, initial ~12 MB). From 8.0.16 on-disk internal temp tables use the InnoDB engine.
- **Self-tuning:** `innodb_dedicated_server` (8.0.3) auto-sizes buffer pool, redo capacity, and flush method from detected RAM; buffer pool remains online-resizable in chunks (inherited from 5.7.5).

**Character set / collation (8.0.1).** Server default changed from latin1 to **utf8mb4**, with default collation **utf8mb4_0900_ai_ci** (an implementation of the Unicode 9.0.0 UCA; MySQL 8.0 also added many ICU-based `utf8mb4_*_0900` language-specific collations, including accent- and case-sensitive `_as_cs` variants). The 8.0.1 Release Notes state: "the default character set has changed from latin1 to utf8mb4" and "The default collation for the utf8mb4 character set has changed from utf8mb4_general_ci to utf8mb4_0900_ai_ci." `utf8mb3`/`utf8` are deprecated in 8.0; from 8.0.28 `SHOW`/I_S display `utf8mb3` explicitly rather than `utf8`. The `collation_server` default likewise moved from `latin1_swedish_ci` to `utf8mb4_0900_ai_ci`.

**Query cache removed.** Deprecated in 5.7.20, removed in 8.0.3—including `query_cache_size/type/limit/min_res_unit/wlock_invalidate` variables, `FLUSH QUERY CACHE`, `RESET QUERY CACHE`, and `Qcache_*` status. There is no in-server replacement; use ProxySQL, application caching, or MySQL Router/read replicas.

**Authentication default (8.0).** `caching_sha2_password` replaced `mysql_native_password` as the default plugin—SHA-256 based, salted, iterated, with an in-memory fast-path cache, but requiring TLS or RSA key exchange for the initial handshake. Deprecation timeline: `mysql_native_password` deprecated 8.0.34; **disabled by default in 8.4** (re-enableable with `--mysql-native-password=ON` or `loose_mysql_native_password=ON`); **removed entirely in 9.0.0**. `default_authentication_plugin` was deprecated 8.0.27 and removed in 8.4, replaced by `authentication_policy`.

**Persisted system variables (8.0.0).** `SET PERSIST` writes runtime + `mysqld-auto.cnf` for restart persistence; `SET PERSIST_ONLY` writes config only. Removes the old pain of runtime tuning not surviving restart.

**Resource groups (8.0.3).** Named CPU-affinity/priority groups to which threads can be assigned—a coarse workload-management primitive (far less mature than Oracle Resource Manager).

### 3. Optimizer and executor

- **Iterator ("Volcano") executor:** a multi-year rewrite (WL#11785/12074) replacing the old flat, nested-loop-centric executor with composable iterators (table scan, filter, sort, hash join, aggregate, nested loop, various semijoin strategies). This is the enabling infrastructure for everything below and for the future join optimizer.
- **Hash join (8.0.18):** used for equi-joins lacking a usable index; visible only in `EXPLAIN FORMAT=TREE`/`EXPLAIN ANALYZE`, not classic EXPLAIN. Hybrid (in-memory + on-disk grace) with spill; controlled by `hash_join` optimizer switch and `NO_HASH_JOIN`/join-buffer size. Later extended to outer/anti/semijoin and to set operations (`hash_set_operations`).
- **EXPLAIN ANALYZE (8.0.18):** actually executes the query and reports per-iterator timing, actual rows, and loops—MySQL's answer to Postgres's `EXPLAIN (ANALYZE, BUFFERS)`, though without buffer accounting.
- **EXPLAIN FORMAT=TREE** (introduced 8.0.16) and, in 8.1, `EXPLAIN FORMAT=JSON ... INTO @var`; `EXPLAIN FOR CONNECTION` (from 5.7) shows a running statement's plan; `explain_json_format_version=2` (8.3) exposes an access-path-based JSON format.
- **Histograms:** column-statistics histograms via `ANALYZE TABLE ... UPDATE HISTOGRAM ON ...` (singleton and equi-height), stored in the dictionary, used for selectivity of non-indexed columns; 8.4 added `AUTO UPDATE` histograms.
- **Invisible indexes (8.0):** `ALTER TABLE ... ALTER INDEX ... INVISIBLE`—the index is maintained but ignored by the optimizer unless `optimizer_switch=use_invisible_indexes=on`. Ideal for safe drop-testing and staged rollouts (add INVISIBLE, then flip VISIBLE). Primary keys cannot be made invisible.
- **Descending indexes (8.0):** B-tree keys physically stored descending, so `ORDER BY a ASC, b DESC` can be served without filesort. Pre-8.0, `DESC` in an index definition was parsed and ignored.
- **Index skip scan (8.0.13):** allows using a composite index when the leading column is not in the predicate (`skip_scan` switch).
- **Cost model:** separate memory vs. disk IO cost constants, configurable cost tables, adaptive scan buffer, condition fanout filtering, constant folding (8.0.16), and many new optimizer hints (`JOIN_ORDER`, `JOIN_PREFIX`, `JOIN_FIXED_ORDER`, `MERGE`, `INDEX_MERGE`, `SET_VAR`, etc.).
- **Hypergraph optimizer:** a from-scratch join optimizer representing joins as a hypergraph under a unified Access Path abstraction (`hypergraph_optimizer` switch, off by default). In Community/Server it is still experimental/limited; it is the production optimizer for the HeatWave secondary engine.

### 4. SQL / developer features (with introduction versions)

- **Common Table Expressions and recursive CTEs (8.0.1):** `WITH [RECURSIVE]`; recursive CTEs support `LIMIT` from 8.0.19.
- **Window functions (8.0.2):** `RANK`, `DENSE_RANK`, `ROW_NUMBER`, `LAG`, `LEAD`, `NTILE`, `FIRST/LAST/NTH_VALUE`, `CUME_DIST`, `PERCENT_RANK`, plus most aggregates usable with `OVER()`; JSON aggregates as window functions from 8.0.14.
- **LATERAL derived tables (8.0.14):** correlated derived tables in `FROM`.
- **INTERSECT and EXCEPT (8.0.31):** with `ALL`/`DISTINCT`; `INTERSECT` binds tighter than `UNION`/`EXCEPT`. No `MINUS` alias. `INTERSECT ALL`/`EXCEPT ALL` supported; note the `EXCEPT` NULL-handling subtlety Percona flags.
- **VALUES table constructor and TABLE statement (8.0.19):** `VALUES ROW(...),ROW(...)`; `TABLE t` as shorthand for `SELECT * FROM t`; usable in set operations.
- **CHECK constraints enforced (8.0.16):** previously parsed and ignored; the 8.0.16 Release Notes state MySQL "now implements the core features of table and column CHECK constraints, for all storage engines," with `ENFORCED`/`NOT ENFORCED`.
- **Functional/expression indexes (8.0.13):** `CREATE INDEX ... ((expr))`, implemented as hidden generated columns; enables indexing JSON extraction, etc.
- **Generated columns:** VIRTUAL and STORED (from 5.7) refined; INSTANT drop of VIRTUAL columns; functional indexes build on them.
- **JSON:** `JSON_TABLE` (8.0.4) relationalizes JSON; partial in-place updates of `JSON_SET/REPLACE/REMOVE` with compact binary binlog logging; `JSON_VALUE` (8.0.21) with typed extraction and `ON ERROR/ON EMPTY`; JSON Schema validation `JSON_SCHEMA_VALID`/`JSON_SCHEMA_VALIDATION_REPORT` (8.0.17) usable in CHECK constraints; **multi-valued indexes on JSON arrays (8.0.17)** via `CAST(... AS ... ARRAY)`; `JSON_ARRAYAGG`/`JSON_OBJECTAGG` aggregates; `->` and `->>` operators. (Contrast: MySQL stores JSON in a native binary format enabling partial update and path indexing—MariaDB does not.)
- **Expressions as DEFAULT (8.0.13):** e.g., `DEFAULT (uuid_to_bin(uuid()))`, `DEFAULT (CURRENT_DATE + INTERVAL 1 YEAR)`.
- **Locking reads:** `FOR UPDATE`/`FOR SHARE` (the latter replacing `LOCK IN SHARE MODE`) with `SKIP LOCKED` and `NOWAIT` (8.0.1)—directly analogous to Postgres semantics, valuable for queue tables.
- **Roles / RBAC (8.0.0):** `CREATE ROLE`, `GRANT role TO user`, `SET ROLE`, `mandatory_roles`, `activate_all_roles_on_login`, default roles; multiple simultaneous active roles (MariaDB permits only one).
- **Dynamic privileges (8.0.0):** granular admin privileges (`BACKUP_ADMIN`, `SYSTEM_VARIABLES_ADMIN`, `REPLICATION_APPLIER`, `CLONE_ADMIN`, etc.) replacing the blunt `SUPER` (now deprecated); `SYSTEM_USER` account category.
- **Partial revokes (8.0.16):** `partial_revokes` lets you grant a global privilege but revoke it on specific schemas—closer to least-privilege modelling.
- **GROUPING() and GROUP BY changes:** `GROUPING()` distinguishes NULLs from ROLLUP super-aggregates; **implicit GROUP BY sorting removed in 8.0**, and the nonstandard `GROUP BY ... ASC/DESC` syntax removed in **8.0.13**—queries relying on GROUP BY producing sorted output must add explicit `ORDER BY`. `ONLY_FULL_GROUP_BY` is default (since 5.7.5).

### 5. Replication and high availability

- **Terminology:** master→source, slave→replica across variables, statements, and channels. In 8.4 the legacy SQL (`START SLAVE`, `SHOW SLAVE STATUS`, `SHOW MASTER STATUS`, `CHANGE MASTER TO`, etc.) is **removed and errors**; use `START REPLICA`, `SHOW REPLICA STATUS`, `SHOW BINARY LOG STATUS`, `CHANGE REPLICATION SOURCE TO`. `terminology_use_previous` provides a transitional shim for some outputs. `slave_*` variables renamed to `replica_*` (old names removed in 8.4).
- **Group Replication:** introduced 5.7.17, matured in 8.0—a Paxos-based (single- or multi-primary) synchronous-certification replication plugin with automatic membership, failover, and flow control.
- **InnoDB Cluster / MySQL Shell AdminAPI / MySQL Router:** the packaged HA stack—Shell's AdminAPI wraps Group Replication; Router provides transparent routing/failover via bootstrap; the clone plugin provisions new members.
- **InnoDB ReplicaSet (8.0.19):** AdminAPI-managed classic async replication for non-HA use cases.
- **Clone plugin (8.0.17):** physical InnoDB snapshot (local or remote) that also transfers binlog/GTID coordinates—fast replica/member provisioning without XtraBackup; integrated with Group Replication distributed recovery (`group_replication_clone_threshold`). Clones only InnoDB data (not MyISAM/CSV); interferes with concurrent DDL.
- **Parallel replication:** writeset-based dependency tracking for higher applier parallelism even within a single database; `binlog_transaction_dependency_tracking` (deprecated 8.2, default WRITESET in 8.3, removed in 8.4 with WRITESET behaviour made internal).
- **Privilege checks on the applier:** `PRIVILEGE_CHECKS_USER` runs the applier under a restricted account.
- **Asynchronous Replication Connection Failover (8.0.22+):** a replica automatically fails its source connection over to alternative sources from a configured list; extended with source-list weighting/managed groups.
- **Other:** multi-source replication (from 5.7) with per-channel filters; partition information in the binary log (8.0.16); compressed binary log transactions (`binlog_transaction_compression`, 8.0.20); tagged GTIDs (`UUID:TAG:NUMBER`, 8.3).
- **8.4 Group Replication default changes:** `group_replication_consistency` default `EVENTUAL`→`BEFORE_ON_PRIMARY_FAILOVER`; `group_replication_exit_state_action` default `READ_ONLY`→`OFFLINE_MODE`; `binlog_format` default now `ROW`; cross-version 8.4.x membership and in-place downgrade within the 8.4 series supported; `group_replication_allow_local_lower_version_join` deprecated; preemptive certification GC added. Recovery metadata is shared compressed (no view-change binlog event) when all members are ≥8.3.

### 6. Security

Beyond roles, dynamic privileges, partial revokes, and `caching_sha2_password`:
- **Dual passwords (8.0.14):** primary + secondary password per account for zero-downtime credential rotation across fleets.
- **Password management:** reuse policy (`password_history`, `password_reuse_interval`, from 8.0.3/8.0.13), current-password verification (`PASSWORD REQUIRE CURRENT`, 8.0.13), failed-login tracking and temporary account locking (`FAILED_LOGIN_ATTEMPTS`, `PASSWORD_LOCK_TIME`, 8.0.19), random password generation (8.0.18, default 20 chars).
- **Multifactor authentication (8.0.27):** up to three factors; FIDO (8.0.27) later superseded by WebAuthn (`authentication_fido` removed in 8.4).
- **TLS/crypto:** TLS 1.3 support; `ALTER INSTANCE RELOAD TLS` for online cert rotation; `tls-certificates-enforced-validation` (8.1); OpenSSL 3.x; weak ciphers and `--ssl`/`have_ssl`/`have_openssl` removed in 8.4; FIPS support. 9.7 added PBKDF2-SHA-512 storage for `caching_sha2_password`.
- **Enterprise (commercial):** Data Masking & De-Identification, Audit, Firewall, TDE keyring components (legacy keyring *file* plugins removed in 8.4 in favour of keyring components).

### 7. Observability and ops

- **Component-based error logging (8.0.4+):** pipeline of log source/filter/sink components (`log_filter_dragnet` rule language, JSON sink, syseventlog sink); every message carries a subsystem tag (`[Server]`, `[InnoDB]`, `[Repl]`) and an error code (`MY-nnnnnn`). Loading via `INSTALL COMPONENT` no longer required for basic use.
- **Performance Schema & sys schema:** expanded instrumentation (error stats, variable/status tables, data-locking tables, clone progress); `sys` schema shipped by default; I_S now backed by the data dictionary (fast, no file scans). 9.7 moved several previously-Enterprise replication observability components (Replication Applier Metrics, etc.) into Community.
- **SHOW/config:** `SHOW MASTER/SLAVE STATUS` renamed; `FLUSH HOSTS` removed in 8.4 (use `TRUNCATE performance_schema.host_cache`); numerous default changes (utf8mb4, `binlog_format=ROW` in 8.4, `innodb_purge_threads` auto-scaled in 8.4, InnoDB buffer/IO-capacity/log-buffer defaults adjusted in 8.4).

### 8. Migration and upgrade gotchas (5.7 → 8.0 → 8.4 → 9.x)

**Upgrade mechanics:**
- **Stepwise only:** 5.7→8.0 first (cannot jump straight to 8.4). Then 8.0→8.4→9.x. Within an LTS series, in-place up/downgrade is supported; Innovation downgrades need dump/reload.
- **`mysql_upgrade` binary:** as of 8.0.16 the server performs upgrade tasks itself at first startup ("the MySQL server performs the upgrade tasks previously handled by mysql_upgrade"); the `mysql_upgrade` client is deprecated (8.0.16) and **removed in 8.4**.
- Use MySQL Shell's **Upgrade Checker** (`util.checkForServerUpgrade()`) and Percona's `pt-upgrade` before upgrading.

**Behaviour/compatibility breakers:**
- **Authentication:** migrate accounts off `mysql_native_password` before 8.4/9.0; audit connectors (Connector/J 8.0+, PyMySQL, mysql2 ≥2.3, PHP ≥7.4) and middleware (ProxySQL ≥2.5.4, with TLS/RSA for the handshake).
- **Reserved words added in 8.0** that can break identifiers: `RANK`, `ROW`, `ROWS`, `GROUPS`, `GROUPING`, `LEAD`, `LAG`, `NTILE`, `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE`, `CUME_DIST`, `DENSE_RANK`, `PERCENT_RANK`, `ROW_NUMBER`, `OVER`, `WINDOW` (reserved from 8.0.2), `RECURSIVE`, `SYSTEM`, `EMPTY`, `EXCEPT`, `JSON_TABLE`, `OF`, `PERSIST`, `PERSIST_ONLY`. Backtick-quote or rename—also a **replication hazard** (per the manual, "a table column named rank on a MySQL 5.7 source that is replicating to a MySQL 8.0 replica could cause a problem because RANK is a reserved word beginning in MySQL 8.0").
- **sql_mode:** `ONLY_FULL_GROUP_BY`, `STRICT_TRANS_TABLES`, `NO_ZERO_DATE`, `NO_ZERO_IN_DATE`, `ERROR_FOR_DIVISION_BY_ZERO` in the default; `NO_AUTO_CREATE_USER` removed (config files containing it prevent startup).
- **GROUP BY:** implicit sorting gone; `GROUP BY ... ASC/DESC` removed (8.0.13)—add explicit `ORDER BY`.
- **Charset:** default utf8mb4/utf8mb4_0900_ai_ci changes sort order and comparison; `utf8mb3` deprecated. Column/connection/collation mismatches can cause illegal-mix-of-collations errors and index-usage changes.
- **Removed in 8.0:** query cache; `PASSWORD()` function; `PROCEDURE ANALYSE`; old temporal-column handling (`avoid_temporal_upgrade`/`show_old_temporals` removed in 8.4).
- **Removed in 8.3/8.4:** InnoDB memcached plugin; `--slave-rows-search-algorithms` and many slave_* options; `binlog_transaction_dependency_tracking`, `--old`/`--new`, `--language`, `innodb_log_file_size`/`innodb_log_files_in_group` (use `innodb_redo_log_capacity`). Config files with removed variables **prevent server startup**.
- **8.4 FK strictness:** `restrict_fk_on_non_standard_key` (default ON) requires a unique key on referenced columns; `AUTO_INCREMENT` on FLOAT/DOUBLE removed.
- **9.0 storage-engine removals:** ARCHIVE, BLACKHOLE, FEDERATED, MEMORY, MERGE removed—rework any temp-table strategies relying on MEMORY.
- **Replication direction:** 8.0→9.0 works; 9.0→8.0 does not. Never replicate newer→older across majors.

**Physical-backup caveat:** because of data-dictionary/redo/undo format changes, XtraBackup/MEB are version-locked (XtraBackup 8.0 only backs up 8.0; 8.4 only 8.4).

### 9. Forks: MariaDB and Percona Server for MySQL

**MariaDB** forked around 5.5 and is now a distinct database, not a drop-in replacement. Version numbering diverged (5.5→10.0→…→11.x/12.x). Divergences that matter for a migration consultant:
- **Optimizer/executor:** entirely separate lineage; different plans, hints, and statistics; no hash-join/iterator-executor parity; MariaDB has its own histogram and optimizer defaults.
- **JSON:** MariaDB `JSON` is an **alias for LONGTEXT** with a `JSON_VALID()` CHECK, parsed at query time; no `->`/`->>` operators; no multi-valued JSON indexes; different NULL/error semantics; strings compared as strings, not JSON values. Cross-replicating JSON columns requires storing as TEXT/statement-based replication; `mysql_json` plugin or `mariadb-upgrade` converts on import.
- **Unique MariaDB features:** sequences (`CREATE SEQUENCE`), **system-versioned (temporal) tables**, application-time periods, bitemporal tables, invisible columns, `INET4`/`INET6`/`UUID` types, DEFAULT partition for LIST/LIST COLUMNS.
- **Storage engines:** Aria (crash-safe MyISAM replacement, default temp engine), ColumnStore, Spider, MyRocks, S3, CONNECT, plus InnoDB; **Galera is built in** (synchronous multi-master).
- **HA/replication:** Galera instead of Group Replication/InnoDB Cluster; different GTID implementation (MariaDB GTIDs are incompatible with MySQL GTIDs). MariaDB 11.4+/11.8 can replicate *from* a MySQL 8.0 source only with adjustments (`binlog-row-value-options=''`, `binlog_transaction_compression=0`, `binlog_format=ROW`, GTID disabled on the connection).
- **RBAC:** MariaDB never allows authentication via roles and permits only one active role at a time; MySQL allows multiple.
- **Auth compatibility:** MariaDB added `caching_sha2_password` as a compatibility plugin in recent releases.
- **VECTOR:** MySQL added it in 9.0 (July 2024); MariaDB added a VECTOR type/relational-vector capability in 11.7 (Feb 2025)—independent implementations (both largely HNSW-based).
- **Reserved words differ:** MySQL-only reserved words (`groups`, `stored`, `empty`, `last_value`, `lead`, `rank`, `system`) can break MariaDB→MySQL moves; sql_mode values like MariaDB's `NO_AUTO_CREATE_USER` and collations like `utf8mb4_unicode_nopad_ci`/`utf8mb3_general_ci` fail on MySQL import.
- **Cross-replication between MySQL 8.0+ and MariaDB is not officially supported.** Treat them as separate products for any non-trivial migration.

**Percona Server for MySQL** is a near-drop-in enhanced build of Oracle MySQL that tracks upstream closely (including all bug fixes) and adds:
- Enhanced instrumentation and diagnostics, additional `INFORMATION_SCHEMA`/`performance_schema` visibility, backup locks (lightweight alternative to `FLUSH TABLES WITH READ LOCK`), audit and threadpool features.
- Ships **XtraDB** (enhanced InnoDB) and **MyRocks** (RocksDB LSM engine, from Facebook—write-optimized, high compression). **TokuDB** (fractal-tree engine) was long included but is deprecated/removed.
- **Percona XtraBackup**—the de facto open-source hot physical backup tool for MySQL/Percona/MariaDB (MariaDB forked it as `mariabackup`); version-locked to major series (8.0 backs up 8.0; 8.4 backs up 8.4). Percona XtraBackup 8.0 reached EOL June 2026; Percona Server for MySQL 8.0 has reached EOL.
- **Percona XtraDB Cluster (PXC)**—Galera-based synchronous multi-master, the Percona analogue to MySQL Group Replication/InnoDB Cluster.
- Percona Toolkit (`pt-online-schema-change`, `pt-upgrade`, etc.) and Percona Monitoring and Management (PMM) round out the ecosystem.

Percona's role: a vendor-neutral open-source alternative that stays compatible with upstream MySQL while adding operational tooling—far lower migration risk than MariaDB.

### 10. The 9.x Innovation line and current state (mid-2026)

- **9.0 (July 2024):** `VECTOR` type (up to 16,383 float32 entries, default 2048), `STRING_TO_VECTOR`/`VECTOR_TO_STRING`/`VECTOR_DIM`/`DISTANCE`/`VECTOR_DISTANCE` functions; **JavaScript stored programs** via the Multilingual Engine (MLE) component (Enterprise/HeatWave only); improved FK standards compliance. First release pulled for a critical bug. Note: the `DISTANCE` function and automatic vector indexing (HNSW) are gated to HeatWave/Enterprise—Community gets the type and conversion functions.
- **9.1–9.3:** MLE enhancements (access to UDFs/procedures from JS, JS transaction API, `CREATE LIBRARY` reusable JS libraries in 9.2); `VECTOR` maturation; row-version limit raised to 255 (9.1); MEMORY-engine removals continue; from 9.3 no Innovation-to-Innovation downgrades even within a series.
- **9.4 (July 2025):** **JSON Duality Views** (`CREATE JSON DUALITY VIEW`)—a bidirectional relational↔JSON mapping with per-level write grants and ETAG-based optimistic concurrency; DML through duality views initially Enterprise-only.
- **9.5–9.6:** further MLE/telemetry; `activate_mandatory_roles`; Version Tokens plugin removed (9.3); OpenSSL updates; side-by-side installation of Innovation and LTS builds.
- **9.7 (April 2026), the second LTS:** JSON Duality View **DML now in Community Edition** (with auto-increment support); PBKDF2-SHA-512 for `caching_sha2_password`; several previously-Enterprise replication observability components moved to Community; cgroup/cpuset-aware CPU sizing. Notably, **native `VECTOR` indexing/search in Community is still not GA as of 9.7**—it remains on the roadmap.

## Recommendations

1. **If you are still on 5.7, treat this as a two-stage project, now urgent.** MySQL 5.7 entered Oracle Sustaining Support on 25 October 2023, and 8.0 is EOL (April 2026). Go 5.7→8.0 (latest 8.0.4x) first, validate, then 8.0→8.4 LTS. Do not attempt to jump straight to 8.4 or 9.x. Target **8.4 LTS** as the destination for production stability (Extended Support to 30 April 2032); reserve 9.x Innovation/9.7 LTS for teams that need `VECTOR`, JS stored programs, or JSON Duality Views and can absorb faster upgrade cadence.
2. **Run the compatibility gauntlet before touching production:** MySQL Shell `util.checkForServerUpgrade()`, `pt-upgrade` for query-behaviour regressions, and a full schema audit for (a) accounts on `mysql_native_password`, (b) identifiers colliding with new reserved words, (c) `sql_mode` assumptions (`ONLY_FULL_GROUP_BY`, zero-dates), (d) reliance on implicit GROUP BY ordering, (e) config files carrying removed variables (these block startup), and (f) charset/collation mismatches.
3. **Sequence the authentication migration explicitly.** Before 8.4/9.0: `ALTER USER ... IDENTIFIED WITH caching_sha2_password`, upgrade every connector and any ProxySQL layer (≥2.5.4, TLS or RSA in place), and use **dual passwords** for zero-downtime rotation across a fleet.
4. **Re-plan physical backups and redo/undo tuning.** Adopt `innodb_redo_log_capacity` (size to ~1 hour of peak redo generation, measured via `Innodb_redo_log_current_lsn`) and validate XtraBackup/MEB versions match the target major series before cutover.
5. **Exploit the new SQL surface to retire application workarounds:** replace emulated ranking/pagination with window functions, hierarchical queries with recursive CTEs, application-side JSON shredding with `JSON_TABLE`/multi-valued indexes, and queue polling with `FOR UPDATE SKIP LOCKED`. Use invisible indexes to de-risk index changes.
6. **For fork decisions:** if the goal is an enhanced-but-compatible MySQL, choose **Percona Server for MySQL** (low migration risk, XtraBackup/PXC/PMM tooling). Choose **MariaDB** only when its unique features (system-versioned tables, sequences, Galera-by-default, ColumnStore) are specifically wanted—and budget for real dialect divergence (JSON, GTID, optimizer, reserved words). Never assume MySQL 8.0+↔MariaDB interchangeability or supported cross-replication.

**Thresholds that change the plan:** if any account cannot be moved off `mysql_native_password` (legacy connector that cannot be upgraded), stay on 8.4 with the plugin explicitly re-enabled rather than moving to 9.x. If you depend on the MEMORY/ARCHIVE/FEDERATED engines, do not move to 9.x until re-architected. If you require true transactional DDL or a mature cost-based hypergraph optimizer in Community, MySQL is not yet there—weigh that against the PostgreSQL baseline you already know.

## Caveats

- **Introduction versions:** version numbers herein are drawn from Oracle's Reference Manual, release notes, and Server Team blog; a handful (e.g., `innodb_dedicated_server` = 8.0.3, resource groups = 8.0.3, `SET PERSIST`/roles = 8.0.0, `JSON_VALUE` = 8.0.21, `EXPLAIN FORMAT=TREE` = 8.0.16, `EXPLAIN ... INTO @var` = 8.0.32) are well-attested but should be spot-checked against the exact release note if a precise integer is contractually important.
- **Edition gating:** JavaScript stored programs, DML on JSON Duality Views (pre-9.7), several vector/`DISTANCE` capabilities, HeatWave, and various security components are **Enterprise/HeatWave-only** or were until a specific release; verify against your edition.
- **Hypergraph optimizer** is experimental in Community Server and production only in the HeatWave secondary engine—do not plan Community workloads around it.
- **Forecast/roadmap items** (native Community `VECTOR` indexing beyond 9.7, future LTS after 9.7) are stated by Oracle as intentions, not commitments; treat as forward-looking.
- Some corroborating detail came from third-party engineering blogs (Percona, Mydbops, MariaDB docs, cloud vendors); where these conflicted with Oracle primary sources, the primary source was preferred.