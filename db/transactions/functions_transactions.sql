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
--   - SECURITY INVOKER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions on transactions and transactions_income
--     handle validation and account balance updates
--   - Exchange rates are dynamically calculated using get_exchange_rate()
-- =========================================
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
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
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

    -- Get account currency
    SELECT currency INTO v_account_currency
    FROM accounts
    WHERE id = p_account_id;

    IF v_account_currency IS NULL THEN
        RAISE EXCEPTION 'Account not found';
    END IF;

    -- Get exchange rate
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);

    -- Create base transaction
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        notes
    ) VALUES (
        v_user_id,
        'income',
        p_amount,
        p_currency,
        v_exchange_rate,
        p_amount * v_exchange_rate,
        p_notes
    )
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
--   p_category_id UUID          - Optional expense category
--   p_payment_method payment_method - Payment method used (default: 'other')
--   p_notes TEXT                - Optional notes for the transaction
--
-- Returns:
--   UUID - ID of the newly created transaction
--
-- Notes:
--   - SECURITY INVOKER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions on transactions and transactions_expense
--     handle validation and account balance updates
--   - Exchange rates are dynamically calculated using get_exchange_rate()
-- =========================================
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
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
BEGIN
    -- Get current user (validated by RLS)
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    -- Validate amount is positive
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Expense amount must be positive';
    END IF;

    -- Get account currency
    SELECT currency INTO v_account_currency 
    FROM accounts 
    WHERE id = p_account_id;

    IF v_account_currency IS NULL THEN
        RAISE EXCEPTION 'Account not found';
    END IF;

    -- Get exchange rate
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);

    -- Create base transaction
    INSERT INTO transactions (
        user_id, 
        type, 
        original_amount, 
        original_currency,
        exchange_rate, 
        converted_amount, 
        notes
    ) VALUES (
        v_user_id, 
        'expense', 
        p_amount, 
        p_currency,
        v_exchange_rate, 
        p_amount * v_exchange_rate, 
        p_notes
    )
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
--   - SECURITY INVOKER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions handle account validations and balance updates
--   - Exchange rates are dynamically calculated using get_exchange_rate()
-- =========================================
CREATE OR REPLACE FUNCTION create_investment_transaction(
    p_funding_account_id UUID,              -- account providing the funds
    p_investment_account_id UUID,           -- account receiving the investment
    p_amount DECIMAL,
    p_currency VARCHAR DEFAULT 'USD',
    p_asset_type VARCHAR DEFAULT NULL,
    p_asset_symbol VARCHAR DEFAULT NULL,
    p_platform VARCHAR DEFAULT NULL,
    p_risk_level risk_level DEFAULT 'medium',
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
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
BEGIN
    -- Get current user (validated by RLS)
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    -- Validate amount is positive
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Investment amount must be positive';
    END IF;

    -- Get funding account currency
    SELECT currency INTO v_account_currency 
    FROM accounts 
    WHERE id = p_funding_account_id;

    IF v_account_currency IS NULL THEN
        RAISE EXCEPTION 'Funding account not found';
    END IF;

    -- Get exchange rate
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);

    -- Create base transaction
    INSERT INTO transactions (
        user_id, 
        type, 
        original_amount, 
        original_currency,
        exchange_rate, 
        converted_amount, 
        notes
    ) VALUES (
        v_user_id, 
        'investment', 
        p_amount, 
        p_currency,
        v_exchange_rate, 
        p_amount * v_exchange_rate, 
        p_notes
    )
    RETURNING id INTO v_transaction_id;

    -- Create investment transaction details
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
        p_asset_type,
        p_asset_symbol,
        p_platform,
        COALESCE(p_risk_level, 'medium'),
        now(),
        now()
    );

    RETURN v_transaction_id;
END;
$$;

-- =========================================
-- 05. Function: create_borrow_transaction
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
--   - SECURITY INVOKER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions handle validation of account ownership and
--     updating account balances
--   - Exchange rates are dynamically calculated using get_exchange_rate()
-- =========================================
CREATE OR REPLACE FUNCTION create_borrow_transaction(
    p_loan_account_id UUID,             -- Loan liability account
    p_disbursement_account_id UUID,     -- Account where borrowed funds go (cash, bank, wallet)
    p_amount DECIMAL,
    p_currency VARCHAR DEFAULT 'USD',
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
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
BEGIN
    -- Get current user (validated by RLS + triggers)
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    -- Validate amount
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Borrow amount must be positive';
    END IF;

    -- Get disbursement account currency (where funds are received)
    SELECT currency INTO v_account_currency 
    FROM accounts 
    WHERE id = p_disbursement_account_id;

    IF v_account_currency IS NULL THEN
        RAISE EXCEPTION 'Disbursement account not found';
    END IF;

    -- Get exchange rate
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);

    -- Insert base transaction
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        notes,
        created_month,
        type_amount_jsonb
    )
    VALUES (
        v_user_id,
        'borrow',
        p_amount,
        p_currency,
        v_exchange_rate,
        p_amount * v_exchange_rate,
        p_notes
    )
    RETURNING id INTO v_transaction_id;

    -- Insert borrow details (trigger will validate accounts and user)
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
--   - SECURITY INVOKER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions handle validation of account ownership and
--     updating account balances
--   - Exchange rates are dynamically calculated using get_exchange_rate()
-- =========================================
CREATE OR REPLACE FUNCTION create_lend_transaction(
    p_receivable_account_id UUID,       -- Where the receivable is tracked (loan asset)
    p_funding_account_id UUID,          -- Account providing funds (cash, bank, wallet)
    p_amount DECIMAL,
    p_currency VARCHAR DEFAULT 'USD',
    p_counterparty_id UUID DEFAULT NULL,
    p_interest_rate DECIMAL(5,2) DEFAULT NULL,
    p_due_date DATE DEFAULT NULL,
    p_collateral TEXT DEFAULT NULL,
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
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
BEGIN
    -- Get current user (validated by RLS + triggers)
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    -- Validate amount is positive
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Lend amount must be positive';
    END IF;

    -- Get funding account currency (source of funds)
    SELECT currency INTO v_account_currency 
    FROM accounts 
    WHERE id = p_funding_account_id;

    IF v_account_currency IS NULL THEN
        RAISE EXCEPTION 'Funding account not found';
    END IF;

    -- Get exchange rate
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);

    -- Insert base transaction
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        notes,
        created_month,
        type_amount_jsonb
    )
    VALUES (
        v_user_id,
        'lend',
        p_amount,
        p_currency,
        v_exchange_rate,
        p_amount * v_exchange_rate,
        p_notes
    )
    RETURNING id INTO v_transaction_id;

    -- Create lend transaction details (trigger validates account ownership)
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
--   - SECURITY INVOKER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions validate account ownership and
--     apply the adjustment to account balances
--   - Exchange rates are calculated dynamically using get_exchange_rate()
-- =========================================
CREATE OR REPLACE FUNCTION create_adjustment_transaction(
    p_account_id UUID,
    p_amount DECIMAL,
    p_currency VARCHAR DEFAULT 'USD',
    p_reason TEXT DEFAULT NULL,
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
    v_account_currency VARCHAR;
    v_exchange_rate NUMERIC;
BEGIN
    -- Get current user (validated by RLS)
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    -- Validate adjustment amount (cannot be zero)
    IF p_amount = 0 THEN
        RAISE EXCEPTION 'Adjustment amount cannot be zero';
    END IF;

    -- Get account currency
    SELECT currency INTO v_account_currency 
    FROM accounts 
    WHERE id = p_account_id;

    IF v_account_currency IS NULL THEN
        RAISE EXCEPTION 'Account not found';
    END IF;

    -- Get exchange rate
    v_exchange_rate := get_exchange_rate(p_currency, v_account_currency);

    -- Create base transaction (neutral type)
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        notes
    )
    VALUES (
        v_user_id,
        'adjustment',
        p_amount,
        p_currency,
        v_exchange_rate,
        p_amount * v_exchange_rate,
        p_notes
    )
    RETURNING id INTO v_transaction_id;

    -- Create adjustment details
    INSERT INTO transactions_adjustment (
        transaction_id,
        account_id,
        reason,
        created_at,
        updated_at
    )
    VALUES (
        v_transaction_id,
        p_account_id,
        p_reason,
        now(),
        now()
    );

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
--   - SECURITY INVOKER ensures the function runs with the privileges
--     of the calling user and respects RLS policies
--   - Trigger functions validate account ownership and apply balance updates
--   - Exchange rates are dynamically retrieved using get_exchange_rate()
--   - Prevents transfers between the same account
-- =========================================
CREATE OR REPLACE FUNCTION create_transfer_transaction(
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
    v_from_account_currency VARCHAR;
    v_to_account_currency VARCHAR;
    v_exchange_rate_from NUMERIC;
    v_exchange_rate_to NUMERIC;
    v_converted_amount_from DECIMAL;
    v_converted_amount_to DECIMAL;
BEGIN
    -- Get current user
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    -- Validate amount
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive';
    END IF;

    -- Prevent self-transfer
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'Cannot transfer to the same account';
    END IF;

    -- Get from_account currency
    SELECT currency INTO v_from_account_currency
    FROM accounts
    WHERE id = p_from_account;
    IF v_from_account_currency IS NULL THEN
        RAISE EXCEPTION 'From account not found';
    END IF;

    -- Get to_account currency
    SELECT currency INTO v_to_account_currency
    FROM accounts
    WHERE id = p_to_account;
    IF v_to_account_currency IS NULL THEN
        RAISE EXCEPTION 'To account not found';
    END IF;

    -- Get exchange rates
    v_exchange_rate_from := get_exchange_rate(p_currency, v_from_account_currency);
    v_exchange_rate_to := get_exchange_rate(p_currency, v_to_account_currency);

    v_converted_amount_from := p_amount * v_exchange_rate_from;
    v_converted_amount_to := p_amount * v_exchange_rate_to;

    -- Create base transaction
    INSERT INTO transactions (
        user_id,
        type,
        original_amount,
        original_currency,
        exchange_rate,
        converted_amount,
        notes,
        created_month,
        type_amount_jsonb
    )
    VALUES (
        v_user_id,
        'transfer',
        p_amount,
        p_currency,
        v_exchange_rate_from,
        v_converted_amount_from,
        p_notes
    )
    RETURNING id INTO v_transaction_id;

    -- Create transfer transaction details
    INSERT INTO transactions_transfer (
        transaction_id,
        from_account,
        to_account,
        transfer_method,
        fees,
        exchange_rate_from,
        exchange_rate_to,
        created_at,
        updated_at
    )
    VALUES (
        v_transaction_id,
        p_from_account,
        p_to_account,
        p_transfer_method,
        COALESCE(p_fees,0),
        v_exchange_rate_from,
        v_exchange_rate_to,
        now(),
        now()
    );

    RETURN v_transaction_id;
END;
$$;

-- =========================================
-- 08. Function: create_recurring_transaction
-- =========================================
-- Purpose:
--   Creates a recurring transaction based on a provided transaction type
--   ('income', 'expense', 'investment', 'borrow', 'lend', 'adjustment', 'transfer'),
--   sets up a recurring schedule, and optionally creates the first occurrence
--   immediately if the start date is today.
--
-- Behavior:
--   - Retrieves the current authenticated user (RLS‑validated)
--   - Dynamically calls the correct create_*_transaction function
--     depending on p_transaction_type, passing parameters from p_params
--   - Inserts a record into transactions_recurring with:
--       * transaction_template_id
--       * frequency and interval
--       * start_date, end_date
--       * next_occurrence
--       * user_id and action_by
--       * timestamps
--   - Immediately processes the first occurrence if start_date = CURRENT_DATE
--
-- Parameters:
--   p_transaction_type TEXT           - Type of transaction ('income', 'expense', etc.)
--   p_params JSONB                    - JSONB object containing transaction-specific parameters
--   p_frequency recurrence_frequency  - Frequency of recurrence ('daily', 'weekly', 'monthly', 'yearly')
--   p_interval INT                    - Interval between occurrences (default: 1)
--   p_start_date DATE                 - Recurrence start date (default: CURRENT_DATE)
--   p_end_date DATE                   - Recurrence end date (optional)
--
-- Returns:
--   UUID - ID of the newly created recurring transaction
--
-- Notes:
--   - SECURITY INVOKER ensures the function executes with the privileges of the caller,
--     respecting Row Level Security (RLS) policies.
--   - Relies on existing create_*_transaction functions for specific transaction creation.
--   - Ensures the user is authenticated before creating transactions.
-- =========================================
CREATE OR REPLACE FUNCTION create_recurring_transaction(
    p_transaction_type TEXT,                  -- 'income', 'expense', 'investment', etc.
    p_params JSONB,                           -- transaction-specific params
    p_frequency recurrence_frequency,
    p_interval INT DEFAULT 1,
    p_start_date DATE DEFAULT CURRENT_DATE,
    p_end_date DATE DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_transaction_id UUID;
    v_recurring_id UUID;
    v_user_id UUID;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No authenticated user found';
    END IF;

    -- Dynamically call the correct create_*_transaction
    CASE p_transaction_type
        WHEN 'income' THEN
            v_transaction_id := create_income_transaction(
                (p_params->>'account_id')::UUID,
                (p_params->>'amount')::DECIMAL,
                COALESCE(p_params->>'currency','USD'),
                (p_params->>'source_id')::UUID,
                p_params->>'notes'
            );

        WHEN 'expense' THEN
            v_transaction_id := create_expense_transaction(
                (p_params->>'account_id')::UUID,
                (p_params->>'amount')::DECIMAL,
                COALESCE(p_params->>'currency','USD'),
                (p_params->>'category_id')::UUID,
                COALESCE((p_params->>'payment_method')::payment_method, 'other'),
                p_params->>'notes'
            );

        WHEN 'investment' THEN
            v_transaction_id := create_investment_transaction(
                (p_params->>'funding_account_id')::UUID,
                (p_params->>'investment_account_id')::UUID,
                (p_params->>'amount')::DECIMAL,
                COALESCE(p_params->>'currency','USD'),
                p_params->>'asset_type',
                p_params->>'asset_symbol',
                p_params->>'platform',
                COALESCE((p_params->>'risk_level')::risk_level, 'medium'),
                p_params->>'notes'
            );

        WHEN 'borrow' THEN
            v_transaction_id := create_borrow_transaction(
                (p_params->>'loan_account_id')::UUID,
                (p_params->>'disbursement_account_id')::UUID,
                (p_params->>'amount')::DECIMAL,
                COALESCE(p_params->>'currency','USD'),
                p_params->>'notes'
            );

        WHEN 'lend' THEN
            v_transaction_id := create_lend_transaction(
                (p_params->>'receivable_account_id')::UUID,
                (p_params->>'funding_account_id')::UUID,
                (p_params->>'amount')::DECIMAL,
                COALESCE(p_params->>'currency','USD'),
                (p_params->>'counterparty_id')::UUID,
                (p_params->>'interest_rate')::DECIMAL,
                (p_params->>'due_date')::DATE,
                p_params->>'collateral',
                p_params->>'notes'
            );

        WHEN 'adjustment' THEN
            v_transaction_id := create_adjustment_transaction(
                (p_params->>'account_id')::UUID,
                (p_params->>'amount')::DECIMAL,
                COALESCE(p_params->>'currency','USD'),
                p_params->>'reason',
                p_params->>'notes'
            );

        WHEN 'transfer' THEN
            v_transaction_id := create_transfer_transaction(
                (p_params->>'from_account')::UUID,
                (p_params->>'to_account')::UUID,
                (p_params->>'amount')::DECIMAL,
                COALESCE(p_params->>'currency','USD'),
                COALESCE((p_params->>'transfer_method')::transfer_method, 'other'),
                COALESCE((p_params->>'fees')::DECIMAL, 0),
                p_params->>'notes'
            );

        ELSE
            RAISE EXCEPTION 'Unsupported recurring transaction type: %', p_transaction_type;
    END CASE;

    -- Link as recurring
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
        v_transaction_id,
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

    -- Immediately create the first transaction if start_date = today
    IF p_start_date = CURRENT_DATE THEN
        PERFORM public.process_single_recurring(v_recurring_id);
    END IF;

    RETURN v_recurring_id;
END;
$$;

-- =========================================
-- 09. Function: generate_transaction_from_template
-- =========================================
-- Purpose:
--   Generates a new transaction based on an existing recurring transaction template.
--   Copies all relevant transaction data and type‑specific details while advancing
--   the recurrence schedule.
--
-- Behavior:
--   - Fetches the recurring rule from transactions_recurring by p_recurring_id,
--     ensuring it is active and due for processing (next_occurrence <= CURRENT_DATE).
--   - Fetches the corresponding template transaction from transactions.
--   - Creates a new transaction row in transactions with base details copied from
--     the template transaction and a note indicating it was auto-generated.
--   - Copies type‑specific transaction details into the appropriate table
--     (transactions_income, transactions_expense, transactions_investment, etc.)
--   - Advances next_occurrence in transactions_recurring according to the
--     defined frequency and interval.
--
-- Parameters:
--   p_recurring_id UUID - ID of the recurring transaction rule to process.
--
-- Returns:
--   UUID - ID of the newly generated transaction, or NULL if no processing occurred.
--
-- Notes:
--   - SECURITY DEFINER ensures the function executes with elevated privileges
--     so it can bypass Row Level Security for processing recurring transactions.
--   - Only processes transactions where next_occurrence is due.
--   - Adds "[Auto-recurring <recurring_id>]" to the notes field for traceability.
-- =========================================
CREATE OR REPLACE FUNCTION public.generate_transaction_from_template(
    p_recurring_id UUID
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    rec RECORD;
    new_tx_id UUID;
    template_tx RECORD;
BEGIN
    -- Fetch the recurring rule
    SELECT *
    INTO rec
    FROM transactions_recurring
    WHERE id = p_recurring_id
      AND deleted_at IS NULL
      AND next_occurrence <= CURRENT_DATE
      AND (end_date IS NULL OR next_occurrence <= end_date);

    IF NOT FOUND THEN
        RETURN NULL; -- nothing to process
    END IF;

    -- Fetch the template transaction
    SELECT *
    INTO template_tx
    FROM transactions
    WHERE id = rec.transaction_template_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE WARNING 'Template % not found for recurring %', rec.transaction_template_id, rec.id;
        RETURN NULL;
    END IF;

    -- Insert new transaction (base)
    INSERT INTO transactions (
        user_id, type, original_amount, original_currency,
        exchange_rate, converted_amount, notes,
        created_at, updated_at
    )
    VALUES (
        template_tx.user_id,
        template_tx.type,
        template_tx.original_amount,
        template_tx.original_currency,
        template_tx.exchange_rate,
        template_tx.converted_amount,
        COALESCE(template_tx.notes, '') || ' [Auto-recurring ' || rec.id::text || ']',
        NOW(),
        NOW()
    )
    RETURNING id INTO new_tx_id;

    -- Copy type-specific details
    CASE template_tx.type
        WHEN 'income' THEN
            INSERT INTO transactions_income (transaction_id, account_id, source_id, notes, created_at, updated_at)
            SELECT new_tx_id, account_id, source_id, 'Auto-generated from recurring', NOW(), NOW()
            FROM transactions_income WHERE transaction_id = template_tx.id AND deleted_at IS NULL;

        WHEN 'expense' THEN
            INSERT INTO transactions_expense (transaction_id, account_id, category_id, payment_method, created_at, updated_at)
            SELECT new_tx_id, account_id, category_id, payment_method, NOW(), NOW()
            FROM transactions_expense WHERE transaction_id = template_tx.id AND deleted_at IS NULL;

        WHEN 'investment' THEN
            INSERT INTO transactions_investment (transaction_id, investment_account_id, funding_account_id,
                                                 asset_type, asset_symbol, platform, risk_level,
                                                 created_at, updated_at)
            SELECT new_tx_id, investment_account_id, funding_account_id,
                   asset_type, asset_symbol, platform, risk_level,
                   NOW(), NOW()
            FROM transactions_investment WHERE transaction_id = template_tx.id AND deleted_at IS NULL;

        WHEN 'adjustment' THEN
            INSERT INTO transactions_adjustment (transaction_id, account_id, reason, created_at, updated_at)
            SELECT new_tx_id, account_id, reason, NOW(), NOW()
            FROM transactions_adjustment WHERE transaction_id = template_tx.id AND deleted_at IS NULL;

        WHEN 'borrow' THEN
            INSERT INTO transactions_borrow (transaction_id, loan_account_id, disbursement_account_id,
                                             lender_id, notes, created_at, updated_at)
            SELECT new_tx_id, loan_account_id, disbursement_account_id,
                   lender_id, 'Auto-generated from recurring borrow', NOW(), NOW()
            FROM transactions_borrow WHERE transaction_id = template_tx.id AND deleted_at IS NULL;

        WHEN 'lend' THEN
            INSERT INTO transactions_lend (transaction_id, receivable_account_id, funding_account_id,
                                           counterparty_id, interest_rate, due_date, collateral,
                                           notes, created_at, updated_at)
            SELECT new_tx_id, receivable_account_id, funding_account_id,
                   counterparty_id, interest_rate, due_date, collateral,
                   'Auto-generated from recurring lend', NOW(), NOW()
            FROM transactions_lend WHERE transaction_id = template_tx.id AND deleted_at IS NULL;

        WHEN 'transfer' THEN
            INSERT INTO transactions_transfer (transaction_id, from_account, to_account, transfer_method, fees, notes,
                                               created_at, updated_at)
            SELECT new_tx_id, from_account, to_account, transfer_method, COALESCE(fees,0),
                   'Auto-generated from recurring transfer', NOW(), NOW()
            FROM transactions_transfer WHERE transaction_id = template_tx.id AND deleted_at IS NULL;
    END CASE;

    -- Advance next_occurrence
    UPDATE transactions_recurring
    SET next_occurrence = CASE rec.frequency::TEXT
            WHEN 'daily'   THEN rec.next_occurrence + (rec.interval || ' days')::interval
            WHEN 'weekly'  THEN rec.next_occurrence + (rec.interval || ' weeks')::interval
            WHEN 'monthly' THEN rec.next_occurrence + (rec.interval || ' months')::interval
            WHEN 'yearly'  THEN rec.next_occurrence + (rec.interval || ' years')::interval
        END,
        updated_at = NOW()
    WHERE id = rec.id;

    RETURN new_tx_id;
END;
$$;

-- =========================================
-- 10. Function: process_single_recurring
-- =========================================
-- Purpose:
--   Processes a single recurring transaction by generating a new transaction
--   from its template and advancing its schedule.
--
-- Behavior:
--   - Invokes generate_transaction_from_template() for the given recurring transaction ID.
--   - Ensures that the specific recurring rule is processed and the next occurrence is advanced.
--
-- Parameters:
--   p_recurring_id UUID - ID of the recurring transaction to process.
--
-- Returns:
--   UUID - ID of the newly created transaction, or NULL if no transaction was generated.
--
-- Notes:
--   - SECURITY DEFINER ensures this function runs with elevated privileges
--     so it can process transactions even if restricted by Row Level Security.
--   - Intended to be used for processing one specific recurring transaction rule at a time.
-- =========================================
CREATE OR REPLACE FUNCTION public.process_single_recurring(
    p_recurring_id UUID
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    RETURN public.generate_transaction_from_template(p_recurring_id);
END;
$$;

-- =========================================
-- 11. Function: process_recurring_transactions
-- =========================================
-- Purpose:
--   Processes all due recurring transactions by generating new transactions
--   from their templates and advancing their schedules.
--
-- Behavior:
--   - Selects all active recurring transactions where the next occurrence
--     date is today or earlier and not past the end date.
--   - Iterates over each recurring transaction and calls
--     generate_transaction_from_template() to create the corresponding transaction.
--   - Tracks the IDs of newly created transactions and counts how many
--     transactions were processed.
--
-- Returns:
--   TABLE(processed_count INT, new_transaction_ids UUID[])
--     processed_count    - Number of recurring transactions processed.
--     new_transaction_ids - Array of UUIDs of the newly created transactions.
--
-- Notes:
--   - SECURITY DEFINER ensures this function runs with elevated privileges,
--     bypassing Row Level Security to process all due recurring rules.
--   - Useful for batch processing of recurring transactions, e.g., via cron jobs.
-- =========================================
CREATE OR REPLACE FUNCTION public.process_recurring_transactions()
RETURNS TABLE(processed_count INT, new_transaction_ids UUID[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    rec RECORD;
    tx_id UUID;
    ids UUID[] := '{}';
    cnt INT := 0;
BEGIN
    FOR rec IN
        SELECT id
        FROM transactions_recurring
        WHERE deleted_at IS NULL
          AND next_occurrence <= CURRENT_DATE
          AND (end_date IS NULL OR next_occurrence <= end_date)
    LOOP
        tx_id := public.generate_transaction_from_template(rec.id);
        IF tx_id IS NOT NULL THEN
            ids := array_append(ids, tx_id);
            cnt := cnt + 1;
        END IF;
    END LOOP;

    processed_count := cnt;
    new_transaction_ids := ids;
    RETURN NEXT;
END;
$$;

-- =========================================
-- 12. Function: schedule_recurring_processing
-- =========================================
-- Purpose:
--   Acts as a scheduled entry point to process all due recurring transactions
--   and logs a system-level audit entry summarizing the processing run.
--
-- Behavior:
--   - Sets a dedicated system user ID in session configuration for audit logging.
--   - Calls process_recurring_transactions() to generate all due transactions
--     from recurring templates.
--   - Collects the count of processed recurring transactions and their IDs.
--   - Builds a summary message describing the processing outcome.
--   - Inserts an audit log entry in the audit_logs table with:
--       * user_id and action_by set to the system user ID
--       * table_name set to 'system'
--       * action set to 'RECURRING_PROCESSING'
--       * new_data containing processed_count, new_transaction_ids, and timestamp.
--
-- Returns:
--   TEXT - A summary message describing:
--       * Number of recurring transactions processed
--       * Execution timestamp
--       * List of new transaction IDs created
--
-- Notes:
--   - SECURITY DEFINER ensures this function runs with elevated privileges,
--     bypassing Row Level Security so that all due recurring transactions
--     can be processed by a scheduled job.
--   - Designed to be called by a scheduler (e.g., pg_cron).
--   - Uses a dedicated system user ID for audit clarity rather than relying
--     on session user context.
-- =========================================
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
    PERFORM set_config('app.system_user_id', '00000000-0000-0000-0000-000000000000', true);
    -- Process all due recurring transactions
    SELECT processed_count, new_transaction_ids INTO result_record 
    FROM public.process_recurring_transactions();

    -- Build log message
    processing_result := format(
        'Processed %s recurring transactions at %s. New transaction IDs: %s',
        COALESCE(result_record.processed_count, 0),
        NOW()::TEXT,
        COALESCE(array_to_string(result_record.new_transaction_ids, ', '), 'none')
    );

    -- Log the processing result in audit logs
    INSERT INTO public.audit_logs(
        user_id,
        action_by,
        table_name,
        record_id,
        action,
        new_data
    )
    VALUES (
        current_setting('app.system_user_id')::uuid, -- dedicated system user
        current_setting('app.system_user_id')::uuid, -- same system user
        'system',
        gen_random_uuid(),
        'RECURRING_PROCESSING',
        jsonb_build_object(
            'processed_count', COALESCE(result_record.processed_count, 0),
            'new_transaction_ids', result_record.new_transaction_ids,
            'processed_at', NOW()
        )
    );
    RETURN processing_result;
END;
$$;

-- Note: Uncomment the following line if pg_cron extension is available
SELECT cron.schedule('process-recurring', '0 0 * * *', 'SELECT schedule_recurring_processing();');

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
-- 04. Function: hard_delete_transaction
-- =========================================
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
    DELETE FROM transactions WHERE id = transaction_id RETURNING id INTO transaction_id;

    IF transaction_id IS NULL THEN
        RAISE EXCEPTION 'Transaction deletion failed';
    END IF;

    RETURN TRUE;
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
                'reason', ta.reason
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
-- 05. Function: hard_delete_recurring_transaction
-- =========================================
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
    SELECT user_id, transaction_template_id
    INTO recurring_owner, template_transaction_id
    FROM transactions_recurring
    WHERE id = recurring_id
      AND deleted_at IS NULL;

    IF recurring_owner IS NULL THEN
        RAISE EXCEPTION 'Recurring transaction not found';
    END IF;

    -- Check permissions
    is_admin := check_admin_permissions();
    IF NOT is_admin AND current_user_id != recurring_owner THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    -- Soft-delete recurring schedule
    UPDATE transactions_recurring
    SET deleted_at = NOW()
    WHERE id = recurring_id;

    -- Hard delete the template transaction if desired
    IF template_transaction_id IS NOT NULL THEN
        PERFORM hard_delete_transaction(template_transaction_id);
    END IF;

    RETURN TRUE;
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
GRANT EXECUTE ON FUNCTION create_income_transaction(UUID, DECIMAL, VARCHAR, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_expense_transaction(UUID, DECIMAL, VARCHAR, UUID, payment_method, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_investment_transaction(UUID, UUID, DECIMAL, VARCHAR, VARCHAR, VARCHAR, VARCHAR, risk_level, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_borrow_transaction(UUID, UUID, DECIMAL, VARCHAR, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_lend_transaction(UUID, UUID, DECIMAL, VARCHAR, UUID, DECIMAL, DATE, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_adjustment_transaction(UUID, DECIMAL, VARCHAR, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_transfer_transaction( UUID, UUID, DECIMAL, VARCHAR, transfer_method, DECIMAL, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_recurring_transaction(TEXT, JSONB, recurrence_frequency, INT, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION process_recurring_transactions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_transaction_from_template(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_single_recurring(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION schedule_recurring_processing() TO authenticated;

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
COMMENT ON FUNCTION create_income_transaction(
    UUID, DECIMAL, VARCHAR, UUID, TEXT
) IS 'RLS-compliant function to create income transactions with validation and automatic balance updates';

COMMENT ON FUNCTION create_expense_transaction(
    UUID, DECIMAL, VARCHAR, UUID, payment_method, TEXT
) IS 'RLS-compliant function to create expense transactions with validation and automatic balance updates';

COMMENT ON FUNCTION create_investment_transaction(
    UUID, UUID, DECIMAL, VARCHAR, VARCHAR, VARCHAR, VARCHAR, risk_level, TEXT
) IS 'RLS-compliant function to create investment transactions with validation and automatic balance updates';

COMMENT ON FUNCTION create_borrow_transaction(
    UUID, UUID, DECIMAL, VARCHAR, TEXT
) IS 'RLS-compliant function to create borrow transactions with validation and automatic balance updates';

COMMENT ON FUNCTION create_lend_transaction(
    UUID, UUID, DECIMAL, VARCHAR, UUID, DECIMAL, DATE, TEXT, TEXT
) IS 'RLS-compliant function to create lend transactions with validation and automatic balance updates';

COMMENT ON FUNCTION create_adjustment_transaction(
    UUID, DECIMAL, VARCHAR, TEXT, TEXT
) IS 'RLS-compliant function to create adjustment transactions for corrections or balance fixes with validation and automatic balance updates';

COMMENT ON FUNCTION create_transfer_transaction(
    UUID, UUID, DECIMAL, VARCHAR, transfer_method, DECIMAL, TEXT
) IS 
'RLS-compliant function to create transfer transactions between two accounts with validation and automatic balance updates';

COMMENT ON FUNCTION create_recurring_transaction(
    TEXT, JSONB, recurrence_frequency, INT, DATE, DATE
) IS 'Creates a recurring transaction of a specified type and stores a template in transactions_recurring table for automated processing. Handles income, expense, investment, adjustment, borrow, lend, and transfer transaction types.';

COMMENT ON FUNCTION process_recurring_transactions() IS 'Processes all active recurring transactions due for execution, creating new transactions based on templates and advancing the schedule.';

COMMENT ON FUNCTION public.generate_transaction_from_template(UUID) IS
'Generates a new transaction from a recurring transaction template.
Fetches the recurring rule and template transaction, inserts a new transaction record,
copies type-specific details, advances the next_occurrence date, and returns the new transaction UUID.';

COMMENT ON FUNCTION public.process_single_recurring(UUID) IS
'Processes a single due recurring transaction by generating a transaction from its template. Returns the new transaction UUID or NULL if not processed.';

COMMENT ON FUNCTION schedule_recurring_processing() IS 'Triggers processing of due recurring transactions and logs the result to audit_logs table. Intended for scheduled execution (e.g., with pg_cron).';


COMMENT ON FUNCTION get_recent_transactions(INTEGER) IS 'RLS-compliant recent transactions query';
COMMENT ON FUNCTION get_income_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get income summary by source and account for current user';
COMMENT ON FUNCTION get_expense_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get expense summary by category and account for current user';
COMMENT ON FUNCTION get_investment_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get investment summary by asset type for current user';
CREATE INDEX IF NOT EXISTS idx_transactions_recurring_user_deleted 
ON transactions_recurring(user_id, deleted_at) WHERE deleted_at IS NULL;