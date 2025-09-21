-- =========================================
-- 01. Function: create_income_transaction
-- =========================================
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

-- =========================================
-- 02. Function: create_expense_transaction
-- =========================================
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

-- =========================================
-- 03. Function: create_investment_transaction
-- =========================================
-- Create Expense Transaction
-- Purpose: Create a new expense transaction with validation
-- Parameters: account_id, amount, currency, category_id (subcategory), payment_method, notes
-- Returns: UUID of created transaction
-- Security: INVOKER (relies on RLS and triggers for validation)
-- RLS: Account and category ownership validated by RLS, transaction created with proper user_id
CREATE OR REPLACE FUNCTION create_investment_transaction(
    p_funding_account_id UUID,              -- account providing the funds (cash, bank, wallet)
    p_investment_account_id UUID,           -- account receiving the investment (investment/crypto/etc.)
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

    -- Create base transaction
    INSERT INTO transactions (user_id, type, amount, currency, notes)
    VALUES (v_user_id, 'investment', p_amount, p_currency, p_notes)
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
-- 04. Function: create_borrow_transaction
-- =========================================
-- Create Expense Transaction
-- Purpose: Create a new expense transaction with validation
-- Parameters: account_id, amount, currency, category_id (subcategory), payment_method, notes
-- Returns: UUID of created transaction
-- Security: INVOKER (relies on RLS and triggers for validation)
-- RLS: Account and category ownership validated by RLS, transaction created with proper user_id
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

    -- Insert base transaction
    INSERT INTO transactions (
        user_id,
        type,
        amount,
        currency,
        notes,
        created_month,
        type_amount_jsonb
    )
    VALUES (
        v_user_id,
        'borrow',
        p_amount,
        p_currency,
        p_notes,
        date_trunc('month', now())::date,
        jsonb_build_object('type','borrow','amount',p_amount)
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
-- Create Expense Transaction
-- Purpose: Create a new expense transaction with validation
-- Parameters: account_id, amount, currency, category_id (subcategory), payment_method, notes
-- Returns: UUID of created transaction
-- Security: INVOKER (relies on RLS and triggers for validation)
-- RLS: Account and category ownership validated by RLS, transaction created with proper user_id
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

    -- Create base transaction
    INSERT INTO transactions (
        user_id,
        type,
        amount,
        currency,
        notes,
        created_month,
        type_amount_jsonb
    )
    VALUES (
        v_user_id,
        'lend',
        p_amount,
        p_currency,
        p_notes,
        date_trunc('month', now())::date,
        jsonb_build_object('type','lend','amount',p_amount)
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
-- Create Expense Transaction
-- Purpose: Create a new expense transaction with validation
-- Parameters: account_id, amount, currency, category_id (subcategory), payment_method, notes
-- Returns: UUID of created transaction
-- Security: INVOKER (relies on RLS and triggers for validation)
-- RLS: Account and category ownership validated by RLS, transaction created with proper user_id
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

    -- Create base transaction (neutral type)
    INSERT INTO transactions (user_id, type, amount, currency, notes)
    VALUES (v_user_id, 'adjustment', p_amount, p_currency, p_notes)
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



-- =========================================
-- 03. Function: execute_transfer
-- =========================================
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
    DELETE FROM transactions WHERE id = transaction_id;
    
    RETURN TRUE;
END;
$$;



-- =========================================
-- 06. Function: create_recurring_schedule
-- =========================================
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

-- =========================================
-- 07. Function: execute_due_recurring_transactions
-- =========================================
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

-- =========================================
-- 08. Function: schedule_recurring_processing
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
SELECT cron.schedule('process-recurring', '0 0 * * *', 'SELECT schedule_recurring_processing();');

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
-- Grant Permissions
-- ================================
GRANT EXECUTE ON FUNCTION get_user_transaction_count(UUID, transaction_type, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION schedule_recurring_processing() TO authenticated;
GRANT EXECUTE ON FUNCTION get_recent_transactions(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_transactions(INTEGER, INTEGER, timestamptz, timestamptz, transaction_type) TO authenticated;
GRANT EXECUTE ON FUNCTION compute_transaction_direction(transaction_type, DECIMAL) TO authenticated;
GRANT EXECUTE ON FUNCTION get_recurring_schedules() TO authenticated;
GRANT EXECUTE ON FUNCTION execute_due_recurring_transactions(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION create_recurring_schedule(UUID, recurrence_frequency, INTEGER, DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION execute_transfer(UUID, UUID, DECIMAL, VARCHAR, transfer_method, DECIMAL, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_expense_transaction(UUID, DECIMAL, VARCHAR, UUID, payment_method, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_income_transaction(UUID, DECIMAL, VARCHAR, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_income_summary(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION get_expense_summary(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION get_investment_summary(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION get_borrow_lend_summary() TO authenticated;


-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION get_recent_transactions(INTEGER) IS 'RLS-compliant recent transactions query';
COMMENT ON FUNCTION create_recurring_schedule(UUID, recurrence_frequency, INTEGER, DATE, DATE) IS 
'RLS-compliant function to create recurring transaction schedules';
COMMENT ON FUNCTION execute_transfer(UUID, UUID, DECIMAL, VARCHAR, transfer_method, DECIMAL, TEXT) IS 
'RLS-compliant atomic transfer function using new transactions_transfer table';
COMMENT ON FUNCTION create_expense_transaction(UUID, DECIMAL, VARCHAR, UUID, payment_method, TEXT) IS 
'RLS-compliant function to create expense transactions with automatic balance updates';
COMMENT ON FUNCTION create_income_transaction(UUID, DECIMAL, VARCHAR, UUID, TEXT) IS 
'RLS-compliant function to create income transactions with automatic balance updates';
COMMENT ON FUNCTION get_income_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get income summary by source and account for current user';
COMMENT ON FUNCTION get_expense_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get expense summary by category and account for current user';
COMMENT ON FUNCTION get_investment_summary(timestamptz, timestamptz) IS 
'RLS-compliant function to get investment summary by asset type for current user';
