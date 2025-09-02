-- =========================================
-- 01. Function: initialize_user_defaults
-- =========================================
-- Purpose:
--   Ensures a user profile exists and inserts default data for new users,
--   including base accounts, expense categories, subcategories, and income sources.
--   Marks defaults as inserted to prevent duplicates.
--
-- Parameters:
--   p_user_id UUID - The ID of the user to initialize
--
-- Returns:
--   JSONB - Object indicating user_id and that defaults were inserted
--
-- Notes:
--   - Uses create_account to insert default accounts
--   - Prevents duplicate inserts using ON CONFLICT
--   - Safe for repeated calls; defaults are only inserted once
-- =========================================
CREATE OR REPLACE FUNCTION initialize_user_defaults(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    profile_exists BOOLEAN;
    defaults_flag BOOLEAN;
    default_category_id UUID;
BEGIN
    -- Check if profile exists and whether defaults are already inserted
    SELECT EXISTS(SELECT 1 FROM profiles WHERE user_id = p_user_id),
           COALESCE((SELECT defaults_inserted FROM profiles WHERE user_id = p_user_id), FALSE)
    INTO profile_exists, defaults_flag;

    -- If profile does not exist, create it
    IF NOT profile_exists THEN
        INSERT INTO profiles(user_id, defaults_inserted)
        VALUES (p_user_id, FALSE)
        ON CONFLICT (user_id) DO NOTHING;

        -- Re-fetch flags after insert
        SELECT EXISTS(SELECT 1 FROM profiles WHERE user_id = p_user_id),
               COALESCE((SELECT defaults_inserted FROM profiles WHERE user_id = p_user_id), FALSE)
        INTO profile_exists, defaults_flag;
    END IF;

    -- If defaults not inserted, insert them
    IF NOT defaults_flag THEN
        -- Insert default accounts using create_account
        PERFORM create_account(p_user_id, 'Cash Wallet', 'cash', 'USD', '{}'::jsonb);
        PERFORM create_account(
            p_user_id,
            'Default Bank',
            'bank',
            'USD',
            '{"bank_name":"Default Bank","account_no":"0000","branch":"Main","account_holder_name":"User","balance":0}'::jsonb
        );

        -- Insert default expense category and subcategory
        INSERT INTO expense_categories(user_id, name)
        VALUES (p_user_id, 'General')
        ON CONFLICT (user_id, name) DO NOTHING
        RETURNING id INTO default_category_id;

        IF default_category_id IS NOT NULL THEN
            INSERT INTO expense_subcategories(category_id, name)
            VALUES (default_category_id, 'Miscellaneous')
            ON CONFLICT (category_id, name) DO NOTHING;
        END IF;

        -- Insert default income source
        INSERT INTO income_sources(user_id, name)
        VALUES (p_user_id, 'Salary')
        ON CONFLICT (user_id, name) DO NOTHING;

        -- Mark defaults as inserted
        UPDATE profiles
        SET defaults_inserted = TRUE, updated_at = NOW()
        WHERE user_id = p_user_id;
    END IF;

    -- Return JSON to Supabase
    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'defaults_inserted', TRUE
    );
END;
$$;

-- =========================================
-- 02. Function: check_admin_permissions
-- =========================================
-- Purpose:
--   Determines whether the current session user has administrative privileges.
--
-- Behavior:
--   - SECURITY DEFINER allows the function to bypass RLS restrictions on the profiles table
--   - Retrieves the `is_admin` flag from the profiles table for the current session user
--   - Considers a user without a profile or with a deleted profile as non-admin
--
-- Parameters:
--   None - The function uses the current session user from auth.uid()
--
-- Returns:
--   BOOLEAN - TRUE if the current user is an admin, FALSE otherwise
--
-- Notes:
--   - Useful for enforcing admin-only actions in triggers, policies, and functions
--   - Always returns FALSE if the session is unauthenticated
-- =========================================
CREATE OR REPLACE FUNCTION check_admin_permissions()
RETURNS BOOLEAN 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current_user UUID;
    is_admin BOOLEAN := FALSE;
BEGIN
    v_current_user := auth.uid();
    
    IF v_current_user IS NULL THEN
        RETURN FALSE;
    END IF;
    
    SELECT p.is_admin INTO is_admin
    FROM public.profiles p
    WHERE p.user_id = v_current_user
      AND p.deleted_at IS NULL;
    
    RETURN COALESCE(is_admin, FALSE);
END;
$$;

-- =========================================
-- 03. Function: check_rate_limit
-- =========================================
-- Purpose:
--   Enforces per-user API rate limits for a given endpoint within a rolling time window.
--
-- Behavior:
--   - SECURITY INVOKER ensures the function runs with the privileges of the calling user
--   - Checks the number of requests made by the current user for a specific endpoint
--     within the specified time window (p_window_minutes)
--   - Inserts a new rate limit record if none exists, or increments the request count
--   - Returns TRUE if the request is allowed (under the limit), FALSE if the limit is exceeded
--
-- Parameters:
--   p_endpoint      VARCHAR(100) - The API endpoint being accessed
--   p_max_requests  INTEGER DEFAULT 100 - Maximum allowed requests in the window
--   p_window_minutes INTEGER DEFAULT 60 - Length of the rolling window in minutes
--
-- Returns:
--   BOOLEAN - TRUE if the request is within the allowed limit, FALSE otherwise
--
-- Notes:
--   - Uses the api_rate_limits table to track requests per user per endpoint
--   - Can be called in triggers or directly from API middleware
--   - Designed to prevent abuse without blocking legitimate usage
-- =========================================
CREATE OR REPLACE FUNCTION check_rate_limit(
    p_endpoint VARCHAR(100),
    p_max_requests INTEGER DEFAULT 100,
    p_window_minutes INTEGER DEFAULT 60
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_user_id UUID;
    v_current_count INTEGER;
    v_window_start TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();
    v_window_start := NOW() - (p_window_minutes || ' minutes')::INTERVAL;
    
    -- Get current count for this user/endpoint in the time window
    SELECT COALESCE(SUM(request_count), 0)::INTEGER
    INTO v_current_count
    FROM public.api_rate_limits
    WHERE user_id = v_user_id
      AND endpoint = p_endpoint
      AND window_start > v_window_start;
    
    -- If under limit, record this request
    IF v_current_count < p_max_requests THEN
        INSERT INTO public.api_rate_limits (user_id, endpoint, request_count)
        VALUES (v_user_id, p_endpoint, 1)
        ON CONFLICT (user_id, endpoint) 
        DO UPDATE SET 
            request_count = public.api_rate_limits.request_count + 1,
            created_at = NOW();
        
        RETURN TRUE;
    ELSE
        RETURN FALSE;
    END IF;
END;
$$;

-- =========================================
-- 01. Function: hard_delete_record
-- =========================================
-- Purpose:
--   Permanently deletes a record from a specified table, handling dependencies
--   and specialized related tables for accounts, transactions, categories,
--   counterparties, and income sources.
--
-- Behavior:
--   - SECURITY DEFINER ensures the function runs with elevated privileges
--     regardless of the caller
--   - Authenticates the current user via auth.uid() and checks admin permissions
--   - Validates the table name to prevent SQL injection
--   - For 'accounts', deletes specialized account tables and associated transactions
--   - For 'transactions', deletes dependent transaction detail tables and recurring links
--   - For 'expense_categories', deletes linked subcategories
--   - For 'counterparties' and 'income_sources', deletes dependent transaction references
--   - Only deletes records that have already been soft-deleted (deleted_at IS NOT NULL)
--   - Uses dynamic SQL to delete the target record safely
--
-- Parameters:
--   table_name TEXT - Name of the table from which to delete the record
--   record_id  UUID - ID of the record to delete
--
-- Returns:
--   BOOLEAN - TRUE if the record was successfully deleted, FALSE if no record
--             was deleted (e.g., record did not exist or was not soft-deleted)
--
-- Notes:
--   - Sets 'app.hard_delete' session flag to allow bypassing soft delete constraints
--   - Ensures cascading deletions for related tables to maintain referential integrity
--   - Designed for administrative operations only; raises exceptions for non-admins
--   - Prevents accidental deletion by restricting to known table names
-- =========================================
CREATE OR REPLACE FUNCTION public.hard_delete_record(
    table_name TEXT,
    record_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    current_user_id UUID;
    is_admin BOOLEAN;
    sql_query TEXT;
    record_exists INTEGER;
    acc_type public.account_type;
BEGIN
    -- Authenticate and authorize user
    current_user_id := auth.uid();
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Check if current user is admin
    is_admin := public.check_admin_permissions();
    IF NOT is_admin THEN
        RAISE EXCEPTION 'Permission denied: only admins can hard delete';
    END IF;

    -- Enable hard delete bypass for this session
    PERFORM set_config('app.hard_delete', 'on', true);

    -- Validate table name to prevent SQL injection
    IF table_name NOT IN (
        'profiles',
        'accounts', 'transactions', 'expense_categories', 'expense_subcategories',
        'income_sources', 'counterparties', 'transactions_recurring',
        'cash_accounts', 'bank_accounts', 'credit_card_accounts', 'loan_accounts',
        'investment_accounts', 'crypto_accounts', 'wallet_accounts', 'receivable_accounts',
        'transactions_income', 'transactions_expense', 'transactions_investment',
        'transactions_borrow', 'transactions_lend', 'transactions_transfer', 'transactions_adjustment'
    ) THEN
        RAISE EXCEPTION 'Invalid table name: %', table_name;
    END IF;

    -- Handle dependencies and specialized tables

    -- If deleting an account, first delete specialized account table + transaction details
    IF table_name = 'accounts' THEN
        SELECT type INTO acc_type FROM public.accounts WHERE id = record_id;

        CASE acc_type
            WHEN 'cash'        THEN DELETE FROM public.cash_accounts        WHERE account_id = record_id;
            WHEN 'bank'        THEN DELETE FROM public.bank_accounts        WHERE account_id = record_id;
            WHEN 'credit_card' THEN DELETE FROM public.credit_card_accounts WHERE account_id = record_id;
            WHEN 'loan'        THEN DELETE FROM public.loan_accounts        WHERE account_id = record_id;
            WHEN 'investment'  THEN DELETE FROM public.investment_accounts  WHERE account_id = record_id;
            WHEN 'crypto'      THEN DELETE FROM public.crypto_accounts      WHERE account_id = record_id;
            WHEN 'wallet'      THEN DELETE FROM public.wallet_accounts      WHERE account_id = record_id;
            WHEN 'receivable'  THEN DELETE FROM public.receivable_accounts  WHERE account_id = record_id;
        END CASE;

        -- Delete recurring transactions linked to these transactions
        DELETE FROM public.transactions_recurring
        WHERE transaction_template_id IN (
            SELECT id FROM public.transactions WHERE 
                id IN (
                    SELECT transaction_id FROM public.transactions_income      WHERE account_id = record_id
                    UNION
                    SELECT transaction_id FROM public.transactions_expense     WHERE account_id = record_id
                    UNION
                    SELECT transaction_id FROM public.transactions_investment  WHERE account_id = record_id
                    UNION
                    SELECT transaction_id FROM public.transactions_borrow      WHERE account_id = record_id
                    UNION
                    SELECT transaction_id FROM public.transactions_lend        WHERE account_id = record_id
                    UNION
                    SELECT transaction_id FROM public.transactions_transfer    WHERE from_account = record_id OR to_account = record_id
                    UNION
                    SELECT transaction_id FROM public.transactions_adjustment  WHERE account_id = record_id
                )
        );

        -- Delete transaction details referencing this account
        DELETE FROM public.transactions_income      WHERE account_id = record_id;
        DELETE FROM public.transactions_expense     WHERE account_id = record_id;
        DELETE FROM public.transactions_investment  WHERE account_id = record_id;
        DELETE FROM public.transactions_borrow      WHERE account_id = record_id;
        DELETE FROM public.transactions_lend        WHERE account_id = record_id;
        DELETE FROM public.transactions_adjustment  WHERE account_id = record_id;
        DELETE FROM public.transactions_transfer    WHERE from_account = record_id OR to_account = record_id;
    END IF;

    -- If deleting transactions, delete dependent transaction detail tables first
    IF table_name = 'transactions' THEN
        -- Delete recurring transactions linked to this transaction
        DELETE FROM public.transactions_recurring
        WHERE transaction_template_id = record_id;

        DELETE FROM public.transactions_income      WHERE transaction_id = record_id;
        DELETE FROM public.transactions_expense     WHERE transaction_id = record_id;
        DELETE FROM public.transactions_investment  WHERE transaction_id = record_id;
        DELETE FROM public.transactions_borrow      WHERE transaction_id = record_id;
        DELETE FROM public.transactions_lend        WHERE transaction_id = record_id;
        DELETE FROM public.transactions_transfer    WHERE transaction_id = record_id;
        DELETE FROM public.transactions_adjustment  WHERE transaction_id = record_id;
    END IF;

    -- If deleting expense category, delete subcategories first
    IF table_name = 'expense_categories' THEN
        DELETE FROM public.expense_subcategories WHERE category_id = record_id;
    END IF;

    -- If deleting a counterparty
    IF table_name = 'counterparties' THEN
        DELETE FROM public.transactions_borrow WHERE counterparty_id = record_id;
        DELETE FROM public.transactions_lend   WHERE counterparty_id = record_id;

    -- If deleting an income source
    ELSIF table_name = 'income_sources' THEN
        DELETE FROM public.transactions_income WHERE source_id = record_id;
    END IF;

    -- Delete only soft-deleted records
    sql_query := format(
        'DELETE FROM %I WHERE id = $1 AND deleted_at IS NOT NULL',
        table_name
    );

    EXECUTE sql_query USING record_id;

    -- Check if any rows were affected
    GET DIAGNOSTICS record_exists = ROW_COUNT;

    -- Return result
    RETURN record_exists > 0;
END;
$$;

-- =========================================
-- CLEAN-UP FUNCTIONS
-- =========================================
-- =========================================
-- 05. Function: cleanup_old_audit_logs
-- =========================================
-- Purpose:
--   Deletes audit log entries older than a specified number of days to manage table size.
--
-- Behavior:
--   - SECURITY DEFINER allows execution even with RLS enabled
--   - Removes rows from public.audit_logs where created_at is older than the cutoff date
--   - Returns the number of rows deleted
--
-- Parameters:
--   p_days_to_keep INTEGER DEFAULT 90 - Number of days to retain audit logs
--
-- Returns:
--   INTEGER - Number of audit log records deleted
--
-- Notes:
--   - Should be scheduled periodically (e.g., via a cron job or maintenance task)
--   - Helps control storage growth for audit_logs table
-- =========================================
CREATE OR REPLACE FUNCTION cleanup_old_audit_logs(p_days_to_keep INTEGER DEFAULT 90)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_deleted_count INTEGER;
BEGIN
    DELETE FROM public.audit_logs 
    WHERE created_at < (CURRENT_DATE - (p_days_to_keep || ' days')::INTERVAL);
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RETURN v_deleted_count;
END;
$$;

-- =========================================
-- 06. Function: cleanup_old_rate_limits
-- =========================================
-- Purpose:
--   Deletes API rate limit records older than 24 hours to keep the table current.
--
-- Behavior:
--   - SECURITY DEFINER allows execution even with RLS enabled
--   - Removes rows from public.api_rate_limits where created_at is older than 24 hours
--   - Returns the number of rows deleted
--
-- Parameters:
--   None
--
-- Returns:
--   INTEGER - Number of rate limit records deleted
--
-- Notes:
--   - Should be scheduled periodically to prevent stale rate limit data
--   - Helps ensure accurate rate limiting without table bloat
-- =========================================
CREATE OR REPLACE FUNCTION cleanup_old_rate_limits()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_deleted_count INTEGER;
BEGIN
    DELETE FROM public.api_rate_limits
    WHERE created_at < (NOW() - INTERVAL '24 hours');
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RETURN v_deleted_count;
END;
$$;

-- =========================================
-- 07. Function: cleanup_soft_deleted_records
-- =========================================
-- Purpose:
--   Batch deletes records that were soft-deleted older than a specified number of days.
--   Intended for periodic cleanup by admins only.
--
-- Behavior:
--   - SECURITY DEFINER allows execution even with RLS enabled
--   - Confirms current user is admin; raises exception if not
--   - Iterates over a predefined list of tables to clean up
--   - Deletes rows where deleted_at is set and older than the cutoff date
--   - Returns a table of table names and the number of rows deleted per table
--
-- Parameters:
--   older_than_days INTEGER DEFAULT 90 - Only delete records older than this many days
--
-- Returns:
--   TABLE(table_name TEXT, deleted_count BIGINT) - Number of rows deleted per table
--
-- Notes:
--   - Only admins can execute this function
--   - Helps maintain database size and prevent accumulation of old soft-deleted data
-- =========================================
CREATE OR REPLACE FUNCTION cleanup_soft_deleted_records(
    older_than_days INTEGER DEFAULT 90
)
RETURNS TABLE(
    table_name TEXT,
    deleted_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    cutoff_date TIMESTAMPTZ;
    tables_to_clean TEXT[] := ARRAY[
        'transactions', 'accounts', 'expense_categories', 'expense_subcategories',
        'income_sources', 'counterparties', 'transactions_recurring'
    ];
    tbl TEXT;
    deleted_rows BIGINT;
BEGIN
    -- Only admins can run this
    IF NOT check_admin_permissions() THEN
        RAISE EXCEPTION 'Admin permissions required';
    END IF;
    
    cutoff_date := NOW() - (older_than_days || ' days')::INTERVAL;
    
    FOREACH tbl IN ARRAY tables_to_clean LOOP
        EXECUTE format(
            'DELETE FROM %I WHERE deleted_at IS NOT NULL AND deleted_at < $1',
            tbl
        ) USING cutoff_date;
        
        GET DIAGNOSTICS deleted_rows = ROW_COUNT;
        
        RETURN QUERY SELECT tbl, deleted_rows;
    END LOOP;
END;
$$;


-- ================================
-- Grant Permissions
-- ================================
GRANT EXECUTE ON FUNCTION initialize_user_defaults(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION check_rate_limit(VARCHAR, INTEGER, INTEGER) TO authenticated;


-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION initialize_user_defaults(UUID) IS 
'Triggers default account and category creation for new users via existing trigger system';
COMMENT ON FUNCTION check_rate_limit(VARCHAR, INTEGER, INTEGER) IS 'API rate limiting with configurable windows';
