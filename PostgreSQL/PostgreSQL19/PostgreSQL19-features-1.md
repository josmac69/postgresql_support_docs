# PostgreSQL 19 - Features and improvements (1)

PostgreSQL 19 is an operationally focused release that bridges the gap between relational databases and modern developer needs. Entering its Beta 1 phase on June 4, 2026, the upcoming engine shifts focus toward reducing production maintenance windows, stabilizing query planning, and adding native graph capabilities. The official General Availability (GA) release is expected around September or October 2026. [1, 2, 3, 4, 5, 6, 7]
Here are the most important feature highlights coming to PostgreSQL 19:
## 🛠️ Production Maintenance & DBA Safeguards

* In-Core REPACK CONCURRENTLY: Rebuilds bloated tables entirely online without acquiring heavy access-exclusive locks. This brings the functionality of the popular pg_repack extension natively into the core engine. [8, 9]
* Parallel Autovacuuming: Expands multi-index table processing by allowing VACUUM tasks to scale across multiple CPU cores, resolving a major single-core performance bottleneck. [2, 3, 5, 9, 10]
* 64-bit MultiXactOffset: Replaces the historical 32-bit MultiXact ceiling. This effectively eliminates the 4-billion-member transaction wraparound risk that previously caused hard crashes on highly concurrent, row-locking workloads. [3, 11, 12]
* Online Checksum Toggling: Enables DBAs to turn data integrity checksums on or off dynamically without needing a cluster restart. [9, 13]

## 📉 Query Planning & Performance Enhancements

* pg_plan_advice (Query Hints): Closes a decades-long community debate by introducing native path-generation strategy overrides. This allows developers to influence query plans and enforce repeatable execution paths without hardcoding brittle query comments. [8, 14, 15, 16, 17]
* Eager Aggregation Optimization: Adjusts optimizer strategy to optionally "aggregate first and join later". This drastically cuts down nested loop iterations by running group-by tasks before resolving expensive relational joins. [18]
* 2x Faster Foreign-Key Inserts: Introduces deep engine-level optimizations that double write throughput for tables constrained by heavily cross-referenced foreign keys. [5, 19]
* Reduced EXPLAIN ANALYZE Overhead: Leverages low-level hardware instructions (RDTSC on x86-64 CPUs) to grab high-speed timestamps, removing the synthetic performance penalties usually caused by benchmarking deep queries. [1, 7]

## 💻 Developer Experience & Syntax Expansion

* Native Graph Queries (SQL/PGQ): Incorporates the newer SQL:2023 standard directly into core Postgres. Developers can run property graph queries on standard relational tables without deploying standalone graph databases.
* Atomic ON CONFLICT DO SELECT: Simplifies the native "get-or-create" workflow. It yields roughly a 4x throughput increase over historical user-space loop workarounds by safely returning rows when unique constraints conflict.
* GROUP BY ALL: Eliminates tedious SQL boilerplate by letting the planner automatically detect and cluster all non-aggregated columns.
* Temporal Data Support: Finishes implementing SQL:2011 standard temporal operators (e.g., FOR PORTION OF), paving the way for native bitemporal tables and historical audit logs. [2, 6, 8, 9, 11, 19]

## 🔄 Replication & Observability

* Sequence Values in Logical Replication: Fixes a notorious pain-point for blue-green database migrations by synchronizing dynamic sequence state across publishers and subscribers.
* WAIT FOR LSN Consistency: Implements explicit log sequence number waiting blocks. Applications can enforce strict "read-your-writes" absolute consistency by forcing read replicas to finish replaying specific transactions before returning data.
* Enhanced System Visibility: Introduces the pg_stat_lock system view to aggregate historical, per-lock-type wait statistics for pinpointing fine-grained application lock contention. [4, 5, 6, 8, 9]

## ⚠️ Significant Default Shifts & Breaking Changes
Before organizing an upgrade path to PostgreSQL 19, keep these default behavioral shifts in mind:

* JIT Compiled Off: Just-In-Time (JIT) compilation is now turned off by default because it frequently harmed standard OLTP workloads more than it helped them.
* LZ4 TOAST Compression: The database transitions away from pg_lz toward faster lz4 compression out of the box for handling oversized table columns.
* Security Tightening: Direct RADIUS authentication has been fully removed, and the server now throws strong deprecation warnings when handling legacy MD5-hashed passwords. [5, 20, 21, 22, 23]


[1] [https://www.youtube.com](https://www.youtube.com/watch?v=4EgdLMxkCrE&t=5)
[2] [https://neon.com](https://neon.com/postgresql/postgresql-19-new-features)
[3] [https://www.bytebase.com](https://www.bytebase.com/blog/postgres-19-features-im-excited-about/)
[4] [https://www.postgresql.org](https://www.postgresql.org/about/news/postgresql-19-beta-1-released-3313/)
[5] [https://www.jusdb.com](https://www.jusdb.com/blog/postgresql-19-beta-new-features-dba-guide)
[6] [https://x.com](https://x.com/alxshp/article/2065094274799296684)
[7] [https://www.developersdigest.tech](https://www.developersdigest.tech/blog/postgres-19-beta-features)
[8] [https://www.devart.com](https://www.devart.com/blog/postgresql-19-release.html)
[9] [https://reptile.haus](https://reptile.haus/journal/postgresql-19-beta-what-development-teams-need-to-know-2026/)
[10] [https://neon.com](https://neon.com/postgresql/postgresql-19/parallel-autovacuum)
[11] [https://daily.dev](https://daily.dev/posts/hdcgv9gq5)
[12] [https://www.infoq.com](https://www.infoq.com/news/2026/06/postgresql-19-graph-queries/)
[13] [https://www.postgresql.org](https://www.postgresql.org/about/news/postgresql-19-beta-1-released-3313/)
[14] [https://www.youtube.com](https://www.youtube.com/watch?v=QLb3nhIy2Lc&t=3)
[15] [https://www.pgedge.com](https://www.pgedge.com/blog/looking-forward-to-postgres-19-query-hints)
[16] [https://www.pgedge.com](https://www.pgedge.com/blog/looking-forward-to-postgres-19-query-hints)
[17] [https://neon.com](https://neon.com/postgresql/postgresql-19/pg-plan-advice)
[18] [https://www.cybertec-postgresql.com](https://www.cybertec-postgresql.com/en/super-fast-aggregations-in-postgresql-19/)
[19] [https://www.youtube.com](https://www.youtube.com/watch?v=sMRI_MP58i0)
[20] [https://www.cybertec-postgresql.com](https://www.cybertec-postgresql.com/en/cybertecs-contributions-to-postgresql-19/)
[21] [https://neon.com](https://neon.com/postgresql/postgresql-19/breaking-changes)
[22] [https://www.postgresql.org](https://www.postgresql.org/docs/19/release-19.html)
[23] [https://www.postgresql.org](https://www.postgresql.org/about/news/postgresql-19-beta-1-released-3313/)
