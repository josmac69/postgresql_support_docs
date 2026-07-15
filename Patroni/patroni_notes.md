

[What is a Patroni cluster and how does it work?](https://serverspace.io/support/help/what-is-a-patroni-cluster-and-how-does-it-work/)
[GitHub - patroni/patroni: A template for PostgreSQL High ...](https://github.com/patroni/patroni)
[PostgreSQL High Availability and Patroni - an Introduction.](https://www.cybertec-postgresql.com/en/postgresql-high-availability-and-patroni-an-introduction/)
[Einrichten eines hochverfügbaren PostgreSQL-Clusters mit ...](https://proventa.de/einrichten-eines-hochverfuegbaren-postgresql-clusters-mit-patroni-unter-verwendung-eines-spilo-images/)
[Sicherstellung der Hochverfügbarkeit mit Patroni: Umgang mit ...](https://proventa.de/sicherstellung-der-hochverfuegbarkeit-mit-patroni-umgang-mit-failover/)
[PostgreSQL 18 High Availability Cluster Setup using Patroni ...](https://www.youtube.com/watch?v=rZW_wwchdL4)
[Patroni : Setting up a highly available PostgreSQL Cluster ...](https://www.cybertec-postgresql.com/en/patroni-setting-up-a-highly-available-postgresql-cluster/)

patronictl is the official command-line interface (CLI) tool for Patroni, used to monitor, manage, and configure PostgreSQL high-availability database clusters. It interacts directly with the Patroni REST API and the Distributed Consensus Store (DCS) like etcd or Consul. [1, 2, 3, 4, 5]
To execute commands, you must provide your cluster configuration file:
patronictl -c /path/to/patroni.yml <command>
## Essential Commands## Cluster Monitoring

* list: Displays the overall status, role, and replication lag of all database nodes.
* topology: Shows the cluster layout and the specific state of the DCS.
* history: Provides a detailed timeline of past failovers and timeline switches. [6, 7, 8, 9, 10]

## Operational Control

* restart: Reboots a specified cluster node or the entire cluster safely.
* reload: Refreshes node configurations without requiring a full database restart.
* pause: Suspends automatic failovers, allowing you to perform manual system maintenance safely.
* resume: Unpauses the cluster to hand back automatic failover orchestration to Patroni. [11, 12, 13, 14, 15]

## Failover & Replication Management

* failover: Triggers a manual failover to promote a replica to primary immediately.
* switchover: Schedules a graceful master migration to a designated replica node.
* reinit: Reinitializes a broken or desynchronized replica node from scratch. [16, 17, 18, 19]

## Cluster Configuration

* edit-config: Opens an interactive YAML editor to dynamically modify live cluster parameters.
* show-config: Prints the active configuration options currently evaluated by the DCS. [20, 21]

Would you like specific examples of how to format a manual switchover or how to safely pause a cluster for system updates?

[1] [https://patroni.readthedocs.io](https://patroni.readthedocs.io/en/latest/patronictl.html)
[2] [https://patroni.readthedocs.io](https://patroni.readthedocs.io/en/latest/modules/patroni.ctl.html)
[3] [https://www.postgresql.eu](https://www.postgresql.eu/events/pgconfeu2024/sessions/session/5892/slides/544/patroni-deployment-patterns.pdf)
[4] [https://www.cybertec-postgresql.com](https://www.cybertec-postgresql.com/en/patroni-cascading-replication-with-stanby-cluster/)
[5] [https://www.cybertec-postgresql.com](https://www.cybertec-postgresql.com/en/patroni-setting-up-a-highly-available-postgresql-cluster/)
[6] [https://github.com](https://github.com/patroni/patroni/issues/2641)
[7] [https://pigsty.io](https://pigsty.io/docs/pgsql/admin/patroni/)
[8] [https://blog.stackademic.com](https://blog.stackademic.com/zero-downtime-postgresql-building-highly-available-clusters-65e0d74d77dc)
[9] [https://www.cybertec-postgresql.com](https://www.cybertec-postgresql.com/en/updating-postgresql-parameters-in-kubernetes-and-other-systems/)
[10] [https://patroni.readthedocs.io](https://patroni.readthedocs.io/en/latest/releases.html)
[11] [https://bootvar.com](https://bootvar.com/useful-patroni-commands/)
[12] [https://pigsty.io](https://pigsty.io/docs/pgsql/admin/patroni/)
[13] [https://blog.stackademic.com](https://blog.stackademic.com/zero-downtime-postgresql-building-highly-available-clusters-65e0d74d77dc)
[14] [https://patroni.readthedocs.io](https://patroni.readthedocs.io/en/latest/patronictl.html)
[15] [https://www.percona.com](https://www.percona.com/blog/patroni-the-key-postgresql-component-for-enterprise-high-availability/)
[16] [https://blog.stackademic.com](https://blog.stackademic.com/zero-downtime-postgresql-building-highly-available-clusters-65e0d74d77dc)
[17] [https://medium.com](https://medium.com/@dickson.gathima/building-a-highly-available-postgresql-cluster-with-patroni-etcd-and-haproxy-1fd465e2c17f)
[18] [https://pigsty.io](https://pigsty.io/docs/pgsql/admin/patroni/)
[19] [https://bootvar.com](https://bootvar.com/useful-patroni-commands/)
[20] [https://patroni.readthedocs.io](https://patroni.readthedocs.io/en/latest/patronictl.html)
[21] [https://patroni.readthedocs.io](https://patroni.readthedocs.io/en/latest/patronictl.html)
