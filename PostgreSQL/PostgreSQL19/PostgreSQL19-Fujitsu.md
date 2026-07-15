# PostgreSQL 19 - Fujitsu contributions

The engineering team at Fujitsu (alongside the open-source community) has proposed design blueprints for logical DDL replication, but native DDL replication did not land as a completed feature in PostgreSQL 19. [1, 2]
However, Fujitsu heavily drove and contributed to several major logical replication upgrades that did make it into PostgreSQL 19 (which entered Beta in June 2026). These features drastically reduce the operational friction of setting up and managing a replication pipeline: [3, 4, 5]
## 1. Online wal_level Changes (No Restarts)
Historically, enabling logical replication required changing the configuration to wal_level = logical and triggering a full database server restart. [6, 7]

* The Fujitsu Update: Co-designed and tested by Fujitsu, PostgreSQL 19 introduces online wal_level switching.
* How it works: The engine dynamically promotes the effective WAL level to logical on-demand as soon as a replication slot is created, and scales it back down to replica when the last slot is dropped. This eliminates planned downtime entirely when initializing replication. [5, 8]

## 2. Native Sequence Synchronization
Before version 19, logical replication completely ignored sequences (like BIGSERIAL auto-increments), requiring manual scripting or extensions during zero-downtime upgrades so the subscriber wouldn't reuse IDs. [9, 10]

* The Fujitsu Update: Fujitsu helped design and implement native sequence synchronization.
* How it works: You can now execute CREATE PUBLICATION ... FOR ALL SEQUENCES;. Under the hood, a new sequencesync worker coordinates with the publisher to seamlessly fetch and pull sequence values forward. [9, 11, 12, 13]

## 3. "FOR ALL TABLES EXCEPT" Clauses
Building large-scale publications used to be an all-or-nothing game, or required manually maintaining a tedious string of individual table names.

* The Fujitsu Update: Code contributions allow developers to specify a blanket publication with targeted exclusions.
* How it works: You can declare syntax such as CREATE PUBLICATION my_pub FOR ALL TABLES EXCEPT (table_a, table_b);, drastically simplifying data-filtering rules across complex schemas. [14, 15]

## 4. Advanced Conflict Resolvers
In bidirectional or multi-master replication topologies, data collisions (e.g., an insert with the same primary key occurring on two nodes simultaneously) are common.

* The Fujitsu Update: Built-in, configurable conflict handlers reduce user intervention.
* How it works: You can specify custom action strategies on the subscription level using syntax like CREATE SUBSCRIPTION ... CONFLICT RESOLVER (conflict_type1 = resolver1); to automatically resolve discrepancies. [16]

## Summary of Where DDL Replication Stands
Fujitsu's community patches (such as adding a WITH (ddl = 'table') parameter to publications) are still heavily discussed and actively reviewed for future versions. If automatic DDL replication is an immediate, non-negotiable requirement for your tech stack today, you will still want to evaluate pgEdge (which utilizes event triggers for auto-DDL) or Fujitsu's proprietary enterprise downstream product, Fujitsu Enterprise Postgres. [2, 17, 18]

[1] [https://wiki.postgresql.org](https://wiki.postgresql.org/images/d/dd/20230602-DDL_Replication.pdf)
[2] [https://postgresql.us](https://postgresql.us/events/pgconfus2025/sessions/session/2015/slides/213/LR_Evolution.pdf)
[3] [https://neon.com](https://neon.com/postgresql/postgresql-19/breaking-changes)
[4] [https://www.bytebase.com](https://www.bytebase.com/blog/postgres-19-features-im-excited-about/)
[5] [https://www.linkedin.com](https://www.linkedin.com/posts/shveta-malik_excited-to-share-my-blog-post-on-a-postgresql-activity-7462333453821423616-sltK)
[6] [https://neon.com](https://neon.com/postgresql/postgresql-19/logical-replication-improvements)
[7] [https://www.jusdb.com](https://www.jusdb.com/blog/postgresql-19-beta-new-features-dba-guide)
[8] [https://www.postgresql.fastware.com](https://www.postgresql.fastware.com/blog/online-wal-level-change-for-logical-decoding-in-postgresql-19)
[9] [https://conf.pgdu.org](https://conf.pgdu.org/system/events/document/000/002/629/PGDU-2025-Vignesh-PostgreSQL_Internals_Uncovered_Enhancing_Logical_Replication_and_Introducing_Columnar_Indexing_Final.pdf)
[10] [https://neon.com](https://neon.com/postgresql/postgresql-19/logical-replication-improvements)
[11] [https://www.postgresql.fastware.com](https://www.postgresql.fastware.com/blog/closing-a-critical-gap-in-postgresql-upgrade-workflows-with-sequence-synchronization)
[12] [https://www.bytebase.com](https://www.bytebase.com/blog/postgres-19-feature-preview-logical-replication-sequence/)
[13] [https://www.bytebase.com](https://www.bytebase.com/blog/postgres-19-features-im-excited-about/)
[14] [https://www.postgresql.fastware.com](https://www.postgresql.fastware.com/blog/topic/database-replication)
[15] [https://www.postgresql.fastware.com](https://www.postgresql.fastware.com/blog/topic/database-replication)
[16] [https://conf.pgdu.org](https://conf.pgdu.org/system/events/document/000/002/629/PGDU-2025-Vignesh-PostgreSQL_Internals_Uncovered_Enhancing_Logical_Replication_and_Introducing_Columnar_Indexing_Final.pdf)
[17] [https://wiki.postgresql.org](https://wiki.postgresql.org/images/d/dd/20230602-DDL_Replication.pdf)
[18] [https://www.youtube.com](https://www.youtube.com/watch?v=YYePeV4RDH8&t=26)
