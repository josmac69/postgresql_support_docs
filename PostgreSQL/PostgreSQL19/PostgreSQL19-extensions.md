# PostgreSQL 19 - extensions

The newest production-ready [PostgreSQL](https://www.postgresql.org/) extensions for 2025 and 2026 are primarily focused on AI integration, vector scalability, and query optimization.
The most significant arrival is the "AI Stack" (pgai and pgvectorscale), which transforms PostgreSQL into a production-grade AI platform, eliminating the need for separate vector databases like Pinecone. [1, 2, 3, 4, 5]
## 1. Top New AI & Vector Extensions (Production Ready)
These extensions matured significantly in 2025 and are now considered standard for modern AI workloads in 2026.

* [pgai](https://github.com/timescale/pgai)
* Status: Production Ready (v1.0+ released 2025).
   * What it does: Brings AI workflows directly inside the database. Instead of managing Python scripts to sync data with an external vector DB, pgai lets you create embeddings, interact with LLMs (OpenAI, Anthropic, Ollama), and perform RAG (Retrieval-Augmented Generation) tasks using simple SQL functions.
   * Why it's new: It solves the "data sync" problem by automating the vectorization of your data as it changes.
   * Key Feature: select ai.openai_embed('text-embedding-3-small', 'hello world'); [6, 7, 8, 9]
* [pgvectorscale](https://github.com/timescale/pgvectorscale)
* Status: Production Ready (Adopted for high-scale workloads in late 2025).
   * What it does: A complement to pgvector that makes vector search faster and cheaper at scale. It introduces a new index type (StreamingDiskANN) inspired by Microsoft's research, allowing you to store massive vector datasets on cheaper disk storage (NVMe) rather than expensive RAM, without sacrificing search speed.
   * Performance: Can outperform specialized vector databases in cost-efficiency and latency for datasets with millions of vectors. [10, 11, 12, 13, 14]

## 2. Operational & Security Extensions
New tools that have become essential for "Day 2" operations in 2026.

* [pg_auth_mon](https://github.com/RafiaSabih/pg_auth_mon)
* Status: Production Ready (Widely adopted in 2026 security audits).
   * What it does: Provides detailed monitoring of authentication attempts. Unlike standard logs, it aggregates data to help you spot brute-force attacks, identify unused user accounts, and audit access patterns without parsing massive text log files.
   * Why it's important: Essential for meeting stricter compliance standards (GDPR, SOC2) in 2026. [1]
* [pg_profile](https://github.com/zubkov-andrei/pg_profile) (Updated)
* Status: Production Ready.
   * What it does: While not "brand new," it has seen major adoption as the standard open-source alternative to Oracle's AWR. It takes periodic snapshots of pg_stat_statements and other metrics to let you "time travel" and see why the database was slow yesterday at 3 PM. [15, 16, 17, 18, 19]

## 3. Coming Soon (PostgreSQL 19 - Late 2026)
The following are technically "contrib modules" (bundled extensions) debuting with PostgreSQL 19, which is currently in Beta (June 2026) and expected for General Availability (GA) in September/October 2026. [20, 21, 22, 23, 24]

* pg_plan_advice (New in PG 19)
* Status: Beta (Coming to production late 2026).
   * The Big Deal: Finally adds official Query Hints to PostgreSQL. It allows DBAs to "lock in" a specific execution plan or guide the planner (e.g., "force a nested loop join") without changing the application code. It resolves a 15-year community debate about plan stability. [20, 25, 26, 27, 28]
* pg_stash_advice
* Status: Beta.
   * Function: Works with pg_plan_advice to store these hints persistently, so they survive server restarts and apply automatically when a specific query ID is seen. [29, 30]

## Summary of the 2026 Ecosystem

| Extension | Category | Best Use Case |
|---|---|---|
| pgai | AI / ML | Building RAG apps; calling LLMs from SQL. |
| pgvectorscale | AI / ML | Storing 50M+ vectors efficiently on disk. |
| pg_auth_mon | Security | detecting failed logins & auditing user access. |
| pg_plan_advice | Performance | Fixing "bad plan" regressions (Available late 2026). |


[1] [https://www.linkedin.com](https://www.linkedin.com/pulse/tiger-data-newsletter-jan-14-28-tigerdata-lxqre)
[2] [https://liambx.com](https://liambx.com/blog/postgresql-timescale-vector-ai-guide)
[3] [https://thenewstack.io](https://thenewstack.io/why-ai-workloads-are-fueling-a-move-back-to-postgres/)
[4] [https://news.ycombinator.com](https://news.ycombinator.com/item?id=47589856)
[5] [https://www.tigerdata.com](https://www.tigerdata.com/blog/postgres-extensions-cheat-sheet)
[6] [https://cloud.google.com](https://cloud.google.com/blog/products/databases/announcing-vector-support-in-postgresql-services-to-power-ai-enabled-applications)
[7] [https://www.youtube.com](https://www.youtube.com/watch?v=8oTnUtFYAes)
[8] [https://github.com](https://github.com/timescale/pgai)
[9] [https://liambx.com](https://liambx.com/blog/postgresql-timescale-vector-ai-guide)
[10] [https://www.tigerdata.com](https://www.tigerdata.com/docs/get-started/news/new)
[11] [https://www.dbvis.com](https://www.dbvis.com/thetable/pgvectorscale-an-extension-for-improved-vector-search-in-postgres/)
[12] [https://www.tigerdata.com](https://www.tigerdata.com/blog/how-we-made-postgresql-the-best-vector-database)
[13] [https://github.com](https://github.com/timescale/pgvectorscale)
[14] [https://www.tigerdata.com](https://www.tigerdata.com/blog/pgvector-is-now-as-fast-as-pinecone-at-75-less-cost)
[15] [https://github.com](https://github.com/zubkov-andrei/pg_profile)
[16] [https://www.wondermentapps.com](https://www.wondermentapps.com/blog/oracle-vs-postgresql/)
[17] [https://www.baremon.eu](https://www.baremon.eu/database-trends-of-2025/)
[18] [https://www.tigerdata.com](https://www.tigerdata.com/blog/its-2026-just-use-postgres)
[19] [https://stormatics.tech](https://stormatics.tech/blogs/enhancing-postgresql-performance-monitoring-a-comprehensive-guide-to-pg_stat_statements)
[20] [https://www.postgresql.org](https://www.postgresql.org/download/products/6-postgresql-extensions/)
[21] [https://www.bytebase.com](https://www.bytebase.com/blog/postgres-19-features-im-excited-about/)
[22] [https://neon.com](https://neon.com/postgresql/postgresql-19-new-features)
[23] [https://www.postgresql.org](https://www.postgresql.org/about/press/faq/)
[24] [https://tomasz-gintowt.medium.com](https://tomasz-gintowt.medium.com/unlocking-postgresql-performance-insights-with-pg-wait-sampling-e951f4913e3e)
[25] [https://neon.com](https://neon.com/postgresql/postgresql-19-new-features)
[26] [https://medium.com](https://medium.com/@the_atomic_architect/postgresql-19-quietly-fixes-the-kind-of-database-problems-that-wake-engineers-up-at-3-am-73214a5421f9)
[27] [https://yandex.cloud](https://yandex.cloud/en/docs/managed-postgresql/concepts/settings-list)
[28] [https://www.pgedge.com](https://www.pgedge.com/blog/looking-forward-to-postgres-19-query-hints)
[29] [https://neon.com](https://neon.com/postgresql/postgresql-19-new-features)
[30] [https://www.linkedin.com](https://www.linkedin.com/posts/christophe-pettus_e1release-19-activity-7473782495541600256-kD3g)
