# Liquibase: Deep Dive & Overview

Liquibase is an open-source database schema change management tool. It allows developers and DBAs to track, version, and deploy database changes alongside application code. By treating database changes as code, Liquibase ensures consistency across different environments (dev, test, prod) and enables automated CI/CD for databases.

## 1. Core Concepts

### 1.1 The Changelog
The **Changelog** is the root file (or collection of files) that defines the changes to be applied to the database. It acts as the single source of truth for your database schema.
- Formats supported: **XML**, **YAML**, **JSON**, and **SQL** (Formatted SQL).
- Best practice: Have a master changelog that `includes` other smaller changelog files to keep things organized.

### 1.2 The Changeset
A **Changeset** is an atomic unit of change within a changelog (e.g., creating a table, adding a column, inserting data).
- Each changeset is uniquely identified by an `id`, an `author`, and the `file path`.
- Liquibase ensures each changeset is only applied *once* to a specific database.

### 1.3 Tracking Tables
When Liquibase runs against a database, it automatically creates and manages two tracking tables:
- `DATABASECHANGELOG`: Stores a record of every changeset that has been executed successfully. Liquibase checks this table to determine what still needs to be run.
- `DATABASECHANGELOGLOCK`: Used to ensure that only one instance of Liquibase runs at a time, preventing race conditions or conflicts during parallel deployments.

## 2. Key Features

- **Database Independence:** If you use XML, YAML, or JSON, Liquibase abstracts the SQL dialect. You can write a "create table" changeset, and Liquibase will generate the correct SQL for PostgreSQL, Oracle, MySQL, etc.
- **Rollbacks:** You can define rollback instructions for changesets. Some changesets (like `createTable`) have automatic rollbacks (e.g., `dropTable`), while destructive ones (like `dropTable`) require you to manually write the rollback logic.
- **Contexts & Labels:** These are tagging mechanisms. You can tag a changeset with `context="test"` and tell Liquibase to only run changesets matching that context (e.g., inserting test data).
- **Preconditions:** Rules that must be met before a changeset runs. For example, "only run this changeset if table X does not exist." If a precondition fails, you can specify what Liquibase should do (halt, warn, or skip).

## 3. Formatted SQL vs. Abstraction (YAML/XML)

You have two main ways to write Liquibase changes:
1. **Abstraction (YAML, XML, JSON):** Database agnostic. Great if you plan to support multiple database vendors or want strict structural validation.
2. **Formatted SQL:** You write plain SQL, but add Liquibase comments to define the changeset boundaries. Great if you heavily rely on vendor-specific features and functions.

Example Formatted SQL:
```sql
--liquibase formatted sql

--changeset josef:1
CREATE TABLE employees (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL
);
--rollback DROP TABLE employees;
```

## 4. Best Practices

1. **One change per changeset:** Don't put 10 table creations in one changeset. If one fails, the changeset is partially applied, which requires manual cleanup.
2. **Never modify a changeset once it has been applied:** Since Liquibase calculates an MD5 checksum of the changeset and stores it in the database, modifying it later will cause a checksum validation error. If you need to fix a mistake, write a *new* changeset.
3. **Use logical IDs:** While IDs can be numbers (`1`, `2`, `3`), using descriptive IDs like `create-employee-table` or ticket numbers (`JIRA-123`) is often better.

## 5. How to run the provided Docker example

In this folder, you will find a `docker-compose.yml` and a `changelog` directory.

1. Open your terminal in this directory.
2. Run `docker-compose up`
3. Docker will spin up a PostgreSQL database.
4. The `liquibase` container will wait for PostgreSQL to be ready, apply the changesets defined in `changelog/db.changelog-master.yaml`, and then exit.
5. You can verify by connecting to the database (User: `postgres`, Pass: `postgrespass`, DB: `mydatabase`, Port: `5432`).
