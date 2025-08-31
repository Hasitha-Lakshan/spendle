-- ================================
-- Spendle: Consolidated Functions
-- ================================
-- This file contains all client-invokable and helper functions for the Spendle application.
-- Updated to align with the new schema that uses:
-- - Normalized transaction structure with base transactions + detail tables
-- - Specialized account tables with proper balance fields
-- - Comprehensive RLS policies and triggers
-- - New recurring transaction system
-- ================================

-- =========================================
-- 01. Function: create_account
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
            INSERT INTO loan_accounts(account_id, loan_type, principal_amount, outstanding_amount, interest_rate, term_months, start_date, end_date, status, notes)
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
                COALESCE(p_details->>'notes', 'Default loan account')
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
-- 02. Function: initialize_user_defaults
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
SECURITY INVOKER
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
    v_account_type account_type;
    v_base JSONB;
    v_details JSONB;
BEGIN
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
                notes = COALESCE(p_update_data->>'notes', notes)
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


-- ================================
-- 1. Transaction Analysis Functions
-- ================================

-- Income Summary by Source and Account
-- Purpose: Aggregate income transactions for reporting/analytics
-- Parameters: user_id, date range
-- Returns: Table with account, source, and totals
-- Security: INVOKER (relies on RLS)
-- RLS: Uses auth.uid() to filter user's data only
CREATE OR REPLACE FUNCTION get_income_summary(
    p_start_date timestamptz DEFAULT NULL,
    p_end_date timestamptz DEFAULT NULL
)
RETURNS TABLE(
    account_id UUID,
    account_name VARCHAR,
    source_id UUID,
    source_name VARCHAR,
    total_amount DECIMAL
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ti.account_id,
        a.account_name,
        ti.source_id,
        COALESCE(ins.name, 'Unknown') as source_name,
        SUM(t.amount) as total_amount
    FROM transactions t
    JOIN transactions_income ti ON t.id = ti.transaction_id
    JOIN accounts a ON ti.account_id = a.id
    LEFT JOIN income_sources ins ON ti.source_id = ins.id
    WHERE t.type = 'income'
      AND t.deleted_at IS NULL
      AND ti.deleted_at IS NULL
      AND a.deleted_at IS NULL
      AND (p_start_date IS NULL OR t.created_at >= p_start_date)
      AND (p_end_date IS NULL OR t.created_at <= p_end_date)
    GROUP BY ti.account_id, a.account_name, ti.source_id, ins.name
    ORDER BY total_amount DESC;
END;
$$;

-- Expense Summary by Category and Account
-- Purpose: Aggregate expense transactions for reporting/analytics
-- Parameters: user_id (implicit via RLS), date range
-- Returns: Table with account, category, subcategory, and totals
-- Security: INVOKER (relies on RLS)
-- RLS: Uses auth.uid() to filter user's data only
CREATE OR REPLACE FUNCTION get_expense_summary(
    p_start_date timestamptz DEFAULT NULL,
    p_end_date timestamptz DEFAULT NULL
)
RETURNS TABLE(
    account_id UUID,
    account_name VARCHAR,
    category_id UUID,
    category_name VARCHAR,
    subcategory_id UUID,
    subcategory_name VARCHAR,
    total_amount DECIMAL
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        te.account_id,
        a.account_name,
        es.category_id,
        ec.name as category_name,
        te.category_id as subcategory_id,
        es.name as subcategory_name,
        SUM(t.amount) as total_amount
    FROM transactions t
    JOIN transactions_expense te ON t.id = te.transaction_id
    JOIN accounts a ON te.account_id = a.id
    LEFT JOIN expense_subcategories es ON te.category_id = es.id
    LEFT JOIN expense_categories ec ON es.category_id = ec.id
    WHERE t.type = 'expense'
      AND t.deleted_at IS NULL
      AND te.deleted_at IS NULL
      AND a.deleted_at IS NULL
      AND (p_start_date IS NULL OR t.created_at >= p_start_date)
      AND (p_end_date IS NULL OR t.created_at <= p_end_date)
    GROUP BY te.account_id, a.account_name, es.category_id, ec.name, te.category_id, es.name
    ORDER BY total_amount DESC;
END;
$$;

-- Investment Summary by Asset Type
-- Purpose: Aggregate investment transactions for portfolio analysis
-- Parameters: user_id (implicit via RLS), date range
-- Returns: Table with account, asset details, and totals
-- Security: INVOKER (relies on RLS)
-- RLS: Uses auth.uid() to filter user's data only
CREATE OR REPLACE FUNCTION get_investment_summary(
    p_start_date timestamptz DEFAULT NULL,
    p_end_date timestamptz DEFAULT NULL
)
RETURNS TABLE(
    account_id UUID,
    account_name VARCHAR,
    asset_type VARCHAR,
    asset_symbol VARCHAR,
    platform VARCHAR,
    total_amount DECIMAL,
    risk_level risk_level
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ti.account_id,
        a.account_name,
        ti.asset_type,
        ti.asset_symbol,
        ti.platform,
        SUM(t.amount) as total_amount,
        ti.risk_level
    FROM transactions t
    JOIN transactions_investment ti ON t.id = ti.transaction_id
    JOIN accounts a ON ti.account_id = a.id
    WHERE t.type = 'investment'
      AND t.deleted_at IS NULL
      AND ti.deleted_at IS NULL
      AND a.deleted_at IS NULL
      AND (p_start_date IS NULL OR t.created_at >= p_start_date)
      AND (p_end_date IS NULL OR t.created_at <= p_end_date)
    GROUP BY ti.account_id, a.account_name, ti.asset_type, ti.asset_symbol, ti.platform, ti.risk_level
    ORDER BY total_amount DESC;
END;
$$;

-- Borrowing and Lending Summary
-- Purpose: Get overview of outstanding loans and receivables
-- Parameters: user_id (implicit via RLS)
-- Returns: Table with counterparty details and amounts
-- Security: INVOKER (relies on RLS)
-- RLS: Uses auth.uid() to filter user's data only
CREATE OR REPLACE FUNCTION get_borrow_lend_summary()
RETURNS TABLE(
    transaction_type transaction_type,
    counterparty_name VARCHAR,
    counterparty_type counterparty_type,
    principal_amount DECIMAL,
    interest_rate DECIMAL,
    due_date DATE,
    collateral TEXT
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
BEGIN
    RETURN QUERY
    -- Borrow transactions
    SELECT 
        'borrow'::transaction_type,
        COALESCE(cp.name, 'Unknown') as counterparty_name,
        COALESCE(cp.type, 'other'::counterparty_type) as counterparty_type,
        t.amount as principal_amount,
        tb.interest_rate,
        tb.due_date,
        tb.collateral
    FROM transactions t
    JOIN transactions_borrow tb ON t.id = tb.transaction_id
    LEFT JOIN counterparties cp ON tb.counterparty_id = cp.id
    WHERE t.type = 'borrow'
      AND t.deleted_at IS NULL
      AND tb.deleted_at IS NULL
    
    UNION ALL
    
    -- Lend transactions
    SELECT 
        'lend'::transaction_type,
        COALESCE(cp.name, 'Unknown') as counterparty_name,
        COALESCE(cp.type, 'other'::counterparty_type) as counterparty_type,
        t.amount as principal_amount,
        tl.interest_rate,
        tl.due_date,
        tl.collateral
    FROM transactions t
    JOIN transactions_lend tl ON t.id = tl.transaction_id
    LEFT JOIN counterparties cp ON tl.counterparty_id = cp.id
    WHERE t.type = 'lend'
      AND t.deleted_at IS NULL
      AND tl.deleted_at IS NULL
    
    ORDER BY principal_amount DESC;
END;
$$;

-- ================================
-- 3. Transaction Creation Functions
-- ================================

-- Create Expense Transaction
-- Purpose: Create a new expense transaction with validation
-- Parameters: account_id, amount, currency, category_id (subcategory), payment_method, notes
-- Returns: UUID of created transaction
-- Security: INVOKER (relies on RLS and triggers for validation)
-- RLS: Account and category ownership validated by RLS, transaction created with proper user_id
CREATE OR REPLACE FUNCTION create_expense_transaction(
    p_account_id UUID,
    p_amount DECIMAL,
    p_currency VARCHAR DEFAULT 'USD',
    p_category_id UUID DEFAULT NULL,
    p_payment_method payment_method DEFAULT 'other',
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_transaction_id UUID;
    v_user_id UUID;
BEGIN
    -- Get current user (will be validated by RLS)
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    
    -- Validate amount is positive
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Expense amount must be positive';
    END IF;
    
    -- Create base transaction (triggers will validate RLS and currency matching)
    INSERT INTO transactions (user_id, type, amount, currency, notes)
    VALUES (v_user_id, 'expense', p_amount, p_currency, p_notes)
    RETURNING id INTO v_transaction_id;
    
    -- Create expense details (triggers will validate account/category ownership and apply balances)
    INSERT INTO transactions_expense (
        transaction_id,
        account_id,
        category_id,
        payment_method
    )
    VALUES (
        v_transaction_id,
        p_account_id,
        p_category_id,
        p_payment_method
    );
    
    RETURN v_transaction_id;
END;
$$;

-- Create Income Transaction
-- Purpose: Create a new income transaction with validation
-- Parameters: account_id, amount, currency, source_id, notes
-- Returns: UUID of created transaction
-- Security: INVOKER (relies on RLS and triggers for validation)
-- RLS: Account and source ownership validated by RLS, transaction created with proper user_id
CREATE OR REPLACE FUNCTION create_income_transaction(
    p_account_id UUID,
    p_amount DECIMAL,
    p_currency VARCHAR DEFAULT 'USD',
    p_source_id UUID DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_transaction_id UUID;
    v_user_id UUID;
BEGIN
    -- Get current user (will be validated by RLS)
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    
    -- Validate amount is positive
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Income amount must be positive';
    END IF;
    
    -- Create base transaction (triggers will validate RLS and currency matching)
    INSERT INTO transactions (user_id, type, amount, currency, notes)
    VALUES (v_user_id, 'income', p_amount, p_currency, p_notes)
    RETURNING id INTO v_transaction_id;
    
    -- Create income details (triggers will validate account/source ownership and apply balances)
    INSERT INTO transactions_income (
        transaction_id,
        account_id,
        source_id,
        notes
    )
    VALUES (
        v_transaction_id,
        p_account_id,
        p_source_id,
        'Income transaction'
    );
    
    RETURN v_transaction_id;
END;
$$;

-- ================================
-- 4. Transfer Functions
-- ================================

-- Atomic Transfer Between Accounts
-- Purpose: Safely transfer funds between two accounts with validation
-- Parameters: from_account, to_account, amount, currency, optional notes and fees
-- Returns: UUID of created transaction
-- Security: INVOKER (relies on RLS and triggers for validation)
-- RLS: Account ownership validated by RLS, transaction details created with proper user_id
-- NOTE: Uses new transactions_transfer table instead of dual transactions
CREATE OR REPLACE FUNCTION execute_transfer(
    p_from_account UUID,
    p_to_account UUID,
    p_amount DECIMAL,
    p_currency VARCHAR DEFAULT 'USD',
    p_transfer_method transfer_method DEFAULT 'other',
    p_fees DECIMAL DEFAULT 0,
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_transaction_id UUID;
    v_user_id UUID;
BEGIN
    -- Get current user (will be validated by RLS)
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    
    -- Validate amount is positive
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive';
    END IF;
    
    -- Validate accounts are different
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'Cannot transfer from account to itself';
    END IF;
    
    -- Create base transaction (triggers will validate RLS and currency matching)
    INSERT INTO transactions (user_id, type, amount, currency, notes)
    VALUES (v_user_id, 'transfer', p_amount, p_currency, 
            COALESCE(p_notes, 'Transfer between accounts'))
    RETURNING id INTO v_transaction_id;
    
    -- Create transfer details (triggers will validate account ownership and apply balances)
    INSERT INTO transactions_transfer (
        transaction_id, 
        from_account, 
        to_account, 
        transfer_method, 
        fees
    )
    VALUES (
        v_transaction_id,
        p_from_account,
        p_to_account,
        p_transfer_method,
        COALESCE(p_fees, 0)
    );
    
    RETURN v_transaction_id;
END;
$$;

-- ================================
-- 4. Recurring Transaction Functions
-- ================================

-- Create Recurring Transaction Schedule
-- Purpose: Set up a recurring transaction based on a template
-- Parameters: template_transaction_id, frequency details, date range
-- Returns: UUID of recurring schedule
-- Security: INVOKER (relies on RLS)
-- RLS: Template transaction ownership validated by RLS
CREATE OR REPLACE FUNCTION create_recurring_schedule(
    p_template_transaction_id UUID,
    p_frequency recurrence_frequency,
    p_interval INTEGER DEFAULT 1,
    p_start_date DATE DEFAULT CURRENT_DATE,
    p_end_date DATE DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    v_recurring_id UUID;
    v_user_id UUID;
    v_next_occurrence timestamptz;
BEGIN
    -- Get current user
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    
    -- Validate interval
    IF p_interval <= 0 THEN
        RAISE EXCEPTION 'Interval must be positive';
    END IF;
    
    -- Calculate next occurrence
    v_next_occurrence := p_start_date::timestamptz;
    
    -- Create recurring schedule (trigger will validate template exists and set action_by)
    INSERT INTO transactions_recurring (
        transaction_template_id,
        frequency,
        interval,
        start_date,
        end_date,
        next_occurrence,
        user_id
    )
    VALUES (
        p_template_transaction_id,
        p_frequency,
        p_interval,
        p_start_date,
        p_end_date,
        v_next_occurrence,
        v_user_id
    )
    RETURNING id INTO v_recurring_id;
    
    RETURN v_recurring_id;
END;
$$;

-- Process Due Recurring Transactions
-- Purpose: Execute recurring transactions that are due (client-callable wrapper)
-- Parameters: optional limit on number to process
-- Returns: TABLE with count and created transaction IDs
-- Security: INVOKER (relies on RLS and existing process_recurring_transactions trigger function)
-- RLS: Only processes recurring transactions owned by current user
CREATE OR REPLACE FUNCTION execute_due_recurring_transactions(
    p_limit INTEGER DEFAULT NULL
)
RETURNS TABLE(processed_count INTEGER, new_transaction_ids UUID[])
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
VOLATILE
AS $$
BEGIN
    -- Call the existing trigger function that handles RLS properly
    RETURN QUERY SELECT * FROM process_recurring_transactions();
END;
$$;

-- Get User's Recurring Schedules
-- Purpose: List all active recurring transaction schedules for user
-- Parameters: user_id (implicit via RLS)
-- Returns: Table with schedule details and template info
-- Security: INVOKER (relies on RLS)
-- RLS: Only returns schedules owned by current user
CREATE OR REPLACE FUNCTION get_recurring_schedules()
RETURNS TABLE(
    schedule_id UUID,
    template_transaction_id UUID,
    transaction_type transaction_type,
    amount DECIMAL,
    currency VARCHAR,
    frequency recurrence_frequency,
    recurrence_interval INTEGER,
    next_occurrence timestamptz,
    end_date DATE,
    created_at timestamptz
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        tr.id as schedule_id,
        tr.transaction_template_id,
        t.type as transaction_type,
        t.amount,
        t.currency,
        tr.frequency,
        tr.interval as recurrence_interval,
        tr.next_occurrence,
        tr.end_date,
        tr.created_at
    FROM transactions_recurring tr
    JOIN transactions t ON tr.transaction_template_id = t.id
    WHERE tr.deleted_at IS NULL
      AND t.deleted_at IS NULL
    ORDER BY tr.next_occurrence ASC;
END;
$$;

-- Get Transaction Direction
-- Purpose: Compute transaction direction based on type and amount
-- Parameters: transaction_type, amount
-- Returns: transaction_direction enum
-- Security: INVOKER (pure computation)
-- RLS: N/A (no data access)
CREATE OR REPLACE FUNCTION compute_transaction_direction(
    p_type transaction_type, 
    p_amount DECIMAL
)
RETURNS transaction_direction
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN p_type = 'income' THEN 'inflow'::transaction_direction
        WHEN p_type = 'expense' THEN 'outflow'::transaction_direction
        WHEN p_type = 'borrow' AND p_amount >= 0 THEN 'inflow'::transaction_direction
        WHEN p_type = 'borrow' AND p_amount < 0 THEN 'outflow'::transaction_direction
        WHEN p_type = 'lend' AND p_amount >= 0 THEN 'outflow'::transaction_direction
        WHEN p_type = 'lend' AND p_amount < 0 THEN 'inflow'::transaction_direction
        WHEN p_type = 'investment' AND p_amount >= 0 THEN 'outflow'::transaction_direction
        WHEN p_type = 'investment' AND p_amount < 0 THEN 'inflow'::transaction_direction
        WHEN p_type = 'adjustment' AND p_amount >= 0 THEN 'inflow'::transaction_direction
        WHEN p_type = 'adjustment' AND p_amount < 0 THEN 'outflow'::transaction_direction
        WHEN p_type = 'transfer' THEN 'neutral'::transaction_direction
        ELSE 'unknown'::transaction_direction
    END;
$$;

-- ================================
-- 6. Administrative Functions
-- ================================

-- Get User Transaction History (with pagination)
-- Purpose: Retrieve paginated transaction history for user dashboard
-- Parameters: limit, offset, date filters
-- Returns: Table with transaction details
-- Security: INVOKER (relies on RLS)
-- RLS: Only returns transactions owned by current user
CREATE OR REPLACE FUNCTION get_user_transactions(
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0,
    p_start_date timestamptz DEFAULT NULL,
    p_end_date timestamptz DEFAULT NULL,
    p_transaction_type transaction_type DEFAULT NULL
)
RETURNS TABLE(
    transaction_id UUID,
    transaction_type transaction_type,
    amount DECIMAL,
    currency VARCHAR,
    notes TEXT,
    created_at timestamptz,
    account_id UUID,
    account_name VARCHAR,
    category_info JSONB,
    direction transaction_direction
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.id as transaction_id,
        t.type as transaction_type,
        t.amount,
        t.currency,
        t.notes,
        t.created_at,
        COALESCE(
            ti.account_id, te.account_id, tinv.account_id, 
            tb.account_id, tl.account_id, ta.account_id
        ) as account_id,
        a.account_name,
        CASE 
            WHEN t.type = 'income' THEN jsonb_build_object(
                'source_id', ti.source_id,
                'source_name', ins.name
            )
            WHEN t.type = 'expense' THEN jsonb_build_object(
                'subcategory_id', te.category_id,
                'subcategory_name', es.name,
                'category_name', ec.name,
                'payment_method', te.payment_method
            )
            WHEN t.type = 'investment' THEN jsonb_build_object(
                'asset_type', tinv.asset_type,
                'asset_symbol', tinv.asset_symbol,
                'platform', tinv.platform,
                'risk_level', tinv.risk_level
            )
            ELSE NULL
        END as category_info,
        compute_transaction_direction(t.type, t.amount) as direction
    FROM transactions t
    LEFT JOIN transactions_income ti ON t.id = ti.transaction_id AND ti.deleted_at IS NULL
    LEFT JOIN transactions_expense te ON t.id = te.transaction_id AND te.deleted_at IS NULL
    LEFT JOIN transactions_investment tinv ON t.id = tinv.transaction_id AND tinv.deleted_at IS NULL
    LEFT JOIN transactions_borrow tb ON t.id = tb.transaction_id AND tb.deleted_at IS NULL
    LEFT JOIN transactions_lend tl ON t.id = tl.transaction_id AND tl.deleted_at IS NULL
    LEFT JOIN transactions_adjustment ta ON t.id = ta.transaction_id AND ta.deleted_at IS NULL
    LEFT JOIN accounts a ON COALESCE(ti.account_id, te.account_id, tinv.account_id, tb.account_id, tl.account_id, ta.account_id) = a.id
    LEFT JOIN income_sources ins ON ti.source_id = ins.id AND ins.deleted_at IS NULL
    LEFT JOIN expense_subcategories es ON te.category_id = es.id AND es.deleted_at IS NULL
    LEFT JOIN expense_categories ec ON es.category_id = ec.id AND ec.deleted_at IS NULL
    WHERE t.deleted_at IS NULL
      AND (p_start_date IS NULL OR t.created_at >= p_start_date)
      AND (p_end_date IS NULL OR t.created_at <= p_end_date)
      AND (p_transaction_type IS NULL OR t.type = p_transaction_type)
    ORDER BY t.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$;

-- =========================================
-- 7. UTILITY & MAINTENANCE FUNCTIONS
-- =========================================

-- Recalculate Account Balance
-- Purpose: Compute an account's true balance from transaction history.
-- Parameters: 
--   p_account_id (UUID) - Target account ID
-- Returns: DECIMAL(36,18) - The recalculated balance
-- Security: INVOKER (relies on RLS)
-- RLS: Only allows recalculation on accounts owned by current user
CREATE OR REPLACE FUNCTION recalculate_account_balance(p_account_id UUID)
RETURNS DECIMAL(36,18) 
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
    calculated_balance DECIMAL(36,18) := 0;
    acc_type public.account_type;
    acc_currency TEXT;
    v_current_user UUID;
BEGIN
    v_current_user := auth.uid();
    
    -- Get account info
    SELECT type, currency INTO acc_type, acc_currency 
    FROM public.accounts 
    WHERE id = p_account_id 
      AND user_id = v_current_user
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account not found or access denied';
    END IF;

    -- Calculate balance based on transaction history for specific account types
    CASE acc_type
        WHEN 'cash', 'bank', 'wallet', 'crypto' THEN
            -- For standard balance accounts: income(+), expense(-), adjustment(+/-)
            SELECT COALESCE(SUM(
                CASE 
                    WHEN t.type = 'income' THEN t.amount
                    WHEN t.type = 'expense' THEN -t.amount
                    WHEN t.type = 'adjustment' THEN t.amount
                    ELSE 0
                END), 0)
            INTO calculated_balance
            FROM public.transactions t
            LEFT JOIN public.transactions_income ti 
                   ON t.id = ti.transaction_id AND ti.account_id = p_account_id
            LEFT JOIN public.transactions_expense te 
                   ON t.id = te.transaction_id AND te.account_id = p_account_id
            LEFT JOIN public.transactions_adjustment ta 
                   ON t.id = ta.transaction_id AND ta.account_id = p_account_id
            WHERE (ti.account_id = p_account_id OR te.account_id = p_account_id OR ta.account_id = p_account_id)
              AND t.user_id = v_current_user
              AND t.deleted_at IS NULL
              AND t.currency = acc_currency;

            -- Add transfer effects
            SELECT calculated_balance + COALESCE(SUM(
                CASE 
                    WHEN tt.from_account = p_account_id THEN -(t.amount + tt.fees)
                    WHEN tt.to_account = p_account_id THEN t.amount
                    ELSE 0
                END), 0)
            INTO calculated_balance
            FROM public.transactions t
            JOIN public.transactions_transfer tt 
                 ON t.id = tt.transaction_id
            WHERE (tt.from_account = p_account_id OR tt.to_account = p_account_id)
              AND t.user_id = v_current_user
              AND t.deleted_at IS NULL;

        WHEN 'credit_card' THEN
            -- For credit cards: expense(+), payment/adjustment(-) 
            SELECT COALESCE(SUM(
                CASE 
                    WHEN t.type = 'expense' THEN t.amount
                    WHEN t.type = 'adjustment' THEN -t.amount
                    ELSE 0
                END), 0)
            INTO calculated_balance
            FROM public.transactions t
            LEFT JOIN public.transactions_expense te 
                   ON t.id = te.transaction_id AND te.account_id = p_account_id
            LEFT JOIN public.transactions_adjustment ta 
                   ON t.id = ta.transaction_id AND ta.account_id = p_account_id
            WHERE (te.account_id = p_account_id OR ta.account_id = p_account_id)
              AND t.user_id = v_current_user
              AND t.deleted_at IS NULL;

        WHEN 'loan' THEN
            -- For loans: borrow(+), repayment(-)
            SELECT COALESCE(SUM(
                CASE 
                    WHEN t.type = 'borrow' THEN t.amount
                    WHEN t.type = 'adjustment' THEN -t.amount
                    ELSE 0
                END), 0)
            INTO calculated_balance
            FROM public.transactions t
            LEFT JOIN public.transactions_borrow tb 
                   ON t.id = tb.transaction_id AND tb.account_id = p_account_id
            LEFT JOIN public.transactions_adjustment ta 
                   ON t.id = ta.transaction_id AND ta.account_id = p_account_id
            WHERE (tb.account_id = p_account_id OR ta.account_id = p_account_id)
              AND t.user_id = v_current_user
              AND t.deleted_at IS NULL;

        WHEN 'investment' THEN
            -- For investments: investment(+), income(+), adjustment(+/-)
            SELECT COALESCE(SUM(
                CASE 
                    WHEN t.type = 'investment' THEN t.amount
                    WHEN t.type = 'income' THEN t.amount
                    WHEN t.type = 'adjustment' THEN t.amount
                    ELSE 0
                END), 0)
            INTO calculated_balance
            FROM public.transactions t
            LEFT JOIN public.transactions_investment ti 
                   ON t.id = ti.transaction_id AND ti.account_id = p_account_id
            LEFT JOIN public.transactions_income tin 
                   ON t.id = tin.transaction_id AND tin.account_id = p_account_id
            LEFT JOIN public.transactions_adjustment ta 
                   ON t.id = ta.transaction_id AND ta.account_id = p_account_id
            WHERE (ti.account_id = p_account_id OR tin.account_id = p_account_id OR ta.account_id = p_account_id)
              AND t.user_id = v_current_user
              AND t.deleted_at IS NULL;

        WHEN 'receivable' THEN
            -- For receivables: lend(+), payment(-), adjustment(+/-)
            SELECT COALESCE(SUM(
                CASE 
                    WHEN t.type = 'lend' THEN t.amount
                    WHEN t.type = 'adjustment' THEN t.amount
                    ELSE 0
                END), 0)
            INTO calculated_balance
            FROM public.transactions t
            LEFT JOIN public.transactions_lend tl 
                   ON t.id = tl.transaction_id AND tl.account_id = p_account_id
            LEFT JOIN public.transactions_adjustment ta 
                   ON t.id = ta.transaction_id AND ta.account_id = p_account_id
            WHERE (tl.account_id = p_account_id OR ta.account_id = p_account_id)
              AND t.user_id = v_current_user
              AND t.deleted_at IS NULL;
    END CASE;

    RETURN calculated_balance;
END;
$$;

-- Update Account Balance Field
-- Purpose: Persist a corrected balance into the specialized account table 
--          (balance/current_balance/outstanding_amount/etc. depending on type).
-- Parameters:
--   p_account_id (UUID) - Target account ID
--   p_new_balance (DECIMAL) - Corrected balance value
-- Returns: BOOLEAN - True if updated successfully, False otherwise
-- Security: INVOKER (relies on RLS)
-- RLS: Only updates accounts owned by current user
CREATE OR REPLACE FUNCTION update_account_balance_field(
    p_account_id UUID,
    p_new_balance DECIMAL(36,18)
)
RETURNS BOOLEAN 
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
    acc_type account_type;
    updated_rows INTEGER;
    v_current_user UUID;
BEGIN
    v_current_user := auth.uid();
    
    -- Get account type
    SELECT type INTO acc_type 
    FROM accounts 
    WHERE id = p_account_id 
      AND user_id = v_current_user
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Update the appropriate balance field based on account type
    CASE acc_type
        WHEN 'cash' THEN
            UPDATE cash_accounts 
            SET balance = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'bank' THEN
            UPDATE bank_accounts 
            SET balance = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'wallet' THEN
            UPDATE wallet_accounts 
            SET balance = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'crypto' THEN
            UPDATE crypto_accounts 
            SET balance = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'credit_card' THEN
            UPDATE credit_card_accounts 
            SET current_balance = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'loan' THEN
            UPDATE loan_accounts 
            SET outstanding_amount = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'investment' THEN
            UPDATE investment_accounts 
            SET portfolio_value = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'receivable' THEN
            UPDATE receivable_accounts 
            SET amount_due = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        ELSE
            RETURN FALSE;
    END CASE;

    -- Update main account timestamp
    UPDATE accounts 
    SET updated_at = NOW() 
    WHERE id = p_account_id;

    RETURN updated_rows > 0;
END;
$$;

-- Cleanup Orphaned Specialized Accounts
-- Purpose: Mark specialized account records as deleted if their parent 
--          record in `accounts` has been removed or soft-deleted.
-- Parameters: None
-- Returns: INTEGER - Number of orphaned specialized accounts cleaned
-- Security: DEFINER (system-level cleanup task)
-- RLS: Enforces ownership by filtering against auth.uid()
CREATE OR REPLACE FUNCTION cleanup_orphaned_specialized_accounts()
RETURNS INTEGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    cleanup_count INTEGER := 0;
    total_count INTEGER := 0;
    v_current_user UUID;
BEGIN
    v_current_user := auth.uid();
    
    -- Clean up each specialized account type
    UPDATE public.cash_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (
        SELECT id FROM public.accounts 
        WHERE user_id = v_current_user 
        AND deleted_at IS NULL
    )
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE public.bank_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (
        SELECT id FROM public.accounts 
        WHERE user_id = v_current_user 
        AND deleted_at IS NULL
    )
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE public.credit_card_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (
        SELECT id FROM public.accounts 
        WHERE user_id = v_current_user 
        AND deleted_at IS NULL
    )
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE public.loan_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (
        SELECT id FROM public.accounts 
        WHERE user_id = v_current_user 
        AND deleted_at IS NULL
    )
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE public.investment_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (
        SELECT id FROM public.accounts 
        WHERE user_id = v_current_user 
        AND deleted_at IS NULL
    )
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE public.crypto_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (
        SELECT id FROM public.accounts 
        WHERE user_id = v_current_user 
        AND deleted_at IS NULL
    )
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE public.wallet_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (
        SELECT id FROM public.accounts 
        WHERE user_id = v_current_user 
        AND deleted_at IS NULL
    )
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE public.receivable_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (
        SELECT id FROM public.accounts 
        WHERE user_id = v_current_user 
        AND deleted_at IS NULL
    )
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    RETURN total_count;
END;
$$;

-- =========================================
-- 8. DATA INTEGRITY FUNCTIONS
-- =========================================

-- Check Balance Integrity
-- Purpose: Compare stored vs. recalculated balance for accounts to identify discrepancies.
-- Parameters:
--   p_account_id (UUID, optional) - Specific account to check; NULL = all
-- Returns: TABLE(account_id, account_name, account_type, current_balance, calculated_balance, difference, needs_correction)
-- Security: INVOKER (relies on RLS)
-- RLS: Only checks accounts owned by current user
CREATE OR REPLACE FUNCTION check_balance_integrity(p_account_id UUID DEFAULT NULL)
RETURNS TABLE(
    account_id UUID,
    account_name TEXT,
    account_type account_type,
    current_balance DECIMAL(36,18),
    calculated_balance DECIMAL(36,18),
    difference DECIMAL(36,18),
    needs_correction BOOLEAN
) 
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_current_user UUID;
BEGIN
    v_current_user := auth.uid();
    
    RETURN QUERY
    SELECT 
        a.id AS account_id,
        a.account_name::TEXT,
        a.type AS account_type,
        vab.current_balance,
        recalculate_account_balance(a.id) AS calculated_balance,
        (vab.current_balance - recalculate_account_balance(a.id)) AS difference,
        (ABS(vab.current_balance - recalculate_account_balance(a.id)) > 0.01) AS needs_correction
    FROM accounts a
    JOIN v_account_balances vab ON a.id = vab.account_id
    WHERE a.deleted_at IS NULL
      AND a.user_id = v_current_user
      AND (p_account_id IS NULL OR a.id = p_account_id)
    ORDER BY ABS(vab.current_balance - recalculate_account_balance(a.id)) DESC;
END;
$$;

-- Fix Balance Discrepancies
-- Purpose: Detect accounts with mismatched stored vs. recalculated balance 
--          and correct them automatically.
-- Parameters:
--   p_account_id (UUID, optional) - Specific account to fix; NULL = all
-- Returns: TABLE(account_id, old_balance, new_balance, corrected)
-- Security: INVOKER (relies on RLS)
-- RLS: Only fixes accounts owned by current user
CREATE OR REPLACE FUNCTION public.fix_balance_discrepancies(p_account_id UUID DEFAULT NULL)
RETURNS TABLE(
    account_id UUID,
    old_balance DECIMAL(36,18),
    new_balance DECIMAL(36,18),
    corrected BOOLEAN
) 
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
DECLARE
    acc_record RECORD;
BEGIN
    FOR acc_record IN
        SELECT * 
        FROM public.check_balance_integrity(p_account_id)
        WHERE needs_correction = TRUE
    LOOP
        RETURN QUERY
        SELECT 
            acc_record.account_id,
            acc_record.current_balance AS old_balance,
            acc_record.calculated_balance AS new_balance,
            public.update_account_balance_field(acc_record.account_id, acc_record.calculated_balance) AS corrected;
    END LOOP;
END;
$$;

-- Comprehensive Account Validation
CREATE OR REPLACE FUNCTION validate_account_data(
    p_account_id UUID,
    p_account_type account_type DEFAULT NULL,
    p_currency VARCHAR(10) DEFAULT NULL
)
RETURNS TABLE(
    is_valid BOOLEAN,
    validation_errors TEXT[]
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
DECLARE
    v_errors TEXT[] := '{}';
    v_account_type account_type;
    v_currency VARCHAR(10);
    v_user_id UUID;
    v_current_user UUID;
BEGIN
    v_current_user := auth.uid();
    
    -- Check if account exists and user has access
    SELECT type, currency, user_id 
    INTO v_account_type, v_currency, v_user_id
    FROM accounts 
    WHERE id = p_account_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        v_errors := array_append(v_errors, 'Account not found or access denied');
    ELSE
        -- Check ownership
        IF v_user_id != v_current_user THEN
            v_errors := array_append(v_errors, 'Account ownership validation failed');
        END IF;
        
        -- Check type consistency
        IF p_account_type IS NOT NULL AND v_account_type != p_account_type THEN
            v_errors := array_append(v_errors, 'Account type mismatch');
        END IF;
        
        -- Check currency consistency
        IF p_currency IS NOT NULL AND v_currency != p_currency THEN
            v_errors := array_append(v_errors, 'Currency mismatch');
        END IF;
        
        -- Check specialized account data exists
        CASE v_account_type
            WHEN 'cash' THEN
                IF NOT EXISTS(SELECT 1 FROM cash_accounts WHERE account_id = p_account_id AND deleted_at IS NULL) THEN
                    v_errors := array_append(v_errors, 'Cash account details missing');
                END IF;
            WHEN 'bank' THEN
                IF NOT EXISTS(SELECT 1 FROM bank_accounts WHERE account_id = p_account_id AND deleted_at IS NULL) THEN
                    v_errors := array_append(v_errors, 'Bank account details missing');
                END IF;
            -- Add other account types as needed
        END CASE;
    END IF;
    
    RETURN QUERY SELECT (array_length(v_errors, 1) IS NULL OR array_length(v_errors, 1) = 0), v_errors;
END;
$$;

-- =========================================
-- 9. REPORTING & DASHBOARD FUNCTIONS
-- =========================================

-- Get User Account Summary
-- Purpose: Provide summary stats by account type for the current user, 
--          including count and total balance grouped by type/currency.
-- Parameters: None
-- Returns: TABLE(account_type, account_count, total_balance, currency)
-- Security: DEFINER (executes with elevated rights but enforces user scope)
-- RLS: Only includes accounts owned by current user
CREATE OR REPLACE FUNCTION get_user_account_summary()
RETURNS TABLE(
    account_type account_type,
    account_count BIGINT,
    total_balance DECIMAL(36,18),
    currency VARCHAR(10)
) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current_user UUID;
BEGIN
    v_current_user := auth.uid();
    
    RETURN QUERY
    SELECT 
        a.type AS account_type,
        COUNT(*) AS account_count,
        SUM(vab.current_balance) AS total_balance,
        a.currency
    FROM accounts a
    JOIN v_account_balances vab ON a.id = vab.account_id
    WHERE a.user_id = v_current_user  -- RLS check
    AND a.deleted_at IS NULL
    GROUP BY a.type, a.currency
    ORDER BY a.type, a.currency;
END;
$$;

-- Get Recent Transactions
-- Purpose: Retrieve most recent transactions for dashboard/overview display.
-- Parameters:
--   p_limit (INTEGER, default=10) - Maximum number of transactions to return
-- Returns: TABLE(transaction_id, transaction_type, amount, currency, date, account_name, notes)
-- Security: DEFINER (executes with elevated rights but enforces user scope)
-- RLS: Only returns transactions owned by current user
CREATE OR REPLACE FUNCTION get_recent_transactions(p_limit INTEGER DEFAULT 10)
RETURNS TABLE(
    transaction_id UUID,
    transaction_type transaction_type,
    amount DECIMAL(36,18),
    currency VARCHAR(10),
    transaction_date TIMESTAMPTZ,
    account_name TEXT,
    notes TEXT
) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current_user UUID;
BEGIN
    v_current_user := auth.uid();
    
    RETURN QUERY
    SELECT 
        t.id AS transaction_id,
        t.type AS transaction_type,
        t.amount,
        t.currency,
        t.created_at AS transaction_date,
        COALESCE(
            (SELECT a.account_name FROM accounts a 
             JOIN transactions_income ti ON a.id = ti.account_id 
             WHERE ti.transaction_id = t.id AND a.user_id = v_current_user AND a.deleted_at IS NULL),
            (SELECT a.account_name FROM accounts a 
             JOIN transactions_expense te ON a.id = te.account_id 
             WHERE te.transaction_id = t.id AND a.user_id = v_current_user AND a.deleted_at IS NULL),
            (SELECT a.account_name FROM accounts a 
             JOIN transactions_investment tinv ON a.id = tinv.account_id 
             WHERE tinv.transaction_id = t.id AND a.user_id = v_current_user AND a.deleted_at IS NULL),
            (SELECT a.account_name FROM accounts a 
             JOIN transactions_adjustment tadj ON a.id = tadj.account_id 
             WHERE tadj.transaction_id = t.id AND a.user_id = v_current_user AND a.deleted_at IS NULL),
            (SELECT a.account_name FROM accounts a 
             JOIN transactions_borrow tb ON a.id = tb.account_id 
             WHERE tb.transaction_id = t.id AND a.user_id = v_current_user AND a.deleted_at IS NULL),
            (SELECT a.account_name FROM accounts a 
             JOIN transactions_lend tl ON a.id = tl.account_id 
             WHERE tl.transaction_id = t.id AND a.user_id = v_current_user AND a.deleted_at IS NULL),
            (SELECT CONCAT(af.account_name, ' → ', at.account_name) FROM 
             accounts af, accounts at, transactions_transfer tt 
             WHERE tt.transaction_id = t.id 
             AND af.id = tt.from_account AND at.id = tt.to_account 
             AND af.user_id = v_current_user AND at.user_id = v_current_user
             AND af.deleted_at IS NULL AND at.deleted_at IS NULL)
        ) AS account_name,
        t.notes
    FROM transactions t
    WHERE t.user_id = v_current_user
    AND t.deleted_at IS NULL
    ORDER BY t.created_at DESC
    LIMIT p_limit;
END;
$$;

-- =========================================
-- 10. ADMIN & SECURITY FUNCTIONS
-- =========================================

-- Check Admin Permissions
-- Purpose: Validate whether current user has admin rights in `profiles`.
-- Parameters: None
-- Returns: BOOLEAN - True if current user is admin, False otherwise
-- Security: DEFINER (checks profile data directly)
-- RLS: Applies to current user only
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
-- 11. SCHEDULED PROCESSING FUNCTIONS
-- =========================================

-- Schedule Recurring Transaction Processing
-- Purpose: Run all due recurring transactions and log audit trail.
-- Parameters: None
-- Returns: TEXT - Summary of processing results
-- Security: DEFINER (system-level job, often used with pg_cron)
-- RLS: Transactions are processed for their rightful owners
CREATE OR REPLACE FUNCTION public.schedule_recurring_processing()
RETURNS TEXT 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    result_record RECORD;
    processing_result TEXT;
BEGIN
    -- Process all due recurring transactions
    SELECT processed_count, new_transaction_ids INTO result_record 
    FROM public.process_recurring_transactions();

    processing_result := format(
        'Processed %s recurring transactions at %s. New transaction IDs: %s',
        result_record.processed_count,
        NOW()::TEXT,
        COALESCE(array_to_string(result_record.new_transaction_ids, ', '), 'none')
    );

    -- Log the processing result in audit logs
    INSERT INTO public.audit_logs(user_id, action_by, table_name, record_id, action, new_data)
    VALUES (
        auth.uid(), -- Current user
        auth.uid(), -- Current user action
        'system',
        gen_random_uuid(),
        'RECURRING_PROCESSING',
        jsonb_build_object(
            'processed_count', result_record.processed_count,
            'new_transaction_ids', result_record.new_transaction_ids,
            'processed_at', NOW()
        )
    );

    RETURN processing_result;
END;
$$;

-- Note: Uncomment the following line if pg_cron extension is available
-- SELECT cron.schedule('process-recurring', '0 0 * * *', 'SELECT schedule_recurring_processing();');

-- =========================================
-- 3. UTILITY FUNCTIONS
-- =========================================

-- Get User's Default Currency
CREATE OR REPLACE FUNCTION get_user_default_currency(p_user_id UUID DEFAULT NULL)
RETURNS VARCHAR(10)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
DECLARE
    v_user_id UUID;
    v_currency VARCHAR(10);
BEGIN
    v_user_id := COALESCE(p_user_id, auth.uid());
    
    -- Get most commonly used currency by this user
    SELECT currency INTO v_currency
    FROM accounts 
    WHERE user_id = v_user_id AND deleted_at IS NULL
    GROUP BY currency 
    ORDER BY COUNT(*) DESC 
    LIMIT 1;
    
    RETURN COALESCE(v_currency, 'USD');
END;
$$;

-- Validate Account Ownership
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

-- Get Transaction Count for User
CREATE OR REPLACE FUNCTION get_user_transaction_count(
    p_user_id UUID DEFAULT NULL,
    p_transaction_type transaction_type DEFAULT NULL,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
DECLARE
    v_user_id UUID;
    v_count INTEGER;
BEGIN
    v_user_id := COALESCE(p_user_id, auth.uid());
    
    SELECT COUNT(*)::INTEGER INTO v_count
    FROM transactions
    WHERE user_id = v_user_id
      AND deleted_at IS NULL
      AND (p_transaction_type IS NULL OR type = p_transaction_type)
      AND (p_start_date IS NULL OR created_at::DATE >= p_start_date)
      AND (p_end_date IS NULL OR created_at::DATE <= p_end_date);
      
    RETURN v_count;
END;
$$;

-- Format Currency Amount
CREATE OR REPLACE FUNCTION format_currency_amount(
    p_amount DECIMAL(36,18),
    p_currency VARCHAR(10) DEFAULT 'USD'
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
    RETURN CASE p_currency
        WHEN 'USD' THEN '$' || TO_CHAR(p_amount, 'FM999,999,999,990.00')
        WHEN 'EUR' THEN '€' || TO_CHAR(p_amount, 'FM999,999,999,990.00')
        WHEN 'GBP' THEN '£' || TO_CHAR(p_amount, 'FM999,999,999,990.00')
        WHEN 'JPY' THEN '¥' || TO_CHAR(p_amount, 'FM999,999,999,990')
        WHEN 'LKR' THEN 'Rs. ' || TO_CHAR(p_amount, 'FM999,999,999,990.00')
        WHEN 'BTC' THEN TO_CHAR(p_amount, 'FM0.00000000') || ' BTC'
        WHEN 'ETH' THEN TO_CHAR(p_amount, 'FM0.000000') || ' ETH'
        ELSE TO_CHAR(p_amount, 'FM999,999,999,990.00') || ' ' || p_currency
    END;
END;
$$;

-- =========================================
-- 4. PERFORMANCE MONITORING FUNCTIONS
-- =========================================

-- Get Database Statistics
CREATE OR REPLACE FUNCTION get_user_database_stats(p_user_id UUID DEFAULT NULL)
RETURNS TABLE(
    user_id UUID,
    total_accounts INTEGER,
    total_transactions INTEGER,
    total_categories INTEGER,
    total_income_sources INTEGER,
    total_counterparties INTEGER,
    active_recurring_schedules INTEGER,
    last_transaction_date TIMESTAMPTZ,
    account_creation_date TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := COALESCE(p_user_id, auth.uid());
    
    RETURN QUERY
    SELECT 
        v_user_id,
        (SELECT COUNT(*)::INTEGER FROM accounts WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT COUNT(*)::INTEGER FROM transactions WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT COUNT(*)::INTEGER FROM expense_categories WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT COUNT(*)::INTEGER FROM income_sources WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT COUNT(*)::INTEGER FROM counterparties WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT COUNT(*)::INTEGER FROM transactions_recurring WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT MAX(created_at) FROM transactions WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT created_at FROM profiles WHERE user_id = v_user_id AND deleted_at IS NULL);
END;
$$;

-- =========================================
-- 6. SECURITY ENHANCEMENTS
-- =========================================
-- Function to check rate limits
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
-- 7. BACKUP AND MAINTENANCE HELPERS
-- =========================================

-- Cleanup old audit logs
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

-- Cleanup old rate limit records
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
-- Hard Delete Functions
-- =========================================
-- These functions allow hard deletion while respecting ownership
-- They bypass RLS but include explicit permission checks

-- Generic hard delete function for any table
CREATE OR REPLACE FUNCTION hard_delete_record(
    table_name TEXT,
    record_id UUID,
    user_id_to_check UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id UUID;
    is_admin BOOLEAN;
    sql_query TEXT;
    record_exists BOOLEAN;
BEGIN
    current_user_id := auth.uid();
    
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    
    -- Check if user is admin
    is_admin := check_admin_permissions();
    
    -- If user_id_to_check is provided, verify ownership (unless admin)
    IF user_id_to_check IS NOT NULL AND NOT is_admin THEN
        IF current_user_id != user_id_to_check THEN
            RAISE EXCEPTION 'Permission denied: not owner';
        END IF;
    END IF;
    
    -- Validate table name to prevent SQL injection
    IF table_name NOT IN (
        'accounts', 'transactions', 'expense_categories', 'expense_subcategories',
        'income_sources', 'counterparties', 'transactions_recurring',
        'cash_accounts', 'bank_accounts', 'credit_card_accounts', 'loan_accounts',
        'investment_accounts', 'crypto_accounts', 'wallet_accounts', 'receivable_accounts',
        'transactions_income', 'transactions_expense', 'transactions_investment',
        'transactions_borrow', 'transactions_lend', 'transactions_transfer', 'transactions_adjustment'
    ) THEN
        RAISE EXCEPTION 'Invalid table name';
    END IF;
    
    -- Build and execute the delete query
    sql_query := format('DELETE FROM %I WHERE id = $1', table_name);
    EXECUTE sql_query USING record_id;
    
    -- Check if any rows were affected
    GET DIAGNOSTICS record_exists = ROW_COUNT;
    
    RETURN record_exists > 0;
END;
$$;

-- Hard delete expense category (and all subcategories)
CREATE OR REPLACE FUNCTION hard_delete_expense_category(category_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id UUID;
    category_owner UUID;
    is_admin BOOLEAN;
BEGIN
    current_user_id := auth.uid();
    
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    
    -- Get category details
    SELECT user_id INTO category_owner
    FROM expense_categories
    WHERE id = category_id AND deleted_at IS NULL;
    
    IF category_owner IS NULL THEN
        RAISE EXCEPTION 'Category not found';
    END IF;
    
    -- Check permissions
    is_admin := check_admin_permissions();
    IF NOT is_admin AND current_user_id != category_owner THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    
    -- Delete subcategories first
    DELETE FROM expense_subcategories WHERE category_id = category_id;
    
    -- Delete the main category
    DELETE FROM expense_categories WHERE id = category_id;
    
    RETURN TRUE;
END;
$$;

-- Hard delete counterparty (check for transaction references first)
CREATE OR REPLACE FUNCTION hard_delete_counterparty(counterparty_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id UUID;
    counterparty_owner UUID;
    is_admin BOOLEAN;
    transaction_count INTEGER;
BEGIN
    current_user_id := auth.uid();
    
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    
    -- Get counterparty details
    SELECT user_id INTO counterparty_owner
    FROM counterparties
    WHERE id = counterparty_id AND deleted_at IS NULL;
    
    IF counterparty_owner IS NULL THEN
        RAISE EXCEPTION 'Counterparty not found';
    END IF;
    
    -- Check permissions
    is_admin := check_admin_permissions();
    IF NOT is_admin AND current_user_id != counterparty_owner THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    
    -- Check if counterparty is referenced in transactions
    SELECT COUNT(*) INTO transaction_count
    FROM (
        SELECT 1 FROM transactions_borrow WHERE counterparty_id = counterparty_id
        UNION ALL
        SELECT 1 FROM transactions_lend WHERE counterparty_id = counterparty_id
    ) t;
    
    IF transaction_count > 0 THEN
        RAISE EXCEPTION 'Cannot delete counterparty: % transactions reference this counterparty. Delete transactions first.', transaction_count;
    END IF;
    
    -- Delete the counterparty
    DELETE FROM counterparties WHERE id = counterparty_id;
    
    RETURN TRUE;
END;
$$;

-- Hard delete recurring transaction template
CREATE OR REPLACE FUNCTION hard_delete_recurring_transaction(recurring_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id UUID;
    recurring_owner UUID;
    template_transaction_id UUID;
    is_admin BOOLEAN;
BEGIN
    current_user_id := auth.uid();
    
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    
    -- Get recurring transaction details
    SELECT user_id, transaction_template_id INTO recurring_owner, template_transaction_id
    FROM transactions_recurring
    WHERE id = recurring_id AND deleted_at IS NULL;
    
    IF recurring_owner IS NULL THEN
        RAISE EXCEPTION 'Recurring transaction not found';
    END IF;
    
    -- Check permissions
    is_admin := check_admin_permissions();
    IF NOT is_admin AND current_user_id != recurring_owner THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    
    -- Delete the recurring transaction record
    DELETE FROM transactions_recurring WHERE id = recurring_id;
    
    -- Optionally delete the template transaction too
    -- (You might want to keep it for audit purposes)
    IF template_transaction_id IS NOT NULL THEN
        PERFORM hard_delete_transaction(template_transaction_id);
    END IF;
    
    RETURN TRUE;
END;
$$;

-- Hard delete user profile and ALL associated data (admin only)
CREATE OR REPLACE FUNCTION hard_delete_user_profile(target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id UUID;
    is_admin BOOLEAN;
    account_ids UUID[];
    account_id UUID;
BEGIN
    current_user_id := auth.uid();
    
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    
    -- Only admins can delete user profiles
    is_admin := check_admin_permissions();
    IF NOT is_admin THEN
        RAISE EXCEPTION 'Admin permissions required';
    END IF;
    
    -- Prevent self-deletion
    IF current_user_id = target_user_id THEN
        RAISE EXCEPTION 'Cannot delete your own profile';
    END IF;
    
    -- Get all account IDs for this user
    SELECT ARRAY(SELECT id FROM accounts WHERE user_id = target_user_id) INTO account_ids;
    
    -- Delete all accounts (this will cascade to transactions)
    FOREACH account_id IN ARRAY account_ids LOOP
        PERFORM hard_delete_account(account_id);
    END LOOP;
    
    -- Delete remaining user data
    DELETE FROM transactions_recurring WHERE user_id = target_user_id;
    DELETE FROM expense_subcategories WHERE category_id IN (
        SELECT id FROM expense_categories WHERE user_id = target_user_id
    );
    DELETE FROM expense_categories WHERE user_id = target_user_id;
    DELETE FROM income_sources WHERE user_id = target_user_id;
    DELETE FROM counterparties WHERE user_id = target_user_id;
    DELETE FROM api_rate_limits WHERE user_id = target_user_id;
    
    -- Delete the profile last
    DELETE FROM profiles WHERE user_id = target_user_id;
    
    RETURN TRUE;
END;
$$;

-- Specific hard delete functions for common operations

-- Hard delete account (and all related data)
CREATE OR REPLACE FUNCTION hard_delete_account(account_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id UUID;
    account_owner UUID;
    account_type account_type;
    is_admin BOOLEAN;
BEGIN
    current_user_id := auth.uid();
    
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    
    -- Get account details
    SELECT user_id, type INTO account_owner, account_type
    FROM accounts
    WHERE id = account_id;
    
    IF account_owner IS NULL THEN
        RAISE EXCEPTION 'Account not found';
    END IF;
    
    -- Check permissions
    is_admin := check_admin_permissions();
    IF NOT is_admin AND current_user_id != account_owner THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    
    -- Delete from specialized account table first
    CASE account_type
        WHEN 'cash' THEN DELETE FROM cash_accounts WHERE account_id = account_id;
        WHEN 'bank' THEN DELETE FROM bank_accounts WHERE account_id = account_id;
        WHEN 'credit_card' THEN DELETE FROM credit_card_accounts WHERE account_id = account_id;
        WHEN 'loan' THEN DELETE FROM loan_accounts WHERE account_id = account_id;
        WHEN 'investment' THEN DELETE FROM investment_accounts WHERE account_id = account_id;
        WHEN 'crypto' THEN DELETE FROM crypto_accounts WHERE account_id = account_id;
        WHEN 'wallet' THEN DELETE FROM wallet_accounts WHERE account_id = account_id;
        WHEN 'receivable' THEN DELETE FROM receivable_accounts WHERE account_id = account_id;
    END CASE;
    
    -- Delete transaction details that reference this account
    DELETE FROM transactions_income WHERE account_id = account_id;
    DELETE FROM transactions_expense WHERE account_id = account_id;
    DELETE FROM transactions_investment WHERE account_id = account_id;
    DELETE FROM transactions_borrow WHERE account_id = account_id;
    DELETE FROM transactions_lend WHERE account_id = account_id;
    DELETE FROM transactions_adjustment WHERE account_id = account_id;
    DELETE FROM transactions_transfer WHERE from_account = account_id OR to_account = account_id;
    
    -- Delete the main account record
    DELETE FROM accounts WHERE id = account_id;
    
    RETURN TRUE;
END;
$$;

-- Hard delete transaction (and all related data)
CREATE OR REPLACE FUNCTION hard_delete_transaction(transaction_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id UUID;
    transaction_owner UUID;
    transaction_type transaction_type;
    is_admin BOOLEAN;
BEGIN
    current_user_id := auth.uid();
    
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    
    -- Get transaction details
    SELECT user_id, type INTO transaction_owner, transaction_type
    FROM transactions
    WHERE id = transaction_id;
    
    IF transaction_owner IS NULL THEN
        RAISE EXCEPTION 'Transaction not found';
    END IF;
    
    -- Check permissions
    is_admin := check_admin_permissions();
    IF NOT is_admin AND current_user_id != transaction_owner THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    
    -- Delete from transaction detail tables
    DELETE FROM transactions_income WHERE transaction_id = transaction_id;
    DELETE FROM transactions_expense WHERE transaction_id = transaction_id;
    DELETE FROM transactions_investment WHERE transaction_id = transaction_id;
    DELETE FROM transactions_borrow WHERE transaction_id = transaction_id;
    DELETE FROM transactions_lend WHERE transaction_id = transaction_id;
    DELETE FROM transactions_transfer WHERE transaction_id = transaction_id;
    DELETE FROM transactions_adjustment WHERE transaction_id = transaction_id;
    
    -- Delete the main transaction record
    DELETE FROM transactions WHERE id = transaction_id;
    
    RETURN TRUE;
END;
$$;

-- Batch hard delete old soft-deleted records (admin only)
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

-- Grant execute permissions to authenticated users for client-facing functions
GRANT EXECUTE ON FUNCTION get_income_summary(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION get_expense_summary(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION get_investment_summary(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION get_borrow_lend_summary() TO authenticated;
GRANT EXECUTE ON FUNCTION get_account_details(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_all_accounts() TO authenticated;
GRANT EXECUTE ON FUNCTION create_expense_transaction(UUID, DECIMAL, VARCHAR, UUID, payment_method, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_income_transaction(UUID, DECIMAL, VARCHAR, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION execute_transfer(UUID, UUID, DECIMAL, VARCHAR, transfer_method, DECIMAL, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_recurring_schedule(UUID, recurrence_frequency, INTEGER, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION execute_due_recurring_transactions(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_recurring_schedules() TO authenticated;
GRANT EXECUTE ON FUNCTION initialize_user_defaults(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION compute_transaction_direction(transaction_type, DECIMAL) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_transactions(INTEGER, INTEGER, timestamptz, timestamptz, transaction_type) TO authenticated;
GRANT EXECUTE ON FUNCTION recalculate_account_balance(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION update_account_balance_field(UUID, DECIMAL) TO authenticated;
GRANT EXECUTE ON FUNCTION cleanup_orphaned_specialized_accounts() TO authenticated;
GRANT EXECUTE ON FUNCTION fix_balance_discrepancies(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_account_summary() TO authenticated;
GRANT EXECUTE ON FUNCTION get_recent_transactions(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION check_admin_permissions() TO authenticated;
GRANT EXECUTE ON FUNCTION check_balance_integrity(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION schedule_recurring_processing() TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_default_currency(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION validate_account_ownership(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_transaction_count(UUID, transaction_type, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION format_currency_amount(DECIMAL, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION validate_account_data(UUID, account_type, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_database_stats(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION check_rate_limit(VARCHAR, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION cleanup_old_audit_logs(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION cleanup_old_rate_limits() TO authenticated;
GRANT EXECUTE ON FUNCTION create_account(UUID, VARCHAR, account_type, VARCHAR, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION get_accounts_by_type(account_type) TO authenticated;
GRANT EXECUTE ON FUNCTION update_account(UUID, JSONB) TO authenticated;

-- ================================
-- Function Documentation
-- ================================

COMMENT ON FUNCTION get_income_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get income summary by source and account for current user';

COMMENT ON FUNCTION get_expense_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get expense summary by category and account for current user';

COMMENT ON FUNCTION get_investment_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get investment summary by asset type for current user';

COMMENT ON FUNCTION get_account_details(UUID) IS
'RLS-compliant function to return full account details as JSON, including base and specialized fields, excluding soft-deleted records';

COMMENT ON FUNCTION create_expense_transaction(UUID, DECIMAL, VARCHAR, UUID, payment_method, TEXT) IS 
'RLS-compliant function to create expense transactions with automatic balance updates';

COMMENT ON FUNCTION create_income_transaction(UUID, DECIMAL, VARCHAR, UUID, TEXT) IS 
'RLS-compliant function to create income transactions with automatic balance updates';

COMMENT ON FUNCTION execute_transfer(UUID, UUID, DECIMAL, VARCHAR, transfer_method, DECIMAL, TEXT) IS 
'RLS-compliant atomic transfer function using new transactions_transfer table';

COMMENT ON FUNCTION create_recurring_schedule(UUID, recurrence_frequency, INTEGER, DATE, DATE) IS 
'RLS-compliant function to create recurring transaction schedules';

COMMENT ON FUNCTION initialize_user_defaults(UUID) IS 
'Triggers default account and category creation for new users via existing trigger system';

COMMENT ON FUNCTION recalculate_account_balance(UUID) IS'RLS-compliant balance recalculation from transaction history';

COMMENT ON FUNCTION get_user_account_summary() IS 'RLS-compliant user account summary';

COMMENT ON FUNCTION get_recent_transactions(INTEGER) IS 'RLS-compliant recent transactions query';

COMMENT ON FUNCTION check_balance_integrity(UUID) IS 'RLS-compliant balance integrity verification';

COMMENT ON FUNCTION get_user_default_currency(UUID) IS 'Get most commonly used currency for user';

COMMENT ON FUNCTION validate_account_ownership(UUID, UUID) IS 'Validate user owns specified account';

COMMENT ON FUNCTION check_rate_limit(VARCHAR, INTEGER, INTEGER) IS 'API rate limiting with configurable windows';

-- ================================
-- END OF FUNCTIONS
-- ================================