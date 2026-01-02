-- =========================================
-- 01. Function: set_updated_at
-- =========================================
-- Purpose:
--   Automatically updates the `updated_at` timestamp column to the current time
--   whenever a row is modified in tables that have an `updated_at` column.
--
-- Behavior:
--   - Trigger fires BEFORE UPDATE on the table.
--   - Compares NEW and OLD row data; updates `updated_at` only if the row has changed.
--   - Ensures that unnecessary writes are avoided when no actual data modification occurs.
--
-- Parameters:
--   NEW - The new row version being updated.
--   OLD - The previous row version.
--
-- Returns:
--   NEW - Modified row with updated timestamp (if applicable).
--
-- Notes:
--   - SECURITY DEFINER allows execution even under restrictive row-level security policies.
--   - Trigger creation is dynamic for all public tables containing an `updated_at` column.
--   - Trigger names are deterministically generated using the first 10 characters of the table name's MD5 hash.
--   - Ensures consistent timestamp maintenance across multiple tables without manual intervention.
-- =========================================
CREATE OR REPLACE FUNCTION util.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
VOLATILE
AS $$
BEGIN
    -- Only update timestamp when row data actually changes
    IF NEW IS DISTINCT FROM OLD THEN
        NEW.updated_at := NOW();
    END IF;

    RETURN NEW;
END;
$$;

-- Apply to all tables with updated_at column in relevant schemas
DO $$
DECLARE
    r record;
    trigger_name text;
BEGIN
    FOR r IN
        SELECT table_schema, table_name
        FROM information_schema.columns c
        WHERE c.column_name = 'updated_at'
          AND c.table_schema IN ('core', 'finance', 'audit', 'api')  -- include all relevant schemas
    LOOP
        -- Deterministic, length-safe trigger name
        trigger_name := 'trg_updated_at_' || substr(md5(r.table_schema || '.' || r.table_name), 1, 10);

        BEGIN
            EXECUTE format(
                'CREATE TRIGGER %I
                 BEFORE UPDATE ON %I.%I
                 FOR EACH ROW
                 EXECUTE FUNCTION util.set_updated_at();',
                trigger_name,
                r.table_schema,
                r.table_name
            );
        EXCEPTION
            WHEN duplicate_object THEN
                -- Trigger already exists, safe to ignore
                NULL;
        END;
    END LOOP;
END;
$$;

-- =========================================
-- 02. Function: enforce_soft_delete
-- =========================================
-- Purpose:
--   Implements soft delete functionality by preventing physical deletion of rows
--   and instead marking them as deleted using the `deleted_at` timestamp.
--
-- Behavior:
--   - Trigger fires BEFORE DELETE on the target table.
--   - Checks the `app.hard_delete` setting; allows actual deletion if set to 'on'.
--   - Dynamically determines the primary key column (`id`, `account_id`, or `transaction_id`) for the table.
--   - Updates `deleted_at` and `updated_at` columns to the current timestamp.
--   - Prevents the physical deletion by returning NULL.
--
-- Parameters:
--   OLD - The row that would be deleted.
--   TG_TABLE_NAME - Name of the table that fired the trigger.
--
-- Returns:
--   NULL - Prevents the actual delete operation; triggers the soft delete instead.
--
-- Notes:
--   - SECURITY DEFINER allows execution even under restrictive row-level security policies.
--   - Supports tables with different primary key names and UUID or other types.
--   - Triggers are dynamically created for a predefined list of major tables to enforce soft deletes.
--   - Ensures consistent soft delete behavior across the schema without modifying application logic.
-- =========================================
CREATE OR REPLACE FUNCTION util.enforce_soft_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
VOLATILE
AS $$
DECLARE
    pk_col text;
    pk_type text;
    pk_val text;
    target_schema text := TG_TABLE_SCHEMA;
BEGIN
    -- Skip soft delete if hard delete mode is on
    IF current_setting('app.hard_delete', true) = 'on' THEN
        RETURN OLD; -- allow actual delete
    END IF;

    -- Determine primary key column dynamically
    SELECT column_name, data_type
    INTO pk_col, pk_type
    FROM information_schema.columns
    WHERE table_schema = target_schema
      AND table_name = TG_TABLE_NAME
      AND column_name IN ('id','account_id','transaction_id')
    ORDER BY CASE column_name 
                 WHEN 'id' THEN 1 
                 WHEN 'account_id' THEN 2 
                 WHEN 'transaction_id' THEN 3 
             END
    LIMIT 1;

   IF pk_col IS NULL THEN
        RAISE EXCEPTION 'Cannot determine primary key column for %.%',
            target_schema,
            TG_TABLE_NAME
            USING ERRCODE = 'P0002';
    END IF;

    -- Get primary key value from OLD row
    EXECUTE format('SELECT ($1).%I::text', pk_col)
    INTO pk_val
    USING OLD;

    -- Skip if primary key value is NULL
    IF pk_val IS NULL THEN
        RETURN OLD;
    END IF;

    -- Perform soft delete with safe UUID handling
    IF pk_type LIKE '%uuid%' THEN
        BEGIN
            EXECUTE format(
                'UPDATE %I.%I SET deleted_at = NOW(), updated_at = NOW() WHERE %I = $1::uuid',
                target_schema, TG_TABLE_NAME, pk_col
            ) USING pk_val;
        EXCEPTION WHEN invalid_text_representation THEN
            -- Skip rows with invalid UUIDs
            RETURN OLD;
        END;
    ELSE
        EXECUTE format(
            'UPDATE %I.%I SET deleted_at = NOW(), updated_at = NOW() WHERE %I = $1',
            target_schema, TG_TABLE_NAME, pk_col
        ) USING pk_val;
    END IF;

    -- Prevent actual delete
    RETURN NULL;
END;
$$;

-- Apply Soft Delete Triggers to all major tables
DO $$
DECLARE
    tbl text[];
    trigger_name text;
    -- List of tables with schema qualification
    tables_to_protect text[][] := ARRAY[
        ['core','profiles'], 
        ['finance','accounts'], 
        ['finance','transactions'], 
        ['finance','counterparties'],
        ['finance','expense_categories'], 
        ['finance','expense_subcategories'], 
        ['finance','income_sources'], 
        ['finance','transactions_recurring'],
        ['finance','cash_accounts'], 
        ['finance','bank_accounts'], 
        ['finance','credit_card_accounts'], 
        ['finance','loan_accounts'], 
        ['finance','investment_accounts'], 
        ['finance','crypto_accounts'], 
        ['finance','wallet_accounts'], 
        ['finance','receivable_accounts'],
        ['finance','transactions_income'], 
        ['finance','transactions_expense'], 
        ['finance','transactions_investment'],
        ['finance','transactions_borrow'], 
        ['finance','transactions_lend'], 
        ['finance','transactions_transfer'], 
        ['finance','transactions_adjustment'],
        ['finance','exchange_rates']
    ];
    i int;
BEGIN
    FOR i IN array_lower(tables_to_protect,1)..array_upper(tables_to_protect,1) LOOP
        -- Deterministic trigger name
        trigger_name := 'trg_' || tables_to_protect[i][2] || '_no_delete';

        -- Attempt trigger creation, ignore duplicates
        BEGIN
            EXECUTE format(
                'CREATE TRIGGER %I
                BEFORE DELETE ON %I.%I
                FOR EACH ROW
                EXECUTE FUNCTION util.enforce_soft_delete();',
                trigger_name,
                tables_to_protect[i][1], tables_to_protect[i][2]
            );
        EXCEPTION
            WHEN duplicate_object THEN
                    -- Trigger already exists, safe to ignore
                NULL;
        END;
    END LOOP;
END;
$$;

-- =========================================
-- 03. Function: log_audit
-- =========================================
-- Purpose:
--   Logs all changes (INSERT, UPDATE, DELETE) to specified tables into the
--   `audit_logs` table for audit and traceability purposes.
--
-- Behavior:
--   - Trigger fires AFTER INSERT, UPDATE, or DELETE on the target table.
--   - Dynamically determines the affected user (`user_id`) from the row data.
--   - Captures the primary key / record ID dynamically (supports `id`, `account_id`, or `transaction_id`).
--   - Inserts a record into `audit_logs` containing the action type, affected user,
--     actor user (fallback service/system user), old and new row data as JSON.
--
-- Parameters:
--   OLD - Previous row version (for UPDATE/DELETE)
--   NEW - New row version (for INSERT/UPDATE)
--   TG_OP - Operation type triggering the function ('INSERT', 'UPDATE', 'DELETE')
--   TG_TABLE_NAME - Name of the table that fired the trigger
--
-- Returns:
--   NULL - This is a trigger function; the return value is ignored for AFTER triggers
--
-- Notes:
--   - SECURITY DEFINER allows execution even under restrictive row-level security policies.
--   - Uses `hstore` for dynamic access to column data regardless of table schema.
--   - Includes a safety check to ensure a valid record ID is present before logging.
--   - Triggers are dynamically created for relevant tables excluding `audit_logs` itself.
--   - Ensures comprehensive audit logging without modifying individual table logic.
-- =========================================
CREATE OR REPLACE FUNCTION audit.log_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, extensions, audit, finance, core, util
VOLATILE
AS $$
DECLARE
    affected_user_id UUID;
    record_id UUID;
    record_id_candidate TEXT;
    row_data hstore;
    session_setting TEXT;
    action_label TEXT;
    extracted_uuid UUID;
    v_executed_by TEXT;
BEGIN
    -- 1. SAFETY GUARD: never audit the audit_logs table itself
    IF TG_TABLE_SCHEMA = 'audit' AND TG_TABLE_NAME = 'audit_logs' THEN
        RETURN NULL;
    END IF;

    -- 2. DETERMINE ACTOR (JWT subject → auth.users.id)
    session_setting := current_setting('request.jwt.claim.sub', true);

    -- Handle the case where session_setting is non-UUID
    IF session_setting IS NOT NULL THEN
        BEGIN
            -- Try to convert to UUID
            extracted_uuid := session_setting::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            -- If conversion fails, set to NULL
            extracted_uuid := NULL;
            RAISE NOTICE 'Invalid JWT claim for extracted_uuid: %', session_setting;
        END;
    ELSE
        extracted_uuid := NULL;
    END IF;

    -- 3. DETERMINE ACTION LABEL
    action_label := TG_OP; -- Default: INSERT, UPDATE, DELETE

    -- Special case for profiles table admin changes
    IF TG_OP = 'UPDATE'
       AND TG_TABLE_SCHEMA = 'core'
       AND TG_TABLE_NAME = 'profiles'
       AND OLD.is_admin IS DISTINCT FROM NEW.is_admin THEN
        action_label := 'ADMIN_PRIVILEGE_CHANGE';
    END IF;

    -- Detect soft delete (deleted_at transition)
    IF TG_OP = 'UPDATE'
       AND (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL) THEN
        action_label := 'SOFT_DELETE';
    END IF;

    -- 4. NORMALIZE ROW DATA
    row_data := hstore(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);

    -- 5. RESOLVE AFFECTED USER (ALWAYS core.profiles.id)
    affected_user_id := NULL;

    -- a. Direct user_id → core.profiles.id
    IF row_data ? 'user_id' AND row_data -> 'user_id' IS NOT NULL THEN
        BEGIN
            -- Some tables store core.profiles.id directly
            SELECT p.id
            INTO affected_user_id
            FROM core.profiles p
            WHERE p.id = (row_data -> 'user_id')::uuid;
        EXCEPTION WHEN invalid_text_representation OR NO_DATA_FOUND THEN
            affected_user_id := NULL;
        END;
    END IF;

    -- b. Via account ownership
    IF affected_user_id IS NULL AND row_data ? 'account_id' AND row_data -> 'account_id' IS NOT NULL THEN
        BEGIN
            SELECT a.user_id
            INTO affected_user_id
            FROM finance.accounts a
            WHERE a.id = (row_data -> 'account_id')::uuid;
        EXCEPTION WHEN invalid_text_representation OR NO_DATA_FOUND THEN
            affected_user_id := NULL;
        END;
    END IF;

    -- c. Via transaction ownership
    IF affected_user_id IS NULL AND row_data ? 'transaction_id' AND row_data -> 'transaction_id' IS NOT NULL THEN
        BEGIN
            SELECT t.user_id
            INTO affected_user_id
            FROM finance.transactions t
            WHERE t.id = (row_data -> 'transaction_id')::uuid;
        EXCEPTION WHEN invalid_text_representation OR NO_DATA_FOUND THEN
            affected_user_id := NULL;
        END;
    END IF;

    -- d. Expense subcategories → categories → user
    IF affected_user_id IS NULL
       AND TG_TABLE_SCHEMA = 'finance'
       AND TG_TABLE_NAME = 'expense_subcategories'
       AND row_data ? 'category_id'
       AND row_data -> 'category_id' IS NOT NULL THEN
        BEGIN
            SELECT ec.user_id
            INTO affected_user_id
            FROM finance.expense_categories ec
            WHERE ec.id = (row_data -> 'category_id')::uuid;
        EXCEPTION WHEN invalid_text_representation OR NO_DATA_FOUND THEN
            affected_user_id := NULL;
        END;
    END IF;

    -- e. Final fallback: derive from JWT subject → core.profiles
    -- Required because audit.audit_logs.user_id is NOT NULL
    IF affected_user_id IS NULL AND extracted_uuid IS NOT NULL THEN
        SELECT p.id
        INTO affected_user_id
        FROM core.profiles p
        WHERE p.user_id = extracted_uuid;
    END IF;

    -- Absolute safety net (should never happen in normal operation)
    IF affected_user_id IS NULL THEN
        RAISE WARNING 'Audit skipped: unable to resolve affected_user_id for %.%',
                      TG_TABLE_SCHEMA, TG_TABLE_NAME;
        RETURN NULL;
    END IF;

    -- 6. RESOLVE EXECUTED_BY
    IF extracted_uuid IS NOT NULL THEN
        IF EXISTS (
            SELECT 1
            FROM core.profiles p
            WHERE p.id = affected_user_id       -- core.profiles.id
              AND p.user_id = extracted_uuid    -- auth.users.id
        ) THEN
            v_executed_by := util.build_actor_internal('user', extracted_uuid);
        ELSE
            v_executed_by := util.build_actor_internal('admin', extracted_uuid);
        END IF;
    ELSE
        v_executed_by := util.build_actor_internal('system');
    END IF;

    -- 7. RESOLVE RECORD_ID (must correspond to real row identity)
    record_id := NULL;

    FOREACH record_id_candidate IN ARRAY ARRAY['id','account_id','transaction_id'] LOOP
        IF record_id IS NULL
           AND row_data ? record_id_candidate
           AND row_data -> record_id_candidate IS NOT NULL THEN
            BEGIN
                record_id := (row_data -> record_id_candidate)::uuid;
            EXCEPTION WHEN invalid_text_representation THEN
                record_id := NULL;
            END;
        END IF;
    END LOOP;

    IF record_id IS NULL THEN
        RAISE WARNING 'Audit skipped: unable to resolve record_id for %.%',
                      TG_TABLE_SCHEMA, TG_TABLE_NAME;
        RETURN NULL;
    END IF;

    -- 8. INSERT AUDIT LOG
    BEGIN
        INSERT INTO audit.audit_logs (
            user_id,
            executed_by,
            table_name,
            record_id,
            action,
            old_data,
            new_data
        ) VALUES (
            affected_user_id,
            v_executed_by,
            TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
            record_id,
            action_label,
            CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN row_to_json(OLD) ELSE NULL END,
            CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN row_to_json(NEW) ELSE NULL END
        );
    EXCEPTION WHEN OTHERS THEN
        -- Auditing must never block the main database operation
        RAISE WARNING 'Audit log insertion failed for %.%: %',
                      TG_TABLE_SCHEMA, TG_TABLE_NAME, SQLERRM;
        RETURN NULL;
    END;

    -- Standard for AFTER triggers
    RETURN NULL;
END;
$$;

-- Create Audit Triggers for All Enabled Tables
DO $$
DECLARE
    t RECORD;
    trigger_name TEXT;
BEGIN
    FOR t IN
        SELECT r.table_schema, r.table_name
        FROM audit.audit_table_registry r
        WHERE r.enabled = TRUE
    LOOP
        trigger_name := 'trg_audit_' || t.table_schema || '_' || t.table_name;

        BEGIN
            EXECUTE format(
                'CREATE TRIGGER %I
                 AFTER INSERT OR UPDATE OR DELETE ON %I.%I
                 FOR EACH ROW
                 EXECUTE FUNCTION audit.log_audit();',
                trigger_name,
                t.table_schema,
                t.table_name
            );
        EXCEPTION
            WHEN duplicate_object THEN
                -- Trigger already exists, safe to ignore
                NULL;
        END;
    END LOOP;
END;
$$;
