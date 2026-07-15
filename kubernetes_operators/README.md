# Kubernetes Operators for PostgreSQL

This directory contains architectural reviews, source-level comparisons, and operational guides for running PostgreSQL inside Kubernetes clusters using modern operator designs.

## Contained Documents

*   **[CloudNativePG: Deep Technical Analysis (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/kubernetes_operators/CloudNativePG__Deep_Technical_Analysis_of_the_Kubernetes-Native_PostgreSQL_Operator.pdf)**: Expert analysis of CloudNativePG (CNPG) controller design, declarative backups, reconciliation loops, and native WAL archiving features.
*   **[CloudNativePG vs. Percona Operator for PostgreSQL (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/kubernetes_operators/CloudNativePG_vs._Percona_Operator_for_PostgreSQL__A_Deep_Architectural_and_Source-Level_Comparison.pdf)**: A source-level architectural comparison mapping differences in failover strategies (Patroni-based vs. Kubernetes native reconciliation), replication mechanisms, local storage persistence, and backup orchestration.
