# Distributed Configuration Store (DCS) for PostgreSQL HA

This directory contains research papers and architectural surveys covering Distributed Configuration Stores used to maintain consensus and cluster topology in PostgreSQL High-Availability stacks.

## Contained Documents

*   **[Distributed Configuration Store Tools for PostgreSQL HA (PDF)](file:///home/josef/github.com/josmac69/postgresql_support_docs/Distributed_Configuration_Store_DCS/Distributed_Configuration_Store_Tools_for_PostgreSQL_HA__Technical_Survey_and_Ranking.pdf)**: An in-depth survey comparing and ranking DCS backends (`etcd v3`, `Consul`, `ZooKeeper`) on their network partition behavior, Raft consensus mechanics, lease TTL expirations, and API efficiency under Patroni management.
