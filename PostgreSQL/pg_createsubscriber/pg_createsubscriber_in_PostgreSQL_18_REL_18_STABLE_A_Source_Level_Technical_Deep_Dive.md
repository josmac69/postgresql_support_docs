# pg_createsubscriber in PostgreSQL 18 (REL_18_STABLE): A Source-Level Technical Deep Dive

## TL;DR
- `pg_createsubscriber` converts an existing physical streaming standby into a logical replication subscriber **without copying table data** — it records a consistent LSN from freshly created logical slots on the primary, recovers the standby exactly to that LSN, promotes it, then advances each subscription's replication origin to that LSN so logical apply resumes precisely where physical replay stopped. Per the official docs, "pg_createsubscriber targets large database systems because in logical replication setup, most of the time is spent doing the initial data copy … For smaller databases, it is recommended to set up logical replication with initial data synchronization" — i.e. it is dramatically faster than `CREATE SUBSCRIPTION … WITH (copy_data=true)` for large clusters.
- PostgreSQL 18 (REL_18_STABLE) adds three options over PG17: `--all` (one subscription per user database), `--enable-two-phase`/`-T` (2PC), and `--clean=publications`; it also switches the subscriber-side GUC checked from `max_replication_slots` to the new `max_active_replication_origins`, writes recovery params to a separate `pg_createsubscriber.conf` (included from `postgresql.auto.conf`) that is renamed `.disabled` afterward, and resets recovery parameters after conversion.
- The operation is destructive and one-shot: once the standby is promoted, a failure means the data directory cannot be reused as a physical replica and must be rebuilt. Sequences, DDL, roles/tablespaces/globals, and large objects are NOT synchronized; the tool changes the subscriber's system identifier via `pg_resetwal`.

## Key Findings

**Purpose & algorithm.** `pg_createsubscriber` (source: `src/bin/pg_createsubscriber/pg_createsubscriber.c`, built under the `pg_basebackup` build directory) creates a new logical replica from a physical standby. Instead of doing a logical initial `COPY` per table, it leverages the fact that a physical replica is already a byte-for-byte clone. It creates a publication (`FOR ALL TABLES`) and a logical replication slot per target database on the primary, uses the **last** slot's LSN as `recovery_target_lsn`, recovers/promotes the standby to that exact point, then creates disabled subscriptions with `copy_data=false, create_slot=false, enabled=false` and calls `pg_replication_origin_advance()` to position each origin at the consistent LSN before enabling. This guarantees no lost or duplicate transactions.

**Why it's fast.** In a normal logical setup most of the time (and WAL retention) is spent in tablesync `COPY`, and the changes accumulated during that copy must then be caught up. `pg_createsubscriber` skips the copy entirely — only the incremental catch-up from the consistent LSN remains.

**PG17 → PG18 changes.** The three new options (`--all`, `--clean`, `--enable-two-phase`) were all authored by Shubham Khanna (Fujitsu), per the PG18 release notes. Commit provenance (confirmed via pgPedia): `--enable-two-phase` = e117cfb2 (the `--two-phase` spelling was added and immediately renamed to `--enable-two-phase` in commit 6d12d5a4, with `-T` as synonym); `--clean` = e5aeed4b (initially `-R/--remove`, renamed in 60dda7bb); `--all` = fb2ea12f. Per Postgres Professional's CommitFest 2025-03 review, `--all` "will create a subscription for every database on the server, except for template databases and those with connections disabled." The subscriber-GUC change reflects PG18's new `max_active_replication_origins`: the release notes state it "was previously controlled by `max_replication_slots`, but this new setting allows a higher origin count in cases where fewer slots are required" (default 10, set only at server start).

## Details

### 1. What pg_createsubscriber does — the 11-step algorithm

The documented "How It Works" sequence (matching the `main()` flow in the source):

1. Start the target (standby) server with restricted command-line options. If it is already running, error out.
2. Run pre-flight checks on both publisher (`check_publisher()`) and subscriber (`check_subscriber()`).
3. `setup_publisher()`: create a publication and logical replication slot per database on the source. Publication/slot/subscription names default to the pattern `pg_createsubscriber_%u_%x` (database OID, random int). The **last** created slot's LSN becomes `consistent_lsn`.
4. `setup_recovery()`: write recovery parameters (into `pg_createsubscriber.conf`, included from `postgresql.auto.conf`) and restart the target so it recovers up to `recovery_target_lsn = consistent_lsn` with `recovery_target_action = promote`.
5. `setup_subscriber()`: create subscriptions (disabled, no copy, no slot).
6. Drop publications on the target that were physically replicated in (they have no use on the subscriber).
7. `set_replication_progress()`: `pg_replication_origin_advance()` each subscription's origin to the consistent LSN.
8. `enable_subscription()`: enable each subscription.
9. Drop `primary_slot_name` on the source if the standby used one.
10. Drop failover replication slots on the target (they can no longer be synchronized).
11. `modify_subscriber_sysid()`: run `pg_resetwal` to change the system identifier (server stopped first).

### 2. Deep source-code analysis (REL_18_STABLE)

**Data structures.** Three structs (defined near the top of the file, ~lines 77–100):
- `struct CreateSubscriberOptions` — parsed CLI options: `subscriber_dir`, `pub_conninfo_str`, `socket_dir`, `sub_port` (default `DEFAULT_SUB_PORT` = `"50432"`), `sub_username`, `two_phase`, `database_names`, `pub_names`, `sub_names`, `replslot_names`, `recovery_timeout`, `all_dbs`, and an object-cleanup bitmask.
- `struct LogicalRepInfo` — per-database: `dbname`, `pubconninfo`, `subconninfo`, `pubname`, `subname`, `replslotname`, and cleanup flags `made_publication` and `made_replslot`.
- `struct LogicalRepInfos` — array wrapper: `dbinfo`, `two_phase` (bool), and `objecttypes_to_clean` (uint32, tested against `OBJECTTYPE_PUBLICATIONS` = `0x0001`).

Key file-scope statics: `dry_run`, `success`, `recovery_ended`, `standby_running`, `recovery_params_set`, `primary_slot_name`, `num_dbs`, `pg_ctl_path`, `pg_resetwal_path`. Macros: `PG_AUTOCONF_FILENAME "postgresql.auto.conf"`, `INCLUDED_CONF_FILE "pg_createsubscriber.conf"`, `INCLUDED_CONF_FILE_DISABLED` (adds `.disabled`), `SERVER_LOG_FILE_NAME`, `INTERNAL_LOG_FILE_NAME`, `WAIT_INTERVAL 1`, `NUM_ATTEMPTS 60`.

**`check_publisher()`** (definition ~line 1015). Connects with `dbinfo[0].pubconninfo`. First rejects a source in recovery (`server_is_in_recovery()` — a cascading primary can't create objects). It issues one query:
```sql
SELECT pg_catalog.current_setting('wal_level'),
       pg_catalog.current_setting('max_replication_slots'),
       (SELECT count(*) FROM pg_catalog.pg_replication_slots),
       pg_catalog.current_setting('max_wal_senders'),
       (SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE backend_type = 'walsender'),
       pg_catalog.current_setting('max_prepared_transactions'),
       pg_catalog.current_setting('max_slot_wal_keep_size');
```
Validation logic:
- `wal_level` must not be `minimal` — error `publisher requires "wal_level" >= "replica"` if it is. (Note: the actual GUC value needed for logical decoding is `logical`; `minimal` fails here, and logical-slot creation later fails unless `logical`.)
- `max_replication_slots - cur_repslots < num_dbs` → error, hint to raise to `cur_repslots + num_dbs`.
- `max_wal_senders - cur_walsenders < num_dbs` → error, hint to raise to `cur_walsenders + num_dbs`.
- If `max_prepared_transactions != 0` and `!dbinfos.two_phase` → warning that `two_phase` won't be enabled; hint suggests `--enable-two-phase`.
- In `--dry-run`, if `max_slot_wal_keep_size != -1` → warning that required WAL could be removed; hint to set it to `-1`.

**`check_subscriber()`** (definition ~line 1154). Connects with `dbinfo[0].subconninfo`. Rejects if the target is **not** in recovery (`target server must be a standby`). Query:
```sql
SELECT setting FROM pg_catalog.pg_settings WHERE name IN (
  'max_logical_replication_workers',
  'max_active_replication_origins',
  'max_worker_processes',
  'primary_slot_name') ORDER BY name;
```
Validation:
- `max_active_replication_origins < num_dbs` → error. **(PG18 change: PG17 checked `max_replication_slots` here; PG18 uses the new `max_active_replication_origins` GUC, added by Euler Taveira precisely to decouple origin count from slot count.)**
- `max_logical_replication_workers < num_dbs` → error.
- `max_worker_processes < num_dbs + 1` → error.
- If `primary_slot_name` is non-empty, it is stored in the file-scope `primary_slot_name` for later cleanup.
Privilege prerequisites (documented, enforced at SQL exec time): the target DB user needs `pg_create_subscription` + `CREATE` on the DB, and privileges to run `pg_replication_origin_advance()` (superuser or appropriate membership). `connect_database()` also runs `ALWAYS_SECURE_SEARCH_PATH_SQL` to clear `search_path`.

**`setup_publisher()` / `create_logical_replication_slot()`** (~line 1546). The slot is created with:
```sql
SELECT lsn FROM pg_catalog.pg_create_logical_replication_slot(<slot>, 'pgoutput', false, <two_phase>, false);
```
Arguments: plugin `pgoutput`, `temporary=false`, `two_phase` = `dbinfos.two_phase ? true : false`, `failover=false`. Sets `dbinfo->made_replslot = true` for cleanup. The returned LSN of the **last** slot is used as the consistent point. `create_publication()` (~line 1794) runs `CREATE PUBLICATION %s FOR ALL TABLES`, first checking the publication doesn't already exist, and sets `made_publication = true`.

**`setup_recovery()`** (~line 1320). Uses `GenerateRecoveryConfig()` then appends:
- `recovery_target = ''`
- `recovery_target_timeline = 'latest'`
- `recovery_target_inclusive = false` — critical: the consistent LSN is *also* the replication start point, so the transaction committed exactly at that LSN must NOT be replayed physically (it will arrive via logical apply); `inclusive=true` would double-apply it.
- `recovery_target_action = promote`
- `recovery_target_name = ''`
- `recovery_target_lsn = '<consistent_lsn>'` (in dry-run, uses `InvalidXLogRecPtr` and a `# dry run mode` marker; no write).
Content is written to `pg_createsubscriber.conf` (included via `include_if_exists` from `postgresql.auto.conf`); sets `recovery_params_set = true`. In PG18 the params are reset afterward (via `ALTER SYSTEM RESET` of the eight `recovery_target*` params / the included file being renamed `.disabled`), fixing an edge case where a checkpoint with no WAL to apply made the server think the target was never reached.

**`wait_for_end_recovery()`** (~line 1748). Polls `pg_is_in_recovery()` every `WAIT_INTERVAL` (1s). PG18 uses `NUM_ATTEMPTS 60` for the "is the slot active / is walreceiver up" retry window. Historically `NUM_CONN_ATTEMPTS 10` governed bailing out when the target disconnected from the primary, but a race between walreceiver shutdown and `pg_is_in_recovery()` returning false caused spurious failures (commit 04c8634c), so the end of recovery is now controlled only by `--recovery-timeout` (0 = wait forever, the default). On timeout the tool aborts; because the server may already be promoted, recovery is unrecoverable.

**`setup_subscriber()` / `create_subscription()`.** Subscriptions are created with `connect=false`-equivalent semantics: `copy_data=false, create_slot=false, enabled=false`, reusing the pre-created slot. Before that, `check_and_drop_existing_subscriptions()` (~line 1304) runs:
```sql
SELECT s.subname FROM pg_catalog.pg_subscription s
INNER JOIN pg_catalog.pg_database d ON (s.subdbid = d.oid)
WHERE d.datname = <dbname>;
```
and drops each via `drop_existing_subscription()`. These pre-existing subscriptions (inherited physically from the former primary) MUST be dropped, otherwise the converted node would connect to unintended publishers.

**`set_replication_progress()`.** Obtains the origin name for each subscription (derived from subscription OID, e.g. `pg_<oid>`) and calls `pg_replication_origin_advance(<origin>, <consistent_lsn>)`. This is the linchpin that aligns the logical apply start with the physical stop point.

**`enable_subscription()`** then runs `ALTER SUBSCRIPTION ... ENABLE`.

**`drop_primary_replication_slot()` / `drop_failover_replication_slots()`.** The physical `primary_slot_name` on the source is dropped after setup (documented warning). Failover slots on the target are dropped because a promoted node can no longer sync them from a primary.

**`modify_subscriber_sysid()`.** Runs `pg_resetwal` on the stopped target to change the system identifier. Rationale: prevent the converted node from ever consuming WAL belonging to the source's timeline/identity (they are now independent clusters); it also breaks any downstream physical standby of the target (which must be rebuilt).

**`cleanup_objects_atexit()`** (~line 201). Registered via `atexit`. If `recovery_params_set`, it renames `pg_createsubscriber.conf` → `.disabled` (durable_rename). If `!success`: if `recovery_ended` (server already promoted), it warns the target can't be reused as a physical replica. For each db with `made_publication`/`made_replslot`, it reconnects to the primary and drops the publication/slot; if the connection fails it warns that objects were left behind (orphaned publications/slots on the primary) with hints to drop them. Finally, if `standby_running`, it stops the target. A cleanup-flag bug (double-clearing `made_replslot`/`made_publication`) was fixed on the hackers list via an `in_cleanup` parameter.

**`start_standby_server()` (transient start).** Signature: `start_standby_server(const struct CreateSubscriberOptions *opt, bool restricted_access, bool restrict_logical_worker)`. It builds a `pg_ctl start -o` string:
- `-p <port>` (default 50432, overridable with `--subscriber-port`).
- When `restricted_access` is true: `-c listen_addresses='' -c unix_socket_permissions=0700 -c unix_socket_directories='<socketdir>'` — no TCP listeners at all (empty string, *not* `localhost`), socket restricted to the owning user in a private dir. This is why "connections to the target server should fail" during transformation.
- When `restrict_logical_worker` is true: `-c max_logical_replication_workers=0` — prevents subscription/apply workers from firing during the transient start (so inherited subscriptions can't connect to other publishers before they are dropped).
- `-c config_file=<file>` if `--config-file` was given.
In `main()`, the first start uses `(restricted_access=true, restrict_logical_worker=false)` (because `check_subscriber` still needs a non-zero `max_logical_replication_workers`); the start that performs recovery/promotion uses `(true, true)`. There is no evidence that `sync_replication_slots=off` is set in this function.

**`generate_object_name()`.** Generates the `pg_createsubscriber_%u_%x` names using the database OID (`%u`) and a `pg_prng`-derived random int (`%x`), minimizing collision risk with any user-chosen name.

**`--dry-run` (`-n`).** Runs all checks and logs every action ("dry-run: would create ...") but performs no writes: no slot/publication/subscription creation, no recovery-config write, no `pg_resetwal`, no origin advance. It additionally validates `max_slot_wal_keep_size` on the publisher.

### 3. Operations on publisher vs subscriber (timeline)

| Order | On PUBLISHER (source/primary) | On SUBSCRIBER-to-be (target/standby) |
|---|---|---|
| 0 | — | Tool starts server: `pg_ctl -o "-p 50432 -c listen_addresses='' -c unix_socket_permissions=0700 -c unix_socket_directories=..."` |
| 1 | `check_publisher()` reads GUCs; must not be in recovery | `check_subscriber()` reads GUCs; must be in recovery |
| 2 | `CREATE PUBLICATION ... FOR ALL TABLES` (per db) | — |
| 3 | `pg_create_logical_replication_slot('pgoutput', false, <2pc>, false)` (per db); last LSN = consistent_lsn | — |
| 4 | — | Write `pg_createsubscriber.conf` (recovery_target_lsn, inclusive=false, action=promote); restart; recover to LSN; **promote** |
| 5 | — | `CREATE SUBSCRIPTION ... WITH (connect=false → copy_data=false, create_slot=false, enabled=false)` |
| 6 | — | Drop physically-replicated publications; drop pre-existing subscriptions |
| 7 | — | `pg_replication_origin_advance(origin, consistent_lsn)` per sub |
| 8 | — | `ALTER SUBSCRIPTION ... ENABLE` |
| 9 | `pg_drop_replication_slot(primary_slot_name)` | — |
| 10 | — | Drop failover slots |
| 11 | — | Stop server; `pg_resetwal` to change system identifier; rename recovery conf `.disabled` |

Ordering matters: the origin MUST be advanced (step 7) before the subscription is enabled (step 8), or the apply worker would start from an undefined position; publications on the primary must be created before slots (a slot with no publication is useless); the sysid change (step 11) must be last (server stopped).

### 4. Prerequisites checklist

| Requirement | Side | Detail |
|---|---|---|
| Same major version | both | target `PG_VERSION` must equal tool's `PG_MAJORVERSION_NUM` |
| Same system identifier | both | target datadir must be a clone of source |
| `wal_level = logical` | publisher | (`minimal` rejected outright) |
| `max_replication_slots ≥ existing + num_dbs` | publisher | |
| `max_wal_senders ≥ existing + num_dbs` | publisher | |
| `max_slot_wal_keep_size = -1` | publisher | prevents premature WAL removal (warned in dry-run) |
| not in recovery | publisher | cascading primary rejected |
| `max_active_replication_origins ≥ num_dbs` | subscriber | **PG18 renamed GUC** (default 10) |
| `max_logical_replication_workers ≥ num_dbs` | subscriber | |
| `max_worker_processes ≥ num_dbs + 1` | subscriber | |
| `max_prepared_transactions > 0` | both | only if `--enable-two-phase` |
| is a physical standby, accepts local conns | subscriber | must be stopped before invocation |
| user has `pg_create_subscription`, CREATE, origin-advance | subscriber | |
| target NOT a running server, NOT accepting writes | subscriber | writes after promotion break the subscription |

Disk: the primary must retain WAL from the consistent LSN until the subscriber catches up; a lagging subscriber bloats the slot. Avoid synchronous-standby configuration (commits on the primary may wait during the run).

### 5. Usual issues, pitfalls & limitations

- **Sequences are NOT replicated.** After conversion the subscriber's sequences hold whatever value they had at promotion; serial/identity columns will collide on cutover. Workaround: dump sequence values from the publisher just before cutover (`pg_dump --sequence-data`, or generate `setval()` statements, often with a safety buffer) and apply on the subscriber. (Native logical sequence sync — `ALTER SUBSCRIPTION ... REFRESH SEQUENCES`, `CREATE PUBLICATION ... FOR ALL SEQUENCES` — is a PostgreSQL 19 feature, not available in PG18.)
- **DDL is not replicated.** Avoid schema changes during and after conversion; post-conversion DDL must be applied manually on both sides.
- **Only table data per database.** Roles, tablespaces, global objects, and other databases are not handled; large objects (`pg_largeobject`) are not replicated by logical replication.
- **Recovery never reaches target.** Because `recovery_target_lsn` = the last slot's creation LSN (which is ahead of current WAL), recovery waits for the primary to write a WAL record past that point. On an idle primary this can hang; heavy write load or long-running transactions delaying a consistent snapshot also stretch it. Mitigation: keep the primary lightly writing, set a sane `--recovery-timeout`. A committed fix addressed unpredictable wait time.
- **restore_command/archive interplay.** If the standby depends on archived WAL, missing segments can stall recovery.
- **`primary_slot_name` is dropped.** After conversion the source's physical slot for this standby is gone; any tooling depending on it must be updated.
- **Consistent LSN is from the LAST slot.** Slots are created sequentially; transactions committed between the first and last slot creation are handled correctly because all subscriptions start from the single last LSN, but this means the window scales with number of databases.
- **Invalidated logical slots on promotion / failover slots.** Synced/failover slots on the standby are dropped; they can't survive the identity change.
- **Mid-run failure states.** Before promotion: publications/slots on the primary are cleaned up (or warned about if the primary is unreachable — orphaned objects retain WAL). After promotion: the datadir is unusable as a physical replica; rebuild required.
- **`max_slot_wal_keep_size` bloat.** If the subscriber falls behind, the primary's slot retains WAL; with a non-`-1` cap the slot can be invalidated and replication breaks.
- **Two-phase.** Without `--enable-two-phase`, prepared transactions replicate only at `COMMIT PREPARED`; enabling later requires disabling the subscription, `ALTER SUBSCRIPTION ... SET (two_phase = true)`, re-enabling; `subtwophasestate` stays pending until tablesync completes.
- **Split-brain / logical divergence.** If both the old primary and the converted node keep accepting writes independently, they diverge; the converted node is a genuine independent primary now.
- **Security fix.** CVE-2026-6476 (per PostgreSQL's official advisory): "SQL injection in PostgreSQL pg_createsubscriber allows an attacker with `pg_create_subscription` rights to execute arbitrary SQL as a superuser … The PostgreSQL project thanks Yu Kunpeng for reporting this problem." CVSS v3.1 Base Score 7.2 (AV:N/AC:L/PR:H/UI:N/S:U/C:H/I:H/A:H); it affects only major versions 17–18 and was fixed in 18.4, 17.10, 16.14, 15.18, and 14.23 (released May 14, 2026) by properly quoting subscription names (Nathan Bossart).

### 6. Behavioral evidence from TAP tests

`src/bin/pg_createsubscriber/t/040_pg_createsubscriber.pl` exercises: mandatory-option failures, run without `--databases`, verification that the physical slot is removed on the primary, and (PG18) that `recovery_target_lsn` is absent from `postgresql.auto.conf` after a successful run (confirming the recovery-param reset). Buildfarm history shows timeout-sensitivity of this test on slow/Windows animals.

## Recommendations

**Staged, production-safe procedure:**
1. **Pre-flight:** Ensure `wal_level=logical`, `max_slot_wal_keep_size=-1`, and adequate `max_replication_slots`/`max_wal_senders` on the primary; `max_active_replication_origins`, `max_logical_replication_workers`, `max_worker_processes` on the standby. Confirm the standby is streaming and current (`pg_stat_replication` lag near zero).
2. **Dry run first:** `pg_createsubscriber --dry-run -v -D <datadir> -P "<primary connstr>" -d <db>...` (or `--all`). Review the logged "would ..." actions and any `max_slot_wal_keep_size` warning.
3. **Stop the standby** cleanly (the tool requires it not running).
4. **Set `--recovery-timeout`** to a value comfortably above expected catch-up (minutes to hours for large lag), and keep the primary lightly writing so `recovery_target_lsn` is reached promptly.
5. **Run it**, capturing the log directory (`pg_createsubscriber_server.log`, `pg_createsubscriber_internal.log`).
6. **Verify:** `pg_stat_subscription` (worker active, `latest_end_lsn` advancing), `pg_replication_origin_status`, `pg_subscription`/`pg_subscription_rel` (`srsubstate='r'`), and row-count/checksum spot checks vs the publisher. On the primary check slot `confirmed_flush_lsn` lag.
7. **Handle sequences** right before cutover (dump/setval from publisher).
8. **For upgrades:** combine with `pg_upgrade` on the converted subscriber (PG17→18 near-zero-downtime pattern), then cut traffic over and drop publications on the old primary.

**Thresholds that change the plan:** if the standby lag is large or the primary is idle, raise `--recovery-timeout` or generate primary writes; if `max_slot_wal_keep_size` cannot be `-1`, ensure the subscriber will catch up fast or accept slot-invalidation risk; if you need 2PC, set `max_prepared_transactions>0` on both sides and pass `--enable-two-phase`.

**When NOT to use it:** small databases (plain logical replication with `copy_data=true` is simpler and safe — this is the project's own recommendation); when you cannot afford to rebuild the standby on failure; when the standby is a synchronous replica you cannot afford to have commits wait on; when you need selective per-table replication that `FOR ALL TABLES` can't express (though PG18 `--publication` can reuse a pre-existing publication).

## Caveats
- Exact current line numbers cited (e.g. `check_publisher` ~1015, `setup_recovery` ~1320, `start_standby_server` ~1650–1732) are from the doxygen/master source viewer and patch threads; minor drift between REL_18_STABLE point releases is possible, but function names, SQL text, and GUC checks quoted are verbatim from the source.
- The `start_standby_server()` `-o` string details (`listen_addresses=''`, `unix_socket_permissions=0700`, `max_logical_replication_workers=0` under `restrict_logical_worker`) are confirmed from committed patch code and the tool's own verbose output; I found no evidence it sets `sync_replication_slots=off`.
- PostgreSQL 19 sequence-synchronization features are mentioned only to contrast with PG18 limitations and are out of scope for REL_18_STABLE.