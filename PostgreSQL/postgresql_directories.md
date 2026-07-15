# POSTGRESQL DIRECTORIES & PATHS CHEAT SHEET
*(Second-screen reference for locating configurations, data, binaries, and logs)*

During a PostgreSQL diagnostic triage or troubleshooting session, you might need to quickly find files to fix disk space issues, modify permissions, tune kernel variables, or edit pg_hba.conf. Because different distros split configuration and data directories differently, this guide maps standard layouts.

---

## 1. How to Query Paths Live (Within PostgreSQL)
If the database is running, the absolute fastest and most reliable way to find the paths is querying the engine itself. Run these queries inside `psql` (or via `psql -c`):

```sql
SHOW data_directory;              -- PGDATA path (contains base, pg_wal, pg_tblspc)
SHOW config_file;                 -- Location of postgresql.conf
SHOW hba_file;                    -- Location of pg_hba.conf
SHOW ident_file;                  -- Location of pg_ident.conf
SHOW unix_socket_directories;     -- Where the Unix domain socket is created
SHOW log_directory;               -- Directory for database engine logs (usually relative to PGDATA)
```

Alternatively, query them all in one go:
```sql
SELECT name, setting, description 
FROM pg_settings 
WHERE name IN ('data_directory', 'config_file', 'hba_file', 'ident_file', 'unix_socket_directories', 'log_directory');
```

---

## 2. Path Layouts by Linux Distribution & OS

### 🐧 Debian / Ubuntu (Official PGDG APT Packages)
Debian-based packages split configuration from the data directory so that configurations can be managed centrally in `/etc`.

| Component | Default Path | Example (PG 17) |
|---|---|---|
| **Configuration Directory** | `/etc/postgresql/<version>/<cluster>/` | `/etc/postgresql/17/main/` |
| **Data Directory (`PGDATA`)** | `/var/lib/postgresql/<version>/<cluster>/` | `/var/lib/postgresql/17/main/` |
| **Binaries Directory** | `/usr/lib/postgresql/<version>/bin/` | `/usr/lib/postgresql/17/bin/` |
| **System Bin wrappers** | `/usr/bin/` | `/usr/bin/psql`, `/usr/bin/pg_ctlcluster` |
| **Log Directory** | `/var/log/postgresql/` | `/var/log/postgresql/postgresql-17-main.log` |
| **Unix Socket Directory** | `/var/run/postgresql/` | `/var/run/postgresql/.s.PGSQL.5432` |
| **Systemd Service Unit** | `/lib/systemd/system/postgresql.service` | (Controls `/lib/systemd/system/postgresql@.service` clusters) |

> [!NOTE]
> Debian/Ubuntu uses symlinks inside `PGDATA` pointing back to `/etc/postgresql/` for `postgresql.conf`, `pg_hba.conf`, and `pg_ident.conf`.

---

### 🐧 RHEL / Rocky / AlmaLinux / CentOS / Amazon Linux (Official PGDG YUM/DNF)
RedHat-based packages store configuration files directly inside the database cluster's `PGDATA` directory.

| Component | Default Path | Example (PG 17) |
|---|---|---|
| **Configuration Directory** | `/var/lib/pgsql/<version>/data/` | `/var/lib/pgsql/17/data/` |
| **Data Directory (`PGDATA`)** | `/var/lib/pgsql/<version>/data/` | `/var/lib/pgsql/17/data/` |
| **Binaries Directory** | `/usr/pgsql-<version>/bin/` | `/usr/pgsql-17/bin/` |
| **Log Directory** | `/var/lib/pgsql/<version>/data/log/` | `/var/lib/pgsql/17/data/log/` (rotated internally) |
| **Unix Socket Directory** | `/var/run/postgresql/` or `/tmp/` | `/var/run/postgresql/.s.PGSQL.5432` |
| **Systemd Service Unit** | `/usr/lib/systemd/system/postgresql-<version>.service` | `postgresql-17.service` |

---

### 🐧 SUSE / SLES (Distro Packages)
SUSE packages keep the layout clean, combining data and configs.

| Component | Default Path | Example (PG 16) |
|---|---|---|
| **Configuration & Data** | `/var/lib/pgsql/data/` | `/var/lib/pgsql/data/` |
| **Binaries Directory** | `/usr/lib/postgresql<version>/bin/` | `/usr/lib/postgresql16/bin/` |
| **Log Directory** | `/var/lib/pgsql/data/log/` | `/var/lib/pgsql/data/log/` |

---

### 🍏 macOS

#### Homebrew Installation
Homebrew locations differ depending on whether the processor is Apple Silicon (M-series) or Intel.

| Component | Apple Silicon (ARM64) | Intel (x86_64) |
|---|---|---|
| **Configuration & Data** | `/opt/homebrew/var/postgresql@<version>/` | `/usr/local/var/postgresql@<version>/` |
| **Binaries Directory** | `/opt/homebrew/opt/postgresql@<version>/bin/` | `/usr/local/opt/postgresql@<version>/bin/` |
| **Unix Socket Directory** | `/tmp/` | `/tmp/` |

#### Postgres.app
Postgres.app encapsulates instances within the application bundle.

| Component | Default Path | Example (PG 17) |
|---|---|---|
| **Configuration & Data** | `/Users/<username>/Library/Application Support/Postgres/var-<version>/` | `/Users/josef/Library/Application Support/Postgres/var-17/` |
| **Binaries Directory** | `/Applications/Postgres.app/Contents/Versions/<version>/bin/` | `/Applications/Postgres.app/Contents/Versions/17/bin/` |
| **Unix Socket Directory** | `/tmp/` | `/tmp/` |

---

### 🪟 Windows (EnterpriseDB Graphical Installer)
Windows stores the binaries in Program Files, and configurations directly within the installation's `data` directory.

| Component | Default Path | Example (PG 17) |
|---|---|---|
| **Configuration & Data** | `C:\Program Files\PostgreSQL\<version>\data\` | `C:\Program Files\PostgreSQL\17\data\` |
| **Binaries Directory** | `C:\Program Files\PostgreSQL\<version>\bin\` | `C:\Program Files\PostgreSQL\17\bin\` |
| **Log Directory** | `C:\Program Files\PostgreSQL\<version>\data\log\` | `C:\Program Files\PostgreSQL\17\data\log\` |

---

## 3. Structure of `PGDATA` (The Database Engine Footprint)
Regardless of the operating system, the structure of the data directory is standardized:

* **`base/`**: Subdirectories containing the actual user tables and databases (names are OIDs).
* **`global/`**: Contains cluster-wide system tables, such as pg_database and pg_authid (roles).
* **`pg_wal/`** (formerly `pg_xlog`): Contains the Write-Ahead Log (WAL) segments. 
  > [!WARNING]
  > Never delete files inside `pg_wal` manually to free up disk space. If WAL builds up, either fix the failing archive_command or drop inactive replication slots.
* **`pg_tblspc/`**: Symlinks pointing to locations outside PGDATA where external tablespaces have been defined.
* **`pg_stat_tmp/`**: Temporary status files (where collector stats are written). Often backed by a RAM disk/tmpfs to improve performance.
* **`pg_commit_ts/`**: Commit timestamp transaction data.
* **`pg_logical/`**: Logical decoding state data.
* **`pg_multixact/`**: Multi-transaction status data (used for shared row locks).
* **`pg_subtrans/`**: Sub-transaction status data.
* **`pg_twophase/`**: Prepared transaction state files.
* **`postmaster.pid`**: Lock file indicating a running instance. Contains the PID of the main postmaster process.
* **`postmaster.opts`**: Command-line arguments used when the postmaster was started.
