# Barman for PostgreSQL: Architecture & Operations Documentation

This directory contains technical manuals, guides, and specifications for EDB/2ndQuadrant Barman (Backup and Recovery Manager) for PostgreSQL.

## Contained Documents

*   **[Barman for PostgreSQL: Deep Technical Architecture Report (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/Barman/Barman_for_PostgreSQL__Deep_Technical_Architecture_and_Operations_Report.pdf)**: An architectural deep-dive into remote backups, WAL streaming, and backup metadata retention.
*   **[Barman for the Experienced PostgreSQL DBA (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/Barman/docs/Barman_for_the_Experienced_PostgreSQL_DBA__2026_Orientation_and_Operational_Guide.pdf)**: Detailed administrator's orientation covering configuration files, recovery commands, cron jobs, and recovery catalog management.
*   **[PostgreSQL 18 pg_receivewal Documentation (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/Barman/docs/PostgreSQL__Documentation__18__pg_receivewal.pdf)**: The official manual for `pg_receivewal`, which Barman utilizes to stream WAL transactions in real-time to prevent data loss.
