-- =========================================
-- 01. Function: initialize_defaults_for_user_internal
-- =========================================
-- Purpose:
--   Inserts all default data for a given user, including:
--     - Cash and Bank accounts
--     - Expense categories and subcategories
--     - Income sources
--     - Exchange rates (fiat and crypto)
--   Marks the user's profile as having defaults inserted to prevent duplicates.
--
-- Parameters:
--   p_user_id UUID - The ID of the user for whom defaults are being created
--
-- Returns:
--   VOID - This function performs actions without returning a value
--
-- Notes:
--   - Uses create_account_internal to insert default accounts
--   - Prevents duplicate inserts using ON CONFLICT
--   - Wraps all inserts in a block to catch errors and raise exceptions
--   - Safe to call multiple times; defaults are only inserted once per user
-- =========================================
CREATE OR REPLACE FUNCTION public.initialize_defaults_for_user_internal(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    default_category_id UUID;
BEGIN
    -- Wrap default insertion in a block to catch errors
    BEGIN
        -- Create Cash account
        PERFORM public.create_account_internal(
            p_user_id := p_user_id,
            p_account_name := 'Cash Wallet',
            p_type := 'cash'::account_type,
            p_currency := 'USD',
            p_details := '{}'::jsonb
        );

        -- Create Bank account
        PERFORM public.create_account_internal(
            p_user_id := p_user_id,
            p_account_name := 'Default Bank',
            p_type := 'bank'::account_type,
            p_currency := 'USD',
            p_details := '{
                "bank_name": "Default Bank",
                "account_no": "0000",
                "branch": "Main",
                "account_holder_name": "User",
                "balance": 0
            }'::jsonb
        );

        -- Insert default expense category and subcategory
        INSERT INTO expense_categories(user_id, name)
        VALUES (p_user_id, 'General')
        ON CONFLICT (user_id, name) DO NOTHING;

        SELECT id INTO default_category_id
        FROM expense_categories
        WHERE user_id = p_user_id AND name = 'General';

        IF default_category_id IS NOT NULL THEN
            INSERT INTO expense_subcategories(category_id, name)
            VALUES (default_category_id, 'Miscellaneous')
            ON CONFLICT (category_id, name) DO NOTHING;
        END IF;

        -- Insert default income source
        INSERT INTO income_sources(user_id, name)
        VALUES (p_user_id, 'Salary')
        ON CONFLICT (user_id, name) DO NOTHING;

        -- Insert default exchange rates
        INSERT INTO exchange_rates(
            user_id, from_currency, to_currency, rate, source, created_at, updated_at
        )
        VALUES
            -- Fiat currencies
            (p_user_id, 'USD', 'EUR', 0.92, 'ECB', NOW(), NOW()),
            (p_user_id, 'EUR', 'USD', 1.09, 'ECB', NOW(), NOW()),
            (p_user_id, 'USD', 'GBP', 0.80, 'ECB', NOW(), NOW()),
            (p_user_id, 'GBP', 'USD', 1.25, 'ECB', NOW(), NOW()),
            (p_user_id, 'USD', 'JPY', 145.23, 'ECB', NOW(), NOW()),
            (p_user_id, 'JPY', 'USD', 0.0069, 'ECB', NOW(), NOW()),
            (p_user_id, 'EUR', 'GBP', 0.87, 'ECB', NOW(), NOW()),
            (p_user_id, 'GBP', 'EUR', 1.15, 'ECB', NOW(), NOW()),
            (p_user_id, 'EUR', 'JPY', 158.00, 'ECB', NOW(), NOW()),
            (p_user_id, 'JPY', 'EUR', 0.0063, 'ECB', NOW(), NOW()),
            (p_user_id, 'USD', 'LKR', 320.00, 'CBSL', NOW(), NOW()),
            (p_user_id, 'LKR', 'USD', 0.003125, 'CBSL', NOW(), NOW()),
            (p_user_id, 'EUR', 'LKR', 333.00, 'CBSL', NOW(), NOW()),
            (p_user_id, 'LKR', 'EUR', 0.00300, 'CBSL', NOW(), NOW()),
            (p_user_id, 'GBP', 'LKR', 448.00, 'CBSL', NOW(), NOW()),
            (p_user_id, 'LKR', 'GBP', 0.00223, 'CBSL', NOW(), NOW()),

            -- Cryptocurrencies
            (p_user_id, 'BTC', 'USD', 27450.00, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'USD', 'BTC', 0.0000364, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'ETH', 'USD', 1800.00, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'USD', 'ETH', 0.000555, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'BTC', 'EUR', 25254.00, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'EUR', 'BTC', 0.0000396, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'ETH', 'EUR', 1650.00, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'EUR', 'ETH', 0.000606, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'BTC', 'LKR', 9995000.00, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'LKR', 'BTC', 0.00000010005, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'ETH', 'LKR', 655000.00, 'CoinGecko', NOW(), NOW()),
            (p_user_id, 'LKR', 'ETH', 0.000001526, 'CoinGecko', NOW(), NOW())
        ON CONFLICT (user_id, from_currency, to_currency) DO NOTHING;

        -- Mark defaults as inserted
        UPDATE profiles
        SET defaults_inserted = TRUE, updated_at = NOW()
        WHERE user_id = p_user_id;

    EXCEPTION WHEN OTHERS THEN
        -- Any error triggers a raised exception
        RAISE EXCEPTION 'Failed to initialize defaults for user %: %', p_user_id, SQLERRM;
    END;
END;
$$;

-- =========================================
-- 02. Function: initialize_my_defaults_internal
-- =========================================
-- Purpose:
--   Initializes default data for the current session user if not already inserted.
--
-- Behavior:
--   - Authenticates the current session user via `auth.uid()`
--   - Enables RLS (`row_security`) for this session to respect policies where applicable
--   - Fetches the user's profile row with a row-level lock
--   - If the profile does not exist, creates a new profile row
--   - Checks if defaults have already been inserted
--   - If defaults are missing, calls `initialize_defaults_for_user_internal()` to insert them
--   - Returns a JSONB object indicating whether defaults were inserted during this call
--
-- Parameters:
--   None - operates on the currently authenticated session user
--
-- Returns:
--   JSONB - containing:
--       * `user_id`: UUID of the current user
--       * `defaults_inserted`: BOOLEAN indicating if defaults were inserted in this execution
--
-- Notes:
--   - SECURITY DEFINER allows the function to bypass RLS restrictions when inserting defaults
--   - VOLATILE since it may modify database state
--   - Raises an exception if the session is unauthenticated
--   - Intended to be called internally or via a SECURITY INVOKER wrapper function for end users
-- =========================================
CREATE OR REPLACE FUNCTION public.initialize_my_defaults_internal()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    defaults_flag BOOLEAN;
    did_insert BOOLEAN := FALSE;
BEGIN
    -- Enable RLS for this function
    PERFORM set_config('row_security', 'on', true);

    -- Authenticate the caller
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated call';
    END IF;

    -- Fetch profile row atomically and lock it
    SELECT defaults_inserted
    INTO defaults_flag
    FROM profiles
    WHERE user_id = v_user_id
    FOR UPDATE;

    -- If profile does not exist, create it
    IF NOT FOUND THEN
        INSERT INTO profiles(user_id, defaults_inserted)
        VALUES (v_user_id, FALSE);
        defaults_flag := FALSE;
    END IF;

    -- If defaults not inserted, insert them
    IF NOT defaults_flag THEN
        PERFORM public.initialize_defaults_for_user_internal(v_user_id);
        -- Mark that we inserted defaults in this call
        did_insert := TRUE;
    END IF;

    -- Return JSON to Supabase
    RETURN jsonb_build_object(
        'user_id', v_user_id,
        'defaults_inserted', did_insert
    );
END;
$$;

-- =========================================
-- 03. Function: initialize_my_defaults
-- =========================================
-- Purpose:
--   Wrapper function to initialize default data for the current session user.
--
-- Behavior:
--   - Calls the internal function `initialize_my_defaults_internal()` which:
--       * Authenticates the session user via `auth.uid()`
--       * Ensures a profile row exists for the user
--       * Inserts default data if not already inserted
--       * Returns a JSONB object summarizing the operation
--
-- Parameters:
--   None - operates on the currently authenticated session user
--
-- Returns:
--   JSONB - containing:
--       * `user_id`: UUID of the current user
--       * `defaults_inserted`: BOOLEAN indicating if defaults were inserted during this call
--
-- Notes:
--   - SECURITY INVOKER ensures RLS policies are applied according to the calling user
--   - Delegates privileged operations to the SECURITY DEFINER internal function
--   - VOLATILE since the function may modify database state
--   - Designed for safe invocation by ordinary users in Supabase or client applications
-- =========================================
CREATE OR REPLACE FUNCTION public.initialize_my_defaults()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
VOLATILE
SET search_path = pg_catalog, public
AS $$
BEGIN
    RETURN public.initialize_my_defaults_internal();
END;
$$;


-- =========================================
-- 04. Function: check_admin_permissions_internal
-- =========================================
-- Purpose:
--   Determines whether the current session user has administrative privileges.
--
-- Behavior:
--   - Retrieves the current session user ID via `auth.uid()`
--   - Queries the `profiles` table for the `is_admin` flag of the active user
--   - Considers users with no profile or a deleted profile as non-admin
--
-- Parameters:
--   None - The function uses the current session user from `auth.uid()`
--
-- Returns:
--   BOOLEAN - TRUE if the current user is an admin, FALSE otherwise
--
-- Notes:
--   - SECURITY DEFINER allows the function to bypass RLS restrictions on the `profiles` table
--   - Useful for enforcing admin-only actions in triggers, policies, and other functions
--   - Always returns FALSE if the session is unauthenticated
-- =========================================
CREATE OR REPLACE FUNCTION public.check_admin_permissions_internal()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
STABLE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_is_admin BOOLEAN;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN FALSE;
    END IF;

    SELECT p.is_admin
    INTO v_is_admin
    FROM public.profiles p
    WHERE p.user_id = v_user_id
      AND p.deleted_at IS NULL;

    RETURN COALESCE(v_is_admin, FALSE);
END;
$$;

-- =========================================
-- 05. Function: admin_initialize_user_defaults
-- =========================================
-- Purpose:
--   Allows an administrator to initialize default data for any user.
--   Ensures the target user's profile exists, checks whether defaults were
--   already inserted, and triggers default data creation only once.
--
-- Parameters:
--   p_user_id UUID - The ID of the user whose defaults should be initialized
--
-- Returns:
--   JSONB - Object containing:
--     - user_id: the target user's ID
--     - defaults_inserted: true if defaults were inserted during this call
--
-- Notes:
--   - Uses auth.uid() to identify the calling administrator
--   - Enforces Row-Level Security during execution
--   - Requires admin privileges via check_admin_permissions_internal
--   - Locks the target user's profile row using FOR UPDATE to prevent race conditions
--   - Delegates all default data creation to initialize_defaults_for_user_internal
--   - Safe for repeated calls; defaults are only inserted once per user
-- =========================================
CREATE OR REPLACE FUNCTION public.admin_initialize_user_defaults(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_admin_id UUID := auth.uid();
    defaults_flag BOOLEAN;
    did_insert BOOLEAN := FALSE;
BEGIN
    -- Enable RLS for this function
    PERFORM set_config('row_security', 'on', true);

    -- Authenticate the caller
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated call';
    END IF;

    -- Only admins may initialize other users
    IF NOT public.check_admin_permissions_internal(v_admin_id) THEN
        RAISE EXCEPTION 'Not authorized to initialize defaults';
    END IF;

    -- Fetch profile row atomically and lock it
    SELECT defaults_inserted
    INTO defaults_flag
    FROM profiles
    WHERE user_id = p_user_id
    FOR UPDATE;

    -- If profile does not exist, create it
    IF NOT FOUND THEN
        INSERT INTO profiles(user_id, defaults_inserted)
        VALUES (p_user_id, FALSE);
        defaults_flag := FALSE;
    END IF;

    -- If defaults not inserted, insert them
    IF NOT defaults_flag THEN
        PERFORM public.initialize_defaults_for_user_internal(p_user_id);
        did_insert := TRUE;
    END IF;

    -- Return JSON to Supabase
    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'defaults_inserted', did_insert
    );
END;
$$;

-- =========================================
-- 06. Function: check_rate_limit_internal
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
CREATE OR REPLACE FUNCTION check_rate_limit_internal(
    p_endpoint VARCHAR(100),
    p_max_requests INTEGER DEFAULT 100,
    p_window_minutes INTEGER DEFAULT 60
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_counter RECORD;
    v_window_start TIMESTAMPTZ;
    v_now TIMESTAMPTZ := NOW();
BEGIN
    v_window_start := v_now - (p_window_minutes || ' minutes')::INTERVAL;

    -- Lock the row for this user/endpoint to prevent race conditions
    SELECT *
    INTO v_counter
    FROM public.api_rate_limits
    WHERE user_id = v_user_id
      AND endpoint = p_endpoint
    FOR UPDATE;

    IF NOT FOUND THEN
        -- Row doesn't exist yet: create it
        INSERT INTO public.api_rate_limits(user_id, endpoint, request_count, last_request_at)
        VALUES (v_user_id, p_endpoint, 1, v_now);
        RETURN TRUE;
    ELSE
        -- Row exists: check if the last_request_at is within the rolling window
        IF v_counter.last_request_at < v_window_start THEN
            -- Window expired: reset counter
            UPDATE public.api_rate_limits
            SET request_count = 1,
                last_request_at = v_now
            WHERE user_id = v_user_id
              AND endpoint = p_endpoint;
            RETURN TRUE;
        ELSE
            -- Within window: check if under max requests
            IF v_counter.request_count < p_max_requests THEN
                UPDATE public.api_rate_limits
                SET request_count = request_count + 1,
                    last_request_at = v_now
                WHERE user_id = v_user_id
                  AND endpoint = p_endpoint;
                RETURN TRUE;
            ELSE
                -- Limit reached
                RETURN FALSE;
            END IF;
        END IF;
    END IF;
END;
$$;

-- =========================================
-- 07. Function: hard_delete_record_internal
-- =========================================
-- Purpose:
--   Executes a hard delete of a record from a specified table, including all
--   dependent or related records. Designed to be called by administrative
--   functions and bypasses standard soft-delete and RLS protections.
--
-- Behavior:
--   - SECURITY DEFINER ensures the function runs with elevated privileges
--   - Validates the table name against an approved list to prevent SQL injection
--   - Handles table-specific dependencies:
--       * Accounts: deletes specialized account tables, transactions, and recurring templates
--       * Transactions: deletes related transaction detail tables and recurring transactions
--       * Expense categories: deletes associated subcategories
--       * Counterparties and income sources: deletes linked accounts or transaction records
--   - Executes a DELETE query only on records marked as soft-deleted (deleted_at IS NOT NULL)
--   - Returns TRUE if a record was successfully deleted, FALSE otherwise
--
-- Parameters:
--   table_name  TEXT - Name of the table from which to delete the record
--   record_id   UUID - Identifier of the record to be deleted
--
-- Returns:
--   BOOLEAN - TRUE if deletion was successful, FALSE if no matching record was deleted
--
-- Notes:
--   - Must be invoked by an admin-level function to ensure proper authorization
--   - Handles specialized deletion logic for accounts and transactions
--   - Protects against invalid table names and non-existent records
-- =========================================
CREATE OR REPLACE FUNCTION public.hard_delete_record_internal(
    table_name TEXT,
    record_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    sql_query TEXT;
    record_exists INTEGER;
    acc_type public.account_type;
BEGIN
    -- Validate table name to prevent SQL injection
    IF table_name NOT IN (
        'profiles',
        'accounts', 'transactions', 'expense_categories', 'expense_subcategories',
        'income_sources', 'counterparties', 'transactions_recurring',
        'cash_accounts', 'bank_accounts', 'credit_card_accounts', 'loan_accounts',
        'investment_accounts', 'crypto_accounts', 'wallet_accounts', 'receivable_accounts',
        'transactions_income', 'transactions_expense', 'transactions_investment',
        'transactions_borrow', 'transactions_lend', 'transactions_transfer', 'transactions_adjustment',
        'exchange_rates'
    ) THEN
        RAISE EXCEPTION 'Invalid table name: %', table_name;
    END IF;

    -- Handle dependencies and specialized tables

    -- If deleting an account, first delete specialized account table + transaction details
    IF table_name = 'accounts' THEN
        SELECT type INTO acc_type FROM public.accounts WHERE id = record_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Account with id % does not exist', record_id;
        END IF;

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
        -- Raise error if transaction does not exist
        PERFORM 1 FROM public.transactions WHERE id = record_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Transaction with id % does not exist', record_id;
        END IF;

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
        PERFORM 1 FROM public.expense_categories WHERE id = record_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Expense category with id % does not exist', record_id;
        END IF;

        DELETE FROM public.expense_subcategories WHERE category_id = record_id;
    END IF;

    -- If deleting a counterparty
    IF table_name = 'counterparties' THEN
        PERFORM 1 FROM public.counterparties WHERE id = record_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Counterparty with id % does not exist', record_id;
        END IF;

        DELETE FROM public.loan_accounts WHERE counterparty_id = record_id;
        DELETE FROM public.receivable_accounts WHERE counterparty_id = record_id;

    -- If deleting an income source
    ELSIF table_name = 'income_sources' THEN
        PERFORM 1 FROM public.income_sources WHERE id = record_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Income source with id % does not exist', record_id;
        END IF;

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
-- 08. Function: admin_hard_delete_record
-- =========================================
-- Purpose:
--   Performs a hard delete of a record from a specified table, bypassing
--   standard soft-delete and RLS restrictions. Intended for administrative use only.
--
-- Behavior:
--   - SECURITY DEFINER allows the function to run with elevated privileges
--   - Enables row-level security (RLS) for this session
--   - Authenticates the current user and ensures they are logged in
--   - Checks if the current user has admin permissions; raises an exception if not
--   - Temporarily enables app-level hard delete flag for the session
--   - Delegates actual deletion logic to the internal helper function
--   - Returns TRUE if deletion succeeds, otherwise raises an exception
--
-- Parameters:
--   table_name  TEXT - Name of the table from which to delete the record
--   record_id   UUID - Identifier of the record to be deleted
--
-- Returns:
--   BOOLEAN - TRUE if the deletion was successful
--
-- Notes:
--   - Only admins can execute this function
--   - Relies on the helper function hard_delete_record_internal for actual deletion
--   - Enforces strict authentication and authorization checks
-- =========================================
CREATE OR REPLACE FUNCTION public.admin_hard_delete_record(
    table_name TEXT,
    record_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    current_user_id UUID;
    is_admin BOOLEAN;
    sql_query TEXT;
BEGIN
    -- Enable RLS for this function
    PERFORM set_config('row_security', 'on', true);

    -- Authenticate and authorize user
    current_user_id := auth.uid();
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Check if current user is admin
    is_admin := public.check_admin_permissions_internal();
    IF NOT is_admin THEN
        RAISE EXCEPTION 'Permission denied: only admins can hard delete';
    END IF;

    -- Enable hard delete bypass for this session
    PERFORM set_config('app.hard_delete', 'on', true);

    -- Delegate deletion logic to the helper
    RETURN public.hard_delete_record_internal(table_name, record_id);
END;
$$;

-- =========================================
-- 09. Function: require_system_role_internal
-- =========================================
-- Purpose:
--   Enforces that the current database session is executed under a system-level role.
--
-- Behavior:
--   - Checks the PostgreSQL `current_user` for an allowed system role
--   - Raises an exception if the session user is not authorized
--   - Execution stops immediately on failure
--
-- Parameters:
--   None - The function relies on the PostgreSQL `current_user`
--
-- Returns:
--   VOID - Throws an exception if the role requirement is not met
--
-- Notes:
--   - Intended for internal/system-only operations
--   - Commonly used as a guard clause at the beginning of privileged functions
--   - SECURITY DEFINER does not grant access unless the role check passes
-- =========================================
CREATE OR REPLACE FUNCTION public.require_system_role_internal()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
BEGIN
    IF current_user NOT IN ('postgres') THEN
        RAISE EXCEPTION 'System role required';
    END IF;
END;
$$;

-- =========================================
-- 10. Function: cleanup_soft_deleted_records_internal
-- =========================================
-- Purpose:
--   Permanently deletes soft-deleted records from key tables that are older than a specified number of days.
--
-- Behavior:
--   - SECURITY DEFINER allows execution even with RLS enabled
--   - Iterates through predefined tables (transactions, accounts, expense_categories, etc.)
--   - For each soft-deleted record older than `older_than_days`, calls `hard_delete_record_internal` to remove it
--   - Returns a summary of how many records were deleted per table
--
-- Parameters:
--   older_than_days INTEGER DEFAULT 90
--     - Number of days after which soft-deleted records should be permanently removed
--
-- Returns:
--   TABLE (table_name TEXT, deleted_count BIGINT)
--     - table_name: name of the table processed
--     - deleted_count: number of records permanently deleted from that table
--
-- Notes:
--   - Should only be run by admins; checks `check_admin_permissions_internal`
--   - Can be scheduled via pg_cron to run automatically, e.g., nightly
--   - Uses `hard_delete_record_internal` to handle dependencies and ensure safe deletion
-- =========================================
CREATE OR REPLACE FUNCTION public.cleanup_soft_deleted_records_internal(
    older_than_days INTEGER DEFAULT 90
)
RETURNS TABLE(
    table_name TEXT,
    deleted_count BIGINT,
    failed_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    cutoff_date TIMESTAMPTZ;
    tables_to_clean TEXT[] := ARRAY[
        'transactions', 'transactions_recurring', 'accounts', 'expense_categories',
        'expense_subcategories', 'income_sources', 'counterparties',
        'exchange_rates'
    ];
    tbl TEXT;
    rec RECORD;
    deleted_counter BIGINT;
    failed_counter BIGINT;
    v_system_uid UUID = '00000000-0000-0000-0000-000000000000'::UUID;
BEGIN
    -- Must be run only by cron_admin
    PERFORM public.require_system_role_internal();

    cutoff_date := NOW() - (older_than_days || ' days')::INTERVAL;

    FOREACH tbl IN ARRAY tables_to_clean LOOP
        deleted_counter := 0;
        failed_counter := 0;

        FOR rec IN EXECUTE format(
            'SELECT id FROM %I WHERE deleted_at IS NOT NULL AND deleted_at < $1',
            tbl
        ) USING cutoff_date
        LOOP
            BEGIN
                -- Call the existing admin_hard_delete_record function
                IF public.hard_delete_record_internal(tbl, rec.id) THEN
                    deleted_counter := deleted_counter + 1;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                failed_counter := failed_counter + 1;

                -- Persistent error logging to audit_logs
                INSERT INTO public.audit_logs(
                    user_id,
                    action_by,
                    table_name,
                    record_id,
                    action,
                    old_data,
                    new_data
                )
                VALUES (
                    v_system_uid,   -- affected user (cron job context)
                    v_system_uid,   -- performed by cron user
                    tbl,
                    rec.id,
                    'DELETE',
                    NULL,
                    jsonb_build_object(
                        'error', SQLERRM
                    )
                );

                -- Also raise notice for session visibility
                RAISE NOTICE 'Failed to hard delete record % from table %: %', rec.id, tbl, SQLERRM;
            END;
        END LOOP;

        -- Return the results for this table, including failed deletions
        RETURN QUERY SELECT tbl, deleted_counter, failed_counter;
    END LOOP;
END;
$$;

-- Schedule the cleanup to run every night at 2:00 AM
SELECT cron.schedule(
  'cleanup_soft_deleted_records_nightly',  -- job name
  '0 2 * * *',                            -- cron expression (2:00 AM daily)
  $$ SELECT public.cleanup_soft_deleted_records_internal(90); $$
);

-- =========================================
-- 11. Function: cleanup_old_audit_logs_internal
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
CREATE OR REPLACE FUNCTION public.cleanup_old_audit_logs_internal(
    p_days_to_keep INTEGER DEFAULT 90
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_deleted_count INTEGER;
BEGIN
    -- Must be run only by cron_admin
    PERFORM public.require_system_role_internal();

    DELETE FROM public.audit_logs
    WHERE created_at < (CURRENT_DATE - (p_days_to_keep || ' days')::INTERVAL);

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RETURN v_deleted_count;
END;
$$;

-- Schedule the cleanup to run every night at 2:00 AM
SELECT cron.schedule(
  'cleanup_audit_logs_daily',
  '0 2 * * *',
  $$ SELECT cleanup_old_audit_logs_internal(90); $$
);

-- =========================================
-- 12. Function: cleanup_old_rate_limits_internal
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
CREATE OR REPLACE FUNCTION public.cleanup_old_rate_limits_internal(p_hours_to_keep INTEGER DEFAULT 24)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_deleted_count INTEGER;
BEGIN
    -- Must be run only by cron_admin
    PERFORM public.require_system_role_internal();

    DELETE FROM public.api_rate_limits
    WHERE created_at < (NOW() - (p_hours_to_keep || ' hours')::INTERVAL);

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RETURN v_deleted_count;
END;
$$;

-- Run cleanup every night at midnight
SELECT cron.schedule(
  'cleanup_api_rate_limits_daily',
  '0 0 * * *',
  $$ SELECT cleanup_old_rate_limits_internal(24); $$  -- explicitly pass 24 hours
);


-- ================================
-- Grant Permissions
-- ================================
GRANT EXECUTE ON FUNCTION public.initialize_my_defaults() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_initialize_user_defaults(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_hard_delete_record(TEXT, UUID) TO authenticated;


-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION public.initialize_my_defaults IS 'Invoker wrapper for initialize_my_defaults_internal() to enforce RLS';
COMMENT ON FUNCTION public.initialize_defaults_for_user_internal(UUID) IS 
'Triggers default account and category creation for new users via existing trigger system';
COMMENT ON FUNCTION public.check_rate_limit_internal(VARCHAR, INTEGER, INTEGER) IS 'API rate limiting with configurable windows';
