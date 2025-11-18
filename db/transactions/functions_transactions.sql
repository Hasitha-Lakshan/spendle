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
-- 24. Function: get_recent_transactions
-- =========================================
-- Purpose:
--   Returns the most recent transactions belonging to the currently
--   authenticated user, limited by the optional p_limit parameter.

-- Behavior:
--   - Retrieves the current user ID using auth.uid().
--   - Ensures only transactions owned by the current user are returned.
--   - Filters out any transactions that have been soft deleted
--     (deleted_at IS NULL).
--   - Sorts results by created_at in descending order so the newest
--     transactions appear first.
--   - Applies the p_limit to control how many rows are returned.

-- Returns:
--   TABLE (
--       transaction_id UUID,
--       type transaction_type,
--       original_amount NUMERIC,
--       original_currency VARCHAR,
--       fees NUMERIC,
--       notes TEXT,
--       is_recurring BOOLEAN,
--       created_at TIMESTAMPTZ
--   )

-- Notes:
--   - SECURITY DEFINER allows the function to run with elevated privileges
--     while still respecting row level security filtering through
--     the user_id match.
--   - Designed to comply fully with RLS policies by returning only the
--     current user's non deleted transactions.
-- =========================================
CREATE OR REPLACE FUNCTION get_recent_transactions(p_limit INTEGER DEFAULT 10)
RETURNS TABLE (
    transaction_id UUID,
    type transaction_type,
    original_amount NUMERIC,
    original_currency VARCHAR,
    fees NUMERIC,
    notes TEXT,
    is_recurring BOOLEAN,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.id AS transaction_id,
        t.type,
        t.original_amount,
        t.original_currency,
        t.fees,
        t.notes,
        t.is_recurring,
        t.created_at
    FROM transactions t
    WHERE t.user_id = auth.uid()
      AND t.deleted_at IS NULL
    ORDER BY t.created_at DESC
    LIMIT p_limit;
END;
$$;

-- =========================================
-- 25. Function: get_user_transactions
-- =========================================
-- Purpose:
--   Retrieves a paginated and optionally filtered list of transactions
--   belonging to the currently authenticated user.

-- Behavior:
--   - Obtains the current user ID using auth.uid().
--   - Ensures only the current user's non deleted transactions are returned.
--   - Supports pagination through p_limit and p_offset.
--   - Allows optional filtering by:
--       * Date range using p_start_date and p_end_date.
--       * Transaction type using p_transaction_type.
--   - Filters out any soft deleted transactions (deleted_at IS NULL).
--   - Sorts the results by created_at in descending order.

-- Returns:
--   TABLE (
--       transaction_id UUID,
--       type transaction_type,
--       original_amount NUMERIC,
--       original_currency VARCHAR,
--       fees NUMERIC,
--       notes TEXT,
--       is_recurring BOOLEAN,
--       created_at TIMESTAMPTZ
--   )

-- Notes:
--   - SECURITY DEFINER allows execution with elevated privileges while still
--     enforcing row level security through user_id matching.
--   - Designed to work safely with RLS by returning only the current user's
--     non deleted data.
--   - Useful for user dashboards and transaction history pages that require
--     filtering and pagination.
-- =========================================
CREATE OR REPLACE FUNCTION get_user_transactions(
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0,
    p_start_date timestamptz DEFAULT NULL,
    p_end_date timestamptz DEFAULT NULL,
    p_transaction_type transaction_type DEFAULT NULL
)
RETURNS TABLE (
    transaction_id UUID,
    type transaction_type,
    original_amount NUMERIC,
    original_currency VARCHAR,
    fees NUMERIC,
    notes TEXT,
    is_recurring BOOLEAN,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        t.id AS transaction_id,
        t.type,
        t.original_amount,
        t.original_currency,
        t.fees,
        t.notes,
        t.is_recurring,
        t.created_at
    FROM transactions t
    WHERE t.user_id = auth.uid()
      AND t.deleted_at IS NULL
      AND (p_transaction_type IS NULL OR t.type = p_transaction_type)
      AND (p_start_date IS NULL OR t.created_at >= p_start_date)
      AND (p_end_date IS NULL OR t.created_at <= p_end_date)
    ORDER BY t.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$;

-- =========================================
-- 26. Function: get_transaction_detail
-- =========================================
-- Purpose:
--   Returns a complete structured JSON response containing both the
--   main transaction fields and the associated detail record based on
--   the transaction type.

-- Behavior:
--   - Retrieves the main transaction record using p_transaction_id.
--   - Ensures the transaction exists and is not soft deleted.
--   - Determines the transaction type and fetches the corresponding
--     detail record from the correct specialized table.
--   - Includes related account, category, counterparty or platform
--     data where applicable.
--   - Combines the main transaction JSON and the detail JSON into a
--     single JSON response.
--   - Supports the following transaction types:
--       * income
--       * expense
--       * investment
--       * borrow
--       * lend
--       * transfer
--       * adjustment

-- Returns:
--   JSONB
--       Contains:
--         - Main transaction fields
--         - A nested "details" object with type specific information

-- Notes:
--   - SECURITY DEFINER allows the function to access related tables while
--     depending on RLS to restrict access to authorized user data.
--   - Each detail lookup enforces deleted_at IS NULL to maintain soft
--     delete integrity.
--   - Ensures consistent JSON structure for all clients that consume
--     transaction detail data.
-- =========================================
CREATE OR REPLACE FUNCTION get_transaction_detail(
    p_transaction_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    base_tx JSONB;
    detail JSONB := '{}'::jsonb;
    tx_type transaction_type;
BEGIN
    -- Fetch ONLY the required main transaction fields
    SELECT jsonb_build_object(
        'transaction_id', t.id,
        'type', t.type,
        'original_amount', t.original_amount,
        'original_currency', t.original_currency,
        'exchange_rate', t.exchange_rate,
        'converted_amount', t.converted_amount,
        'fees', t.fees,
        'notes', t.notes,
        'is_recurring', t.is_recurring,
        'created_at', t.created_at
    )
    INTO base_tx
    FROM transactions t
    WHERE t.id = p_transaction_id
      AND t.deleted_at IS NULL;

    IF base_tx IS NULL THEN
        RAISE EXCEPTION 'Transaction % not found or has been deleted', p_transaction_id;
    END IF;

    tx_type := (base_tx ->> 'type')::transaction_type;

    -- Fetch specific detail based on transaction type
    IF tx_type = 'income' THEN
        SELECT jsonb_build_object(
            'account', (
                SELECT jsonb_build_object(
                    'id', a.id,
                    'name', a.account_name,
                    'account_type', a.type,
                    'currency', a.currency
                )
                FROM accounts a
                WHERE a.id = ti.account_id
                  AND a.deleted_at IS NULL
                LIMIT 1
            ),
            'source', (
                SELECT jsonb_build_object('id', s.id, 'name', s.name)
                FROM income_sources s
                WHERE s.id = ti.source_id
                  AND s.deleted_at IS NULL
                LIMIT 1
            )
        )
        INTO detail
        FROM transactions_income ti
        WHERE ti.transaction_id = p_transaction_id
          AND ti.deleted_at IS NULL
        LIMIT 1;

    ELSIF tx_type = 'expense' THEN
        SELECT jsonb_build_object(
            'account', (
                SELECT jsonb_build_object(
                    'id', a.id,
                    'name', a.account_name,
                    'account_type', a.type,
                    'currency', a.currency
                )
                FROM accounts a
                WHERE a.id = te.account_id
                AND a.deleted_at IS NULL
                LIMIT 1
            ),
            'category', (
                SELECT jsonb_build_object(
                    'id', sc.id,
                    'name', sc.name,
                    'parent_category', jsonb_build_object(
                        'id', c.id,
                        'name', c.name
                    )
                )
                FROM expense_subcategories sc
                JOIN expense_categories c ON sc.category_id = c.id
                WHERE sc.id = te.category_id
                AND sc.deleted_at IS NULL
                AND c.deleted_at IS NULL
                LIMIT 1
            ),
            'payment_method', te.payment_method
        )
        INTO detail
        FROM transactions_expense te
        WHERE te.transaction_id = p_transaction_id
        AND te.deleted_at IS NULL
        LIMIT 1;

    ELSIF tx_type = 'investment' THEN
        SELECT jsonb_build_object(
            'funding_account', (
                SELECT jsonb_build_object('id', a.id, 'name', a.account_name, 'account_type', a.type, 'currency', a.currency)
                FROM accounts a
                WHERE a.id = ti.funding_account_id
                  AND a.deleted_at IS NULL
                LIMIT 1
            ),
            'investment_account', (
                SELECT jsonb_build_object('id', a.id, 'name', a.account_name, 'account_type', a.type, 'currency', a.currency)
                FROM accounts a
                WHERE a.id = ti.investment_account_id
                  AND a.deleted_at IS NULL
                LIMIT 1
            ),
            'asset_type', ti.asset_type,
            'asset_symbol', ti.asset_symbol,
            'platform', ti.platform,
            'risk_level', ti.risk_level
        )
        INTO detail
        FROM transactions_investment ti
        WHERE ti.transaction_id = p_transaction_id
          AND ti.deleted_at IS NULL
        LIMIT 1;

    ELSIF tx_type = 'borrow' THEN
        SELECT jsonb_build_object(
            'loan_account', (
                SELECT jsonb_build_object('id', a.id, 'name', a.account_name, 'account_type', a.type, 'currency', a.currency)
                FROM accounts a
                WHERE a.id = tb.loan_account_id
                  AND a.deleted_at IS NULL
                LIMIT 1
            ),
            'disbursement_account', (
                SELECT jsonb_build_object('id', a.id, 'name', a.account_name, 'account_type', a.type, 'currency', a.currency)
                FROM accounts a
                WHERE a.id = tb.disbursement_account_id
                  AND a.deleted_at IS NULL
                LIMIT 1
            )
        )
        INTO detail
        FROM transactions_borrow tb
        WHERE tb.transaction_id = p_transaction_id
          AND tb.deleted_at IS NULL
        LIMIT 1;

    ELSIF tx_type = 'lend' THEN
        SELECT jsonb_build_object(
            'funding_account', (
                SELECT jsonb_build_object('id', a.id, 'name', a.account_name, 'account_type', a.type, 'currency', a.currency)
                FROM accounts a
                WHERE a.id = tl.funding_account_id
                  AND a.deleted_at IS NULL
                LIMIT 1
            ),
            'receivable_account', (
                SELECT jsonb_build_object('id', a.id, 'name', a.account_name, 'account_type', a.type, 'currency', a.currency)
                FROM accounts a
                WHERE a.id = tl.receivable_account_id
                  AND a.deleted_at IS NULL
                LIMIT 1
            ),
            'counterparty', (
                SELECT jsonb_build_object('id', cp.id, 'name', cp.name, 'type', cp.type)
                FROM counterparties cp
                WHERE cp.id = tl.counterparty_id
                  AND cp.deleted_at IS NULL
                LIMIT 1
            ),
            'interest_rate', tl.interest_rate,
            'due_date', tl.due_date,
            'collateral', tl.collateral
        )
        INTO detail
        FROM transactions_lend tl
        WHERE tl.transaction_id = p_transaction_id
          AND tl.deleted_at IS NULL
        LIMIT 1;

    ELSIF tx_type = 'transfer' THEN
        SELECT jsonb_build_object(
            'from_account', (
                SELECT jsonb_build_object('id', a.id, 'name', a.account_name, 'account_type', a.type, 'currency', a.currency)
                FROM accounts a
                WHERE a.id = tt.from_account
                  AND a.deleted_at IS NULL
                LIMIT 1
            ),
            'to_account', (
                SELECT jsonb_build_object('id', a.id, 'name', a.account_name, 'account_type', a.type, 'currency', a.currency)
                FROM accounts a
                WHERE a.id = tt.to_account
                  AND a.deleted_at IS NULL
                LIMIT 1
            ),
            'transfer_method', tt.transfer_method
        )
        INTO detail
        FROM transactions_transfer tt
        WHERE tt.transaction_id = p_transaction_id
          AND tt.deleted_at IS NULL
        LIMIT 1;

    ELSIF tx_type = 'adjustment' THEN
        SELECT jsonb_build_object(
            'account', (
                SELECT jsonb_build_object('id', a.id, 'name', a.account_name, 'account_type', a.type, 'currency', a.currency)
                FROM accounts a
                WHERE a.id = ta.account_id
                  AND a.deleted_at IS NULL
                LIMIT 1
            )
        )
        INTO detail
        FROM transactions_adjustment ta
        WHERE ta.transaction_id = p_transaction_id
          AND ta.deleted_at IS NULL
        LIMIT 1;
    END IF;

    -- Return final combined JSON
    RETURN base_tx || jsonb_build_object('details', detail);
END;
$$;

-- =========================================
-- 27. Function: get_recurring_schedules
-- =========================================
-- Purpose:
--   Retrieves a paginated list of recurring transaction schedules for
--   the currently authenticated user, optionally filtered by start and
--   end dates.

-- Behavior:
--   - Obtains the current user ID using auth.uid().
--   - Raises an exception if the request is unauthenticated.
--   - Filters recurring schedules that belong to the current user and
--     are not soft deleted (deleted_at IS NULL).
--   - Supports optional filtering by:
--       * Start date using p_start_date.
--       * End date using p_end_date.
--   - Supports pagination through p_limit and p_offset.
--   - Orders the results by next_occurrence in ascending order.
--   - Aggregates the schedules into a single JSONB array for easy
--     consumption.

-- Returns:
--   JSONB
--       Contains an array of recurring schedule objects with fields:
--         - id
--         - transaction_template_id
--         - frequency
--         - interval
--         - start_date
--         - end_date
--         - next_occurrence
--         - created_at
--         - updated_at

-- Notes:
--   - SECURITY DEFINER allows access to the transactions_recurring
--     table while relying on RLS to restrict data to the current user.
--   - Returns an empty JSON array if no schedules match the criteria.
--   - Designed for dashboards, reporting, or any feature that requires
--     viewing upcoming recurring transactions.
-- =========================================
CREATE OR REPLACE FUNCTION get_recurring_schedules(
    p_start_date DATE DEFAULT NULL,
    p_end_date   DATE DEFAULT NULL,
    p_limit      INTEGER DEFAULT 50,
    p_offset     INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    result JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated request';
    END IF;

    SELECT jsonb_agg(data ORDER BY data->>'next_occurrence')
    INTO result
    FROM (
        SELECT jsonb_build_object(
            'id', tr.id,
            'transaction_template_id', tr.transaction_template_id,
            'frequency', tr.frequency,
            'interval', tr.interval,
            'start_date', tr.start_date,
            'end_date', tr.end_date,
            'next_occurrence', tr.next_occurrence,
            'created_at', tr.created_at,
            'updated_at', tr.updated_at
        ) AS data
        FROM transactions_recurring tr
        WHERE tr.user_id = v_user_id
          AND tr.deleted_at IS NULL
          AND (p_start_date IS NULL OR tr.start_date >= p_start_date)
          AND (p_end_date IS NULL OR tr.end_date <= p_end_date)
        ORDER BY tr.next_occurrence ASC
        LIMIT p_limit
        OFFSET p_offset
    ) AS sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 28. Function: get_transaction_counts_by_type
-- =========================================
-- Purpose:
--   Returns the count of transactions grouped by transaction type
--   for the currently authenticated user, separating recurring and
--   non-recurring transactions, optionally filtered by start and end dates.

-- Behavior:
--   - Retrieves the current user ID using auth.uid().
--   - Raises an exception if the request is unauthenticated.
--   - Filters only transactions belonging to the current user and
--     not soft deleted (deleted_at IS NULL).
--   - Supports optional filtering by:
--       * Start date using p_start_date.
--       * End date using p_end_date.
--   - Counts transactions for each type, distinguishing between:
--       * Recurring transactions (is_recurring = TRUE)
--       * Non-recurring transactions (is_recurring = FALSE)
--   - Aggregates the results into a JSONB array, ordered by type.

-- Returns:
--   JSONB
--       Contains an array of objects with fields:
--         - type
--         - recurring_count
--         - non_recurring_count

-- Notes:
--   - SECURITY DEFINER allows execution while respecting RLS policies
--     for the current user.
--   - Returns an empty JSON array if no transactions match the criteria.
--   - Useful for dashboards, reporting, or summaries showing transaction
--     distribution by type and recurrence over a specific period.
-- =========================================
CREATE OR REPLACE FUNCTION get_transaction_counts_by_type(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    result JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated request';
    END IF;

    SELECT jsonb_agg(
               jsonb_build_object(
                   'type', type,
                   'recurring_count', recurring_count,
                   'non_recurring_count', non_recurring_count
               )
           )
    INTO result
    FROM (
        SELECT
            type,
            COUNT(*) FILTER (WHERE is_recurring = TRUE) AS recurring_count,
            COUNT(*) FILTER (WHERE is_recurring = FALSE) AS non_recurring_count
        FROM transactions t
        WHERE t.user_id = v_user_id
          AND t.deleted_at IS NULL
          AND (p_start_date IS NULL OR t.created_at::date >= p_start_date)
          AND (p_end_date IS NULL OR t.created_at::date <= p_end_date)
        GROUP BY type
        ORDER BY type
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 29. Function: get_income_summary_by_source_account
-- =========================================
-- Purpose:
--   Provides a summary of income transactions grouped by income
--   source and account for the currently authenticated user,
--   separating recurring and non-recurring amounts.

-- Behavior:
--   - Retrieves the current user ID using auth.uid().
--   - Raises an exception if the request is unauthenticated.
--   - Joins transactions_income with transactions, income_sources,
--     and accounts to collect relevant data.
--   - Filters only records that are not soft deleted (deleted_at IS NULL)
--     and where converted_amount is not null.
--   - Supports optional filtering by start and end dates.
--   - Aggregates sums of converted_amount separately for recurring
--     and non-recurring transactions.
--   - Groups results by income source and account.
--   - Orders results by source_name and account_name.
--   - Returns a JSONB array of summarized records.

-- Returns:
--   JSONB
--       Contains an array of objects with fields:
--         - source_id
--         - source_name
--         - account_id
--         - account_name
--         - account_currency
--         - recurring_total
--         - non_recurring_total

-- Notes:
--   - SECURITY DEFINER allows execution while respecting RLS policies
--     for the current user.
--   - Returns an empty JSON array if no matching transactions exist.
--   - Useful for dashboards, reporting, or generating summaries of
--     income by source and account.
-- =========================================
CREATE OR REPLACE FUNCTION get_income_summary_by_source_account(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    result JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated request';
    END IF;

    SELECT jsonb_agg(
               jsonb_build_object(
                   'source_id', source_id,
                   'source_name', source_name,
                   'account_id', account_id,
                   'account_name', account_name,
                   'account_currency', account_currency,
                   'recurring_total', recurring_total,
                   'non_recurring_total', non_recurring_total
               )
           )
    INTO result
    FROM (
        SELECT
            ti.source_id,
            isrc.name AS source_name,
            ti.account_id,
            acc.account_name,
            acc.currency AS account_currency,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = TRUE) AS recurring_total,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = FALSE) AS non_recurring_total
        FROM transactions_income ti
        JOIN transactions t ON t.id = ti.transaction_id
        JOIN income_sources isrc ON isrc.id = ti.source_id
        JOIN accounts acc ON acc.id = ti.account_id
        WHERE t.user_id = v_user_id
          AND t.deleted_at IS NULL
          AND ti.deleted_at IS NULL
          AND isrc.deleted_at IS NULL
          AND acc.deleted_at IS NULL
          AND t.converted_amount IS NOT NULL
          AND (p_start_date IS NULL OR t.created_at::date >= p_start_date)
          AND (p_end_date IS NULL OR t.created_at::date <= p_end_date)
        GROUP BY ti.source_id, isrc.name, ti.account_id, acc.account_name, acc.currency
        ORDER BY source_name, account_name
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 30. Function: get_expense_summary_by_category_account
-- =========================================
-- Purpose:
--   Provides a summary of expense transactions grouped by expense
--   category and account for the currently authenticated user,
--   separating recurring and non-recurring amounts.

-- Behavior:
--   - Retrieves the current user ID using auth.uid().
--   - Raises an exception if the request is unauthenticated.
--   - Joins transactions_expense with transactions, expense_subcategories,
--     and accounts to collect relevant data.
--   - Filters only records that are not soft deleted (deleted_at IS NULL)
--     and where converted_amount is not null.
--   - Supports optional filtering by start and end dates.
--   - Aggregates sums of converted_amount separately for recurring
--     and non-recurring transactions.
--   - Groups results by expense category and account.
--   - Orders results by category_name and account_name.
--   - Returns a JSONB array of summarized records.

-- Returns:
--   JSONB
--       Contains an array of objects with fields:
--         - category_id
--         - category_name
--         - account_id
--         - account_name
--         - account_currency
--         - recurring_total
--         - non_recurring_total

-- Notes:
--   - SECURITY DEFINER allows execution while respecting RLS policies
--     for the current user.
--   - Returns an empty JSON array if no matching transactions exist.
--   - Useful for dashboards, reporting, or generating summaries of
--     expenses by category and account.
-- =========================================
CREATE OR REPLACE FUNCTION get_expense_summary_by_category_account(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    result JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated request';
    END IF;

    SELECT jsonb_agg(
               jsonb_build_object(
                   'category_id', category_id,
                   'category_name', category_name,
                   'account_id', account_id,
                   'account_name', account_name,
                   'account_currency', account_currency,
                   'recurring_total', recurring_total,
                   'non_recurring_total', non_recurring_total
               )
           )
    INTO result
    FROM (
        SELECT
            te.category_id,
            esc.name AS category_name,
            te.account_id,
            acc.account_name,
            acc.currency AS account_currency,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = TRUE) AS recurring_total,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = FALSE) AS non_recurring_total
        FROM transactions_expense te
        JOIN transactions t ON t.id = te.transaction_id
        JOIN expense_subcategories esc ON esc.id = te.category_id
        JOIN accounts acc ON acc.id = te.account_id
        WHERE t.user_id = v_user_id
          AND t.deleted_at IS NULL
          AND te.deleted_at IS NULL
          AND esc.deleted_at IS NULL
          AND acc.deleted_at IS NULL
          AND t.converted_amount IS NOT NULL
          AND (p_start_date IS NULL OR t.created_at::date >= p_start_date)
          AND (p_end_date IS NULL OR t.created_at::date <= p_end_date)
        GROUP BY te.category_id, esc.name, te.account_id, acc.account_name, acc.currency
        ORDER BY category_name, account_name
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 31. Function: get_investment_summary_by_investment_account
-- =========================================
-- Purpose:
--   Provides a summary of investment transactions grouped by investment
--   account for the currently authenticated user, separating recurring
--   and non-recurring amounts.

-- Behavior:
--   - Retrieves the current user ID using auth.uid().
--   - Raises an exception if the request is unauthenticated.
--   - Joins transactions_investment with transactions and accounts to
--     collect relevant data.
--   - Filters only records that are not soft deleted (deleted_at IS NULL)
--     and where converted_amount is not null.
--   - Supports optional filtering by start and end dates.
--   - Aggregates sums of converted_amount separately for recurring
--     and non-recurring transactions.
--   - Groups results by investment account.
--   - Orders results by investment_account_name.
--   - Returns a JSONB array of summarized records.

-- Returns:
--   JSONB
--       Contains an array of objects with fields:
--         - investment_account_id
--         - investment_account_name
--         - investment_account_currency
--         - recurring_total
--         - non_recurring_total

-- Notes:
--   - SECURITY DEFINER allows execution while respecting RLS policies
--     for the current user.
--   - Returns an empty JSON array if no matching transactions exist.
--   - Useful for dashboards, reporting, or generating summaries of
--     investments by account.
-- =========================================
CREATE OR REPLACE FUNCTION get_investment_summary_by_investment_account(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    result JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated request';
    END IF;

    SELECT jsonb_agg(
               jsonb_build_object(
                   'investment_account_id', investment_account_id,
                   'investment_account_name', investment_account_name,
                   'investment_account_currency', investment_account_currency,
                   'recurring_total', recurring_total,
                   'non_recurring_total', non_recurring_total
               )
           )
    INTO result
    FROM (
        SELECT
            ti.investment_account_id,
            inv_acc.account_name AS investment_account_name,
            inv_acc.currency AS investment_account_currency,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = TRUE) AS recurring_total,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = FALSE) AS non_recurring_total
        FROM transactions_investment ti
        JOIN transactions t ON t.id = ti.transaction_id
        JOIN accounts inv_acc ON inv_acc.id = ti.investment_account_id
        WHERE t.user_id = v_user_id
          AND t.deleted_at IS NULL
          AND ti.deleted_at IS NULL
          AND inv_acc.deleted_at IS NULL
          AND t.converted_amount IS NOT NULL
          AND (p_start_date IS NULL OR t.created_at::date >= p_start_date)
          AND (p_end_date IS NULL OR t.created_at::date <= p_end_date)
        GROUP BY ti.investment_account_id, inv_acc.account_name, inv_acc.currency
        ORDER BY investment_account_name
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 32. Function: get_borrow_summary_by_loan_account
-- =========================================
-- Purpose:
--   Provides a summary of borrow (loan) transactions grouped by loan
--   account for the currently authenticated user, separating recurring
--   and non-recurring amounts.

-- Behavior:
--   - Retrieves the current user ID using auth.uid().
--   - Raises an exception if the request is unauthenticated.
--   - Joins transactions_borrow with transactions and accounts to
--     collect relevant data.
--   - Filters only records that are not soft deleted (deleted_at IS NULL)
--     and where converted_amount is not null.
--   - Supports optional filtering by start and end dates.
--   - Aggregates sums of converted_amount separately for recurring
--     and non-recurring transactions.
--   - Groups results by loan account.
--   - Orders results by loan_account_name.
--   - Returns a JSONB array of summarized records.

-- Returns:
--   JSONB
--       Contains an array of objects with fields:
--         - loan_account_id
--         - loan_account_name
--         - loan_account_currency
--         - recurring_total
--         - non_recurring_total

-- Notes:
--   - SECURITY DEFINER allows execution while respecting RLS policies
--     for the current user.
--   - Returns an empty JSON array if no matching transactions exist.
--   - Useful for dashboards, reporting, or generating summaries of
--     borrow transactions by account.
-- =========================================
CREATE OR REPLACE FUNCTION get_borrow_summary_by_loan_account(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    result JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated request';
    END IF;

    SELECT jsonb_agg(
               jsonb_build_object(
                   'loan_account_id', loan_account_id,
                   'loan_account_name', loan_account_name,
                   'loan_account_currency', loan_account_currency,
                   'recurring_total', recurring_total,
                   'non_recurring_total', non_recurring_total
               )
           )
    INTO result
    FROM (
        SELECT
            tb.loan_account_id,
            loan_acc.account_name AS loan_account_name,
            loan_acc.currency AS loan_account_currency,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = TRUE) AS recurring_total,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = FALSE) AS non_recurring_total
        FROM transactions_borrow tb
        JOIN transactions t ON t.id = tb.transaction_id
        JOIN accounts loan_acc ON loan_acc.id = tb.loan_account_id
        WHERE t.user_id = v_user_id
          AND t.deleted_at IS NULL
          AND tb.deleted_at IS NULL
          AND loan_acc.deleted_at IS NULL
          AND t.converted_amount IS NOT NULL
          AND (p_start_date IS NULL OR t.created_at::date >= p_start_date)
          AND (p_end_date IS NULL OR t.created_at::date <= p_end_date)
        GROUP BY tb.loan_account_id, loan_acc.account_name, loan_acc.currency
        ORDER BY loan_account_name
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 33. Function: get_lend_summary_by_receivable_account
-- =========================================
-- Purpose:
--   Provides a summary of lend transactions grouped by receivable
--   account for the currently authenticated user, separating recurring
--   and non-recurring amounts.

-- Behavior:
--   - Retrieves the current user ID using auth.uid().
--   - Raises an exception if the request is unauthenticated.
--   - Joins transactions_lend with transactions and accounts to
--     collect relevant data.
--   - Filters only records that are not soft deleted (deleted_at IS NULL)
--     and where converted_amount is not null.
--   - Supports optional filtering by start and end dates.
--   - Aggregates sums of converted_amount separately for recurring
--     and non-recurring transactions.
--   - Groups results by receivable account.
--   - Orders results by receivable_account_name.
--   - Returns a JSONB array of summarized records.

-- Returns:
--   JSONB
--       Contains an array of objects with fields:
--         - receivable_account_id
--         - receivable_account_name
--         - receivable_account_currency
--         - recurring_total
--         - non_recurring_total

-- Notes:
--   - SECURITY DEFINER allows execution while respecting RLS policies
--     for the current user.
--   - Returns an empty JSON array if no matching transactions exist.
--   - Useful for dashboards, reporting, or generating summaries of
--     lend transactions by receivable account.
-- =========================================
CREATE OR REPLACE FUNCTION get_lend_summary_by_receivable_account(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    result JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated request';
    END IF;

    SELECT jsonb_agg(
               jsonb_build_object(
                   'receivable_account_id', receivable_account_id,
                   'receivable_account_name', receivable_account_name,
                   'receivable_account_currency', receivable_account_currency,
                   'recurring_total', recurring_total,
                   'non_recurring_total', non_recurring_total
               )
           )
    INTO result
    FROM (
        SELECT
            tl.receivable_account_id,
            rec_acc.account_name AS receivable_account_name,
            rec_acc.currency AS receivable_account_currency,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = TRUE) AS recurring_total,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = FALSE) AS non_recurring_total
        FROM transactions_lend tl
        JOIN transactions t ON t.id = tl.transaction_id
        JOIN accounts rec_acc ON rec_acc.id = tl.receivable_account_id
        WHERE t.user_id = v_user_id
          AND t.deleted_at IS NULL
          AND tl.deleted_at IS NULL
          AND rec_acc.deleted_at IS NULL
          AND t.converted_amount IS NOT NULL
          AND (p_start_date IS NULL OR t.created_at::date >= p_start_date)
          AND (p_end_date IS NULL OR t.created_at::date <= p_end_date)
        GROUP BY tl.receivable_account_id, rec_acc.account_name, rec_acc.currency
        ORDER BY receivable_account_name
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 34. Function: get_adjustment_summary_by_account
-- =========================================
-- Purpose:
--   Provides a summary of adjustment transactions grouped by account
--   for the currently authenticated user, separating recurring and
--   non-recurring amounts.

-- Behavior:
--   - Retrieves the current user ID using auth.uid().
--   - Raises an exception if the request is unauthenticated.
--   - Joins transactions_adjustment with transactions and accounts to
--     collect relevant data.
--   - Filters only records that are not soft deleted (deleted_at IS NULL)
--     and where converted_amount is not null.
--   - Supports optional filtering by start and end dates.
--   - Aggregates sums of converted_amount separately for recurring
--     and non-recurring transactions.
--   - Groups results by account.
--   - Orders results by account_name.
--   - Returns a JSONB array of summarized records.

-- Returns:
--   JSONB
--       Contains an array of objects with fields:
--         - account_id
--         - account_name
--         - account_currency
--         - recurring_total
--         - non_recurring_total

-- Notes:
--   - SECURITY DEFINER allows execution while respecting RLS policies
--     for the current user.
--   - Returns an empty JSON array if no matching transactions exist.
--   - Useful for dashboards, reporting, or generating summaries of
--     adjustment transactions by account.
-- =========================================
CREATE OR REPLACE FUNCTION get_adjustment_summary_by_account(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    result JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated request';
    END IF;

    SELECT jsonb_agg(
               jsonb_build_object(
                   'account_id', account_id,
                   'account_name', account_name,
                   'account_currency', account_currency,
                   'recurring_total', recurring_total,
                   'non_recurring_total', non_recurring_total
               )
           )
    INTO result
    FROM (
        SELECT
            ta.account_id,
            acc.account_name,
            acc.currency AS account_currency,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = TRUE) AS recurring_total,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = FALSE) AS non_recurring_total
        FROM transactions_adjustment ta
        JOIN transactions t ON t.id = ta.transaction_id
        JOIN accounts acc ON acc.id = ta.account_id
        WHERE t.user_id = v_user_id
          AND t.deleted_at IS NULL
          AND ta.deleted_at IS NULL
          AND acc.deleted_at IS NULL
          AND t.converted_amount IS NOT NULL
          AND (p_start_date IS NULL OR t.created_at::date >= p_start_date)
          AND (p_end_date IS NULL OR t.created_at::date <= p_end_date)
        GROUP BY ta.account_id, acc.account_name, acc.currency
        ORDER BY account_name
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 35. Function: get_transfer_summary_by_to_and_from_accounts
-- =========================================
-- Purpose:
--   Provides a summary of transfer transactions grouped by both
--   from-account and to-account for the currently authenticated user,
--   separating recurring and non-recurring amounts in both original
--   and converted currencies.

-- Behavior:
--   - Retrieves the current user ID using auth.uid().
--   - Raises an exception if the request is unauthenticated.
--   - Joins transactions_transfer with transactions and accounts to
--     collect relevant data.
--   - Filters only records that are not soft deleted (deleted_at IS NULL)
--     and where original_amount and converted_amount are not null.
--   - Supports optional filtering by start and end dates.
--   - Aggregates sums of converted_amount and original_amount separately
--     for recurring and non-recurring transactions.
--   - Groups results by both from-account and to-account.
--   - Orders results by from_account_name and to_account_name.
--   - Returns a JSONB array of summarized records.

-- Returns:
--   JSONB
--       Contains an array of objects with fields:
--         - from_account_id
--         - from_account_name
--         - from_account_currency
--         - to_account_id
--         - to_account_name
--         - to_account_currency
--         - recurring_converted_total
--         - non_recurring_converted_total
--         - recurring_original_total
--         - non_recurring_original_total

-- Notes:
--   - SECURITY DEFINER allows execution while respecting RLS policies
--     for the current user.
--   - Returns an empty JSON array if no matching transactions exist.
--   - Useful for dashboards, reporting, or generating summaries of
--     transfers between accounts.
-- =========================================
CREATE OR REPLACE FUNCTION get_transfer_summary_by_to_and_from_accounts(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    result JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Unauthenticated request';
    END IF;

    SELECT jsonb_agg(
               jsonb_build_object(
                   'from_account_id', from_account_id,
                   'from_account_name', from_account_name,
                   'from_account_currency', from_account_currency,
                   'to_account_id', to_account_id,
                   'to_account_name', to_account_name,
                   'to_account_currency', to_account_currency,
                   'recurring_converted_total', recurring_converted_total,
                   'non_recurring_converted_total', non_recurring_converted_total,
                   'recurring_original_total', recurring_original_total,
                   'non_recurring_original_total', non_recurring_original_total
               )
           )
    INTO result
    FROM (
        SELECT
            tt.from_account AS from_account_id,
            from_acc.account_name AS from_account_name,
            from_acc.currency AS from_account_currency,
            tt.to_account AS to_account_id,
            to_acc.account_name AS to_account_name,
            to_acc.currency AS to_account_currency,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = TRUE) AS recurring_converted_total,
            SUM(t.converted_amount) FILTER (WHERE t.is_recurring = FALSE) AS non_recurring_converted_total,
            SUM(t.original_amount) FILTER (WHERE t.is_recurring = TRUE) AS recurring_original_total,
            SUM(t.original_amount) FILTER (WHERE t.is_recurring = FALSE) AS non_recurring_original_total
        FROM transactions_transfer tt
        JOIN transactions t ON t.id = tt.transaction_id
        JOIN accounts from_acc ON from_acc.id = tt.from_account
        JOIN accounts to_acc ON to_acc.id = tt.to_account
        WHERE t.user_id = v_user_id
          AND t.deleted_at IS NULL
          AND tt.deleted_at IS NULL
          AND from_acc.deleted_at IS NULL
          AND to_acc.deleted_at IS NULL
          AND t.converted_amount IS NOT NULL
          AND t.original_amount IS NOT NULL
          AND (p_start_date IS NULL OR t.created_at::date >= p_start_date)
          AND (p_end_date IS NULL OR t.created_at::date <= p_end_date)
        GROUP BY tt.from_account, from_acc.account_name, from_acc.currency,
                 tt.to_account, to_acc.account_name, to_acc.currency
        ORDER BY from_account_name, to_account_name
    ) sub;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- =========================================
-- 36. Function: get_transactions_summary
-- =========================================
-- Purpose:
--   Aggregates multiple transaction summaries for the currently
--   authenticated user into a single JSONB object, optionally filtered
--   by start and end dates. Includes summaries across all transaction
--   types, accounts, and categories.

-- Behavior:
--   - Retrieves various transaction summaries by invoking existing functions:
--       * get_transaction_counts_by_type
--       * get_income_summary_by_source_account
--       * get_expense_summary_by_category_account
--       * get_investment_summary_by_investment_account
--       * get_borrow_summary_by_loan_account
--       * get_lend_summary_by_receivable_account
--       * get_adjustment_summary_by_account
--       * get_transfer_summary_by_to_and_from_accounts
--   - Each function receives the optional p_start_date and p_end_date
--     parameters for date filtering.
--   - Combines results into a single JSONB object with keys:
--       * transaction_counts_by_type
--       * income_summary_by_source_account
--       * expense_summary_by_category_account
--       * investment_summary_by_investment_account
--       * borrow_summary_by_loan_account
--       * lend_summary_by_receivable_account
--       * adjustment_summary_by_account
--       * transfer_summary_by_to_and_from_accounts

-- Returns:
--   JSONB
--       A consolidated object containing all individual summary JSONB
--       arrays under their respective keys.

-- Notes:
--   - SECURITY DEFINER ensures execution with elevated privileges
--     while still respecting RLS policies for the current user.
--   - Useful for dashboards or reports requiring a comprehensive
--     view of all transaction activity.
--   - Each summary function handles empty results gracefully,
--     so this function will always return a complete JSONB object.
-- =========================================
CREATE OR REPLACE FUNCTION get_transactions_summary(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result JSONB := '{}'::jsonb;
BEGIN
    -- Transaction counts by type
    v_result := v_result || jsonb_build_object(
        'transaction_counts_by_type', get_transaction_counts_by_type(p_start_date, p_end_date)
    );

    -- Income summary by source account
    v_result := v_result || jsonb_build_object(
        'income_summary_by_source_account', get_income_summary_by_source_account(p_start_date, p_end_date)
    );

    -- Expense summary by category account
    v_result := v_result || jsonb_build_object(
        'expense_summary_by_category_account', get_expense_summary_by_category_account(p_start_date, p_end_date)
    );

    -- Investment summary by investment account
    v_result := v_result || jsonb_build_object(
        'investment_summary_by_investment_account', get_investment_summary_by_investment_account(p_start_date, p_end_date)
    );

    -- Borrow summary by loan account
    v_result := v_result || jsonb_build_object(
        'borrow_summary_by_loan_account', get_borrow_summary_by_loan_account(p_start_date, p_end_date)
    );

    -- Lend summary by receivable account
    v_result := v_result || jsonb_build_object(
        'lend_summary_by_receivable_account', get_lend_summary_by_receivable_account(p_start_date, p_end_date)
    );

    -- Adjustment summary by account
    v_result := v_result || jsonb_build_object(
        'adjustment_summary_by_account', get_adjustment_summary_by_account(p_start_date, p_end_date)
    );

    -- Transfer summary by to and from accounts
    v_result := v_result || jsonb_build_object(
        'transfer_summary_by_to_and_from_accounts', get_transfer_summary_by_to_and_from_accounts(p_start_date, p_end_date)
    );

    RETURN v_result;
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
GRANT EXECUTE ON FUNCTION public.create_recurring_transaction(UUID, recurrence_frequency, INT, DATE, DATE) TO authenticated;
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
GRANT EXECUTE ON FUNCTION public.get_transaction_counts_by_type(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_income_summary_by_source_account(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_expense_summary_by_category_account(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_investment_summary_by_investment_account(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_borrow_summary_by_loan_account(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_lend_summary_by_receivable_account(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_adjustment_summary_by_account(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_transfer_summary_by_to_and_from_accounts(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_transactions_summary(DATE, DATE) TO authenticated;


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
    UUID, recurrence_frequency, INT, DATE, DATE
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

COMMENT ON FUNCTION public.get_transaction_counts_by_type(DATE, DATE)
IS 'RLS-compliant function returning transaction counts by type for the current user';

COMMENT ON FUNCTION public.get_income_summary_by_source_account(DATE, DATE)
IS 'RLS-compliant function returning income summary grouped by source and account for the current user';

COMMENT ON FUNCTION public.get_expense_summary_by_category_account(DATE, DATE)
IS 'RLS-compliant function returning expense summary grouped by category and account for the current user';

COMMENT ON FUNCTION public.get_investment_summary_by_investment_account(DATE, DATE)
IS 'RLS-compliant function returning investment summary grouped by investment account for the current user';

COMMENT ON FUNCTION public.get_borrow_summary_by_loan_account(DATE, DATE)
IS 'RLS-compliant function returning borrow summary grouped by loan account for the current user';

COMMENT ON FUNCTION public.get_lend_summary_by_receivable_account(DATE, DATE)
IS 'RLS-compliant function returning lend summary grouped by receivable account for the current user';

COMMENT ON FUNCTION public.get_adjustment_summary_by_account(DATE, DATE)
IS 'RLS-compliant function returning adjustment summary grouped by account for the current user';

COMMENT ON FUNCTION public.get_transfer_summary_by_to_and_from_accounts(DATE, DATE)
IS 'RLS-compliant function returning transfer summary grouped by source and destination accounts for the current user';

COMMENT ON FUNCTION public.get_transactions_summary(DATE, DATE)
IS 'RLS-compliant master function aggregating all transaction summaries (income, expense, investment, borrow, lend, adjustment, transfer) for the current user';
