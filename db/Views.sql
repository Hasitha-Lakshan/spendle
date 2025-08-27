-- =========================================
-- VIEWS FOR SPENDLE DATABASE
-- =========================================
-- enhance functionality, performance, and usability.
-- =========================================

-- Unified Account Balance View
-- Purpose: Single view to get current balances across all account types
CREATE OR REPLACE VIEW v_account_balances 
WITH (security_invoker=on) AS
SELECT 
    a.id AS account_id,
    a.user_id,
    a.account_name,
    a.type AS account_type,
    a.currency,
    CASE a.type
        WHEN 'cash' THEN ca.balance
        WHEN 'bank' THEN ba.balance
        WHEN 'wallet' THEN wa.balance
        WHEN 'crypto' THEN cra.balance
        WHEN 'credit_card' THEN -cca.current_balance  -- negative liability
        WHEN 'loan' THEN -la.outstanding_amount       -- negative liability
        WHEN 'investment' THEN ia.portfolio_value
        WHEN 'receivable' THEN ra.amount_due
    END AS current_balance,
    CASE a.type
        WHEN 'cash' THEN ca.status
        WHEN 'bank' THEN ba.status
        WHEN 'wallet' THEN wa.status
        WHEN 'crypto' THEN cra.status
        WHEN 'credit_card' THEN cca.status
        WHEN 'loan' THEN la.status
        WHEN 'investment' THEN ia.status
        WHEN 'receivable' THEN ra.status
    END AS account_status,
    -- Additional type-specific information
    CASE a.type
        WHEN 'credit_card' THEN cca.credit_limit
        WHEN 'loan' THEN la.principal_amount
        ELSE NULL
    END AS credit_limit_or_principal,
    a.created_at,
    a.updated_at,
    GREATEST(
        a.updated_at,
        COALESCE(ca.updated_at, '1970-01-01'::timestamptz),
        COALESCE(ba.updated_at, '1970-01-01'::timestamptz),
        COALESCE(wa.updated_at, '1970-01-01'::timestamptz),
        COALESCE(cra.updated_at, '1970-01-01'::timestamptz),
        COALESCE(cca.updated_at, '1970-01-01'::timestamptz),
        COALESCE(la.updated_at, '1970-01-01'::timestamptz),
        COALESCE(ia.updated_at, '1970-01-01'::timestamptz),
        COALESCE(ra.updated_at, '1970-01-01'::timestamptz)
    ) AS last_activity
FROM accounts a
LEFT JOIN cash_accounts ca ON a.id = ca.account_id AND ca.deleted_at IS NULL
LEFT JOIN bank_accounts ba ON a.id = ba.account_id AND ba.deleted_at IS NULL
LEFT JOIN wallet_accounts wa ON a.id = wa.account_id AND wa.deleted_at IS NULL
LEFT JOIN crypto_accounts cra ON a.id = cra.account_id AND cra.deleted_at IS NULL
LEFT JOIN credit_card_accounts cca ON a.id = cca.account_id AND cca.deleted_at IS NULL
LEFT JOIN loan_accounts la ON a.id = la.account_id AND la.deleted_at IS NULL
LEFT JOIN investment_accounts ia ON a.id = ia.account_id AND ia.deleted_at IS NULL
LEFT JOIN receivable_accounts ra ON a.id = ra.account_id AND ra.deleted_at IS NULL
WHERE a.deleted_at IS NULL 
  AND a.user_id = auth.uid();

-- Transaction Summary View with Enhanced Details
CREATE OR REPLACE VIEW v_transaction_details
WITH (security_invoker=on) AS
SELECT 
    t.id as transaction_id,
    t.user_id,
    t.type as transaction_type,
    t.amount,
    t.currency,
    t.notes as transaction_notes,
    t.created_at,
    t.updated_at,
    
    -- Account information
    COALESCE(
        ti.account_id, te.account_id, tinv.account_id, 
        tb.account_id, tl.account_id, ta.account_id
    ) as primary_account_id,
    
    -- Transfer-specific accounts
    tt.from_account,
    tt.to_account,
    tt.fees as transfer_fees,
    
    -- Transaction direction
    CASE
        WHEN t.type = 'income' THEN 'inflow'
        WHEN t.type = 'expense' THEN 'outflow'
        WHEN t.type = 'borrow' AND t.amount >= 0 THEN 'inflow'
        WHEN t.type = 'borrow' AND t.amount < 0 THEN 'outflow'
        WHEN t.type = 'lend' AND t.amount >= 0 THEN 'outflow'
        WHEN t.type = 'lend' AND t.amount < 0 THEN 'inflow'
        WHEN t.type = 'investment' AND t.amount >= 0 THEN 'outflow'
        WHEN t.type = 'investment' AND t.amount < 0 THEN 'inflow'
        WHEN t.type = 'adjustment' AND t.amount >= 0 THEN 'inflow'
        WHEN t.type = 'adjustment' AND t.amount < 0 THEN 'outflow'
        WHEN t.type = 'transfer' THEN 'neutral'
        ELSE 'unknown'
    END::transaction_direction as direction,
    
    -- Type-specific details as JSONB
    CASE 
        WHEN t.type = 'income' THEN jsonb_build_object(
            'account_id', ti.account_id,
            'source_id', ti.source_id,
            'source_name', ins.name,
            'notes', ti.notes
        )
        WHEN t.type = 'expense' THEN jsonb_build_object(
            'account_id', te.account_id,
            'category_id', te.category_id,
            'subcategory_name', es.name,
            'category_name', ec.name,
            'payment_method', te.payment_method
        )
        WHEN t.type = 'investment' THEN jsonb_build_object(
            'account_id', tinv.account_id,
            'asset_type', tinv.asset_type,
            'asset_symbol', tinv.asset_symbol,
            'platform', tinv.platform,
            'risk_level', tinv.risk_level
        )
        WHEN t.type = 'borrow' THEN jsonb_build_object(
            'account_id', tb.account_id,
            'counterparty_id', tb.counterparty_id,
            'counterparty_name', cp_b.name,
            'interest_rate', tb.interest_rate,
            'due_date', tb.due_date,
            'collateral', tb.collateral
        )
        WHEN t.type = 'lend' THEN jsonb_build_object(
            'account_id', tl.account_id,
            'counterparty_id', tl.counterparty_id,
            'counterparty_name', cp_l.name,
            'interest_rate', tl.interest_rate,
            'due_date', tl.due_date,
            'collateral', tl.collateral
        )
        WHEN t.type = 'transfer' THEN jsonb_build_object(
            'from_account', tt.from_account,
            'to_account', tt.to_account,
            'from_account_name', a_from.account_name,
            'to_account_name', a_to.account_name,
            'transfer_method', tt.transfer_method,
            'fees', tt.fees
        )
        WHEN t.type = 'adjustment' THEN jsonb_build_object(
            'account_id', ta.account_id,
            'reason', ta.reason
        )
        ELSE NULL
    END as type_details

FROM transactions t
LEFT JOIN transactions_income ti ON t.id = ti.transaction_id AND ti.deleted_at IS NULL
LEFT JOIN transactions_expense te ON t.id = te.transaction_id AND te.deleted_at IS NULL
LEFT JOIN transactions_investment tinv ON t.id = tinv.transaction_id AND tinv.deleted_at IS NULL
LEFT JOIN transactions_borrow tb ON t.id = tb.transaction_id AND tb.deleted_at IS NULL
LEFT JOIN transactions_lend tl ON t.id = tl.transaction_id AND tl.deleted_at IS NULL
LEFT JOIN transactions_transfer tt ON t.id = tt.transaction_id AND tt.deleted_at IS NULL
LEFT JOIN transactions_adjustment ta ON t.id = ta.transaction_id AND ta.deleted_at IS NULL

-- Join related entities
LEFT JOIN income_sources ins ON ti.source_id = ins.id AND ins.deleted_at IS NULL
LEFT JOIN expense_subcategories es ON te.category_id = es.id AND es.deleted_at IS NULL
LEFT JOIN expense_categories ec ON es.category_id = ec.id AND ec.deleted_at IS NULL
LEFT JOIN counterparties cp_b ON tb.counterparty_id = cp_b.id AND cp_b.deleted_at IS NULL
LEFT JOIN counterparties cp_l ON tl.counterparty_id = cp_l.id AND cp_l.deleted_at IS NULL
LEFT JOIN accounts a_from ON tt.from_account = a_from.id AND a_from.deleted_at IS NULL
LEFT JOIN accounts a_to ON tt.to_account = a_to.id AND a_to.deleted_at IS NULL

WHERE t.deleted_at IS NULL 
  AND t.user_id = auth.uid();

-- Net Worth Calculation View
CREATE OR REPLACE VIEW v_user_net_worth
WITH (security_invoker=on) AS
SELECT 
    user_id,
    currency,
    SUM(CASE 
        WHEN account_type IN ('cash','bank','investment','crypto','wallet','receivable')
        THEN current_balance
        ELSE 0
    END) AS total_assets,
    SUM(CASE 
        WHEN account_type IN ('credit_card','loan')
        THEN -current_balance
        ELSE 0
    END) AS total_liabilities,
    SUM(CASE 
        WHEN account_type IN ('cash','bank','investment','crypto','wallet','receivable')
        THEN current_balance
        ELSE -current_balance
    END) AS net_worth,
    COUNT(*) AS total_accounts,
    MAX(last_activity) AS last_updated
FROM v_account_balances
WHERE account_status = 'active'
GROUP BY user_id, currency;

-- Monthly Transaction Summaries
CREATE OR REPLACE VIEW v_monthly_transaction_summary
WITH (security_invoker=on) AS
SELECT 
    user_id,
    currency,
    DATE_TRUNC('month', created_at) AS month_year,
    type AS transaction_type,
    COUNT(*) AS transaction_count,
    SUM(amount) AS total_amount,
    AVG(amount) AS average_amount,
    MIN(amount) AS min_amount,
    MAX(amount) AS max_amount
FROM transactions
WHERE deleted_at IS NULL
  AND user_id = auth.uid()
GROUP BY user_id, currency, DATE_TRUNC('month', created_at), type;

-- =========================================
-- GRANT PERMISSIONS
-- =========================================

GRANT SELECT ON v_account_balances TO authenticated;
GRANT SELECT ON v_transaction_details TO authenticated;
GRANT SELECT ON v_user_net_worth TO authenticated;
GRANT SELECT ON v_monthly_transaction_summary TO authenticated;

-- =========================================
-- COMMENTS AND DOCUMENTATION
-- =========================================

COMMENT ON VIEW v_account_balances IS 'Unified view of account balances across all account types with RLS';
COMMENT ON VIEW v_transaction_details IS 'Enhanced transaction details with type-specific information as JSONB';
COMMENT ON VIEW v_user_net_worth IS 'Per-user net worth calculation by currency';
COMMENT ON VIEW v_monthly_transaction_summary IS 'Monthly transaction summaries with counts and aggregates per user';
