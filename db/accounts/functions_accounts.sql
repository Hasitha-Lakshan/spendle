-- =========================================
-- 01. Function: get_json_numeric_internal
-- =========================================
-- Purpose:
--   Safely extracts a numeric value from a JSONB object for a specified field,
--   with automatic type casting and default fallback if the value is missing or invalid.
--
-- Behavior:
--   - Checks if the specified field exists in the JSONB object.
--   - Returns the value cast to DECIMAL or INT based on p_type.
--   - Returns p_default if the field is missing, empty, or cannot be cast.
--   - Raises an exception if an unsupported type is requested.
--
-- Parameters:
--   p_json    JSONB   - The JSONB object containing the field.
--   p_field   TEXT    - The field name to extract.
--   p_type    TEXT    - Expected numeric type: 'DECIMAL' or 'INT'.
--   p_default NUMERIC - Default value to return if extraction or casting fails.
--
-- Returns:
--   NUMERIC - The numeric value extracted and cast, or the default if unavailable.
--
-- Notes:
--   - Uses SECURITY DEFINER to allow safe usage within other definer functions
--     while bypassing Row-Level Security (RLS) if required.
--   - Handles casting errors gracefully using an EXCEPTION block.
--   - Designed as a reusable helper function for numeric field extraction
--     from JSONB, centralizing validation and default handling.
-- =========================================
CREATE OR REPLACE FUNCTION util.get_json_numeric_internal(
    p_json JSONB,
    p_field TEXT,
    p_type TEXT,        -- 'DECIMAL' or 'INT'
    p_default NUMERIC   -- default value if missing or invalid
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
STABLE
AS $$
DECLARE
    v_val TEXT;
    v_result NUMERIC;
BEGIN
    -- Check if the JSON contains the requested field
    IF p_json ? p_field THEN
        v_val := TRIM(p_json->>p_field);  -- Trim whitespace

        -- Return default if value is null or empty string
        IF v_val IS NULL OR v_val = '' THEN
            RETURN p_default;
        END IF;

        -- Pre-validate numeric value using regex
        IF (p_type = 'DECIMAL' AND v_val ~ '^[-+]?\d*\.?\d+$') OR
           (p_type = 'INT' AND v_val ~ '^[-+]?\d+$') THEN

            -- Cast to appropriate numeric type
            IF p_type = 'DECIMAL' THEN
                v_result := v_val::DECIMAL(36,18);
            ELSE  -- INT
                v_result := v_val::INT;
            END IF;

            RETURN v_result;

        ELSE
            -- Invalid numeric format, return default
            RETURN p_default;
        END IF;
    ELSE
        -- Field not present, return default
        RETURN p_default;
    END IF;
END;
$$;

-- =========================================
-- 02. Function: validate_account_ownership_internal
-- =========================================
-- Purpose:
--   Checks whether the currently authenticated user owns a specified account.
--
-- Behavior:
--   - Retrieves the current user ID using auth.uid().
--   - Checks the accounts table for a row matching the given account ID,
--     the current user ID, and where deleted_at IS NULL (i.e., not soft-deleted).
--   - Returns TRUE if the account exists and belongs to the user.
--   - Returns FALSE if the account does not exist, belongs to another user,
--     or has been soft-deleted.
--
-- Parameters:
--   p_account_id UUID - The ID of the account to validate ownership for.
--
-- Returns:
--   BOOLEAN - TRUE if the account belongs to the current user and is active,
--             FALSE otherwise.
--
-- Notes:
--   - Uses SECURITY DEFINER to allow safe usage within other definer functions
--     while bypassing Row-Level Security (RLS) if required.
--   - Marked STABLE since it does not modify the database and can be safely
--     used in queries, triggers, or other functions.
--   - Designed as a helper function for access control, validation, and
--     permission checks within account-related operations.
-- =========================================
CREATE OR REPLACE FUNCTION finance.validate_account_ownership_internal(p_account_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
STABLE
AS $$
DECLARE
    v_user_id UUID := auth.uid();  -- current authenticated user
    v_exists BOOLEAN;
BEGIN
    -- Check if the account exists, belongs to the current user, and is not soft-deleted
    SELECT EXISTS(
        SELECT 1 
        FROM finance.accounts 
        WHERE id = p_account_id 
          AND user_id = v_user_id 
          AND deleted_at IS NULL
    ) INTO v_exists;
    
    RETURN v_exists;
END;
$$;

-- =========================================
-- 03. Function: create_account_internal
-- =========================================
-- Purpose:
--   Creates a new account for a given user with both base account data
--   and specialized fields based on account type.
--
-- Behavior:
--   - Validates that the caller is creating the account for themselves.
--   - Ensures the provided account type is valid according to the finance.account_type enum.
--   - Inserts a record into the base 'accounts' table and returns the generated account ID.
--   - Parses specialized fields from the provided JSONB 'p_details', using defaults
--     where values are missing or invalid.
--   - For account types requiring a counterparty (loan, receivable), validates that
--     the counterparty exists and belongs to the current user.
--   - Inserts into the appropriate specialized table based on the account type:
--       cash, bank, credit_card, loan, investment, crypto, wallet, receivable.
--   - Handles numeric fields safely using get_json_numeric_internal to ensure proper casting
--     and default values.
--   - Raises clear exceptions for permission errors, invalid account type, invalid
--     UUIDs, or missing mandatory fields.
--
-- Parameters:
--   p_user_id UUID        - The user ID for whom the account is being created.
--   p_account_name VARCHAR - Name of the new account.
--   p_type finance.account_type   - Enum specifying the type of account to create.
--   p_currency VARCHAR    - Currency code for the account (ISO 4217).
--   p_details JSONB       - Optional JSON containing specialized fields for the account type.
--
-- Returns:
--   UUID - The ID of the newly created account.
--
-- Notes:
--   - Uses SECURITY DEFINER to allow safe usage within other definer functions
--     while bypassing Row-Level Security (RLS) if required.
--   - Designed as a centralized function to standardize account creation logic
--     and enforce data integrity across multiple specialized account tables.
--   - Handles defaulting and validation for numeric fields, text fields, dates,
--     and counterparty references.
--   - Critical for maintaining correct ownership, type safety, and relational integrity.
-- =========================================
CREATE OR REPLACE FUNCTION finance.create_account_internal(
    p_user_id UUID,
    p_account_name VARCHAR,
    p_type finance.account_type,
    p_currency VARCHAR,
    p_details JSONB DEFAULT '{}' -- contains specialized fields per account type
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_account_id UUID;
    v_counterparty_id UUID;

    -- Numeric fields
    v_balance DECIMAL(36,18);
    v_interest_rate DECIMAL(36,18);
    v_credit_limit DECIMAL(36,18);
    v_current_balance DECIMAL(36,18);
    v_principal_amount DECIMAL(36,18);
    v_outstanding_amount DECIMAL(36,18);
    v_term_months INT;
    v_portfolio_value DECIMAL(36,18);
    v_amount_due DECIMAL(36,18);

    v_type_text TEXT := p_type::TEXT;
BEGIN
    -- Enable Row-Level Security
    PERFORM set_config('row_security', 'on', true);

    -- Ensure authenticated user
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Ensure caller is creating account only for themselves
    IF p_user_id IS DISTINCT FROM v_user_id THEN
        RAISE EXCEPTION 'Permission denied: cannot create account for another user'
            USING ERRCODE = '42501';
    END IF;

    -- Enum-safe validation for account type
    IF NOT EXISTS (
        SELECT 1
        FROM unnest(enum_range(NULL::finance.account_type)) AS t(val)
        WHERE t.val::TEXT = v_type_text
    ) THEN
        RAISE EXCEPTION 'Invalid account type: %', v_type_text;
    END IF;
    
    -- Safely cast counterparty_id to UUID if present
    IF p_details ? 'counterparty_id' THEN
        BEGIN
            v_counterparty_id := (p_details->>'counterparty_id')::UUID;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Invalid counterparty_id: % is not a valid UUID', p_details->>'counterparty_id';
        END;
    END IF;

    -- Parse numeric fields using helper function
    v_balance := util.get_json_numeric_internal(p_details, 'balance', 'DECIMAL', 0);
    v_interest_rate := util.get_json_numeric_internal(p_details, 'interest_rate', 'DECIMAL', 0);
    v_credit_limit := util.get_json_numeric_internal(p_details, 'credit_limit', 'DECIMAL', 0);
    v_current_balance := util.get_json_numeric_internal(p_details, 'current_balance', 'DECIMAL', 0);
    v_principal_amount := util.get_json_numeric_internal(p_details, 'principal_amount', 'DECIMAL', 0);
    v_outstanding_amount := util.get_json_numeric_internal(p_details, 'outstanding_amount', 'DECIMAL', 0);
    v_term_months := util.get_json_numeric_internal(p_details, 'term_months', 'INT', 12);
    v_portfolio_value := util.get_json_numeric_internal(p_details, 'portfolio_value', 'DECIMAL', 0);
    v_amount_due := util.get_json_numeric_internal(p_details, 'amount_due', 'DECIMAL', 0);

    -- Insert into base accounts table
    INSERT INTO finance.accounts(user_id, account_name, type, currency)
    VALUES (p_user_id, p_account_name, p_type, p_currency)
    RETURNING id INTO v_account_id;

    -- Insert into specialized account table based on type
    CASE p_type
        WHEN 'cash' THEN
            INSERT INTO finance.cash_accounts(account_id, location, balance, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'location', 'Wallet'),
                v_balance,
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default cash account')
            )
            ON CONFLICT (account_id) DO NOTHING;

        WHEN 'bank' THEN
            INSERT INTO finance.bank_accounts(account_id, bank_name, account_no, branch, account_holder_name, balance, interest_rate, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'bank_name', 'UNKNOWN'),
                COALESCE(p_details->>'account_no', '0000'),
                COALESCE(p_details->>'branch', 'Main'),
                COALESCE(p_details->>'account_holder_name', 'User'),
                v_balance,
                v_interest_rate,
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default bank account')
            )
            ON CONFLICT (account_id) DO NOTHING;

        WHEN 'credit_card' THEN
            INSERT INTO finance.credit_card_accounts(account_id, card_number, card_type, credit_limit, current_balance, billing_cycle, interest_rate, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'card_number', '0000'),
                COALESCE(p_details->>'card_type', 'Standard'),
                v_credit_limit,
                v_current_balance,
                COALESCE(p_details->>'billing_cycle', 'monthly'),
                v_interest_rate,
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default credit card')
            )
            ON CONFLICT (account_id) DO NOTHING;

        WHEN 'loan' THEN
            -- Ensure counterparty_id is mandatory
            IF v_counterparty_id IS NULL THEN
                RAISE EXCEPTION 'counterparty_id is required and must be valid UUID for loan accounts';
            END IF;

            -- Validate counterparty_id ownership
            IF NOT EXISTS (
                SELECT 1 FROM finance.counterparties WHERE id = v_counterparty_id AND user_id = v_user_id
            ) THEN
                RAISE EXCEPTION 'Invalid counterparty_id: % or does not belong to current user', v_counterparty_id;
            END IF;

            INSERT INTO finance.loan_accounts(account_id, loan_type, principal_amount, outstanding_amount, interest_rate, term_months, start_date, end_date, status, notes, counterparty_id, collateral)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'loan_type', 'Personal'),
                v_principal_amount,
                v_outstanding_amount,
                v_interest_rate,
                v_term_months,
                COALESCE((p_details->>'start_date')::DATE, CURRENT_DATE),
                COALESCE((p_details->>'end_date')::DATE, CURRENT_DATE + INTERVAL '1 year'),
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default loan account'),
                v_counterparty_id,
                p_details->>'collateral'
            )
            ON CONFLICT (account_id) DO NOTHING;

        WHEN 'investment' THEN
            INSERT INTO finance.investment_accounts(account_id, investment_type, institution_name, account_no, portfolio_value, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'investment_type', 'Stock'),
                COALESCE(p_details->>'institution_name', 'Unknown'),
                COALESCE(p_details->>'account_no', '0000'),
                v_portfolio_value,
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default investment account')
            )
            ON CONFLICT (account_id) DO NOTHING;

        WHEN 'crypto' THEN
            INSERT INTO finance.crypto_accounts(account_id, crypto_wallet_address, exchange_name, balance, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'crypto_wallet_address', 'pending'),
                COALESCE(p_details->>'exchange_name', 'Unknown'),
                v_balance,
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default crypto account')
            )
            ON CONFLICT (account_id) DO NOTHING;

        WHEN 'wallet' THEN
            INSERT INTO finance.wallet_accounts(account_id, wallet_name, provider, balance, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'wallet_name', 'Default Wallet'),
                COALESCE(p_details->>'provider', 'Generic'),
                v_balance,
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default wallet account')
            )
            ON CONFLICT (account_id) DO NOTHING;

        WHEN 'receivable' THEN
            -- Ensure counterparty_id is mandatory
            IF v_counterparty_id IS NULL THEN
                RAISE EXCEPTION 'counterparty_id is required and must be valid UUID for receivable accounts';
            END IF;

            -- Validate counterparty_id ownership
            IF NOT EXISTS (
                SELECT 1 FROM finance.counterparties WHERE id = v_counterparty_id AND user_id = v_user_id
            ) THEN
                RAISE EXCEPTION 'Invalid counterparty_id: % or does not belong to current user', v_counterparty_id;
            END IF;

            INSERT INTO finance.receivable_accounts(account_id, counterparty_id, invoice_no, principal_amount, amount_due, due_date, status, notes)
            VALUES (
                v_account_id,
                v_counterparty_id,
                COALESCE(p_details->>'invoice_no', 'INV000'),
                v_principal_amount,
                v_amount_due,
                COALESCE((p_details->>'due_date')::DATE, CURRENT_DATE),
                COALESCE(p_details->>'status', 'pending'),
                COALESCE(p_details->>'notes', 'Default receivable account')
            )
            ON CONFLICT (account_id) DO NOTHING;

        ELSE
            RAISE EXCEPTION 'Unknown account type: %', p_type;
    END CASE;

    RETURN v_account_id;
END;
$$;

-- =========================================
-- 04. Function: update_account_internal
-- =========================================
-- Purpose:
--   Updates an existing account and its associated specialized account record
--   based on the provided JSONB payload, while enforcing ownership, rate limits,
--   and data integrity.
--
-- Behavior:
--   - Validates that the current user owns the account being updated.
--   - Enforces a rate limit to prevent excessive update requests.
--   - Retrieves the base account information and ensures the account is active
--     (not soft-deleted).
--   - Updates base account fields such as account_name and currency when provided.
--   - Safely parses and applies numeric fields using get_json_numeric_internal, ensuring
--     partial updates do not overwrite existing values unintentionally.
--   - Validates and applies counterparty_id updates for account types that
--     support counterparties (loan, receivable).
--   - Updates the appropriate specialized account table based on the account type.
--   - Returns a merged JSONB object containing base account data and the updated
--     specialized account details.
--
-- Parameters:
--   p_account_id UUID - The ID of the account to update.
--   p_update_data JSONB - A JSONB object containing fields to update. Only
--                         provided fields are modified; others remain unchanged.
--
-- Returns:
--   JSONB - A JSONB object combining the base account data with the updated
--           specialized account fields.
--
-- Notes:
--   - Uses SECURITY DEFINER to allow controlled privilege escalation and to
--     safely bypass Row-Level Security (RLS) where required.
--   - Marked VOLATILE because it performs write operations and depends on
--     runtime context such as auth.uid() and rate limiting.
--   - Designed to support partial updates without requiring the full account
--     payload to be resubmitted.
--   - Ensures counterparty ownership validation to maintain referential and
--     access integrity.
--   - Centralizes update logic for all account types to maintain consistency
--     across specialized account tables.
-- =========================================
CREATE OR REPLACE FUNCTION finance.update_account_internal(
    p_account_id UUID,
    p_update_data JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, api
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_max_requests INTEGER := 100;
    v_window_minutes INTEGER := 60;
    v_account_type finance.account_type;
    v_base JSONB;
    v_details JSONB;
    v_counterparty_id UUID;

    -- Numeric fields
    v_balance DECIMAL(36,18);
    v_interest_rate DECIMAL(36,18);
    v_credit_limit DECIMAL(36,18);
    v_current_balance DECIMAL(36,18);
    v_principal_amount DECIMAL(36,18);
    v_outstanding_amount DECIMAL(36,18);
    v_term_months INT;
    v_portfolio_value DECIMAL(36,18);
    v_amount_due DECIMAL(36,18);
BEGIN
    -- Enable Row-Level Security
    PERFORM set_config('row_security', 'on', true);

    -- Ensure authenticated user
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Validate ownership
    IF NOT finance.validate_account_ownership_internal(p_account_id) THEN
        RAISE EXCEPTION 'Permission denied: cannot update this account'
            USING ERRCODE = '42501';
    END IF;

    -- Enforce rate limit
    IF NOT api.check_rate_limit_internal('update_account', v_max_requests, v_window_minutes) THEN
        RAISE EXCEPTION 'Rate limit exceeded: max % requests per % minutes',
            v_max_requests, v_window_minutes;
    END IF;

    -- Fetch base account info
    SELECT jsonb_build_object(
        'id', a.id,
        'user_id', a.user_id,
        'account_name', a.account_name,
        'type', a.type,
        'currency', a.currency,
        'created_at', a.created_at,
        'updated_at', a.updated_at
    )
    INTO v_base
    FROM finance.accounts a
    WHERE a.id = p_account_id
      AND a.user_id = v_user_id
      AND a.deleted_at IS NULL;

    IF v_base IS NULL THEN
        RAISE EXCEPTION 'Account not found or access denied';
    END IF;

    -- Validate and cast account type safely
    IF NOT EXISTS (
        SELECT 1
        FROM unnest(enum_range(NULL::finance.account_type)) AS t(val)
        WHERE t.val::TEXT = v_base->>'type'
    ) THEN
        RAISE EXCEPTION 'Invalid account type in database: %', v_base->>'type';
    END IF;

    v_account_type := (v_base->>'type')::finance.account_type;

    -- Safely cast counterparty_id if present
    IF p_update_data ? 'counterparty_id' THEN
        BEGIN
            v_counterparty_id := (p_update_data->>'counterparty_id')::UUID;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Invalid counterparty_id: % is not a valid UUID',
                p_update_data->>'counterparty_id';
        END;
    END IF;

    -- Parse numeric fields using helper function
    v_balance := util.get_json_numeric_internal(p_update_data, 'balance', 'DECIMAL', NULL);
    v_interest_rate := util.get_json_numeric_internal(p_update_data, 'interest_rate', 'DECIMAL', NULL);
    v_credit_limit := util.get_json_numeric_internal(p_update_data, 'credit_limit', 'DECIMAL', NULL);
    v_current_balance := util.get_json_numeric_internal(p_update_data, 'current_balance', 'DECIMAL', NULL);
    v_principal_amount := util.get_json_numeric_internal(p_update_data, 'principal_amount', 'DECIMAL', NULL);
    v_outstanding_amount := util.get_json_numeric_internal(p_update_data, 'outstanding_amount', 'DECIMAL', NULL);
    v_term_months := util.get_json_numeric_internal(p_update_data, 'term_months', 'INT', NULL);
    v_portfolio_value := util.get_json_numeric_internal(p_update_data, 'portfolio_value', 'DECIMAL', NULL);
    v_amount_due := util.get_json_numeric_internal(p_update_data, 'amount_due', 'DECIMAL', NULL);

    -- Update base account fields
    UPDATE finance.accounts
    SET
        account_name = COALESCE(p_update_data->>'account_name', account_name),
        currency = COALESCE(p_update_data->>'currency', currency),
        updated_at = NOW()
    WHERE id = p_account_id
        AND deleted_at IS NULL;

    -- Update specialized tables
    CASE v_account_type
        WHEN 'cash' THEN
            UPDATE finance.cash_accounts
            SET
                location = COALESCE(p_update_data->>'location', location),
                balance = COALESCE(v_balance, balance),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(finance.cash_accounts) - 'account_id' INTO v_details;

        WHEN 'bank' THEN
            UPDATE finance.bank_accounts
            SET
                bank_name = COALESCE(p_update_data->>'bank_name', bank_name),
                account_no = COALESCE(p_update_data->>'account_no', account_no),
                branch = COALESCE(p_update_data->>'branch', branch),
                account_holder_name = COALESCE(p_update_data->>'account_holder_name', account_holder_name),
                balance = COALESCE(v_balance, balance),
                interest_rate = COALESCE(v_interest_rate, interest_rate),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(finance.bank_accounts) - 'account_id' INTO v_details;

        WHEN 'credit_card' THEN
            UPDATE finance.credit_card_accounts
            SET
                card_number = COALESCE(p_update_data->>'card_number', card_number),
                card_type = COALESCE(p_update_data->>'card_type', card_type),
                credit_limit = COALESCE(v_credit_limit, credit_limit),
                current_balance = COALESCE(v_current_balance, current_balance),
                billing_cycle = COALESCE(p_update_data->>'billing_cycle', billing_cycle),
                interest_rate = COALESCE(v_interest_rate, interest_rate),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(finance.credit_card_accounts) - 'account_id' INTO v_details;

        WHEN 'investment' THEN
            UPDATE finance.investment_accounts
            SET
                investment_type = COALESCE(p_update_data->>'investment_type', investment_type),
                institution_name = COALESCE(p_update_data->>'institution_name', institution_name),
                account_no = COALESCE(p_update_data->>'account_no', account_no),
                portfolio_value = COALESCE(v_portfolio_value, portfolio_value),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(finance.investment_accounts) - 'account_id' INTO v_details;

        WHEN 'crypto' THEN
            UPDATE finance.crypto_accounts
            SET
                crypto_wallet_address = COALESCE(p_update_data->>'crypto_wallet_address', crypto_wallet_address),
                exchange_name = COALESCE(p_update_data->>'exchange_name', exchange_name),
                balance = COALESCE(v_balance, balance),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(finance.crypto_accounts) - 'account_id' INTO v_details;

        WHEN 'wallet' THEN
            UPDATE finance.wallet_accounts
            SET
                wallet_name = COALESCE(p_update_data->>'wallet_name', wallet_name),
                provider = COALESCE(p_update_data->>'provider', provider),
                balance = COALESCE(v_balance, balance),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(finance.wallet_accounts) - 'account_id' INTO v_details;

        WHEN 'loan' THEN
            -- Validate counterparty_id
            IF v_counterparty_id IS NOT NULL THEN
                IF NOT EXISTS (
                    SELECT 1
                    FROM finance.counterparties
                    WHERE id = v_counterparty_id
                      AND user_id = v_user_id
                ) THEN
                    RAISE EXCEPTION
                        'Invalid counterparty_id: % or does not belong to current user',
                        v_counterparty_id;
                END IF;
            END IF;

            UPDATE finance.loan_accounts
            SET
                loan_type = COALESCE(p_update_data->>'loan_type', loan_type),
                principal_amount = COALESCE(v_principal_amount, principal_amount),
                outstanding_amount = COALESCE(v_outstanding_amount, outstanding_amount),
                interest_rate = COALESCE(v_interest_rate, interest_rate),
                term_months = COALESCE(v_term_months, term_months),
                start_date = COALESCE((p_update_data->>'start_date')::DATE, start_date),
                end_date = COALESCE((p_update_data->>'end_date')::DATE, end_date),
                notes = COALESCE(p_update_data->>'notes', notes),
                counterparty_id = COALESCE(v_counterparty_id, counterparty_id),
                collateral = COALESCE(p_update_data->>'collateral', collateral)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(finance.loan_accounts) - 'account_id' INTO v_details;

        WHEN 'receivable' THEN
            -- Validate counterparty_id
            IF v_counterparty_id IS NOT NULL THEN
                IF NOT EXISTS (
                    SELECT 1
                    FROM finance.counterparties
                    WHERE id = v_counterparty_id
                      AND user_id = v_user_id
                ) THEN
                    RAISE EXCEPTION
                        'Invalid counterparty_id: % or does not belong to current user',
                        v_counterparty_id;
                END IF;
            END IF;

            UPDATE finance.receivable_accounts
            SET
                counterparty_id = COALESCE(v_counterparty_id, counterparty_id),
                invoice_no = COALESCE(p_update_data->>'invoice_no', invoice_no),
                principal_amount = COALESCE(v_principal_amount, principal_amount),
                amount_due = COALESCE(v_amount_due, amount_due),
                due_date = COALESCE((p_update_data->>'due_date')::DATE, due_date),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(finance.receivable_accounts) - 'account_id' INTO v_details;

        ELSE
            RAISE EXCEPTION 'Unknown account type: %', v_account_type;
    END CASE;

    RETURN v_base || COALESCE(v_details, '{}'::jsonb);
END;
$$;

-- =========================================
-- 05. Function: soft_delete_account_internal
-- =========================================
-- Purpose:
--   Performs a soft delete on a user-owned account by marking it as deleted
--   without physically removing the record from the database.
--
-- Behavior:
--   - Ensures the caller is authenticated.
--   - Validates that the caller owns the account using the
--     validate_account_ownership_internal helper.
--   - Updates the account's deleted_at and updated_at timestamps to indicate
--     a soft-deleted state.
--   - Returns TRUE if the account was successfully soft-deleted.
--   - Returns FALSE if the account does not exist or is already soft-deleted.
--   - Relies on database triggers (e.g., cleanup_specialized_account) to handle
--     cascading effects or cleanup for linked specialized account tables.
--
-- Parameters:
--   p_account_id UUID - The ID of the account to soft-delete.
--
-- Returns:
--   BOOLEAN - TRUE if the account was soft-deleted successfully,
--             FALSE if no update was performed.
--
-- Notes:
--   - Uses SECURITY DEFINER to allow controlled privilege escalation while
--     respecting Row-Level Security (RLS).
--   - Strictly enforces ownership: users can delete only their own accounts.
--   - Explicit exception handling is provided for:
--       * unique_violation
--       * data_exception
--       * other unexpected errors
--     to provide clear and actionable error messages.
--   - Does not physically remove records to preserve historical data and
--     maintain referential integrity.
-- =========================================
CREATE OR REPLACE FUNCTION finance.soft_delete_account_internal(p_account_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_exists UUID;
BEGIN
    -- Enable Row-Level Security
    PERFORM set_config('row_security', 'on', true);

    -- Ensure authenticated user
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Validate ownership (users can delete only their own accounts)
    IF NOT finance.validate_account_ownership_internal(p_account_id) THEN
        RAISE EXCEPTION
            'Permission denied: user is not authorized to delete account (%s).',
            p_account_id
            USING ERRCODE = '42501';
    END IF;

    -- Perform soft delete (self-owned accounts only)
    UPDATE finance.accounts
    SET deleted_at = NOW(),
        updated_at = NOW()
    WHERE id = p_account_id
      AND user_id = v_user_id
      AND deleted_at IS NULL
    RETURNING id INTO v_exists;

    -- If nothing was updated, either already deleted or nonexistent
    IF v_exists IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Trigger cleanup_specialized_account will handle linked accounts
    RETURN TRUE;

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION
            'Duplicate account ID (%s) detected during soft delete.',
            p_account_id;
    WHEN data_exception THEN
        RAISE EXCEPTION
            'Invalid data encountered while soft deleting account (%s): %s',
            p_account_id, SQLERRM;
    WHEN OTHERS THEN
        RAISE EXCEPTION
            'Unexpected error during soft delete of account (%s): %s',
            p_account_id, SQLERRM;
END;
$$;

-- =========================================
-- 06. Function: admin_soft_delete_account_internal
-- =========================================
-- Purpose:
--   Performs a soft delete on any account by marking it as deleted without
--   physically removing the record from the database. This operation is
--   restricted to administrators.
--
-- Behavior:
--   - Validates that the caller has administrative privileges using
--     check_admin_permissions_internal().
--   - Updates the account's deleted_at and updated_at timestamps to indicate
--     a soft-deleted state.
--   - Returns TRUE if the account was successfully soft-deleted.
--   - Returns FALSE if the account does not exist or is already soft-deleted.
--   - Relies on database triggers (e.g., cleanup_specialized_account) to handle
--     cascading effects or cleanup for linked specialized account tables.
--
-- Parameters:
--   p_account_id UUID - The ID of the account to be soft-deleted.
--
-- Returns:
--   BOOLEAN - TRUE if the account was soft-deleted successfully,
--             FALSE if no update was performed.
--
-- Notes:
--   - Uses SECURITY DEFINER to allow controlled privilege escalation while
--     respecting Row-Level Security (RLS).
--   - Only callable by administrators; regular users cannot invoke this function.
--   - Explicit exception handling is provided for:
--       * unique_violation
--       * data_exception
--       * other unexpected errors
--     to provide clear and actionable error messages.
--   - Does not physically remove records to preserve historical data and
--     maintain referential integrity.
-- =========================================
CREATE OR REPLACE FUNCTION finance.admin_soft_delete_account_internal(p_account_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, util
VOLATILE
AS $$
DECLARE
    v_is_admin BOOLEAN := util.check_admin_permissions_internal();
    v_exists UUID;
BEGIN
    -- Enable Row-Level Security
    PERFORM set_config('row_security', 'on', true);

    -- Ensure caller is an admin
    IF NOT v_is_admin THEN
        RAISE EXCEPTION 'Permission denied: only admins can soft delete accounts.'
            USING ERRCODE = '42501';
    END IF;

    -- Perform soft delete (any user’s account)
    UPDATE finance.accounts
    SET deleted_at = NOW(),
        updated_at = NOW()
    WHERE id = p_account_id
      AND deleted_at IS NULL
    RETURNING id INTO v_exists;

    -- If nothing was updated, either already deleted or nonexistent
    IF v_exists IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Trigger cleanup_specialized_account will handle linked accounts
    RETURN TRUE;

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Duplicate account ID (%s) detected during soft delete.', p_account_id;
    WHEN data_exception THEN
        RAISE EXCEPTION 'Invalid data encountered while soft deleting account (%s): %s', p_account_id, SQLERRM;
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Unexpected error during soft delete of account (%s): %s', p_account_id, SQLERRM;
END;
$$;

-- =========================================
-- 07. Function: admin_hard_delete_account_internal
-- =========================================
-- Purpose:
--   Permanently removes an account and all related data from the system,
--   including transactions and specialized account records.
--
-- Behavior:
--   - Requires the caller to be authenticated and have administrator privileges.
--   - Ensures the account exists and has already been soft-deleted before
--     allowing a hard delete.
--   - Temporarily enables a session-level configuration flag to allow
--     hard-delete operations.
--   - Deletes all transactions that reference the account across all
--     transaction types (income, expense, investment, borrow, lend, transfer,
--     and adjustment).
--   - Deletes the corresponding specialized account record based on account type.
--   - Deletes the base account record from the accounts table.
--   - Returns TRUE upon successful completion.
--
-- Parameters:
--   p_account_id UUID - The ID of the account to be permanently deleted.
--
-- Returns:
--   BOOLEAN - TRUE if the account and all related data were successfully
--             deleted.
--
-- Notes:
--   - Uses SECURITY DEFINER to allow controlled privilege escalation and
--     bypass Row-Level Security (RLS) where required.
--   - Restricted to administrators only to prevent irreversible data loss.
--   - Requires a prior soft delete to reduce the risk of accidental
--     permanent deletions.
--   - Explicitly removes dependent transaction data to maintain referential
--     integrity and avoid orphaned records.
--   - Intended for administrative or maintenance workflows only.
-- =========================================
CREATE OR REPLACE FUNCTION finance.admin_hard_delete_account_internal(p_account_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, util
VOLATILE
AS $$
DECLARE
    current_user_id UUID;
    account_owner UUID;
    account_type finance.account_type;
    is_admin BOOLEAN;
    v_deleted_at timestamptz;
BEGIN
    -- Enable Row-Level Security for this session
    PERFORM set_config('row_security', 'on', true);

    current_user_id := auth.uid();

    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Check admin permissions
    is_admin := util.check_admin_permissions_internal();
    IF NOT is_admin THEN
        RAISE EXCEPTION 'Permission denied: only admins can hard delete';
    END IF;

    -- Enable hard delete bypass for this session
    PERFORM set_config('app.hard_delete', 'on', true);

    -- Get account info
    SELECT user_id, type, deleted_at
    INTO account_owner, account_type, v_deleted_at
    FROM finance.accounts
    WHERE id = p_account_id;

    IF account_owner IS NULL THEN
        RAISE EXCEPTION 'Account not found';
    END IF;

    IF v_deleted_at IS NULL THEN
        RAISE EXCEPTION 'Account must be soft-deleted before hard delete';
    END IF;

    -- Delete all transactions referencing this account using EXISTS for performance
    DELETE FROM finance.transactions t
    WHERE EXISTS (
        SELECT 1 FROM finance.transactions_income ti
        WHERE ti.transaction_id = t.id AND ti.account_id = p_account_id
    )
    OR EXISTS (
        SELECT 1 FROM finance.transactions_expense te
        WHERE te.transaction_id = t.id AND te.account_id = p_account_id
    )
    OR EXISTS (
        SELECT 1 FROM finance.transactions_investment ti
        WHERE ti.transaction_id = t.id AND (ti.funding_account_id = p_account_id OR ti.investment_account_id = p_account_id)
    )
    OR EXISTS (
        SELECT 1 FROM finance.transactions_borrow tb
        WHERE tb.transaction_id = t.id AND (tb.loan_account_id = p_account_id OR tb.disbursement_account_id = p_account_id)
    )
    OR EXISTS (
        SELECT 1 FROM finance.transactions_lend tl
        WHERE tl.transaction_id = t.id AND (tl.funding_account_id = p_account_id OR tl.receivable_account_id = p_account_id)
    )
    OR EXISTS (
        SELECT 1 FROM finance.transactions_transfer tt
        WHERE tt.transaction_id = t.id AND (tt.from_account = p_account_id OR tt.to_account = p_account_id)
    )
    OR EXISTS (
        SELECT 1 FROM finance.transactions_adjustment ta
        WHERE ta.transaction_id = t.id AND ta.account_id = p_account_id
    );

    -- Delete the specialized account row
    CASE account_type
        WHEN 'cash'       THEN DELETE FROM finance.cash_accounts        WHERE account_id = p_account_id;
        WHEN 'bank'       THEN DELETE FROM finance.bank_accounts        WHERE account_id = p_account_id;
        WHEN 'credit_card' THEN DELETE FROM finance.credit_card_accounts WHERE account_id = p_account_id;
        WHEN 'loan'       THEN DELETE FROM finance.loan_accounts        WHERE account_id = p_account_id;
        WHEN 'investment' THEN DELETE FROM finance.investment_accounts  WHERE account_id = p_account_id;
        WHEN 'crypto'     THEN DELETE FROM finance.crypto_accounts      WHERE account_id = p_account_id;
        WHEN 'wallet'     THEN DELETE FROM finance.wallet_accounts      WHERE account_id = p_account_id;
        WHEN 'receivable' THEN DELETE FROM finance.receivable_accounts  WHERE account_id = p_account_id;
        ELSE
            RAISE EXCEPTION 'Unknown account type during hard delete: %', account_type;
    END CASE;

    -- Delete the account itself
    DELETE FROM finance.accounts WHERE id = p_account_id;

    RETURN TRUE;
END;
$$;

-- =========================================
-- 08. Function: create_account
-- =========================================
-- Purpose:
--   Provides a public-facing wrapper for creating a new account, delegating
--   the actual creation logic to create_account_internal.
--
-- Behavior:
--   - Executes as SECURITY INVOKER, ensuring the caller’s identity and
--     permissions are preserved.
--   - Passes all parameters directly to create_account_internal without
--     modifying input data.
--   - Relies on internal function logic for validation, ownership checks,
--     and data integrity enforcement.
--
-- Parameters:
--   p_user_id UUID        - The user ID for whom the account is being created.
--   p_account_name TEXT  - Name of the new account.
--   p_type finance.account_type  - Enum specifying the type of account to create.
--   p_currency TEXT      - Currency code for the account.
--   p_details JSONB      - JSON object containing specialized fields for the
--                          account type.
--
-- Returns:
--   UUID - The ID of the newly created account.
--
-- Notes:
--   - Designed as a thin wrapper to clearly separate privilege boundaries
--     between invoker-level and definer-level logic.
--   - Keeps all sensitive validation and insert operations centralized
--     within create_account_internal.
--   - Suitable for direct use by application code or API layers.
-- =========================================
CREATE OR REPLACE FUNCTION public.create_account(
    p_user_id UUID,
    p_account_name TEXT,
    p_type finance.account_type,
    p_currency TEXT,
    p_details JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_account_id UUID;
BEGIN
    -- Basic input validation
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'User id is required';
    END IF;

    IF p_account_name IS NULL OR trim(p_account_name) = '' THEN
        RAISE EXCEPTION 'Account name is required';
    END IF;

    IF p_currency IS NULL OR trim(p_currency) = '' THEN
        RAISE EXCEPTION 'Currency is required';
    END IF;

    -- Call internal function
    v_account_id := finance.create_account_internal(
        p_user_id,
        p_account_name,
        p_type,
        p_currency,
        p_details
    );

    RETURN jsonb_build_object(
        'success', true,
        'account_id', v_account_id,
        'message', 'Account created successfully'
    );

EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', NULL,
            'message', 'An account with the same name and type already exists'
        );

    WHEN check_violation OR foreign_key_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', NULL,
            'message', 'Invalid account data'
        );

    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', NULL,
            'message', 'Failed to create account'
        );
END;
$$;

-- =========================================
-- 09. Function: update_account
-- =========================================
-- Purpose:
--   Provides a public-facing wrapper for updating an existing account,
--   delegating all validation and update logic to update_account_internal.
--
-- Behavior:
--   - Executes as SECURITY INVOKER, preserving the caller’s identity and
--     permission context.
--   - Forwards the account ID and update payload directly to the internal
--     update function without altering the input.
--   - Relies on update_account_internal for ownership checks, rate limiting,
--     validation, and data persistence.
--
-- Parameters:
--   p_account_id UUID   - The ID of the account to be updated.
--   p_update_data JSONB - A JSONB object containing fields to update.
--
-- Returns:
--   JSONB - A JSONB object representing the updated account, including
--           base and specialized account details.
--
-- Notes:
--   - Designed as a thin wrapper to maintain a clear separation between
--     invoker-level access and definer-level business logic.
--   - Suitable for direct use by application and API layers.
--   - Centralizes complex update behavior within update_account_internal
--     for consistency and maintainability.
-- =========================================
CREATE OR REPLACE FUNCTION public.update_account(
    p_account_id UUID,
    p_update_data JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_result JSONB;
BEGIN
    -- Basic input validation
    IF p_account_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', NULL,
            'message', 'Account ID is required'
        );
    END IF;

    IF p_update_data IS NULL OR jsonb_typeof(p_update_data) <> 'object' THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', p_account_id,
            'message', 'Update data must be a valid JSON object'
        );
    END IF;

    -- Call internal function
    v_result := finance.update_account_internal(p_account_id, p_update_data);

    RETURN jsonb_build_object(
        'success', true,
        'account_id', p_account_id,
        'updated_data', v_result,
        'message', 'Account updated successfully'
    );

EXCEPTION
    WHEN unique_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', p_account_id,
            'message', 'Account with the same name already exists'
        );

    WHEN check_violation OR foreign_key_violation THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', p_account_id,
            'message', 'Invalid update data'
        );

    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', p_account_id,
            'message', 'Failed to update account'
        );
END;
$$;

-- =========================================
-- 10. Function: soft_delete_account
-- =========================================
-- Purpose:
--   Provides a SECURITY INVOKER wrapper for performing a soft delete on a 
--   user-owned account by delegating to soft_delete_account_internal().
--
-- Behavior:
--   - Simply calls soft_delete_account_internal() which performs all
--     authentication, ownership validation, and soft-delete logic.
--   - Returns the result of the internal function.
--
-- Parameters:
--   p_account_id UUID - The ID of the account to be soft-deleted.
--
-- Returns:
--   BOOLEAN - TRUE if the account was soft-deleted successfully,
--             FALSE if the account does not exist or is already soft-deleted.
--
-- Notes:
--   - SECURITY INVOKER ensures that the caller's privileges are used, while
--     the internal function handles SECURITY DEFINER operations.
--   - Acts as a safe, public-facing interface to the internal function.
--   - No direct validation or RLS handling occurs here; all logic is delegated.
-- =========================================
CREATE OR REPLACE FUNCTION public.soft_delete_account(
    p_account_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_success BOOLEAN;
BEGIN
    IF p_account_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', NULL,
            'message', 'Account ID is required'
        );
    END IF;

    -- Call internal function
    v_success := finance.soft_delete_account_internal(p_account_id);

    IF v_success THEN
        RETURN jsonb_build_object(
            'success', true,
            'account_id', p_account_id,
            'message', 'Account soft-deleted successfully'
        );
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'account_id', p_account_id,
            'message', 'Account could not be soft-deleted'
        );
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', p_account_id,
            'message', 'Failed to soft-delete account'
        );
END;
$$;

-- =========================================
-- 11. Function: admin_soft_delete_account
-- =========================================
-- Purpose:
--   Provides a SECURITY INVOKER wrapper for performing a soft delete on any
--   account by delegating to admin_soft_delete_account_internal().
--
-- Behavior:
--   - Calls admin_soft_delete_account_internal(), which performs all
--     administrative privilege checks and soft-delete logic.
--   - Returns the result of the internal function.
--
-- Parameters:
--   p_account_id UUID - The ID of the account to be soft-deleted.
--
-- Returns:
--   BOOLEAN - TRUE if the account was soft-deleted successfully,
--             FALSE if the account does not exist or is already soft-deleted.
--
-- Notes:
--   - SECURITY INVOKER ensures the function runs with the caller's privileges,
--     while the internal function handles SECURITY DEFINER operations.
--   - Acts as a safe, public-facing interface for administrators.
--   - All authentication, permission validation, and RLS handling are
--     performed inside the internal function.
-- =========================================
CREATE OR REPLACE FUNCTION public.admin_soft_delete_account(
    p_account_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_success BOOLEAN;
BEGIN
    IF p_account_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', NULL,
            'message', 'Account ID is required'
        );
    END IF;

    -- Call internal function
    v_success := finance.admin_soft_delete_account_internal(p_account_id);

    IF v_success THEN
        RETURN jsonb_build_object(
            'success', true,
            'account_id', p_account_id,
            'message', 'Account soft-deleted successfully by admin'
        );
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'account_id', p_account_id,
            'message', 'Account could not be soft-deleted by admin'
        );
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', p_account_id,
            'message', 'Failed to soft-delete account'
        );
END;
$$;

-- =========================================
-- 12. Function: admin_hard_delete_account
-- =========================================
-- Purpose:
--   Provides a public-facing wrapper for permanently deleting an account,
--   delegating all authorization and deletion logic to admin_hard_delete_account_internal.
--
-- Behavior:
--   - Executes as SECURITY INVOKER, preserving the caller’s authentication
--     and permission context.
--   - Forwards the account ID directly to the internal hard delete function.
--   - Relies entirely on the internal function for administrator checks,
--     soft-delete verification, and irreversible data removal.
--
-- Parameters:
--   p_account_id UUID - The ID of the account to be permanently deleted.
--
-- Returns:
--   BOOLEAN - TRUE if the account and all related data were successfully deleted.
--
-- Notes:
--   - Designed as a thin wrapper to clearly separate invoker-level access
--     from definer-level destructive operations.
--   - Intended strictly for administrative workflows due to the irreversible
--     nature of hard deletes.
--   - Completes the account lifecycle by providing controlled access to
--     permanent data removal.
-- =========================================
CREATE OR REPLACE FUNCTION public.admin_hard_delete_account(
    p_account_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_success BOOLEAN;
BEGIN
    IF p_account_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', NULL,
            'message', 'Account ID is required'
        );
    END IF;

    -- Call internal function
    v_success := finance.admin_hard_delete_account_internal(p_account_id);

    IF v_success THEN
        RETURN jsonb_build_object(
            'success', true,
            'account_id', p_account_id,
            'message', 'Account hard-deleted successfully by admin'
        );
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'account_id', p_account_id,
            'message', 'Account could not be hard-deleted by admin'
        );
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'account_id', p_account_id,
            'message', 'Failed to hard-delete account'
        );
END;
$$;

-- =========================================
-- 13. Function: get_all_accounts_internal
-- =========================================
-- Purpose:
--   Retrieves a unified list of all active accounts belonging to the
--   authenticated user, normalizing balances and statuses across
--   different account types.
--
-- Behavior:
--   - Executes as SECURITY DEFINER to reliably access account and
--     specialized account tables under Row-Level Security (RLS).
--   - Filters out soft-deleted accounts and specialized records.
--   - Resolves account balance and status dynamically based on account type.
--   - Returns one row per account with a consistent schema.
--
-- Parameters:
--   None.
--
-- Returns:
--   TABLE (
--     account_id   UUID        - Unique identifier of the account.
--     account_name VARCHAR     - Display name of the account.
--     account_type finance.account_type- Type of the account (cash, bank, loan, etc.).
--     currency     VARCHAR     - Account currency code.
--     balance      DECIMAL     - Computed current balance or value for the account.
--     status       VARCHAR     - Current operational status of the account.
--   )
--
-- Notes:
--   - Uses LEFT JOINs to safely include accounts even if specialized
--     records are partially missing.
--   - Balance and status fields are derived from the appropriate
--     specialized table based on account type.
--   - Designed for account listing views, dashboards, and summaries.
--   - Marked STABLE as it performs read-only operations and does not
--     modify database state.
-- =========================================
CREATE OR REPLACE FUNCTION finance.get_all_accounts_internal()
RETURNS TABLE(
    account_id UUID,
    account_name VARCHAR,
    account_type finance.account_type,
    currency VARCHAR,
    balance DECIMAL,
    status VARCHAR
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
STABLE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
BEGIN
    -- Enable Row-Level Security
    PERFORM set_config('row_security', 'on', true);
    
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    RETURN QUERY
    SELECT 
        a.id as account_id,
        a.account_name,
        a.type as account_type,
        a.currency,
        CASE a.type
            WHEN 'cash' THEN COALESCE(ca.balance, 0)
            WHEN 'bank' THEN COALESCE(ba.balance, 0)
            WHEN 'credit_card' THEN COALESCE(cca.current_balance, 0)
            WHEN 'loan' THEN COALESCE(la.outstanding_amount, 0)
            WHEN 'investment' THEN COALESCE(ia.portfolio_value, 0)
            WHEN 'crypto' THEN COALESCE(cra.balance, 0)
            WHEN 'wallet' THEN COALESCE(wa.balance, 0)
            WHEN 'receivable' THEN COALESCE(ra.amount_due, 0)
            ELSE 0
        END as balance,
        CASE a.type
            WHEN 'cash' THEN COALESCE(ca.status, 'unknown')
            WHEN 'bank' THEN COALESCE(ba.status, 'unknown')
            WHEN 'credit_card' THEN COALESCE(cca.status, 'unknown')
            WHEN 'loan' THEN COALESCE(la.status, 'unknown')
            WHEN 'investment' THEN COALESCE(ia.status, 'unknown')
            WHEN 'crypto' THEN COALESCE(cra.status, 'unknown')
            WHEN 'wallet' THEN COALESCE(wa.status, 'unknown')
            WHEN 'receivable' THEN COALESCE(ra.status, 'unknown')
            ELSE 'unknown'
        END as status
    FROM finance.accounts a
    LEFT JOIN finance.cash_accounts ca ON a.id = ca.account_id AND ca.deleted_at IS NULL
    LEFT JOIN finance.bank_accounts ba ON a.id = ba.account_id AND ba.deleted_at IS NULL
    LEFT JOIN finance.credit_card_accounts cca ON a.id = cca.account_id AND cca.deleted_at IS NULL
    LEFT JOIN finance.loan_accounts la ON a.id = la.account_id AND la.deleted_at IS NULL
    LEFT JOIN finance.investment_accounts ia ON a.id = ia.account_id AND ia.deleted_at IS NULL
    LEFT JOIN finance.crypto_accounts cra ON a.id = cra.account_id AND cra.deleted_at IS NULL
    LEFT JOIN finance.wallet_accounts wa ON a.id = wa.account_id AND wa.deleted_at IS NULL
    LEFT JOIN finance.receivable_accounts ra ON a.id = ra.account_id AND ra.deleted_at IS NULL
    WHERE a.deleted_at IS NULL
      AND a.user_id = v_user_id
    ORDER BY a.account_name;
END;
$$;

-- =========================================
-- 14. Function: get_account_details_internal
-- =========================================
-- Purpose:
--   Retrieves the complete details of a single account, combining
--   base account metadata with type-specific fields into a unified
--   JSONB response.
--
-- Behavior:
--   - Executes as SECURITY DEFINER to ensure reliable access under RLS.
--   - Enforces account ownership by matching the account’s user_id
--     with the authenticated user (auth.uid()).
--   - Validates the account type against the account_type enum
--     before casting or querying specialized tables.
--   - Dynamically fetches and merges specialized account fields
--     based on the account’s type.
--
-- Parameters:
--   p_account_id UUID - The ID of the account to retrieve.
--
-- Returns:
--   JSONB - A merged JSON object containing:
--     - Base account fields (id, user_id, account_name, type, currency,
--       created_at, updated_at).
--     - Type-specific fields from the corresponding specialized
--       account table.
--
-- Notes:
--   - Raises an exception if the account does not exist, is soft-deleted,
--     or does not belong to the authenticated user.
--   - Removes the internal account_id field from specialized records
--     before merging into the response.
--   - Designed for account detail views, edit forms, and API responses
--     requiring a normalized yet flexible JSON structure.
--   - Marked STABLE as it performs read-only operations and does not
--     modify database state.
-- =========================================
CREATE OR REPLACE FUNCTION finance.get_account_details_internal(p_account_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
STABLE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_account_type finance.account_type;
    v_base JSONB;
    v_details JSONB;
    v_type_text TEXT;
BEGIN
    -- Enable Row-Level Security
    PERFORM set_config('row_security', 'on', true);

    -- Validate ownership
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Get base account info (ownership enforced here)
    SELECT jsonb_build_object(
        'id', a.id,
        'user_id', a.user_id,
        'account_name', a.account_name,
        'type', a.type,
        'currency', a.currency,
        'created_at', a.created_at,
        'updated_at', a.updated_at
    )
    INTO v_base
    FROM finance.accounts a
    WHERE a.id = p_account_id
      AND a.deleted_at IS NULL
      AND a.user_id = v_user_id;  -- enforce ownership

    IF v_base IS NULL THEN
        RAISE EXCEPTION 'Account not found or access denied';
    END IF;

    -- Validate and cast account type safely
    v_type_text := v_base->>'type';
    IF NOT EXISTS (
        SELECT 1
        FROM unnest(enum_range(NULL::finance.account_type)) AS t(val)
        WHERE t.val::TEXT = v_type_text
    ) THEN
        RAISE EXCEPTION 'Invalid account type: %', v_type_text;
    END IF;

    v_account_type := v_type_text::finance.account_type;

    -- Fetch specialized fields based on type
    CASE v_account_type
        WHEN 'cash' THEN
            SELECT to_jsonb(ca) - 'account_id'
            INTO v_details
            FROM finance.cash_accounts ca
            WHERE ca.account_id = p_account_id AND ca.deleted_at IS NULL;

        WHEN 'bank' THEN
            SELECT to_jsonb(ba) - 'account_id'
            INTO v_details
            FROM finance.bank_accounts ba
            WHERE ba.account_id = p_account_id AND ba.deleted_at IS NULL;

        WHEN 'credit_card' THEN
            SELECT to_jsonb(cc) - 'account_id'
            INTO v_details
            FROM finance.credit_card_accounts cc
            WHERE cc.account_id = p_account_id AND cc.deleted_at IS NULL;

        WHEN 'loan' THEN
            SELECT to_jsonb(la) - 'account_id'
            INTO v_details
            FROM finance.loan_accounts la
            WHERE la.account_id = p_account_id AND la.deleted_at IS NULL;

        WHEN 'investment' THEN
            SELECT to_jsonb(ia) - 'account_id'
            INTO v_details
            FROM finance.investment_accounts ia
            WHERE ia.account_id = p_account_id AND ia.deleted_at IS NULL;

        WHEN 'crypto' THEN
            SELECT to_jsonb(cra) - 'account_id'
            INTO v_details
            FROM finance.crypto_accounts cra
            WHERE cra.account_id = p_account_id AND cra.deleted_at IS NULL;

        WHEN 'wallet' THEN
            SELECT to_jsonb(wa) - 'account_id'
            INTO v_details
            FROM finance.wallet_accounts wa
            WHERE wa.account_id = p_account_id AND wa.deleted_at IS NULL;

        WHEN 'receivable' THEN
            SELECT to_jsonb(ra) - 'account_id'
            INTO v_details
            FROM finance.receivable_accounts ra
            WHERE ra.account_id = p_account_id AND ra.deleted_at IS NULL;

        ELSE
            RAISE EXCEPTION 'Unknown account type: %', v_account_type;
    END CASE;

    RETURN v_base || COALESCE(v_details, '{}'::jsonb);
END;
$$;

-- =========================================
-- 15. Function: get_accounts_by_type_internal
-- =========================================
-- Purpose:
--   Retrieves all non-deleted accounts of a specified account type
--   for the authenticated user, returning a unified JSONB array
--   that merges base account data with type-specific fields.
--
-- Behavior:
--   - Executes as SECURITY DEFINER to ensure consistent access under RLS.
--   - Enforces user ownership by filtering on auth.uid().
--   - Returns only accounts that are not soft-deleted.
--   - Dynamically joins the appropriate specialized account table
--     based on the provided account_type.
--   - Safely removes internal account_id fields from specialized
--     records before merging into the result.
--
-- Parameters:
--   p_account_type finance.account_type - The account type to filter by
--     (e.g. cash, bank, credit_card, loan, investment, crypto,
--      wallet, receivable).
--
-- Returns:
--   JSONB - An array of JSON objects, where each object contains:
--     - Base account fields from the accounts table.
--     - Type-specific fields from the corresponding specialized table.
--   Returns an empty JSON array if no matching accounts exist.
--
-- Notes:
--   - Raises an exception if an unsupported or unknown account_type
--     is provided.
--   - Designed for list views, dashboards, and filtered account
--     selectors in client applications.
--   - Marked STABLE as it performs read-only queries without
--     modifying database state.
-- =========================================
CREATE OR REPLACE FUNCTION finance.get_accounts_by_type_internal(p_account_type finance.account_type)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
STABLE
AS $$
DECLARE
    v_result JSONB := '[]'::jsonb;
    v_user_id UUID := auth.uid();
BEGIN
    -- Enable Row-Level Security
    PERFORM set_config('row_security', 'on', true);

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    
    -- Cash accounts
    IF p_account_type = 'cash' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(ca) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM finance.accounts a_base
        LEFT JOIN finance.cash_accounts ca ON a_base.id = ca.account_id AND ca.deleted_at IS NULL
        WHERE a_base.type = 'cash'
          AND a_base.deleted_at IS NULL
          AND a_base.user_id = v_user_id;

    -- Bank accounts
    ELSIF p_account_type = 'bank' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(ba) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM finance.accounts a_base
        LEFT JOIN finance.bank_accounts ba ON a_base.id = ba.account_id AND ba.deleted_at IS NULL
        WHERE a_base.type = 'bank'
          AND a_base.deleted_at IS NULL
          AND a_base.user_id = v_user_id;

    -- Credit card accounts
    ELSIF p_account_type = 'credit_card' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(cc) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM finance.accounts a_base
        LEFT JOIN finance.credit_card_accounts cc ON a_base.id = cc.account_id AND cc.deleted_at IS NULL
        WHERE a_base.type = 'credit_card'
          AND a_base.deleted_at IS NULL
          AND a_base.user_id = v_user_id;

    -- Loan accounts
    ELSIF p_account_type = 'loan' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(la) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM finance.accounts a_base
        LEFT JOIN finance.loan_accounts la ON a_base.id = la.account_id AND la.deleted_at IS NULL
        WHERE a_base.type = 'loan'
          AND a_base.deleted_at IS NULL
          AND a_base.user_id = v_user_id;

    -- Investment accounts
    ELSIF p_account_type = 'investment' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(ia) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM finance.accounts a_base
        LEFT JOIN finance.investment_accounts ia ON a_base.id = ia.account_id AND ia.deleted_at IS NULL
        WHERE a_base.type = 'investment'
          AND a_base.deleted_at IS NULL
          AND a_base.user_id = v_user_id;

    -- Crypto accounts
    ELSIF p_account_type = 'crypto' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(cra) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM finance.accounts a_base
        LEFT JOIN finance.crypto_accounts cra ON a_base.id = cra.account_id AND cra.deleted_at IS NULL
        WHERE a_base.type = 'crypto'
          AND a_base.deleted_at IS NULL
          AND a_base.user_id = v_user_id;

    -- Wallet accounts
    ELSIF p_account_type = 'wallet' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(wa) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM finance.accounts a_base
        LEFT JOIN finance.wallet_accounts wa ON a_base.id = wa.account_id AND wa.deleted_at IS NULL
        WHERE a_base.type = 'wallet'
          AND a_base.deleted_at IS NULL
          AND a_base.user_id = v_user_id;

    -- Receivable accounts
    ELSIF p_account_type = 'receivable' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(ra) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM finance.accounts a_base
        LEFT JOIN finance.receivable_accounts ra ON a_base.id = ra.account_id AND ra.deleted_at IS NULL
        WHERE a_base.type = 'receivable'
          AND a_base.deleted_at IS NULL
          AND a_base.user_id = v_user_id;

    ELSE
        RAISE EXCEPTION 'Unknown account type: %', p_account_type;
    END IF;

    RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 16. Function: get_all_accounts
-- =========================================
-- Purpose:
--   Provides a SECURITY INVOKER wrapper for retrieving all accounts
--   accessible to the calling user.
--
-- Behavior:
--   - Delegates execution to finance.get_all_accounts_internal().
--   - The internal function encapsulates all business logic, filtering,
--     and Row Level Security enforcement.
--
-- Parameters:
--   None.
--
-- Returns:
--   TABLE(
--     account_id   UUID,
--     account_name VARCHAR,
--     account_type finance.account_type,
--     currency     VARCHAR,
--     balance      DECIMAL,
--     status       VARCHAR
--   )
--
-- Notes:
--   - SECURITY INVOKER ensures the query executes with the caller’s
--     privileges and active RLS policies.
--   - Acts as a stable, public-facing API function.
--   - All authorization, visibility rules, and data shaping are handled
--     inside the internal function.
-- =========================================
CREATE OR REPLACE FUNCTION public.get_all_accounts()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, finance
STABLE
AS $$
DECLARE
    v_accounts JSONB;
BEGIN
    -- Fetch all accounts via internal function
    BEGIN
        v_accounts := to_jsonb(finance.get_all_accounts_internal());
        RETURN jsonb_build_object(
            'success', true,
            'accounts', v_accounts,
            'message', 'Fetched all accounts successfully'
        );
    EXCEPTION
        WHEN OTHERS THEN
            RETURN jsonb_build_object(
                'success', false,
                'accounts', '[]'::jsonb,
                'message', 'Failed to fetch accounts'
            );
    END;
END;
$$;

-- =========================================
-- 17. Function: get_account_details
-- =========================================
-- Purpose:
--   Provides a SECURITY INVOKER wrapper for retrieving detailed
--   information about a single account.
--
-- Behavior:
--   - Calls finance.get_account_details_internal() with the provided
--     account identifier.
--   - The internal function performs all access validation and data
--     aggregation.
--
-- Parameters:
--   p_account_id UUID
--     The unique identifier of the account to retrieve.
--
-- Returns:
--   JSONB
--     A JSON representation of the account details as defined by the
--     internal function.
--
-- Notes:
--   - SECURITY INVOKER ensures caller context and RLS are respected.
--   - Designed as a safe, public-facing read API.
--   - All permission checks and error handling are implemented in the
--     internal function.
-- =========================================
CREATE OR REPLACE FUNCTION public.get_account_details(p_account_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, finance
STABLE
AS $$
DECLARE
    v_account JSONB;
BEGIN
    BEGIN
        v_account := finance.get_account_details_internal(p_account_id);
        RETURN jsonb_build_object(
            'success', true,
            'account', v_account,
            'message', 'Fetched account details successfully'
        );
    EXCEPTION
        WHEN OTHERS THEN
            RETURN jsonb_build_object(
                'success', false,
                'account', '{}'::jsonb,
                'message', 'Failed to fetch account details'
            );
    END;
END;
$$;

-- =========================================
-- 18. Function: get_accounts_by_type
-- =========================================
-- Purpose:
--   Provides a SECURITY INVOKER wrapper for retrieving accounts filtered
--   by account type.
--
-- Behavior:
--   - Delegates execution to finance.get_accounts_by_type_internal().
--   - Filtering, authorization, and visibility rules are enforced
--     internally.
--
-- Parameters:
--   p_account_type finance.account_type
--     The account type used to filter results.
--
-- Returns:
--   JSONB
--     A JSON array or object containing accounts of the specified type,
--     as produced by the internal function.
--
-- Notes:
--   - SECURITY INVOKER ensures execution under the caller’s privileges.
--   - Serves as a controlled, public-facing query interface.
--   - Business rules and RLS logic are fully encapsulated within the
--     internal function.
-- =========================================
CREATE OR REPLACE FUNCTION public.get_accounts_by_type(p_account_type finance.account_type)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, finance
STABLE
AS $$
DECLARE
    v_accounts JSONB;
BEGIN
    BEGIN
        v_accounts := finance.get_accounts_by_type_internal(p_account_type);
        RETURN jsonb_build_object(
            'success', true,
            'accounts', v_accounts,
            'message', 'Fetched accounts successfully'
        );
    EXCEPTION
        WHEN OTHERS THEN
            RETURN jsonb_build_object(
                'success', false,
                'accounts', '[]'::jsonb,
                'message', 'Failed to fetch accounts by type'
            );
    END;
END;
$$;


-- ================================
-- Grant Permissions
-- ================================
GRANT EXECUTE ON FUNCTION public.create_account(UUID, text, finance.account_type, text, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_account(UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.soft_delete_account(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_soft_delete_account(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_hard_delete_account(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_all_accounts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_account_details(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_accounts_by_type(finance.account_type) TO authenticated;


-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION finance.get_account_details_internal(UUID) IS
'RLS-compliant function to return full account details as JSON, including base and specialized fields, excluding soft-deleted records';
COMMENT ON FUNCTION finance.validate_account_ownership_internal(UUID) IS 'Validate user owns specified account';
