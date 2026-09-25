-- IMM-OS PostgreSQL Schema: Phase 2

-- Create role and assign permissions for microservices
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'imm_user') THEN
        CREATE ROLE imm_user WITH LOGIN PASSWORD 'imm_pass';
    END IF;
END
$$;
GRANT ALL PRIVILEGES ON DATABASE imm_db TO imm_user;
-- Ensure future tables/sequences inherit permissions in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO imm_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO imm_user;

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

-- ── Phase 5: ECLSS ────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS eclss_lighting_state (
    zone VARCHAR(50) PRIMARY KEY,
    brightness SMALLINT NOT NULL CHECK (brightness BETWEEN 0 AND 100),
    kelvin SMALLINT NOT NULL CHECK (kelvin BETWEEN 2000 AND 6500),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS waste_events (
    id BIGSERIAL PRIMARY KEY,
    weight_kg DOUBLE PRECISION NOT NULL,
    rfid_tag VARCHAR(100) NOT NULL,
    container VARCHAR(100) NOT NULL,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS shower_events (
    id BIGSERIAL PRIMARY KEY,
    duration_seconds DOUBLE PRECISION NOT NULL,
    estimated_liters DOUBLE PRECISION NOT NULL,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS water_flow_events (
    id BIGSERIAL PRIMARY KEY,
    event_ml DOUBLE PRECISION NOT NULL,
    daily_total_ml DOUBLE PRECISION NOT NULL,
    source VARCHAR(100) NOT NULL,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS biolab_readings (
    id BIGSERIAL PRIMARY KEY,
    ph_level DOUBLE PRECISION NOT NULL,
    water_temp_c DOUBLE PRECISION NOT NULL,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_waste_events_time ON waste_events(recorded_at);
CREATE INDEX IF NOT EXISTS idx_shower_events_time ON shower_events(recorded_at);
CREATE INDEX IF NOT EXISTS idx_water_flow_events_time ON water_flow_events(recorded_at);
CREATE INDEX IF NOT EXISTS idx_biolab_readings_time ON biolab_readings(recorded_at);

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

-- ── Phase 9: Medical & Health ─────────────────────────────────────
-- Column names/types follow services/medical_api.py (imm-os-backend).

CREATE TABLE IF NOT EXISTS medical_readings (
    id BIGSERIAL PRIMARY KEY,
    crew_id VARCHAR(100) NOT NULL,
    reading_type VARCHAR(50) NOT NULL, -- 'hr', 'bp_sys', 'bp_dia', 'spo2', 'glucose', 'temp', 'weight', 'ecg_bpm'
    value DOUBLE PRECISION NOT NULL,
    unit VARCHAR(20) NOT NULL,
    device VARCHAR(100) DEFAULT 'manual',
    notes TEXT,
    mission_day INTEGER DEFAULT 1,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS food_items (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,
    calories INTEGER NOT NULL,          -- per 100 g
    protein_g DOUBLE PRECISION NOT NULL,
    carb_g DOUBLE PRECISION NOT NULL,
    fat_g DOUBLE PRECISION NOT NULL,
    category VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS food_log (
    id BIGSERIAL PRIMARY KEY,
    crew_id VARCHAR(100) NOT NULL,
    food_item_id INTEGER REFERENCES food_items(id),
    meal_name VARCHAR(255),
    meal_type VARCHAR(50) DEFAULT 'meal',
    calories INTEGER DEFAULT 0,
    protein_g DOUBLE PRECISION DEFAULT 0,
    carb_g DOUBLE PRECISION DEFAULT 0,
    fat_g DOUBLE PRECISION DEFAULT 0,
    quantity_g DOUBLE PRECISION DEFAULT 100,
    mission_day INTEGER DEFAULT 1,
    logged_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS food_stock (
    id BIGSERIAL PRIMARY KEY,
    item_name VARCHAR(255) NOT NULL,
    quantity DOUBLE PRECISION NOT NULL,
    unit VARCHAR(20) DEFAULT 'kg',
    expiry_date DATE,
    location VARCHAR(100) DEFAULT 'galley',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS medication_log (
    id BIGSERIAL PRIMARY KEY,
    crew_id VARCHAR(100) NOT NULL,
    drug_name VARCHAR(255) NOT NULL,
    dose_mg DOUBLE PRECISION,
    dose_unit VARCHAR(20) DEFAULT 'mg',
    frequency VARCHAR(100),
    stock_count INTEGER DEFAULT 0,
    expiry_date DATE,
    notes TEXT,
    mission_day INTEGER DEFAULT 1,
    last_taken_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS medical_evaluations (
    id BIGSERIAL PRIMARY KEY,
    crew_id VARCHAR(100) NOT NULL,
    evaluator_id VARCHAR(100) NOT NULL,
    diagnosis TEXT,
    treatment_plan TEXT,
    mission_day INTEGER DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS workout_log (
    id BIGSERIAL PRIMARY KEY,
    crew_id VARCHAR(100) NOT NULL,
    exercise_type VARCHAR(100) NOT NULL,
    duration_min INTEGER NOT NULL,
    intensity VARCHAR(20) DEFAULT 'moderate',
    avg_hr INTEGER,
    max_hr INTEGER,
    calories_burned INTEGER,
    hr_data JSONB DEFAULT '[]',
    mission_day INTEGER DEFAULT 1,
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS questionnaire_templates (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL, -- e.g. 'NASA_TLX', 'PSQI', 'GHQ_12'
    description TEXT,
    questions JSONB NOT NULL,
    scoring_rules JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS questionnaire_responses (
    id BIGSERIAL PRIMARY KEY,
    template_id INTEGER REFERENCES questionnaire_templates(id),
    crew_id VARCHAR(100) NOT NULL,
    responses JSONB NOT NULL,
    total_score DOUBLE PRECISION,
    subscores JSONB DEFAULT '{}',
    mission_day INTEGER DEFAULT 1,
    completed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_food_log_crew_day ON food_log(crew_id, mission_day);
CREATE INDEX IF NOT EXISTS idx_medication_log_crew ON medication_log(crew_id);
CREATE INDEX IF NOT EXISTS idx_workout_log_crew_time ON workout_log(crew_id, started_at);
CREATE INDEX IF NOT EXISTS idx_questionnaire_responses_crew ON questionnaire_responses(crew_id);

-- ── Phase 10: Psychology & Sociodynamics ────────────────────────
-- Column names/types follow services/psychology_api.py (imm-os-backend).

CREATE TABLE IF NOT EXISTS sleep_log (
    id BIGSERIAL PRIMARY KEY,
    crew_id VARCHAR(100) NOT NULL,
    sleep_onset TIMESTAMP WITH TIME ZONE,   -- NULL for wearable webhook rows
    wake_time TIMESTAMP WITH TIME ZONE,
    duration_min INTEGER,
    quality_score INTEGER,
    source VARCHAR(50) DEFAULT 'manual',    -- 'manual', 'webhook', device name
    awakenings INTEGER DEFAULT 0,
    rem_min INTEGER DEFAULT 0,
    deep_min INTEGER DEFAULT 0,
    hr_avg INTEGER,
    mission_day INTEGER DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS mood_checkins (
    id BIGSERIAL PRIMARY KEY,
    crew_id VARCHAR(100) NOT NULL,
    period VARCHAR(20) NOT NULL,            -- 'morning' | 'evening'
    score INTEGER NOT NULL CHECK (score BETWEEN 1 AND 5),
    note TEXT,
    mission_day INTEGER DEFAULT 1,
    checked_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS psych_survey_templates (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,      -- e.g. 'PANAS', 'IES_R'
    description TEXT,
    schedule_days INTEGER DEFAULT 7,
    questions JSONB NOT NULL,
    scoring_rules JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS psych_survey_responses (
    id BIGSERIAL PRIMARY KEY,
    template_id INTEGER REFERENCES psych_survey_templates(id),
    crew_id VARCHAR(100) NOT NULL,
    responses JSONB NOT NULL,
    total_score DOUBLE PRECISION,
    subscores JSONB DEFAULT '{}',
    mission_day INTEGER DEFAULT 1,
    completed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sociogram_ratings (
    id BIGSERIAL PRIMARY KEY,
    rater_id VARCHAR(100) NOT NULL,
    ratee_id VARCHAR(100) NOT NULL,
    comfort_score INTEGER NOT NULL CHECK (comfort_score BETWEEN 1 AND 5),
    mission_day INTEGER DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (rater_id, ratee_id, mission_day)
);

CREATE INDEX IF NOT EXISTS idx_sleep_log_crew_day ON sleep_log(crew_id, mission_day);
CREATE INDEX IF NOT EXISTS idx_mood_checkins_crew_day ON mood_checkins(crew_id, mission_day);
CREATE INDEX IF NOT EXISTS idx_psych_survey_responses_crew ON psych_survey_responses(crew_id);

-- ── Phase 11: AI & Autonomous Operations ────────────────────────

CREATE TABLE IF NOT EXISTS ai_insights (
    id BIGSERIAL PRIMARY KEY,
    system_area VARCHAR(50) NOT NULL, -- 'eclss', 'power', 'crew', 'eva'
    insight_type VARCHAR(50) NOT NULL, -- 'anomaly', 'prediction', 'recommendation'
    severity VARCHAR(20) DEFAULT 'info', -- 'info', 'warning', 'critical'
    summary TEXT NOT NULL,
    metadata JSONB DEFAULT '{}', -- stores z-scores, correlation data, model version
    mission_day INTEGER DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS autonomous_actions (
    id BIGSERIAL PRIMARY KEY,
    insight_id BIGINT REFERENCES ai_insights(id),
    action_type VARCHAR(50) NOT NULL, -- 'hvac_adjust', 'power_shed', 'lighting_dim'
    command_issued TEXT NOT NULL,
    reasoning TEXT NOT NULL,
    status VARCHAR(20) DEFAULT 'EXECUTED', -- 'EXECUTED', 'PENDING_APPROVAL', 'OVERRIDDEN'
    crew_override_by VARCHAR(100),
    mission_day INTEGER DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- AI Indexes
CREATE INDEX IF NOT EXISTS idx_medical_readings_crew ON medical_readings(crew_id);
CREATE INDEX IF NOT EXISTS idx_ai_insights_mission_day ON ai_insights(mission_day);
CREATE INDEX IF NOT EXISTS idx_ai_insights_severity ON ai_insights(severity);
CREATE INDEX IF NOT EXISTS idx_autonomous_actions_status ON autonomous_actions(status);
