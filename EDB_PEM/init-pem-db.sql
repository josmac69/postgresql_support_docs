-- EDB PEM Simulated Backend DB Setup
CREATE DATABASE pem;

\c pem;

CREATE SCHEMA IF NOT EXISTS pem;

-- Table to store registered PEM Agents
CREATE TABLE IF NOT EXISTS pem.agents (
    id SERIAL PRIMARY KEY,
    display_name VARCHAR(100) UNIQUE NOT NULL,
    status VARCHAR(20) DEFAULT 'UNKNOWN',
    registered_at TIMESTAMP DEFAULT NOW(),
    last_heartbeat TIMESTAMP
);

-- Table to store probe definition
CREATE TABLE IF NOT EXISTS pem.probes (
    id SERIAL PRIMARY KEY,
    probe_name VARCHAR(50) UNIQUE NOT NULL,
    interval_seconds INT DEFAULT 10,
    description TEXT
);

-- Populate default probes
INSERT INTO pem.probes (probe_name, interval_seconds, description) VALUES
('database_stats', 5, 'Collects connection count, locks, and DB size metrics.'),
('system_stats', 10, 'Collects virtual OS stats (CPU, Memory).');

-- Table to store historical metrics collected by agents
CREATE TABLE IF NOT EXISTS pem.metrics_history (
    id SERIAL PRIMARY KEY,
    agent_id INT REFERENCES pem.agents(id) ON DELETE CASCADE,
    collected_at TIMESTAMP DEFAULT NOW(),
    connections_count INT,
    active_transactions INT,
    locks_count INT,
    db_size_bytes BIGINT
);

-- Table to store active alerts evaluated by the server
CREATE TABLE IF NOT EXISTS pem.alerts (
    id SERIAL PRIMARY KEY,
    agent_id INT REFERENCES pem.agents(id) ON DELETE CASCADE,
    severity VARCHAR(20) NOT NULL, -- OK, WARNING, CRITICAL
    metric_name VARCHAR(50) NOT NULL,
    current_value NUMERIC,
    message TEXT,
    triggered_at TIMESTAMP DEFAULT NOW()
);

-- Create a view for DBAs to easily check latest metrics per agent
CREATE OR REPLACE VIEW pem.v_latest_agent_metrics AS
SELECT DISTINCT ON (agent_id) 
    a.display_name,
    m.collected_at,
    m.connections_count,
    m.active_transactions,
    m.locks_count,
    pg_size_pretty(m.db_size_bytes) as db_size
FROM pem.metrics_history m
JOIN pem.agents a ON m.agent_id = a.id
ORDER BY agent_id, collected_at DESC;
