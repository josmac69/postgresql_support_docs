# EDB Postgres Migration Toolkit (MTK): Deep Dive & Learning Guide

The EDB Postgres Migration Toolkit (MTK) is a command-line utility that facilitates the rapid, high-performance migration of database schemas and data from legacy and proprietary engines (Oracle, MS SQL Server, Sybase ASE, MySQL) to PostgreSQL or EDB Postgres Advanced Server (EPAS).

---

## 1. Core Architecture

MTK is a Java-based application that operates using JDBC (Java Database Connectivity) connections. It does not require a middle agent; it connects directly to both the source and target databases.

```mermaid
graph LR
    Source[(Source DB: Oracle/SQL Server/MySQL/Sybase)]
    Target[(Target DB: Postgres/EPAS)]
    
    subgraph EDB MTK (Java CLI)
        Engine[Migration Engine]
        JDBC_Src[Source JDBC Driver]
        JDBC_Tgt[Target JDBC Driver]
    end
    
    Source <--> JDBC_Src
    JDBC_Src <--> Engine
    Engine <--> JDBC_Tgt
    JDBC_Tgt <--> Target
    
    Config[toolkit.properties] --> Engine
```

### Key Workflow
1. **Metadata Discovery:** MTK queries the catalog/system tables of the source database to understand tables, data types, constraints, indexes, views, and stored procedures.
2. **DataType Mapping:** MTK translates source-specific data types to their closest PostgreSQL equivalents (e.g., Oracle's `NUMBER` to `NUMERIC` or `DOUBLE PRECISION`, MySQL's `DATETIME` to `TIMESTAMP`).
3. **DDL Generation & Execution:** Unless restricted (e.g., by `-dataOnly`), MTK generates the PostgreSQL DDL and runs it against the target database.
4. **Data Migration:** MTK performs bulk data copy. If `-fastCopy` is enabled, it uses PostgreSQL's high-speed `COPY` protocol (via JDBC copy manager) rather than slow `INSERT` statements.

---

## 2. Configuration (`toolkit.properties`)

MTK reads connection properties from a file named `toolkit.properties`, typically located in the `etc` subfolder of your MTK installation (e.g., `/usr/edb/migrationtoolkit/etc/toolkit.properties`).

### Standard Configuration Structure

```properties
# Source Connection Details (MySQL Example)
SRC_DB_URL=jdbc:mysql://mysql-source:3306/sourcedb?useSSL=false&allowPublicKeyRetrieval=true
SRC_DB_USER=root
SRC_DB_PASSWORD=rootpassword

# Target Connection Details (PostgreSQL Example)
TARGET_DB_URL=jdbc:postgresql://postgres-target:5432/targetdb
TARGET_DB_USER=postgres
TARGET_DB_PASSWORD=postgrespassword
```

### JDBC Driver Requirements
MTK does not ship with JDBC drivers for proprietary databases due to licensing. You must download the appropriate JDBC `.jar` file and place it in the `lib` folder of your MTK installation (e.g., `/usr/edb/migrationtoolkit/lib/`):
- **Oracle:** `ojdbc8.jar`
- **MySQL:** `mysql-connector-j-x.x.x.jar`
- **SQL Server:** `mssql-jdbc-x.x.x.jar`
- **Sybase:** `jconn4.jar`

---

## 3. Important Command-Line Options

The utility is executed via the `runMTK.sh` (Linux) or `runMTK.bat` (Windows) wrapper.

```bash
runMTK.sh [options] database_name
```

### Primary Parameters

| Option | Description |
| :--- | :--- |
| `-sourceType <engine>` | Source database engine: `oracle`, `mysql`, `mssql`, `sybase`. (Required) |
| `-targetType <engine>` | Target database engine: `postgres` (community PostgreSQL) or `enterprisedb` (EPAS). Defaults to `enterprisedb`. |
| `-schemaOnly` | Migrates schema definitions (tables, constraints, indexes, views) but does not copy data. |
| `-dataOnly` | Migrates data only. Assumes the target tables already exist. |
| `-tables <t1,t2...>` | Migrates only the specified tables (comma-separated list, case-sensitive). |
| `-truncate` | Truncates target tables before loading data. Critical for repeating data runs. |
| `-fastCopy` | Enables PostgreSQL binary COPY protocol for high-performance bulk data loading. Always recommend for production. |
| `-batchSize <count>` | Sets the batch size for inserts/updates (default: 1000). Larger sizes (e.g., 5000-20000) speed up migrations over latency-prone connections. |
| `-replaceRules` | Replaces existing migration rules in the target database if they exist. |
| `-safeMode` | Uses standard, row-by-row inserts instead of batching, useful for pinpointing bad rows causing failures. |

---

## 4. EDB Postgres Advanced Server (EPAS) Target vs. PostgreSQL Target

A major architectural consideration during migrations is the target type:

### Target: `enterprisedb` (EPAS)
- **Oracle Compatibility:** EPAS natively compiles Oracle’s PL/SQL procedural dialect, package structures (`DBMS_*`, `UTL_*`), and built-in functions.
- **Remediation:** MTK can migrate Oracle packages, functions, and procedures to EPAS with **minimal to no remediation**. The code is loaded directly as-is.

### Target: `postgres` (Community PostgreSQL)
- **Dialect Translation:** Standard PostgreSQL only understands PL/pgSQL. MTK tries to translate PL/SQL structures on-the-fly.
- **Remediation:** For complex packages, dynamic SQL, or custom Oracle types, MTK's automatic translation will fail or generate placeholders. Manual rewriting of stored procedures into PL/pgSQL is usually required.

---

## 5. Performance Optimization & Best Practices

1. **JVM Memory Tuning:** For large migrations (millions of rows, huge metadata counts), the JVM might run out of memory. Adjust JVM heap size before execution:
   ```bash
   export JVM_HEAP_SIZE=4096m
   ```
2. **Constraint Management:** By default, MTK loads data with foreign keys enabled, which can be slow and fail if tables are loaded out of order. Consider:
   - Creating schemas with `-schemaOnly`
   - Migrating data with `-dataOnly` (disabling constraints on target database temporarily)
   - Applying constraints post-migration.
3. **Index Management:** Loading data into tables with pre-existing indexes is extremely slow because the database must update indexes on every write. For large tables, migrate the schema without indexes, migrate the data, and then build indexes concurrently.
