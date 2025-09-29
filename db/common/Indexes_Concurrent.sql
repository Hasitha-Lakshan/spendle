-- =========================================
-- Spendle: Concurrent Indexes
-- =========================================
-- These indexes improve performance on large tables.
-- Must be run outside a transaction in Supabase SQL editor.

-- -------------------------------------------------
-- 1. Transactions: Index by user and original_amount
-- Speeds up queries filtering transactions by user and original_amount.
-- Example: SELECT * FROM transactions WHERE user_id = ? AND original_amount > 100;
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transactions_original_amount_range
    ON transactions(user_id, original_amount)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------
-- 2. Transactions: Index by user and converted_amount
-- Speeds up queries filtering transactions by user and converted_amount.
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transactions_converted_amount_range
    ON transactions(user_id, converted_amount)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------
-- 3. Transactions: Index by month (generated column)
-- Speeds up monthly aggregation/grouping queries.
-- Uses `created_month` populated by trigger
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transactions_created_month
    ON transactions(user_id, created_month)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------
-- 4. Transactions: JSONB index for type and amount (generated column)
-- Uses `type_amount_jsonb` populated by trigger
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_transaction_details_jsonb
    ON transactions USING gin(type_amount_jsonb)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------
-- 5. Recent transactions (boolean column)
-- Uses `is_recent` populated by trigger
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_recent_transactions
    ON transactions(user_id, created_at DESC)
    WHERE deleted_at IS NULL
    AND is_recent = TRUE;

-- -------------------------------------------------
-- 6. Large transactions
-- Optimizes queries for high-value transactions (original_amount > 1000).
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_large_transactions_original_amount
    ON transactions(user_id, original_amount DESC)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------
-- 7. Large converted transactions
-- Optimizes queries for high-value converted_amount transactions.
-- -------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_large_transactions_converted_amount
    ON transactions(user_id, converted_amount DESC)
    WHERE deleted_at IS NULL;
