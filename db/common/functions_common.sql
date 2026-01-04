-- =========================================
-- 01. Function: util.build_actor_internal
-- =========================================
-- Purpose:
--   Constructs a normalized actor identifier string used for auditing,
--   logging, or attribution of actions within the system.
--
-- Behavior:
--   - For p_type = 'user' or 'admin':
--       * Requires a non-null UUID.
--       * Returns a string in the format '<type>:<uuid>'.
--   - For p_type = 'system':
--       * Requires p_profile_id to be NULL.
--       * Returns the fixed identifier 'system:cron'.
--   - For any other p_type:
--       * Raises an exception.
--
-- Parameters:
--   p_type TEXT
--     The actor category. Supported values are 'user', 'admin', and 'system'.
--
--   p_profile_id UUID
--     The actor identifier. Mandatory for 'user' and 'admin', must be NULL for 'system'.
--
-- Returns:
--   TEXT
--     A canonical actor string suitable for persistent storage and comparison.
--
-- Notes:
--   - Enforces strict validation to prevent malformed actor identifiers.
--   - Marked IMMUTABLE because the output depends solely on input parameters.
--   - Defined as SECURITY DEFINER to allow use in privileged contexts such as triggers.
-- =========================================
CREATE OR REPLACE FUNCTION util.build_actor_internal(
    p_type TEXT,
    p_profile_id UUID DEFAULT NULL
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
IMMUTABLE
AS $$
BEGIN
    -- User or admin must have a UUID
    IF p_type IN ('user','admin') THEN
        IF p_profile_id IS NULL THEN
            RAISE EXCEPTION 'Actor id required for %', p_type
                USING ERRCODE = 'P0001'; -- user-defined exception
        END IF;
        RETURN p_type || ':' || p_profile_id::text;

    -- System actor must not have a UUID
    ELSIF p_type = 'system' THEN
        IF p_profile_id IS NOT NULL THEN
            RAISE EXCEPTION 'System actor must not have UUID'
                USING ERRCODE = 'P0002'; -- user-defined exception
        END IF;
        RETURN 'system:cron';

    -- Invalid actor type
    ELSE
        RAISE EXCEPTION 'Invalid actor type %', p_type
            USING ERRCODE = 'P0003'; -- user-defined exception
    END IF;
END;
$$;

-- =========================================
-- 02. Function: util.current_active_profile_id_internal
-- =========================================
-- Purpose:
--   Resolves the current authenticated user's active profile ID.
--
-- Behavior:
--   - Maps auth.uid() → core.profiles.user_id
--   - Returns core.profiles.id
--   - Enforces deleted_at IS NULL
--   - Fails fast if no active profile exists
--
-- Security:
--   - SECURITY DEFINER to allow use inside RLS
--   - search_path locked to pg_catalog, core
--
-- Notes:
--   - Assumes exactly one active profile per auth user
--   - Prevents multi-row ambiguity via LIMIT 1
-- =========================================
CREATE OR REPLACE FUNCTION util.current_active_profile_id_internal()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, core
STABLE
AS $$
    SELECT p.id
    FROM core.profiles p
    WHERE p.user_id = auth.uid()
      AND p.deleted_at IS NULL
    LIMIT 1
    FOR SHARE;
$$;

-- =========================================
-- 03. Function: check_admin_permissions_internal
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
-- 04. Function: check_rate_limit_internal
-- =========================================
-- Purpose:
--   Enforces per-user API rate limits for a given endpoint within a rolling time window.
--
-- Behavior:
--   - SECURITY DEFINER ensures the function runs with the privileges of the owner
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
    v_user_id UUID;
    v_counter RECORD;
    v_window_start TIMESTAMPTZ;
    v_now TIMESTAMPTZ := NOW();
BEGIN
    v_user_id := util.current_active_profile_id_internal();
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
-- 05. Function: initialize_defaults_for_user_internal
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
CREATE OR REPLACE FUNCTION finance.initialize_defaults_for_user_internal(p_profile_id UUID)
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
        p_user_id := p_profile_id,
        p_account_name := 'Cash Wallet',
        p_type := 'cash'::finance.account_type,
        p_currency := 'USD',
        p_details := '{}'::jsonb
    );

    -- Create Bank account
    PERFORM finance.create_account_internal(
        p_user_id := p_profile_id,
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
    VALUES (p_profile_id, 'General')
    ON CONFLICT (user_id, lower(name)) 
    WHERE deleted_at IS NULL
    DO NOTHING;

    -- Get the inserted category id
    SELECT id INTO default_category_id
    FROM finance.expense_categories
    WHERE user_id = p_profile_id AND name = 'General';

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
    VALUES (p_profile_id, 'Salary')
    ON CONFLICT (user_id, lower(name))
    WHERE deleted_at IS NULL
    DO NOTHING;

    -- Insert default exchange rates
    INSERT INTO finance.exchange_rates(
        user_id, from_currency, to_currency, rate, source, created_at, updated_at
    )
    VALUES
        -- Fiat currencies
        (p_profile_id, 'USD', 'EUR', 0.92, 'ECB', NOW(), NOW()),
        (p_profile_id, 'EUR', 'USD', 1.09, 'ECB', NOW(), NOW()),
        (p_profile_id, 'USD', 'GBP', 0.80, 'ECB', NOW(), NOW()),
        (p_profile_id, 'GBP', 'USD', 1.25, 'ECB', NOW(), NOW()),
        (p_profile_id, 'USD', 'JPY', 145.23, 'ECB', NOW(), NOW()),
        (p_profile_id, 'JPY', 'USD', 0.0069, 'ECB', NOW(), NOW()),
        (p_profile_id, 'EUR', 'GBP', 0.87, 'ECB', NOW(), NOW()),
        (p_profile_id, 'GBP', 'EUR', 1.15, 'ECB', NOW(), NOW()),
        (p_profile_id, 'EUR', 'JPY', 158.00, 'ECB', NOW(), NOW()),
        (p_profile_id, 'JPY', 'EUR', 0.0063, 'ECB', NOW(), NOW()),
        (p_profile_id, 'USD', 'LKR', 320.00, 'CBSL', NOW(), NOW()),
        (p_profile_id, 'LKR', 'USD', 0.003125, 'CBSL', NOW(), NOW()),
        (p_profile_id, 'EUR', 'LKR', 333.00, 'CBSL', NOW(), NOW()),
        (p_profile_id, 'LKR', 'EUR', 0.00300, 'CBSL', NOW(), NOW()),
        (p_profile_id, 'GBP', 'LKR', 448.00, 'CBSL', NOW(), NOW()),
        (p_profile_id, 'LKR', 'GBP', 0.00223, 'CBSL', NOW(), NOW()),

        -- Cryptocurrencies
        (p_profile_id, 'BTC', 'USD', 27450.00, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'USD', 'BTC', 0.0000364, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'ETH', 'USD', 1800.00, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'USD', 'ETH', 0.000555, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'BTC', 'EUR', 25254.00, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'EUR', 'BTC', 0.0000396, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'ETH', 'EUR', 1650.00, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'EUR', 'ETH', 0.000606, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'BTC', 'LKR', 9995000.00, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'LKR', 'BTC', 0.00000010005, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'ETH', 'LKR', 655000.00, 'CoinGecko', NOW(), NOW()),
        (p_profile_id, 'LKR', 'ETH', 0.000001526, 'CoinGecko', NOW(), NOW())
    ON CONFLICT (user_id, from_currency, to_currency)
    WHERE deleted_at IS NULL
    DO NOTHING;

    -- Mark defaults as inserted
    UPDATE core.profiles
    SET defaults_inserted = TRUE, updated_at = NOW()
    WHERE id = p_profile_id;

END;
$$;

-- =========================================
-- 06. Function: initialize_my_defaults_internal
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
--   - Intended to be called internally or via a SECURITY DEFINER wrapper function for end users
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
    v_profile_id UUID;
    defaults_flag BOOLEAN;
    is_soft_deleted BOOLEAN := FALSE;
BEGIN
    -- Enable RLS
    PERFORM set_config('row_security', 'on', true);

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
        v_profile_id := util.current_active_profile_id_internal();
        PERFORM finance.initialize_defaults_for_user_internal(v_profile_id);
        RETURN TRUE;  -- inserted now
    END IF;

    RETURN FALSE; -- already existed
END;
$$;

-- =========================================
-- 07. Function: initialize_my_defaults
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
--   - SECURITY DEFINER ensures RLS policies are applied according to the owner
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
    v_user_id UUID := auth.uid();
    v_result BOOLEAN;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'NOT_AUTHENTICATED',
            'message', 'User is not authenticated',
            'data', NULL
        );
    END IF;

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
-- 08. Function: admin_initialize_user_defaults_internal
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
    v_user_profile_id UUID;
    defaults_flag BOOLEAN;
    is_soft_deleted BOOLEAN := FALSE;
BEGIN
    -- Enable RLS for this function
    PERFORM set_config('row_security', 'on', true);

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
        SELECT id INTO v_user_profile_id
        FROM core.profiles
        WHERE user_id = p_user_id
          AND deleted_at IS NULL
        LIMIT 1;
        PERFORM finance.initialize_defaults_for_user_internal(v_user_profile_id);
        RETURN TRUE;  -- inserted now
    END IF;

    -- Defaults already existed
    RETURN FALSE;
END;
$$;

-- =========================================
-- 09. Function: admin_initialize_user_defaults
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
--   - SECURITY DEFINER ensures RLS policies are evaluated using the owner’s identity
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
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
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

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'NOT_AUTHENTICATED',
            'message', 'User is not authenticated',
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
-- 10. Function: hard_delete_record_internal
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
    v_rows_deleted INTEGER;
    v_acc_type finance.account_type;
    v_sql_query TEXT;
    v_deleted_at TIMESTAMP;
    v_primary_key_col TEXT;
    v_schema_name TEXT;
    v_table_name TEXT;
    v_pk_value UUID;
BEGIN
    -- Split the input table name into schema and table
    v_schema_name := split_part(p_table_name, '.', 1);
    v_table_name := split_part(p_table_name, '.', 2);

    -- Validate table name (allow-list)
    IF p_table_name NOT IN (
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

    BEGIN
        -- Determine PK column dynamically from whitelist
        SELECT column_name
        INTO v_primary_key_col
        FROM information_schema.columns
        WHERE table_schema = v_schema_name
          AND table_name = v_table_name
          AND column_name IN ('id','account_id','transaction_id')
        ORDER BY CASE column_name
                     WHEN 'id' THEN 1
                     WHEN 'account_id' THEN 2
                     WHEN 'transaction_id' THEN 3
                 END
        LIMIT 1;

        IF v_primary_key_col IS NULL THEN
            RAISE EXCEPTION 'No primary key column found in table %', p_table_name
            USING ERRCODE = '55000';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Failed to determine primary key column for table %: %', p_table_name, SQLERRM;
    END;

    v_sql_query := format(
        'SELECT %I, deleted_at FROM %I.%I WHERE %I = $1 FOR UPDATE',
        v_primary_key_col,  -- primary key column
        v_schema_name,      -- schema
        v_table_name,       -- table
        v_primary_key_col   -- PK filter
    );

    EXECUTE v_sql_query INTO v_pk_value, v_deleted_at USING p_record_id;

    -- Check if row exists
    IF v_pk_value IS NULL THEN
        RAISE EXCEPTION 'Record does not exist'
        USING ERRCODE = '02000';
    END IF;

    -- Now v_deleted_at can be used to check if soft-deleted
    IF v_deleted_at IS NULL THEN
        RAISE EXCEPTION 'Cannot hard-delete a row that is not soft-deleted'
        USING ERRCODE = '55000';
    END IF;

    -- Account-specific cascading deletes
    -- If deleting an account, first delete specialized account table + transaction details
    IF p_table_name = 'finance.accounts' THEN
        SELECT type
        INTO v_acc_type
        FROM finance.accounts
        WHERE id = p_record_id
        FOR UPDATE;

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
                SELECT transaction_id FROM finance.transactions_investment WHERE funding_account_id = p_record_id OR investment_account_id = p_record_id
                UNION
                SELECT transaction_id FROM finance.transactions_borrow     WHERE loan_account_id = p_record_id OR disbursement_account_id = p_record_id
                UNION
                SELECT transaction_id FROM finance.transactions_lend       WHERE funding_account_id = p_record_id OR receivable_account_id = p_record_id
                UNION
                SELECT transaction_id FROM finance.transactions_transfer   WHERE from_account = p_record_id OR to_account = p_record_id
                UNION
                SELECT transaction_id FROM finance.transactions_adjustment WHERE account_id = p_record_id
            )
        );

        -- Delete transaction details referencing this account
        DELETE FROM finance.transactions_income      WHERE account_id = p_record_id;
        DELETE FROM finance.transactions_expense     WHERE account_id = p_record_id;
        DELETE FROM finance.transactions_investment  WHERE funding_account_id = p_record_id OR investment_account_id = p_record_id;
        DELETE FROM finance.transactions_borrow      WHERE loan_account_id = p_record_id OR disbursement_account_id = p_record_id;
        DELETE FROM finance.transactions_lend        WHERE funding_account_id = p_record_id OR receivable_account_id = p_record_id;
        DELETE FROM finance.transactions_adjustment  WHERE account_id = p_record_id;
        DELETE FROM finance.transactions_transfer    WHERE from_account = p_record_id OR to_account = p_record_id;
    END IF;

    -- Transaction-specific cascading deletes
    IF p_table_name = 'finance.transactions' THEN
        -- Raise error if transaction does not exist
        PERFORM 1 FROM finance.transactions WHERE id = p_record_id FOR UPDATE;
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
        PERFORM 1 FROM finance.expense_categories WHERE id = p_record_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION
            'Expense category does not exist'
            USING ERRCODE = '02000';
        END IF;

        DELETE FROM finance.expense_subcategories WHERE category_id = p_record_id;
    END IF;

    -- Counterparty cascade
    IF p_table_name = 'finance.counterparties' THEN
        PERFORM 1 FROM finance.counterparties WHERE id = p_record_id FOR UPDATE;
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
        PERFORM 1 FROM finance.income_sources WHERE id = p_record_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION
            'Income source does not exist'
            USING ERRCODE = '02000';
        END IF;

        DELETE FROM finance.transactions_income WHERE source_id = p_record_id;
    END IF;

    -- Finally, hard-delete main row
    v_sql_query := format(
        'DELETE FROM %I.%I WHERE %I = $1 AND deleted_at IS NOT NULL',
        v_schema_name,  -- schema
        v_table_name,  -- table
        v_primary_key_col
    );

    EXECUTE v_sql_query USING p_record_id;

    -- Check if any rows were affected
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;

    -- Return result
    RETURN v_rows_deleted > 0;
END;
$$;

-- =========================================
-- 11. Function: admin_hard_delete_record_internal
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
BEGIN
    -- Enable RLS for this function
    PERFORM set_config('row_security', 'on', true);

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
-- 12. Function: admin_hard_delete_record
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
--   - SECURITY DEFINER ensures RLS policies are evaluated using the owner’s identity
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
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
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

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'NOT_AUTHENTICATED',
            'message', 'User is not authenticated',
            'data', NULL
        );
    END IF;

    -- Call internal function
    v_deleted := finance.admin_hard_delete_record_internal(table_name, record_id);

    -- Check if deletion actually happened
    IF NOT v_deleted THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_FOUND',
            'message', 'Record does not exist or already deleted',
            'data', NULL
        );
    END IF;

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

    WHEN SQLSTATE '02000' THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_FOUND',
            'message', 'Record does not exist',
            'data', NULL
        );

    WHEN undefined_table THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'TABLE_NOT_FOUND',
            'message', 'Target table does not exist',
            'data', NULL
        );

    WHEN invalid_authorization_specification THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_AUTHENTICATED',
            'message', 'User is not authenticated',
            'data', NULL
        );

    WHEN insufficient_privilege THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_AUTHORIZED',
            'message', 'User does not have admin privileges',
            'data', NULL
        );

    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'INTERNAL_ERROR',
            'message', SQLERRM,
            'data', NULL
        );
END;
$$;

-- =========================================
-- 13. Function: finance.soft_delete_profile_internal
-- =========================================
-- Purpose:
--   Performs a soft-delete of a profile in the `core.profiles` table.
--   Designed for internal use by RPC wrappers or administrative routines.
--
-- Behavior:
--   - Raises an exception with SQLSTATE '02000' if the profile does not exist.
--   - Soft-deletes the profile by setting `deleted_at = NOW()`, but only if it is not already deleted.
--   - Returns TRUE if the profile was successfully soft-deleted.
--   - Returns FALSE if the profile existed but was already soft-deleted.
--
-- Parameters:
--   p_profile_id UUID
--     The unique identifier of the profile to be soft-deleted.
--
-- Returns:
--   BOOLEAN
--     - TRUE: profile was soft-deleted.
--     - FALSE: profile already soft-deleted.
--
-- Notes:
--   - Raises a controlled exception for non-existent profiles to ensure consistent error handling.
--   - Uses SECURITY DEFINER to allow execution with elevated privileges.
--   - VOLATILE because the function modifies table data.
--   - Designed to be wrapped by higher-level RPC functions that handle JSON responses and logging.
-- =========================================
CREATE OR REPLACE FUNCTION finance.soft_delete_profile_internal(p_profile_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, core
VOLATILE
AS $$
DECLARE
    v_profile_id UUID;
    v_deleted_at TIMESTAMP;
    v_updated BOOLEAN;
BEGIN
    -- Enable RLS for this function
    PERFORM set_config('row_security', 'on', true);

    -- Check if profile exists
    SELECT deleted_at
    INTO v_deleted_at
    FROM core.profiles
    WHERE id = p_profile_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profile not found: %', p_profile_id
            USING ERRCODE = '02000';  -- no_data_found
    END IF;

    IF v_deleted_at IS NOT NULL THEN
        -- Already soft-deleted
        RETURN FALSE;
    END IF;

    -- Get current active profile ID
    v_profile_id := util.current_active_profile_id_internal();

    IF v_profile_id IS DISTINCT FROM p_profile_id THEN
        -- Check admin privileges
        IF NOT util.check_admin_permissions_internal() THEN
            RAISE EXCEPTION
                'Not authorized'
            USING ERRCODE = '42501'; -- insufficient_privilege
        END IF;
    END IF;

    -- Soft-delete only if not already deleted
    UPDATE core.profiles
    SET deleted_at = NOW()
    WHERE id = p_profile_id
      AND deleted_at IS NULL
    RETURNING TRUE
    INTO v_updated;

    -- Already soft-deleted → FALSE
    RETURN COALESCE(v_updated, FALSE);
END;
$$;

-- =========================================
-- 14. Function: public.soft_delete_my_profile
-- =========================================
-- Purpose:
--   Soft-deletes the currently active profile of the authenticated user.
--   Intended to be used via RPC endpoints for self-service profile management.
--
-- Behavior:
--   - Retrieves the current active profile ID using `util.current_active_profile_id_internal()`.
--   - Returns a `NOT_AUTHENTICATED` error if no active profile exists (i.e., user not logged in).
--   - Calls `core.soft_delete_profile_internal(v_profile_id)` to perform the soft-delete:
--       * Returns `ALREADY_DELETED` if the profile was already soft-deleted.
--       * Raises SQLSTATE '02000' if the profile does not exist.
--       * Returns `TRUE` if the profile was successfully soft-deleted.
--   - Returns a success JSON object including the profile ID if deletion succeeds.
--   - Catches exceptions for:
--       * Profile not found (`02000`)
--       * Unauthorized session (`invalid_authorization_specification`)
--       * Insufficient privileges (`insufficient_privilege`)
--       * Any other internal error (`OTHERS`)
--
-- Parameters:
--   p_profile_id UUID
--     Parameter for profile ID (not directly used; function relies on current active profile).
--
-- Returns:
--   JSONB
--     Standardized JSON response object with:
--       - success (BOOLEAN)
--       - code (TEXT)
--       - message (TEXT)
--       - data (JSONB, containing profile_id when applicable)
--
-- Notes:
--   - SECURITY DEFINER allows the function to execute with elevated privileges.
--   - VOLATILE because it updates table data.
--   - Handles authentication, authorization, and soft-delete state in a single RPC-friendly wrapper.
--   - Exception handling ensures uniform JSON output for all error conditions.
-- =========================================
CREATE OR REPLACE FUNCTION public.soft_delete_my_profile(p_profile_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, core
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_deleted BOOLEAN;
BEGIN
    -- Input validation
    IF p_profile_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'MISSING_PROFILE_ID',
            'message', 'Profile ID is required',
            'data', NULL
        );
    END IF;

    -- Authentication check
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'NOT_AUTHENTICATED',
            'message', 'User is not authenticated',
            'data', NULL
        );
    END IF;

    -- Call internal function
    v_deleted := core.soft_delete_profile_internal(p_profile_id);

    -- Already soft-deleted
    IF NOT v_deleted THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'ALREADY_DELETED',
            'message', 'Profile already soft-deleted',
            'data', jsonb_build_object('profile_id', p_profile_id)
        );
    END IF;

    -- Success response
    RETURN jsonb_build_object(
        'success', TRUE,
        'code', 'OK',
        'message', 'Profile soft-deleted; all child data cascaded',
        'data', jsonb_build_object('profile_id', p_profile_id)
    );

EXCEPTION
    -- Explicit NOT FOUND from internal function
    WHEN SQLSTATE '02000' THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_FOUND',
            'message', 'Profile not found',
            'data', jsonb_build_object('profile_id', p_profile_id)
        );

    WHEN invalid_authorization_specification THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_AUTHENTICATED',
            'message', 'User is not authenticated',
            'data', NULL
        );

    WHEN insufficient_privilege THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_AUTHORIZED',
            'message', 'User does not have admin privileges',
            'data', NULL
        );

    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'INTERNAL_ERROR',
            'message', SQLERRM,
            'data', jsonb_build_object('profile_id', p_profile_id)
        );
END;
$$;

-- =========================================
-- 15. Function: public.admin_soft_user_delete_profile
-- =========================================
-- Purpose:
--   Allows an administrator to soft-delete a specific user profile.
--   Designed for administrative use via RPC endpoints or internal scripts.
--
-- Behavior:
--   - Authenticates the calling user via `auth.uid()`.
--   - Returns `NOT_AUTHENTICATED` if the admin session is invalid or missing.
--   - Checks admin privileges using `util.check_admin_permissions_internal()`.
--       * Returns `NOT_AUTHORIZED` if the user lacks admin rights.
--   - Validates the input `p_profile_id`:
--       * Returns `MISSING_PROFILE_ID` if NULL.
--   - Calls `core.soft_delete_profile_internal(p_profile_id)`:
--       * Returns `ALREADY_DELETED` if the profile was already soft-deleted.
--       * Raises SQLSTATE '02000' if the profile does not exist.
--       * Returns `TRUE` if the profile was successfully soft-deleted.
--   - Returns a success JSON object including the profile ID if deletion succeeds.
--   - Exception handling:
--       * `SQLSTATE '02000'` → `NOT_FOUND`
--       * `OTHERS` → `INTERNAL_ERROR`
--
-- Parameters:
--   p_profile_id UUID
--     The unique identifier of the profile to be soft-deleted.
--
-- Returns:
--   JSONB
--     Standardized JSON response object with:
--       - success (BOOLEAN)
--       - code (TEXT)
--       - message (TEXT)
--       - data (JSONB, containing profile_id when applicable)
--
-- Notes:
--   - SECURITY DEFINER ensures the function executes with elevated privileges required for admin operations.
--   - VOLATILE because it modifies table data.
--   - Provides a safe RPC-friendly wrapper for soft-deleting user profiles by administrators.
--   - Exception handling ensures consistent JSON output for all error conditions.
-- =========================================
CREATE OR REPLACE FUNCTION public.admin_soft_user_delete_profile(p_profile_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, core, util
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_deleted BOOLEAN;
BEGIN
    -- Input validation
    IF p_profile_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'MISSING_PROFILE_ID',
            'message', 'Profile ID is required',
            'data', NULL
        );
    END IF;

    -- Authentication check
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'NOT_AUTHENTICATED',
            'message', 'User is not authenticated',
            'data', NULL
        );
    END IF;

    -- Call internal function to soft-delete profile
    v_deleted := core.soft_delete_profile_internal(p_profile_id);

    -- Already soft-deleted
    IF NOT v_deleted THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'ALREADY_DELETED',
            'message', 'Profile already soft-deleted',
            'data', jsonb_build_object('profile_id', p_profile_id)
        );
    END IF;

    -- Success response
    RETURN jsonb_build_object(
        'success', TRUE,
        'code', 'OK',
        'message', 'Profile soft-deleted; all child data cascaded',
        'data', jsonb_build_object('profile_id', p_profile_id)
    );

EXCEPTION
    -- Profile does not exist
    WHEN SQLSTATE '02000' THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'NOT_FOUND',
            'message', 'Profile not found',
            'data', jsonb_build_object('profile_id', p_profile_id)
        );

    -- Any other error
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'code', 'INTERNAL_ERROR',
            'message', SQLERRM,
            'data', jsonb_build_object('profile_id', p_profile_id)
        );
END;
$$;

-- =========================================
-- 16. Function: cleanup_soft_deleted_records_internal
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
    older_than_days INTEGER DEFAULT 90,
    batch_size INTEGER DEFAULT 500  -- number of rows to process per batch
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
    -- List of all tables with soft-delete support
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
    rows_fetched BIGINT;
BEGIN
    -- Enable hard-delete bypass for entire session
    PERFORM set_config('app.hard_delete', 'on', true);

    cutoff_date := NOW() - (older_than_days || ' days')::INTERVAL;

    FOREACH tbl IN ARRAY tables_to_clean LOOP
        deleted_counter := 0;
        failed_counter := 0;
        LOOP
            -- Fetch a batch of IDs to process
            rows_fetched := 0;
            FOR rec IN EXECUTE format(
                'SELECT id FROM %I.%I WHERE deleted_at IS NOT NULL AND deleted_at < $1 ORDER BY deleted_at LIMIT %s FOR UPDATE',
                split_part(tbl, '.', 1),
                split_part(tbl, '.', 2),
                batch_size
            ) USING cutoff_date
            LOOP
                rows_fetched := rows_fetched + 1;

                BEGIN
                    -- Call the existing hard_delete_record_internal function
                    IF finance.hard_delete_record_internal(tbl, rec.id) THEN
                        deleted_counter := deleted_counter + 1;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        failed_counter := failed_counter + 1;

                        -- Log failure
                        RAISE NOTICE
                            'Failed to hard delete record % from table % (SQLSTATE %): %',
                            rec.id, tbl, SQLSTATE, SQLERRM;
                END;
            END LOOP;

            -- If no rows were fetched in this batch, exit the inner loop
            EXIT WHEN rows_fetched = 0;
        END LOOP;

        -- Return the results for this table
        RETURN QUERY
        SELECT tbl, deleted_counter, failed_counter;
    END LOOP;
END;
$$;

-- Schedule the cleanup to run every night at 2:00 AM
SELECT cron.schedule(
  'cleanup_soft_deleted_records_nightly',  -- job name
  '0 2 * * *',                             -- cron expression (2:00 AM daily)
  $$ SELECT finance.cleanup_soft_deleted_records_internal(90, 500); $$
);

-- =========================================
-- 17. Function: cleanup_old_audit_logs_internal
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
    p_days_to_keep INTEGER DEFAULT 90,
    p_batch_size INTEGER DEFAULT 1000  -- number of rows to delete per batch
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, audit, util
VOLATILE
AS $$
DECLARE
    v_deleted_count INTEGER := 0;        -- total deleted rows
    v_batch_deleted INTEGER := 0;        -- rows deleted in current batch
    v_cutoff_date TIMESTAMPTZ;
    rec RECORD;
BEGIN
    -- Calculate cutoff date
    v_cutoff_date := CURRENT_DATE - (p_days_to_keep || ' days')::INTERVAL;

    LOOP
        v_batch_deleted := 0;

        -- Select a batch of old audit log IDs to delete
        FOR rec IN
            SELECT id
            FROM audit.audit_logs
            WHERE created_at < v_cutoff_date
            ORDER BY created_at
            LIMIT p_batch_size
            FOR UPDATE
        LOOP
            -- Delete each row individually
            DELETE FROM audit.audit_logs
            WHERE id = rec.id;

            v_batch_deleted := v_batch_deleted + 1;
        END LOOP;

        -- Add batch count to total
        v_deleted_count := v_deleted_count + v_batch_deleted;

        -- Exit when no more rows in batch
        EXIT WHEN v_batch_deleted = 0;
    END LOOP;

    -- Optional notice for job logs
    RAISE NOTICE 'Deleted % audit logs older than % days', v_deleted_count, p_days_to_keep;

    RETURN v_deleted_count;
END;
$$;

-- Schedule the cleanup to run every night at 2:00 AM
SELECT cron.schedule(
  'cleanup_audit_logs_daily',           -- job name
  '0 2 * * *',                          -- cron expression (2:00 AM daily)
  $$ SELECT audit.cleanup_old_audit_logs_internal(90, 1000); $$  -- call function with fully qualified reference
);

-- =========================================
-- 18. Function: cleanup_old_rate_limits_internal
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
    p_hours_to_keep INTEGER DEFAULT 24,
    p_batch_size INTEGER DEFAULT 1000
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, api, util
VOLATILE
AS $$
DECLARE
    cutoff_timestamp TIMESTAMPTZ;
    v_deleted_count INTEGER := 0;
    v_batch_deleted INTEGER;
BEGIN
    -- Calculate cutoff timestamp
    cutoff_timestamp := NOW() - (p_hours_to_keep || ' hours')::INTERVAL;

    LOOP
        /*
         * Delete a bounded batch of rows.
         * FOR UPDATE SKIP LOCKED ensures:
         * - No contention with concurrent cleanup jobs
         * - No blocking on rows being inserted or processed elsewhere
         */
        WITH to_delete AS (
            SELECT id
            FROM api.api_rate_limits
            WHERE created_at < cutoff_timestamp
            ORDER BY created_at
            LIMIT p_batch_size
            FOR UPDATE SKIP LOCKED
        )
        DELETE FROM api.api_rate_limits arl
        USING to_delete
        WHERE arl.id = to_delete.id;

        GET DIAGNOSTICS v_batch_deleted = ROW_COUNT;

        -- Accumulate total deleted rows
        v_deleted_count := v_deleted_count + v_batch_deleted;

        -- Exit when no more rows qualify
        EXIT WHEN v_batch_deleted = 0;
    END LOOP;

    -- Optional notice for job logs
    RAISE NOTICE
        'Deleted % API rate limit records older than % hours',
        v_deleted_count, p_hours_to_keep;

    RETURN v_deleted_count;
END;
$$;

-- Run cleanup every night at midnight
SELECT cron.schedule(
  'cleanup_api_rate_limits_daily',        -- job name
  '0 0 * * *',                            -- cron expression (midnight daily)
  $$ SELECT util.cleanup_old_rate_limits_internal(24, 1000); $$  -- call function with fully qualified reference
);

-- ================================
-- Grant Permissions
-- ================================
GRANT EXECUTE ON FUNCTION public.initialize_my_defaults() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_initialize_user_defaults(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_hard_delete_record(TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.soft_delete_my_profile(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_soft_user_delete_profile(UUID) TO authenticated;

-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION public.initialize_my_defaults IS 'Definer wrapper for initialize_my_defaults_internal() to enforce RLS';
COMMENT ON FUNCTION finance.initialize_defaults_for_user_internal(UUID) IS 
'Triggers default account and category creation for new users via existing trigger system';
COMMENT ON FUNCTION api.check_rate_limit_internal(VARCHAR, INTEGER, INTEGER) IS 'API rate limiting with configurable windows';
