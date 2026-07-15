# Liquibase Learning Module

This directory contains resources and a working Docker example for learning Liquibase.

## Contents

- `liquibase_overview.md`: A comprehensive guide on Liquibase core concepts, features, and best practices.
- `docker-compose.yml`: A Docker Compose setup featuring a PostgreSQL database and a Liquibase container.
- `changelog/`: Contains the sample Liquibase migrations written in YAML.
- `Makefile`: A helper script to quickly start and stop the Docker environment.

## Getting Started

You can use the provided `Makefile` to test the Liquibase migrations against the local PostgreSQL container.

### Start the environment
This will start PostgreSQL and run the Liquibase container to apply the migrations in the `changelog` folder:
```bash
make up
```

### Stop the environment
To stop the containers and clean up the database volume:
```bash
make down
```

### View Logs
If you run `make up` in detached mode (e.g., `docker-compose up -d`), you can view the logs using:
```bash
make logs
```

## Exploring the Database

While the environment is running, you can connect to the PostgreSQL instance using any database client:
- **Host**: `localhost`
- **Port**: `5432`
- **User**: `postgres`
- **Password**: `postgrespass`
- **Database**: `mydatabase`

Inside the database, you will see the `users` table created by the changelog, as well as Liquibase's tracking tables (`DATABASECHANGELOG` and `DATABASECHANGELOGLOCK`).
