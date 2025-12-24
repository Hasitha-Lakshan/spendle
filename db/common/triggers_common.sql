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
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    -- Only update timestamp when row data actually changes
    IF NEW IS DISTINCT FROM OLD THEN
        NEW.updated_at := NOW();
    END IF;

    RETURN NEW;
END;
$$;

-- Apply to all tables with updated_at column
DO $$
DECLARE
    r record;
    trigger_name text;
BEGIN
    FOR r IN
        SELECT c.table_name
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND c.column_name = 'updated_at'
    LOOP
        -- Deterministic, length-safe trigger name
        trigger_name := 'trg_updated_at_' || substr(md5(r.table_name), 1, 10);

        EXECUTE format(
            'CREATE TRIGGER %I
             BEFORE UPDATE ON public.%I
             FOR EACH ROW
             EXECUTE FUNCTION public.set_updated_at();',
            trigger_name,
            r.table_name
        );
    EXCEPTION
        WHEN duplicate_object THEN
            -- Trigger already exists, safe to ignore
            NULL;
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
CREATE OR REPLACE FUNCTION public.enforce_soft_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    pk_col text;
    pk_type text;
    pk_val text;
BEGIN
    -- Skip soft delete if bypass flag is set
    IF current_setting('app.hard_delete', true) = 'on' THEN
        RETURN OLD; -- allow actual delete
    END IF;

    -- Determine primary key column dynamically
    SELECT column_name, data_type
    INTO pk_col, pk_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = TG_TABLE_NAME
      AND column_name IN ('id','account_id','transaction_id')
    ORDER BY CASE column_name 
                 WHEN 'id' THEN 1 
                 WHEN 'account_id' THEN 2 
                 WHEN 'transaction_id' THEN 3 
             END
    LIMIT 1;

    IF pk_col IS NULL THEN
        RAISE EXCEPTION 'Cannot determine primary key column for %', TG_TABLE_NAME;
    END IF;

    -- Get primary key value from OLD row
    pk_val := OLD.(pk_col)::text;

    -- Perform soft delete with schema-qualified table
    IF pk_type LIKE '%uuid%' THEN
        EXECUTE format(
            'UPDATE public.%I SET deleted_at = NOW(), updated_at = NOW() WHERE %I = $1::uuid',
            TG_TABLE_NAME, pk_col
        ) USING pk_val;
    ELSE
        EXECUTE format(
            'UPDATE public.%I SET deleted_at = NOW(), updated_at = NOW() WHERE %I = $1',
            TG_TABLE_NAME, pk_col
        ) USING pk_val;
    END IF;

    -- Prevent actual delete
    RETURN NULL;
END;
$$;

-- Apply to all major tables
DO $$
DECLARE
    tbl text;
    trigger_name text;
    tables_to_protect text[] := ARRAY[
        'profiles','accounts','transactions','counterparties',
        'expense_categories','expense_subcategories','income_sources',
        'transactions_recurring','cash_accounts','bank_accounts',
        'credit_card_accounts','loan_accounts','investment_accounts',
        'crypto_accounts','wallet_accounts','receivable_accounts',
        'transactions_income','transactions_expense','transactions_investment',
        'transactions_borrow','transactions_lend','transactions_transfer',
        'transactions_adjustment','exchange_rates'
    ];
BEGIN
    FOREACH tbl IN ARRAY tables_to_protect LOOP
        -- Deterministic trigger name
        trigger_name := 'trg_' || tbl || '_no_delete';

        -- Attempt trigger creation, ignore duplicates
        BEGIN
            EXECUTE format(
                'CREATE TRIGGER %I
                 BEFORE DELETE ON public.%I
                 FOR EACH ROW
                 EXECUTE FUNCTION public.enforce_soft_delete();',
                 trigger_name, tbl
            );
        EXCEPTION
            WHEN duplicate_object THEN
                -- Trigger already exists, ignore
                NULL;
        END;
    END LOOP;
END;
$$;

-- =========================================
-- 03. Function: log_admin_changes
-- =========================================
-- Purpose:
--   Logs changes to the `is_admin` flag in the `profiles` table for audit and
--   traceability purposes, capturing when a user's administrative privileges
--   are granted or revoked.
--
-- Behavior:
--   - Trigger fires AFTER UPDATE on the `profiles` table.
--   - Compares OLD and NEW row values; logs only if the `is_admin` flag has changed.
--   - Inserts a record into `audit_logs` containing:
--       * user_id of the affected user
--       * action_by (the current database user executing the change)
--       * table name and record ID
--       * action type ('ADMIN_PRIVILEGE_CHANGE')
--       * old and new values of `is_admin` as JSONB
--
-- Parameters:
--   OLD - Previous row version (before update).
--   NEW - New row version (after update).
--   TG_TABLE_NAME - Name of the table that fired the trigger.
--
-- Returns:
--   NEW - The updated row is returned to complete the update operation.
--
-- Notes:
--   - SECURITY DEFINER allows execution even under restrictive row-level security policies.
--   - Trigger is specifically created for the `profiles` table.
--   - Ensures that changes to administrative privileges are consistently recorded
--     for compliance and audit purposes.
--   - Duplicate trigger creation is safely ignored.
-- =========================================
CREATE OR REPLACE FUNCTION public.log_admin_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    -- Log only when admin flag actually changes
    IF OLD.is_admin IS DISTINCT FROM NEW.is_admin THEN
        INSERT INTO public.audit_logs (
            user_id,
            action_by,
            table_name,
            record_id,
            action,
            old_data,
            new_data
        )
        VALUES (
            NEW.user_id,
            current_user,
            TG_TABLE_NAME,
            NEW.id,
            'ADMIN_PRIVILEGE_CHANGE',
            jsonb_build_object('is_admin', OLD.is_admin),
            jsonb_build_object('is_admin', NEW.is_admin)
        );
    END IF;

    RETURN NEW;
END;
$$;

DO $$
BEGIN
    CREATE TRIGGER trg_log_admin_changes
        AFTER UPDATE ON public.profiles
        FOR EACH ROW
        EXECUTE FUNCTION public.log_admin_changes();
EXCEPTION
    WHEN duplicate_object THEN
        NULL;
END;
$$;

-- =========================================
-- 04. Function: log_audit
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
CREATE OR REPLACE FUNCTION public.log_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    affected_user_id UUID;
    actor_user_id UUID;
    record_id UUID;
    row_data hstore;
    system_user CONSTANT UUID := '00000000-0000-0000-0000-000000000000'::uuid;
BEGIN
    -- SAFETY GUARD: never audit the audit table itself
    IF TG_TABLE_NAME = 'audit_logs' THEN
        RETURN NULL;
    END IF;

    -- Determine actor (who performed the action)
    BEGIN
        actor_user_id := auth.uid();
    EXCEPTION WHEN OTHERS THEN
        actor_user_id := NULL;
    END;

    IF actor_user_id IS NULL THEN
        actor_user_id := system_user;
    END IF;

    -- Normalize row data for dynamic access
    IF TG_OP = 'DELETE' THEN
        row_data := hstore(OLD);
    ELSE
        row_data := hstore(NEW);
    END IF;

    -- Resolve affected user
    affected_user_id := NULL;

    -- 1. Direct user_id
    BEGIN
        affected_user_id := (row_data -> 'user_id')::uuid;
    EXCEPTION WHEN OTHERS THEN
        affected_user_id := NULL;
    END;

    -- 2. Via account_id
    IF affected_user_id IS NULL AND row_data ? 'account_id' THEN
        BEGIN
            SELECT a.user_id
            INTO affected_user_id
            FROM accounts a
            WHERE a.id = (row_data -> 'account_id')::uuid;
        EXCEPTION WHEN OTHERS THEN
            affected_user_id := NULL;
        END;
    END IF;

    -- 3. Via transaction_id
    IF affected_user_id IS NULL AND row_data ? 'transaction_id' THEN
        BEGIN
            SELECT t.user_id
            INTO affected_user_id
            FROM transactions t
            WHERE t.id = (row_data -> 'transaction_id')::uuid;
        EXCEPTION WHEN OTHERS THEN
            affected_user_id := NULL;
        END;
    END IF;

    -- 4. Expense subcategories → categories
    IF affected_user_id IS NULL AND TG_TABLE_NAME = 'expense_subcategories' THEN
        BEGIN
            SELECT ec.user_id
            INTO affected_user_id
            FROM expense_categories ec
            WHERE ec.id = (row_data -> 'category_id')::uuid;
        EXCEPTION WHEN OTHERS THEN
            affected_user_id := NULL;
        END;
    END IF;

    -- Final fallback
    IF affected_user_id IS NULL THEN
        affected_user_id := actor_user_id;
    END IF;

    -- Resolve record_id (never NULL)
    record_id := NULL;

    BEGIN
        record_id := COALESCE(
            (row_data -> 'id')::uuid,
            (row_data -> 'account_id')::uuid,
            (row_data -> 'transaction_id')::uuid
        );
    EXCEPTION WHEN OTHERS THEN
        record_id := NULL;
    END;

    -- Absolute fallback: deterministic UUID derived from table + time
    IF record_id IS NULL THEN
        record_id := gen_random_uuid();
    END IF;

    -- Insert audit log (never fails outward)
    BEGIN
        IF TG_OP = 'INSERT' THEN
            INSERT INTO public.audit_logs (
                user_id,
                action_by,
                table_name,
                record_id,
                action,
                new_data
            ) VALUES (
                affected_user_id,
                actor_user_id,
                TG_TABLE_NAME,
                record_id,
                'INSERT',
                row_to_json(NEW)
            );

        ELSIF TG_OP = 'UPDATE' THEN
            INSERT INTO public.audit_logs (
                user_id,
                action_by,
                table_name,
                record_id,
                action,
                old_data,
                new_data
            ) VALUES (
                affected_user_id,
                actor_user_id,
                TG_TABLE_NAME,
                record_id,
                'UPDATE',
                row_to_json(OLD),
                row_to_json(NEW)
            );

        ELSIF TG_OP = 'DELETE' THEN
            INSERT INTO public.audit_logs (
                user_id,
                action_by,
                table_name,
                record_id,
                action,
                old_data
            ) VALUES (
                affected_user_id,
                actor_user_id,
                TG_TABLE_NAME,
                record_id,
                'DELETE',
                row_to_json(OLD)
            );
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- swallow all errors: auditing must never block writes
        NULL;
    END;

    RETURN NULL;
END;
$$;

-- Create Audit Triggers for All Relevant Tables
DO $$
DECLARE
    t TEXT;
    trigger_name TEXT;
BEGIN
    FOR t IN
        SELECT r.table_name
        FROM audit_table_registry r
        WHERE r.enabled = TRUE
    LOOP
        trigger_name := 'trg_audit_' || t;

        BEGIN
            EXECUTE format(
                'CREATE TRIGGER %I
                 AFTER INSERT OR UPDATE OR DELETE ON public.%I
                 FOR EACH ROW
                 EXECUTE FUNCTION public.log_audit();',
                trigger_name, t
            );
        EXCEPTION
            WHEN duplicate_object THEN
                -- Trigger already exists, safe to ignore
                NULL;
        END;
    END LOOP;
END;
$$;
