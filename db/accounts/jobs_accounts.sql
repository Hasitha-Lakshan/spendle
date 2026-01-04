-- =========================================
-- 01. Function: update_receivable_status_internal
-- =========================================
-- Purpose:
--   Updates the status of receivable accounts in batches based on
--   their `amount_due` and `due_date`.
--
-- Behavior:
--   - Iteratively updates records in batches of `p_batch_size` to
--     avoid large table locks on big tables.
--   - Sets status to:
--       * 'paid'     if amount_due <= 0
--       * 'overdue'  if due_date < CURRENT_DATE and amount_due > 0
--       * 'pending'  otherwise
--   - Skips rows where the current status already matches the computed status.
--   - Loops until all rows are processed.
--   - Raises a NOTICE indicating the total number of updated rows.
--
-- Parameters:
--   p_batch_size INTEGER (default 1000)
--     Number of rows to update per batch iteration.
--
-- Returns:
--   INTEGER
--     Total number of receivable accounts whose status was updated.
--
-- Notes:
--   - SECURITY DEFINER ensures execution under the owner's privileges.
--   - Intended for use by scheduled jobs or manual maintenance calls.
--   - Encapsulates status logic to be reused by triggers or cron jobs,
--     preventing duplication.
-- =========================================
CREATE OR REPLACE FUNCTION finance.update_receivable_status_internal(
    p_batch_size INTEGER DEFAULT 1000  -- number of rows to update per batch
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_updated_count INTEGER := 0;       -- total updated rows
    v_batch_updated INTEGER := 0;       -- rows updated in current batch
BEGIN
    LOOP
        -- Update a batch of receivable accounts with incorrect statuses
        WITH updated AS (
            UPDATE finance.receivable_accounts
            SET status = CASE
                WHEN amount_due <= 0 THEN 'paid'
                WHEN due_date < CURRENT_DATE THEN 'overdue'
                ELSE 'pending'
            END
            WHERE status != CASE
                WHEN amount_due <= 0 THEN 'paid'
                WHEN due_date < CURRENT_DATE THEN 'overdue'
                ELSE 'pending'
            END
            RETURNING 1
            LIMIT p_batch_size
        )
        SELECT COUNT(*) INTO v_batch_updated FROM updated;

        -- Add batch count to total
        v_updated_count := v_updated_count + v_batch_updated;

        -- Exit when no more rows to update
        EXIT WHEN v_batch_updated = 0;
    END LOOP;

    -- Optional notice for logs
    RAISE NOTICE 'Updated % receivable accounts statuses', v_updated_count;

    RETURN v_updated_count;
END;
$$;

-- Schedule job: run daily at midnight
SELECT cron.schedule(
    'update_receivable_status_daily',           -- job name
    '0 0 * * *',                                -- cron expression: daily at midnight
    $$ SELECT finance.update_receivable_status_internal(1000); $$  -- call with batch size
);

-- =========================================
-- 02. Function: update_loan_status_internal
-- =========================================
-- Purpose:
--   Updates the status of loan accounts in batches based on
--   their `outstanding_amount` and `end_date`.
--
-- Behavior:
--   - Iteratively updates records in batches of `p_batch_size` to
--     minimize table locking on large tables.
--   - Sets status to:
--       * 'closed'     if outstanding_amount <= 0
--       * 'defaulted'  if end_date < CURRENT_DATE and outstanding_amount > 0
--       * 'active'     otherwise
--   - Skips rows where the current status already matches the computed status.
--   - Loops until all applicable rows are processed.
--   - Raises a NOTICE indicating the total number of updated rows.
--
-- Parameters:
--   p_batch_size INTEGER (default 1000)
--     Number of rows to update per batch iteration.
--
-- Returns:
--   INTEGER
--     Total number of loan accounts whose status was updated.
--
-- Notes:
--   - SECURITY DEFINER ensures execution under the owner's privileges.
--   - Intended for use by scheduled jobs or manual maintenance calls.
--   - Encapsulates status logic to be reused by triggers or cron jobs,
--     preventing duplication.
-- =========================================
CREATE OR REPLACE FUNCTION finance.update_loan_status_internal(
    p_batch_size INTEGER DEFAULT 1000  -- number of rows to update per batch
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_updated_count INTEGER := 0;       -- total updated rows
    v_batch_updated INTEGER := 0;       -- rows updated in current batch
BEGIN
    LOOP
        -- Update a batch of loan accounts with incorrect statuses
        WITH updated AS (
            UPDATE finance.loan_accounts
            SET status = CASE
                WHEN outstanding_amount <= 0 THEN 'closed'
                WHEN end_date < CURRENT_DATE AND outstanding_amount > 0 THEN 'defaulted'
                ELSE 'active'
            END
            WHERE status != CASE
                WHEN outstanding_amount <= 0 THEN 'closed'
                WHEN end_date < CURRENT_DATE AND outstanding_amount > 0 THEN 'defaulted'
                ELSE 'active'
            END
            RETURNING 1
            LIMIT p_batch_size
        )
        SELECT COUNT(*) INTO v_batch_updated FROM updated;

        -- Add batch count to total
        v_updated_count := v_updated_count + v_batch_updated;

        -- Exit when no more rows to update
        EXIT WHEN v_batch_updated = 0;
    END LOOP;

    -- Optional notice for job logs
    RAISE NOTICE 'Updated % loan account statuses', v_updated_count;

    RETURN v_updated_count;
END;
$$;

-- Schedule job: run daily at midnight
SELECT cron.schedule(
    'update_loan_status_daily',                      -- job name
    '0 0 * * *',                                     -- cron expression: daily at midnight
    $$ SELECT finance.update_loan_status_internal(1000); $$  -- call with batch size
);
