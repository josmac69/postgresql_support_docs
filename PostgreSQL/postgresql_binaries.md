# POSTGRESQL STANDARD BINARIES CHEAT SHEET

When managing PostgreSQL environments, you will need to quickly interact with, diagnose, back up, and optimize the database. Knowing the standard binaries, their locations, and how to invoke them directly (especially if wrapper scripts fail or aren't installed) is critical.

---

## 1. Binary Path Locations

Depending on the Linux distribution used for the EC2 instances, the PostgreSQL binaries are located in different directories. If they are not in your system `PATH`, you must invoke them using their absolute paths.

### Debian / Ubuntu (PGDG Packages)
* **Standard wrapper path:** `/usr/bin/` (contains wrappers like `pg_ctlcluster`, `pg_lsclusters`, etc.)
* **Direct versioned binaries:** `/usr/lib/postgresql/<version>/bin/`
  * *Example (PG 17):* `/usr/lib/postgresql/17/bin/psql`

### RHEL / Rocky / CentOS / Amazon Linux (Pgdg / Percona Packages)
* **Direct versioned binaries:** `/usr/pgsql-<version>/bin/`
  * *Example (PG 17):* `/usr/pgsql-17/bin/psql`
* **Percona Distribution for PostgreSQL:** `/usr/sbin/` or `/usr/bin/` depending on the packages, but usually symlinked or located in `/usr/pgsql-<version>/bin/`.

---

## 2. Core Client & Connection Binaries

### `psql` — The Interactive Terminal
The primary interface for running queries, checking explain plans, and database administration.
* **Key Diagnostic / Operational Uses:** Running query optimizations (`EXPLAIN ANALYZE`), checking locks, inspecting catalog tables.
* **Useful Flags:**
  * `-h <host>` / `-p <port>` / `-U <username>` / `-d <dbname>`
  * `-c "SQL"` — Execute a single command and exit (great for scripting/verification).
  * `-tAc` — Tuple-only, unaligned, clean output (perfect for extracting variables into shell variables).
* **Example:**
  ```bash
  PGDATA=$(sudo -u postgres psql -tAc "SHOW data_directory;")
  ```

### `pg_isready` — Connection Status Check
Checks the connection status of a PostgreSQL server without requiring authentication.
* **Key Diagnostic / Operational Uses:** Verifying if the database server has finished starting up or is accepting connections. Useful in verification scripts or loop-checks.
* **Example:**
  ```bash
  pg_isready -h localhost -p 5432
  # Exit status: 0 = accepting connections, 1 = rejected, 2 = no response, 3 = no attempt
  ```

### `pg_bench` — Benchmarking & Churn Generation
Runs a benchmark test on PostgreSQL, simulating concurrent client connections running transactions.
* **Key Diagnostic / Operational Uses:** Creating write load/traffic to test replication lag, trigger autovacuum, or force WAL file generation to test disk space issues.
* **Example:**
  ```bash
  # Initialize pgbench tables in database 'shop' with scale factor 50
  pg_bench -i -s 50 shop
  # Run a 60-second read-write test with 10 clients across 2 threads
  pg_bench -c 10 -j 2 -T 60 shop
  ```

---

## 3. Administration & Daemon Control

### `pg_ctl` — Server Control Utility
Initializes, starts, stops, restarts, or reloads the PostgreSQL server.
* **Key Diagnostic / Operational Uses:** Controlling the server instance. Prefer `pg_ctl reload` (or systemd reload) over `restart` unless changing a non-dynamic parameter (like `shared_preload_libraries` or `shared_buffers`).
* **Debian/Ubuntu Alternative:** Use `pg_ctlcluster <version> <cluster> <action>` (e.g., `pg_ctlcluster 17 main restart`).
* **Example:**
  ```bash
  # Reload configuration without dropping connections
  sudo -u postgres pg_ctl reload -D /var/lib/postgresql/17/main
  # Promote a standby server to primary
  sudo -u postgres pg_ctl promote -D /var/lib/postgresql/17/main
  ```

### `postgres` (or `postmaster`) — The Server Daemon
The actual PostgreSQL server executable. Can be run directly in the foreground for debugging startup failures.
* **Key Diagnostic / Operational Uses:** Diagnosing a server that crashes immediately on start (displays exact error on `stderr` directly).
* **Example:**
  ```bash
  sudo -u postgres postgres -D /var/lib/postgresql/17/main
  ```

### `initdb` — Create a New Cluster
Creates a new PostgreSQL database cluster (a collection of databases managed by a single server instance).
* **Key Diagnostic / Operational Uses:** Setting up a secondary cluster for a replication task or fresh environment.
* **Example:**
  ```bash
  sudo -u postgres initdb -D /var/lib/postgresql/17/standby -E UTF8 --locale=C
  ```

---

## 4. Diagnostics & Emergency Recovery

### `pg_controldata` — Cluster Control Information
Displays control information of a PostgreSQL database cluster (such as database state, WAL checkpoint details, and catalog version).
* **Key Diagnostic / Operational Uses:** Reading the state of the cluster offline (e.g., when PostgreSQL won't start). It will tell you if the database shut down cleanly, is in recovery, or has corrupted control file checksums.
* **Example:**
  ```bash
  sudo -u postgres pg_controldata -D /var/lib/postgresql/17/main
  # Look specifically for: "Database cluster state" (e.g. "shut down", "in production")
  ```

### `pg_waldump` — Write-Ahead Log Parser
Decodes PostgreSQL write-ahead logs (WAL) into a human-readable format.
* **Key Diagnostic / Operational Uses:** Diagnosing high write volumes or identifying what operations are filling up `pg_wal`.
* **Example:**
  ```bash
  # Dump WAL starting from a specific segment file
  sudo -u postgres pg_waldump /var/lib/postgresql/17/main/pg_wal/000000010000000000000001 | head -n 20
  ```

### `pg_resetwal` — Reset WAL / Control Data
Resets the write-ahead log (WAL) and other control information of a PostgreSQL database cluster.
* **Key Diagnostic / Operational Uses:** **Emergency-only recovery.** Use *only* if the server refuses to start due to missing/corrupted WAL and you have explicitly announced this and justified it. Can cause data corruption.
* **Example:**
  ```bash
  sudo -u postgres pg_resetwal -f -D /var/lib/postgresql/17/main
  ```

---

## 5. Backup & Restore Binaries

### `pg_dump` — Single Database Backup
Extracts a PostgreSQL database into a SQL script file or custom archive file.
* **Key Diagnostic / Operational Uses:** Backing up database schemas or data before performing risky optimizations, refactoring, or upgrades.
* **Example:**
  ```bash
  # Backup schema only (safe and fast, no lock issues)
  pg_dump -Fc -s -d shop -f /tmp/shop_schema.dump
  # Backup specific table data in directory format
  pg_dump -Fd -j 4 -t orders -d shop -f /tmp/orders_backup
  ```

### `pg_dumpall` — Cluster-wide Backup
Extracts all PostgreSQL databases of a cluster, including global objects like roles and tablespaces.
* **Key Diagnostic / Operational Uses:** Creating a full backup before database upgrades (`pg_upgrade`).
* **Example:**
  ```bash
  sudo -u postgres pg_dumpall --globals-only > /tmp/globals.sql
  ```

### `pg_restore` — Restore from Archive
Restores a PostgreSQL database from an archive created by `pg_dump` (only works with custom `-Fc` or directory `-Fd` formats).
* **Key Diagnostic / Operational Uses:** Importing test data or restoring from backup.
* **Example:**
  ```bash
  # Restore database in parallel
  pg_restore -d shop -j 4 -v /tmp/shop.dump
  ```

---

## 6. Replication & High Availability

### `pg_basebackup` — Create a Standby Base Backup
Takes a base backup of a running PostgreSQL cluster to bootstrap a standby replica.
* **Key Diagnostic / Operational Uses:** Bootstrapping a standby replica in high-availability environments.
* **Example:**
  ```bash
  # Bootstrap standby with slot configuration and write connection info to postgresql.auto.conf
  sudo -u postgres pg_basebackup -h primary_ip -D /var/lib/postgresql/17/standby -U replication_user -P -R -X stream --slot=standby_slot
  ```

### `pg_rewind` — Resynchronize Standbys
Synchronizes a PostgreSQL data directory with another data directory, running backward in WAL history to resolve split-brain.
* **Key Diagnostic / Operational Uses:** Fast failback/failover tasks. Avoids needing a full `pg_basebackup` when primary and standby have diverged slightly.
* **Example:**
  ```bash
  sudo -u postgres pg_rewind --target-pgdata=/var/lib/postgresql/17/main --source-server='host=primary_ip user=postgres dbname=postgres'
  ```

### `pg_receivewal` — Stream WAL Files
Streams write-ahead logs (WAL) from a PostgreSQL server to a local directory in real-time.
* **Key Diagnostic / Operational Uses:** Setting up external archivers or log-shipping standbys.
* **Example:**
  ```bash
  pg_receivewal -D /var/lib/postgresql/archive/ -h primary_ip -U replication_user --create-slot --slot=wal_receiver_slot
  ```

### `pg_recvlogical` — Logical Decoding Stream Controller
Controls logical decoding streams, allowing you to create replication slots and stream changes.
* **Key Diagnostic / Operational Uses:** Setting up logical replication troubleshooting.
* **Example:**
  ```bash
  pg_recvlogical -d shop --slot=logical_slot --create-slot -p test_decoding
  ```

---

## 7. Command-Line Maintenance Wrappers
These are thin, convenient command-line wrappers around standard SQL commands. Useful when you want to execute maintenance without launching `psql`.

* **`vacuumdb`**: Vacuum and analyze a database.
  * *Example:* `vacuumdb -h localhost -d shop -t orders -z --verbose`
* **`reindexdb`**: Rebuild indexes on a database.
  * *Example:* `reindexdb -d shop -t orders_cust_created_idx`
* **`createdb` / `dropdb`**: Create or drop a database.
  * *Example:* `createdb -U postgres shop`
* **`createuser` / `dropuser`**: Create or drop a database role.
  * *Example:* `createuser -P replication_user`
* **`clusterdb`**: Cluster a database according to an index.
  * *Example:* `clusterdb -d shop -t orders --index=orders_cust_created_idx`

---

## 8. Upgrade Utilities

### `pg_upgrade` — Major Version Upgrades
Upgrades a PostgreSQL database cluster from an older major version to a newer version.
* **Key Diagnostic / Operational Uses:** Upgrading PG in-place (e.g., from PG 15 to PG 17).
* **Example:**
  ```bash
  sudo -u postgres pg_upgrade \
    -b /usr/lib/postgresql/15/bin/ \
    -B /usr/lib/postgresql/17/bin/ \
    -d /var/lib/postgresql/15/main/ \
    -D /var/lib/postgresql/17/main/ \
    --check
  ```
