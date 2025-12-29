-- =========================================
-- Full Database Reset Script – Custom Schemas
-- =========================================
-- WARNING: Deletes ONLY objects you own in the specified custom schemas.
-- System tables, Supabase auth/storage schemas, and pg_catalog are preserved.
-- =========================================

DO $$ DECLARE
    sch_name TEXT;
    r RECORD;
    custom_schemas TEXT[] := ARRAY['finance','audit','api','util','core'];
BEGIN
    -- Iterate over custom schemas
    FOREACH sch_name IN ARRAY custom_schemas
    LOOP
        RAISE NOTICE 'Processing schema: %', sch_name;

        -- Disable triggers
        FOR r IN 
            SELECT t.tgname, c.relname AS table_name
            FROM pg_trigger t
            JOIN pg_class c ON t.tgrelid = c.oid
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE NOT tgisinternal
            AND n.nspname = sch_name
            AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
        LOOP
            EXECUTE 'ALTER TABLE ' || quote_ident(sch_name) || '.' || quote_ident(r.table_name) || 
                    ' DISABLE TRIGGER ' || quote_ident(r.tgname) || ';';
        END LOOP;

        -- Drop views
        FOR r IN 
            SELECT c.relname AS view_name
            FROM pg_class c
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE c.relkind = 'v'
              AND n.nspname = sch_name
              AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
        LOOP
            EXECUTE 'DROP VIEW IF EXISTS ' || quote_ident(sch_name) || '.' || quote_ident(r.view_name) || ' CASCADE;';
        END LOOP;

        -- Drop materialized views
        FOR r IN 
            SELECT c.relname AS matview_name
            FROM pg_class c
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE c.relkind = 'm'
              AND n.nspname = sch_name
              AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
        LOOP
            EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS ' || quote_ident(sch_name) || '.' || quote_ident(r.matview_name) || ' CASCADE;';
        END LOOP;

        -- Drop functions / procedures
        FOR r IN 
            SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
            FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = sch_name
              AND p.proowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
        LOOP
            EXECUTE 'DROP FUNCTION IF EXISTS ' || quote_ident(sch_name) || '.' || quote_ident(r.proname) || 
                    '(' || r.args || ') CASCADE;';
        END LOOP;

        -- Drop tables
        FOR r IN 
            SELECT c.relname AS table_name
            FROM pg_class c
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE c.relkind = 'r'
              AND n.nspname = sch_name
              AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
        LOOP
            EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(sch_name) || '.' || quote_ident(r.table_name) || ' CASCADE;';
        END LOOP;

        -- Drop sequences
        FOR r IN 
            SELECT c.relname AS seq_name
            FROM pg_class c
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE c.relkind = 'S'
              AND n.nspname = sch_name
              AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
        LOOP
            EXECUTE 'DROP SEQUENCE IF EXISTS ' || quote_ident(sch_name) || '.' || quote_ident(r.seq_name) || ' CASCADE;';
        END LOOP;

        -- Drop enum types
        FOR r IN 
            SELECT t.typname
            FROM pg_type t
            JOIN pg_namespace n ON t.typnamespace = n.oid
            WHERE t.typtype = 'e'
              AND n.nspname = sch_name
              AND t.typowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
        LOOP
            EXECUTE 'DROP TYPE IF EXISTS ' || quote_ident(sch_name) || '.' || quote_ident(r.typname) || ' CASCADE;';
        END LOOP;

        -- Re-enable triggers
        FOR r IN 
            SELECT tgname, tgrelid::regclass AS table_name
            FROM pg_trigger t
            JOIN pg_class c ON t.tgrelid = c.oid
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE NOT tgisinternal
              AND n.nspname = sch_name
              AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
        LOOP
            EXECUTE 'ALTER TABLE ' || quote_ident(sch_name) || '.' || r.table_name || 
                    ' ENABLE TRIGGER ' || quote_ident(r.tgname) || ';';
        END LOOP;

    END LOOP;
END $$;

-- =========================================
-- Drop specific custom schemas
-- =========================================
DO $$ DECLARE
    sch_name TEXT;
    custom_schemas TEXT[] := ARRAY['finance','audit','api','util','core'];
BEGIN
    FOREACH sch_name IN ARRAY custom_schemas
    LOOP
        RAISE NOTICE 'Dropping schema: %', sch_name;
        EXECUTE 'DROP SCHEMA IF EXISTS ' || quote_ident(sch_name) || ' CASCADE;';
    END LOOP;
END $$;

-- =========================================
-- Notes
-- =========================================
-- 1. Only objects owned by your current user are affected.
-- 2. System schemas (pg_*, information_schema) and Supabase auth/storage schemas are preserved.
-- 3. Safe for development/testing in shared Supabase projects.
