#!/bin/bash
set -e

# Ensure pg_hba or other directories are writeable by postgres
mkdir -p /var/lib/postgresql/data/patroni
chmod 700 /var/lib/postgresql/data/patroni

# Create .pgpass file required by Patroni/pg_rewind
echo "*:*:*:postgres:postgrespassword" > /var/lib/postgresql/.pgpass
echo "*:*:*:replicator:reppassword" >> /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass

# Execute patroni
exec patroni /etc/patroni/patroni.yml
