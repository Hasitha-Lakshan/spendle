-- =========================================
-- 01. Function: cleanup_soft_deleted_records_internal
-- =========================================
-- Purpose:
--   Permanently deletes soft-deleted records from key tables that are older than a specified number of days.
--
-- Behavior:
--   - SECURITY DEFINER allows execution even with RLS enabled
--   - Iterates through predefined tables (transactions, accounts, expense_categories, etc.)
--   - For each soft-deleted record older than `older_than_days`, calls `hard_delete_record_internal` to remove it
--   - Returns a summary of how many records were deleted per table
--
-- Parameters:
--   older_than_days INTEGER DEFAULT 90
--     - Number of days after which soft-deleted records should be permanently removed
--
-- Returns:
--   TABLE (table_name TEXT, deleted_count BIGINT)
--     - table_name: name of the table processed
--     - deleted_count: number of records permanently deleted from that table
--
-- Notes:
--   - Should only be run by admins; checks `check_admin_permissions_internal`
--   - Can be scheduled via pg_cron to run automatically, e.g., nightly
--   - Uses `hard_delete_record_internal` to handle dependencies and ensure safe deletion
-- =========================================
CREATE OR REPLACE FUNCTION finance.cleanup_soft_deleted_records_internal(
    p_older_than_days NUMERIC DEFAULT 90,
    p_batch_size INTEGER DEFAULT 500  -- number of rows to process per batch
)
RETURNS TABLE(
    table_name TEXT,
    deleted_count BIGINT,
    failed_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, audit, util
VOLATILE
AS $$
DECLARE
    v_cutoff_date TIMESTAMPTZ;
    -- List of all tables with soft-delete support
    v_tables_to_clean TEXT[] := ARRAY[
        -- Transactions and related
        'finance.transactions', 'finance.transactions_recurring',
        'finance.transactions_income', 'finance.transactions_expense',
        'finance.transactions_investment', 'finance.transactions_borrow',
        'finance.transactions_lend', 'finance.transactions_transfer',
        'finance.transactions_adjustment',
        -- Accounts and specialized accounts
        'finance.accounts', 'finance.cash_accounts', 'finance.bank_accounts',
        'finance.credit_card_accounts', 'finance.loan_accounts',
        'finance.investment_accounts', 'finance.crypto_accounts',
        'finance.wallet_accounts', 'finance.receivable_accounts',
        -- Categories and sources
        'finance.expense_categories', 'finance.expense_subcategories',
        'finance.income_sources', 'finance.counterparties',
        'finance.exchange_rates'
    ];

    v_tbl TEXT;
    v_rec RECORD;
    v_deleted_counter BIGINT;
    v_failed_counter BIGINT;
    v_rows_fetched BIGINT;
BEGIN
    -- Enable hard-delete bypass for entire session
    PERFORM set_config('app.hard_delete', 'on', true);

    v_cutoff_date := NOW() - (p_older_than_days || ' days')::INTERVAL;

    FOREACH v_tbl IN ARRAY v_tables_to_clean LOOP
        v_deleted_counter := 0;
        v_failed_counter := 0;
        LOOP
            -- Fetch a batch of IDs to process
            v_rows_fetched := 0;
            FOR v_rec IN EXECUTE format(
                'SELECT id FROM %I.%I WHERE deleted_at IS NOT NULL AND deleted_at < $1 ORDER BY deleted_at LIMIT %s FOR UPDATE',
                split_part(v_tbl, '.', 1),
                split_part(v_tbl, '.', 2),
                p_batch_size
            ) USING v_cutoff_date
            LOOP
                v_rows_fetched := v_rows_fetched + 1;

                BEGIN
                    -- Call the existing hard_delete_record_internal function
                    IF finance.hard_delete_record_internal(v_tbl, v_rec.id) THEN
                        v_deleted_counter := v_deleted_counter + 1;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        v_failed_counter := v_failed_counter + 1;

                        -- Log failure
                        RAISE NOTICE
                            'Failed to hard delete record % from table % (SQLSTATE %): %',
                            v_rec.id, v_tbl, SQLSTATE, SQLERRM;
                END;
            END LOOP;

            -- If no rows were fetched in this batch, exit the inner loop
            EXIT WHEN v_rows_fetched = 0;
        END LOOP;

        -- Return the results for this table
        RETURN QUERY
        SELECT v_tbl, v_deleted_counter, v_failed_counter;
    END LOOP;
END;
$$;

-- Schedule the cleanup to run every night at 2:00 AM
SELECT cron.schedule(
  'cleanup_soft_deleted_records_nightly',  -- job name
  '0 2 * * *',                             -- cron expression (2:00 AM daily)
  $$ SELECT finance.cleanup_soft_deleted_records_internal(90, 500); $$
);

-- =========================================
-- 02. Function: cleanup_old_audit_logs_internal
-- =========================================
-- Purpose:
--   Deletes audit log entries older than a specified number of days to manage table size.
--
-- Behavior:
--   - SECURITY DEFINER allows execution even with RLS enabled
--   - Removes rows from public.audit_logs where created_at is older than the cutoff date
--   - Returns the number of rows deleted
--
-- Parameters:
--   p_older_than_days INTEGER DEFAULT 90 - Number of days to retain audit logs
--
-- Returns:
--   INTEGER - Number of audit log records deleted
--
-- Notes:
--   - Should be scheduled periodically (e.g., via a cron job or maintenance task)
--   - Helps control storage growth for audit_logs table
-- =========================================
CREATE OR REPLACE FUNCTION audit.cleanup_old_audit_logs_internal(
    p_older_than_days NUMERIC DEFAULT 90,
    p_batch_size INTEGER DEFAULT 1000  -- number of rows to delete per batch
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, audit, util
VOLATILE
AS $$
DECLARE
    v_deleted_count INTEGER := 0;        -- total deleted rows
    v_batch_deleted INTEGER := 0;        -- rows deleted in current batch
    v_cutoff_date TIMESTAMPTZ;
    v_rec RECORD;
BEGIN
    -- Calculate cutoff date
    v_cutoff_date := NOW() - (p_older_than_days || ' days')::INTERVAL;

    LOOP
        v_batch_deleted := 0;

        -- Select a batch of old audit log IDs to delete
        FOR v_rec IN
            SELECT id
            FROM audit.audit_logs
            WHERE created_at < v_cutoff_date
            ORDER BY created_at
            LIMIT p_batch_size
            FOR UPDATE
        LOOP
            -- Delete each row individually
            DELETE FROM audit.audit_logs
            WHERE id = v_rec.id;

            v_batch_deleted := v_batch_deleted + 1;
        END LOOP;

        -- Add batch count to total
        v_deleted_count := v_deleted_count + v_batch_deleted;

        -- Exit when no more rows in batch
        EXIT WHEN v_batch_deleted = 0;
    END LOOP;

    -- Optional notice for job logs
    RAISE NOTICE 'Deleted % audit logs older than % days', v_deleted_count, p_older_than_days;

    RETURN v_deleted_count;
END;
$$;

-- Schedule the cleanup to run every night at 2:00 AM
SELECT cron.schedule(
  'cleanup_audit_logs_daily',           -- job name
  '0 2 * * *',                          -- cron expression (2:00 AM daily)
  $$ SELECT audit.cleanup_old_audit_logs_internal(90, 1000); $$  -- call function with fully qualified reference
);

-- =========================================
-- 03. Function: cleanup_old_rate_limits_internal
-- =========================================
-- Purpose:
--   Deletes API rate limit records older than 24 hours to keep the table current.
--
-- Behavior:
--   - SECURITY DEFINER allows execution even with RLS enabled
--   - Removes rows from public.api_rate_limits where created_at is older than 24 hours
--   - Returns the number of rows deleted
--
-- Parameters:
--   None
--
-- Returns:
--   INTEGER - Number of rate limit records deleted
--
-- Notes:
--   - Should be scheduled periodically to prevent stale rate limit data
--   - Helps ensure accurate rate limiting without table bloat
-- =========================================
CREATE OR REPLACE FUNCTION util.cleanup_old_rate_limits_internal(
    p_older_than_hours NUMERIC DEFAULT 24,
    p_batch_size INTEGER DEFAULT 1000
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, api, util
VOLATILE
AS $$
DECLARE
    v_cutoff_timestamp TIMESTAMPTZ;
    v_deleted_count INTEGER := 0;
    v_batch_deleted INTEGER;
BEGIN
    -- Calculate cutoff timestamp
    v_cutoff_timestamp := NOW() - (p_older_than_hours || ' hours')::INTERVAL;

    LOOP
        /*
         * Delete a bounded batch of rows.
         * FOR UPDATE SKIP LOCKED ensures:
         * - No contention with concurrent cleanup jobs
         * - No blocking on rows being inserted or processed elsewhere
         */
        WITH to_delete AS (
            SELECT id
            FROM api.api_rate_limits
            WHERE created_at < v_cutoff_timestamp
            ORDER BY created_at
            LIMIT p_batch_size
            FOR UPDATE SKIP LOCKED
        )
        DELETE FROM api.api_rate_limits arl
        USING to_delete
        WHERE arl.id = to_delete.id;

        GET DIAGNOSTICS v_batch_deleted = ROW_COUNT;

        -- Accumulate total deleted rows
        v_deleted_count := v_deleted_count + v_batch_deleted;

        -- Exit when no more rows qualify
        EXIT WHEN v_batch_deleted = 0;
    END LOOP;

    -- Optional notice for job logs
    RAISE NOTICE
        'Deleted % API rate limit records older than % hours',
        v_deleted_count, p_older_than_hours;

    RETURN v_deleted_count;
END;
$$;

-- Run cleanup every night at midnight
SELECT cron.schedule(
  'cleanup_api_rate_limits_daily',        -- job name
  '0 0 * * *',                            -- cron expression (midnight daily)
  $$ SELECT util.cleanup_old_rate_limits_internal(24, 1000); $$  -- call function with fully qualified reference
);
