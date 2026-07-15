FROM postgres:16-bookworm

# Install Python, pip, and Patroni dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-psycopg2 \
    python3-yaml \
    python3-requests \
    && rm -rf /var/lib/apt/lists/*

# Install Patroni with etcd3 support using pip3 (PEP 668 bypass required on Bookworm)
RUN pip3 install --break-system-packages patroni[etcd3]

# Create directories and set permissions
RUN mkdir -p /etc/patroni /var/lib/postgresql/data/patroni \
    && chown -R postgres:postgres /etc/patroni /var/lib/postgresql

COPY patroni.yml.template /etc/patroni/patroni.yml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER postgres
EXPOSE 5432 8008

ENTRYPOINT ["/entrypoint.sh"]
