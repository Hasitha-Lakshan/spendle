-- =========================================
-- 01. Function: create_income_transaction
-- =========================================
-- Purpose:
--   Creates a new income transaction for a specific account, ensuring
--   correct currency conversion, positive amount validation, and
--   linkage to the account and income details.
--
-- Behavior:
--   - Retrieves the current authenticated user (RLS‑validated)
--   - Validates that the amount is positive
--   - Retrieves the currency of the target account
--   - Fetches the appropriate exchange rate between the provided
--     currency and the account currency
--   - Inserts a new row into the transactions table with converted
--     amounts and metadata
--   - Inserts a corresponding row into the transactions_income table
--     linking the transaction to the account and optional source
--
-- Parameters:
--   p_account_id UUID       - The account receiving the income
--   p_amount DECIMAL        - The amount of income (must be positive)
--   p_currency VARCHAR      - Currency code of the amount (default: 'USD')
--   p_source_id UUID        - Optional source ID for the income
--   p_notes TEXT            - Optional notes for the transaction
--
-- Returns:
--   UUID - ID of the newly created transaction
--
-- Notes:
--   - SECURITY DEFINER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions on transactions and transactions_income
--     handle validation and account balance updates
--   - Exchange rates are dynamically calculated using get_exchange_rate()
-- =========================================
CREATE OR REPLACE FUNCTION public.create_income_transaction(
    p_account_id UUID,
    p_amount DECIMAL,
    p_currency VARCHAR,
    p_source_id UUID,
    p_fees DECIMAL DEFAULT 0,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT FALSE,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
VOLATILE
AS $$
DECLARE
    v_transaction_id UUID;
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Validate transaction inputs ===
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount is required and must be positive';
    END IF;

    -- Validate fees
    IF p_fees IS NULL OR p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be null or negative';
    END IF;

    -- Validate account ID
    IF p_account_id IS NULL THEN
        RAISE EXCEPTION 'Account ID is required';
    END IF;

    -- === STEP 3: Validate account ownership and fetch currency
    SELECT currency INTO v_account_currency
    FROM accounts
    WHERE id = p_account_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_account_currency IS NULL THEN
        RAISE EXCEPTION 'Account not found, deleted, or not accessible';
    END IF;

    -- === STEP 4: Validate exchange rate ===
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate for % to %', p_currency, v_account_currency;
    END IF;

    -- === STEP 5: Validate income source ===
    IF p_source_id IS NULL THEN
        RAISE EXCEPTION 'Income source is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM income_sources
        WHERE id = p_source_id
        AND (user_id = v_user_id OR v_is_admin)
        AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Income source not found, deleted, or not accessible';
    END IF;

    -- === STEP 6: Create base transaction ===
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        fees,
        notes,
        created_at,
        updated_at
    )
    VALUES (
        v_user_id,
        'income',
        p_amount,
        UPPER(p_currency),
        v_exchange_rate,
        p_amount * v_exchange_rate,
        p_fees,
        p_notes,
        now(),
        now()
    )
    RETURNING id INTO v_transaction_id;

    -- === STEP 7: Create income-specific details ===
    INSERT INTO transactions_income (
        transaction_id,
        account_id,
        source_id
    )
    VALUES (
        v_transaction_id,
        p_account_id,
        p_source_id
    );

    -- === STEP 8: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(v_transaction_id, p_is_recurring, p_params);

    RETURN v_transaction_id;
END;
$$;

-- =========================================
-- 02. Function: create_expense_transaction
-- =========================================
-- Purpose:
--   Creates a new expense transaction for a specific account, ensuring
--   correct currency conversion, positive amount validation, and
--   linkage to the account and expense details.
--
-- Behavior:
--   - Retrieves the current authenticated user (RLS‑validated)
--   - Validates that the expense amount is positive
--   - Retrieves the currency of the target account
--   - Fetches the appropriate exchange rate between the provided
--     currency and the account currency
--   - Inserts a new row into the transactions table with converted
--     amounts and metadata
--   - Inserts a corresponding row into the transactions_expense table
--     linking the transaction to the account, category, and payment method
--
-- Parameters:
--   p_account_id UUID           - The account from which the expense is paid
--   p_amount DECIMAL            - The expense amount (must be positive)
--   p_currency VARCHAR          - Currency code of the amount (default: 'USD')
--   p_sub_category_id UUID          - Optional expense sub-category
--   p_payment_method payment_method - Payment method used (default: 'other')
--   p_notes TEXT                - Optional notes for the transaction
--
-- Returns:
--   UUID - ID of the newly created transaction
--
-- Notes:
--   - SECURITY DEFINER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions on transactions and transactions_expense
--     handle validation and account balance updates
--   - Exchange rates are dynamically calculated using get_exchange_rate()
-- =========================================
CREATE OR REPLACE FUNCTION public.create_expense_transaction(
    p_account_id UUID,
    p_amount DECIMAL,
    p_currency VARCHAR,
    p_sub_category_id UUID,
    p_payment_method payment_method, 
    p_fees DECIMAL DEFAULT 0,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT FALSE,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
VOLATILE
AS $$
DECLARE
    v_transaction_id UUID;
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Validate inputs ===
    IF p_account_id IS NULL THEN
        RAISE EXCEPTION 'Account ID is required';
    END IF;

    -- Validate amount
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Expense amount is required and must be positive';
    END IF;

        -- Validate fees
    IF p_fees IS NULL OR p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be null or negative';
    END IF;

    -- Validate payment method
    IF p_payment_method IS NULL THEN
        RAISE EXCEPTION 'Payment method is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM unnest(enum_range(NULL::payment_method)) AS m(val)
        WHERE val = p_payment_method
    ) THEN
        RAISE EXCEPTION 'Invalid payment method: %', p_payment_method;
    END IF;

    -- === STEP 3: Validate account ownership and fetch currency ===
    SELECT currency INTO v_account_currency
    FROM accounts
    WHERE id = p_account_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_account_currency IS NULL THEN
        RAISE EXCEPTION 'Account not found, deleted, or not accessible';
    END IF;

    -- === STEP 4: Validate exchange rate ===
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate for % to %', p_currency, v_account_currency;
    END IF;

    -- === STEP 5: Validate sub-category if provided ===
    IF p_sub_category_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1
            FROM expense_subcategories s
            JOIN expense_categories c ON c.id = s.category_id
            WHERE s.id = p_sub_category_id
            AND (c.user_id = v_user_id OR v_is_admin)
            AND s.deleted_at IS NULL
            AND c.deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'Expense sub-category not found, deleted, or not accessible';
        END IF;
    END IF;

    -- === STEP 6: Create base transaction ===
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        fees,
        notes,
        created_at,
        updated_at
    )
    VALUES (
        v_user_id,
        'expense',
        p_amount,
        UPPER(p_currency),
        v_exchange_rate,
        p_amount * v_exchange_rate,
        p_fees,
        p_notes,
        now(),
        now()
    )
    RETURNING id INTO v_transaction_id;

    -- === STEP 7: Create expense-specific details ===
    INSERT INTO transactions_expense (
        transaction_id,
        account_id,
        category_id,
        payment_method
    )
    VALUES (
        v_transaction_id,
        p_account_id,
        p_sub_category_id,
        p_payment_method
    );

    -- === STEP 8: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(v_transaction_id, p_is_recurring, p_params);

    RETURN v_transaction_id;
END;
$$;

-- =========================================
-- 06. Function: create_adjustment_transaction
-- =========================================
-- Purpose:
--   Creates a neutral adjustment transaction for a given account,
--   allowing manual corrections to account balances with reason notes,
--   and applying currency conversion if needed.
--
-- Behavior:
--   - Retrieves the current authenticated user (RLS‑validated)
--   - Validates that the adjustment amount is not zero
--   - Retrieves the currency of the target account
--   - Fetches the appropriate exchange rate between the provided
--     currency and the account currency
--   - Inserts a new row into the transactions table as an
--     'adjustment' type with converted amounts and notes
--   - Inserts a corresponding row into transactions_adjustment
--     including reason and timestamps
--
-- Parameters:
--   p_account_id UUID     - Account to be adjusted
--   p_amount DECIMAL      - Adjustment amount (cannot be zero)
--   p_currency VARCHAR    - Currency code of the amount (default: 'USD')
--   p_reason TEXT         - Reason for adjustment
--   p_notes TEXT          - Optional notes for the transaction
--
-- Returns:
--   UUID - ID of the newly created adjustment transaction
--
-- Notes:
--   - SECURITY DEFINER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions validate account ownership and
--     apply the adjustment to account balances
--   - Exchange rates are calculated dynamically using get_exchange_rate()
-- =========================================
CREATE OR REPLACE FUNCTION public.create_adjustment_transaction(
    p_account_id UUID,
    p_amount DECIMAL,
    p_currency VARCHAR,
    p_fees DECIMAL DEFAULT 0,             -- fees for the adjustment transaction
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT FALSE, -- flag for recurring transactions
    p_params JSONB DEFAULT '{}'::JSONB    -- recurrence parameters
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
VOLATILE
AS $$
DECLARE
    v_transaction_id UUID;
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Validate transaction inputs ===
    IF p_account_id IS NULL THEN
        RAISE EXCEPTION 'Account ID is required';
    END IF;

    -- Validate amount
    IF p_amount IS NULL OR p_amount = 0 THEN
        RAISE EXCEPTION 'Adjustment amount cannot be null or zero';
    END IF;

    IF p_fees IS NULL OR p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be null or negative';
    END IF;

    -- === STEP 3: Validate account ownership and fetch currency ===
    SELECT currency INTO v_account_currency
    FROM accounts
    WHERE id = p_account_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_account_currency IS NULL THEN
        RAISE EXCEPTION 'Account not found, deleted, or not accessible';
    END IF;

    -- === STEP 4: Validate exchange rate ===
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate for % to %', p_currency, v_account_currency;
    END IF;

    -- === STEP 5: Create base transaction ===
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        fees,
        notes,
        created_at,
        updated_at
    )
    VALUES (
        v_user_id,
        'adjustment',
        p_amount,
        UPPER(p_currency),
        v_exchange_rate,
        p_amount * v_exchange_rate,
        p_fees,
        p_notes,
        now(),
        now()
    )
    RETURNING id INTO v_transaction_id;

    -- === STEP 6: Create adjustment-specific details ===
    INSERT INTO transactions_adjustment (
        transaction_id,
        account_id,
        created_at,
        updated_at
    )
    VALUES (
        v_transaction_id,
        p_account_id,
        now(),
        now()
    );

    -- === STEP 7: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(v_transaction_id, p_is_recurring, p_params);

    RETURN v_transaction_id;
END;
$$;

-- =========================================
-- 03. Function: create_investment_transaction
-- =========================================
-- Purpose:
--   Creates a new investment transaction linking a funding account
--   to an investment account, with currency conversion, asset details,
--   and risk level recorded.
--
-- Behavior:
--   - Retrieves the current authenticated user (RLS‑validated)
--   - Validates that the investment amount is positive
--   - Retrieves the currency of the funding account
--   - Fetches the appropriate exchange rate between the provided
--     currency and the funding account currency
--   - Inserts a new row into the transactions table with converted
--     amounts and metadata
--   - Inserts a corresponding row into transactions_investment linking
--     the transaction to the funding account, investment account, and
--     recording asset details and risk level
--
-- Parameters:
--   p_funding_account_id UUID     - Account providing the funds
--   p_investment_account_id UUID  - Account receiving the investment
--   p_amount DECIMAL              - Investment amount (must be positive)
--   p_currency VARCHAR            - Currency code of the amount (default: 'USD')
--   p_asset_type VARCHAR          - Type of the asset (optional)
--   p_asset_symbol VARCHAR        - Symbol of the asset (optional)
--   p_platform VARCHAR            - Investment platform name (optional)
--   p_risk_level risk_level       - Risk level of the investment (default: 'medium')
--   p_notes TEXT                  - Optional notes for the transaction
--
-- Returns:
--   UUID - ID of the newly created investment transaction
--
-- Notes:
--   - SECURITY DEFINER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions handle account validations and balance updates
--   - Exchange rates are dynamically calculated using get_exchange_rate()
-- =========================================
CREATE OR REPLACE FUNCTION public.create_investment_transaction(
    p_funding_account_id UUID,              -- account providing the funds
    p_investment_account_id UUID,           -- account receiving the investment
    p_amount DECIMAL,
    p_asset_type VARCHAR,
    p_asset_symbol VARCHAR,
    p_platform VARCHAR,
    p_risk_level risk_level,
    p_fees DECIMAL DEFAULT 0,               -- fees for the transaction
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT FALSE,   -- flag for recurring transactions
    p_params JSONB DEFAULT '{}'::JSONB      -- recurrence parameters
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
VOLATILE
AS $$
DECLARE
    v_transaction_id UUID;
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_funding_account_currency VARCHAR;
    v_investment_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount DECIMAL;
BEGIN
    -- === STEP 1: Validate authenticated user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found.';
    END IF;
    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Validate input parameters ===
    IF p_funding_account_id IS NULL THEN
        RAISE EXCEPTION 'Funding account ID is required.';
    END IF;

    -- Validate investment account
    IF p_investment_account_id IS NULL THEN
        RAISE EXCEPTION 'Investment account ID is required.';
    END IF;

    -- Validate amount
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Investment amount must be greater than zero.';
    END IF;

    -- Validate fees
    IF p_fees IS NULL OR p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be null or negative.';
    END IF;

    -- === STEP 2A: Validate required asset details ===
    IF p_asset_type IS NULL OR trim(p_asset_type) = '' THEN
        RAISE EXCEPTION 'Asset type is required. Please specify the type of investment.';
    END IF;

    IF p_asset_symbol IS NULL OR trim(p_asset_symbol) = '' THEN
        RAISE EXCEPTION 'Asset symbol is required. Please provide the asset ticker or symbol.';
    END IF;

    IF p_platform IS NULL OR trim(p_platform) = '' THEN
        RAISE EXCEPTION 'Investment platform is required. Please specify the platform or broker.';
    END IF;

    -- === STEP 2B: Validate risk level ===
    IF p_risk_level IS NULL THEN
        RAISE EXCEPTION 'Risk level is required.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM unnest(enum_range(NULL::risk_level)) AS r(val)
        WHERE val = p_risk_level
    ) THEN
        RAISE EXCEPTION 'Invalid risk level: %', p_risk_level;
    END IF;

    -- === STEP 3: Validate funding account ownership and fetch currency ===
    SELECT currency INTO v_funding_account_currency
    FROM accounts
    WHERE id = p_funding_account_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_funding_account_currency IS NULL THEN
        RAISE EXCEPTION 'Funding account not found, deleted, or not accessible.';
    END IF;

    -- === STEP 4: Validate investment account ownership and fetch currency ===
    SELECT currency INTO v_investment_account_currency
    FROM accounts
    WHERE id = p_investment_account_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_investment_account_currency IS NULL THEN
        RAISE EXCEPTION 'Investment account not found, deleted, or not accessible.';
    END IF;

    -- === STEP 5: Get and validate exchange rate ===
    v_exchange_rate := get_exchange_rate(v_funding_account_currency, v_investment_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate for % to %', v_funding_account_currency, v_investment_account_currency;
    END IF;

    -- === STEP 6: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 7: Insert base transaction ===
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        fees,
        notes,
        created_at,
        updated_at
    )
    VALUES (
        v_user_id,
        'investment',
        p_amount,
        v_funding_account_currency,
        v_exchange_rate,
        v_converted_amount,
        p_fees,
        p_notes,
        now(),
        now()
    )
    RETURNING id INTO v_transaction_id;

    -- === STEP 8: Insert investment-specific details ===
    INSERT INTO transactions_investment (
        transaction_id,
        funding_account_id,
        investment_account_id,
        asset_type,
        asset_symbol,
        platform,
        risk_level,
        created_at,
        updated_at
    )
    VALUES (
        v_transaction_id,
        p_funding_account_id,
        p_investment_account_id,
        trim(p_asset_type),
        trim(p_asset_symbol),
        trim(p_platform),
        p_risk_level,
        now(),
        now()
    );

    -- === STEP 9: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(v_transaction_id, p_is_recurring, p_params);

    RETURN v_transaction_id;
END;
$$;

-- =========================================
-- 04. Function: create_borrow_transaction
-- =========================================
-- Purpose:
--   Creates a new borrow transaction that records a loan liability,
--   including the account where borrowed funds are disbursed,
--   with currency conversion and optional notes.
--
-- Behavior:
--   - Retrieves the current authenticated user (RLS‑validated)
--   - Validates that the borrow amount is positive
--   - Retrieves the currency of the disbursement account
--   - Fetches the appropriate exchange rate between the provided
--     currency and the disbursement account currency
--   - Inserts a new row into the transactions table with converted
--     amounts, notes, and metadata
--   - Inserts a corresponding row into transactions_borrow linking
--     the transaction to the loan account and disbursement account
--
-- Parameters:
--   p_loan_account_id UUID           - Account representing the loan liability
--   p_disbursement_account_id UUID   - Account receiving the borrowed funds
--   p_amount DECIMAL                  - Borrowed amount (must be positive)
--   p_currency VARCHAR                - Currency code of the amount (default: 'USD')
--   p_notes TEXT                      - Optional notes for the transaction
--
-- Returns:
--   UUID - ID of the newly created borrow transaction
--
-- Notes:
--   - SECURITY DEFINER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions handle validation of account ownership and
--     updating account balances
--   - Exchange rates are dynamically calculated using get_exchange_rate()
-- =========================================
CREATE OR REPLACE FUNCTION public.create_borrow_transaction(
    p_loan_account_id UUID,             -- Loan liability account
    p_disbursement_account_id UUID,     -- Account where borrowed funds go (cash, bank, wallet)
    p_amount DECIMAL,
    p_fees DECIMAL DEFAULT 0,           -- fees for the transaction
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT FALSE,        
    p_params JSONB DEFAULT '{}'::JSONB           
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
VOLATILE
AS $$
DECLARE
    v_transaction_id UUID;
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_loan_account_currency VARCHAR;
    v_disbursement_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount DECIMAL;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Validate account IDs ===
    IF p_loan_account_id IS NULL THEN
        RAISE EXCEPTION 'Loan account ID is required';
    END IF;

    IF p_disbursement_account_id IS NULL THEN
        RAISE EXCEPTION 'Disbursement account ID is required';
    END IF;

    -- === STEP 3: Validate amount ===
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Borrow amount must be positive and not null';
    END IF;

    -- === STEP 4: Validate fees ===
    IF p_fees IS NULL OR p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be null or negative';
    END IF;

    -- === STEP 5: Validate loan account ownership and fetch currency ===
    SELECT currency INTO v_loan_account_currency 
    FROM accounts 
    WHERE id = p_loan_account_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_loan_account_currency IS NULL THEN
        RAISE EXCEPTION 'Loan account not found, deleted, or not accessible';
    END IF;

    -- === STEP 6: Validate disbursement account ownership and fetch currency ===
    SELECT currency INTO v_disbursement_account_currency 
    FROM accounts 
    WHERE id = p_disbursement_account_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_disbursement_account_currency IS NULL THEN
        RAISE EXCEPTION 'Disbursement account not found, deleted, or not accessible';
    END IF;

    -- === STEP 7: Get and validate exchange rate ===
    v_exchange_rate := get_exchange_rate(v_loan_account_currency, v_disbursement_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate for % to %', v_loan_account_currency, v_disbursement_account_currency;
    END IF;

    -- === STEP 8: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 9: Create base transaction ===
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        fees,
        notes,
        created_at,
        updated_at
    )
    VALUES (
        v_user_id,
        'borrow',
        p_amount,
        v_loan_account_currency,
        v_exchange_rate,
        v_converted_amount,
        p_fees,
        p_notes,
        now(),
        now()
    )
    RETURNING id INTO v_transaction_id;

    -- === STEP 10: Create borrow-specific details ===
    INSERT INTO transactions_borrow (
        transaction_id,
        loan_account_id,
        disbursement_account_id,
        created_at,
        updated_at
    )
    VALUES (
        v_transaction_id,
        p_loan_account_id,
        p_disbursement_account_id,
        now(),
        now()
    );

    -- === STEP 11: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(v_transaction_id, p_is_recurring, p_params);

    RETURN v_transaction_id;
END;
$$;

-- =========================================
-- 05. Function: create_lend_transaction
-- =========================================
-- Purpose:
--   Creates a new lend transaction that records a loan receivable,
--   including the account providing the funds and associated terms,
--   with currency conversion and optional collateral or notes.
--
-- Behavior:
--   - Retrieves the current authenticated user (RLS‑validated)
--   - Validates that the lend amount is positive
--   - Retrieves the currency of the funding account
--   - Fetches the appropriate exchange rate between the provided
--     currency and the funding account currency
--   - Inserts a new row into the transactions table with converted
--     amounts, notes, and metadata
--   - Inserts a corresponding row into transactions_lend linking
--     the transaction to the receivable and funding accounts
--     along with optional counterparty, interest rate, due date, and collateral
--
-- Parameters:
--   p_receivable_account_id UUID  - Account where the receivable is tracked (loan asset)
--   p_funding_account_id UUID     - Account providing the funds (cash, bank, wallet)
--   p_amount DECIMAL               - Lend amount (must be positive)
--   p_currency VARCHAR             - Currency code of the amount (default: 'USD')
--   p_counterparty_id UUID         - Optional counterparty ID
--   p_interest_rate DECIMAL(5,2)   - Optional interest rate
--   p_due_date DATE                - Optional due date for repayment
--   p_collateral TEXT              - Optional collateral details
--   p_notes TEXT                   - Optional notes for the transaction
--
-- Returns:
--   UUID - ID of the newly created lend transaction
--
-- Notes:
--   - SECURITY DEFINER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions handle validation of account ownership and
--     updating account balances
--   - Exchange rates are dynamically calculated using get_exchange_rate()
-- =========================================
CREATE OR REPLACE FUNCTION public.create_lend_transaction(
    p_receivable_account_id UUID,       -- Where the receivable is tracked (loan asset)
    p_funding_account_id UUID,          -- Account providing funds (cash, bank, wallet)
    p_amount DECIMAL,
    p_interest_rate DECIMAL(5,2),
    p_counterparty_id UUID,
    p_collateral TEXT,
    p_fees DECIMAL DEFAULT 0,           -- fees for the transaction
    p_due_date DATE DEFAULT NULL,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT FALSE,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
VOLATILE
AS $$
DECLARE
    v_transaction_id UUID;
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_receivable_account_currency VARCHAR;
    v_funding_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount DECIMAL;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Validate account IDs ===
    IF p_receivable_account_id IS NULL THEN
        RAISE EXCEPTION 'Receivable account ID is required';
    END IF;

    IF p_funding_account_id IS NULL THEN
        RAISE EXCEPTION 'Funding account ID is required';
    END IF;

    -- === STEP 3: Validate amount and fees ===
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Lend amount must be positive and not null';
    END IF;

    IF p_fees IS NULL OR p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be null or negative';
    END IF;

    -- === STEP 4: Validate required lend-specific params ===
    IF p_counterparty_id IS NULL THEN
        RAISE EXCEPTION 'Counterparty ID is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM counterparties
        WHERE id = p_counterparty_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Counterparty not found, deleted, or not accessible';
    END IF;

    IF p_interest_rate IS NULL OR p_interest_rate < 0 THEN
        RAISE EXCEPTION 'Interest rate is required and cannot be negative';
    END IF;

    IF p_collateral IS NULL OR LENGTH(TRIM(p_collateral)) = 0 THEN
        RAISE EXCEPTION 'Collateral is required';
    END IF;

    -- === STEP 5: Validate receivable account ownership and fetch currency ===
    SELECT currency INTO v_receivable_account_currency
    FROM accounts
    WHERE id = p_receivable_account_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_receivable_account_currency IS NULL THEN
        RAISE EXCEPTION 'Receivable account not found, deleted, or not accessible';
    END IF;

    -- === STEP 6: Validate funding account ownership and fetch currency ===
    SELECT currency INTO v_funding_account_currency
    FROM accounts
    WHERE id = p_funding_account_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_funding_account_currency IS NULL THEN
        RAISE EXCEPTION 'Funding account not found, deleted, or not accessible';
    END IF;

    -- === STEP 7: Get and validate exchange rate ===
    v_exchange_rate := get_exchange_rate(v_funding_account_currency, v_receivable_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate from % to %', v_funding_account_currency, v_receivable_account_currency;
    END IF;

    -- === STEP 8: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 9: Insert base transaction ===
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        fees,
        notes,
        created_at,
        updated_at
    )
    VALUES (
        v_user_id,
        'lend',
        p_amount,
        v_funding_account_currency,
        v_exchange_rate,
        v_converted_amount,
        p_fees,
        p_notes,
        now(),
        now()
    )
    RETURNING id INTO v_transaction_id;

    -- === STEP 10: Insert lend transaction details ===
    INSERT INTO transactions_lend (
        transaction_id,
        receivable_account_id,
        funding_account_id,
        counterparty_id,
        interest_rate,
        due_date,
        collateral,
        created_at,
        updated_at
    )
    VALUES (
        v_transaction_id,
        p_receivable_account_id,
        p_funding_account_id,
        p_counterparty_id,
        p_interest_rate,
        p_due_date,
        p_collateral,
        now(),
        now()
    );

    -- === STEP 11: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(v_transaction_id, p_is_recurring, p_params);

    RETURN v_transaction_id;
END;
$$;

-- =========================================
-- 07. Function: create_transfer_transaction
-- =========================================
-- Purpose:
--   Creates a transfer transaction between two accounts, handling
--   currency conversion and optional fees while ensuring ownership
--   validation and applying business rules.
--
-- Behavior:
--   - Retrieves the current authenticated user (RLS‑validated)
--   - Validates that:
--       * Transfer amount is positive
--       * Source and destination accounts are different
--       * Both accounts exist
--   - Retrieves the currencies of both the source (from_account)
--     and destination (to_account) accounts
--   - Fetches exchange rates for the provided currency to both account currencies
--   - Calculates converted amounts for both accounts
--   - Inserts a new row into the transactions table as a 'transfer' type
--     with the calculated exchange rates and amounts
--   - Inserts a corresponding row into transactions_transfer including
--     transfer details, method, fees, and timestamps
--
-- Parameters:
--   p_from_account UUID         - Account to transfer funds from
--   p_to_account UUID           - Account to transfer funds to
--   p_amount DECIMAL            - Amount to transfer
--   p_currency VARCHAR          - Currency of the transfer amount (default: 'USD')
--   p_transfer_method transfer_method - Transfer method (default: 'other')
--   p_fees DECIMAL              - Optional fees for the transfer (default: 0)
--   p_notes TEXT                - Optional notes for the transaction
--
-- Returns:
--   UUID - ID of the newly created transfer transaction
--
-- Notes:
--   - SECURITY DEFINER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions validate account ownership and apply balance updates
--   - Exchange rates are dynamically retrieved using get_exchange_rate()
--   - Prevents transfers between the same account
-- =========================================
CREATE OR REPLACE FUNCTION public.create_transfer_transaction(
    p_from_account UUID,
    p_to_account UUID,
    p_amount DECIMAL,
    p_transfer_method transfer_method,
    p_fees DECIMAL DEFAULT 0,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT FALSE,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
VOLATILE
AS $$
DECLARE
    v_transaction_id UUID;
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_from_account_currency VARCHAR;
    v_to_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount DECIMAL;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Validate accounts ===
    IF p_from_account IS NULL THEN
        RAISE EXCEPTION 'From account ID is required';
    END IF;

    IF p_to_account IS NULL THEN
        RAISE EXCEPTION 'To account ID is required';
    END IF;

    -- Prevent self-transfer
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'Cannot transfer to the same account';
    END IF;

    -- === STEP 3: Validate amount and fees ===
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive and not null';
    END IF;

    IF p_fees IS NULL OR p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be null or negative';
    END IF;

    -- === STEP 4: Validate transfer method ===
    IF p_transfer_method IS NULL THEN
        RAISE EXCEPTION 'Transfer method is required';
    END IF;

    -- Optional: explicit check against enum values (extra safety)
    IF NOT EXISTS (
        SELECT 1
        FROM unnest(enum_range(NULL::transfer_method)) AS m(val)
        WHERE val = p_transfer_method
    ) THEN
        RAISE EXCEPTION 'Invalid transfer method: %', p_transfer_method;
    END IF;

    -- === STEP 5: Validate from_account ownership and fetch currency ===
    SELECT currency INTO v_from_account_currency
    FROM accounts
    WHERE id = p_from_account
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_from_account_currency IS NULL THEN
        RAISE EXCEPTION 'From account not found, deleted, or not accessible';
    END IF;

    -- === STEP 6: Validate to_account ownership and fetch currency ===
    SELECT currency INTO v_to_account_currency
    FROM accounts
    WHERE id = p_to_account
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF v_to_account_currency IS NULL THEN
        RAISE EXCEPTION 'To account not found, deleted, or not accessible';
    END IF;

    -- === STEP 7: Get and validate exchange rate ===
    v_exchange_rate := get_exchange_rate(v_from_account_currency, v_to_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate from % to %', v_from_account_currency, v_to_account_currency;
    END IF;

    -- === STEP 8: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 9: Insert base transaction ===
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        fees,
        notes,
        created_at,
        updated_at
    )
    VALUES (
        v_user_id,
        'transfer',
        p_amount,
        v_from_account_currency,
        v_exchange_rate,
        v_converted_amount,
        p_fees,
        p_notes,
        now(),
        now()
    )
    RETURNING id INTO v_transaction_id;

    -- === STEP 10: Insert transfer transaction details ===
    INSERT INTO transactions_transfer (
        transaction_id,
        from_account,
        to_account,
        transfer_method,
        created_at,
        updated_at
    )
    VALUES (
        v_transaction_id,
        p_from_account,
        p_to_account,
        p_transfer_method,
        now(),
        now()
    );

    -- === STEP 11: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(v_transaction_id, p_is_recurring, p_params);

    RETURN v_transaction_id;
END;
$$;

-- =========================================
-- 08. Function: update_income_transaction
-- =========================================
-- Purpose:
--   Updates an existing income transaction and its associated account details,
--   ensuring balance adjustments are handled correctly if relevant fields change.
--
-- Behavior:
--   - Retrieves the existing transaction and income record by transaction ID,
--     validating ownership based on the current authenticated user.
--   - Determines if relevant details (account, currency, amount, fees) have changed.
--   - If balance-affecting changes are detected, reverses the previous transaction's balance
--     using reverse_transaction_balance().
--   - Validates the new account and retrieves its currency.
--   - Calculates the updated exchange rate and converted amount using get_exchange_rate().
--   - Updates the transactions table with new values (amount, currency, fees, notes, etc.).
--   - Updates the transactions_income table with any changes to account_id or source_id.
--   - If balance-affecting changes occurred, reapplies the transaction balance using apply_transaction_balance().
--   - Returns a JSON object containing the updated transaction and income record.
--
-- Parameters:
--   p_transaction_id UUID     - The ID of the transaction to update.
--   p_account_id UUID         - (Optional) New account ID for the transaction.
--   p_amount NUMERIC          - (Optional) New amount for the transaction.
--   p_currency VARCHAR        - (Optional) New currency for the transaction.
--   p_fees NUMERIC            - (Optional) New fees for the transaction.
--   p_source_id UUID          - (Optional) New income source ID.
--   p_notes TEXT              - (Optional) Updated transaction notes.
--
-- Returns:
--   JSON - A JSON object containing:
--     * 'transaction' → Updated transaction record.
--     * 'income'       → Updated income transaction details.
--     * 'error'        → Error message if operation failed.
--
-- Notes:
--   - SECURITY DEFINER allows privilege escalation for balance updates while
--     enforcing ownership rules.
--   - Uses get_transaction_table_name() to determine the correct income table dynamically.
--   - Handles exceptions gracefully, returning error information in JSON format.
-- =========================================
CREATE OR REPLACE FUNCTION public.update_income_transaction(
    p_transaction_id UUID,
    p_account_id UUID,
    p_amount NUMERIC,
    p_currency VARCHAR,
    p_source_id UUID,
    p_fees NUMERIC DEFAULT 0,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT NULL,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_existing RECORD;
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount NUMERIC;
    v_table_name TEXT;
    v_result JSON;
    v_balance_changed BOOLEAN := FALSE;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    v_is_admin := public.check_admin_permissions();

    IF p_transaction_id IS NULL THEN
        RAISE EXCEPTION 'Transaction ID is required';
    END IF;

    -- === STEP 2: Fetch existing transaction ===
    SELECT t.*, i.account_id, i.source_id
    INTO v_existing
    FROM transactions t
    JOIN transactions_income i ON i.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Income transaction not found or access denied';
    END IF;

    -- === STEP 3: Validate amount and fees ===
    IF p_amount IS NOT NULL AND p_amount <= 0 THEN
        RAISE EXCEPTION 'Income amount must be positive';
    END IF;

    IF p_fees IS NOT NULL AND p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be negative';
    END IF;

    -- === STEP 4: Validate account ownership if changed ===
    IF p_account_id IS NOT NULL AND p_account_id IS DISTINCT FROM v_existing.account_id THEN
        SELECT currency INTO v_account_currency
        FROM accounts
        WHERE id = p_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_account_currency IS NULL THEN
            RAISE EXCEPTION 'New account not found, deleted, or not owned by user';
        END IF;
    ELSE
        SELECT currency INTO v_account_currency
        FROM accounts
        WHERE id = v_existing.account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_account_currency IS NULL THEN
            RAISE EXCEPTION 'Account not found, deleted, or not owned by user';
        END IF;
    END IF;

    -- === STEP 5: Validate income source ===
    IF p_source_id IS NULL THEN
        RAISE EXCEPTION 'Income source is required';
    END IF;

    -- === STEP 5: Validate income source if changed ===
    -- === STEP 5: Validate income source if changed ===
    IF p_source_id IS NOT NULL AND p_source_id IS DISTINCT FROM v_existing.source_id THEN
        IF NOT EXISTS (
            SELECT 1
            FROM income_sources
            WHERE id = p_source_id
              AND (user_id = v_user_id OR v_is_admin)
              AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'Income source not found, deleted, or not owned by user';
        END IF;
    END IF;

    -- === STEP 6: Determine transaction table name ===
    v_table_name := public.get_transaction_table_name(v_existing.type::TEXT);

    -- === STEP 7: Detect balance-impacting changes ===
    v_balance_changed := (
        (p_account_id IS DISTINCT FROM v_existing.account_id)
        OR (p_amount IS NOT NULL AND p_amount IS DISTINCT FROM v_existing.original_amount)
        OR (p_fees IS NOT NULL AND p_fees IS DISTINCT FROM v_existing.fees)
        OR (v_account_currency IS DISTINCT FROM v_existing.original_currency)
    );

    -- === STEP 8: Validate exchange rate ===
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate for % to %', p_currency, v_account_currency;
    END IF;

    -- === STEP 9: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 10: Reverse balance if needed ===
    IF v_balance_changed THEN
        PERFORM public.reverse_transaction_balance(p_transaction_id, v_existing.type::transaction_type);
    END IF;

    -- === STEP 11: Update transactions table ===
    UPDATE transactions
    SET
        original_amount   = p_amount,
        original_currency = p_currency,
        exchange_rate     = v_exchange_rate,
        converted_amount  = v_converted_amount,
        fees              = p_fees,
        notes             = COALESCE(p_notes, v_existing.notes),
        updated_at        = NOW()
    WHERE id = p_transaction_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction update failed or access denied';
    END IF;

    -- === STEP 12: Update income-specific details===
    UPDATE transactions_income
    SET
        account_id = COALESCE(p_account_id, v_existing.account_id),
        source_id  = COALESCE(p_source_id, v_existing.source_id),
        updated_at = NOW()
    WHERE transaction_id = p_transaction_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Income update failed or access denied';
    END IF;

    -- === STEP 13: Handle recurring transactions ===
    PERFORM public.handle_recurring_transaction(p_transaction_id, p_is_recurring, p_params);

    -- === STEP 14: Reapply balance if changed ===
    IF v_balance_changed THEN
        PERFORM public.apply_transaction_balance(
            v_table_name,
            (SELECT i FROM transactions_income i WHERE i.transaction_id = p_transaction_id)
        );
    END IF;

    -- === STEP 15: Return updated record ===
    SELECT json_build_object(
        'transaction', row_to_json(t),
        'income', row_to_json(i)
    )
    INTO v_result
    FROM transactions t
    JOIN transactions_income i ON i.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN json_build_object(
            'error', SQLERRM,
            'transaction_id', p_transaction_id
        );
END;
$$;

-- =========================================
-- 09. Function: update_expense_transaction
-- =========================================
-- Purpose:
--   Updates an existing expense transaction, including both the general
--   transaction record and the expense-specific details, while ensuring
--   proper ownership and balance adjustments.
--
-- Behavior:
--   - Validates transaction ownership or admin privileges.
--   - Checks if key details (account, currency, amount, fees) have changed
--     and reverses the previous transaction balance if needed.
--   - Validates ownership of the new account if provided.
--   - Calculates updated exchange rates and converted amounts.
--   - Updates the main transactions table with new amounts, currency,
--     exchange rates, fees, and notes.
--   - Updates the transactions_expense table with account, category, and
--     payment method changes.
--   - Reapplies the transaction balance if relevant changes occurred.
--   - Returns a JSON object containing the updated transaction and expense
--     details.
--
-- Parameters:
--   p_transaction_id UUID            - ID of the transaction to update.
--   p_account_id UUID DEFAULT NULL   - New account ID (optional).
--   p_amount NUMERIC DEFAULT NULL    - New original amount (optional).
--   p_currency VARCHAR DEFAULT NULL  - New currency code (optional).
--   p_fees NUMERIC DEFAULT NULL      - New fees amount (optional).
--   p_sub_category_id UUID DEFAULT NULL  - New expense sub-category ID (optional).
--   p_payment_method payment_method DEFAULT NULL - New payment method (optional).
--   p_notes TEXT DEFAULT NULL        - New notes or description (optional).
--
-- Returns:
--   JSON - Updated transaction and expense details in JSON format,
--          or an error message if update fails.
--
-- Notes:
--   - SECURITY DEFINER is used to allow controlled access checks.
--   - Includes ownership/admin checks to prevent unauthorized updates.
--   - Reverses and reapplies balances when key fields are modified.
--     for dynamic table access and change detection.
-- =========================================
CREATE OR REPLACE FUNCTION public.update_expense_transaction(
    p_transaction_id UUID,
    p_account_id UUID,
    p_amount NUMERIC,
    p_currency VARCHAR,
    p_sub_category_id UUID,
    p_payment_method payment_method,
    p_fees NUMERIC DEFAULT 0,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT NULL,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_existing RECORD;
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount NUMERIC;
    v_table_name TEXT;
    v_result JSON;
    v_balance_changed BOOLEAN := FALSE;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    v_is_admin := public.check_admin_permissions();

    IF p_transaction_id IS NULL THEN
        RAISE EXCEPTION 'Transaction ID is required';
    END IF;

    -- === STEP 2: Fetch existing transaction ===
    SELECT t.*, e.account_id, e.category_id, e.payment_method
    INTO v_existing
    FROM transactions t
    JOIN transactions_expense e ON e.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found or access denied';
    END IF;

    -- === STEP 3: Validate amount and fees ===
    IF p_amount IS NOT NULL AND p_amount <= 0 THEN
        RAISE EXCEPTION 'Expense amount must be positive';
    END IF;

    -- === STEP 4: Validate fees if provided ===
    IF p_fees IS NOT NULL AND p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be negative';
    END IF;

    -- === STEP 4: Validate account ownership and get currency ===
    IF p_account_id IS NOT NULL AND p_account_id IS DISTINCT FROM v_existing.account_id THEN
        SELECT currency INTO v_account_currency
        FROM accounts
        WHERE id = p_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_account_currency IS NULL THEN
            RAISE EXCEPTION 'New account not found, deleted, or not owned by user';
        END IF;
    ELSE
        SELECT currency INTO v_account_currency
        FROM accounts
        WHERE id = v_existing.account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_account_currency IS NULL THEN
            RAISE EXCEPTION 'Account not found, deleted, or not owned by user';
        END IF;
    END IF;

    -- === STEP 5: Validate sub-category if provided ===
    IF p_sub_category_id IS NOT NULL AND p_sub_category_id IS DISTINCT FROM v_existing.category_id THEN
        IF NOT EXISTS (
            SELECT 1
            FROM expense_subcategories s
            JOIN expense_categories c ON c.id = s.category_id
            WHERE s.id = p_sub_category_id
            AND (c.user_id = v_user_id OR v_is_admin)
            AND s.deleted_at IS NULL
            AND c.deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'Expense sub-category not found, deleted, or not accessible';
        END IF;
    END IF;

    -- === STEP 5b: Validate payment method ===
    IF p_payment_method IS NULL THEN
        RAISE EXCEPTION 'Payment method is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM unnest(enum_range(NULL::payment_method)) AS m(val)
        WHERE val = p_payment_method
    ) THEN
        RAISE EXCEPTION 'Invalid payment method: %', p_payment_method;
    END IF;

    -- === STEP 6: Determine transaction table name ===
    v_table_name := public.get_transaction_table_name(v_existing.type::TEXT);

    -- === STEP 7: Detect balance-impacting changes ===
    v_balance_changed := (
        (p_account_id IS DISTINCT FROM v_existing.account_id)
        OR (p_amount IS NOT NULL AND p_amount IS DISTINCT FROM v_existing.original_amount)
        OR (p_fees IS NOT NULL AND p_fees IS DISTINCT FROM v_existing.fees)
        OR (v_account_currency IS DISTINCT FROM v_existing.original_currency)
    );

    -- === STEP 8: Validate exchange rate ===
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate for % to %', p_currency, v_account_currency;
    END IF;

    -- === STEP 9: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 10: Reverse balance if needed ===
    IF v_balance_changed THEN
        PERFORM public.reverse_transaction_balance(p_transaction_id, v_existing.type::transaction_type);
    END IF;

    -- === STEP 11: Update transactions table ===
    UPDATE transactions
    SET
        original_amount   = p_amount,
        original_currency = p_currency,
        exchange_rate     = v_exchange_rate,
        converted_amount  = v_converted_amount,
        fees              = p_fees,
        notes             = COALESCE(p_notes, v_existing.notes),
        updated_at        = NOW()
    WHERE id = p_transaction_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction update failed or access denied';
    END IF;

    -- === STEP 12: Update expense-specific details ===
    UPDATE transactions_expense
    SET
        account_id     = COALESCE(p_account_id, v_existing.account_id),
        category_id    = COALESCE(p_sub_category_id, v_existing.category_id),
        payment_method = COALESCE(p_payment_method, v_existing.payment_method),
        updated_at     = NOW()
    WHERE transaction_id = p_transaction_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Expense details update failed or access denied';
    END IF;

    -- === STEP 13: Handle recurring transactions ===
    PERFORM public.handle_recurring_transaction(p_transaction_id, p_is_recurring, p_params);

    -- === STEP 14: Reapply balance if changed ===
    IF v_balance_changed THEN
        PERFORM public.apply_transaction_balance(
            v_table_name,
            (SELECT e FROM transactions_expense e WHERE e.transaction_id = p_transaction_id)
        );
    END IF;

    -- === STEP 15: Return updated record ===
    SELECT json_build_object(
        'transaction', row_to_json(t),
        'expense', row_to_json(e)
    )
    INTO v_result
    FROM transactions t
    JOIN transactions_expense e ON e.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN json_build_object(
            'error', SQLERRM,
            'transaction_id', p_transaction_id
        );
END;
$$;

-- =========================================
-- 11. Function: update_adjustment_transaction
-- =========================================
-- Purpose:
--   Updates an existing adjustment transaction, including both the general
--   transaction record and the adjustment-specific details, while ensuring
--   proper ownership and balance adjustments.
--
-- Behavior:
--   - Validates transaction ownership or admin privileges.
--   - Checks if key details (account, currency, amount, fees) have changed
--     and reverses the previous transaction balance if needed.
--   - Validates ownership of the new account if provided.
--   - Calculates updated exchange rates and converted amounts.
--   - Updates the main transactions table with new amounts, currency,
--     exchange rates, fees, and notes.
--   - Updates the transactions_adjustment table with account and reason details.
--   - Reapplies the transaction balance if relevant changes occurred.
--   - Returns a JSON object containing the updated transaction and adjustment
--     details.
--
-- Parameters:
--   p_transaction_id UUID            - ID of the transaction to update.
--   p_account_id UUID DEFAULT NULL   - New account ID (optional).
--   p_amount NUMERIC DEFAULT NULL    - New original amount (optional).
--   p_currency VARCHAR DEFAULT NULL  - New currency code (optional).
--   p_fees NUMERIC DEFAULT NULL      - New fees amount (optional).
--   p_reason TEXT DEFAULT NULL       - New reason for adjustment (optional).
--
-- Returns:
--   JSON - Updated transaction and adjustment details in JSON format,
--          or an error message if update fails.
--
-- Notes:
--   - SECURITY DEFINER is used to allow controlled access checks.
--   - Includes ownership/admin checks to prevent unauthorized updates.
--   - Reverses and reapplies balances when key fields are modified.
--     for dynamic table access and change detection.
-- =========================================
CREATE OR REPLACE FUNCTION public.update_adjustment_transaction(
    p_transaction_id UUID,
    p_account_id UUID,
    p_amount NUMERIC,
    p_currency VARCHAR,
    p_fees NUMERIC DEFAULT 0,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT NULL,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_existing RECORD;
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount NUMERIC;
    v_table_name TEXT;
    v_result JSON;
    v_balance_changed BOOLEAN := FALSE;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;
    v_is_admin := public.check_admin_permissions();

    IF p_transaction_id IS NULL THEN
        RAISE EXCEPTION 'Transaction ID is required';
    END IF;

    -- === STEP 2: Fetch existing transaction ===
    SELECT t.*, a.account_id
    INTO v_existing
    FROM transactions t
    JOIN transactions_adjustment a ON a.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Adjustment transaction not found or access denied';
    END IF;

    -- === STEP 3: Basic validation ===
    IF p_amount IS NOT NULL AND p_amount = 0 THEN
        RAISE EXCEPTION 'Adjustment amount cannot be zero';
    END IF;

    IF p_fees IS NOT NULL AND p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be negative';
    END IF;

    -- === STEP 4: Validate account ownership and get currency ===
    IF p_account_id IS NOT NULL AND p_account_id IS DISTINCT FROM v_existing.account_id THEN
        SELECT currency INTO v_account_currency
        FROM accounts
        WHERE id = p_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_account_currency IS NULL THEN
            RAISE EXCEPTION 'New account not found or access denied';
        END IF;
    ELSE
        SELECT currency INTO v_account_currency
        FROM accounts
        WHERE id = v_existing.account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_account_currency IS NULL THEN
            RAISE EXCEPTION 'Account not found or access denied';
        END IF;
    END IF;

    -- === STEP 5: Determine transaction table name ===
    v_table_name := public.get_transaction_table_name(v_existing.type::TEXT);

    -- === STEP 6: Detect balance-impacting changes ===
    v_balance_changed := (
        (p_account_id IS DISTINCT FROM v_existing.account_id)
        OR (p_amount IS NOT NULL AND p_amount IS DISTINCT FROM v_existing.original_amount)
        OR (p_fees IS NOT NULL AND p_fees IS DISTINCT FROM v_existing.fees)
        OR (v_account_currency IS DISTINCT FROM v_existing.original_currency)
    );

    -- === STEP 7: Validate exchange rate ===
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate for % to %', p_currency, v_account_currency;
    END IF;

    -- === STEP 8: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 9: Reverse previous balance if needed ===
    IF v_balance_changed THEN
        PERFORM public.reverse_transaction_balance(p_transaction_id, v_existing.type::transaction_type);
    END IF;

    -- === STEP 10: Update transactions table ===
    UPDATE transactions
    SET
        original_amount   = p_amount,
        original_currency = p_currency,
        exchange_rate     = v_exchange_rate,
        converted_amount  = v_converted_amount,
        fees              = p_fees,
        notes             = COALESCE(p_notes, v_existing.notes),
        updated_at        = NOW()
    WHERE id = p_transaction_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Update failed or access denied';
    END IF;

    -- === STEP 11: Update adjustment-specific details ===
    UPDATE transactions_adjustment
    SET
        account_id = COALESCE(p_account_id, v_existing.account_id),
        updated_at = NOW()
    WHERE transaction_id = p_transaction_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Adjustment update failed or access denied';
    END IF;

    -- === STEP 12: Handle recurring transactions ===
    PERFORM public.handle_recurring_transaction(p_transaction_id, p_is_recurring, p_params);

    -- === STEP 13: Reapply balance if changed ===
    IF v_balance_changed THEN
        PERFORM public.apply_transaction_balance(
            v_table_name,
            (SELECT a FROM transactions_adjustment a WHERE a.transaction_id = p_transaction_id)
        );
    END IF;

    -- === STEP 14: Return updated record ===
    SELECT json_build_object(
        'transaction', row_to_json(t),
        'adjustment', row_to_json(a)
    )
    INTO v_result
    FROM transactions t
    JOIN transactions_adjustment a ON a.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN json_build_object(
            'error', SQLERRM,
            'transaction_id', p_transaction_id
        );
END;
$$;

-- =========================================
-- 10. Function: update_investment_transaction
-- =========================================
-- Purpose:
--   Updates an existing investment transaction, including both the general
--   transaction record and the investment-specific details, while ensuring
--   proper ownership and balance adjustments.
--
-- Behavior:
--   - Validates transaction ownership or admin privileges.
--   - Checks if key details (funding account, investment account, currency,
--     amount, fees) have changed and reverses the previous transaction balance if needed.
--   - Validates ownership of funding and investment accounts if changed.
--   - Calculates updated exchange rates and converted amounts.
--   - Updates the main transactions table with new amounts, currency,
--     exchange rates, fees, and notes.
--   - Updates the transactions_investment table with funding account,
--     investment account, asset details, platform, and risk level.
--   - Reapplies the transaction balance if relevant changes occurred.
--   - Returns a JSON object containing the updated transaction and investment
--     details.
--
-- Parameters:
--   p_transaction_id UUID                       - ID of the transaction to update.
--   p_funding_account_id UUID DEFAULT NULL      - New funding account ID (optional).
--   p_investment_account_id UUID DEFAULT NULL   - New investment account ID (optional).
--   p_amount NUMERIC DEFAULT NULL               - New original amount (optional).
--   p_currency VARCHAR DEFAULT NULL             - New currency code (optional).
--   p_fees NUMERIC DEFAULT NULL                 - New fees amount (optional).
--   p_asset_type VARCHAR DEFAULT NULL           - New asset type (optional).
--   p_asset_symbol VARCHAR DEFAULT NULL         - New asset symbol (optional).
--   p_platform VARCHAR DEFAULT NULL              - New platform name (optional).
--   p_risk_level risk_level DEFAULT NULL        - New risk level (optional).
--   p_notes TEXT DEFAULT NULL                   - New notes or description (optional).
--
-- Returns:
--   JSON - Updated transaction and investment details in JSON format,
--          or an error message if update fails.
--
-- Notes:
--   - SECURITY DEFINER is used to allow controlled access checks.
--   - Includes ownership/admin checks to prevent unauthorized updates.
--   - Reverses and reapplies balances when key fields are modified.
--     for dynamic table access and change detection.
-- =========================================
CREATE OR REPLACE FUNCTION public.update_investment_transaction(
    p_transaction_id UUID,
    p_funding_account_id UUID,
    p_investment_account_id UUID,
    p_amount NUMERIC,
    p_asset_type VARCHAR,
    p_asset_symbol VARCHAR,
    p_platform VARCHAR,
    p_risk_level risk_level,
    p_fees NUMERIC DEFAULT 0,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT NULL,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_existing RECORD;
    v_funding_currency VARCHAR;
    v_investment_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount NUMERIC;
    v_table_name TEXT;
    v_result JSON;
    v_balance_changed BOOLEAN := FALSE;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Fetch and validate existing transaction ===
    SELECT t.*, i.funding_account_id, i.investment_account_id
    INTO v_existing
    FROM transactions t
    JOIN transactions_investment i ON i.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found or access denied';
    END IF;

    -- === STEP 3: Basic validation ===
    IF p_amount IS NOT NULL AND p_amount <= 0 THEN
        RAISE EXCEPTION 'Investment amount must be positive when provided';
    END IF;

    IF p_fees IS NOT NULL AND p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be negative';
    END IF;

    -- === STEP 2A: Validate required asset details ===
    IF p_asset_type IS NULL OR trim(p_asset_type) = '' THEN
        RAISE EXCEPTION 'Asset type is required. Please specify the type of investment.';
    END IF;

    IF p_asset_symbol IS NULL OR trim(p_asset_symbol) = '' THEN
        RAISE EXCEPTION 'Asset symbol is required. Please provide the asset ticker or symbol.';
    END IF;

    IF p_platform IS NULL OR trim(p_platform) = '' THEN
        RAISE EXCEPTION 'Investment platform is required. Please specify the platform or broker.';
    END IF;

    IF p_risk_level IS NULL THEN
        RAISE EXCEPTION 'Risk level is required.';
    END IF;
    
    IF NOT EXISTS (
        SELECT 1
        FROM unnest(enum_range(NULL::risk_level)) AS r(val)
        WHERE val = p_risk_level
    ) THEN
        RAISE EXCEPTION 'Invalid risk level: %', p_risk_level;
    END IF;

    -- === STEP 4: Determine transaction table name ===
    v_table_name := public.get_transaction_table_name(v_existing.type::TEXT);

    -- === STEP 5: Validate funding account ===
    IF p_funding_account_id IS NOT NULL AND p_funding_account_id <> v_existing.funding_account_id THEN
        SELECT currency INTO v_funding_currency
        FROM accounts
        WHERE id = p_funding_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_funding_currency IS NULL THEN
            RAISE EXCEPTION 'New Funding account not found or access denied';
        END IF;
    ELSE
        SELECT currency INTO v_funding_currency
        FROM accounts
        WHERE id = v_existing.funding_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_funding_currency IS NULL THEN
            RAISE EXCEPTION 'Funding account not found or access denied';
        END IF;
    END IF;

    -- === STEP 6: Validate investment account ===
    IF p_investment_account_id IS NOT NULL AND p_investment_account_id <> v_existing.investment_account_id THEN
        SELECT currency INTO v_investment_currency
        FROM accounts
        WHERE id = p_investment_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_investment_currency IS NULL THEN
            RAISE EXCEPTION 'New Investment account not found or access denied';
        END IF;
    ELSE
        SELECT currency INTO v_investment_currency
        FROM accounts
        WHERE id = v_existing.investment_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_investment_currency IS NULL THEN
            RAISE EXCEPTION 'Investment account not found or access denied';
        END IF;
    END IF;

    -- === STEP 7: Detect balance-impacting changes ===
    v_balance_changed := (
        (p_funding_account_id IS DISTINCT FROM v_existing.funding_account_id)
        OR (p_investment_account_id IS DISTINCT FROM v_existing.investment_account_id)
        OR (p_amount IS NOT NULL AND p_amount IS DISTINCT FROM v_existing.original_amount)
        OR (p_fees IS NOT NULL AND p_fees IS DISTINCT FROM v_existing.fees)
        OR (v_funding_currency IS DISTINCT FROM v_existing.original_currency)
    );

    -- === STEP 8: Validate exchange rate ===
    v_exchange_rate := get_exchange_rate(v_funding_currency, v_investment_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate for % to %',
            v_funding_currency, v_investment_currency;
    END IF;

    -- === STEP 9: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 10: Reverse balance if needed ===
    IF v_balance_changed THEN
        PERFORM public.reverse_transaction_balance(p_transaction_id, v_existing.type::transaction_type);
    END IF;

    -- === STEP 11: Update transactions table ===
    UPDATE transactions
    SET
        original_amount   = p_amount,
        original_currency = v_funding_currency,
        exchange_rate     = v_exchange_rate,
        converted_amount  = v_converted_amount,
        fees              = p_fees,
        notes             = COALESCE(p_notes, v_existing.notes),
        updated_at        = NOW()
    WHERE id = p_transaction_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Update failed or access denied';
    END IF;

    -- === STEP 12: Update investment-specific details (using COALESCE) ===
    UPDATE transactions_investment
    SET
        funding_account_id    = COALESCE(p_funding_account_id, v_existing.funding_account_id),
        investment_account_id = COALESCE(p_investment_account_id, v_existing.investment_account_id),
        asset_type            = p_asset_type,
        asset_symbol          = p_asset_symbol,
        platform              = p_platform,
        risk_level            = p_risk_level,
        updated_at            = NOW()
    WHERE transaction_id = p_transaction_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Investment update failed or access denied';
    END IF;

    -- === STEP 13: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(p_transaction_id, p_is_recurring, p_params);

    -- === STEP 14: Reapply balance if changed ===
    IF v_balance_changed THEN
        PERFORM public.apply_transaction_balance(
            v_table_name,
            (SELECT i FROM transactions_investment i WHERE i.transaction_id = p_transaction_id)
        );
    END IF;

    -- === STEP 15: Return updated record ===
    SELECT json_build_object(
        'transaction', row_to_json(t),
        'investment', row_to_json(i)
    )
    INTO v_result
    FROM transactions t
    JOIN transactions_investment i ON i.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN json_build_object(
            'error', SQLERRM,
            'transaction_id', p_transaction_id
        );
END;
$$;

-- =========================================
-- 12. Function: update_borrow_transaction
-- =========================================
-- Purpose:
--   Updates an existing borrow transaction, including both the general
--   transaction record and the borrow-specific details, while ensuring
--   proper ownership and balance adjustments.
--
-- Behavior:
--   - Validates transaction ownership or admin privileges.
--   - Checks if key details (loan account, disbursement account, currency,
--     amount, fees) have changed and reverses the previous transaction balance if needed.
--   - Validates ownership of loan and disbursement accounts if changed.
--   - Calculates updated exchange rates and converted amounts.
--   - Updates the main transactions table with new amounts, currency,
--     exchange rates, fees, and notes.
--   - Updates the transactions_borrow table with loan and disbursement account details.
--   - Reapplies the transaction balance if relevant changes occurred.
--   - Returns a JSON object containing the updated transaction and borrow details.
--
-- Parameters:
--   p_transaction_id UUID                       - ID of the transaction to update.
--   p_loan_account_id UUID DEFAULT NULL         - New loan account ID (optional).
--   p_disbursement_account_id UUID DEFAULT NULL - New disbursement account ID (optional).
--   p_amount NUMERIC DEFAULT NULL               - New original amount (optional).
--   p_currency VARCHAR DEFAULT NULL             - New currency code (optional).
--   p_fees NUMERIC DEFAULT NULL                 - New fees amount (optional).
--   p_notes TEXT DEFAULT NULL                   - New notes or description (optional).
--
-- Returns:
--   JSON - Updated transaction and borrow details in JSON format,
--          or an error message if update fails.
--
-- Notes:
--   - SECURITY DEFINER is used to allow controlled access checks.
--   - Includes ownership/admin checks to prevent unauthorized updates.
--   - Reverses and reapplies balances when key fields are modified.
--     for dynamic table access and change detection.
-- =========================================
CREATE OR REPLACE FUNCTION public.update_borrow_transaction(
    p_transaction_id UUID,
    p_loan_account_id UUID,
    p_disbursement_account_id UUID,
    p_amount NUMERIC,
    p_fees NUMERIC DEFAULT 0,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT NULL,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_existing RECORD;
    v_loan_account_currency VARCHAR;
    v_disbursement_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount NUMERIC;
    v_table_name TEXT;
    v_result JSON;
    v_balance_changed BOOLEAN := FALSE;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Fetch existing transaction and ownership check ===
    SELECT t.*, b.loan_account_id, b.disbursement_account_id
    INTO v_existing
    FROM transactions t
    JOIN transactions_borrow b ON b.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found or access denied';
    END IF;

    -- === STEP 3: Validate amount and fees ===
    IF p_amount IS NOT NULL AND p_amount <= 0 THEN
        RAISE EXCEPTION 'Borrow amount must be positive when provided';
    END IF;

    IF p_fees IS NOT NULL AND p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be negative';
    END IF;

    -- === STEP 4: Validate loan account if changed and get currency ===
    IF p_loan_account_id IS NOT NULL AND p_loan_account_id <> v_existing.loan_account_id THEN
        SELECT currency INTO v_loan_account_currency
        FROM accounts
        WHERE id = p_loan_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;

        IF v_loan_account_currency IS NULL THEN
            RAISE EXCEPTION 'New Loan account not found or access denied';
        END IF;
    ELSE
        SELECT currency INTO v_loan_account_currency
        FROM accounts
        WHERE id = v_existing.loan_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;

        IF v_loan_account_currency IS NULL THEN
            RAISE EXCEPTION 'Loan account not found or access denied';
        END IF;
    END IF;

    -- === STEP 5: Validate disbursement account if changed and get currency ===
    IF p_disbursement_account_id IS NOT NULL AND p_disbursement_account_id <> v_existing.disbursement_account_id THEN
        SELECT currency INTO v_disbursement_account_currency
        FROM accounts
        WHERE id = p_disbursement_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;

        IF v_disbursement_account_currency IS NULL THEN
            RAISE EXCEPTION 'New Disbursement account not found or access denied';
        END IF;
    ELSE
        SELECT currency INTO v_disbursement_account_currency
        FROM accounts
        WHERE id = v_existing.disbursement_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;

        IF v_disbursement_account_currency IS NULL THEN
            RAISE EXCEPTION 'Disbursement account not found or access denied';
        END IF;
    END IF;

    -- === STEP 6: Determine transaction table name ===
    v_table_name := public.get_transaction_table_name(v_existing.type::TEXT);

    -- === STEP 7: Detect balance-impacting changes (null-safe) ===
    v_balance_changed := (
        (p_loan_account_id IS DISTINCT FROM v_existing.loan_account_id)
        OR (p_disbursement_account_id IS DISTINCT FROM v_existing.disbursement_account_id)
        OR (p_amount IS NOT NULL AND p_amount IS DISTINCT FROM v_existing.original_amount)
        OR (p_fees IS NOT NULL AND p_fees IS DISTINCT FROM v_existing.fees)
        OR (v_loan_account_currency IS DISTINCT FROM v_existing.original_currency)
    );

    -- === STEP 8: Get exchange rate and validate ===
    v_exchange_rate := get_exchange_rate(v_loan_account_currency, v_disbursement_account_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate from % to %',
            v_loan_account_currency, v_disbursement_account_currency;
    END IF;

    -- === STEP 9: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 10: Reverse balance if needed ===
    IF v_balance_changed THEN
        PERFORM public.reverse_transaction_balance(p_transaction_id, v_existing.type::transaction_type);
    END IF;

    -- === STEP 11: Update transactions table ===
    UPDATE transactions
    SET
        original_amount   = p_amount,
        original_currency = v_loan_account_currency,
        exchange_rate     = v_exchange_rate,
        converted_amount  = v_converted_amount,
        fees              = p_fees,
        notes             = COALESCE(p_notes, v_existing.notes),
        updated_at        = NOW()
    WHERE id = p_transaction_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Update failed or access denied';
    END IF;

    -- === STEP 12: Update borrow-specific details ===
    UPDATE transactions_borrow
    SET
        loan_account_id         = COALESCE(p_loan_account_id, v_existing.loan_account_id),
        disbursement_account_id = COALESCE(p_disbursement_account_id, v_existing.disbursement_account_id),
        updated_at              = NOW()
    WHERE transaction_id = p_transaction_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Borrow update failed or access denied';
    END IF;

    -- === STEP 13: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(p_transaction_id, p_is_recurring, p_params);

    -- === STEP 14: Reapply balance if changed ===
    IF v_balance_changed THEN
        PERFORM public.apply_transaction_balance(
            v_table_name,
            (SELECT b FROM transactions_borrow b WHERE b.transaction_id = p_transaction_id)
        );
    END IF;

    -- === STEP 15: Return updated record ===
    SELECT json_build_object(
        'transaction', row_to_json(t),
        'borrow', row_to_json(b)
    )
    INTO v_result
    FROM transactions t
    JOIN transactions_borrow b ON b.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN json_build_object(
            'error', SQLERRM,
            'transaction_id', p_transaction_id
        );
END;
$$;

-- =========================================
-- 13. Function: update_lend_transaction
-- =========================================
-- Purpose:
--   Updates an existing lend transaction, including both the general
--   transaction record and the lend-specific details, while ensuring
--   proper ownership and balance adjustments.
--
-- Behavior:
--   - Validates transaction ownership or admin privileges.
--   - Checks if key details (funding account, receivable account, currency,
--     amount, fees) have changed and reverses the previous transaction balance if needed.
--   - Validates ownership of funding and receivable accounts if changed.
--   - Calculates updated exchange rates and converted amounts.
--   - Updates the main transactions table with new amounts, currency,
--     exchange rates, fees, and notes.
--   - Updates the transactions_lend table with account IDs, counterparty,
--     interest rate, due date, and collateral details.
--   - Reapplies the transaction balance if relevant changes occurred.
--   - Returns a JSON object containing the updated transaction and lend details.
--
-- Parameters:
--   p_transaction_id UUID                       - ID of the transaction to update.
--   p_funding_account_id UUID DEFAULT NULL      - New funding account ID (optional).
--   p_receivable_account_id UUID DEFAULT NULL   - New receivable account ID (optional).
--   p_amount NUMERIC DEFAULT NULL               - New original amount (optional).
--   p_currency VARCHAR DEFAULT NULL             - New currency code (optional).
--   p_fees NUMERIC DEFAULT NULL                 - New fees amount (optional).
--   p_counterparty_id UUID DEFAULT NULL         - New counterparty ID (optional).
--   p_interest_rate NUMERIC DEFAULT NULL        - New interest rate (optional).
--   p_due_date DATE DEFAULT NULL                - New due date (optional).
--   p_collateral TEXT DEFAULT NULL              - New collateral description (optional).
--   p_notes TEXT DEFAULT NULL                   - New notes or description (optional).
--
-- Returns:
--   JSON - Updated transaction and lend details in JSON format,
--          or an error message if update fails.
--
-- Notes:
--   - SECURITY DEFINER is used to allow controlled access checks.
--   - Includes ownership/admin checks to prevent unauthorized updates.
--   - Reverses and reapplies balances when key fields are modified.
--     for dynamic table access and change detection.
-- =========================================
CREATE OR REPLACE FUNCTION public.update_lend_transaction(
    p_transaction_id UUID,
    p_funding_account_id UUID,
    p_receivable_account_id UUID,
    p_amount NUMERIC,
    p_counterparty_id UUID,
    p_interest_rate NUMERIC,
    p_collateral TEXT,
    p_fees NUMERIC DEFAULT 0,
    p_due_date DATE DEFAULT NULL,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT NULL,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_existing RECORD;
    v_funding_currency VARCHAR;
    v_receivable_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount NUMERIC;
    v_table_name TEXT;
    v_result JSON;
    v_balance_changed BOOLEAN := FALSE;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Fetch existing transaction and ownership check ===
    SELECT t.*, l.funding_account_id, l.receivable_account_id
    INTO v_existing
    FROM transactions t
    JOIN transactions_lend l ON l.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found or access denied';
    END IF;

    -- === STEP 3: Validate amount and fees ===
    IF p_amount IS NOT NULL AND p_amount <= 0 THEN
        RAISE EXCEPTION 'Lend amount must be positive when provided';
    END IF;

    IF p_fees IS NOT NULL AND p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be negative';
    END IF;

    IF p_counterparty_id IS NULL THEN
        RAISE EXCEPTION 'Counterparty ID is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM counterparties
        WHERE id = p_counterparty_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Counterparty not found, deleted, or not accessible';
    END IF;

    IF p_interest_rate IS NULL OR p_interest_rate < 0 THEN
        RAISE EXCEPTION 'Interest rate is required and cannot be negative';
    END IF;

    IF p_collateral IS NULL OR LENGTH(TRIM(p_collateral)) = 0 THEN
        RAISE EXCEPTION 'Collateral is required';
    END IF;

    -- === STEP 4: Determine transaction table name ===
    v_table_name := public.get_transaction_table_name(v_existing.type::TEXT);

    -- === STEP 5: Validate funding account if changed and get currency ===
    IF p_funding_account_id IS NOT NULL AND p_funding_account_id <> v_existing.funding_account_id THEN
        SELECT currency INTO v_funding_currency
        FROM accounts
        WHERE id = p_funding_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;

        IF v_funding_currency IS NULL THEN
            RAISE EXCEPTION 'New Funding account not found or access denied';
        END IF;
    ELSE
        SELECT currency INTO v_funding_currency
        FROM accounts
        WHERE id = v_existing.funding_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;

        IF v_funding_currency IS NULL THEN
            RAISE EXCEPTION 'Funding account not found or access denied';
        END IF;
    END IF;

    -- === STEP 6: Validate receivable account if changed and get currency ===
    IF p_receivable_account_id IS NOT NULL AND p_receivable_account_id <> v_existing.receivable_account_id THEN
        SELECT currency INTO v_receivable_currency
        FROM accounts
        WHERE id = p_receivable_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;

        IF v_receivable_currency IS NULL THEN
            RAISE EXCEPTION 'New Receivable account not found or access denied';
        END IF;
    ELSE
        SELECT currency INTO v_receivable_currency
        FROM accounts
        WHERE id = v_existing.receivable_account_id
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;

        IF v_receivable_currency IS NULL THEN
            RAISE EXCEPTION 'Receivable account not found or access denied';
        END IF;
    END IF;

    -- === STEP 7: Detect balance-impacting changes (null-safe) ===
    v_balance_changed := (
        (p_funding_account_id IS DISTINCT FROM v_existing.funding_account_id)
        OR (p_receivable_account_id IS DISTINCT FROM v_existing.receivable_account_id)
        OR (p_amount IS NOT NULL AND p_amount IS DISTINCT FROM v_existing.original_amount)
        OR (p_fees IS NOT NULL AND p_fees IS DISTINCT FROM v_existing.fees)
        OR (v_funding_currency IS DISTINCT FROM v_existing.original_currency)
    );

    -- === STEP 8: Get exchange rate and validate ===
    v_exchange_rate := get_exchange_rate(v_funding_currency, v_receivable_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate from % to %',
            v_funding_currency, v_receivable_currency;
    END IF;

    -- === STEP 9: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 10: Reverse previous balance if needed ===
    IF v_balance_changed THEN
        PERFORM public.reverse_transaction_balance(p_transaction_id, v_existing.type::transaction_type);
    END IF;

    -- === STEP 11: Update transactions table ===
    UPDATE transactions
    SET
        original_amount   = p_amount,
        original_currency = v_funding_currency,
        exchange_rate     = v_exchange_rate,
        converted_amount  = v_converted_amount,
        fees              = p_fees,
        notes             = COALESCE(p_notes, v_existing.notes),
        updated_at        = NOW()
    WHERE id = p_transaction_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Update failed or access denied';
    END IF;

    -- === STEP 12: Update lend-specific details (using COALESCE) ===
    UPDATE transactions_lend
    SET
        funding_account_id    = COALESCE(p_funding_account_id, v_existing.funding_account_id),
        receivable_account_id = COALESCE(p_receivable_account_id, v_existing.receivable_account_id),
        counterparty_id       = p_counterparty_id,
        interest_rate         = p_interest_rate,
        due_date              = p_due_date,
        collateral            = p_collateral,
        updated_at            = NOW()
    WHERE transaction_id = p_transaction_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Lend update failed or access denied';
    END IF;

    -- === STEP 13: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(p_transaction_id, p_is_recurring, p_params);

    -- === STEP 14: Reapply balance if changed ===
    IF v_balance_changed THEN
        PERFORM public.apply_transaction_balance(
            v_table_name,
            (SELECT l FROM transactions_lend l WHERE l.transaction_id = p_transaction_id)
        );
    END IF;

    -- === STEP 15: Return updated record ===
    SELECT json_build_object(
        'transaction', row_to_json(t),
        'lend', row_to_json(l)
    )
    INTO v_result
    FROM transactions t
    JOIN transactions_lend l ON l.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN json_build_object(
            'error', SQLERRM,
            'transaction_id', p_transaction_id
        );
END;
$$;

-- =========================================
-- 14. Function: update_transfer_transaction
-- =========================================
-- Purpose:
--   Updates an existing transfer transaction, including both the general
--   transaction record and the transfer-specific details, while ensuring
--   proper ownership and balance adjustments.
--
-- Behavior:
--   - Validates transaction ownership or admin privileges.
--   - Checks if key details (from account, to account, currency, amount,
--     fees) have changed and reverses the previous transaction balance if needed.
--   - Validates ownership of from and to accounts if changed.
--   - Calculates updated exchange rates and converted amounts.
--   - Updates the main transactions table with new amounts, currency,
--     exchange rates, fees, and notes.
--   - Updates the transactions_transfer table with account IDs and transfer method.
--   - Reapplies the transaction balance if relevant changes occurred.
--   - Returns a JSON object containing the updated transaction and transfer details.
--
-- Parameters:
--   p_transaction_id UUID            - ID of the transaction to update.
--   p_from_account UUID DEFAULT NULL - New from account ID (optional).
--   p_to_account UUID DEFAULT NULL   - New to account ID (optional).
--   p_amount NUMERIC DEFAULT NULL    - New original amount (optional).
--   p_currency VARCHAR DEFAULT NULL  - New currency code (optional).
--   p_fees NUMERIC DEFAULT NULL      - New fees amount (optional).
--   p_transfer_method transfer_method DEFAULT NULL - New transfer method (optional).
--   p_notes TEXT DEFAULT NULL        - New notes or description (optional).
--
-- Returns:
--   JSON - Updated transaction and transfer details in JSON format,
--          or an error message if update fails.
--
-- Notes:
--   - SECURITY DEFINER is used to allow controlled access checks.
--   - Includes ownership/admin checks to prevent unauthorized updates.
--   - Reverses and reapplies balances when key fields are modified.
--     for dynamic table access and change detection.
-- =========================================
CREATE OR REPLACE FUNCTION public.update_transfer_transaction(
    p_transaction_id UUID,
    p_from_account UUID,
    p_to_account UUID,
    p_amount NUMERIC,
    p_transfer_method transfer_method,
    p_fees NUMERIC DEFAULT 0,
    p_notes TEXT DEFAULT NULL,
    p_is_recurring BOOLEAN DEFAULT NULL,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_is_admin BOOLEAN;
    v_existing RECORD;
    v_from_currency VARCHAR;
    v_to_currency VARCHAR;
    v_exchange_rate NUMERIC;
    v_converted_amount NUMERIC;
    v_table_name TEXT;
    v_result JSON;
    v_balance_changed BOOLEAN := FALSE;
BEGIN
    -- === STEP 1: Validate user ===
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    v_is_admin := public.check_admin_permissions();

    -- === STEP 2: Fetch existing transaction and validate access ===
    SELECT t.*, tr.from_account, tr.to_account
    INTO v_existing
    FROM transactions t
    JOIN transactions_transfer tr ON tr.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found or access denied';
    END IF;

    -- === STEP 3: Basic validations ===
    IF p_amount IS NOT NULL AND p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive when provided';
    END IF;

    IF p_fees IS NOT NULL AND p_fees < 0 THEN
        RAISE EXCEPTION 'Fees cannot be negative';
    END IF;

    IF p_transfer_method IS NULL THEN
        RAISE EXCEPTION 'Transfer method is required';
    END IF;

    -- Optional: explicit check against enum values (extra safety)
    IF NOT EXISTS (
        SELECT 1
        FROM unnest(enum_range(NULL::transfer_method)) AS m(val)
        WHERE val = p_transfer_method
    ) THEN
        RAISE EXCEPTION 'Invalid transfer method: %', p_transfer_method;
    END IF;

    -- Prevent self-transfer
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'Cannot transfer to the same account';
    END IF;

    -- === STEP 4: Determine transaction table name ===
    v_table_name := public.get_transaction_table_name(v_existing.type::TEXT);

    -- === STEP 5: Validate from_account if changed and get currency ===
    IF p_from_account IS NOT NULL AND p_from_account <> v_existing.from_account THEN
        SELECT currency INTO v_from_currency
        FROM accounts
        WHERE id = p_from_account
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_from_currency IS NULL THEN
            RAISE EXCEPTION 'New From account not found or access denied';
        END IF;
    ELSE
        SELECT currency INTO v_from_currency
        FROM accounts
        WHERE id = v_existing.from_account
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_from_currency IS NULL THEN
            RAISE EXCEPTION 'From account not found or access denied';
        END IF;
    END IF;

    -- === STEP 6: Validate to_account if changed and get currency ===
    IF p_to_account IS NOT NULL AND p_to_account <> v_existing.to_account THEN
        SELECT currency INTO v_to_currency
        FROM accounts
        WHERE id = p_to_account
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_to_currency IS NULL THEN
            RAISE EXCEPTION 'New To account not found or access denied';
        END IF;
    ELSE
        SELECT currency INTO v_to_currency
        FROM accounts
        WHERE id = v_existing.to_account
          AND (user_id = v_user_id OR v_is_admin)
          AND deleted_at IS NULL;
        IF v_to_currency IS NULL THEN
            RAISE EXCEPTION 'To account not found or access denied';
        END IF;
    END IF;

    -- === STEP 7: Detect balance-impacting changes (null-safe) ===
    v_balance_changed := (
        (p_from_account IS DISTINCT FROM v_existing.from_account)
        OR (p_to_account IS DISTINCT FROM v_existing.to_account)
        OR (p_amount IS NOT NULL AND p_amount IS DISTINCT FROM v_existing.original_amount)
        OR (p_fees IS NOT NULL AND p_fees IS DISTINCT FROM v_existing.fees)
        OR (v_from_currency IS DISTINCT FROM v_existing.original_currency)
    );

    -- === STEP 8: Get exchange rate and validate ===
    v_exchange_rate := get_exchange_rate(v_from_currency, v_to_currency);
    IF v_exchange_rate IS NULL OR v_exchange_rate <= 0 THEN
        RAISE EXCEPTION 'Invalid or missing exchange rate from % to %',
            v_from_currency, v_to_currency;
    END IF;

    -- === STEP 9: Calculate converted amount ===
    v_converted_amount := p_amount * v_exchange_rate;

    -- === STEP 10: Reverse previous balance if needed ===
    IF v_balance_changed THEN
        PERFORM public.reverse_transaction_balance(p_transaction_id, v_existing.type::transaction_type);
    END IF;

    -- === STEP 11: Update transactions table ===
    UPDATE transactions
    SET
        original_amount   = p_amount,
        original_currency = v_from_currency,
        exchange_rate     = v_exchange_rate,
        converted_amount  = v_converted_amount,
        fees              = p_fees,
        notes             = COALESCE(p_notes, v_existing.notes),
        updated_at        = NOW()
    WHERE id = p_transaction_id
      AND (user_id = v_user_id OR v_is_admin)
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Update failed or access denied';
    END IF;

    -- === STEP 12: Update transfer-specific details (using COALESCE) ===
    UPDATE transactions_transfer
    SET
        from_account    = COALESCE(p_from_account, v_existing.from_account),
        to_account      = COALESCE(p_to_account, v_existing.to_account),
        transfer_method = p_transfer_method,
        updated_at      = NOW()
    WHERE transaction_id = p_transaction_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transfer update failed or access denied';
    END IF;

    -- === STEP 13: Handle recurring logic ===
    PERFORM public.handle_recurring_transaction(p_transaction_id, p_is_recurring, p_params);

    -- === STEP 14: Reapply balance if changed ===
    IF v_balance_changed THEN
        PERFORM public.apply_transaction_balance(
            v_table_name,
            (SELECT tr FROM transactions_transfer tr WHERE tr.transaction_id = p_transaction_id)
        );
    END IF;

    -- === STEP 15: Return updated record ===
    SELECT json_build_object(
        'transaction', row_to_json(t),
        'transfer', row_to_json(tr)
    )
    INTO v_result
    FROM transactions t
    JOIN transactions_transfer tr ON tr.transaction_id = t.id
    WHERE t.id = p_transaction_id
      AND (t.user_id = v_user_id OR v_is_admin)
      AND t.deleted_at IS NULL;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN json_build_object(
            'error', SQLERRM,
            'transaction_id', p_transaction_id
        );
END;
$$;

-- =========================================
--  15. Function: handle_recurring_transaction
-- =========================================
-- Purpose:
--   Centralized logic to handle recurring transaction creation.
--
-- Parameters:
--   - p_transaction_id: ID of the main transaction
--   - p_is_recurring: whether this transaction is recurring
--   - p_params: JSONB containing recurrence details
--
-- Expected JSON keys in p_params:
--   frequency, interval, start_date, end_date
-- =========================================
CREATE OR REPLACE FUNCTION public.handle_recurring_transaction(
    p_transaction_id UUID,
    p_is_recurring BOOLEAN,
    p_params JSONB DEFAULT '{}'::JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_exists BOOLEAN;
    v_frequency  recurrence_frequency;
    v_interval   INT;
    v_start_date DATE;
    v_end_date   DATE;
BEGIN

    -- Exit if no change
    IF p_is_recurring IS NULL THEN
        RAISE EXCEPTION 'Recurring status is required.';
    END IF;

     -- Simple recurring parameters validation
    IF p_is_recurring THEN
        IF p_params IS NULL OR jsonb_typeof(p_params) <> 'object' THEN
            RAISE EXCEPTION 'Recurring parameters must be a valid JSON object';
        END IF;

        IF NOT p_params ? 'frequency' OR length(trim(p_params ->> 'frequency')) = 0 THEN
            RAISE EXCEPTION 'Recurring transaction must include a non-empty frequency parameter';
        END IF;

        -- Validate frequency value
        IF NOT (p_params ->> 'frequency')::text = ANY (ARRAY['daily','weekly','monthly','yearly']) THEN
            RAISE EXCEPTION 'Invalid frequency value: %, allowed values are daily, weekly, monthly, yearly', p_params ->> 'frequency';
        END IF;
    END IF;

    -- Check if recurring record exists
    SELECT EXISTS (
        SELECT 1 FROM transactions_recurring
        WHERE transaction_template_id = p_transaction_id
          AND deleted_at IS NULL
    )
    INTO v_exists;

    -- Case 1: Marked as recurring
    IF p_is_recurring THEN
        v_frequency  := (p_params ->> 'frequency')::recurrence_frequency;
        v_interval   := COALESCE((p_params ->> 'interval')::INT, 1);
        v_start_date := COALESCE((p_params ->> 'start_date')::DATE, CURRENT_DATE);
        v_end_date   := (p_params ->> 'end_date')::DATE;

        IF v_exists THEN
            PERFORM public.update_recurring_transaction(
                p_transaction_id,
                v_frequency,
                v_interval,
                v_start_date,
                v_end_date
            );
        ELSE
            PERFORM public.create_recurring_transaction(
                p_transaction_id,
                v_frequency,
                v_interval,
                v_start_date,
                v_end_date
            );
        END IF;
    
    -- Case 2: Marked as non-recurring
    ELSE
        IF v_exists THEN
            PERFORM public.soft_delete_recurring_transaction(p_transaction_id);
        END IF;
    END IF;
END;
$$;

-- =========================================
-- 16. Function: create_recurring_transaction
-- =========================================
-- Purpose:
--   Registers an existing transaction as a recurring template by
--   creating an entry in `transactions_recurring` and marking the
--   original transaction as recurring.
--
-- Behavior:
--   - Retrieves the current authenticated user (RLS-validated)
--   - Validates that the specified transaction:
--       * Exists
--       * Belongs to the authenticated user
--       * Is not soft-deleted (deleted_at IS NULL)
--   - Updates the original transaction to set is_recurring = TRUE
--   - Inserts a new recurring definition record with:
--       * transaction_template_id
--       * frequency, interval, start_date, end_date
--       * next_occurrence
--       * user_id and action_by for audit tracking
--       * created_at and updated_at timestamps
--   - Returns the UUID of the newly created recurring entry
--
-- Parameters:
--   p_transaction_id UUID              - ID of the existing transaction to make recurring
--   p_frequency recurrence_frequency   - Frequency of recurrence ('daily', 'weekly', etc.)
--   p_interval INT                     - Interval between occurrences (default: 1)
--   p_start_date DATE                  - Start date of recurrence (default: CURRENT_DATE)
--   p_end_date DATE                    - Optional end date for the recurrence
--
-- Returns:
--   UUID - ID of the new recurring transaction record
--
-- Notes:
--   - Skips processing if the transaction is deleted or not owned by the user.
--   - SECURITY DEFINER allows controlled elevation while preserving data integrity.
--   - Does not immediately generate new transactions; only defines the recurrence.
-- =========================================
CREATE OR REPLACE FUNCTION public.create_recurring_transaction(
    p_transaction_id UUID,                  -- 'income', 'expense', 'investment', etc.
    p_frequency recurrence_frequency,         -- how often it recurs (daily, weekly, monthly, etc.)
    p_interval INT DEFAULT 1,                 -- interval multiplier (e.g., every 2 weeks)
    p_start_date DATE DEFAULT CURRENT_DATE,   -- start of recurrence
    p_end_date DATE DEFAULT NULL              -- optional end of recurrence
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_recurring_id UUID;
    v_user_id UUID := auth.uid();
BEGIN
    -- Validate user context
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    -- Validate transaction ownership and non-deletion
    IF NOT EXISTS (
        SELECT 1
        FROM transactions t
        WHERE t.id = p_transaction_id
          AND t.user_id = v_user_id
          AND t.deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Transaction % not found, deleted, or not owned by user', p_transaction_id;
    END IF;

    -- Mark transaction as recurring
    UPDATE transactions
    SET is_recurring = TRUE,
        updated_at = now()
    WHERE id = p_transaction_id
      AND deleted_at IS NULL;

    -- Insert recurrence entry
    INSERT INTO transactions_recurring (
        transaction_template_id,
        frequency,
        interval,
        start_date,
        end_date,
        next_occurrence,
        user_id,
        action_by,
        created_at,
        updated_at
    )
    VALUES (
        p_transaction_id,
        p_frequency,
        p_interval,
        p_start_date,
        p_end_date,
        p_start_date,
        v_user_id,
        v_user_id,
        now(),
        now()
    )
    RETURNING id INTO v_recurring_id;

    -- Return new recurring record ID
    RETURN v_recurring_id;
END;
$$;

-- =========================================
-- 17. Function: update_recurring_transaction
-- =========================================
-- Purpose:
--   Updates the recurrence metadata of an existing recurring transaction,
--   including frequency, interval, start date, and end date, while ensuring
--   proper ownership and consistency.
--
-- Behavior:
--   - Validates recurring transaction ownership or admin privileges.
--   - Updates recurrence schedule fields in the `transactions_recurring` table.
--   - Returns a JSON object containing the updated recurring transaction details.
--
-- Parameters:
--   p_recurring_id UUID                        - ID of the transaction template linked to
--                                                  the recurring transaction.
--   p_frequency recurrence_frequency DEFAULT NULL - New recurrence frequency (optional).
--   p_interval INT DEFAULT NULL                - New recurrence interval (optional).
--   p_start_date DATE DEFAULT NULL             - New start date (optional).
--   p_end_date DATE DEFAULT NULL               - New end date (optional).
--
-- Returns:
--   JSON - Contains updated recurring transaction details and template transaction ID,
--          or an error message if the update fails.
--
-- Notes:
--   - SECURITY DEFINER is used to allow controlled access checks.
--   - Includes ownership/admin checks to prevent unauthorized updates.
-- =========================================
CREATE OR REPLACE FUNCTION public.update_recurring_transaction(
    p_transaction_id UUID,
    p_frequency recurrence_frequency DEFAULT NULL,
    p_interval INT DEFAULT NULL,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_is_admin BOOLEAN := public.check_admin_permissions();
    v_result JSON;
BEGIN
    -- === STEP 1: Validate recurring transaction ownership/admin ===
    PERFORM 1
    FROM transactions_recurring r
    JOIN transactions t ON t.id = r.transaction_template_id
    WHERE r.transaction_template_id = p_transaction_id
    AND (r.user_id = v_user_id OR v_is_admin)
    AND t.deleted_at IS NULL
    AND r.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring transaction not found or access denied';
    END IF;

    -- === STEP 2: Update recurring metadata ===
    UPDATE transactions_recurring r
    SET
        frequency  = COALESCE(p_frequency, r.frequency),
        interval   = COALESCE(p_interval, r.interval),
        start_date = COALESCE(p_start_date, r.start_date),
        end_date   = COALESCE(p_end_date, r.end_date),
        updated_at = NOW()
    WHERE r.transaction_template_id = p_transaction_id
      AND (r.user_id = v_user_id OR v_is_admin)
      AND r.deleted_at IS NULL
    RETURNING row_to_json(r) INTO v_result;

    -- === STEP 3: Return result ===
    RETURN json_build_object(
        'recurring', v_result,
        'template_transaction_id', p_transaction_id
    );

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error updating recurring transaction: %', SQLERRM;
        RETURN json_build_object(
            'error', SQLERRM,
            'transaction_id', p_transaction_id
        );
END;
$$;

-- =========================================
-- 18. Function: soft_delete_recurring_transaction
-- =========================================
-- Purpose:
--   Performs a soft delete of a recurring transaction by marking it as deleted
--   without physically removing it from the database. Ensures proper ownership
--   and administrative privileges before performing the deletion.
--
-- Behavior:
--   - Validates recurring transaction ownership or admin privileges.
--   - Sets the `deleted_at` timestamp to indicate a soft deletion.
--   - Returns a JSON object containing the deleted recurring transaction details.
--
-- Parameters:
--   p_recurring_id UUID - ID of the recurring transaction to soft delete.
--
-- Returns:
--   JSON - Contains details of the deleted recurring transaction and its
--          associated template transaction ID, or an error message if deletion fails.
--
-- Notes:
--   - SECURITY DEFINER is used to allow controlled access checks.
--   - Includes ownership/admin checks to prevent unauthorized deletions.
--   - Maintains data integrity by not physically removing records.
-- =========================================
CREATE OR REPLACE FUNCTION public.soft_delete_recurring_transaction( 
    p_transaction_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_is_admin BOOLEAN := public.check_admin_permissions();
    v_result JSON;
BEGIN
    -- === STEP 1: Validate recurring transaction ownership/admin ===
    PERFORM 1
    FROM transactions_recurring r
    JOIN transactions t ON t.id = r.transaction_template_id
    WHERE r.transaction_template_id = p_transaction_id
    AND (r.user_id = v_user_id OR v_is_admin)
    AND t.deleted_at IS NULL
    AND r.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring transaction not found or access denied';
    END IF;

    -- === STEP 2: Soft delete recurring transaction ===
    UPDATE transactions_recurring r
    SET 
        deleted_at = NOW(),
        updated_at = NOW()
    WHERE r.transaction_template_id = p_transaction_id
    AND (r.user_id = v_user_id OR v_is_admin)
    AND r.deleted_at IS NULL
    RETURNING row_to_json(r) INTO v_result;

    -- === STEP 3: Mark base transaction as non-recurring ===
    UPDATE transactions
    SET 
        is_recurring = FALSE,
        updated_at = NOW()
    WHERE id = p_transaction_id
      AND deleted_at IS NULL;

    -- === STEP 4: Return result ===
    RETURN json_build_object(
        'deleted_recurring', v_result,
        'template_transaction_id', p_transaction_id
    );

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error deleting recurring transaction: %', SQLERRM;
        RETURN json_build_object(
            'error', SQLERRM,
            'transaction_id', p_transaction_id
        );
END;
$$;

-- =========================================
-- 20. Function: get_transaction_table_name
-- =========================================
-- Purpose:
--   Maps a given transaction type string to the corresponding transaction
--   table name in the database. This allows generic functions and triggers
--   to determine the correct table to operate on based on transaction type.
--
-- Behavior:
--   - Takes a transaction type as input.
--   - Normalizes the input by trimming spaces and converting to lowercase.
--   - Returns the corresponding table name for the transaction type:
--       * 'income'      → transactions_income
--       * 'expense'     → transactions_expense
--       * 'investment'  → transactions_investment
--       * 'borrow'      → transactions_borrow
--       * 'lend'        → transactions_lend
--       * 'transfer'    → transactions_transfer
--       * 'adjustment'  → transactions_adjustment
--   - Raises an exception if the transaction type is unrecognized, with a hint
--     showing valid transaction types.
--
-- Parameters:
--   p_transaction_type TEXT - The transaction type to map.
--
-- Returns:
--   TEXT - The name of the transaction table corresponding to the given type.
--
-- Notes:
--   - Marked IMMUTABLE because it returns the same result for the same input.
--   - SECURITY INVOKER ensures function runs with privileges of the caller.
--   - Used in dynamic SQL contexts where transaction type determines table name.
-- =========================================
CREATE OR REPLACE FUNCTION public.get_transaction_table_name(
    p_transaction_type TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
    CASE LOWER(TRIM(p_transaction_type))
        WHEN 'income' THEN
            RETURN 'transactions_income';
        WHEN 'expense' THEN
            RETURN 'transactions_expense';
        WHEN 'investment' THEN
            RETURN 'transactions_investment';
        WHEN 'borrow' THEN
            RETURN 'transactions_borrow';
        WHEN 'lend' THEN
            RETURN 'transactions_lend';
        WHEN 'transfer' THEN
            RETURN 'transactions_transfer';
        WHEN 'adjustment' THEN
            RETURN 'transactions_adjustment';
        ELSE
            RAISE EXCEPTION 'Unknown transaction type: %', p_transaction_type
                USING HINT = 'Expected one of: income, expense, investment, borrow, lend, transfer, adjustment.';
    END CASE;
END;
$$;

-- =========================================
-- 21. Function: validate_transaction_ownership
-- =========================================
-- Purpose:
--   Checks whether a given transaction belongs to a specific user and is not soft deleted.
--
-- Behavior:
--   - Uses COALESCE to determine the effective user ID:
--       * If p_user_id is provided, uses that.
--       * Otherwise, uses the current session's authenticated user ID (auth.uid()).
--   - Queries the transactions table to verify:
--       * The transaction exists with the given ID.
--       * The transaction belongs to the determined user.
--       * The transaction is not soft deleted (deleted_at IS NULL).
--   - Returns a BOOLEAN indicating ownership status.
--
-- Returns:
--   BOOLEAN - TRUE if the transaction exists, belongs to the user, and is not deleted;
--             FALSE otherwise.
--
-- Notes:
--   - SECURITY INVOKER ensures this function runs with the privileges of the caller.
--   - Useful as a shared helper function to enforce row-level ownership checks
--     before performing sensitive operations like updates or deletes.
-- =========================================
CREATE OR REPLACE FUNCTION public.validate_transaction_ownership(
    p_transaction_id UUID,
    p_user_id UUID DEFAULT NULL
)
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
        SELECT 1 FROM transactions t
        WHERE t.id = p_transaction_id
          AND t.user_id = v_user_id
          AND t.deleted_at IS NULL
    ) INTO v_exists;

    RETURN v_exists;
END;
$$;

-- =========================================
-- 22. Function: soft_delete_transaction
-- =========================================
-- Purpose:
--   Performs a soft delete of a transaction, ensuring that only the transaction owner
--   or an administrator can delete it. Returns a descriptive text message indicating
--   the result of the operation.
--
-- Behavior:
--   - Retrieves the current user's ID from session context (auth.uid()).
--   - Checks if the transaction exists and determines whether it is already soft deleted.
--   - Checks if the current user has ownership of the transaction or has admin rights.
--   - If ownership or admin rights are confirmed, performs a soft delete by updating
--     the deleted_at and updated_at timestamps.
--   - Returns a clear text result indicating success, already deleted status, or raises
--     a permission or error exception.
--
-- Returns:
--   TEXT - Possible values:
--       * 'Transaction (%) deleted successfully'
--       * 'Transaction (%) is already deleted'
--       * Raises an exception if permission denied, transaction not found, or an error occurs.
--
-- Notes:
--   - SECURITY DEFINER ensures this function executes with elevated privileges, allowing
--     admin overrides while still enforcing ownership rules.
--   - Uses public.check_admin_permissions() to determine if the current user is an admin.
--   - Designed for safe deletion with explicit ownership/admin checks and clear feedback.
-- =========================================
CREATE OR REPLACE FUNCTION public.soft_delete_transaction(p_transaction_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_deleted_at TIMESTAMP;
    v_updated BOOLEAN;
    v_is_admin BOOLEAN := public.check_admin_permissions();
BEGIN
    -- Check if transaction exists and its deleted_at
    SELECT deleted_at
    INTO v_deleted_at
    FROM public.transactions
    WHERE id = p_transaction_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction (%s) does not exist', p_transaction_id
            USING ERRCODE = 'P0001';
    END IF;

    -- If already soft deleted
    IF v_deleted_at IS NOT NULL THEN
        RETURN format('Transaction (%s) is already deleted', p_transaction_id);
    END IF;

    -- Validate ownership OR admin rights
    IF NOT v_is_admin AND NOT public.validate_transaction_ownership(p_transaction_id, v_user_id) THEN
        RAISE EXCEPTION 'Permission denied: user (%s) is not authorized to delete transaction (%s).',
            v_user_id, p_transaction_id
            USING ERRCODE = '42501';
    END IF;

    -- Perform soft delete
    UPDATE public.transactions
    SET deleted_at = NOW(),
        updated_at = NOW()
    WHERE id = p_transaction_id
      AND deleted_at IS NULL
    RETURNING TRUE INTO v_updated;

    -- Double check for race condition
    IF NOT FOUND THEN
        RETURN format('Transaction (%s) is already deleted', p_transaction_id);
    END IF;

    -- Successful deletion
    RETURN format('Transaction (%s) deleted successfully', p_transaction_id);

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Duplicate transaction ID (%s) detected during soft delete.', p_transaction_id;
    WHEN data_exception THEN
        RAISE EXCEPTION 'Invalid data encountered while soft deleting transaction (%s): %s', p_transaction_id, SQLERRM;
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Unexpected error during soft delete of transaction (%s): %s', p_transaction_id, SQLERRM;
END;
$$;

-- =========================================
-- 23. Function: hard_delete_transaction
-- =========================================
-- Purpose:
--   Permanently deletes a transaction and all related specialized detail records,
--   ensuring that only administrators can perform this action on transactions
--   that have already been soft deleted.
--
-- Behavior:
--   - Retrieves the current user's ID from session context (auth.uid()).
--   - Verifies the user is authenticated.
--   - Checks if the current user has administrative privileges via
--     public.check_admin_permissions().
--   - Confirms that the specified transaction exists and has been soft deleted
--     (deleted_at IS NOT NULL).
--   - Enables a session-level hard delete bypass flag (app.hard_delete = 'on').
--   - Deletes all related records from specialized transaction detail tables
--     (income, expense, investment, borrow, lend, transfer, adjustment)
--     where the record is also soft deleted.
--   - Deletes related recurring transactions that reference the transaction.
--   - Deletes the transaction record itself.
--   - Handles exceptions gracefully, returning FALSE and logging a exception
--     if deletion fails.
--
-- Returns:
--   BOOLEAN
--       * TRUE  - if all deletions succeed.
--       * FALSE - if any deletion fails or an exception occurs.
--
-- Notes:
--   - SECURITY DEFINER ensures this function runs with elevated privileges,
--     allowing admin overrides while still enforcing RLS rules.
--   - Strictly enforces that only admins can perform hard deletes,
--     and only on already soft-deleted transactions.
--   - Designed for complete cleanup of transaction data in compliance
--     with row-level security policies and application rules.
-- =========================================
CREATE OR REPLACE FUNCTION public.hard_delete_transaction(p_transaction_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    current_user_id UUID;
    tx_type transaction_type;
    is_admin BOOLEAN;
BEGIN
    -- 1. Authenticate user
    current_user_id := auth.uid();
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- 2. Check admin privileges
    is_admin := public.check_admin_permissions();
    IF NOT is_admin THEN
        RAISE EXCEPTION 'Permission denied: only admins can hard delete';
    END IF;

    -- 3. Enable hard delete bypass for this session
    PERFORM set_config('app.hard_delete', 'on', true);

    -- 4. Get transaction type and ensure transaction exists and is soft deleted
    SELECT type INTO tx_type
    FROM public.transactions
    WHERE id = p_transaction_id AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found or not soft deleted';
    END IF;

    -- 5. Wrap deletion in an atomic block with exception handling
    BEGIN
        -- 5a. Delete specialized transaction detail records if they are soft deleted
        CASE tx_type
            WHEN 'income' THEN
                DELETE FROM public.transactions_income
                WHERE transaction_id = p_transaction_id AND deleted_at IS NOT NULL;

            WHEN 'expense' THEN
                DELETE FROM public.transactions_expense
                WHERE transaction_id = p_transaction_id AND deleted_at IS NOT NULL;

            WHEN 'investment' THEN
                DELETE FROM public.transactions_investment
                WHERE transaction_id = p_transaction_id AND deleted_at IS NOT NULL;

            WHEN 'borrow' THEN
                DELETE FROM public.transactions_borrow
                WHERE transaction_id = p_transaction_id AND deleted_at IS NOT NULL;

            WHEN 'lend' THEN
                DELETE FROM public.transactions_lend
                WHERE transaction_id = p_transaction_id AND deleted_at IS NOT NULL;

            WHEN 'transfer' THEN
                DELETE FROM public.transactions_transfer
                WHERE transaction_id = p_transaction_id AND deleted_at IS NOT NULL;

            WHEN 'adjustment' THEN
                DELETE FROM public.transactions_adjustment
                WHERE transaction_id = p_transaction_id AND deleted_at IS NOT NULL;

            ELSE
                RAISE EXCEPTION 'Unknown transaction type %, skipping specialized deletion', tx_type;
        END CASE;

        -- 5b. Delete related recurring transactions
        DELETE FROM public.transactions_recurring
        WHERE transaction_template_id = p_transaction_id AND deleted_at IS NOT NULL;

        -- 5c. Delete transaction record itself
        DELETE FROM public.transactions
        WHERE id = p_transaction_id AND deleted_at IS NOT NULL;

        RETURN TRUE;

    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Hard delete failed for transaction %, error: %', p_transaction_id, SQLERRM;
        RETURN FALSE;
    END;
END;
$$;

-- =========================================
-- 17. Function: compute_transaction_direction
-- =========================================
-- Get Transaction Direction
-- Purpose: Compute transaction direction based on type and amount
-- Parameters: transaction_type, amount
-- Returns: transaction_direction enum
-- Security: INVOKER (pure computation)
-- RLS: N/A (no data access)
CREATE OR REPLACE FUNCTION compute_transaction_direction(
    p_type transaction_type, 
    p_original_amount DECIMAL
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
        WHEN p_type = 'borrow' AND p_original_amount >= 0 THEN 'inflow'::transaction_direction
        WHEN p_type = 'borrow' AND p_original_amount < 0 THEN 'outflow'::transaction_direction
        WHEN p_type = 'lend' AND p_original_amount >= 0 THEN 'outflow'::transaction_direction
        WHEN p_type = 'lend' AND p_original_amount < 0 THEN 'inflow'::transaction_direction
        WHEN p_type = 'investment' AND p_original_amount >= 0 THEN 'outflow'::transaction_direction
        WHEN p_type = 'investment' AND p_original_amount < 0 THEN 'inflow'::transaction_direction
        WHEN p_type = 'adjustment' AND p_original_amount >= 0 THEN 'inflow'::transaction_direction
        WHEN p_type = 'adjustment' AND p_original_amount < 0 THEN 'outflow'::transaction_direction
        WHEN p_type = 'transfer' THEN 'neutral'::transaction_direction
        ELSE 'unknown'::transaction_direction
    END;
$$;

-- =========================================
-- 09. Function: get_recent_transactions
-- =========================================
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
    original_amount DECIMAL(36,18),
    original_currency VARCHAR(10),
    converted_amount DECIMAL(36,18),
    converted_currency VARCHAR(10),
    exchange_rate DECIMAL(36,18),
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
        t.original_amount,
        t.original_currency,
        t.converted_amount,
        t.currency AS converted_currency,
        t.exchange_rate,
        t.created_at AS transaction_date,
        COALESCE(
            (SELECT a.account_name 
             FROM accounts a 
             JOIN transactions_income ti ON a.id = ti.account_id 
             WHERE ti.transaction_id = t.id 
               AND a.user_id = v_current_user 
               AND a.deleted_at IS NULL),
            (SELECT a.account_name 
             FROM accounts a 
             JOIN transactions_expense te ON a.id = te.account_id 
             WHERE te.transaction_id = t.id 
               AND a.user_id = v_current_user 
               AND a.deleted_at IS NULL),
            (SELECT a.account_name 
             FROM accounts a 
             JOIN transactions_investment tinv ON a.id = tinv.funding_account_id 
             WHERE tinv.transaction_id = t.id 
               AND a.user_id = v_current_user 
               AND a.deleted_at IS NULL),
            (SELECT a.account_name 
             FROM accounts a 
             JOIN transactions_adjustment tadj ON a.id = tadj.account_id 
             WHERE tadj.transaction_id = t.id 
               AND a.user_id = v_current_user 
               AND a.deleted_at IS NULL),
            (SELECT a.account_name 
             FROM accounts a 
             JOIN transactions_borrow tb ON a.id = tb.disbursement_account_id 
             WHERE tb.transaction_id = t.id 
               AND a.user_id = v_current_user 
               AND a.deleted_at IS NULL),
            (SELECT a.account_name 
             FROM accounts a 
             JOIN transactions_lend tl ON a.id = tl.funding_account_id 
             WHERE tl.transaction_id = t.id 
               AND a.user_id = v_current_user 
               AND a.deleted_at IS NULL),
            (SELECT CONCAT(af.account_name, ' → ', at.account_name) 
             FROM accounts af, accounts at, transactions_transfer tt 
             WHERE tt.transaction_id = t.id 
               AND af.id = tt.from_account 
               AND at.id = tt.to_account 
               AND af.user_id = v_current_user 
               AND at.user_id = v_current_user
               AND af.deleted_at IS NULL 
               AND at.deleted_at IS NULL)
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
-- 10. Function: get_user_transactions
-- =========================================
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
    original_amount DECIMAL(36,18),
    original_currency VARCHAR(10),
    converted_amount DECIMAL(36,18),
    converted_currency VARCHAR(10),
    exchange_rate DECIMAL(36,18),
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
        t.id AS transaction_id,
        t.type AS transaction_type,
        t.original_amount,
        t.original_currency,
        t.converted_amount,
        t.currency AS converted_currency,
        t.exchange_rate,
        t.notes,
        t.created_at,
        COALESCE(
            ti.account_id, te.account_id, tinv.funding_account_id, 
            tb.disbursement_account_id, tl.funding_account_id, ta.account_id
        ) AS account_id,
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
            WHEN t.type = 'borrow' THEN jsonb_build_object(
                'loan_account_id', tb.loan_account_id,
                'disbursement_account_id', tb.disbursement_account_id
            )
            WHEN t.type = 'lend' THEN jsonb_build_object(
                'receivable_account_id', tl.receivable_account_id,
                'funding_account_id', tl.funding_account_id,
                'counterparty_id', tl.counterparty_id,
                'interest_rate', tl.interest_rate,
                'due_date', tl.due_date,
                'collateral', tl.collateral
            )
            WHEN t.type = 'adjustment' THEN jsonb_build_object(
                'account_id', ta.account_id
            )
            WHEN t.type = 'transfer' THEN jsonb_build_object(
                'from_account', tt.from_account,
                'to_account', tt.to_account,
                'transfer_method', tt.transfer_method,
                'fees', tt.fees
            )
            ELSE NULL
        END AS category_info,
        compute_transaction_direction(t.type, t.converted_amount) AS direction
    FROM transactions t
    LEFT JOIN transactions_income ti ON t.id = ti.transaction_id AND ti.deleted_at IS NULL
    LEFT JOIN transactions_expense te ON t.id = te.transaction_id AND te.deleted_at IS NULL
    LEFT JOIN transactions_investment tinv ON t.id = tinv.transaction_id AND tinv.deleted_at IS NULL
    LEFT JOIN transactions_borrow tb ON t.id = tb.transaction_id AND tb.deleted_at IS NULL
    LEFT JOIN transactions_lend tl ON t.id = tl.transaction_id AND tl.deleted_at IS NULL
    LEFT JOIN transactions_adjustment ta ON t.id = ta.transaction_id AND ta.deleted_at IS NULL
    LEFT JOIN transactions_transfer tt ON t.id = tt.transaction_id AND tt.deleted_at IS NULL
    LEFT JOIN accounts a ON COALESCE(
        ti.account_id, te.account_id, tinv.funding_account_id, 
        tb.disbursement_account_id, tl.funding_account_id, ta.account_id,
        tt.from_account
    ) = a.id
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
-- 11. Function: get_user_transaction_count
-- =========================================
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
    -- Use passed user_id or fallback to authenticated user
    v_user_id := COALESCE(p_user_id, auth.uid());

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    -- Count transactions for the user with filters
    SELECT COUNT(*)::INTEGER
    INTO v_count
    FROM transactions
    WHERE user_id = v_user_id
      AND deleted_at IS NULL
      AND (p_transaction_type IS NULL OR type = p_transaction_type)
      AND (p_start_date IS NULL OR created_at::DATE >= p_start_date)
      AND (p_end_date IS NULL OR created_at::DATE <= p_end_date);

    RETURN v_count;
END;
$$;

-- =========================================
-- 12. Function: get_recurring_schedules
-- =========================================
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
    original_amount DECIMAL(36,18),
    original_currency VARCHAR(10),
    exchange_rate DECIMAL(36,18),
    converted_amount DECIMAL(36,18),
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
        tr.id AS schedule_id,
        tr.transaction_template_id,
        t.type AS transaction_type,
        t.original_amount,
        t.original_currency,
        t.exchange_rate,
        t.converted_amount,
        tr.frequency,
        tr.interval AS recurrence_interval,
        tr.next_occurrence,
        tr.end_date,
        tr.created_at
    FROM transactions_recurring tr
    JOIN transactions t 
        ON tr.transaction_template_id = t.id
    WHERE tr.deleted_at IS NULL
      AND t.deleted_at IS NULL
    ORDER BY tr.next_occurrence ASC;
END;
$$;

-- =========================================
-- 13. Function: get_income_summary
-- =========================================
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
    total_original_amount DECIMAL(36,18),
    total_converted_amount DECIMAL(36,18)
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
        COALESCE(ins.name, 'Unknown') AS source_name,
        SUM(t.original_amount) AS total_original_amount,
        SUM(t.converted_amount) AS total_converted_amount
    FROM transactions t
    JOIN transactions_income ti 
        ON t.id = ti.transaction_id
        AND ti.deleted_at IS NULL
    JOIN accounts a 
        ON ti.account_id = a.id
        AND a.deleted_at IS NULL
    LEFT JOIN income_sources ins 
        ON ti.source_id = ins.id
        AND ins.deleted_at IS NULL
    WHERE t.type = 'income'
      AND t.deleted_at IS NULL
      AND (p_start_date IS NULL OR t.created_at >= p_start_date)
      AND (p_end_date IS NULL OR t.created_at <= p_end_date)
    GROUP BY ti.account_id, a.account_name, ti.source_id, ins.name
    ORDER BY total_converted_amount DESC;
END;
$$;

-- =========================================
-- 14. Function: get_expense_summary
-- =========================================
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
    total_original_amount DECIMAL(36,18),
    total_converted_amount DECIMAL(36,18)
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
        ec.name AS category_name,
        te.category_id AS subcategory_id,
        es.name AS subcategory_name,
        SUM(t.original_amount) AS total_original_amount,
        SUM(t.converted_amount) AS total_converted_amount
    FROM transactions t
    JOIN transactions_expense te 
        ON t.id = te.transaction_id
        AND te.deleted_at IS NULL
    JOIN accounts a 
        ON te.account_id = a.id
        AND a.deleted_at IS NULL
    LEFT JOIN expense_subcategories es 
        ON te.category_id = es.id
        AND es.deleted_at IS NULL
    LEFT JOIN expense_categories ec 
        ON es.category_id = ec.id
        AND ec.deleted_at IS NULL
    WHERE t.type = 'expense'
      AND t.deleted_at IS NULL
      AND (p_start_date IS NULL OR t.created_at >= p_start_date)
      AND (p_end_date IS NULL OR t.created_at <= p_end_date)
    GROUP BY te.account_id, a.account_name, es.category_id, ec.name, te.category_id, es.name
    ORDER BY total_converted_amount DESC;
END;
$$;

-- =========================================
-- 15. Function: get_investment_summary
-- =========================================
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
    total_original_amount DECIMAL(36,18),
    total_converted_amount DECIMAL(36,18),
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
        SUM(t.original_amount) AS total_original_amount,
        SUM(t.converted_amount) AS total_converted_amount,
        ti.risk_level
    FROM transactions t
    JOIN transactions_investment ti 
        ON t.id = ti.transaction_id
        AND ti.deleted_at IS NULL
    JOIN accounts a 
        ON ti.account_id = a.id
        AND a.deleted_at IS NULL
    WHERE t.type = 'investment'
      AND t.deleted_at IS NULL
      AND (p_start_date IS NULL OR t.created_at >= p_start_date)
      AND (p_end_date IS NULL OR t.created_at <= p_end_date)
    GROUP BY ti.account_id, a.account_name, ti.asset_type, ti.asset_symbol, ti.platform, ti.risk_level
    ORDER BY total_converted_amount DESC;
END;
$$;

-- =========================================
-- 16. Function: get_borrow_lend_summary
-- =========================================
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
    principal_original_amount DECIMAL(36,18),
    principal_converted_amount DECIMAL(36,18),
    currency VARCHAR,
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
        COALESCE(cp.name, 'Unknown') AS counterparty_name,
        COALESCE(cp.type, 'other'::counterparty_type) AS counterparty_type,
        t.original_amount AS principal_original_amount,
        t.converted_amount AS principal_converted_amount,
        t.currency,
        tb.interest_rate,
        tb.due_date,
        tb.collateral
    FROM transactions t
    JOIN transactions_borrow tb 
        ON t.id = tb.transaction_id
        AND tb.deleted_at IS NULL
    LEFT JOIN counterparties cp 
        ON tb.counterparty_id = cp.id
    WHERE t.type = 'borrow'
      AND t.deleted_at IS NULL

    UNION ALL

    -- Lend transactions
    SELECT 
        'lend'::transaction_type,
        COALESCE(cp.name, 'Unknown') AS counterparty_name,
        COALESCE(cp.type, 'other'::counterparty_type) AS counterparty_type,
        t.original_amount AS principal_original_amount,
        t.converted_amount AS principal_converted_amount,
        t.currency,
        tl.interest_rate,
        tl.due_date,
        tl.collateral
    FROM transactions t
    JOIN transactions_lend tl 
        ON t.id = tl.transaction_id
        AND tl.deleted_at IS NULL
    LEFT JOIN counterparties cp 
        ON tl.counterparty_id = cp.id
    WHERE t.type = 'lend'
      AND t.deleted_at IS NULL

    ORDER BY principal_converted_amount DESC;
END;
$$;


-- ================================
-- Grant Permissions
-- ================================
GRANT EXECUTE ON FUNCTION public.create_income_transaction(UUID, DECIMAL, VARCHAR, UUID, DECIMAL, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_expense_transaction(UUID, DECIMAL, VARCHAR, UUID, payment_method, DECIMAL, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_investment_transaction(UUID, UUID, DECIMAL, VARCHAR, VARCHAR, VARCHAR, risk_level, DECIMAL, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_borrow_transaction(UUID, UUID, DECIMAL, DECIMAL, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_lend_transaction(UUID, UUID, DECIMAL, DECIMAL, UUID, TEXT, DECIMAL, DATE, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_adjustment_transaction(UUID, DECIMAL, VARCHAR, DECIMAL, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_transfer_transaction(UUID, UUID, DECIMAL, transfer_method, DECIMAL, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_recurring_transaction(TEXT, JSONB, recurrence_frequency, INT, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.soft_delete_transaction(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.validate_transaction_ownership(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hard_delete_transaction(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_transaction_table_name(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_income_transaction(UUID, UUID, NUMERIC, VARCHAR, UUID, NUMERIC, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_expense_transaction(UUID, UUID, NUMERIC, VARCHAR, UUID, payment_method, NUMERIC, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_investment_transaction(UUID, UUID, UUID, NUMERIC, VARCHAR, VARCHAR, VARCHAR, risk_level, NUMERIC, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_adjustment_transaction(UUID, UUID, NUMERIC, VARCHAR, NUMERIC, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_borrow_transaction(UUID, UUID, UUID, NUMERIC, NUMERIC, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_lend_transaction(UUID, UUID, UUID, NUMERIC, UUID, NUMERIC, TEXT, NUMERIC, DATE, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_transfer_transaction(UUID, UUID, UUID, NUMERIC, transfer_method, NUMERIC, TEXT, BOOLEAN, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_recurring_transaction(UUID, recurrence_frequency, INT, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.soft_delete_recurring_transaction(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handle_recurring_transaction(UUID, BOOLEAN, JSONB) TO authenticated;

GRANT EXECUTE ON FUNCTION get_user_transaction_count(UUID, transaction_type, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION get_recent_transactions(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_transactions(INTEGER, INTEGER, timestamptz, timestamptz, transaction_type) TO authenticated;
GRANT EXECUTE ON FUNCTION compute_transaction_direction(transaction_type, DECIMAL) TO authenticated;
GRANT EXECUTE ON FUNCTION get_recurring_schedules() TO authenticated;
GRANT EXECUTE ON FUNCTION get_income_summary(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION get_expense_summary(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION get_investment_summary(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION get_borrow_lend_summary() TO authenticated;

-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION public.create_income_transaction(
    UUID, DECIMAL, VARCHAR, UUID, DECIMAL, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to create income transactions with validation and automatic balance updates';

COMMENT ON FUNCTION public.create_expense_transaction(
    UUID, DECIMAL, VARCHAR, UUID, payment_method, DECIMAL, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to create expense transactions with validation and automatic balance updates';

COMMENT ON FUNCTION public.create_investment_transaction(
    UUID, UUID, DECIMAL, VARCHAR, VARCHAR, VARCHAR, risk_level, DECIMAL, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to create investment transactions with validation and automatic balance updates';

COMMENT ON FUNCTION public.create_borrow_transaction(
    UUID, UUID, DECIMAL, DECIMAL, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to create borrow transactions with validation and automatic balance updates';

COMMENT ON FUNCTION public.create_lend_transaction(
    UUID, UUID, DECIMAL, DECIMAL, UUID, TEXT, DECIMAL, DATE, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to create lend transactions with validation and automatic balance updates';

COMMENT ON FUNCTION public.create_adjustment_transaction(
    UUID, DECIMAL, VARCHAR, DECIMAL, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to create adjustment transactions for corrections or balance fixes with validation and automatic balance updates';

COMMENT ON FUNCTION public.create_transfer_transaction(
    UUID, UUID, DECIMAL, transfer_method, DECIMAL, TEXT, BOOLEAN, JSONB
) IS 
'RLS-compliant function to create transfer transactions between two accounts with validation and automatic balance updates';

COMMENT ON FUNCTION public.create_recurring_transaction(
    TEXT, JSONB, recurrence_frequency, INT, DATE, DATE
) IS 'Creates a recurring transaction of a specified type and stores a template in transactions_recurring table for automated processing. Handles income, expense, investment, adjustment, borrow, lend, and transfer transaction types.';

COMMENT ON FUNCTION public.soft_delete_transaction(UUID) IS
'Soft deletes a transaction by setting deleted_at and updated_at. Requires transaction ownership. Checks ownership via validate_transaction_ownership().';

COMMENT ON FUNCTION public.validate_transaction_ownership(UUID, UUID) IS
'Checks if the given user owns the transaction and it is not soft deleted.';

COMMENT ON FUNCTION public.hard_delete_transaction(UUID) IS
'Hard deletes a transaction and all related detail records (income, expense, investment, borrow, lend, transfer, adjustment) and recurring transactions.
Only available to admins. Requires transaction to be soft deleted (deleted_at IS NOT NULL).
Runs with SECURITY DEFINER privileges. Returns TRUE on success, FALSE on failure.';

COMMENT ON FUNCTION public.update_income_transaction(UUID, UUID, NUMERIC, VARCHAR, UUID, NUMERIC, TEXT, BOOLEAN, JSONB)
IS 'RLS-compliant function to update income transactions with balance reversal, revalidation, and exchange recalculation.';

COMMENT ON FUNCTION public.get_transaction_table_name(TEXT)
IS 'Returns the correct transaction table name given a transaction type string.';

COMMENT ON FUNCTION public.update_expense_transaction(
    UUID, UUID, NUMERIC, VARCHAR, UUID, payment_method, NUMERIC, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to update an expense transaction with balance adjustments and validation';

COMMENT ON FUNCTION public.update_investment_transaction(
    UUID, UUID, UUID, NUMERIC, VARCHAR, VARCHAR, VARCHAR, risk_level, NUMERIC, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to update an investment transaction with balance adjustments and validation';

COMMENT ON FUNCTION public.update_adjustment_transaction(
    UUID, UUID, NUMERIC, VARCHAR, NUMERIC, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to update an adjustment transaction with balance adjustments and validation';

COMMENT ON FUNCTION public.update_borrow_transaction(
    UUID, UUID, UUID, NUMERIC, NUMERIC, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to update a borrow transaction with balance adjustments and validation';

COMMENT ON FUNCTION public.update_lend_transaction(
    UUID, UUID, UUID, NUMERIC, UUID, NUMERIC, TEXT, NUMERIC, DATE, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to update a lend transaction with balance adjustments and validation';

COMMENT ON FUNCTION public.update_transfer_transaction(
    UUID, UUID, UUID, NUMERIC, transfer_method, NUMERIC, TEXT, BOOLEAN, JSONB
) IS 'RLS-compliant function to update a transfer transaction with balance adjustments and validation';

COMMENT ON FUNCTION public.update_recurring_transaction(
    UUID, recurrence_frequency, INT, DATE, DATE
) IS 
'RLS-compliant function to update recurrence metadata of an existing recurring transaction, 
validating ownership and ensuring proper access control. 
Updates frequency, interval, start date, and end date, returning the updated recurring transaction details.';

COMMENT ON FUNCTION public.soft_delete_recurring_transaction(
    UUID
) IS 
'RLS-compliant function to perform a soft delete of a recurring transaction, 
validating ownership or admin permissions before marking the record as deleted. 
Returns a JSON object containing details of the deleted recurring transaction.';

COMMENT ON FUNCTION public.handle_recurring_transaction(
    UUID, BOOLEAN, JSONB
) IS
'Centralized RLS-compliant helper function to create, update, or soft-delete recurring transaction records based on parameters. Used internally by create_* and update_* transaction functions.';

COMMENT ON FUNCTION get_recent_transactions(INTEGER) IS 'RLS-compliant recent transactions query';
COMMENT ON FUNCTION get_income_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get income summary by source and account for current user';
COMMENT ON FUNCTION get_expense_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get expense summary by category and account for current user';
COMMENT ON FUNCTION get_investment_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get investment summary by asset type for current user';
CREATE INDEX IF NOT EXISTS idx_transactions_recurring_user_deleted 
ON transactions_recurring(user_id, deleted_at) WHERE deleted_at IS NULL;