-- IMM-OS migration 001: align Phase 9/10 tables with medical_api / psychology_api
--
-- The original init.sql created medical and psych tables with a different
-- column design from the one the services use, so medical-api and psych-api
-- crashed on startup. init.sql now matches the services, but on an existing
-- volume `CREATE TABLE IF NOT EXISTS` leaves the old tables in place.
--
-- This drops ONLY tables that still have the old columns (the services could
-- never read or write them, so they hold no usable data). Tables already in
-- the new shape are left alone, so re-running this is safe.
--
-- Apply, then re-run init.sql (idempotent) to create the new tables:
--   docker compose exec -T postgres psql -U admin -d imm_db -v ON_ERROR_STOP=1 < postgres/migrations/001_align_medical_psych_schema.sql
--   docker compose exec -T postgres psql -U admin -d imm_db -v ON_ERROR_STOP=1 < postgres/init.sql

DO $$
DECLARE
    legacy RECORD;
BEGIN
    -- (table, column that only exists in the old design); children before parents
    FOR legacy IN
        SELECT * FROM (VALUES
            ('food_log',                'name_override'),
            ('food_items',              'calories_per_100g'),
            ('questionnaire_responses', 'computed_score'),
            ('questionnaire_templates', 'structure'),
            ('medical_readings',        'type'),
            ('medication_log',          'medication_name'),
            ('workout_log',             'duration_minutes'),
            ('sleep_log',               'onset_at'),
            ('mood_checkins',           'valence')
        ) AS t(tbl, old_col)
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = legacy.tbl
              AND column_name = legacy.old_col
        ) THEN
            RAISE NOTICE 'Dropping legacy table % (has old column %)', legacy.tbl, legacy.old_col;
            EXECUTE format('DROP TABLE %I CASCADE', legacy.tbl);
        END IF;
    END LOOP;
END
$$;
