-- ===============================================================================
-- 1. Partial UNIQUE indexes (soft-delete aware)
-- ===============================================================================
-- Active exchange rates per user + currency pair
CREATE UNIQUE INDEX IF NOT EXISTS exchange_rates_user_from_to_active_unique
ON finance.exchange_rates (profile_id, from_currency, to_currency)
WHERE deleted_at IS NULL;

-- Active accounts per user, account name, and type (case-insensitive)
CREATE UNIQUE INDEX IF NOT EXISTS accounts_user_name_type_active_unique
ON finance.accounts (profile_id, lower(account_name), type)
WHERE deleted_at IS NULL;

-- Active expense categories per user
CREATE UNIQUE INDEX IF NOT EXISTS expense_categories_user_name_active_unique
ON finance.expense_categories (profile_id, lower(name))
WHERE deleted_at IS NULL;

-- Active expense subcategories per category
CREATE UNIQUE INDEX IF NOT EXISTS expense_subcategories_category_name_active_unique
ON finance.expense_subcategories (category_id, lower(name))
WHERE deleted_at IS NULL;

-- Active income sources per user
CREATE UNIQUE INDEX IF NOT EXISTS income_sources_user_name_active_unique
ON finance.income_sources (profile_id, lower(name))
WHERE deleted_at IS NULL;

-- Active counterparties per user + name + type
CREATE UNIQUE INDEX IF NOT EXISTS counterparties_user_name_type_active_unique
ON finance.counterparties (profile_id, lower(name), type)
WHERE deleted_at IS NULL;

-- Active recurring transaction templates
CREATE UNIQUE INDEX IF NOT EXISTS transactions_recurring_template_active_unique
ON finance.transactions_recurring (transaction_template_id)
WHERE deleted_at IS NULL;

-- ===============================================================================
-- 2. Foreign key / per-user indexes (for RLS and joins)
-- ===============================================================================
CREATE INDEX IF NOT EXISTS idx_accounts_profile_id ON finance.accounts(profile_id);
CREATE INDEX IF NOT EXISTS idx_expense_categories_profile_id ON finance.expense_categories(profile_id);
CREATE INDEX IF NOT EXISTS idx_expense_subcategories_category_id ON finance.expense_subcategories(category_id);
CREATE INDEX IF NOT EXISTS idx_income_sources_profile_id ON finance.income_sources(profile_id);
CREATE INDEX IF NOT EXISTS idx_counterparties_profile_id ON finance.counterparties(profile_id);

CREATE INDEX IF NOT EXISTS idx_transactions_profile_id ON finance.transactions(profile_id);
CREATE INDEX IF NOT EXISTS idx_transactions_type ON finance.transactions(type);

-- ===============================================================================
-- 3. Soft-delete-aware partial indexes
-- ===============================================================================
CREATE INDEX IF NOT EXISTS idx_accounts_active ON finance.accounts(profile_id, type) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_transactions_active ON finance.transactions(profile_id, created_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_counterparties_active ON finance.counterparties(profile_id, type) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_expense_categories_active ON finance.expense_categories(profile_id, name) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_expense_subcategories_active ON finance.expense_subcategories(category_id, name) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_income_sources_active ON finance.income_sources(profile_id, name) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_transactions_recurring_deleted_at ON finance.transactions_recurring(deleted_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_transactions_deleted_at ON finance.transactions(deleted_at);

-- ===============================================================================
-- 4. Transactions-specific indexes (for analytics & reports)
-- ===============================================================================
-- Filter by date / type for per-user queries
CREATE INDEX IF NOT EXISTS idx_transactions_user_transaction_date 
    ON finance.transactions(profile_id, transaction_date DESC) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_user_type_transaction_date
    ON finance.transactions(profile_id, type, transaction_date DESC) WHERE deleted_at IS NULL;

-- ===============================================================================
-- 5. Transaction-type table indexes
-- ===============================================================================
-- Income
CREATE INDEX IF NOT EXISTS idx_txi_txid ON finance.transactions_income(transaction_id);
CREATE INDEX IF NOT EXISTS idx_txi_account_id ON finance.transactions_income(account_id);

-- Expense
CREATE INDEX IF NOT EXISTS idx_txe_txid ON finance.transactions_expense(transaction_id);
CREATE INDEX IF NOT EXISTS idx_txe_account_id ON finance.transactions_expense(account_id);
CREATE INDEX IF NOT EXISTS idx_txe_category_id ON finance.transactions_expense(category_id);

-- Investment
CREATE INDEX IF NOT EXISTS idx_txin_txid ON finance.transactions_investment(transaction_id);
CREATE INDEX IF NOT EXISTS idx_txin_funding_account_id ON finance.transactions_investment(funding_account_id);
CREATE INDEX IF NOT EXISTS idx_txin_investment_account_id ON finance.transactions_investment(investment_account_id);

-- Borrow
CREATE INDEX IF NOT EXISTS idx_txb_txid ON finance.transactions_borrow(transaction_id);
CREATE INDEX IF NOT EXISTS idx_txb_loan_account_id ON finance.transactions_borrow(loan_account_id);
CREATE INDEX IF NOT EXISTS idx_txb_disbursement_account_id ON finance.transactions_borrow(disbursement_account_id);

-- Lend
CREATE INDEX IF NOT EXISTS idx_txl_txid ON finance.transactions_lend(transaction_id);
CREATE INDEX IF NOT EXISTS idx_txl_funding_account_id ON finance.transactions_lend(funding_account_id);
CREATE INDEX IF NOT EXISTS idx_txl_receivable_account_id ON finance.transactions_lend(receivable_account_id);

-- Transfer
CREATE INDEX IF NOT EXISTS idx_txt_txid ON finance.transactions_transfer(transaction_id);
CREATE INDEX IF NOT EXISTS idx_txt_from_account ON finance.transactions_transfer(from_account);
CREATE INDEX IF NOT EXISTS idx_txt_to_account ON finance.transactions_transfer(to_account);

-- Adjustment
CREATE INDEX IF NOT EXISTS idx_txa_txid ON finance.transactions_adjustment(transaction_id);
CREATE INDEX IF NOT EXISTS idx_txa_account_id ON finance.transactions_adjustment(account_id);

-- ===============================================================================
-- 6. Audit log indexes
-- ===============================================================================
-- Common lookups
CREATE INDEX IF NOT EXISTS idx_audit_user_table_record 
    ON audit.audit_logs(profile_id, table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_executed_by ON audit.audit_logs(executed_by);
CREATE INDEX IF NOT EXISTS idx_audit_created_at ON audit.audit_logs(created_at);

-- JSONB lookups
CREATE INDEX IF NOT EXISTS idx_audit_old_data_gin ON audit.audit_logs USING gin(old_data);
CREATE INDEX IF NOT EXISTS idx_audit_new_data_gin ON audit.audit_logs USING gin(new_data);

-- Numeric expression indexes for filtering
CREATE INDEX IF NOT EXISTS idx_audit_old_original_amount ON audit.audit_logs ((old_data->>'original_amount'));
CREATE INDEX IF NOT EXISTS idx_audit_new_original_amount ON audit.audit_logs ((new_data->>'original_amount'));
CREATE INDEX IF NOT EXISTS idx_audit_old_converted_amount ON audit.audit_logs ((old_data->>'converted_amount'));
CREATE INDEX IF NOT EXISTS idx_audit_new_converted_amount ON audit.audit_logs ((new_data->>'converted_amount'));

-- ===============================================================================
-- 7. Other utility / API indexes
-- ===============================================================================
-- API rate-limits
CREATE INDEX IF NOT EXISTS idx_rate_limits_user_endpoint 
    ON api.api_rate_limits(profile_id, endpoint, last_request_at);

-- Cleanup / retention support
CREATE INDEX IF NOT EXISTS idx_api_rate_limits_created_at
    ON api.api_rate_limits(created_at);

-- ===============================================================================
-- 8. Concurrent Indexes for finance.transaction
-- ===============================================================================
-- Transactions: Index by user and original_amount
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transactions_original_amount_range
    ON finance.transactions(profile_id, original_amount)
    WHERE deleted_at IS NULL;

-- Transactions: Index by user and converted_amount
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transactions_converted_amount_range
    ON finance.transactions(profile_id, converted_amount)
    WHERE deleted_at IS NULL;

-- Transactions: Index by month (generated column)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transactions_transaction_month
    ON finance.transactions(profile_id, transaction_month)
    WHERE deleted_at IS NULL;

-- Transactions: JSONB index for type and amount (generated column)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transaction_details_jsonb
    ON finance.transactions USING gin(type_amount_jsonb)
    WHERE deleted_at IS NULL;

-- Recent transactions (boolean column)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_recent_transactions
    ON finance.transactions(profile_id, transaction_date DESC)
    WHERE deleted_at IS NULL
    AND is_recent = TRUE;
