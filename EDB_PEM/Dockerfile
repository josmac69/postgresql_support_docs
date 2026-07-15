FROM python:3.10-slim

# Install PostgreSQL connector
RUN pip install --no-cache-dir psycopg2-binary

# Copy agent script
COPY pem_agent.py /usr/bin/pem_agent.py
RUN chmod +x /usr/bin/pem_agent.py

# Run the agent daemon
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["/usr/bin/pem_agent.py"]
