-- =========================================
-- Full Database Reset Script – Spendle (User-Owned Only)
-- =========================================
-- WARNING: Deletes ONLY objects you own in the current schema.
-- System tables and Supabase storage/auth tables are preserved.
-- =========================================

-- Disable all user-owned triggers
DO $$ DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT tgname, tgrelid::regclass AS table_name
        FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE NOT tgisinternal       -- skip system triggers
          AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
    LOOP
        EXECUTE 'ALTER TABLE ' || r.table_name || ' DISABLE TRIGGER ' || quote_ident(r.tgname) || ';';
    END LOOP;
END $$;

-- Drop all views owned by current user
DO $$ DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT c.relname AS view_name
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE c.relkind = 'v'
          AND n.nspname = current_schema()
          AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
    LOOP
        EXECUTE 'DROP VIEW IF EXISTS ' || quote_ident(r.view_name) || ' CASCADE;';
    END LOOP;
END $$;

-- Drop all materialized views owned by current user
DO $$ DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT c.relname AS matview_name
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE c.relkind = 'm'
          AND n.nspname = current_schema()
          AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
    LOOP
        EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS ' || quote_ident(r.matview_name) || ' CASCADE;';
    END LOOP;
END $$;

-- Drop all functions / procedures owned by current user
DO $$ DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = current_schema()
          AND p.proowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || quote_ident(r.proname) || '(' || r.args || ') CASCADE;';
    END LOOP;
END $$;

-- Drop all tables owned by current user
DO $$ DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE c.relkind = 'r'
          AND n.nspname = current_schema()
          AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
    LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.table_name) || ' CASCADE;';
    END LOOP;
END $$;

-- Drop all sequences owned by current user
DO $$ DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT c.relname AS seq_name
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE c.relkind = 'S'
          AND n.nspname = current_schema()
          AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
    LOOP
        EXECUTE 'DROP SEQUENCE IF EXISTS ' || quote_ident(r.seq_name) || ' CASCADE;';
    END LOOP;
END $$;

-- Drop all enum types owned by current user
DO $$ DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT t.typname
        FROM pg_type t
        JOIN pg_namespace n ON t.typnamespace = n.oid
        WHERE t.typtype = 'e'
          AND n.nspname = current_schema()
          AND t.typowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
    LOOP
        EXECUTE 'DROP TYPE IF EXISTS ' || quote_ident(r.typname) || ' CASCADE;';
    END LOOP;
END $$;

-- Re-enable remaining triggers you own
DO $$ DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT tgname, tgrelid::regclass AS table_name
        FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE NOT tgisinternal
          AND c.relowner = (SELECT usesysid FROM pg_user WHERE usename = current_user)
    LOOP
        EXECUTE 'ALTER TABLE ' || r.table_name || ' ENABLE TRIGGER ' || quote_ident(r.tgname) || ';';
    END LOOP;
END $$;

-- =========================================
-- Notes
-- =========================================
-- 1. Only objects owned by your current user are affected.
-- 2. System triggers, Supabase storage, and auth tables are preserved.
-- 3. Safe for development/testing in shared Supabase projects.
