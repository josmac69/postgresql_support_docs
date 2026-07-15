FROM python:3.10-slim

# Install DB drivers needed by the Python simulator
RUN pip install --no-cache-dir pymysql psycopg2-binary

# Create realistic EDB MTK directory structure
RUN mkdir -p /usr/edb/migrationtoolkit/etc

# Copy configuration
COPY toolkit.properties /usr/edb/migrationtoolkit/etc/toolkit.properties

# Copy script and shell wrapper
COPY runMTK.py /usr/bin/runMTK.py
COPY runMTK.sh /usr/bin/runMTK.sh

RUN chmod +x /usr/bin/runMTK.py /usr/bin/runMTK.sh

# Keep container alive
CMD ["tail", "-f", "/dev/null"]
