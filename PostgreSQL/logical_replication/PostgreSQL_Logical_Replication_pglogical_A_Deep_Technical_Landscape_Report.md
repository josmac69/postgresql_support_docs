# PostgreSQL Logical Replication & pglogical: A Deep Technical Landscape Report

## TL;DR
- The canonical modern corpus is dominated by primary sources (PostgreSQL docs/release notes, pgsql-hackers and commitfest threads) plus a tight cluster of authoritative blogs — Fujitsu's postgresql.fastware.com, Amit Kapila's blog, Bertrand Drouvot's github.io, dbi-services, pgEdge, and the AWS Database blog — which together cover PG16 (origin filtering, logical decoding on standby), PG17 (failover slots, `pg_createsubscriber`), and PG18 (generated columns, seven conflict counters, `idle_replication_slot_timeout`, `streaming=parallel` default).
- pglogical 2.x is in EDB maintenance mode (still tracking new majors — v2.4.6 adds PostgreSQL 18, v2.4.7 adds PostgreSQL 19) but is no longer the recommended path; its lineage now runs through pgEdge's Spock fork (active-active, delta-apply CRDTs, geo-sharding) and EDB's Postgres Distributed (PGD). This is the key "is pglogical still relevant in 2026" story.
- The richest untapped territory for new talks/articles is internals-level operational content: reorder-buffer / `logical_decoding_work_mem` memory behavior, parallel-apply-worker deadlock detection, failover-slot production runbooks (native sync vs `pg_failover_slots` vs Patroni), multi-TB major-version upgrades, and the still-unsolved DDL replication problem.

## Key Findings
- **Version currency matters enormously, and secondary sources frequently get it wrong.** PG16 introduced origin filtering (`origin=none`) and minimal logical decoding on standby; PG17 introduced native failover slots (`sync_replication_slots`, the slotsync worker) and `pg_createsubscriber`; PG18 shipped generated-column replication (`publish_generated_columns`, STORED only), seven new `pg_stat_subscription_stats` conflict counters, `idle_replication_slot_timeout`, and flipped the `streaming` default from `off` to `parallel`. **Sequence replication did NOT make PG18 — it is a PostgreSQL 19 feature** (`FOR ALL SEQUENCES`, `REFRESH SEQUENCES`, a new sequencesync worker, landed across three commits from Amit Kapila). Being precise about this boundary is a differentiator.
- **The best internals writing is not on the largest blogs.** Fujitsu/Fastware (Kuroda, Vigneshwaran C, Shlok Kyal, Kapila) and Amit Kapila's personal blog carry the deepest source-code-level material; Bertrand Drouvot's blog is the best commit-anchored highlight coverage (he quotes commit hashes like 93db6cbd for the slotsync worker and 0fdab27a for standby decoding).
- **Conference material is fragmented and under-indexed** across postgresql.eu (stable slide PDFs), pgconf.dev / pgevents.ca, pgconf.in, pgday.ch, Speaker Deck (Peter Eisentraut), and YouTube.
- **pglogical is effectively frozen but not dead.** GitHub shows steady maintenance releases (bug fixes and new-major support only). New development flows to Spock (pgEdge) and PGD (EDB), which is confirmed by pgEdge's own statement that "pgLogical is now in maintenance mode, with no new features planned."
- **The single largest doc-acknowledged gap is DDL replication** — still unsolved in core (commitfest entry 3595 has been long-running), worked around via event triggers (pgl_ddl_deploy, logical_ddl). It was the topic that "received the most discussion" in the PGConf.dev logical-replication roadmap unconference, repeatedly flagged as the top enterprise blocker.

---

## SECTION 1 — TOP 15 ARTICLES (ranked by content quality)

**1. PostgreSQL Documentation — Chapter 29 (Logical Replication) & Chapter 49 (Logical Decoding)**
Author: PostgreSQL Global Development Group. Publisher: postgresql.org. URLs: https://www.postgresql.org/docs/current/logical-replication.html and https://www.postgresql.org/docs/current/logicaldecoding-explanation.html. Year: continuously updated (PG18/current). Versions: 14–18/devel.
Summary: The authoritative reference — architecture (walsender→pgoutput→apply), row filters (29.4), column lists, conflicts (29.7, including the full PG18 conflict-log format), restrictions (29.8: no DDL, no sequences pre-19, no large objects, partition/`publish_via_partition_root` rules, REPLICA IDENTITY FULL datatype caveats), failover (29.3), and slot-synchronization concepts (47/49).
Quality justification: #1 because it is primary, version-specific, and precise exactly where blogs are sloppy (sequence handling, replica-identity datatype restrictions, synced-slot semantics). Indispensable, though terse on internals rationale.

**2. "How to gain insight into the pg_stat_replication_slots view by examining logical replication" — Fujitsu Fastware**
Author: Fujitsu OSS team. Publisher: postgresql.fastware.com. URL: https://www.postgresql.fastware.com/blog/how-to-gain-insight-into-the-pg-stat-replication-slots-view-by-examining-logical-replication. Versions: 14+.
Summary: Source-level walkthrough of `ReorderBufferChange` memory accounting — how transaction data size is computed per change type (INSERT = base ReorderBufferChange + HeapTupleData + new-tuple length; TRUNCATE = base + OID×nrels), the xid-keyed hash table, and the `logical_decoding_work_mem` spill-vs-stream decision.
Quality justification: The single best public explanation of walsender/reorder-buffer memory behavior — precisely the internals depth an expert audience wants.

**3. Amit Kapila's blog — "Parallel Apply of Large Transactions," "Failover Slots in PostgreSQL-17," "Evolution of Logical Replication"**
Author: Amit Kapila (PostgreSQL committer/major developer). Publisher: amitkapila16.blogspot.com. URLs: http://amitkapila16.blogspot.com/2025/09/parallel-apply-of-large-transactions.html ; http://amitkapila16.blogspot.com/2024/10/failover-slots-in-postgresql-17.html ; http://amitkapila16.blogspot.com/2023/09/evolution-of-logical-replication.html. Versions: 10–18.
Summary: Leader-apply-worker (LA) → parallel-apply-worker (PA) assignment over a shared-memory queue (`shm_mq`), commit-order preservation, and heavyweight-lock-based deadlock detection between LA and PA. The failover post details the slotsync worker, `synchronized_standby_slots`, `hot_standby_feedback`, and the required `dbname` in `primary_conninfo`. The evolution post traces 9.4→16 feature-by-feature.
Quality justification: Written by the feature author; internals accuracy is unmatched. Docked slightly for blog brevity vs a design doc.

**4. Bertrand Drouvot — "Postgres 17 highlight: Logical replication slots synchronization" & "Postgres 16 highlight: Logical decoding on standby"**
Author: Bertrand Drouvot (AWS RDS Open Source). Publisher: bdrouvot.github.io. URLs: https://bdrouvot.github.io/2024/03/16/postgres-17-highlight-logical-replication-slots-synchronization/ ; https://bdrouvot.github.io/2023/04/19/postgres-16-highlight-logical-decoding-on-standby/. Versions: 16–17.
Summary: Commit-level walkthrough (quotes commit 93db6cbd and 0fdab27a) of the slotsync worker, the `failover` flag on `pg_create_logical_replication_slot`, `pg_log_standby_snapshot()`, and standby-decoding invalidation semantics.
Quality justification: Best commit-anchored highlight coverage; author co-developed logical-decoding-on-standby.

**5. AWS Database Blog — "Logical replication improvements in Amazon RDS for PostgreSQL 18"**
Author: AWS Database team. Publisher: aws.amazon.com/blogs/database. URL: https://aws.amazon.com/blogs/database/logical-replication-improvements-in-amazon-rds-for-postgresql-18/. Versions: 18.
Summary: Practical PG18 tour: `publish_generated_columns` (STORED only; virtual generated columns cannot replicate because they have no physical storage); the seven `pg_stat_subscription_stats` counters — `confl_insert_exists`, `confl_update_origin_differs`, `confl_update_exists`, `confl_update_missing`, `confl_delete_origin_differs`, `confl_delete_missing`, `confl_multiple_unique_conflicts` — with the note that "the *_origin_differs counters only work when track_commit_timestamp = on is set on the subscriber"; `streaming=parallel` verification (pre-PG18 `streaming=off` meant memory consumption proportional to transaction size — potentially hundreds of MB to multiple GB for very large transactions); toggling two-phase on a running subscription; and `idle_replication_slot_timeout` behavior at checkpoint.
Quality justification: Most complete, accurate single PG18 operational writeup, grounded in managed-service reality. Loses a point for RDS-specific framing.

**6. pgEdge — "Logical Replication Features in PG-17" & "Postgres 18: Generated Column Replication and Enhanced Monitoring"**
Author: pgEdge engineering. Publisher: pgedge.com. URLs: https://www.pgedge.com/blog/logical-replication-features-in-pg-17 ; https://www.pgedge.com/blog/postgres-18-generated-column-replication-and-enhanced-monitoring. Versions: 16–18.
Summary: Hands-on failover-slot setup with full `postgresql.conf` params, `pg_replication_slots` synced/failover column walkthrough, and PG18 conflict counters tied to distributed (Spock) architectures. Credits the community contributors (Hou Zhijie, Nisha Moond, Shubham Khanna, Vignesh C, Peter Smith).
Quality justification: Strong practical + code depth; useful bridge to active-active. Vendor lens toward pgEdge/Spock.

**7. dbi-services — "PostgreSQL 17: Convert a physical replica to a logical replica using pg_createsubscriber" (+ PG19 sequences follow-up)**
Author: Daniel Westermann. Publisher: dbi-services.com. URLs: https://www.dbi-services.com/blog/postgresql-17-convert-a-physical-replica-to-a-logical-replica-using-pg_createsubscriber/ ; https://www.dbi-services.com/blog/postgresql-19-logical-replication-of-sequences/. Versions: 17, 19.
Summary: Full command-line transcript of `pg_createsubscriber` including `--dry-run`, LSN recovery output, and the blue/green implication ("the key to faster green/blue PostgreSQL deployments"). The PG19 post is the best hands-on preview of `FOR ALL SEQUENCES` / `REFRESH SEQUENCES` / sequencesync and `pg_subscription_rel` state (r=ready).
Quality justification: Reproducible, transcript-level detail from a respected consultant.

**8. Fujitsu Fastware — "Bi-directional replication using origin filtering in PostgreSQL"**
Author: Vigneshwaran C. Publisher: postgresql.fastware.com. URL: https://www.postgresql.fastware.com/blog/bi-directional-replication-using-origin-filtering-in-postgresql. Versions: 16.
Summary: The `origin=none|any` semantics, WAL origin tagging, the initial-COPY origin-ambiguity WARNING, and the SQL to detect potentially non-local origins on a publisher. Written by a core contributor to the feature.
Quality justification: Authoritative primary-adjacent coverage of the PG16 active-active foundation.

**9. Fujitsu Fastware — "Failover Logical Slots — Ensuring High Availability of Logical replication in PostgreSQL 17"**
Author: Fujitsu OSS team. Publisher: postgresql.fastware.com. URL: https://www.postgresql.fastware.com/blog/failover-logical-slots-ensuring-high-availability-of-logical-replication-in-postgresql-17. Versions: 17.
Summary: `pg_replication_slots` synced/failover/invalidation columns, the `failover_ready` verification query, and synced-slot restrictions (cannot drop/consume on standby; temporary synced slots dropped on promotion; invalidation on primary propagates to standby).
Quality justification: Clear, accurate HA-focused deep dive; complements docs §29.3.

**10. "Failover Slots, Two Years On" — thebuild.com (Christophe Pettus)**
Author: Christophe Pettus (PGX). Publisher: thebuild.com. URL: https://thebuild.com/blog/failover-slots-two-years-on/. Versions: 17–18.
Summary: Opinionated production runbook — enable `sync_replication_slots`, set `synchronized_standby_slots`, create subscriptions with `failover=true`, and critically gate promotion on slot-sync confirmation via `pg_sync_replication_slots()`; distinguishes `synchronized_standby_slots` from `synchronous_standby_names`. Notes PG18's read-only `effective_wal_level` GUC and the `slotsync_skip_reason` column.
Quality justification: Rare production-judgment content; the "correct in the average case, quietly broken in the failure case" framing is exactly what practitioners need.

**11. Gunnar Morling — "Mastering Postgres Replication Slots: Preventing WAL Bloat and Other Production Issues"**
Author: Gunnar Morling (Decodable, ex-Debezium lead). Publisher: morling.dev. URL: https://www.morling.dev/blog/mastering-postgres-replication-slots/. Versions: 13–18.
Summary: `max_slot_wal_keep_size` invalidation mechanics (wal_status=unreserved, safe_wal_size negative), PG18 `idle_replication_slot_timeout` (recommends 48h–72h), heartbeat strategies, and multi-database WAL-growth pitfalls in CDC pipelines.
Quality justification: The best slot-lifecycle/WAL-retention article for CDC users; authoritative author.

**12. peerdb.io — "Exploring versions of the Postgres logical replication protocol"**
Author: PeerDB team. Publisher: blog.peerdb.io. URL: https://blog.peerdb.io/exploring-versions-of-the-postgres-logical-replication-protocol. Versions: 14–16.
Summary: Protocol versions 1–4 dissected (v2 in-progress streaming, v3 two-phase, v4 parallel apply of a single large txn — clarifying that v4 spreads one large transaction across multiple subscriber processes, not multiple transactions), with a custom Go tool (polorex) and benchmarks on slot-size behavior.
Quality justification: Unusually deep protocol-level content for anyone building a decoding consumer; niche but excellent.

**13. Fujitsu Fastware — "An introduction to PostgreSQL pg_createsubscriber" & "Inside logical replication in PostgreSQL: How it works"**
Author: Shlok Kyal / Fujitsu OSS. Publisher: postgresql.fastware.com. URLs: https://www.postgresql.fastware.com/blog/an-introduction-to-postgresql-pg-createsubscriber ; https://www.postgresql.fastware.com/blog/inside-logical-replication-in-postgresql. Versions: 15–18.
Summary: tablesync-worker mechanics (`max_sync_workers_per_subscription`, USE_SNAPSHOT + COPY, per-table slots, SYNCDONE→READY) and the pg_createsubscriber rationale vs COPY-based initial sync.
Quality justification: Clear internals from contributors; good teaching material.

**14. Neon — "PostgreSQL 18 Logical Replication of Generated Columns"**
Author: Neon. Publisher: neon.com. URL: https://neon.com/postgresql/postgresql-18/logical-replication-improvements. Versions: 18.
Summary: Generated-column replication, the conflict-monitoring view, and the streaming-default change, with the `track_commit_timestamp` caveat spelled out.
Quality justification: Concise, accurate PG18 summary; good secondary reference.

**15. pgEdge — "Introducing pgEdge Distributed PostgreSQL (and Spock)" & "pgLogical Alternatives & Distributed Postgres Options"**
Author: pgEdge (incl. commentary from the Slony-era founder Jan Wieck's circle). Publisher: pgedge.com. URLs: https://www.pgedge.com/blog/introducing-pgedge-distributed-postgresql-and-spock ; https://www.pgedge.com/blog/navigating-distributed-postgresql-options-pglogical-and-beyond. Versions: 15–18.
Summary: The pglogical→Spock lineage, Delta Conflict Avoidance (a lightweight CRDT alternative for running sums/counters), partitioned-table geo-sharding, PII column exclusion, and the explicit statement that "pgLogical is now in maintenance mode, with no new features planned."
Quality justification: The definitive "where did pglogical go" narrative, from the fork's own maintainers (read with vendor bias in mind).

*Honorable mentions:* Mydbops (PG16 bidirectional; pg_createsubscriber), Severalnines bidirectional deep dive, Crunchy Data "Active Active in Postgres 16," "That Guy From Delhi" ReorderBufferWrite wait-event post, Highgo logical-replication overview and sequence-decoding analysis, DZone "Evolution of Logical Replication in PostgreSQL 16," bytebase.com PG19 sequence preview, singhajit.com Debezium-outbox database-impact analysis.

---

## SECTION 2 — TOP 15 SLIDE DECKS / CONFERENCE PRESENTATIONS (ranked)

**1. "Scaling Logical Replication: Parallel Apply and Centralized Decoding" — Amit Kapila & Hayato Kuroda, PGConf.dev 2026**
Session page: https://2026.pgconf.dev/session/526 (Wed May 20, 2026, Labatt room, 50 min). Topics: parallel apply with commit-ordering/dependency management; a "decode once, serve many" centralized-decoding model sharing Logical Change Records (LCRs) across walsenders; WIP parallel-apply patch benchmarks.
Quality justification: The most forward-looking authoritative talk; two feature authors (note: Kapila is now listed as affiliated with Apple). Slides/video may not yet be posted.

**2. "PostgreSQL 17 and beyond" — Amit Kapila, PGConf.dev 2024**
Slides PDF: https://www.pgevents.ca/events/pgconfdev2024/sessions/session/52/slides/36/PostgreSQL%2017%20and%20beyond_conf.pdf ; video: https://youtu.be/aWScCI5Ko18. Topics: failover slots, pg_createsubscriber, preserving subscription state across pg_upgrade, and roadmap (DDL replication, conflict detection/resolution, active-active).
Quality justification: Roadmap from a major developer; primary-hosted slides.

**3. "Online Upgrade of replication clusters without downtime" — Hayato Kuroda (w/ Vigneshwaran C), PGConf.dev 2024**
Session: https://www.pgevents.ca/events/pgconfdev2024/sessions/session/20-online-upgrade-of-replication-clusters-without-downtime/ ; video: https://www.youtube.com/watch?v=EdSsmJAe0R0. Topics: pg_upgrade of nodes with logical slots (PG17+), preserving slots/subscriptions, minimal-downtime major upgrades.
Quality justification: Directly targets the top production use case; feature author.

**4. "Speeding up logical replication setup" — Euler Taveira, PGConf.EU 2024**
Slides PDF: https://www.postgresql.eu/events/pgconfeu2024/sessions/session/5853/slides/567/Speeding%20up%20logical%20replication%20setup.pdf. Topics: pg_createsubscriber design/internals (author is the committer, commit d44032d0), tablesync workflow (`max_sync_workers_per_subscription`, COPY … TO STDOUT, SUBREL_STATE_SYNCDONE→SUBREL_STATE_READY), and benchmark speedups (the deck cites ~13× at 20 GB and ~7× at 10 GB).
Quality justification: Feature author, primary-hosted slides, concrete numbers.

**5. "Internals of logical replication" — Vigneshwaran C, PGConf India 2023**
Slides PDF: https://www.postgresql.fastware.com/hubfs/_Global/Download/Share/PostgreSQL%20Internals%20of%20logical%20replication.pdf. Topics: walsender/walreceiver, apply and tablesync workers, replication slots, the logical-decoding pipeline.
Quality justification: One of the few internals-focused decks with a stable public PDF.

**6. "pg_failover_slots: The missing piece" — Peter Eisentraut, PGConf.EU 2023**
Video: https://www.youtube.com/watch?v=oACqSne3-eE. Topics: maintaining logical slots across physical failover before native PG17 support; the pg_failover_slots extension.
Quality justification: Committer-delivered; the canonical pre-PG17 failover-slot talk.

**7. "Postgres 16 highlight: Logical decoding on standby" — Bertrand Drouvot, FOSDEM PGDay 2024**
Slides PDF: https://www.postgresql.eu/events/fosdem2024/sessions/session/5123/slides/472/pgdayfosdem2024.pdf ; video (PGConf.EU 2023 version): https://www.youtube.com/watch?v=RQucDdeg0Ac. Topics: standby logical decoding internals, slot invalidation, `pg_log_standby_snapshot()`.
Quality justification: Co-developer; live demo; primary-hosted slides.

**8. "Implementing failover of logical replication slots in Patroni" — Alexander Kukushkin, PGConf.DE 2022**
Slides PDF: https://www.postgresql.eu/events/pgconfde2022/sessions/session/3745/slides/306/Implementing%20failover%20of%20logical%20replication%20slots%20in%20Patroni.pdf. Topics: the "logical decoding cannot be used while in recovery" problem, Patroni REST health-check gating (503), pg_tm_aux, slot copying via libpq, the risk of silent event loss.
Quality justification: The definitive Patroni-integration talk, from Patroni's principal maintainer.

**9. "Logical Replication in PostgreSQL 10" — Peter Eisentraut, PGConf US 2017 (Speaker Deck)**
Slides: https://speakerdeck.com/petere/logical-replication-in-postgresql-10. Topics: the original publication/subscription model, name-based mapping, use cases.
Quality justification: Canonical origin document; outdated on features but historically essential.

**10. "The journey towards active-active replication in PostgreSQL" — PGConf.EU 2023**
Slides PDF: https://www.postgresql.eu/events/pgconfeu2023/sessions/session/4783/slides/434/pgconfeu2023_active_active.pdf. Topics: origin filtering (`origin=none/any`), loop prevention, n-way replication roadmap.
Quality justification: Good synthesis of the active-active trajectory in core.

**11. "A journey into PostgreSQL logical replication" — José Neves, PGConf.EU 2023**
Slides PDF: https://www.postgresql.eu/events/pgconfeu2023/sessions/session/4773/slides/427/A%20journey%20into%20postgresql%20logical%20replication.pdf. Topics: a real-world monolith-to-distributed migration.
Quality justification: Practitioner war-stories; useful production framing.

**12. "Understanding logical decoding and replication" — Michael Paquier, Postgres Open 2014**
Slides PDF: https://paquier.xyz/content/materials/20140919_pgopen_logirep.pdf (index: https://paquier.xyz/presentations/). Topics: logical-decoding internals, output plugins, protocol.
Quality justification: Foundational internals deck from a committer; dated but conceptually canonical.

**13. "Logical replication - for fun and profit" — Patrick Stählin (Aiven), Swiss PGDay 2025**
Slides PDF: https://www.pgday.ch/common/slides/2025_Logical_replication_-_Swiss_PGDay_2025.pdf. Topics: publications/subscriptions (with the full `CREATE PUBLICATION` grammar), column/row filters, practical setup.
Quality justification: Recent, accessible EMEA regional talk; good intro-to-intermediate reference.

**14. "Selective Replication in PostgreSQL" — AWS, Swiss PGDay 2024**
Slides PDF: https://www.pgday.ch/common/slides/2024_selective_replication_in_PG.pdf. Topics: row filters, column lists, parallel apply, binary COPY for initial sync.
Quality justification: Clean feature survey with analytics/reporting use cases.

**15. "Using logical replication for major version upgrades and tenant migrations" — Shayon Mukherjee, PGConf NYC 2024**
Session page (slides on Google Drive): https://postgresql.us/events/pgconfnyc2024/schedule/session/1577-using-logical-replication-for-major-version-upgrades-and-tenant-migrations/. Topics: `pg_easy_replicate` (developed at Tines) performing "seamless upgrades across 50+ production databases via blue/green setup with DNS based switchovers."
Quality justification: Real multi-tenant blue/green production experience; strong operational value (less durable Google-Drive hosting).

*Honorable mentions:* Petr Jelínek's pglogical talks (PGConf.EU 2015/2016 — foundational but stable slides hard to locate); pgEdge/Spock multi-master talk at Postgres Conference (https://www.pgedge.com/postgres-conference-preso-video-multi-master-replication); Shveta Malik/Vignesh C "Unlocking New Possibilities: The Evolving Landscape of PostgreSQL Logical Replication" (PGConf NYC 2025 — parallel apply, failover slots, conflict detection; slides referenced only via LinkedIn recap, unverified); PGCon 2023 DDL Replication deck (https://wiki.postgresql.org/images/d/dd/20230602-DDL_Replication.pdf); CloudNativePG Recipe 15 (article, not a deck: https://www.gabrielebartolini.it/articles/2024/12/cnpg-recipe-15-postgresql-major-online-upgrades-with-logical-replication/).

---

## SECTION 3 — GAP ANALYSIS / BRAINSTORMING (most important section)

### A. Production patterns (underserved)

**A1. Multi-TB major-version upgrades via logical replication — end-to-end at scale.**
What exists: pg_createsubscriber intros (dbi, Fastware, Euler's slides); the Tines/pg_easy_replicate blue/green talk; AWS blue/green docs. What's missing: a rigorous, numbers-driven internals treatment combining `pg_createsubscriber --all` + `pg_upgrade` + a reverse-subscription safety net + sequence handling + cutover orchestration at 10+ TB, with WAL-retention math and failure-recovery paths (pg_createsubscriber leaves the data directory unrecoverable on post-promotion failure — a fact rarely stressed). **Attractiveness: 9/10.** The #1 real-world use case with no single deep, vendor-neutral, internals-level guide.

**A2. Walsender memory & reorder-buffer behavior under production load.**
What exists: the Fastware `pg_stat_replication_slots` post; the "ReorderBufferWrite" wait-event post. What's missing: a consolidated model of per-walsender memory (static ~10–20 MB + `logical_decoding_work_mem`, default 64 MB) multiplied across N slots, with the spill-to-disk vs streaming thresholds and how to size `logical_decoding_work_mem` for CDC fleets (common starting point 256 MB, some to 1 GB). **Attractiveness: 8/10.**

**A3. Parallel-apply worker internals & deadlock detection (PG16 → PG18 default).**
What exists: Kapila's blog; the GUC docs. What's missing: a talk dissecting the LA↔PA `shm_mq` protocol, commit-order enforcement, the heavyweight-lock deadlock-detection scheme, and when parallel apply *hurts* (partition/constraint-induced dependencies that are independent on the publisher but interdependent on the subscriber). Timely now that PG18 defaults `streaming=parallel`. **Attractiveness: 8/10.**

**A4. Failover-slot decision matrix in practice: native sync (PG17) vs pg_failover_slots vs Patroni permanent slots.**
What exists: docs, Fastware, thebuild, Percona/Patroni, EDB. What's missing: a single comparative treatment incorporating the crucial EDB statement — verbatim: *"v18 will be the final release for which EDB supports pg_failover_slots. This will allow customers time to transition before v19, where we recommend using the native logical failover slot capability introduced in PostgreSQL 17"* — plus Patroni-version requirements and promotion-gating runbooks. **Attractiveness: 9/10.** Timely migration guidance nobody has consolidated.

**A5. Monitoring/alerting design for logical replication.**
What exists: scattered queries. What's missing: a coherent observability blueprint — `confirmed_flush_lsn` lag, `pg_stat_replication_slots` spill/stream counters, the PG18 `confl_*` counters, `pg_stat_subscription_stats` (with the PG19 split of `sync_table_error_count` vs `sync_seq_error_count`), `slotsync_skip_reason`, and `inactive_since` — mapped to concrete alert thresholds. **Attractiveness: 8/10.**

**A6. Sequence handling strategies pre-PG19.**
What exists: docs restriction note; pgEdge/bytebase/dbi PG19 previews. What's missing: a definitive "what to actually do today" guide (setval scripts; pglogical's +1000 buffer trick via a background worker; ordering in cutover runbooks) and a clear-eyed explanation of *why* sequences broke logical decoding's foundations (WAL logging every 32 increments, logging a future value, and the nextval XID-0 subtransaction problem). **Attractiveness: 7/10** (shrinking as PG19 lands, but relevant for years given upgrade lag).

### B. Corner cases (weakly covered)

**B1. Slot-invalidation taxonomy (PG18).** `max_slot_wal_keep_size` vs `idle_replication_slot_timeout` (invalidation at checkpoint time, not immediately — up to `checkpoint_timeout` lag; synced slots exempt because they are always considered inactive), `wal_status` transitions, and downstream-consumer impact. **Attractiveness: 7/10.**

**B2. Snapshot builder & exported-snapshot consistency during initial sync.** The `snapbuild.c` consistent-point machinery (`AllocateSnapshotBuilder`, `xmin_horizon`), USE_SNAPSHOT tablesync, and failure/restart of tablesync workers. Almost no accessible writing exists. **Attractiveness: 8/10** (pure internals gold, hard to research = high differentiation).

**B3. Origin loops & initial-COPY origin ambiguity in bidirectional setups.** The documented WARNING that initial COPY cannot distinguish origins, plus the audit SQL. **Attractiveness: 6/10.**

**B4. Partitioned-table replication nuances (`publish_via_partition_root`).** Leaf-vs-root identity, row-filter interaction, mismatched partition schemes, and the requirement that leaf partitions exist as valid targets. **Attractiveness: 7/10.**

**B5. Interaction with VACUUM / xmin horizon / catalog_xmin bloat on the publisher.** How `catalog_xmin` retention from a lagging or idle slot blocks autovacuum from removing dead catalog tuples and causes catalog bloat — under-explained despite being a top outage cause. **Attractiveness: 8/10.**

**B6. Two-phase commit decoding edge cases & subtransaction/spill behavior.** Including the PG17→18 ability to toggle `two_phase` on a running subscription, `subtwophasestate` in `pg_subscription`, and the nextval-XID-0 subtransaction decoding bug class surfaced in the sequences thread. **Attractiveness: 6/10.**

**B7. `disable_on_error` + conflict-skip workflows (`pg_replication_origin_advance`, `ALTER SUBSCRIPTION … SKIP`).** Practical recovery choreography, especially where parallel-apply doesn't log the finish LSN (docs advise switching `streaming` off/on to re-surface it). **Attractiveness: 7/10.**

### C. Speculative / advanced architectures

**C1. pglogical vs native in 2026 — and the Spock/PGD lineage.** A clear-eyed "is pglogical still relevant" piece: maintenance-only status, PG18/PG19 support via v2.4.6/v2.4.7, feature-parity gaps closed by native, and when Spock (delta-apply CRDTs, geo-sharding, PII exclusion) or PGD is actually warranted. **Attractiveness: 9/10.** High demand, much confusion, little authoritative neutral writing.

**C2. Geo-distributed active-active with origin filtering + conflict detection (PG16→18→19).** Building toward core-only multi-master: origin filtering, PG18 conflict stats, and the roadmap toward conflict *resolution* (the proposed `apply_remote` / `keep_local` / `last_update_wins` strategies). **Attractiveness: 8/10.**

**C3. Native logical replication vs Debezium/Kafka as a CDC backbone.** When to use `pgoutput` natively vs Debezium; per-slot decoding-cost duplication (each slot decodes the entire WAL stream independently); at-least-once (not exactly-once) semantics and consumer idempotency; unbounded WAL-growth risk. **Attractiveness: 8/10.**

**C4. Logical replication in Kubernetes (CloudNativePG declarative Publication/Subscription).** CNPG 1.25+ Publication/Subscription CRDs and the Recipe 15 major-online-upgrade pattern; almost no conference-grade internals treatment exists. **Attractiveness: 8/10** (fast-growing audience).

**C5. Mixing physical and logical replication + synchronous-quorum interactions.** How `synchronized_standby_slots` interacts with `synchronous_standby_names` and quorum commit (and how it can silently stall logical senders), plus cascading logical topologies (fan-in consolidation, fan-out distribution). **Attractiveness: 7/10.**

**C6. Selective data residency / GDPR sharding via row filters + column lists + PII exclusion.** Combining PG15 row filters/column lists with Spock-style PII column exclusion and geo-sharded partitioned tables for compliance-driven topologies. **Attractiveness: 7/10.**

**C7. The DDL-replication problem — survey + workarounds + roadmap.** Commitfest 3595 history, the parse-tree→JSONB deparse design (`parse-tree→jsonb→jsonb-string→WAL→expand-to-DDL`), event-trigger workarounds (enova's pgl_ddl_deploy with `exclude_alter_table_subcommands`; samedyildirim's logical_ddl), and why it remains unsolved. Consistently the #1 roadmap topic at PGConf.dev. **Attractiveness: 9/10.** Perennial, high-interest, and no neutral up-to-date survey exists.

---

## Prioritized shortlist — 10 most promising topics for the requester
(EMEA/Asia conference speaker; deep internals-level writing)

1. **Multi-TB major-version upgrades with pg_createsubscriber + pg_upgrade: an internals-grade runbook** (A1) — flagship talk, universal appeal, directly aligned with PGConf.dev/PGConf.EU roadmap emphasis.
2. **The failover-slot decision matrix in 2026: native sync vs pg_failover_slots (EOL after v18) vs Patroni** (A4) — timely migration guidance anchored to the EDB deprecation.
3. **Is pglogical still relevant? pglogical → Spock → PGD, and native parity in 2026** (C1) — clears widespread confusion; strong EMEA/Asia draw.
4. **Inside the walsender: reorder buffer, logical_decoding_work_mem, spill vs stream** (A2/B2) — pure internals differentiation, source-code-level.
5. **DDL replication: the last big gap — history, deparse design, workarounds, and the road ahead** (C7) — perennial top-interest topic with no neutral survey.
6. **Parallel apply internals now that PG18 makes it the default** (A3) — timely, code-level, benchmark-friendly.
7. **catalog_xmin, VACUUM, and slot-induced bloat: the outage nobody warns you about** (B5) — high ops payoff, under-covered, memorable.
8. **Designing observability & alerting for logical replication (PG17/18/19 signals)** (A5) — practical, reusable, sponsor-friendly.
9. **Native logical replication vs Debezium/Kafka as your CDC backbone** (C3) — bridges DB and data-engineering audiences.
10. **Logical replication in Kubernetes with CloudNativePG declarative Pub/Sub** (C4) — fastest-growing audience segment.

## Caveats
- **Version precision:** Several secondary sources conflate PG18 and PG19. Sequence replication (`FOR ALL SEQUENCES`, `REFRESH SEQUENCES`, sequencesync worker) is a **PostgreSQL 19** feature, not PG18; PG18 shipped generated-column replication, seven conflict counters, `idle_replication_slot_timeout`, and the `streaming=parallel` default. pglogical v2.4.7 adds PG19 support per its GitHub changelog; v2.4.6 added PG18.
- **Forward-looking items:** The PGConf.dev 2026 talk (session 526) abstract is confirmed but slides/video may not yet be posted. PG19 features are described from beta/commit/mailing-list state and could change. Anything phrased as roadmap ("proposed," conflict-resolution strategies) is not yet committed to core.
- **Vendor bias:** pgEdge (Spock), EDB (pglogical/PGD/pg_failover_slots), AWS/Neon, and Fujitsu content carries commercial framing; technical facts were cross-checked against primary docs where possible.
- **Link durability:** Slide URLs on postgresql.eu and pgevents.ca are generally stable; Google-Drive-hosted decks (PGConf NYC) and LinkedIn recaps are less durable, and some (e.g. the Shveta Malik/Vignesh C NYC 2025 slides) could not be independently verified.
- **Euler Taveira benchmark figures:** The ~13× (20 GB) / ~7× (10 GB) speedups appear on the presenter's own slides and reference a pgsql-hackers message; treat as author-reported rather than independently reproduced.
- **pg_failover_slots EOL:** EDB states v18 will be the final supported release, recommending native PG17 failover slots for v19 — verify against current EDB docs before advising clients, as timelines can shift.