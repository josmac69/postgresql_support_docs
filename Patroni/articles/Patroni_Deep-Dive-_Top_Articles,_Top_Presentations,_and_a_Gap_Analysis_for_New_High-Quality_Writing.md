# Patroni Deep-Dive: Top Articles, Top Presentations, and a Gap Analysis for New High-Quality Writing

## TL;DR
- The best existing Patroni material clusters around a handful of high-quality sources — the official docs (quorum, DCS failsafe, watchdog modules), Kukushkin/Bungina conference talks, and vendor deep-dives from Cybertec, Percona, Crunchy Data and Palark — but almost all of it stops at Patroni 3.x concepts and PostgreSQL ≤16, leaving a large opening for authoritative writing on Patroni 4.x internals and PostgreSQL 17/18.
- The strongest single presentation lineage is Kukushkin/Bungina's "What is Patroni, really?" (POSETTE 2025) plus the PGCon 2019 training deck; the strongest article lineage is the Patroni docs' own `replication_modes`, `dcs_failsafe_mode` and `watchdog` pages combined with Cybertec's etcd/standby-cluster series and Percona's logical-slot-failover post.
- The richest un-covered territory for an expert author is: (1) Patroni 4.x quorum synchronous internals and the `QuorumStateResolver` state machine; (2) PostgreSQL 17 native failover slots (`sync_replication_slots`) vs. Patroni's own slot-copying, including the silent-data-loss edge cases; (3) PostgreSQL 18 async I/O / background I/O worker interaction with Patroni; and (4) rigorous corner-case engineering (failsafe partition math, watchdog safety-margin, clock skew, OOM behavior).

---

## SECTION 1 — TOP 15 ARTICLES ON PATRONI (ranked by quality of content)

Ranking criteria: technical depth, accuracy, coverage of internals, and relevance to recent versions. Primary-source and internals-heavy material is ranked above tutorials. Note: Patroni's officially supported PostgreSQL range is now "9.3 to 18" (per the Patroni 4.1.4 README/docs), so version relevance below is judged against that span.

### 1. Patroni official documentation — "Replication modes" (Synchronous / Quorum commit)
- **Author/Publisher:** Patroni Contributors (maintained by Alexander Kukushkin, Polina Bungina, Israel Barth Rubio) — patroni.readthedocs.io
- **Date:** Continuously updated; current for 4.1.x (2025–2026)
- **URL:** https://patroni.readthedocs.io/en/latest/replication_modes.html
- **Covers:** Asynchronous durability, `synchronous_mode`, `synchronous_mode_strict`, synchronous replication factor, maximum lag on sync node, and the quorum-commit mode with the `/sync` DCS key (`quorum`, `voters`, `numsync`).
- **Depth:** Very high — this is the authoritative description of how Patroni maps its `/sync` key onto `synchronous_standby_names` and guarantees a failover candidate holds the latest commit.
- **Versions:** Patroni 3.x/4.x; PostgreSQL 9.6–18.
- **Why ranked #1:** It is the canonical, correct, maintainer-written reference for the single hardest area of Patroni. Everything else on synchronous/quorum replication derives from it.

### 2. Patroni official documentation — "DCS Failsafe Mode"
- **Author/Publisher:** Patroni Contributors (feature by Alexander Kukushkin, PR #2379) — patroni.readthedocs.io
- **Date:** Current for 4.1.x
- **URL:** https://patroni.readthedocs.io/en/latest/dcs_failsafe_mode.html
- **Covers:** Why a primary demotes when it loses the DCS, the `/failsafe` key, the `POST /failsafe` REST call, why the primary must see *all* members (not a quorum), and the partition-math reasoning.
- **Depth:** Very high — includes the low-level rationale and the "what if node terminates while DCS is down" edge cases.
- **Versions:** 3.0+ (failsafe), current 4.x.
- **Why ranked #2:** The single best explanation of Patroni's most subtle safety mechanism, written by the author of the feature.

### 3. Patroni official documentation — "Watchdog support"
- **Author/Publisher:** Patroni Contributors — patroni.readthedocs.io
- **Date:** Current for 4.1.x
- **URL:** https://patroni.readthedocs.io/en/latest/watchdog.html
- **Covers:** Split-brain fencing via Linux watchdog, `safety_margin`, the `ttl - safety_margin - loop_wait` timing budget, `safety_margin: -1` (ttl//2), and softdog setup.
- **Depth:** High — precise on the timing guarantees and the window where the guarantee can be invalidated.
- **Versions:** all current.
- **Why ranked #3:** Authoritative and unusually rigorous about the timing math that most blog posts get wrong.

### 4. "How Patroni Addresses the Problem of the Logical Replication Slot Failover" — Percona
- **Author/Publisher:** Jobin Augustine (and colleagues), Percona blog
- **Date:** ~2020, still widely referenced
- **URL:** https://www.percona.com/blog/how-patroni-addresses-the-problem-of-the-logical-replication-slot-failover-in-a-postgresql-cluster/
- **Covers:** Permanent logical slots defined in the `slots:` section, how Patroni copies slot state to standbys and advances via `pg_replication_slot_advance()`, and downstream re-pointing after switchover. (Per Kukushkin's PGConf.DE 2022 slides, failover of logical slots "is supported by Patroni starting from 2.1.0 (released in July 2021)," "requires PostgreSQL v11 or newer," and disables the old "create logical slots after promote" behavior.)
- **Depth:** High and practical, with `patroni.yml` and `pg_replication_slots` output.
- **Versions:** PostgreSQL 11+; pre-dates PG17 native failover slots.
- **Why ranked #4:** The clearest write-up of a genuinely hard feature — but it should be read alongside GitHub issue #1749 (below) for the data-loss caveats.

### 5. Patroni GitHub Issue #1749 — "Replication slot sync feature is unsafe, high data corruption risk"
- **Author/Publisher:** Craig Ringer (ringerc, 2ndQuadrant), patroni/patroni GitHub — opened **November 9, 2020**
- **Date:** 2020 (still the definitive statement of the hazard)
- **URL:** https://github.com/patroni/patroni/issues/1749
- **Covers:** The precise mechanism by which Patroni's pre-PG17 logical-slot copying can silently drop transactions on failover (confirmed_flush_lsn on the new timeline vs. the subscriber's last-seen LSN). Ringer's framing: "The slots configuration parameter is unsafe when used with logical replication slots and is highly likely to lead to silent data loss… there is no warning or error when provider is skipped over on failover. You will just get a silent gap where some changes did not replicate."
- **Depth:** Very high — a primary-source engineering discussion with a reproducible data-loss recipe.
- **Versions:** PostgreSQL 10–16 semantics.
- **Why ranked #5:** Indispensable counterpoint to the Percona article; the kind of corner case an expert audience wants.

### 6. "Patroni & etcd in High Availability Environments" — Crunchy Data
- **Author/Publisher:** Crunchy Data blog
- **Date:** Recent (Crunchy HA series)
- **URL:** https://www.crunchydata.com/blog/patroni-etcd-in-high-availability-environments
- **Covers:** Why etcd disk-write latency and >75% disk usage cause heartbeat timeouts, resource starvation and cascade failovers; the etcd/Patroni communication contract.
- **Depth:** High — operational root-cause analysis rather than a tutorial.
- **Versions:** DCS-agnostic; current.
- **Why ranked #6:** One of the few articles that treats the DCS as the real failure domain it is.

### 7. Cybertec — "Patroni etcd clusters: Introduction and How-To"
- **Author/Publisher:** Julian Markwort / Cybertec PostgreSQL
- **Date:** ~2019–2020 (etcd v2→v3 caveats)
- **URL:** https://www.cybertec-postgresql.com/en/introduction-and-how-to-etcd-clusters-for-patroni/
- **Covers:** The leader-race and leader-lock CAS mechanics, TTL renewal and forced demotion, and multi-DC etcd member placement ("biased" vs "tertiary decider").
- **Depth:** High — explains the consensus/mutex reasoning behind Patroni's behavior.
- **Versions:** etcd v2/v3 era; concepts still valid.
- **Why ranked #7:** Best conceptual treatment of why etcd node placement dictates failover behavior.

### 8. Cybertec — "Patroni: Cascading Replication with Standby Cluster"
- **Author/Publisher:** Cybertec PostgreSQL
- **Date:** Recent (RHEL-based examples)
- **URL:** https://www.cybertec-postgresql.com/en/patroni-cascading-replication-with-stanby-cluster/
- **Covers:** Standby-cluster (DC2 following DC1), standby leader, `standby_cluster.hosts`, `primary_slot_name`, permanent slots, and why manual promotion is required with only two DCs.
- **Depth:** High and hands-on.
- **Versions:** Patroni 3.x/4.x.
- **Why ranked #8:** The clearest practical guide to a real production DR pattern, with the split-brain caveat spelled out.

### 9. Palark — "Patroni-managed PostgreSQL cluster switchover: a tricky case that ended well"
- **Author/Publisher:** Palark tech blog
- **Date:** ~2023
- **URL:** https://palark.com/blog/patroni-postgresql-cluster-switchover/
- **Covers:** A real incident where a switchover promoted the least-current replica because a CHECKPOINT_SHUTDOWN record didn't reach one node; pg_waldump forensics; the fix in Patroni 3.2.1.
- **Depth:** High — genuine post-incident forensics with WAL-level detail.
- **Versions:** Patroni 3.0.1 → 3.2.1; PostgreSQL 15.
- **Why ranked #9:** Rare, honest failure narrative that teaches the async-switchover edge case better than any tutorial.

### 10. Kaarel Moppel — "Postgres Synchronous Replication — a 99.99% guarantee only"
- **Author/Publisher:** Kaarel Moppel (personal blog, ex-Cybertec)
- **Date:** 2024-12-09
- **URL:** https://kmoppel.github.io/2024-12-09-postgres-sync-replication-data-safety/
- **Covers:** The "ghost data" problem — `canceling wait for synchronous replication` still commits locally; why even 3+ quorum nodes are not bulletproof; the SyncRep wait-event connection-exhaustion failure pattern; 2PC as the only true fix.
- **Depth:** Very high — nuanced treatment of a widely-misunderstood durability gap.
- **Versions:** Current PostgreSQL; Patroni sync mode.
- **Why ranked #10:** Exactly the kind of "the default is not what you think" analysis expert readers value.

### 11. Percona — "PostgreSQL HA with Patroni: Your Turn to Test Failure Scenarios"
- **Author/Publisher:** Percona blog (Fernando Laudares Camargos et al.)
- **Date:** ~2021–2022
- **URL:** https://www.percona.com/blog/postgresql-ha-with-patroni-your-turn-to-test-failure-scenarios/
- **Covers:** Hands-on failure injection, softdog setup and the blacklisted-module gotcha, disabling systemd auto-start of PostgreSQL, and switchover testing.
- **Depth:** Medium-high, strongly practical.
- **Versions:** Patroni 2.x/3.x; PostgreSQL 12+.
- **Why ranked #11:** The best "actually test your cluster" companion piece.

### 12. Cybertec — "PostgreSQL High Availability and Patroni — an Introduction" + "PostgreSQL High-Availability Architectures"
- **Author/Publisher:** Cybertec PostgreSQL
- **Date:** ongoing series
- **URLs:** https://www.cybertec-postgresql.com/en/postgresql-high-availability-and-patroni-an-introduction/ and https://www.cybertec-postgresql.com/en/postgresql-high-availability-architectures/
- **Covers:** Replication fundamentals, the Patroni bot/DCS architecture, and multi-DC architecture patterns including standby clusters and the need for a third site.
- **Depth:** Medium-high; excellent conceptual foundation.
- **Versions:** current-ish.
- **Why ranked #12:** Best "foundational reading" pair for practitioners new to Patroni internals.

### 13. Percona Distribution for PostgreSQL — HA solution & "Patroni" solution docs
- **Author/Publisher:** Percona documentation
- **Date:** current (versions 12–17 solution pages)
- **URLs:** https://docs.percona.com/postgresql/17/solutions/patroni-info.html and https://docs.percona.com/postgresql/16/solutions/high-availability.html
- **Covers:** The three-layer split-brain protection model (Patroni leader key → etcd Raft → watchdog/STONITH), reference architecture with HAProxy/pgBackRest/PMM.
- **Depth:** Medium-high; well-structured reference architecture.
- **Versions:** PostgreSQL 12–17.
- **Why ranked #13:** Clean, vendor-neutral-ish reference architecture with the fencing model laid out clearly.

### 14. Medium — "PostgreSQL and Patroni Synchronous Replication Parameters" (Yasemin Büşra Karakaş)
- **Author/Publisher:** Yasemin Büşra Karakaş, Medium
- **Date:** 2024–2025
- **URL:** https://medium.com/@yaseminbsra.sergen/postgresql-and-patroni-synchronous-replication-parameters-48c6190ed347
- **Covers:** `synchronous_commit` levels (off/local/remote_write/on/remote_apply), `ANY k`/`FIRST` semantics, `nosync`/`nofailover` tags, and `synchronous_mode_strict` trade-offs with `patronictl list` output.
- **Depth:** Medium — good practical parameter map.
- **Versions:** current.
- **Why ranked #14:** A useful, concrete parameter reference, though community-blog quality.

### 15. Medium — "PostgreSQL Replication Internals & High Availability with Patroni" (Pawan Sharma)
- **Author/Publisher:** Pawan Sharma, Medium
- **Date:** 2024–2025
- **URL:** https://medium.com/@pawanpg0963/postgresql-replication-internals-high-availability-with-patroni-acb5a9812d59
- **Covers:** Replication slots, `synchronous_commit` behavior, WAL retention risks, and how these tie into Patroni HA.
- **Depth:** Medium.
- **Versions:** current, PostgreSQL 16-era.
- **Why ranked #15:** Solid replication-internals primer that connects Postgres mechanics to Patroni; representative of the better community content.

*(Honorable mentions consulted but not ranked: InstaDevOps' pgBouncer/pgBackRest guide, dev.to "Patroni, pg_auto_failover, and Streaming Replication," Decodable's PG17 failover-slots article, and Severalnines' Patroni+ClusterControl overview.)*

---

## SECTION 2 — TOP 15 PRESENTATIONS ON PATRONI (ranked by quality of content)

### 1. "Patroni: Understanding and Implementing PostgreSQL HA" — PGCon 2019 training
- **Speakers:** Alexander Kukushkin & Oleksii Kliukin
- **Conference/Year:** PGCon 2019 (Ottawa)
- **URL:** https://www.pgcon.org/2019/schedule/attachments/515_Patroni-training.pdf (also on SlideShare)
- **Summary:** Full-day training deck: architecture overview, first test cluster, dynamic config, REST endpoints/monitoring, advanced features, pg_rewind demo, troubleshooting.
- **Depth:** Very high — the most complete single Patroni teaching resource ever published.
- **Versions:** Patroni 1.6-era but architecture still current.
- **Why ranked #1:** Breadth + depth + hands-on; the reference training material.

### 2. "What is Patroni, really?" — POSETTE 2025
- **Speaker:** Polina Bungina (Zalando, Patroni co-maintainer)
- **Conference/Year:** POSETTE: An Event for Postgres 2025
- **URLs:** Slides https://speakerdeck.com/hugh0capet/what-is-patroni-really ; Video https://www.youtube.com/watch?v=9aWqnt9Uv74 ; Session https://posetteconf.com/2025/talks/what-is-patroni-really/
- **Summary:** Internals-focused: what Patroni writes to the DCS (`/config`, `/leader`, `/members`, `/status`, `/sync`, `/failover`, `/history`), the HA loop, synchronous mode, quorum-based failover, DCS failsafe, Citus, `pending restart` handling and `max_connections` propagation.
- **Depth:** Very high and current.
- **Versions:** Patroni 3.x/4.x.
- **Why ranked #2:** The most current maintainer-authored internals talk.

### 3. "Patroni in 2019: What's New and Future Plans" — PGConf.EU 2019 (and PGConf.ASIA 2019)
- **Speakers:** Alexander Kukushkin & Dmitrii Dolgov
- **Conference/Year:** PGConf.EU 2019 (Milan); PGConf.ASIA 2019 (Bali)
- **URL:** https://www.postgresql.eu/events/pgconfeu2019/sessions/session/2717/slides/218/
- **Summary:** Bot pattern, automatic failover, atomic CAS leader race, watchdog fencing, plus a roadmap slide foreshadowing quorum commit (issue #672) and native etcd v3.
- **Depth:** High.
- **Versions:** Patroni 1.6, PostgreSQL 12.
- **Why ranked #3:** Best historical anchor showing how the quorum/etcd-v3 features were conceived.

### 4. Cameron Murdoch — "Patroni: what the blog posts don't tell you…" — PGConf.EU 2025
- **Speaker:** Cameron Murdoch (University of Oslo)
- **Conference/Year:** PGConf.EU 2025 (Riga)
- **URLs:** Slides https://www.postgresql.eu/events/pgconfeu2025/sessions/session/7018/slides/771/patroni_talk_pgconf2025.pdf ; Video https://www.youtube.com/watch?v=jGtuxlbdY88
- **Summary:** The "missing manual" — etcd/DCS hardening, why you might *not* want Patroni, initial vs runtime config traps, proxy options (incl. libpq load balancing from PG16), failsafe, and backups through the proxy.
- **Depth:** High, operations-focused.
- **Versions:** Patroni 3.x/4.x; PostgreSQL 16+.
- **Why ranked #4:** Uniquely candid about real-world traps; complements the maintainer decks.

### 5. Michael Banck — "Patroni Deployment Patterns" — PGConf.EU 2024
- **Speaker:** Michael Banck (NetApp / credativ; Debian Patroni maintainer)
- **Conference/Year:** PGConf.EU 2024 (Athens)
- **URLs:** Slides https://www.postgresql.eu/events/pgconfeu2024/sessions/session/5892/slides/544/patroni-deployment-patterns.pdf ; Video https://www.youtube.com/watch?v=CJ3GxB4LUog ; also SCaLE 21x (2024) and PGDay Chicago 2023 variants
- **Summary:** Deployment topologies and their pitfalls — sync standbys/read replicas, standby clusters for multi-region, `member_slots_ttl`, client failover, load balancing with HAProxy.
- **Depth:** High.
- **Versions:** Patroni 3.3/4.0.
- **Why ranked #5:** Best structured treatment of deployment topology choices.

### 6. "Implementing failover of logical replication slots in Patroni" — PGConf.DE 2022
- **Speaker:** Alexander Kukushkin
- **Conference/Year:** PGConf.DE 2022
- **URL:** https://www.postgresql.eu/events/pgconfde2022/sessions/session/3745/slides/306/
- **Summary:** How Patroni copies logical slots, why logical events can be silently lost if a consumer lags, the REST health-check 503 gate, and the `pg_tm_aux` extension for creating slots "in the past." States the support baseline: Patroni 2.1.0+ (July 2021), PostgreSQL 11+.
- **Depth:** Very high — deepest public treatment of logical-slot failover mechanics.
- **Versions:** pre-PG17 semantics.
- **Why ranked #6:** Directly targets the hardest slot edge cases; pairs with issue #1749.

### 7. "Citus & Patroni: The Key to Scalable and Fault-Tolerant PostgreSQL" — Citus Con 2023
- **Speaker:** Alexander Kukushkin
- **Conference/Year:** Citus Con 2023
- **URLs:** Video https://www.youtube.com/watch?v=Mw8O9d0ez7E (also on Microsoft Learn)
- **Summary:** Implementation of Patroni↔Citus integration, coordinator/worker groups, worker switchover without dropping client connections, live demo.
- **Depth:** High.
- **Versions:** Patroni 3.0+ Citus support.
- **Why ranked #7:** The definitive talk on the Citus integration.

### 8. Ants Aasma — "Taming write latencies with Patroni quorum mode" — Nordic PGDay 2025
- **Speaker:** Ants Aasma (Cybertec)
- **Conference/Year:** Nordic PGDay 2025 (Copenhagen)
- **URL:** https://www.postgresql.eu/events/nordicpgday2025/schedule/session/6555-taming-write-latencies-with-patroni-quorum-mode/
- **Summary:** How Patroni 4's quorum replication mode stabilizes p99 write latency; practical configuration guidance.
- **Depth:** High (quorum-specific).
- **Versions:** Patroni 4.x; PostgreSQL 10+ quorum commit.
- **Why ranked #8:** One of the very few talks dedicated to the 4.x quorum feature; by its implementer.

### 9. Kukushkin — "Myths and Truths about Synchronous Replication in PostgreSQL" — POSETTE 2025
- **Speaker:** Alexander Kukushkin
- **Conference/Year:** POSETTE 2025
- **URL:** POSETTE 2025 talk listing (posetteconf.com); video via the POSETTE 2025 YouTube playlist
- **Summary:** Correct mental model for synchronous replication durability guarantees and how they interact with Patroni failover decisions.
- **Depth:** High.
- **Versions:** current.
- **Why ranked #9:** Directly relevant to the sync/quorum durability questions expert authors care about. (Exact slide/video URL should be retrieved from the POSETTE 2025 playlist.)

### 10. Stefan Fercot — "Patroni and pgBackRest: better together" — PGConf.EU 2025
- **Speaker:** Stefan Fercot (Data Egret)
- **Conference/Year:** PGConf.EU 2025 (Riga)
- **URL:** https://pgstef.github.io/talks/en/20251022_PGConfEU_Patroni-and-pgBackRest.pdf
- **Summary:** Integrating pgBackRest as a Patroni `create_replica_method`, WAL archiving, backups from replicas, PITR of a Patroni cluster.
- **Depth:** High, backup/restore-focused.
- **Versions:** current.
- **Why ranked #10:** Best backup-integration talk from a pgBackRest maintainer.

### 11. "Patroni in 2019: What's New and Future Plans" (PGConf.ASIA 2019 Bali variant)
- **Speaker:** Alexander Kukushkin
- **Conference/Year:** PGConf.ASIA 2019 (Bali)
- **URL:** https://www.slideshare.net/Equnix/pgconfasia-2019-bali-patroni-in-2019-alexander-kukushkin
- **Summary:** Zalando-scale numbers (>1000 databases across k8s), PostgreSQL 12/IPv6 support, quorum commit and etcd v3 roadmap, split-brain avoidance.
- **Depth:** High.
- **Versions:** Patroni 1.6.
- **Why ranked #11:** Useful scale context and roadmap; the annotated SlideShare is easy to reference.

### 12. "KubeCon EU 2016: Full Automatic Database — PostgreSQL HA with Kubernetes"
- **Speaker:** Josh Berkus (with the later "Elephants on Automatic," Josh Berkus & Oleksii Kliukin, KubeCon Berlin 2017)
- **Conference/Year:** KubeCon EU 2016 / 2017
- **URL:** https://www.slideshare.net/kubecon/kubecon-eu-2016-full-automatic-database-postgresql-ha-with-kubernetes
- **Summary:** The original Patroni-on-Kubernetes vision — controller as PID 1, etcd as CA store, the proxy problem, pg_rewind, WAL-E PITR.
- **Depth:** Medium-high; historically important.
- **Versions:** early Patroni.
- **Why ranked #12:** Foundational Kubernetes-native Patroni talk; still-relevant proxy discussion.

### 13. "Patroni: Kubernetes-native PostgreSQL companion" — PGConf.APAC 2018
- **Speaker:** Alexander Kukushkin
- **Conference/Year:** PGConf.APAC 2018
- **URL:** https://slideshare.net/AlexanderKukushkin1/patroni-ha-postgresql-made-easy (related deck)
- **Summary:** Using the Kubernetes API itself as the DCS (leader election via endpoints/configmaps), eliminating the separate etcd dependency.
- **Depth:** Medium-high.
- **Versions:** Patroni 1.4/1.5.
- **Why ranked #13:** The clearest explanation of the Kubernetes-as-DCS mechanism.

### 14. "Patroni in 2019: What's New and Future Plans" — annotated deck (docplayer / SlideShare mirror)
- **Speaker:** Alexander Kukushkin
- **Conference/Year:** 2019
- **URL:** http://docplayer.net/167560822-Patroni-in-2019-what-s-new-and-future-plans-pgconf-eu-2019-milan.html
- **Summary:** Includes the "A good HA system: Quorum, Fencing, Watchdog" slide and the quorum-commit/etcd-v3 POC snippets.
- **Depth:** Medium.
- **Versions:** 2019-era.
- **Why ranked #14:** Handy quotable slides on the HA-primitives triad.

### 15. Lucio Grenzi — "Patroni: PostgreSQL HA in the cloud" — PGDay.IT 2017
- **Speaker:** Lucio Grenzi
- **Conference/Year:** PGDay.IT 2017
- **URL:** https://slideshare.net/lucio_grenzi/patroni-postgresql-ha-in-the-cloud
- **Summary:** Synchronous mode implementation rules, HAProxy single-endpoint config, failover/reattach mechanics.
- **Depth:** Medium.
- **Versions:** early Patroni.
- **Why ranked #15:** Good independent (non-maintainer) treatment of sync-mode rules.

*(Also noted: the PGConf.EU 2025 Patroni Community Summit — Kukushkin, Bungina, Ants Aasma on major-upgrade automation, strict-sync improvements, and primary/standby-cluster switching — wiki: https://wiki.postgresql.org/wiki/PGConf.EU_2025_Patroni_community_summit. It is a working session rather than a slide deck, but it signals the current roadmap.)*

---

## SECTION 3 — GAP ANALYSIS / BRAINSTORMING: UNDER-COVERED TOPICS FOR NEW ARTICLES

The overwhelming pattern in existing material: it is either (a) introductory setup tutorials (hundreds of these) or (b) maintainer talks that necessarily stay high-level. Deep, current, version-specific writing on Patroni 4.x internals and PostgreSQL 17/18 interaction is almost absent. For context, **Patroni 4.0.0 was released 2024-08-29** (it "completes work on getting rid of the 'master' term, in favor of 'primary'," and upgrading to 4.x is only reliable from Patroni 3.1.0+), and **Patroni 4.1.0 on 2025-09-23**; Patroni now supports "PostgreSQL versions 9.3 to 18." Below, grouped by the three requested angles, with why each is under-covered and what a new article could contribute.

### A. Production patterns (under-covered)

**A1. Patroni 4.x quorum synchronous replication — the internals nobody has written up.**
Why under-covered: existing material describes *that* quorum mode exists (docs, Aasma's talk) but nothing walks through the `patroni.quorum` module — the `QuorumStateResolver`, the strict-ordering invariant (increase `numsync` before decreasing `quorum`; decrease `quorum` after), `numsync_confirmed`, and how the `/sync` key transitions are serialized to prevent an async node winning the race. A new article could be *the* reference, with state-transition diagrams and failure-injection tests mapping DCS `/sync` contents to `synchronous_standby_names` across membership changes.

**A2. PostgreSQL 17 native failover slots (`sync_replication_slots`, `failover=true`) vs. Patroni's own slot copying.**
Why under-covered: PG17 introduced core slot synchronization (slotsync worker), which overlaps with — and can conflict with — Patroni's historical `slots:` copying. There is no authoritative guide on which mechanism to use under Patroni 4.x, migration, the `synchronized_standby_slots` GUC, and the multi-failover bug — **PostgreSQL BUG #18789, logged 2025-01-29 by Sachin Konde-Deshmukh: "We are using 2 node PostgreSQL 17 HA setup using Patroni 4.0.4. When I do failover 2nd or third time or more than once, it fails to transfer or move logical replication slot to new Primary"** (PG 17.2, Oracle Linux 8.9). A new article could define the decision matrix and document the interaction precisely.

**A3. PostgreSQL 18 async I/O and the background I/O worker under Patroni.**
Why under-covered: the Patroni 4.1.0 release notes state verbatim, "GUC's validator rules were extended. Patroni now properly handles the new background I/O worker," but no article connects `io_method` (worker/io_uring/sync), `io_workers`, `effective_io_concurrency` tuning to Patroni-managed clusters — e.g., how async I/O changes crash-recovery/replay timing, failover RTO, and process-count limits that can break startup. (Independent 2026 production benchmarks report ~2–3x cold-cache read gains and, on i4i NVMe, 35–40% throughput improvements — worth grounding a Patroni-specific piece in.) High-value, genuinely novel.

**A4. Observability of Patroni internals (not just "is it up").**
Why under-covered: most monitoring posts stop at `patroni_master`/replication lag. Patroni 4.0 enriched `/metrics` with PostgreSQL state; nobody has written a deep guide to instrumenting the HA loop itself — `loop_wait` cycle time, DCS request latency, `/sync` key churn, failsafe activations, `pending restart` propagation — and turning those into SLO alerts. Could include a Grafana dashboard and PromQL for leader-race and quorum-transition anomalies.

**A5. etcd v3-specific operational engineering for Patroni.**
Why under-covered: the docs say "prefer etcd3," and Crunchy covers disk latency, but there's no consolidated piece on etcd v3 for Patroni: v2→v3 migration, the etcd 3.6 / etcd3gw client confusion (GitHub discussion #3461), auth changes in etcd 3.6.9/3.5.28/3.4.42 that broke topology reads and lease keepalive without authentication (addressed in a recent Patroni release), compaction/defrag, and dedicated io2 volumes. A definitive "etcd for Patroni DBAs in 2026" article.

**A6. Citus + Patroni HA at scale beyond the demo.**
Why under-covered: Kukushkin's talk demos it; nobody documents day-2 operations — coordinator vs worker failover coordination, `pg_dist_node` secondary registration, rebalancing during failover, and monitoring a sharded HA cluster.

**A7. pgBackRest / WAL-G as `create_replica_method` — reseeding at scale.**
Why under-covered: Fercot's talk covers pgBackRest well, but there's little on the corner cases — delta restore as a reinit strategy for multi-TB replicas, avoiding full pg_basebackup storms after failover, and WAL-G specifics. A comparative WAL-G vs pgBackRest-under-Patroni piece would be new.

### B. Corner cases (under-covered)

**B1. Failsafe-mode partition math and its own failure modes.**
Why under-covered: docs explain the happy path, but real incidents (GitHub #2625: failsafe not triggering when a co-located node is lost; #3552: infinite etcd loop after failsafe when etcd returns; and a recent release-note fix "failsafe mode not being triggered in case of Etcd unavailability" because etcd3 exceptions weren't always handled) show subtle behavior. An article dissecting *when failsafe protects you and when it doesn't* — with the "primary must see ALL members" reasoning and the co-located-etcd anti-pattern — is missing.

**B2. Watchdog safety-margin engineering and clock skew.**
Why under-covered: everyone shows `modprobe softdog`; nobody rigorously analyzes the `ttl - safety_margin - loop_wait - retry_timeout` budget, the `safety_margin: -1` (ttl//2) guarantee, VM-pause/hypervisor-stall scenarios, and how NTP clock skew interacts with TTL expiry. Deep, quantitative treatment would be novel.

**B3. Split-brain scenarios catalogued and reproduced.**
Why under-covered: split-brain is mentioned everywhere but reproduced almost nowhere. An article that *builds* each split-brain path (DCS partition with stale primary, standby-cluster mis-promotion, `pg_ctl promote` bypassing Patroni) and shows how each protection layer catches it would be a landmark reference.

**B4. Synchronous replication "ghost data" under quorum commit.**
Why under-covered: Moppel's post opened this; nobody has extended it to Patroni 4.x quorum mode specifically — does quorum commit change the `canceling wait for synchronous replication` local-commit hazard? How should apps handle the warning? Where does 2PC fit? An expert-level durability article.

**B5. Failover during heavy WAL load / checkpoint interactions.**
Why under-covered: the Palark incident hints at it (CHECKPOINT_SHUTDOWN not reaching a node). A systematic study of failover behavior under write saturation — `maximum_lag_on_failover`, candidate selection when all replicas lag, and the interaction with PG18 async I/O replay — is absent.

**B6. Behavior during OOM and strict memory limits.**
Why under-covered: per the Patroni docs, "Recent Patroni releases (4.1.1+, 4.0.8+) reduce the impact of this issue by starting all required threads early during startup" — mitigating a Python 3.11+ thread-start hang under `vm.overcommit_memory=2`, with recommended `MALLOC_ARENA_MAX=1`, the default `thread_stack_size` of 512kB, and default `thread_pool_size` of 5. This is documented tersely but never explained in depth — what actually happens to the HA loop under memory pressure and how to tune it. Very practical, unwritten.

**B7. Pause/maintenance-mode subtleties.**
Why under-covered: pause mode disables the watchdog and changes slot/sync behavior (e.g., `/sync` not updated when renaming a leader in pause — fixed in 4.1.x; GUCs like `synchronous_standby_names` being discarded when restarting in pause). A "everything that changes in pause mode, and the traps" article would help experts running maintenance safely.

**B8. Cascading replication failover.**
Why under-covered: cascading (replica-of-replica) topologies and how Patroni re-parents cascade children on failover are barely documented outside standby-cluster context. Worth a dedicated treatment.

**B9. Race conditions in leader election / offline demotion.**
Why under-covered: release notes reveal real races (concurrent "offline" demotion during slow shutdown; stale checkpoint result reused on next promote; stale etcd node reads mitigated via `raft_term` comparison; timeline-increase after single-user crash recovery + promote triggering a pg_rewind check). An article walking the `Ha.run_cycle()` critical sections and the concurrency invariants would be genuinely deep and has no equivalent today.

### C. Speculative / novel architectures (under-covered)

**C1. Patroni multisite / automatic cross-DC failover.**
Why under-covered: standard Patroni requires *manual* promotion across two DCs. Cybertec maintains a "multisite" Patroni fork (confirmed via the `cybertec-postgresql/patroni-windows-packaging` GitHub releases, e.g. `v250418-multisite`: "PATRONI · multisite based on 4.0.5," bundled with Python 3.13.1, etcd 3.5.18, PostgreSQL 15.12) aiming at automatic site-level failover, but there's virtually no independent write-up. An article evaluating multisite vs. standby clusters vs. a third-site witness — and mapping onto Cybertec's own "Cluster options" whitepaper (Options 4/6/7/8: automatic DC failover with bias, cloud quorum, 3-DC, and DC quorum/distribution) — with the split-brain trade-offs, would be new and valuable. Treat the fork's capabilities as vendor-described until independently tested.

**C2. Patroni vs. CloudNativePG — an honest, deep comparison.**
Why under-covered: plenty of shallow operator comparisons exist; few engage with the architectural philosophy (CNPG's Instance Manager as a Go binary/PID 1 with no external DCS and Kubernetes-native leader election, vs. Patroni's DCS-based consensus — as argued in Gabriele Bartolini's May 2026 "CloudNativePG and Crunchy PGO" piece, noting Crunchy PGO delegates HA to Patroni while CNPG embeds nothing but PostgreSQL). An expert comparison of failure semantics, split-brain guarantees, and where Patroni could borrow ideas would stand out.

**C3. DCS-less / Raft-native Patroni futures.**
Why under-covered: Patroni's built-in Raft (pysyncobj) is deprecated-ish and lightly documented (pgstef's pure-Raft post is the main reference). A forward-looking article on DCS-less HA, comparing Patroni-on-Raft, CNPG's approach, and what a modern embedded-consensus Patroni could look like.

**C4. Patroni across hybrid cloud and edge.**
Why under-covered: essentially unwritten. Latency-tolerant quorum placement across on-prem+cloud, witness nodes in a third cloud, and edge scenarios (intermittent connectivity, failsafe behavior at the edge) are fertile speculative territory.

**C5. Borrowing from Pacemaker / repmgr / pg_auto_failover.**
Why under-covered: comparisons exist but rarely ask "what does Patroni lack that these have?" — e.g., Pacemaker's richer fencing/STONITH agents, pg_auto_failover's explicit two-node state machine and monitor (which handles the two-node case Patroni finds awkward), repmgr's simplicity. An article on concrete ideas Patroni could adopt (a better two-node story, richer fencing integrations) is missing.

**C6. AI-assisted failover analysis and post-incident forensics.**
Why under-covered: entirely open. An article on feeding Patroni logs, DCS history (`/history`), and WAL forensics into automated/LLM-assisted root-cause analysis of failover events — and the risks of AI-in-the-loop for promotion decisions — would be genuinely novel.

**C7. Patroni + PgDog / modern Rust proxies for read/write split during failover.**
Why under-covered: HAProxy/PgBouncer are covered to death; newer SQL-aware proxies (PgDog) and libpq client-side load balancing (PG16+) interacting with Patroni failover are barely written about. Worth a modern connection-routing article.

### Suggested prioritization for the author
Highest novelty + highest expert demand: **A1 (quorum internals), A2 (PG17 failover slots vs Patroni), A3 (PG18 async I/O), B9 (`run_cycle` race conditions), B1 (failsafe corner cases).** These are areas where the author's internals expertise is a genuine differentiator and where essentially no authoritative content exists. Second tier: **A4 (deep observability), B2/B4 (watchdog + ghost-data durability), C1 (multisite), C2 (Patroni vs CNPG).**

---

## Recommendations

**Stage 1 — Establish authority in the biggest gap (weeks 1–6).** Write the two flagship pieces that no one else has: (A1) "Inside Patroni 4.x quorum synchronous replication — the `QuorumStateResolver` and the `/sync` key," and (A2) "PostgreSQL 17 native failover slots vs. Patroni slot copying: which, when, and the multi-failover trap (BUG #18789)." Ground both in reproducible lab tests. Benchmark that changes the plan: if the maintainers publish an official quorum-internals deep-dive first, pivot A1 toward a comparative/operational angle instead of a from-scratch explainer.

**Stage 2 — Own PostgreSQL 18 + Patroni (weeks 6–10).** Publish (A3) the async-I/O/background-I/O-worker interaction piece with measured failover-RTO and replay-timing data on `io_uring` vs `worker` vs `sync`. This is time-sensitive: PG18 shipped 2025-09-25 and the field is wide open in early-to-mid 2026. Threshold: if a vendor (Percona/Cybertec/EDB) ships a definitive Patroni+PG18 guide, differentiate by focusing narrowly on crash-recovery/replay and process-limit failure modes rather than general tuning.

**Stage 3 — Corner-case series (weeks 10–20).** Ship a "Patroni failure modes, reproduced" series: B1 (failsafe partition math + co-located-etcd anti-pattern, citing issues #2625/#3552), B2 (watchdog safety-margin + clock skew), B9 (`run_cycle()` race conditions from the release-note fixes). Each should include a Docker/VM harness so readers can reproduce. These compound into a book-length reference and are the strongest demonstration of internals expertise.

**Stage 4 — Architecture/opinion pieces (weeks 20+).** Publish C2 (Patroni vs CloudNativePG, honest failure-semantics comparison) and C1 (multisite vs standby-cluster vs witness). These attract the widest readership and position the author in the current "is Patroni still the right choice on Kubernetes?" debate.

**Cross-cutting benchmarks that should change priorities:**
- If Patroni 4.2+ or a 5.0 ships with a reworked sync/quorum model or DCS-less mode, immediately re-scope A1/C3 to cover it — recency is the whole value proposition.
- If community demand (Slack #patroni, GitHub discussions, HN/Reddit threads) spikes on a specific pain point (etcd 3.6 compatibility, PG17 slot loss), pull the matching gap topic forward.
- Prefer topics where you can publish primary-source lab evidence; the existing corpus is saturated with tutorials and thin on reproducible internals testing — that is precisely the differentiator.

---

## Caveats
- Several high-value sources are primary artifacts (GitHub issues/PRs, release notes, conference PDFs) rather than polished articles; they are ranked on content quality, not production value.
- A few community/Medium articles in the article ranking are individually useful but vary in editorial rigor; they are ranked and flagged accordingly.
- Exact publication dates for some vendor blog posts and a few slide decks could not be pinned precisely; where uncertain this is indicated with "~".
- The Cybertec "multisite" Patroni feature is confirmed via the fork's packaging-repo release notes and branch names rather than a dedicated vendor article; treat its capabilities as vendor-described until independently tested.
- POSETTE 2025 slide/video URLs for Kukushkin's synchronous-replication talk were not individually captured; use the POSETTE 2025 YouTube playlist / posetteconf.com listing to retrieve the exact link.
- Patroni release facts are confirmed against the official release notes: **4.0.0 = 2024-08-29**, **4.1.0 = 2025-09-23**, supported PostgreSQL "9.3 to 18." The PG18 background-I/O-worker handling and the memory-pressure thread-start mitigations are quoted from the official docs/release notes.
- The gap analysis is a forward-looking editorial assessment of what is missing as of mid-2026; the "under-covered" judgments reflect the sources surveyed here and could be overtaken by new maintainer or vendor publications — verify novelty just before writing.