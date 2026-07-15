# Patroni PostgreSQL High-Availability Lab & References

This directory contains configuration templates, automation scripts, and Docker orchestration files to stand up a containerized three-node Patroni PostgreSQL high-availability cluster with etcd as the Distributed Configuration Store (DCS). It also serves as a repository for deep-dive Patroni research reports.

## Lab Infrastructure & Automation

*   **[docker-compose.yml](file:///home/josef/github.com/josmac69/postgresql_support_docs/Patroni/docker-compose.yml)**: Defines the three Patroni nodes and the etcd backend container.
*   **[Dockerfile](file:///home/josef/github.com/josmac69/postgresql_support_docs/Patroni/Dockerfile)**: Custom container image containing Patroni, PostgreSQL, pgBackRest, and standard diagnostic tools.
*   **[entrypoint.sh](file:///home/josef/github.com/josmac69/postgresql_support_docs/Patroni/entrypoint.sh)**: Executable wrapper shell script to initialize Patroni nodes within containers.
*   **[Makefile](file:///home/josef/github.com/josmac69/postgresql_support_docs/Patroni/Makefile)**: Handles building the image, starting/stopping the cluster, viewing logs, and running diagnostics.
*   **[patroni.yml.template](file:///home/josef/github.com/josmac69/postgresql_support_docs/Patroni/patroni.yml.template)**: Base Patroni configuration file template defining the DCS settings, replication, and bootstrap rules.

## Guides & Deep-Dive Articles

*   **[Patroni Overview Guide](file:///home/josef/github.com/josmac69/postgresql_support_docs/Patroni/patroni_overview.md)**: Explains the internal mechanics of Patroni (heartbeats, leader elections, and dynamic configuration keys).
*   **[Patroni HA Technical Notes](file:///home/josef/github.com/josmac69/postgresql_support_docs/Patroni/patroni_notes.md)**: GUC parameters, replication slots failovers, and REST API commands.
*   **[Patroni Literature & Gap Analysis](file:///home/josef/github.com/josmac69/postgresql_support_docs/Patroni/articles/Patroni_Deep-Dive-_Top_Articles,_Top_Presentations,_and_a_Gap_Analysis_for_New_High-Quality_Writing.md)**: A survey of the best existing Patroni articles, conference slides, and white papers.
*   **[Patroni PostgreSQL HA Research Report (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/Patroni/articles/Patroni_PostgreSQL_HA_Research_Report.pdf)**: Expert research paper on high-availability design, RTO, and fence-device (watchdog) timing parameters.
