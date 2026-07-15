# PostgreSQL Reference Manuals & Playbooks

This directory contains technical guides, playbooks, checklists, and documentation sheets for auditing, tuning, and operating PostgreSQL databases.

## Master Index

### 1. Diagnostic Playbooks & Scenarios
*   **[Streaming Replication Diagnostic & Repair Playbook](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/PostgreSQL_Streaming_Replication_Diagnostic_&_Repair_Playbook_(PG_14–18).md)**: Step-by-step triage guide for fixing broken replication streams, split-brain conditions, and timeline mismatches.
*   **[Kubernetes Patroni vs VM HA Scenarios](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/Kubernetes-Patroni_and_VM-based_HA_scenarios.md)**: Details on running Patroni clusters inside Kubernetes (Percona Operator) versus standard bare-VM architectures.
*   **[Replication Health Playbook (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/PostgreSQL_Replication_Health_Playbook.pdf)**: Comprehensive guide on keeping replication streams synchronized.

### 2. Workload & Performance Profiling
*   **[pg_stat_monitor Practitioner's Guide](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/pg_stat_monitor-_Installation_and_Practitioner's_Guide_for_Finding_Problematic_PostgreSQL_Workloads_(PostgreSQL_14–18).md)**: Complete guide on installing and utilizing EDB/Percona's `pg_stat_monitor` extension for deep query analytics.
*   **[pg_stat_statements Field Manual](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/pg_stat_statements_for_Finding_and_Diagnosing_Problematic_Workloads_(PostgreSQL_14–18)-_A_Practitioner's_Field_Manual.md)**: standard manual for debugging queries with `pg_stat_statements`.
*   **[pg_stat_statements Workload Analysis Guide](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/PostgreSQL_pg_stat_statements_Workload_Analysis.md)**: Explains statement statistics calculations and query plans.
*   **[Query Performance & Configuration](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/postgresql_14-18_query_performance_config.md)**: Optimal settings for planners, parallel workers, and index structures.

### 3. Cheat Sheets & Reference Guides
*   **[psql Cheat Sheet (PG 14–18)](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/psql_Cheat_Sheet_-_PostgreSQL_14_to_18.md)**: Common command-line syntax, meta-commands, session views, and database information queries.
*   **[Directories & Paths Cheat Sheet](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/postgresql_directories.md)**: Layout reference for locating binaries, log files, data directories (`PGDATA`), and configurations across different operating systems.
*   **[PostgreSQL Extensions Field Reference](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/PostgreSQL_Extensions_-_Field_Reference_(PG_15-18).md)**: Overview of extension support matrix (PGSM, TimescaleDB, PostGIS, pg_partman, pgvector) across PG 15–18.
*   **[Binary Executables Reference](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/postgresql_binaries.md)**: A catalog of all core PostgreSQL binary utilities (such as `pg_ctl`, `pg_basebackup`, `pg_rewind`, `pg_upgrade`, and `pg_dump`).
*   **[Linux & OS Tuning for PostgreSQL](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/postgresql_linux_tuning.md)**: Key GUC configurations linked to Linux virtual memory, shared memory (shm), and filesystem mounts.

### 4. Technical Subdirectories
*   **[Autovacuum & Relation Bloat](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/autovacuum/)**:
    *   [Autovacuum Tuning Guide (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/autovacuum/PostgreSQL_Autovacuum_Tuning__Expert_Reference_for_Versions_14_through_18.pdf)
    *   [Autovacuum Query Playbook (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/autovacuum/autovacuum_query_playbook.md.pdf)
*   **[Query Executor Architecture](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/executor/)**:
    *   [Evolution of the Query Executor](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/executor/The_Evolution_of_the_PostgreSQL_Query_Executor-_From_POSTGRES_(Berkeley)_to_PostgreSQL_18.md)
    *   [Tuple-by-tuple Execution in PG 18](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/executor/Tuple-by-tuple_execution_in_PostgreSQL_18.md)
    *   [Robert Haas: Braces are Too Expensive (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/executor/Robert_Haas__Braces_Are_Too_Expensive.pdf)
*   **[pg_createsubscriber Deep-Dive](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/pg_createsubscriber/)**:
    *   [pg_createsubscriber Source Code Deep-Dive](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/pg_createsubscriber/pg_createsubscriber_in_PostgreSQL_18_(REL_18_STABLE)-_A_Source-Level_Technical_Deep_Dive.md)
    *   [pg_createsubscriber GUC Settings & Execution](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/pg_createsubscriber/pg_createsubscriber.md)
*   **[pg_resetwal Triage](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/pg_resetwal/)**:
    *   [pg_resetwal Command Reference & Risks](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/pg_resetwal/pg_resetwal.md)
*   **[PostgreSQL Upgrades](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/upgrades/)**:
    *   [Upgrading Across Multiple PostgreSQL Major Versions](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/upgrades/upgrades.md)
*   **[PostgreSQL 19 Roadmap Features](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/PostgreSQL19/)**:
    *   [PostgreSQL 19 Beta Features & Parallel Autovacuum (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/PostgreSQL19/PostgreSQL_19_Beta_New_Features__Parallel_Autovacuum,_REPACK_&_More___JusDB_Blog.pdf)
    *   [PostgreSQL 19 Extensions Support](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/PostgreSQL19/PostgreSQL19-extensions.md)
    *   [PostgreSQL 19 Features Part 1](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/PostgreSQL19/PostgreSQL19-features-1.md)
    *   [Fujitsu & PostgreSQL 19 Architecture](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/PostgreSQL19/PostgreSQL19-Fujitsu.md)

### 5. Template & Scaffolding Resources
*   **[Report Template](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/01_report_template.md)**: Standard template for writing database audit reports.
*   **[Clarifying Questions Guide](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/02_clarifying_questions.md)**: Questions to ask clients before starting major operations.
*   **[Sysadmin Cheat Sheet](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/04_sysadmin_cheatsheet.md)**: Basic commands for checking system space, services, and connectivity.
*   **[Reference Links Collection](file:///home/josef/github.com/josmac69/postgresql_support_docs/PostgreSQL/links.md)**: External links to official docs and PostgreSQL blogs.
