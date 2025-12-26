-- =========================================
-- Spendle: Concurrent Indexes
-- =========================================
-- These indexes improve performance on large tables.
-- Must be run outside a transaction in Supabase SQL editor.

-- -------------------------------------------------
-- 1. Transactions: Index by user and original_amount
-- Speeds up queries filtering transactions by user and original_amount.
-- Example: SELECT * FROM finance.transactions WHERE user_id = ? AND original_amount > 100;
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transactions_original_amount_range
    ON finance.transactions(user_id, original_amount)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------
-- 2. Transactions: Index by user and converted_amount
-- Speeds up queries filtering transactions by user and converted_amount.
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transactions_converted_amount_range
    ON finance.transactions(user_id, converted_amount)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------
-- 3. Transactions: Index by month (generated column)
-- Speeds up monthly aggregation/grouping queries.
-- Uses `transaction_month` populated by trigger
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transactions_transaction_month
    ON finance.transactions(user_id, transaction_month)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------
-- 4. Transactions: JSONB index for type and amount (generated column)
-- Uses `type_amount_jsonb` populated by trigger
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transaction_details_jsonb
    ON finance.transactions USING gin(type_amount_jsonb)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------
-- 5. Recent transactions (boolean column)
-- Uses `is_recent` populated by trigger
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_recent_transactions
    ON finance.transactions(user_id, transaction_date DESC)
    WHERE deleted_at IS NULL
    AND is_recent = TRUE;
