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

-- ── Phase 7: Crew Communications ──────────────────────────────────

CREATE TABLE IF NOT EXISTS threads (
    id BIGSERIAL PRIMARY KEY,
    subject VARCHAR(255) NOT NULL,
    created_by VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS messages (
    id BIGSERIAL PRIMARY KEY,
    thread_id BIGINT REFERENCES threads(id) ON DELETE CASCADE,
    sender_id VARCHAR(100) NOT NULL,
    recipient_group VARCHAR(20) NOT NULL CHECK (recipient_group IN ('astro','mcc','all')),
    subject VARCHAR(255),
    body TEXT NOT NULL,
    delay_seconds NUMERIC DEFAULT 0,
    deliver_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    delivered BOOLEAN DEFAULT FALSE,
    read_by TEXT[] DEFAULT '{}',
    mission_day INTEGER DEFAULT 1,
    sent_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS attachments (
    id BIGSERIAL PRIMARY KEY,
    message_id BIGINT REFERENCES messages(id) ON DELETE CASCADE,
    filename VARCHAR(255) NOT NULL,
    mime_type VARCHAR(100),
    storage_path TEXT NOT NULL,
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS journals (
    id BIGSERIAL PRIMARY KEY,
    author_id VARCHAR(100) NOT NULL,
    title VARCHAR(255),
    body TEXT,
    media_path TEXT,
    media_type VARCHAR(10) CHECK (media_type IN ('text','voice','video')),
    mission_day INTEGER DEFAULT 1,
    tags TEXT[] DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS briefings (
    id BIGSERIAL PRIMARY KEY,
    created_by VARCHAR(100) NOT NULL,
    mission_day INTEGER NOT NULL,
    objectives TEXT,
    eclss_snapshot JSONB DEFAULT '{}',
    eva_summary TEXT,
    assignments JSONB DEFAULT '[]',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS briefing_acks (
    id BIGSERIAL PRIMARY KEY,
    briefing_id BIGINT NOT NULL REFERENCES briefings(id) ON DELETE CASCADE,
    crew_id VARCHAR(100) NOT NULL,
    item_index INTEGER NOT NULL,
    acked_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (briefing_id, crew_id, item_index)
);

CREATE TABLE IF NOT EXISTS push_subscriptions (
    id BIGSERIAL PRIMARY KEY,
    user_id VARCHAR(100) NOT NULL,
    endpoint TEXT NOT NULL UNIQUE,
    p256dh TEXT NOT NULL,
    auth TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS video_logs (
    id BIGSERIAL PRIMARY KEY,
    crew_id VARCHAR(100) NOT NULL,
    title VARCHAR(255),
    media_path TEXT NOT NULL,
    mime_type VARCHAR(50) DEFAULT 'video/mp4',
    mission_day INTEGER DEFAULT 1,
    duration_seconds NUMERIC,
    keywords TEXT[] DEFAULT '{}',
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Comms indexes
CREATE INDEX IF NOT EXISTS idx_messages_deliver_at ON messages(deliver_at);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_recipient ON messages(recipient_group);
CREATE INDEX IF NOT EXISTS idx_journals_author ON journals(author_id);
CREATE INDEX IF NOT EXISTS idx_journals_mission_day ON journals(mission_day);
CREATE INDEX IF NOT EXISTS idx_briefings_mission_day ON briefings(mission_day);
CREATE INDEX IF NOT EXISTS idx_video_logs_mission_day ON video_logs(mission_day);

-- ── Phase 8: Work Scheduling & Procedures ────────────────────────

CREATE TABLE IF NOT EXISTS projects (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    owner_id VARCHAR(100) NOT NULL,
    status VARCHAR(20) DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAUSED','COMPLETE','ARCHIVED')),
    start_date DATE,
    end_date DATE,
    mission_day_start INTEGER DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS tasks (
    id BIGSERIAL PRIMARY KEY,
    project_id BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    parent_task_id BIGINT REFERENCES tasks(id) ON DELETE CASCADE,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    assignee_id VARCHAR(100),
    status VARCHAR(20) DEFAULT 'PENDING' CHECK (status IN ('PENDING','IN_PROGRESS','BLOCKED','COMPLETE','CANCELLED')),
    priority VARCHAR(10) DEFAULT 'NORMAL' CHECK (priority IN ('LOW','NORMAL','HIGH','CRITICAL')),
    deadline TIMESTAMP WITH TIME ZONE,
    mission_day INTEGER DEFAULT 1,
    completed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS milestones (
    id BIGSERIAL PRIMARY KEY,
    project_id BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    target_date DATE NOT NULL,
    reached BOOLEAN DEFAULT FALSE,
    reached_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE IF NOT EXISTS procedures (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    category VARCHAR(100),
    description TEXT,
    version VARCHAR(20) DEFAULT '1.0',
    steps JSONB NOT NULL DEFAULT '[]',
    created_by VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS procedure_runs (
    id BIGSERIAL PRIMARY KEY,
    procedure_id BIGINT NOT NULL REFERENCES procedures(id) ON DELETE CASCADE,
    crew_id VARCHAR(100) NOT NULL,
    task_id BIGINT REFERENCES tasks(id),
    status VARCHAR(20) DEFAULT 'IN_PROGRESS' CHECK (status IN ('IN_PROGRESS','COMPLETE','ABORTED')),
    current_step INTEGER DEFAULT 0,
    step_timestamps JSONB DEFAULT '{}',
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE
);

-- Scheduling indexes
CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id);
CREATE INDEX IF NOT EXISTS idx_tasks_assignee ON tasks(assignee_id);
CREATE INDEX IF NOT EXISTS idx_tasks_deadline ON tasks(deadline);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_procedure_runs_status ON procedure_runs(status);
CREATE INDEX IF NOT EXISTS idx_milestones_date ON milestones(target_date);
