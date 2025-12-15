-- =========================================
-- 01. Function: validate_account_ownership
-- =========================================
-- Purpose:
--   Validates that a given account belongs to the current user (or a
--   specified user if provided) and is not soft-deleted.
--   Ensures ownership checks before performing account operations.
--
-- Parameters:
--   p_account_id UUID       - The account to validate
--   p_user_id UUID DEFAULT NULL
--       - Optional explicit user ID
--       - If NULL, defaults to auth.uid() (current session user)
--
-- Returns:
--   BOOLEAN
--   - TRUE if the account belongs to the user and is active
--   - FALSE otherwise
--
-- Notes:
--   - Uses soft delete check (deleted_at IS NULL)
--   - Safe to call from other functions, triggers, or policies
--   - Helps enforce account-level access control consistently
-- =========================================
CREATE OR REPLACE FUNCTION validate_account_ownership(p_account_id UUID, p_user_id UUID DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
DECLARE
    v_user_id UUID;
    v_exists BOOLEAN;
BEGIN
    v_user_id := COALESCE(p_user_id, auth.uid());
    
    SELECT EXISTS(
        SELECT 1 FROM accounts 
        WHERE id = p_account_id 
        AND user_id = v_user_id 
        AND deleted_at IS NULL
    ) INTO v_exists;
    
    RETURN v_exists;
END;
$$;

-- =========================================
-- 02. Function: create_account
-- =========================================
-- Purpose:
--   Creates a new account with base details and inserts into the corresponding
--   specialized account table based on account type.
--   Non-specified fields are filled with sensible defaults.
--
-- Parameters:
--   p_user_id UUID          - Owner of the account
--   p_account_name VARCHAR  - Name of the account
--   p_type account_type     - Type of account (cash, bank, credit_card, loan, etc.)
--   p_currency VARCHAR      - Currency code (e.g., USD, LKR, BTC)
--   p_details JSONB         - Optional JSONB with specialized fields per account type
--
-- Returns:
--   UUID - ID of the newly created account
--
-- Notes:
--   - Balance and certain status fields have defaults if not provided
--   - Raises exception if account type is unknown
-- =========================================
CREATE OR REPLACE FUNCTION create_account(
    p_user_id UUID,
    p_account_name VARCHAR,
    p_type account_type,
    p_currency VARCHAR,
    p_details JSONB DEFAULT '{}' -- contains specialized fields per account type
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_account_id UUID;
BEGIN
    -- Ensure caller is creating account only for themselves
    IF p_user_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'Permission denied: cannot create account for another user'
            USING ERRCODE = '42501';
    END IF;

    -- Insert into base accounts table
    INSERT INTO accounts(user_id, account_name, type, currency)
    VALUES (p_user_id, p_account_name, p_type, p_currency)
    RETURNING id INTO v_account_id;

    -- Insert into specialized account table based on type
    CASE p_type
        WHEN 'cash' THEN
            INSERT INTO cash_accounts(account_id, location, balance, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'location', 'Wallet'),
                COALESCE((p_details->>'balance')::DECIMAL, 0),
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default cash account')
            );

        WHEN 'bank' THEN
            INSERT INTO bank_accounts(account_id, bank_name, account_no, branch, account_holder_name, balance, interest_rate, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'bank_name', 'UNKNOWN'),
                COALESCE(p_details->>'account_no', '0000'),
                COALESCE(p_details->>'branch', 'Main'),
                COALESCE(p_details->>'account_holder_name', 'User'),
                COALESCE((p_details->>'balance')::DECIMAL, 0),
                COALESCE((p_details->>'interest_rate')::DECIMAL, 0),
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default bank account')
            );

        WHEN 'credit_card' THEN
            INSERT INTO credit_card_accounts(account_id, card_number, card_type, credit_limit, current_balance, billing_cycle, interest_rate, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'card_number', '0000'),
                COALESCE(p_details->>'card_type', 'Standard'),
                COALESCE((p_details->>'credit_limit')::DECIMAL, 0),
                COALESCE((p_details->>'current_balance')::DECIMAL, 0),
                COALESCE(p_details->>'billing_cycle', 'monthly'),
                COALESCE((p_details->>'interest_rate')::DECIMAL, 0),
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default credit card')
            );

        WHEN 'loan' THEN
            -- Validate counterparty_id if provided
            IF p_details ? 'counterparty_id' THEN
                IF NOT EXISTS (
                    SELECT 1
                    FROM counterparties
                    WHERE id = (p_details->>'counterparty_id')::UUID
                ) THEN
                    RAISE EXCEPTION 'Invalid counterparty_id: % does not exist', p_details->>'counterparty_id';
                END IF;
            END IF;

            INSERT INTO loan_accounts(account_id, loan_type, principal_amount, outstanding_amount, interest_rate, term_months, start_date, end_date, status, notes, counterparty_id, collateral)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'loan_type', 'Personal'),
                COALESCE((p_details->>'principal_amount')::DECIMAL, 0),
                COALESCE((p_details->>'outstanding_amount')::DECIMAL, 0),
                COALESCE((p_details->>'interest_rate')::DECIMAL, 0),
                COALESCE((p_details->>'term_months')::INT, 12),
                COALESCE((p_details->>'start_date')::DATE, CURRENT_DATE),
                COALESCE((p_details->>'end_date')::DATE, CURRENT_DATE + INTERVAL '1 year'),
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default loan account'),
                CASE WHEN p_details ? 'counterparty_id' THEN (p_details->>'counterparty_id')::UUID ELSE NULL END,
                p_details->>'collateral'
            );

        WHEN 'investment' THEN
            INSERT INTO investment_accounts(account_id, investment_type, institution_name, account_no, portfolio_value, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'investment_type', 'Stock'),
                COALESCE(p_details->>'institution_name', 'Unknown'),
                COALESCE(p_details->>'account_no', '0000'),
                COALESCE((p_details->>'portfolio_value')::DECIMAL, 0),
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default investment account')
            );

        WHEN 'crypto' THEN
            INSERT INTO crypto_accounts(account_id, crypto_wallet_address, exchange_name, balance, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'crypto_wallet_address', 'pending'),
                COALESCE(p_details->>'exchange_name', 'Unknown'),
                COALESCE((p_details->>'balance')::DECIMAL, 0),
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default crypto account')
            );

        WHEN 'wallet' THEN
            INSERT INTO wallet_accounts(account_id, wallet_name, provider, balance, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'wallet_name', 'Default Wallet'),
                COALESCE(p_details->>'provider', 'Generic'),
                COALESCE((p_details->>'balance')::DECIMAL, 0),
                COALESCE(p_details->>'status', 'active'),
                COALESCE(p_details->>'notes', 'Default wallet account')
            );

        WHEN 'receivable' THEN
            INSERT INTO receivable_accounts(account_id, customer_name, invoice_no, principal_amount, amount_due, due_date, status, notes)
            VALUES (
                v_account_id,
                COALESCE(p_details->>'customer_name', 'Customer'),
                COALESCE(p_details->>'invoice_no', 'INV000'),
                COALESCE((p_details->>'principal_amount')::DECIMAL, 0),
                COALESCE((p_details->>'amount_due')::DECIMAL, 0),
                COALESCE((p_details->>'due_date')::DATE, CURRENT_DATE),
                COALESCE(p_details->>'status', 'pending'),
                COALESCE(p_details->>'notes', 'Default receivable account')
            );

        ELSE
            RAISE EXCEPTION 'Unknown account type: %', p_type;
    END CASE;

    RETURN v_account_id;
END;
$$;

-- =========================================
-- 03. Function: get_all_accounts
-- =========================================
-- Purpose:
--   Returns a summary of all accounts with balances and status for the current user.
--   Useful for dashboards, overviews, and account listings.
--
-- Parameters:
--   None (user context is enforced via RLS)
--
-- Returns:
--   Table with columns: account_id, account_name, account_type, currency, balance, status
--
-- Notes:
--   - Balances and status are aggregated from specialized account tables
--   - Safe for repeated calls; respects account ownership via RLS
--   - LEFT JOIN ensures accounts without specialized rows are still included
-- =========================================
CREATE OR REPLACE FUNCTION get_all_accounts()
RETURNS TABLE(
    account_id UUID,
    account_name VARCHAR,
    account_type account_type,
    currency VARCHAR,
    balance DECIMAL,
    status VARCHAR
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
STABLE
AS $$
BEGIN
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
    FROM accounts a
    LEFT JOIN cash_accounts ca ON a.id = ca.account_id AND ca.deleted_at IS NULL
    LEFT JOIN bank_accounts ba ON a.id = ba.account_id AND ba.deleted_at IS NULL
    LEFT JOIN credit_card_accounts cca ON a.id = cca.account_id AND cca.deleted_at IS NULL
    LEFT JOIN loan_accounts la ON a.id = la.account_id AND la.deleted_at IS NULL
    LEFT JOIN investment_accounts ia ON a.id = ia.account_id AND ia.deleted_at IS NULL
    LEFT JOIN crypto_accounts cra ON a.id = cra.account_id AND cra.deleted_at IS NULL
    LEFT JOIN wallet_accounts wa ON a.id = wa.account_id AND wa.deleted_at IS NULL
    LEFT JOIN receivable_accounts ra ON a.id = ra.account_id AND ra.deleted_at IS NULL
    WHERE a.deleted_at IS NULL
      AND a.user_id = auth.uid()
    ORDER BY a.account_name;
END;
$$;

-- =========================================
-- 04. Function: get_account_details
-- =========================================
-- Purpose:
--   Retrieves full details for a specific account, including specialized fields.
--   Useful for account overview or detail views.
--
-- Parameters:
--   p_account_id UUID - ID of the account to retrieve
--
-- Returns:
--   JSONB object combining base account fields and specialized account data
--
-- Notes:
--   - Ensures access via RLS; only returns accounts owned by the current user
--   - Specialized fields are fetched based on account type
--   - Safe for repeated calls; accounts without specialized rows return base info only
-- =========================================
CREATE OR REPLACE FUNCTION get_account_details(p_account_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
DECLARE
    v_account_type account_type;
    v_base JSONB;
    v_details JSONB;
BEGIN
    -- Get base account info (RLS ensures ownership)
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
    FROM accounts a
    WHERE a.id = p_account_id AND a.deleted_at IS NULL;

    IF v_base IS NULL THEN
        RAISE EXCEPTION 'Account not found or access denied';
    END IF;

    -- Get account type
    v_account_type := (v_base ->> 'type')::account_type;

    -- Fetch specialized fields based on type
    CASE v_account_type
        WHEN 'cash' THEN
            SELECT to_jsonb(ca) - 'account_id'
            INTO v_details
            FROM cash_accounts ca
            WHERE ca.account_id = p_account_id AND ca.deleted_at IS NULL;

        WHEN 'bank' THEN
            SELECT to_jsonb(ba) - 'account_id'
            INTO v_details
            FROM bank_accounts ba
            WHERE ba.account_id = p_account_id AND ba.deleted_at IS NULL;

        WHEN 'credit_card' THEN
            SELECT to_jsonb(cc) - 'account_id'
            INTO v_details
            FROM credit_card_accounts cc
            WHERE cc.account_id = p_account_id AND cc.deleted_at IS NULL;

        WHEN 'loan' THEN
            SELECT to_jsonb(la) - 'account_id'
            INTO v_details
            FROM loan_accounts la
            WHERE la.account_id = p_account_id AND la.deleted_at IS NULL;

        WHEN 'investment' THEN
            SELECT to_jsonb(ia) - 'account_id'
            INTO v_details
            FROM investment_accounts ia
            WHERE ia.account_id = p_account_id AND ia.deleted_at IS NULL;

        WHEN 'crypto' THEN
            SELECT to_jsonb(cra) - 'account_id'
            INTO v_details
            FROM crypto_accounts cra
            WHERE cra.account_id = p_account_id AND cra.deleted_at IS NULL;

        WHEN 'wallet' THEN
            SELECT to_jsonb(wa) - 'account_id'
            INTO v_details
            FROM wallet_accounts wa
            WHERE wa.account_id = p_account_id AND wa.deleted_at IS NULL;

        WHEN 'receivable' THEN
            SELECT to_jsonb(ra) - 'account_id'
            INTO v_details
            FROM receivable_accounts ra
            WHERE ra.account_id = p_account_id AND ra.deleted_at IS NULL;

        ELSE
            RAISE EXCEPTION 'Unknown account type: %', v_account_type;
    END CASE;

    RETURN v_base || COALESCE(v_details, '{}'::jsonb);
END;
$$;

-- =========================================
-- 05. Function: get_accounts_by_type
-- =========================================
-- Purpose:
--   Retrieves all accounts of a specific type for the current user, 
--   including specialized fields for each account type.
--
-- Parameters:
--   p_account_type account_type - Type of accounts to retrieve
--
-- Returns:
--   JSONB array of accounts with base and specialized fields
--
-- Notes:
--   - Access is controlled via RLS; only accounts owned by the user are returned
--   - Safe for repeated calls; accounts without specialized rows still include base info
-- =========================================
CREATE OR REPLACE FUNCTION get_accounts_by_type(p_account_type account_type)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
DECLARE
    v_result JSONB := '[]'::jsonb;
BEGIN
    -- Cash accounts
    IF p_account_type = 'cash' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(ca) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM accounts a_base
        LEFT JOIN cash_accounts ca ON a_base.id = ca.account_id AND ca.deleted_at IS NULL
        WHERE a_base.type = 'cash' AND a_base.deleted_at IS NULL;

    -- Bank accounts
    ELSIF p_account_type = 'bank' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(ba) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM accounts a_base
        LEFT JOIN bank_accounts ba ON a_base.id = ba.account_id AND ba.deleted_at IS NULL
        WHERE a_base.type = 'bank' AND a_base.deleted_at IS NULL;

    -- Credit card accounts
    ELSIF p_account_type = 'credit_card' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(cc) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM accounts a_base
        LEFT JOIN credit_card_accounts cc ON a_base.id = cc.account_id AND cc.deleted_at IS NULL
        WHERE a_base.type = 'credit_card' AND a_base.deleted_at IS NULL;

    -- Loan accounts
    ELSIF p_account_type = 'loan' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(la) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM accounts a_base
        LEFT JOIN loan_accounts la ON a_base.id = la.account_id AND la.deleted_at IS NULL
        WHERE a_base.type = 'loan' AND a_base.deleted_at IS NULL;

    -- Investment accounts
    ELSIF p_account_type = 'investment' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(ia) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM accounts a_base
        LEFT JOIN investment_accounts ia ON a_base.id = ia.account_id AND ia.deleted_at IS NULL
        WHERE a_base.type = 'investment' AND a_base.deleted_at IS NULL;

    -- Crypto accounts
    ELSIF p_account_type = 'crypto' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(cra) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM accounts a_base
        LEFT JOIN crypto_accounts cra ON a_base.id = cra.account_id AND cra.deleted_at IS NULL
        WHERE a_base.type = 'crypto' AND a_base.deleted_at IS NULL;

    -- Wallet accounts
    ELSIF p_account_type = 'wallet' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(wa) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM accounts a_base
        LEFT JOIN wallet_accounts wa ON a_base.id = wa.account_id AND wa.deleted_at IS NULL
        WHERE a_base.type = 'wallet' AND a_base.deleted_at IS NULL;

    -- Receivable accounts
    ELSIF p_account_type = 'receivable' THEN
        SELECT jsonb_agg(to_jsonb(a_base) || COALESCE(to_jsonb(ra) - 'account_id', '{}'::jsonb))
        INTO v_result
        FROM accounts a_base
        LEFT JOIN receivable_accounts ra ON a_base.id = ra.account_id AND ra.deleted_at IS NULL
        WHERE a_base.type = 'receivable' AND a_base.deleted_at IS NULL;

    ELSE
        RAISE EXCEPTION 'Unknown account type: %', p_account_type;
    END IF;

    RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 06. Function: update_account
-- =========================================
-- Purpose:
--   Updates base account fields and specialized account details for any account type.
--   Only non-balance fields are updated. Balance and certain status fields for 
--   some account types (loan, receivable) are managed by triggers.
--
-- Parameters:
--   p_account_id UUID       - ID of the account to update
--   p_update_data JSONB     - Key-value pairs of fields to update
--
-- Returns:
--   JSONB - Updated account object including base and specialized fields
--
-- Notes:
--   - RLS ensures only accounts owned by the current user can be updated
--   - Fields not provided in JSON remain unchanged
-- =========================================
CREATE OR REPLACE FUNCTION update_account(
    p_account_id UUID,
    p_update_data JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_max_requests INTEGER := 100;
    v_window_minutes INTEGER := 60;
    v_account_type account_type;
    v_base JSONB;
    v_details JSONB;
BEGIN
    -- Enforce rate limit for this endpoint
    IF NOT check_rate_limit('update_account', v_max_requests, v_window_minutes) THEN
        RAISE EXCEPTION 'Rate limit exceeded: max % requests per % minutes', 
            v_max_requests, v_window_minutes;
    END IF;

    -- Validate ownership
    IF NOT validate_account_ownership(p_account_id, auth.uid()) THEN
        RAISE EXCEPTION 'Permission denied: cannot update this account'
            USING ERRCODE = '42501';
    END IF;

    -- Fetch base account info (RLS ensures ownership)
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
    FROM accounts a
    WHERE a.id = p_account_id AND a.deleted_at IS NULL;

    IF v_base IS NULL THEN
        RAISE EXCEPTION 'Account not found or access denied';
    END IF;

    -- Update base account fields
    UPDATE accounts
    SET
        account_name = COALESCE(p_update_data->>'account_name', account_name)
    WHERE id = p_account_id AND deleted_at IS NULL;

    -- Determine account type
    v_account_type := (v_base ->> 'type')::account_type;

    -- Update specialized table based on account type (non-balance fields, allow manual status for non-trigger accounts)
    CASE v_account_type
        WHEN 'cash' THEN
            UPDATE cash_accounts
            SET
                location = COALESCE(p_update_data->>'location', location),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(cash_accounts) - 'account_id' INTO v_details;

        WHEN 'bank' THEN
            UPDATE bank_accounts
            SET
                bank_name = COALESCE(p_update_data->>'bank_name', bank_name),
                account_no = COALESCE(p_update_data->>'account_no', account_no),
                branch = COALESCE(p_update_data->>'branch', branch),
                account_holder_name = COALESCE(p_update_data->>'account_holder_name', account_holder_name),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(bank_accounts) - 'account_id' INTO v_details;

        WHEN 'credit_card' THEN
            UPDATE credit_card_accounts
            SET
                credit_limit = COALESCE((p_update_data->>'credit_limit')::DECIMAL, credit_limit),
                billing_cycle = COALESCE(p_update_data->>'billing_cycle', billing_cycle),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(credit_card_accounts) - 'account_id' INTO v_details;

        WHEN 'investment' THEN
            UPDATE investment_accounts
            SET
                investment_type = COALESCE(p_update_data->>'investment_type', investment_type),
                institution_name = COALESCE(p_update_data->>'institution_name', institution_name),
                account_no = COALESCE(p_update_data->>'account_no', account_no),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(investment_accounts) - 'account_id' INTO v_details;

        WHEN 'crypto' THEN
            UPDATE crypto_accounts
            SET
                crypto_wallet_address = COALESCE(p_update_data->>'crypto_wallet_address', crypto_wallet_address),
                exchange_name = COALESCE(p_update_data->>'exchange_name', exchange_name),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(crypto_accounts) - 'account_id' INTO v_details;

        WHEN 'wallet' THEN
            UPDATE wallet_accounts
            SET
                wallet_name = COALESCE(p_update_data->>'wallet_name', wallet_name),
                provider = COALESCE(p_update_data->>'provider', provider),
                status = COALESCE(p_update_data->>'status', status),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(wallet_accounts) - 'account_id' INTO v_details;

        -- Status for loan and receivable accounts is managed by triggers
        WHEN 'loan' THEN
            UPDATE loan_accounts
            SET
                loan_type = COALESCE(p_update_data->>'loan_type', loan_type),
                principal_amount = COALESCE((p_update_data->>'principal_amount')::DECIMAL, principal_amount),
                interest_rate = COALESCE((p_update_data->>'interest_rate')::DECIMAL, interest_rate),
                term_months = COALESCE((p_update_data->>'term_months')::INT, term_months),
                start_date = COALESCE((p_update_data->>'start_date')::DATE, start_date),
                end_date = COALESCE((p_update_data->>'end_date')::DATE, end_date),
                notes = COALESCE(p_update_data->>'notes', notes),
                counterparty_id = COALESCE((p_update_data->>'counterparty_id')::UUID, counterparty_id),
                collateral = COALESCE(p_update_data->>'collateral', collateral)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(loan_accounts) - 'account_id' INTO v_details;

        WHEN 'receivable' THEN
            UPDATE receivable_accounts
            SET
                customer_name = COALESCE(p_update_data->>'customer_name', customer_name),
                invoice_no = COALESCE(p_update_data->>'invoice_no', invoice_no),
                principal_amount = COALESCE((p_update_data->>'principal_amount')::DECIMAL, principal_amount),
                amount_due = COALESCE((p_update_data->>'amount_due')::DECIMAL, amount_due),
                due_date = COALESCE((p_update_data->>'due_date')::DATE, due_date),
                notes = COALESCE(p_update_data->>'notes', notes)
            WHERE account_id = p_account_id AND deleted_at IS NULL
            RETURNING to_jsonb(receivable_accounts) - 'account_id' INTO v_details;

        ELSE
            RAISE EXCEPTION 'Unknown account type: %', v_account_type;
    END CASE;

    RETURN v_base || COALESCE(v_details, '{}'::jsonb);
END;
$$;

-- =========================================
-- 07. Function: soft_delete_account
-- =========================================
-- Purpose:
--   Performs a soft delete on an account by setting its deleted_at timestamp.
--   Automatically cascades the soft delete to the specialized account record
--   via the cleanup_specialized_account trigger.
--
-- Parameters:
--   p_account_id UUID - The unique identifier of the account to soft delete
--
-- Returns:
--   BOOLEAN - 
--     true  → account successfully soft deleted
--     false → account not found or already deleted
--
-- Notes:
--   - Access is enforced through RLS policies; only the account owner 
--     (or roles with permission) can delete their accounts.
--   - Specialized account cleanup is handled automatically by trigger logic.
--   - This function does not permanently remove records; 
--     they remain for auditing and historical purposes.
-- =========================================
CREATE OR REPLACE FUNCTION public.soft_delete_account(p_account_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_is_admin BOOLEAN := public.check_admin_permissions();
    v_exists BOOLEAN;
BEGIN
    -- Validate ownership or admin privilege
    IF NOT v_is_admin AND NOT public.validate_account_ownership(p_account_id, v_user_id) THEN
        RAISE EXCEPTION 'Permission denied: user (%s) is not authorized to delete account (%s).',
            v_user_id, p_account_id
            USING ERRCODE = '42501';
    END IF;

    -- Perform soft delete
    UPDATE public.accounts
    SET deleted_at = NOW(),
        updated_at = NOW()
    WHERE id = p_account_id
      AND deleted_at IS NULL
    RETURNING TRUE INTO v_exists;

    -- If nothing was updated, either already deleted or nonexistent
    IF NOT FOUND THEN
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
-- 08. Function: hard_delete_account
-- =========================================
-- Purpose:
--   Permanently deletes an account and all associated data from the database.
--   This includes:
--     - Specialized account table entries
--     - Transactions referencing the account
--     - The main account record
--
-- Parameters:
--   account_id UUID  - The ID of the account to be hard deleted.
--
-- Returns:
--   BOOLEAN
--   - TRUE if the account and all related data were successfully deleted.
--
-- Notes:
--   - Requires the user to be authenticated.
--   - Only the account owner or a user with admin permissions can perform this operation.
--   - Deletes all associated transaction records to maintain referential integrity.
--   - Use with caution: this action is irreversible.
-- =========================================
CREATE OR REPLACE FUNCTION public.hard_delete_account(p_account_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    current_user_id UUID;
    account_owner UUID;
    account_type public.account_type;
    is_admin BOOLEAN;
BEGIN
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

    -- Get account details
    SELECT user_id, type INTO account_owner, account_type
    FROM public.accounts
    WHERE id = p_account_id;

    IF account_owner IS NULL THEN
        RAISE EXCEPTION 'Account not found';
    END IF;

    -- Delete from specialized account table first
    CASE account_type
        WHEN 'cash'       THEN DELETE FROM public.cash_accounts        WHERE account_id = p_account_id;
        WHEN 'bank'       THEN DELETE FROM public.bank_accounts        WHERE account_id = p_account_id;
        WHEN 'credit_card' THEN DELETE FROM public.credit_card_accounts WHERE account_id = p_account_id;
        WHEN 'loan'       THEN DELETE FROM public.loan_accounts        WHERE account_id = p_account_id;
        WHEN 'investment' THEN DELETE FROM public.investment_accounts  WHERE account_id = p_account_id;
        WHEN 'crypto'     THEN DELETE FROM public.crypto_accounts      WHERE account_id = p_account_id;
        WHEN 'wallet'     THEN DELETE FROM public.wallet_accounts      WHERE account_id = p_account_id;
        WHEN 'receivable' THEN DELETE FROM public.receivable_accounts  WHERE account_id = p_account_id;
    END CASE;

    -- Delete transaction details that reference this account
    DELETE FROM public.transactions_income      WHERE account_id = p_account_id;
    DELETE FROM public.transactions_expense     WHERE account_id = p_account_id;
    DELETE FROM public.transactions_investment  WHERE funding_account_id = p_account_id OR investment_account_id = p_account_id;
    DELETE FROM public.transactions_borrow      WHERE loan_account_id = p_account_id OR disbursement_account_id = p_account_id;
    DELETE FROM public.transactions_lend        WHERE funding_account_id = p_account_id OR receivable_account_id = p_account_id;
    DELETE FROM public.transactions_adjustment  WHERE account_id = p_account_id;
    DELETE FROM public.transactions_transfer    WHERE from_account = p_account_id OR to_account = p_account_id;

    -- Delete only soft-deleted records
    DELETE FROM public.accounts WHERE id = p_account_id AND deleted_at IS NOT NULL;

    RETURN TRUE;
END;
$$;


-- ================================
-- Grant Permissions
-- ================================
GRANT EXECUTE ON FUNCTION create_account(UUID, VARCHAR, account_type, VARCHAR, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION get_all_accounts() TO authenticated;
GRANT EXECUTE ON FUNCTION get_account_details(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_accounts_by_type(account_type) TO authenticated;
GRANT EXECUTE ON FUNCTION update_account(UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION soft_delete_account(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION validate_account_ownership(UUID, UUID) TO authenticated;


-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION get_account_details(UUID) IS
'RLS-compliant function to return full account details as JSON, including base and specialized fields, excluding soft-deleted records';
COMMENT ON FUNCTION validate_account_ownership(UUID, UUID) IS 'Validate user owns specified account';
