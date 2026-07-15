#!/usr/bin/env python3
import os
import sys
import time
import signal
import psycopg2

# Configuration parameters
PEM_SERVER_HOST = os.getenv("PEM_SERVER_HOST", "pem-server-db")
PEM_SERVER_DB = "pem"
PEM_SERVER_USER = "postgres"
PEM_SERVER_PASS = "postgrespass"

DB_NODE_HOST = os.getenv("DB_NODE_HOST", "db-node")
DB_NODE_DB = "postgres"
DB_NODE_USER = "postgres"
DB_NODE_PASS = "postgrespass"

AGENT_DISPLAY_NAME = os.getenv("AGENT_DISPLAY_NAME", "db-node-agent")

running = True

def handle_sigterm(signum, frame):
    global running
    print("[INFO] Received shutdown signal. Terminating PEM agent...")
    running = False

signal.signal(signal.SIGTERM, handle_sigterm)
signal.signal(signal.SIGINT, handle_sigterm)

def connect_with_retry(host, db, user, password, desc):
    while running:
        try:
            conn = psycopg2.connect(
                host=host,
                dbname=db,
                user=user,
                password=password
            )
            print(f"[INFO] Connected to {desc} ({host}/{db})")
            return conn
        except Exception as e:
            print(f"[WARNING] Failed to connect to {desc} ({host}/{db}): {e}. Retrying in 3s...")
            time.sleep(3)
    sys.exit(0)

def register_agent(pem_conn):
    cursor = pem_conn.cursor()
    while running:
        try:
            # Check if agent already exists
            cursor.execute("SELECT id FROM pem.agents WHERE display_name = %s", (AGENT_DISPLAY_NAME,))
            res = cursor.fetchone()
            if res:
                agent_id = res[0]
                print(f"[INFO] Agent already registered. ID: {agent_id}")
            else:
                cursor.execute(
                    "INSERT INTO pem.agents (display_name, status) VALUES (%s, 'ACTIVE') RETURNING id",
                    (AGENT_DISPLAY_NAME,)
                )
                agent_id = cursor.fetchone()[0]
                print(f"[INFO] Registered new agent. Generated ID: {agent_id}")
            pem_conn.commit()
            return agent_id
        except Exception as e:
            print(f"[ERROR] Error during agent registration: {e}. Retrying...")
            pem_conn.rollback()
            time.sleep(3)
    sys.exit(0)

def collect_metrics(node_conn):
    cursor = node_conn.cursor()
    try:
        # 1. Connection count
        cursor.execute("SELECT count(*) FROM pg_stat_activity")
        conn_count = cursor.fetchone()[0]

        # 2. Active transactions
        cursor.execute("SELECT count(*) FROM pg_stat_activity WHERE state = 'active'")
        active_tx = cursor.fetchone()[0]

        # 3. Locks count
        cursor.execute("SELECT count(*) FROM pg_locks")
        locks = cursor.fetchone()[0]

        # 4. Total DB size bytes
        cursor.execute("SELECT sum(pg_database_size(oid)) FROM pg_database")
        db_size = cursor.fetchone()[0]

        return conn_count, active_tx, locks, db_size
    except Exception as e:
        print(f"[ERROR] Error querying metrics from target DB: {e}")
        node_conn.rollback()
        return None

def write_metrics(pem_conn, agent_id, metrics):
    conn_count, active_tx, locks, db_size = metrics
    cursor = pem_conn.cursor()
    try:
        # Write history
        cursor.execute(
            """
            INSERT INTO pem.metrics_history (agent_id, connections_count, active_transactions, locks_count, db_size_bytes)
            VALUES (%s, %s, %s, %s, %s)
            """,
            (agent_id, conn_count, active_tx, locks, db_size)
        )

        # Update heartbeat status
        cursor.execute(
            "UPDATE pem.agents SET last_heartbeat = NOW(), status = 'ACTIVE' WHERE id = %s",
            (agent_id,)
        )

        # Simple Alert Evaluation (connections threshold > 5 for warning, > 10 for critical)
        cursor.execute("DELETE FROM pem.alerts WHERE agent_id = %s AND metric_name = 'connections_count'", (agent_id,))
        
        severity = None
        message = ""
        if conn_count > 10:
            severity = "CRITICAL"
            message = f"Critical alert: Active connections ({conn_count}) exceeds threshold of 10."
        elif conn_count > 5:
            severity = "WARNING"
            message = f"Warning alert: Active connections ({conn_count}) exceeds threshold of 5."

        if severity:
            cursor.execute(
                """
                INSERT INTO pem.alerts (agent_id, severity, metric_name, current_value, message)
                VALUES (%s, %s, 'connections_count', %s, %s)
                """,
                (agent_id, severity, conn_count, message)
            )
            print(f"[{severity}] Triggered alert: {message}")

        pem_conn.commit()
        print(f"[INFO] Pushed metrics: Conns={conn_count}, Locks={locks}, Tx={active_tx}, Size={db_size} bytes")
    except Exception as e:
        print(f"[ERROR] Error saving metrics to PEM server database: {e}")
        pem_conn.rollback()

def main():
    print("[INFO] Starting EDB PEM Agent Simulator...")
    
    # Connect to databases
    pem_conn = connect_with_retry(PEM_SERVER_HOST, PEM_SERVER_DB, PEM_SERVER_USER, PEM_SERVER_PASS, "PEM Server DB")
    node_conn = connect_with_retry(DB_NODE_HOST, DB_NODE_DB, DB_NODE_USER, DB_NODE_PASS, "Target DB Node")
    node_conn.autocommit = True
    
    # Register agent
    agent_id = register_agent(pem_conn)
    
    print("[INFO] EDB PEM Agent is now actively polling metrics.")
    while running:
        metrics = collect_metrics(node_conn)
        if metrics:
            write_metrics(pem_conn, agent_id, metrics)
        time.sleep(5)
        
    pem_conn.close()
    node_conn.close()
    print("[INFO] PEM agent exited cleanly.")

if __name__ == "__main__":
    main()
