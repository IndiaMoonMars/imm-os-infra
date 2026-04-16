-- IMM-OS PostgreSQL Schema: Phase 2

CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) DEFAULT 'user',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS audit_log (
    id BIGSERIAL PRIMARY KEY,
    sensor_id VARCHAR(50) NOT NULL,
    event_timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    checksum VARCHAR(64) NOT NULL,
    received_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sensor_config (
    sensor_id VARCHAR(50) PRIMARY KEY,
    zone VARCHAR(50) NOT NULL,
    sensor_type VARCHAR(50) NOT NULL,
    calibration_offset NUMERIC DEFAULT 0.0,
    is_active BOOLEAN DEFAULT TRUE,
    last_updated TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS alert_history (
    id BIGSERIAL PRIMARY KEY,
    sensor_id VARCHAR(50) NOT NULL,
    metric VARCHAR(50) NOT NULL,
    metric_value NUMERIC NOT NULL,
    zscore NUMERIC NOT NULL,
    alert_timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    acknowledged BOOLEAN DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS command_history (
    id BIGSERIAL PRIMARY KEY,
    operator_id VARCHAR(100) NOT NULL,
    command_text TEXT NOT NULL,
    status VARCHAR(20) DEFAULT 'SENT',
    sent_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS eva_plans (
    id BIGSERIAL PRIMARY KEY,
    crew_members TEXT[] NOT NULL,
    objectives TEXT NOT NULL,
    duration_minutes INTEGER NOT NULL,
    tools_required TEXT[] DEFAULT '{}',
    abort_criteria TEXT,
    checklist JSONB DEFAULT '[]',
    status VARCHAR(20) DEFAULT 'PLANNED',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    go_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE IF NOT EXISTS tool_inventory (
    id BIGSERIAL PRIMARY KEY,
    rfid_tag VARCHAR(100) UNIQUE NOT NULL,
    tool_name VARCHAR(100) NOT NULL,
    category VARCHAR(50),
    is_available BOOLEAN DEFAULT TRUE,
    last_scan TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS tool_checkout (
    id BIGSERIAL PRIMARY KEY,
    rfid_tag VARCHAR(100) NOT NULL REFERENCES tool_inventory(rfid_tag),
    eva_plan_id BIGINT REFERENCES eva_plans(id),
    operator_id VARCHAR(100),
    action VARCHAR(10) NOT NULL CHECK (action IN ('CHECKOUT', 'CHECKIN')),
    scanned_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_audit_log_timestamp ON audit_log(event_timestamp);
CREATE INDEX IF NOT EXISTS idx_sensor_config_zone ON sensor_config(zone);
CREATE INDEX IF NOT EXISTS idx_alert_history_timestamp ON alert_history(alert_timestamp);
CREATE INDEX IF NOT EXISTS idx_command_history_time ON command_history(sent_at);
CREATE INDEX IF NOT EXISTS idx_eva_plans_status ON eva_plans(status);
CREATE INDEX IF NOT EXISTS idx_tool_checkout_tag ON tool_checkout(rfid_tag);
CREATE INDEX IF NOT EXISTS idx_tool_checkout_eva ON tool_checkout(eva_plan_id);
