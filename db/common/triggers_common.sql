-- =========================================
-- 01. Function: log_audit
-- =========================================
-- Purpose:
--   Provides RLS-compliant audit logging for INSERT, UPDATE, and DELETE operations across multiple tables.
--   Tracks both the affected user and the actor performing the action.
--
-- Behavior:
--   - Determines affected_user_id based on standard user_id columns or recursively from related tables (accounts, transactions, expense_subcategories)
--   - Determines actor_user_id using auth.uid(); defaults to affected_user_id if session user is null
--   - Dynamically identifies the primary key of the affected record (id, account_id, transaction_id)
--   - Inserts audit logs into the audit_logs table with old_data and new_data as JSON
--   - Works for tables with varying schemas and handles exceptions for missing columns
--
-- Parameters:
--   OLD - Previous row version (for UPDATE and DELETE)
--   NEW - New row version (for INSERT and UPDATE)
--
-- Returns:
--   NULL - Since this is an AFTER trigger
--
-- Notes:
--   - SECURITY DEFINER allows logging even when RLS is applied
--   - Trigger creation is dynamic for all relevant public tables except audit_logs
--   - Ensures comprehensive tracking of user actions without hardcoding table-specific logic
-- =========================================
CREATE OR REPLACE FUNCTION log_audit() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    affected_user_id UUID;
    actor_user_id UUID;
    record_id UUID;
BEGIN
    -- Determine affected user
    BEGIN
        IF TG_OP = 'DELETE' THEN
            affected_user_id := OLD.user_id;
        ELSE
            affected_user_id := NEW.user_id;
        END IF;
    EXCEPTION WHEN undefined_column THEN
        -- Recursive resolution for known FK patterns
        IF TG_OP = 'DELETE' THEN
            IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = TG_TABLE_NAME AND column_name = 'account_id') THEN
                SELECT a.user_id INTO affected_user_id FROM accounts a WHERE a.id = OLD.account_id;
            ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = TG_TABLE_NAME AND column_name = 'transaction_id') THEN
                SELECT t.user_id INTO affected_user_id FROM transactions t WHERE t.id = OLD.transaction_id;
            ELSIF TG_TABLE_NAME = 'expense_subcategories' THEN
                SELECT ec.user_id INTO affected_user_id
                FROM expense_categories ec WHERE ec.id = OLD.category_id;
            ELSE
                affected_user_id := NULL;
            END IF;
        ELSE
            IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = TG_TABLE_NAME AND column_name = 'account_id') THEN
                SELECT a.user_id INTO affected_user_id FROM accounts a WHERE a.id = NEW.account_id;
            ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = TG_TABLE_NAME AND column_name = 'transaction_id') THEN
                SELECT t.user_id INTO affected_user_id FROM transactions t WHERE t.id = NEW.transaction_id;
            ELSIF TG_TABLE_NAME = 'expense_subcategories' THEN
                SELECT ec.user_id INTO affected_user_id
                FROM expense_categories ec WHERE ec.id = NEW.category_id;
            ELSE
                affected_user_id := NULL;
            END IF;
        END IF;
    END;

    -- Actor = current session user
    actor_user_id := auth.uid();
    IF actor_user_id IS NULL THEN
        actor_user_id := affected_user_id;
    END IF;

    -- Determine primary key for record
    IF TG_OP = 'DELETE' THEN
        IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = TG_TABLE_NAME AND column_name = 'id') THEN
            record_id := OLD.id;
        ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = TG_TABLE_NAME AND column_name = 'account_id') THEN
            record_id := OLD.account_id;
        ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = TG_TABLE_NAME AND column_name = 'transaction_id') THEN
            record_id := OLD.transaction_id;
        ELSE
            record_id := NULL;
        END IF;
    ELSE
        IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = TG_TABLE_NAME AND column_name = 'id') THEN
            record_id := NEW.id;
        ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = TG_TABLE_NAME AND column_name = 'account_id') THEN
            record_id := NEW.account_id;
        ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = TG_TABLE_NAME AND column_name = 'transaction_id') THEN
            record_id := NEW.transaction_id;
        ELSE
            record_id := NULL;
        END IF;
    END IF;

    -- Insert into audit_logs
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.audit_logs(
            user_id, action_by, table_name, record_id, action, new_data
        )
        VALUES (
            affected_user_id, actor_user_id, TG_TABLE_NAME, record_id, 'INSERT', row_to_json(NEW)
        );
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO public.audit_logs(
            user_id, action_by, table_name, record_id, action, old_data, new_data
        )
        VALUES (
            affected_user_id, actor_user_id, TG_TABLE_NAME, record_id, 'UPDATE', row_to_json(OLD), row_to_json(NEW)
        );
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO public.audit_logs(
            user_id, action_by, table_name, record_id, action, old_data
        )
        VALUES (
            affected_user_id, actor_user_id, TG_TABLE_NAME, record_id, 'DELETE', row_to_json(OLD)
        );
    END IF;

    RETURN NULL;
END;
$$;

-- Create audit triggers for all relevant tables
DO $$
DECLARE 
    t text;
BEGIN
    FOR t IN 
        SELECT tablename FROM pg_tables 
        WHERE schemaname = 'public' 
        AND tablename NOT IN ('audit_logs') 
        AND tablename ~ '^(profiles|accounts|.*_accounts|transactions.*|expense_.*|income_sources|counterparties|exchange_rates)$'
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_audit_%I AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION log_audit();', 
            t, t
        );
    END LOOP;
END$$;

-- =========================================
-- 02. Function: set_updated_at
-- =========================================
-- Purpose:
--   Automatically updates the `updated_at` timestamp column to the current time
--   whenever a row is modified in tables that have an `updated_at` column.
--
-- Behavior:
--   - Trigger fires BEFORE UPDATE on the table
--   - Sets NEW.updated_at = NOW() to reflect the latest modification
--
-- Parameters:
--   NEW - The new row version being updated
--
-- Returns:
--   NEW - Modified row with updated timestamp
--
-- Notes:
--   - SECURITY DEFINER allows this function to execute even with RLS policies
--   - Trigger creation is dynamic for all public tables containing an `updated_at` column
--   - Ensures consistent time stamping without requiring manual updates
-- =========================================
CREATE OR REPLACE FUNCTION set_updated_at() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

-- Apply to all tables with updated_at column
DO $$
DECLARE 
    t text;
BEGIN
    FOR t IN 
        SELECT tablename FROM pg_tables t1
        WHERE schemaname = 'public'
        AND EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'public' 
            AND table_name = t1.tablename 
            AND column_name = 'updated_at'
        )
    LOOP
        EXECUTE format('CREATE TRIGGER trg_%I_updated BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
    END LOOP;
END$$;

-- =========================================
-- 03. Function: enforce_soft_delete
-- =========================================
-- Purpose:
--   Implements soft delete functionality by updating the `deleted_at` and `updated_at`
--   columns instead of performing a physical DELETE.
--
-- Behavior:
--   - Trigger fires BEFORE DELETE on a table
--   - Updates the row with the current timestamp in `deleted_at` and `updated_at`
--   - Prevents the actual deletion by returning NULL
--
-- Parameters:
--   OLD - The row being deleted
--
-- Returns:
--   NULL - Stops the physical deletion and enforces soft delete
--
-- Notes:
--   - SECURITY DEFINER allows the trigger to execute even with RLS policies
--   - Applied to all major tables, specialized account tables, and transaction detail tables
--   - Ensures data retention and enables recovery of deleted records
-- =========================================
CREATE OR REPLACE FUNCTION enforce_soft_delete() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    pk_col text;
BEGIN
    -- Skip soft delete if bypass flag is set
    IF current_setting('app.hard_delete', true) = 'on' THEN
        RETURN OLD; -- allow actual delete to proceed
    END IF;

    -- Determine primary key column dynamically
    SELECT column_name
    INTO pk_col
    FROM information_schema.columns
    WHERE table_name = TG_TABLE_NAME
      AND column_name IN ('id','account_id','transaction_id')
    ORDER BY CASE column_name 
                 WHEN 'id' THEN 1 
                 WHEN 'account_id' THEN 2 
                 WHEN 'transaction_id' THEN 3 
             END
    LIMIT 1;

    -- Update the deleted_at and updated_at timestamps
    EXECUTE format(
        'UPDATE %I SET deleted_at = NOW(), updated_at = NOW() WHERE %I = $1',
        TG_TABLE_NAME, pk_col
    ) USING COALESCE(OLD.id, OLD.account_id, OLD.transaction_id);

    RETURN NULL; -- Prevent actual delete
END;
$$;

-- Apply to all major tables
CREATE TRIGGER trg_profiles_no_delete
    BEFORE DELETE ON profiles
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_accounts_no_delete
    BEFORE DELETE ON accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_no_delete
    BEFORE DELETE ON transactions
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_counterparties_no_delete
    BEFORE DELETE ON counterparties
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_expense_categories_no_delete
    BEFORE DELETE ON expense_categories
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_expense_subcategories_no_delete
    BEFORE DELETE ON expense_subcategories
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_income_sources_no_delete
    BEFORE DELETE ON income_sources
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_recurring_no_delete
    BEFORE DELETE ON transactions_recurring
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

-- Soft delete for specialized account tables
CREATE TRIGGER trg_cash_accounts_no_delete
    BEFORE DELETE ON cash_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_bank_accounts_no_delete
    BEFORE DELETE ON bank_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_credit_card_accounts_no_delete
    BEFORE DELETE ON credit_card_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_loan_accounts_no_delete
    BEFORE DELETE ON loan_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_investment_accounts_no_delete
    BEFORE DELETE ON investment_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_crypto_accounts_no_delete
    BEFORE DELETE ON crypto_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_wallet_accounts_no_delete
    BEFORE DELETE ON wallet_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_receivable_accounts_no_delete
    BEFORE DELETE ON receivable_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

-- Soft delete for transaction detail tables
CREATE TRIGGER trg_transactions_income_no_delete
    BEFORE DELETE ON transactions_income
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_expense_no_delete
    BEFORE DELETE ON transactions_expense
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_investment_no_delete
    BEFORE DELETE ON transactions_investment
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_borrow_no_delete
    BEFORE DELETE ON transactions_borrow
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_lend_no_delete
    BEFORE DELETE ON transactions_lend
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_transfer_no_delete
    BEFORE DELETE ON transactions_transfer
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_adjustment_no_delete
    BEFORE DELETE ON transactions_adjustment
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_exchange_rates_no_delete
    BEFORE DELETE ON exchange_rates
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();


-- =========================================
-- 04. Function: log_admin_changes
-- =========================================
-- Purpose:
--   Logs changes to the `is_admin` field in the `profiles` table.
--   Tracks both the affected user and the actor performing the privilege change.
--
-- Behavior:
--   - Trigger fires AFTER UPDATE on the `profiles` table
--   - Checks if `is_admin` has changed
--   - Inserts a record into `audit_logs` with old and new values of `is_admin`
--   - Raises a notice with the affected user and the privilege change
--
-- Parameters:
--   OLD - Previous row version (before update)
--   NEW - New row version (after update)
--
-- Returns:
--   NEW - Returns the updated row to complete the trigger operation
--
-- Notes:
--   - SECURITY INVOKER allows the function to respect the session user's permissions
--   - Only fires when `is_admin` is actually changed, preventing unnecessary audit entries
--   - Uses `COALESCE(auth.uid(), NEW.user_id)` to ensure `action_by` is always populated
--   - Requires `audit_logs` to allow the 'ADMIN_PRIVILEGE_CHANGE' action in its check constraint
-- =========================================
CREATE OR REPLACE FUNCTION log_admin_changes() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- Log when admin privileges are granted or revoked
    IF OLD.is_admin IS DISTINCT FROM NEW.is_admin THEN
        INSERT INTO public.audit_logs(user_id, action_by, table_name, record_id, action, old_data, new_data)
        VALUES (
            NEW.user_id,
            COALESCE(auth.uid(), NEW.user_id),
            'profiles',
            NEW.id,
            'ADMIN_PRIVILEGE_CHANGE',
            jsonb_build_object('is_admin', OLD.is_admin),
            jsonb_build_object('is_admin', NEW.is_admin)
        );

        RAISE NOTICE 'Admin privilege changed for user % from % to %', 
            NEW.user_id, OLD.is_admin, NEW.is_admin;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_log_admin_changes
    AFTER UPDATE ON profiles
    FOR EACH ROW EXECUTE FUNCTION log_admin_changes();


-- =========================================
-- GRANT PERMISSIONS FOR RLS FUNCTIONS
-- =========================================
GRANT EXECUTE ON FUNCTION log_audit() TO authenticated;
GRANT EXECUTE ON FUNCTION set_updated_at() TO authenticated;
GRANT EXECUTE ON FUNCTION enforce_soft_delete() TO authenticated;
GRANT EXECUTE ON FUNCTION log_admin_changes() TO authenticated;


-- =========================================
-- COMMENTS AND DOCUMENTATION
-- =========================================
COMMENT ON FUNCTION log_audit() IS 'RLS-compliant audit logging with dual user tracking';