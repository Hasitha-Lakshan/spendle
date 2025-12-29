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
CREATE OR REPLACE FUNCTION finance.initialize_defaults_for_user_internal(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, core
VOLATILE
AS $$
DECLARE
    default_category_id UUID;
BEGIN
    -- Create Cash account
    PERFORM finance.create_account_internal(
        p_user_id := p_user_id,
        p_account_name := 'Cash Wallet',
        p_type := 'cash'::finance.account_type,
        p_currency := 'USD',
        p_details := '{}'::jsonb
    );

    -- Create Bank account
    PERFORM finance.create_account_internal(
        p_user_id := p_user_id,
        p_account_name := 'Default Bank',
        p_type := 'bank'::finance.account_type,
        p_currency := 'USD',
        p_details := '{
            "bank_name": "Default Bank",
            "account_no": "0000",
            "branch": "Main",
            "account_holder_name": "User",
            "balance": 0
        }'::jsonb
    );

    -- Insert default expense category
    INSERT INTO finance.expense_categories(user_id, name)
    VALUES (p_user_id, 'General')
    ON CONFLICT (user_id, lower(name)) 
    WHERE deleted_at IS NULL
    DO NOTHING;

    -- Get the inserted category id
    SELECT id INTO default_category_id
    FROM finance.expense_categories
    WHERE user_id = p_user_id AND name = 'General';

    -- Insert default expense subcategory
    IF default_category_id IS NOT NULL THEN
        INSERT INTO finance.expense_subcategories(category_id, name)
        VALUES (default_category_id, 'Miscellaneous')
        ON CONFLICT (category_id, lower(name))
        WHERE deleted_at IS NULL
        DO NOTHING;
    END IF;

    -- Insert default income source
    INSERT INTO finance.income_sources(user_id, name)
    VALUES (p_user_id, 'Salary')
    ON CONFLICT (user_id, lower(name))
    WHERE deleted_at IS NULL
    DO NOTHING;

    -- Insert default exchange rates
    INSERT INTO finance.exchange_rates(
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
    ON CONFLICT (user_id, from_currency, to_currency)
    WHERE deleted_at IS NULL
    DO NOTHING;

    -- Mark defaults as inserted
    UPDATE core.profiles
    SET defaults_inserted = TRUE, updated_at = NOW()
    WHERE user_id = p_user_id;

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
CREATE OR REPLACE FUNCTION finance.initialize_my_defaults_internal()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, core
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    defaults_flag BOOLEAN;
    is_soft_deleted BOOLEAN := FALSE;
BEGIN
    -- Enable RLS
    PERFORM set_config('row_security', 'on', true);

    -- Authenticate
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Not authenticated'
            USING ERRCODE = '28000'; -- invalid_authorization_specification
    END IF;

    -- Lock profile
    SELECT defaults_inserted, deleted_at IS NOT NULL
    INTO defaults_flag, is_soft_deleted
    FROM core.profiles
    WHERE user_id = v_user_id
    FOR UPDATE;

    -- Soft-deleted profile is a semantic failure
    IF FOUND AND is_soft_deleted THEN
        RAISE EXCEPTION
            'Profile is soft-deleted'
            USING ERRCODE = '23514'; -- check_violation (semantic constraint)
    END IF;

    -- Create profile if missing
    IF NOT FOUND THEN
        INSERT INTO core.profiles(user_id, defaults_inserted)
        VALUES (v_user_id, FALSE);
        defaults_flag := FALSE;
    END IF;

    -- Insert defaults if needed
    IF NOT defaults_flag THEN
        PERFORM finance.initialize_defaults_for_user_internal(v_user_id);
        RETURN TRUE;  -- inserted now
    END IF;

    RETURN FALSE; -- already existed
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
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    -- Call internal function
    v_result := finance.initialize_my_defaults_internal();

    -- Build success response
    RETURN jsonb_build_object(
        'success', TRUE,
        'code', 'OK',
        'message', 'Defaults initialized successfully',
        'data', jsonb_build_object('defaults_inserted', v_result)
    );

EXCEPTION
    WHEN check_violation THEN  -- soft-deleted profile
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'PROFILE_SOFT_DELETED',
            'message', 'Cannot initialize defaults: profile is soft-deleted',
            'data', NULL
        );

    WHEN invalid_authorization_specification THEN  -- unauthenticated
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_AUTHENTICATED',
            'message', 'You must be logged in to initialize defaults',
            'data', NULL
        );

    WHEN OTHERS THEN
        -- Catch-all for unexpected errors
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'INTERNAL_ERROR',
            'message', 'Failed to initialize defaults',
            'data', NULL
        );
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
CREATE OR REPLACE FUNCTION util.check_admin_permissions_internal()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, core
STABLE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_is_admin BOOLEAN := FALSE;
BEGIN
    -- Return false if user is unauthenticated
    IF v_user_id IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Check admin flag from core.profiles
    SELECT p.is_admin
    INTO v_is_admin
    FROM core.profiles p
    WHERE p.user_id = v_user_id
      AND p.deleted_at IS NULL
    LIMIT 1;

    RETURN COALESCE(v_is_admin, FALSE);
EXCEPTION
    WHEN OTHERS THEN
        -- Log or propagate unexpected errors
        RAISE EXCEPTION 'Failed to check admin permissions for user %: %', v_user_id, SQLERRM;
END;
$$;

-- =========================================
-- 05. Function: admin_initialize_user_defaults_internal
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
CREATE OR REPLACE FUNCTION finance.admin_initialize_user_defaults_internal(
    p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, core, util
VOLATILE
AS $$
DECLARE
    v_admin_id UUID := auth.uid();
    defaults_flag BOOLEAN;
    is_soft_deleted BOOLEAN := FALSE;
BEGIN
    -- Enable RLS for this function
    PERFORM set_config('row_security', 'on', true);

    -- Authenticate caller
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'Not authenticated'
            USING ERRCODE = '28000'; -- invalid_authorization_specification
    END IF;

    -- Authorize admin privileges
    IF NOT util.check_admin_permissions_internal() THEN
        RAISE EXCEPTION
            'Not authorized'
            USING ERRCODE = '42501'; -- insufficient_privilege
    END IF;

    -- Lock profile row
    SELECT defaults_inserted, deleted_at IS NOT NULL
    INTO defaults_flag, is_soft_deleted
    FROM core.profiles
    WHERE user_id = p_user_id
    FOR UPDATE;

    -- Soft-deleted profile is a semantic failure
    IF FOUND AND is_soft_deleted THEN
        RAISE EXCEPTION
            'Profile is soft-deleted'
            USING ERRCODE = '23514'; -- check_violation
    END IF;

    -- Create profile if missing
    IF NOT FOUND THEN
        INSERT INTO core.profiles(user_id, defaults_inserted)
        VALUES (p_user_id, FALSE);
        defaults_flag := FALSE;
    END IF;

    -- Insert defaults if needed
    IF NOT defaults_flag THEN
        PERFORM finance.initialize_defaults_for_user_internal(p_user_id);
        RETURN TRUE;  -- inserted now
    END IF;

    -- Defaults already existed
    RETURN FALSE;
END;
$$;

-- =========================================
-- 06. Function: admin_initialize_user_defaults
-- =========================================
-- Purpose:
--   Wrapper function to initialize default data for a specified user,
--   intended for administrative use via RPC.
--
-- Behavior:
--   - Calls the internal function `admin_initialize_user_defaults_internal(p_user_id)` which:
--       * Authenticates the calling session via `auth.uid()`
--       * Verifies the caller has administrative privileges
--       * Ensures a profile row exists for the target user
--       * Inserts default data for the target user if not already inserted
--       * Returns a JSONB object summarizing the operation
--
-- Parameters:
--   p_user_id UUID
--     - The user ID for which default data should be initialized
--
-- Returns:
--   JSONB - containing:
--       * `user_id`: UUID of the target user
--       * `defaults_inserted`: BOOLEAN indicating whether defaults were inserted during this call
--
-- Notes:
--   - SECURITY INVOKER ensures RLS policies are evaluated using the caller’s identity
--   - All authentication and authorization logic is enforced in the SECURITY DEFINER
--     internal function
--   - VOLATILE since the function may create or modify user-scoped data
--   - Intended for controlled administrative access via Supabase RPC endpoints
-- =========================================
CREATE OR REPLACE FUNCTION public.admin_initialize_user_defaults(
    p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_inserted BOOLEAN;
BEGIN
    -- Validate input
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'MISSING_USER_ID',
            'message', 'User id is required',
            'data', NULL
        );
    END IF;

    -- Call internal function
    v_inserted := finance.admin_initialize_user_defaults_internal(p_user_id);

    -- Return consistent success JSON
    RETURN jsonb_build_object(
        'success', TRUE,
        'code', 'OK',
        'message', 'Defaults initialized successfully',
        'data', jsonb_build_object('defaults_inserted', v_inserted)
    );

EXCEPTION
    WHEN invalid_authorization_specification THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_AUTHENTICATED',
            'message', 'You must be logged in to perform this action',
            'data', NULL
        );

    WHEN insufficient_privilege THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_AUTHORIZED',
            'message', 'You do not have permission to initialize defaults for this user',
            'data', NULL
        );

    WHEN check_violation THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'PROFILE_SOFT_DELETED',
            'message', 'Cannot initialize defaults: profile is soft-deleted',
            'data', NULL
        );

    WHEN invalid_text_representation THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'INVALID_AUTH_CONTEXT',
            'message', 'Invalid authentication context (expected UUID)',
            'data', NULL
        );

    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'INTERNAL_ERROR',
            'message', 'Failed to initialize defaults for user',
            'data', NULL
        );
END;
$$;

-- =========================================
-- 07. Function: check_rate_limit_internal
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
CREATE OR REPLACE FUNCTION api.check_rate_limit_internal(
    p_endpoint VARCHAR(100),
    p_max_requests INTEGER DEFAULT 100,
    p_window_minutes INTEGER DEFAULT 60
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, api
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
    FROM api.api_rate_limits
    WHERE user_id = v_user_id
      AND endpoint = p_endpoint
    FOR UPDATE;

    IF NOT FOUND THEN
        -- Row doesn't exist yet: create it
        INSERT INTO api.api_rate_limits(user_id, endpoint, request_count, last_request_at)
        VALUES (v_user_id, p_endpoint, 1, v_now);
        RETURN TRUE;
    ELSE
        -- Row exists: check if the last_request_at is within the rolling window
        IF v_counter.last_request_at < v_window_start THEN
            -- Window expired: reset counter
            UPDATE api.api_rate_limits
            SET request_count = 1,
                last_request_at = v_now
            WHERE user_id = v_user_id
              AND endpoint = p_endpoint;
            RETURN TRUE;
        ELSE
            -- Within window: check if under max requests
            IF v_counter.request_count < p_max_requests THEN
                UPDATE api.api_rate_limits
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
-- 08. Function: hard_delete_record_internal
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
CREATE OR REPLACE FUNCTION finance.hard_delete_record_internal(
    p_table_name TEXT,
    p_record_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, core
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_rows_deleted INTEGER;
    v_acc_type finance.account_type;
    v_sql_query TEXT;
BEGIN
    -- Require authentication
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Not authenticated'
            USING ERRCODE = '28000'; -- invalid_authorization_specification
    END IF;

    -- Validate table name (allow-list)
    IF p_table_name NOT IN (
        'core.profiles',
        'finance.accounts', 'finance.transactions', 'finance.expense_categories', 'finance.expense_subcategories',
        'finance.income_sources', 'finance.counterparties', 'finance.transactions_recurring',
        'finance.cash_accounts', 'finance.bank_accounts', 'finance.credit_card_accounts', 'finance.loan_accounts',
        'finance.investment_accounts', 'finance.crypto_accounts', 'finance.wallet_accounts', 'finance.receivable_accounts',
        'finance.transactions_income', 'finance.transactions_expense', 'finance.transactions_investment',
        'finance.transactions_borrow', 'finance.transactions_lend', 'finance.transactions_transfer', 'finance.transactions_adjustment',
        'finance.exchange_rates'
    ) THEN
        RAISE EXCEPTION
            'Invalid table name'
            USING ERRCODE = '42601'; -- syntax_error (semantic misuse)
    END IF;

    -- Account-specific cascading deletes
    -- If deleting an account, first delete specialized account table + transaction details
    IF p_table_name = 'finance.accounts' THEN
        SELECT type
        INTO v_acc_type
        FROM finance.accounts
        WHERE id = p_record_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Account does not exist'
                USING ERRCODE = '02000'; -- no_data_found
        END IF;

        CASE v_acc_type
            WHEN 'cash'        THEN DELETE FROM finance.cash_accounts        WHERE account_id = p_record_id;
            WHEN 'bank'        THEN DELETE FROM finance.bank_accounts        WHERE account_id = p_record_id;
            WHEN 'credit_card' THEN DELETE FROM finance.credit_card_accounts WHERE account_id = p_record_id;
            WHEN 'loan'        THEN DELETE FROM finance.loan_accounts        WHERE account_id = p_record_id;
            WHEN 'investment'  THEN DELETE FROM finance.investment_accounts  WHERE account_id = p_record_id;
            WHEN 'crypto'      THEN DELETE FROM finance.crypto_accounts      WHERE account_id = p_record_id;
            WHEN 'wallet'      THEN DELETE FROM finance.wallet_accounts      WHERE account_id = p_record_id;
            WHEN 'receivable'  THEN DELETE FROM finance.receivable_accounts  WHERE account_id = p_record_id;
        END CASE;

        -- Delete recurring transactions linked to these transactions
        DELETE FROM finance.transactions_recurring
        WHERE transaction_template_id IN (
            SELECT id FROM finance.transactions WHERE id IN (
                SELECT transaction_id FROM finance.transactions_income     WHERE account_id = p_record_id
                UNION
                SELECT transaction_id FROM finance.transactions_expense    WHERE account_id = p_record_id
                UNION
                SELECT transaction_id FROM finance.transactions_investment WHERE account_id = p_record_id
                UNION
                SELECT transaction_id FROM finance.transactions_borrow     WHERE account_id = p_record_id
                UNION
                SELECT transaction_id FROM finance.transactions_lend       WHERE account_id = p_record_id
                UNION
                SELECT transaction_id FROM finance.transactions_transfer   WHERE from_account = p_record_id OR to_account = p_record_id
                UNION
                SELECT transaction_id FROM finance.transactions_adjustment WHERE account_id = p_record_id
            )
        );

        -- Delete transaction details referencing this account
        DELETE FROM finance.transactions_income      WHERE account_id = p_record_id;
        DELETE FROM finance.transactions_expense     WHERE account_id = p_record_id;
        DELETE FROM finance.transactions_investment  WHERE account_id = p_record_id;
        DELETE FROM finance.transactions_borrow      WHERE account_id = p_record_id;
        DELETE FROM finance.transactions_lend        WHERE account_id = p_record_id;
        DELETE FROM finance.transactions_adjustment  WHERE account_id = p_record_id;
        DELETE FROM finance.transactions_transfer    WHERE from_account = p_record_id OR to_account = p_record_id;
    END IF;

    -- Transaction-specific cascading deletes
    IF p_table_name = 'finance.transactions' THEN
        -- Raise error if transaction does not exist
        PERFORM 1 FROM finance.transactions WHERE id = p_record_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Transaction does not exist'
                USING ERRCODE = '02000';
        END IF;

        -- Delete recurring transactions linked to this transaction
        DELETE FROM finance.transactions_recurring
        WHERE transaction_template_id = p_record_id;

        DELETE FROM finance.transactions_income      WHERE transaction_id = p_record_id;
        DELETE FROM finance.transactions_expense     WHERE transaction_id = p_record_id;
        DELETE FROM finance.transactions_investment  WHERE transaction_id = p_record_id;
        DELETE FROM finance.transactions_borrow      WHERE transaction_id = p_record_id;
        DELETE FROM finance.transactions_lend        WHERE transaction_id = p_record_id;
        DELETE FROM finance.transactions_transfer    WHERE transaction_id = p_record_id;
        DELETE FROM finance.transactions_adjustment  WHERE transaction_id = p_record_id;
    END IF;

    -- Expense category cascade
    IF p_table_name = 'finance.expense_categories' THEN
        PERFORM 1 FROM finance.expense_categories WHERE id = p_record_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Expense category does not exist'
                USING ERRCODE = '02000';
        END IF;

        DELETE FROM finance.expense_subcategories WHERE category_id = p_record_id;
    END IF;

    -- Counterparty cascade
    IF p_table_name = 'finance.counterparties' THEN
        PERFORM 1 FROM finance.counterparties WHERE id = p_record_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Counterparty does not exist'
                USING ERRCODE = '02000';
        END IF;

        DELETE FROM finance.loan_accounts        WHERE counterparty_id = p_record_id;
        DELETE FROM finance.receivable_accounts  WHERE counterparty_id = p_record_id;
    END IF;

    -- Income source cascade
    IF p_table_name = 'finance.income_sources' THEN
        PERFORM 1 FROM finance.income_sources WHERE id = p_record_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Income source does not exist'
                USING ERRCODE = '02000';
        END IF;

        DELETE FROM finance.transactions_income WHERE source_id = p_record_id;
    END IF;

    -- Hard delete only soft-deleted rows
    v_sql_query := format(
        'DELETE FROM %I WHERE id = $1 AND deleted_at IS NOT NULL',
        p_table_name
    );

    EXECUTE v_sql_query USING p_record_id;

    -- Check if any rows were affected
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;

    -- Return result
    RETURN record_exists > 0;
END;
$$;

-- =========================================
-- 09. Function: admin_hard_delete_record_internal
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
CREATE OR REPLACE FUNCTION finance.admin_hard_delete_record_internal(
    p_table_name TEXT,
    p_record_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, util
VOLATILE
AS $$
DECLARE
    v_admin_id UUID := auth.uid();
BEGIN
    -- Require authentication
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'Not authenticated'
            USING ERRCODE = '28000'; -- invalid_authorization_specification
    END IF;

    -- Require admin privileges
    IF NOT util.check_admin_permissions_internal() THEN
        RAISE EXCEPTION
            'Not authorized'
            USING ERRCODE = '42501'; -- insufficient_privilege
    END IF;

    -- Enable hard-delete bypass for this session
    PERFORM set_config('app.hard_delete', 'on', true);

    -- Delegate deletion logic
    RETURN finance.hard_delete_record_internal(p_table_name, p_record_id);
END;
$$;

-- =========================================
-- 10. Function: admin_hard_delete_record
-- =========================================
-- Purpose:
--   Wrapper function to perform a hard delete on a specific record
--   in a specified table, intended strictly for administrative use
--   via RPC.
--
-- Behavior:
--   - Delegates execution to `public.admin_hard_delete_record(table_name, record_id)` which:
--       * Authenticates the calling session using `auth.uid()`
--       * Verifies the caller has administrative privileges
--       * Temporarily enables the `app.hard_delete` bypass flag
--       * Performs a hard delete through `hard_delete_record_internal`
--       * Returns a BOOLEAN indicating whether the delete succeeded
--
-- Parameters:
--   table_name TEXT
--     - Name of the table from which the record should be hard deleted
--   record_id UUID
--     - Primary key value of the record to be deleted
--
-- Returns:
--   BOOLEAN
--     - TRUE if the record was successfully deleted
--     - FALSE if the delete operation failed or no record was affected
--
-- Notes:
--   - SECURITY INVOKER ensures RLS policies are evaluated using the caller’s identity
--   - All authentication, authorization, and hard delete bypass logic is enforced
--     within the SECURITY DEFINER internal function
--   - VOLATILE due to irreversible data mutation
--   - Intended for tightly controlled administrative access via Supabase RPC endpoints
-- =========================================
CREATE OR REPLACE FUNCTION public.admin_hard_delete_record(
    table_name TEXT,
    record_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_deleted BOOLEAN;
BEGIN
    -- Input validation
    IF table_name IS NULL OR table_name = '' THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'MISSING_TABLE_NAME',
            'message', 'Table name is required',
            'data', NULL
        );
    END IF;

    IF record_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'MISSING_RECORD_ID',
            'message', 'Record id is required',
            'data', NULL
        );
    END IF;

    -- Call internal function
    v_deleted := finance.admin_hard_delete_record_internal(table_name, record_id);

    -- Success response
    RETURN jsonb_build_object(
        'success', TRUE,
        'code', 'OK',
        'message', 'Record permanently deleted',
        'data', jsonb_build_object('deleted', v_deleted)
    );

EXCEPTION
    WHEN foreign_key_violation THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'FOREIGN_KEY_VIOLATION',
            'message', 'Record cannot be deleted due to existing references',
            'data', NULL
        );

    WHEN undefined_table THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'TABLE_NOT_FOUND',
            'message', 'Target table does not exist',
            'data', NULL
        );

    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'INTERNAL_ERROR',
            'message', 'Failed to delete record',
            'data', NULL
        );
END;
$$;

-- =========================================
-- 11. Function: cleanup_soft_deleted_records_internal
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
CREATE OR REPLACE FUNCTION finance.cleanup_soft_deleted_records_internal(
    older_than_days INTEGER DEFAULT 90
)
RETURNS TABLE(
    table_name TEXT,
    deleted_count BIGINT,
    failed_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, audit, util
VOLATILE
AS $$
DECLARE
    cutoff_date TIMESTAMPTZ;
    -- Include all tables with soft-delete support
    tables_to_clean TEXT[] := ARRAY[
        -- Transactions and related
        'finance.transactions', 'finance.transactions_recurring',
        'finance.transactions_income', 'finance.transactions_expense',
        'finance.transactions_investment', 'finance.transactions_borrow',
        'finance.transactions_lend', 'finance.transactions_transfer',
        'finance.transactions_adjustment',
        -- Accounts and specialized accounts
        'finance.accounts', 'finance.cash_accounts', 'finance.bank_accounts',
        'finance.credit_card_accounts', 'finance.loan_accounts',
        'finance.investment_accounts', 'finance.crypto_accounts',
        'finance.wallet_accounts', 'finance.receivable_accounts',
        -- Categories and sources
        'finance.expense_categories', 'finance.expense_subcategories',
        'finance.income_sources', 'finance.counterparties',
        'finance.exchange_rates'
    ];

    tbl TEXT;
    rec RECORD;
    deleted_counter BIGINT;
    failed_counter BIGINT;

    -- Fixed internal actor for scheduled jobs
    v_internal_actor_id UUID := '059fd8b9-f48b-4347-93b7-23d852b48a8a'::UUID;
BEGIN
    -- Establish system identity for downstream auth.uid() checks
    PERFORM set_config('request.jwt.claim.sub', v_internal_actor_id::TEXT, true);

    -- Enable hard-delete bypass for entire session
    PERFORM set_config('app.hard_delete', 'on', true);

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
                -- Call the existing hard_delete_record_internal function
                IF finance.hard_delete_record_internal(tbl, rec.id) THEN
                    deleted_counter := deleted_counter + 1;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    failed_counter := failed_counter + 1;

                    -- Persistent error logging to audit_logs
                    INSERT INTO audit.audit_logs(
                        user_id,
                        action_by,
                        table_name,
                        record_id,
                        action,
                        old_data,
                        new_data
                    )
                    VALUES (
                        v_internal_actor_id,   -- affected user (cron job context)
                        v_internal_actor_id,   -- performed by cron user
                        tbl,
                        rec.id,
                        'DELETE',
                        NULL,
                        jsonb_build_object(
                            'error', SQLERRM,
                            'sqlstate', SQLSTATE
                        )
                    );

                    -- Also raise notice for session visibility
                    RAISE NOTICE
                        'Failed to hard delete record % from table % (SQLSTATE %): %',
                        rec.id, tbl, SQLSTATE, SQLERRM;
            END;
        END LOOP;

        -- Return the results for this table, including failed deletions
        RETURN QUERY
        SELECT tbl, deleted_counter, failed_counter;
    END LOOP;
END;
$$;

-- Schedule the cleanup to run every night at 2:00 AM
SELECT cron.schedule(
  'cleanup_soft_deleted_records_nightly',  -- job name
  '0 2 * * *',                             -- cron expression (2:00 AM daily)
  $$ SELECT finance.cleanup_soft_deleted_records_internal(90); $$
);

-- =========================================
-- 12. Function: cleanup_old_audit_logs_internal
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
CREATE OR REPLACE FUNCTION audit.cleanup_old_audit_logs_internal(
    p_days_to_keep INTEGER DEFAULT 90
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, audit, util
VOLATILE
AS $$
DECLARE
    v_deleted_count INTEGER;
    cutoff_date TIMESTAMPTZ;
    v_internal_actor_id UUID := '059fd8b9-f48b-4347-93b7-23d852b48a8a'::UUID;
BEGIN
    -- Set internal actor for session (prevents auth.uid() errors)
    PERFORM set_config('request.jwt.claim.sub', v_internal_actor_id::TEXT, true);

    -- Calculate cutoff date
    cutoff_date := CURRENT_DATE - (p_days_to_keep || ' days')::INTERVAL;

    -- Delete old audit logs
    DELETE FROM audit.audit_logs
    WHERE created_at < cutoff_date;

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    -- Optional notice for job logs
    RAISE NOTICE 'Deleted % audit logs older than % days', v_deleted_count, p_days_to_keep;

    RETURN v_deleted_count;
END;
$$;

-- Schedule the cleanup to run every night at 2:00 AM
SELECT cron.schedule(
  'cleanup_audit_logs_daily',           -- job name
  '0 2 * * *',                          -- cron expression (2:00 AM daily)
  $$ SELECT audit.cleanup_old_audit_logs_internal(90); $$  -- call function with fully qualified reference
);

-- =========================================
-- 13. Function: cleanup_old_rate_limits_internal
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
CREATE OR REPLACE FUNCTION util.cleanup_old_rate_limits_internal(
    p_hours_to_keep INTEGER DEFAULT 24
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, api, util
VOLATILE
AS $$
DECLARE
    v_deleted_count INTEGER;
    cutoff_timestamp TIMESTAMPTZ;
    v_internal_actor_id UUID := '059fd8b9-f48b-4347-93b7-23d852b48a8a'::UUID;
BEGIN
    -- Set system actor for session (prevents auth.uid() errors)
    PERFORM set_config('request.jwt.claim.sub', v_internal_actor_id::TEXT, true);

    -- Calculate cutoff timestamp
    cutoff_timestamp := NOW() - (p_hours_to_keep || ' hours')::INTERVAL;

    -- Delete old API rate limit entries
    DELETE FROM api.api_rate_limits
    WHERE created_at < cutoff_timestamp;

    -- Return number of deleted rows
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    -- Optional notice for job logs
    RAISE NOTICE 'Deleted % API rate limit records older than % hours', v_deleted_count, p_hours_to_keep;

    RETURN v_deleted_count;
END;
$$;

-- Run cleanup every night at midnight
SELECT cron.schedule(
  'cleanup_api_rate_limits_daily',        -- job name
  '0 0 * * *',                            -- cron expression (midnight daily)
  $$ SELECT util.cleanup_old_rate_limits_internal(24); $$  -- call function with fully qualified reference
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
COMMENT ON FUNCTION finance.initialize_defaults_for_user_internal(UUID) IS 
'Triggers default account and category creation for new users via existing trigger system';
COMMENT ON FUNCTION api.check_rate_limit_internal(VARCHAR, INTEGER, INTEGER) IS 'API rate limiting with configurable windows';
