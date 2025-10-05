-- =========================================
-- 01. Function: validate_transaction_user
-- =========================================
-- Purpose:
--   Ensures that a transaction being inserted is associated with the
--   correct user and account. Prevents unauthorized or mismatched entries.
--
-- Behavior:
--   - Checks that the account exists, is not deleted, and belongs to the current user
--   - Checks that the transaction exists, is not deleted, and belongs to the current user
--   - Raises an exception if either the account or transaction is missing or access is denied
--   - Raises an exception if the transaction user_id does not match the account user_id
--
-- Parameters:
--   NEW (trigger record) - The new row being inserted
--
-- Returns:
--   NEW - The original row if validation passes
--
-- Notes:
--   - Trigger is applied BEFORE INSERT on all transaction detail tables:
--       transactions_income, transactions_expense, transactions_investment,
--       transactions_adjustment, transactions_borrow, transactions_lend
--   - Uses SECURITY DEFINER to enforce consistent validation regardless of RLS
--   - Ensures that transaction ownership and account-user relationships are always correct
-- =========================================
CREATE OR REPLACE FUNCTION validate_transaction_user() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE 
    v_account_user UUID;
    v_tx_user UUID;
BEGIN
    -- Determine account_id based on table
    IF TG_TABLE_NAME = 'transactions_borrow' THEN
        -- Validate main loan account
        SELECT user_id INTO v_account_user 
        FROM public.accounts 
        WHERE id = NEW.loan_account_id 
          AND user_id = auth.uid()
          AND deleted_at IS NULL;

        -- Validate disbursement account if provided
        IF NEW.disbursement_account_id IS NOT NULL THEN
            PERFORM 1 
            FROM public.accounts 
            WHERE id = NEW.disbursement_account_id 
              AND user_id = auth.uid() 
              AND deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Disbursement account invalid or access denied';
            END IF;
        END IF;

    ELSIF TG_TABLE_NAME = 'transactions_lend' THEN
        -- Validate main receivable account
        SELECT user_id INTO v_account_user 
        FROM public.accounts 
        WHERE id = NEW.receivable_account_id 
          AND user_id = auth.uid()
          AND deleted_at IS NULL;

        -- Validate funding account if provided
        IF NEW.funding_account_id IS NOT NULL THEN
            PERFORM 1 
            FROM public.accounts 
            WHERE id = NEW.funding_account_id 
              AND user_id = auth.uid() 
              AND deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Funding account invalid or access denied';
            END IF;
        END IF;

    ELSIF TG_TABLE_NAME = 'transactions_investment' THEN
        -- Validate main investment account
        SELECT user_id INTO v_account_user 
        FROM public.accounts 
        WHERE id = NEW.investment_account_id 
          AND user_id = auth.uid()
          AND deleted_at IS NULL;

        -- Validate funding account if provided
        IF NEW.funding_account_id IS NOT NULL THEN
            PERFORM 1 
            FROM public.accounts 
            WHERE id = NEW.funding_account_id 
              AND user_id = auth.uid() 
              AND deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Funding account invalid or access denied';
            END IF;
        END IF;

    ELSIF TG_TABLE_NAME = 'transactions_transfer' THEN
        -- Prevent transfers from an account to itself
        IF NEW.from_account = NEW.to_account THEN
            RAISE EXCEPTION 'Cannot transfer from an account to itself';
        END IF;

        -- Validate from_account belongs to current user
        PERFORM 1
        FROM public.accounts
        WHERE id = NEW.from_account
          AND user_id = auth.uid()
          AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'From account invalid or access denied';
        END IF;

        -- Validate to_account belongs to current user
        PERFORM 1
        FROM public.accounts
        WHERE id = NEW.to_account
          AND user_id = auth.uid()
          AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'To account invalid or access denied';
        END IF;

        -- Set account_user for final check
        v_account_user := auth.uid();

    ELSE
        -- Generic account validation
        SELECT user_id INTO v_account_user 
        FROM public.accounts 
        WHERE id = NEW.account_id 
          AND user_id = auth.uid()
          AND deleted_at IS NULL;
    END IF;
    
    -- Validate transaction user
    SELECT user_id INTO v_tx_user 
    FROM public.transactions 
    WHERE id = NEW.transaction_id 
      AND user_id = auth.uid()
      AND deleted_at IS NULL;
    
    IF v_account_user IS NULL OR v_tx_user IS NULL THEN
        RAISE EXCEPTION 'Account or transaction not found or access denied';
    END IF;

    IF v_account_user <> v_tx_user THEN
        RAISE EXCEPTION 'Transaction user_id (%) does not match account user_id (%)', v_tx_user, v_account_user;
    END IF;

    RETURN NEW;
END;
$$;

-- Apply to all transaction detail tables
CREATE TRIGGER trg_tx_income_validate
    BEFORE INSERT ON transactions_income
    FOR EACH ROW EXECUTE FUNCTION validate_transaction_user();

CREATE TRIGGER trg_tx_expense_validate
    BEFORE INSERT ON transactions_expense
    FOR EACH ROW EXECUTE FUNCTION validate_transaction_user();

CREATE TRIGGER trg_tx_investment_validate
    BEFORE INSERT ON transactions_investment
    FOR EACH ROW EXECUTE FUNCTION validate_transaction_user();

CREATE TRIGGER trg_tx_adjustment_validate
    BEFORE INSERT ON transactions_adjustment
    FOR EACH ROW EXECUTE FUNCTION validate_transaction_user();

CREATE TRIGGER trg_tx_borrow_validate
    BEFORE INSERT ON transactions_borrow
    FOR EACH ROW EXECUTE FUNCTION validate_transaction_user();

CREATE TRIGGER trg_tx_lend_validate
    BEFORE INSERT ON transactions_lend
    FOR EACH ROW EXECUTE FUNCTION validate_transaction_user();

CREATE TRIGGER trg_tx_transfer_validate
    BEFORE INSERT ON transactions_transfer
    FOR EACH ROW EXECUTE FUNCTION validate_transaction_user();

-- =========================================
-- 02. TRANSACTIONS GENERATED COLUMNS TRIGGERS
-- =========================================
-- Purpose:
--   Automatically populate and maintain certain derived columns in the transactions table
--   whenever rows are inserted or updated. This ensures consistency and reduces manual computation.
--
-- 1. Function: set_created_month
-- -----------------------------------------
-- Behavior:
--   - Sets NEW.created_month to the first day of the month of NEW.created_at
--   - Provides an easy reference for monthly aggregation and reporting
--
-- Parameters:
--   NEW (trigger record) - The row being inserted or updated
--
-- Returns:
--   NEW - The modified row with updated created_month
--
-- Notes:
--   - Trigger applied BEFORE INSERT OR UPDATE on transactions
--   - Uses SECURITY DEFINER to ensure consistent behavior regardless of RLS
-- =========================================
CREATE OR REPLACE FUNCTION public.set_created_month()
RETURNS TRIGGER AS $$
BEGIN
    -- Ensure created_at is set before computing created_month
    IF NEW.created_at IS NULL THEN
        NEW.created_at := NOW();
    END IF;

    -- Set created_month to the first day of the created_at month
    NEW.created_month := DATE_TRUNC('month', NEW.created_at)::DATE;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog;

CREATE TRIGGER trg_transactions_set_created_month
BEFORE INSERT OR UPDATE ON transactions
FOR EACH ROW
EXECUTE FUNCTION public.set_created_month();

-- 2. Function: set_type_amount_jsonb
-- -----------------------------------------
-- Behavior:
--   - Constructs a JSONB object in NEW.type_amount_jsonb containing:
--       'type'   → transaction type
--       'amount' → transaction amount
--   - Facilitates easy querying and aggregation in JSON-based workflows
--
-- Parameters:
--   NEW (trigger record) - The row being inserted or updated
--
-- Returns:
--   NEW - The modified row with updated type_amount_jsonb
--
-- Notes:
--   - Trigger applied BEFORE INSERT OR UPDATE on transactions
--   - Uses SECURITY DEFINER to ensure consistent behavior regardless of RLS
-- =========================================
CREATE OR REPLACE FUNCTION public.set_type_amount_jsonb()
RETURNS TRIGGER AS $$
BEGIN
    NEW.type_amount_jsonb := jsonb_build_object(
        'type', NEW.type,
        'original_amount', NEW.original_amount,
        'original_currency', NEW.original_currency,
        'exchange_rate', NEW.exchange_rate,
        'converted_amount', NEW.converted_amount
    );
    RETURN NEW;
END;
$$
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog;

CREATE TRIGGER trg_transactions_set_jsonb
BEFORE INSERT OR UPDATE ON transactions
FOR EACH ROW
EXECUTE FUNCTION public.set_type_amount_jsonb();

-- 3. Function: set_is_recent
-- -----------------------------------------
-- Behavior:
--   - Sets NEW.is_recent to TRUE if NEW.created_at is within the last 30 days, otherwise FALSE
--   - Useful for filtering recent transactions without repeated computation
--
-- Parameters:
--   NEW (trigger record) - The row being inserted or updated
--
-- Returns:
--   NEW - The modified row with updated is_recent
--
-- Notes:
--   - Trigger applied BEFORE INSERT OR UPDATE on transactions
--   - Uses SECURITY DEFINER to ensure consistent behavior regardless of RLS
-- =========================================
CREATE OR REPLACE FUNCTION public.set_is_recent()
RETURNS TRIGGER AS $$
BEGIN
    NEW.is_recent := NEW.created_at >= (CURRENT_DATE - INTERVAL '30 days');
    RETURN NEW;
END;
$$
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog;

CREATE TRIGGER trg_transactions_set_is_recent
BEFORE INSERT OR UPDATE ON transactions
FOR EACH ROW
EXECUTE FUNCTION public.set_is_recent();

-- 4. Function: refresh_is_recent
-- -----------------------------------------
-- Behavior:
--   - Updates the is_recent column for all transactions based on whether
--     created_at is within the last 30 days
--   - Ensures is_recent remains accurate over time without manual updates
--
-- Parameters:
--   None
--
-- Returns:
--   void - updates rows in place
--
-- Notes:
--   - Intended to be run periodically (e.g., daily) via a scheduler such as pg_cron
--   - Uses SECURITY DEFINER to ensure execution regardless of RLS
-- =========================================
CREATE OR REPLACE FUNCTION public.refresh_is_recent()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  -- Recalculate only rows that might have changed
  UPDATE transactions
  SET is_recent = (created_at >= (CURRENT_DATE - INTERVAL '30 days'))
  WHERE is_recent IS DISTINCT FROM (created_at >= (CURRENT_DATE - INTERVAL '30 days'));
END;
$$;

SELECT cron.schedule(
  'refresh-is-recent-daily',   -- unique job name
  '0 0 * * *',                 -- every day at 00:00
  $$CALL public.refresh_is_recent();$$
);

-- =========================================
-- 03. Function: apply_transaction_balance
-- =========================================
-- Purpose:
--   Automatically updates the balances or relevant fields of accounts
--   whenever a transaction row is inserted. Ensures that all account types
--   reflect the correct amounts based on transaction activity.
--
-- Behavior:
--   - Retrieves the transaction amount and user_id
--   - Validates that the transaction and account exist and belong to the current user
--   - Updates the main accounts table timestamp
--   - Updates the appropriate account table field depending on:
--       * Transaction type (income, expense, investment, adjustment, borrow, lend)
--       * Account type (cash, bank, wallet, crypto, credit_card, investment, loan, receivable)
--   - Skips transfer transactions (handled separately)
--   - Raises exceptions if access is denied or accounts/transactions are missing
--
-- Parameters:
--   NEW (trigger record) - The newly inserted transaction row
--
-- Returns:
--   NEW - The original row after updating account balances
--
-- Notes:
--   - Trigger is applied AFTER INSERT on all transaction detail tables:
--       transactions_income, transactions_expense, transactions_investment,
--       transactions_adjustment, transactions_borrow, transactions_lend
--   - Uses SECURITY DEFINER to ensure consistent balance updates regardless of RLS
--   - Handles all account types and transaction types with specific field updates
-- =========================================
CREATE OR REPLACE FUNCTION public.apply_transaction_balance()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_original_amount NUMERIC;
    v_converted_amount NUMERIC;
    v_fees NUMERIC;
    v_to_account_type account_type;
    v_from_account_type account_type;
BEGIN
    -- SKIP processing if this is a soft delete
    IF NEW.deleted_at IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- Fetch transaction amounts and fees
    SELECT original_amount, converted_amount, COALESCE(fees, 0)
    INTO v_original_amount, v_converted_amount, v_fees
    FROM public.transactions
    WHERE id = NEW.transaction_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found';
    END IF;

    -- Apply logic based on which table fired the trigger
    CASE TG_TABLE_NAME

        WHEN 'transactions_income' THEN
            SELECT type INTO v_to_account_type FROM accounts WHERE id = NEW.account_id;
            UPDATE accounts SET updated_at = NOW() WHERE id = NEW.account_id;
            -- Income inflow reduced by fees
            PERFORM set_account_balance(v_to_account_type, NEW.account_id, v_converted_amount - COALESCE(v_fees, 0));

        WHEN 'transactions_expense' THEN
            SELECT type INTO v_from_account_type FROM accounts WHERE id = NEW.account_id;
            UPDATE accounts SET updated_at = NOW() WHERE id = NEW.account_id;
            IF v_from_account_type = 'credit_card' THEN
                -- Credit card expense increases balance owed including fees
                PERFORM set_account_balance(v_from_account_type, NEW.account_id, v_converted_amount + COALESCE(v_fees, 0));
            ELSE
                -- Regular expense outflow increases by fees
                PERFORM set_account_balance(v_from_account_type, NEW.account_id, -(v_converted_amount + COALESCE(v_fees, 0)));
            END IF;

        WHEN 'transactions_transfer' THEN
            -- From account (outflow including fees)
            SELECT type INTO v_from_account_type FROM accounts WHERE id = NEW.from_account;
            UPDATE accounts SET updated_at = NOW() WHERE id = NEW.from_account;

            IF v_from_account_type IN ('credit_card','loan') THEN
                -- Paying with credit card or loan increases balance owed
                PERFORM set_account_balance(v_from_account_type, NEW.from_account, v_original_amount + COALESCE(v_fees, 0));
            ELSE
                -- Regular outflow
                PERFORM set_account_balance(v_from_account_type, NEW.from_account, -(v_original_amount + COALESCE(v_fees, 0)));
            END IF;

            -- To account (inflow)
            SELECT type INTO v_to_account_type FROM accounts WHERE id = NEW.to_account;
            UPDATE accounts SET updated_at = NOW() WHERE id = NEW.to_account;

            IF v_to_account_type IN ('credit_card','loan') THEN
                -- Paying to credit card or loan reduces balance owed
                PERFORM set_account_balance(v_to_account_type, NEW.to_account, -v_converted_amount);
            ELSE
                -- Regular inflow
                PERFORM set_account_balance(v_to_account_type, NEW.to_account, v_converted_amount);
            END IF;

        WHEN 'transactions_investment' THEN
            -- Investment account increases
            SELECT type INTO v_to_account_type FROM accounts WHERE id = NEW.investment_account_id;
            UPDATE accounts SET updated_at = NOW() WHERE id = NEW.investment_account_id;
            PERFORM set_account_balance(v_to_account_type, NEW.investment_account_id, v_converted_amount);

            -- Funding account decreases (including fees)
            IF NEW.funding_account_id IS NOT NULL THEN
                SELECT type INTO v_from_account_type FROM accounts WHERE id = NEW.funding_account_id;
                UPDATE accounts SET updated_at = NOW() WHERE id = NEW.funding_account_id;
                PERFORM set_account_balance(v_from_account_type, NEW.funding_account_id, -(v_original_amount + COALESCE(v_fees, 0)));
            END IF;

        WHEN 'transactions_borrow' THEN
            -- Loan account increases
            SELECT type INTO v_from_account_type FROM accounts WHERE id = NEW.loan_account_id;
            UPDATE accounts SET updated_at = NOW() WHERE id = NEW.loan_account_id;
            PERFORM set_account_balance(v_from_account_type, NEW.loan_account_id, v_original_amount + COALESCE(v_fees, 0));

            -- Disbursement account increases (reduced by fees)
            IF NEW.disbursement_account_id IS NOT NULL THEN
                SELECT type INTO v_to_account_type FROM accounts WHERE id = NEW.disbursement_account_id;
                UPDATE accounts SET updated_at = NOW() WHERE id = NEW.disbursement_account_id;
                PERFORM set_account_balance(v_to_account_type, NEW.disbursement_account_id, v_converted_amount);
            END IF;

        WHEN 'transactions_lend' THEN
            -- Receivable account increases
            SELECT type INTO v_to_account_type FROM accounts WHERE id = NEW.receivable_account_id;
            UPDATE accounts SET updated_at = NOW() WHERE id = NEW.receivable_account_id;
            PERFORM set_account_balance(v_to_account_type, NEW.receivable_account_id, v_converted_amount);

            -- Funding account decreases (including fees)
            IF NEW.funding_account_id IS NOT NULL THEN
                SELECT type INTO v_from_account_type FROM accounts WHERE id = NEW.funding_account_id;
                UPDATE accounts SET updated_at = NOW() WHERE id = NEW.funding_account_id;
                PERFORM set_account_balance(v_from_account_type, NEW.funding_account_id, -(v_original_amount + COALESCE(v_fees, 0)));
            END IF;

        WHEN 'transactions_adjustment' THEN
            SELECT type INTO v_to_account_type FROM accounts WHERE id = NEW.account_id;
            UPDATE accounts SET updated_at = NOW() WHERE id = NEW.account_id;
            -- Adjustment reduced by fees
            PERFORM set_account_balance(v_to_account_type, NEW.account_id, v_converted_amount);

    END CASE;

    RETURN NEW;
END;
$$;

-- Attach triggers to all transaction tables
CREATE TRIGGER trg_tx_income_balance
    AFTER INSERT ON transactions_income
    FOR EACH ROW EXECUTE FUNCTION apply_transaction_balance();

CREATE TRIGGER trg_tx_expense_balance
    AFTER INSERT ON transactions_expense
    FOR EACH ROW EXECUTE FUNCTION apply_transaction_balance();

CREATE TRIGGER trg_tx_investment_balance
    AFTER INSERT ON transactions_investment
    FOR EACH ROW EXECUTE FUNCTION apply_transaction_balance();

CREATE TRIGGER trg_tx_adjustment_balance
    AFTER INSERT ON transactions_adjustment
    FOR EACH ROW EXECUTE FUNCTION apply_transaction_balance();

CREATE TRIGGER trg_tx_borrow_balance
    AFTER INSERT ON transactions_borrow
    FOR EACH ROW EXECUTE FUNCTION apply_transaction_balance();

CREATE TRIGGER trg_tx_lend_balance
    AFTER INSERT ON transactions_lend
    FOR EACH ROW EXECUTE FUNCTION apply_transaction_balance();

CREATE TRIGGER trg_tx_transfer_balance
    AFTER INSERT ON transactions_transfer
    FOR EACH ROW EXECUTE FUNCTION apply_transaction_balance();

-- =========================================
-- 03. Function: validate_and_apply_exchange_rate
-- =========================================
-- Purpose:
--   Validates that the currency of a transaction detail row matches the
--   currency of the associated account(s) before insertion or update.
--
-- Behavior:
--   - For transfer transactions, ensures both from_account and to_account
--     currencies match the transaction currency.
--   - For other transaction types, ensures the account currency matches
--     the transaction currency.
--   - Raises an exception if the transaction or account is not found,
--     access is denied, or currencies do not match.
--
-- Parameters:
--   NEW (trigger record) - The new row being inserted or updated
--
-- Returns:
--   NEW - The validated row if all checks pass
--
-- Notes:
--   - Applied as a BEFORE INSERT OR UPDATE trigger on all transaction detail tables
--   - Uses SECURITY DEFINER to bypass RLS for validation
--   - Prevents inconsistent currency assignments across transactions
-- =========================================
CREATE OR REPLACE FUNCTION validate_and_apply_exchange_rate() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_account_currency VARCHAR(10);
    v_tx_currency VARCHAR(10);
    v_exchange_rate NUMERIC;
    v_user_id UUID;
BEGIN
    -- SKIP processing if this is a soft delete
    IF NEW.deleted_at IS NOT NULL THEN
        RETURN NEW;
    END IF;

    v_user_id := COALESCE(
        NULLIF(current_setting('app.system_user_id', true), '')::uuid,
        auth.uid()
    );
    -- Get transaction original currency
    SELECT original_currency INTO v_tx_currency 
    FROM public.transactions 
    WHERE id = NEW.transaction_id 
      AND user_id = v_user_id
      AND deleted_at IS NULL;
    
    IF v_tx_currency IS NULL THEN
        RAISE EXCEPTION 'Transaction not found or access denied';
    END IF;

    -- Handle account validation per transaction type
    CASE TG_TABLE_NAME
        WHEN 'transactions_transfer' THEN
            -- From account
            SELECT currency INTO v_account_currency 
            FROM public.accounts 
            WHERE id = NEW.from_account
              AND user_id = v_user_id
              AND deleted_at IS NULL;

            IF v_account_currency IS NULL THEN
                RAISE EXCEPTION 'From account not found or access denied';
            END IF;

            IF v_tx_currency <> v_account_currency THEN
                v_exchange_rate := get_exchange_rate(v_tx_currency, v_account_currency);
                UPDATE transactions 
                SET exchange_rate = v_exchange_rate, 
                    converted_amount = original_amount * v_exchange_rate 
                WHERE id = NEW.transaction_id;
            ELSE
                UPDATE transactions 
                SET exchange_rate = 1, 
                    converted_amount = original_amount 
                WHERE id = NEW.transaction_id;
            END IF;

            -- To account
            SELECT currency INTO v_account_currency 
            FROM public.accounts 
            WHERE id = NEW.to_account
              AND user_id = v_user_id
              AND deleted_at IS NULL;

            IF v_account_currency IS NULL THEN
                RAISE EXCEPTION 'To account not found or access denied';
            END IF;

            IF v_tx_currency <> v_account_currency THEN
                v_exchange_rate := get_exchange_rate(v_tx_currency, v_account_currency);
                UPDATE transactions 
                SET exchange_rate = v_exchange_rate, 
                    converted_amount = original_amount * v_exchange_rate 
                WHERE id = NEW.transaction_id;
            END IF;

        WHEN 'transactions_borrow' THEN
            -- Loan account
            SELECT currency INTO v_account_currency
            FROM public.accounts
            WHERE id = NEW.loan_account_id
              AND user_id = v_user_id
              AND deleted_at IS NULL;

            IF v_account_currency IS NULL THEN
                RAISE EXCEPTION 'Loan account not found or access denied';
            END IF;

            IF v_tx_currency <> v_account_currency THEN
                v_exchange_rate := get_exchange_rate(v_tx_currency, v_account_currency);
                UPDATE transactions 
                SET exchange_rate = v_exchange_rate, 
                    converted_amount = original_amount * v_exchange_rate 
                WHERE id = NEW.transaction_id;
            ELSE
                UPDATE transactions 
                SET exchange_rate = 1, 
                    converted_amount = original_amount 
                WHERE id = NEW.transaction_id;
            END IF;

            -- Disbursement account
            SELECT currency INTO v_account_currency
            FROM public.accounts
            WHERE id = NEW.disbursement_account_id
              AND user_id = v_user_id
              AND deleted_at IS NULL;

            IF v_account_currency IS NULL THEN
                RAISE EXCEPTION 'Disbursement account not found or access denied';
            END IF;

            IF v_tx_currency <> v_account_currency THEN
                v_exchange_rate := get_exchange_rate(v_tx_currency, v_account_currency);
                UPDATE transactions 
                SET exchange_rate = v_exchange_rate, 
                    converted_amount = original_amount * v_exchange_rate 
                WHERE id = NEW.transaction_id;
            END IF;

        WHEN 'transactions_lend' THEN
            -- Receivable account
            SELECT currency INTO v_account_currency
            FROM public.accounts
            WHERE id = NEW.receivable_account_id
              AND user_id = v_user_id
              AND deleted_at IS NULL;

            IF v_account_currency IS NULL THEN
                RAISE EXCEPTION 'Receivable account not found or access denied';
            END IF;

            IF v_tx_currency <> v_account_currency THEN
                v_exchange_rate := get_exchange_rate(v_tx_currency, v_account_currency);
                UPDATE transactions 
                SET exchange_rate = v_exchange_rate, 
                    converted_amount = original_amount * v_exchange_rate 
                WHERE id = NEW.transaction_id;
            ELSE
                UPDATE transactions 
                SET exchange_rate = 1, 
                    converted_amount = original_amount 
                WHERE id = NEW.transaction_id;
            END IF;

            -- Funding account
            SELECT currency INTO v_account_currency
            FROM public.accounts
            WHERE id = NEW.funding_account_id
              AND user_id = v_user_id
              AND deleted_at IS NULL;

            IF v_account_currency IS NULL THEN
                RAISE EXCEPTION 'Funding account not found or access denied';
            END IF;

            IF v_tx_currency <> v_account_currency THEN
                v_exchange_rate := get_exchange_rate(v_tx_currency, v_account_currency);
                UPDATE transactions 
                SET exchange_rate = v_exchange_rate, 
                    converted_amount = original_amount * v_exchange_rate 
                WHERE id = NEW.transaction_id;
            END IF;

        WHEN 'transactions_investment' THEN
            -- Investment account
            SELECT currency INTO v_account_currency
            FROM public.accounts
            WHERE id = NEW.investment_account_id
              AND user_id = v_user_id
              AND deleted_at IS NULL;

            IF v_account_currency IS NULL THEN
                RAISE EXCEPTION 'Investment account not found or access denied';
            END IF;

            IF v_tx_currency <> v_account_currency THEN
                v_exchange_rate := get_exchange_rate(v_tx_currency, v_account_currency);
                UPDATE transactions 
                SET exchange_rate = v_exchange_rate, 
                    converted_amount = original_amount * v_exchange_rate 
                WHERE id = NEW.transaction_id;
            ELSE
                UPDATE transactions 
                SET exchange_rate = 1, 
                    converted_amount = original_amount 
                WHERE id = NEW.transaction_id;
            END IF;

            -- Funding account
            SELECT currency INTO v_account_currency
            FROM public.accounts
            WHERE id = NEW.funding_account_id
              AND user_id = v_user_id
              AND deleted_at IS NULL;

            IF v_account_currency IS NULL THEN
                RAISE EXCEPTION 'Funding account not found or access denied';
            END IF;

            IF v_tx_currency <> v_account_currency THEN
                v_exchange_rate := get_exchange_rate(v_tx_currency, v_account_currency);
                UPDATE transactions 
                SET exchange_rate = v_exchange_rate, 
                    converted_amount = original_amount * v_exchange_rate 
                WHERE id = NEW.transaction_id;
            END IF;

        ELSE
            -- Default case: single account_id field (income, expense, adjustment)
            SELECT currency INTO v_account_currency 
            FROM public.accounts 
            WHERE id = NEW.account_id
              AND user_id = v_user_id
              AND deleted_at IS NULL;

            IF v_account_currency IS NULL THEN
                RAISE EXCEPTION 'Account not found or access denied';
            END IF;

            IF v_tx_currency <> v_account_currency THEN
                v_exchange_rate := get_exchange_rate(v_tx_currency, v_account_currency);
                UPDATE transactions 
                SET exchange_rate = v_exchange_rate, 
                    converted_amount = original_amount * v_exchange_rate 
                WHERE id = NEW.transaction_id;
            ELSE
                UPDATE transactions 
                SET exchange_rate = 1, 
                    converted_amount = original_amount 
                WHERE id = NEW.transaction_id;
            END IF;
    END CASE;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_exchange_income
    BEFORE INSERT OR UPDATE ON transactions_income
    FOR EACH ROW EXECUTE FUNCTION validate_and_apply_exchange_rate();

CREATE TRIGGER trg_validate_exchange_expense
    BEFORE INSERT OR UPDATE ON transactions_expense
    FOR EACH ROW EXECUTE FUNCTION validate_and_apply_exchange_rate();

CREATE TRIGGER trg_validate_exchange_investment
    BEFORE INSERT OR UPDATE ON transactions_investment
    FOR EACH ROW EXECUTE FUNCTION validate_and_apply_exchange_rate();

CREATE TRIGGER trg_validate_exchange_adjustment
    BEFORE INSERT OR UPDATE ON transactions_adjustment
    FOR EACH ROW EXECUTE FUNCTION validate_and_apply_exchange_rate();

CREATE TRIGGER trg_validate_exchange_borrow
    BEFORE INSERT OR UPDATE ON transactions_borrow
    FOR EACH ROW EXECUTE FUNCTION validate_and_apply_exchange_rate();

CREATE TRIGGER trg_validate_exchange_lend
    BEFORE INSERT OR UPDATE ON transactions_lend
    FOR EACH ROW EXECUTE FUNCTION validate_and_apply_exchange_rate();

CREATE TRIGGER trg_validate_exchange_transfer
    BEFORE INSERT OR UPDATE ON transactions_transfer
    FOR EACH ROW EXECUTE FUNCTION validate_and_apply_exchange_rate();

-- =========================================
-- 08. Function: set_account_balance
-- =========================================
-- Purpose:
--   Adjusts the balance or relevant field of a specific account by adding
--   (or subtracting if negative) the specified amount, based on its account type.
--   Typically used during transaction postings, rollbacks, or adjustments.
--
-- Behavior:
--   - Determines the account type (cash, bank, wallet, crypto, credit_card,
--     investment, loan, receivable)
--   - Increments the appropriate field by the specified amount:
--       * balance for cash, bank, wallet, crypto
--       * current_balance for credit_card
--       * portfolio_value for investment
--       * outstanding_amount for loan
--       * amount_due for receivable
--   - Updates the updated_at timestamp for the affected account
--   - Raises an exception if the account type is unknown
--
-- Parameters:
--   p_acc_type    account_type - Type of the account
--   p_account_id  UUID         - ID of the account to update
--   p_amount      NUMERIC      - Amount to add (positive to increase,
--                                negative to decrease)
--
-- Returns:
--   VOID - This function performs a balance adjustment and does not return a value
--
-- Notes:
--   - Uses SECURITY DEFINER to enforce consistent behavior regardless of RLS
--   - Passing a negative amount will reduce the balance/value
--   - Ensures consistency across all account types by handling adjustments uniformly
CREATE OR REPLACE FUNCTION public.set_account_balance(
    p_acc_type account_type,
    p_account_id UUID,
    p_amount NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    CASE p_acc_type
        WHEN 'cash' THEN
            UPDATE public.cash_accounts
            SET balance = balance + p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;

        WHEN 'bank' THEN
            UPDATE public.bank_accounts
            SET balance = balance + p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;

        WHEN 'wallet' THEN
            UPDATE public.wallet_accounts
            SET balance = balance + p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;

        WHEN 'crypto' THEN
            UPDATE public.crypto_accounts
            SET balance = balance + p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;

        WHEN 'credit_card' THEN
            UPDATE public.credit_card_accounts
            SET current_balance = current_balance + p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;

        WHEN 'investment' THEN
            UPDATE public.investment_accounts
            SET portfolio_value = portfolio_value + p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;

        WHEN 'loan' THEN
            UPDATE public.loan_accounts
            SET outstanding_amount = outstanding_amount + p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;

        WHEN 'receivable' THEN
            UPDATE public.receivable_accounts
            SET amount_due = amount_due + p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;

        ELSE
            RAISE EXCEPTION 'Unknown account type in set_account_balance: %', p_acc_type;
    END CASE;
END;
$$;

-- =========================================
-- 12. Function: validate_income_account
-- =========================================
-- Purpose:
--   Ensures that any inserted or updated income transaction has a valid account type.
--
-- Behavior:
--   - Trigger fires BEFORE INSERT or UPDATE on transactions_income
--   - Retrieves the account type from the accounts table for the account_id specified in the transaction
--   - Checks that the account type is one of the allowed types for income transactions:
--       * 'cash', 'bank', 'wallet', 'investment', 'receivable'
--   - Raises an exception if the account type is invalid, preventing the transaction from being saved
--
-- Parameters:
--   - Implicit NEW record (trigger variable) representing the transaction being inserted or updated
--
-- Returns:
--   - NEW record (if account type is valid)
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass potential RLS restrictions and ensure consistent access to accounts
--   - Locks search_path to public to avoid role-mutable schema resolution issues
--   - Schema-qualified references (public.accounts) ensure predictable table resolution
CREATE OR REPLACE FUNCTION public.validate_income_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    acct_type account_type;
BEGIN
    SELECT type INTO acct_type
    FROM public.accounts
    WHERE id = NEW.account_id;

    IF acct_type NOT IN ('cash', 'bank', 'wallet', 'crypto') THEN
        RAISE EXCEPTION 'Invalid account type % for income transaction', acct_type;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_income_account
BEFORE INSERT OR UPDATE ON public.transactions_income
FOR EACH ROW
EXECUTE FUNCTION public.validate_income_account();

-- =========================================
-- 13. Function: validate_expense_account
-- =========================================
-- Purpose:
--   Ensures that any inserted or updated expense transaction has a valid account type.
--
-- Behavior:
--   - Trigger fires BEFORE INSERT or UPDATE on transactions_expense
--   - Retrieves the account type from the accounts table for the account_id specified in the transaction
--   - Checks that the account type is one of the allowed types for expense transactions:
--       * 'cash', 'bank', 'wallet', 'credit_card'
--   - Raises an exception if the account type is invalid, preventing the transaction from being saved
--
-- Parameters:
--   - Implicit NEW record (trigger variable) representing the transaction being inserted or updated
--
-- Returns:
--   - NEW record (if account type is valid)
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass potential RLS restrictions and ensure consistent access to accounts
--   - Locks search_path to public to avoid role-mutable schema resolution issues
--   - Schema-qualified references (public.accounts) ensure predictable table resolution
CREATE OR REPLACE FUNCTION public.validate_expense_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    acct_type account_type;
BEGIN
    SELECT type INTO acct_type
    FROM public.accounts
    WHERE id = NEW.account_id;

    IF acct_type NOT IN ('cash', 'bank', 'wallet', 'credit_card', 'crypto', 'investment') THEN
        RAISE EXCEPTION 'Invalid account type % for expense transaction', acct_type;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_expense_account
BEFORE INSERT OR UPDATE ON public.transactions_expense
FOR EACH ROW
EXECUTE FUNCTION public.validate_expense_account();

-- =========================================
-- 14. Function: validate_investment_account
-- =========================================
-- Purpose:
--   Ensures that any inserted or updated investment transaction has a valid account type.
--
-- Behavior:
--   - Trigger fires BEFORE INSERT or UPDATE on transactions_investment
--   - Retrieves the account type from the accounts table for the account_id specified in the transaction
--   - Checks that the account type is one of the allowed types for investment transactions:
--       * 'investment', 'bank', 'crypto', 'wallet'
--   - Raises an exception if the account type is invalid, preventing the transaction from being saved
--
-- Parameters:
--   - Implicit NEW record (trigger variable) representing the transaction being inserted or updated
--
-- Returns:
--   - NEW record (if account type is valid)
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass potential RLS restrictions and ensure consistent access to accounts
--   - Locks search_path to public to avoid role-mutable schema resolution issues
--   - Schema-qualified references (public.accounts) ensure predictable table resolution
CREATE OR REPLACE FUNCTION public.validate_investment_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    acct_type account_type;
    funding_type account_type;
BEGIN
    -- Main investment account check
    SELECT type INTO acct_type
    FROM public.accounts
    WHERE id = NEW.investment_account_id;

    IF acct_type NOT IN ('investment') THEN
        RAISE EXCEPTION 'Invalid account type % for investment transaction', acct_type;
    END IF;

    -- Funding account check
    IF NEW.funding_account_id IS NOT NULL THEN
        SELECT type INTO funding_type
        FROM public.accounts
        WHERE id = NEW.funding_account_id;

        IF funding_type NOT IN ('cash', 'bank', 'wallet', 'crypto') THEN
            RAISE EXCEPTION 'Invalid funding account type % for investment transaction', funding_type;
        END IF;

        -- Explicit same-account prevention
        IF NEW.funding_account_id = NEW.investment_account_id THEN
            RAISE EXCEPTION 'Funding and investment accounts cannot be the same';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_investment_account
BEFORE INSERT OR UPDATE ON public.transactions_investment
FOR EACH ROW
EXECUTE FUNCTION public.validate_investment_account();

-- =========================================
-- 15. Function: validate_borrow_account
-- =========================================
-- Purpose:
--   Ensures that any inserted or updated borrow transaction has a valid account type.
--
-- Behavior:
--   - Trigger fires BEFORE INSERT or UPDATE on transactions_borrow
--   - Retrieves the account type from the accounts table for the account_id specified in the transaction
--   - Checks that the account type is one of the allowed types for borrow transactions:
--       * 'loan', 'bank'
--   - Raises an exception if the account type is invalid, preventing the transaction from being saved
--
-- Parameters:
--   - Implicit NEW record (trigger variable) representing the transaction being inserted or updated
--
-- Returns:
--   - NEW record (if account type is valid)
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass potential RLS restrictions and ensure consistent access to accounts
--   - Locks search_path to public to avoid role-mutable schema resolution issues
--   - Schema-qualified references (public.accounts) ensure predictable table resolution
CREATE OR REPLACE FUNCTION public.validate_borrow_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    acct_type account_type;
    disbursement_type account_type;
BEGIN
    -- Main loan account check
    SELECT type INTO acct_type
    FROM public.accounts
    WHERE id = NEW.loan_account_id;

    IF acct_type NOT IN ('loan') THEN
        RAISE EXCEPTION 'Invalid account type % for borrow transaction', acct_type;
    END IF;

    -- Disbursement account check
    IF NEW.disbursement_account_id IS NOT NULL THEN
        SELECT type INTO disbursement_type
        FROM public.accounts
        WHERE id = NEW.disbursement_account_id;

        IF disbursement_type NOT IN ('cash', 'bank', 'wallet', 'crypto') THEN
            RAISE EXCEPTION 'Invalid disbursement account type % for borrow transaction', disbursement_type;
        END IF;

        -- Explicit same-account prevention
        IF NEW.loan_account_id = NEW.disbursement_account_id THEN
            RAISE EXCEPTION 'Loan account and disbursement account cannot be the same';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_borrow_account
BEFORE INSERT OR UPDATE ON public.transactions_borrow
FOR EACH ROW
EXECUTE FUNCTION public.validate_borrow_account();

-- =========================================
-- 16. Function: validate_lend_account
-- =========================================
-- Purpose:
--   Ensures that any inserted or updated lend transaction has a valid account type.
--
-- Behavior:
--   - Trigger fires BEFORE INSERT or UPDATE on transactions_lend
--   - Retrieves the account type from the accounts table for the account_id specified in the transaction
--   - Checks that the account type is one of the allowed types for lend transactions:
--       * 'cash', 'bank', 'wallet', 'investment'
--   - Raises an exception if the account type is invalid, preventing the transaction from being saved
--
-- Parameters:
--   - Implicit NEW record (trigger variable) representing the transaction being inserted or updated
--
-- Returns:
--   - NEW record (if account type is valid)
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass potential RLS restrictions and ensure consistent access to accounts
--   - Locks search_path to public to avoid role-mutable schema resolution issues
--   - Schema-qualified references (public.accounts) ensure predictable table resolution
CREATE OR REPLACE FUNCTION public.validate_lend_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    acct_type account_type;
    funding_type account_type;
BEGIN
    -- Main receivable account check
    SELECT type INTO acct_type
    FROM public.accounts
    WHERE id = NEW.receivable_account_id;

    IF acct_type NOT IN ('receivable') THEN
        RAISE EXCEPTION 'Invalid account type % for lend transaction', acct_type;
    END IF;

    -- Funding account check
    IF NEW.funding_account_id IS NOT NULL THEN
        SELECT type INTO funding_type
        FROM public.accounts
        WHERE id = NEW.funding_account_id;

        IF funding_type NOT IN ('cash', 'bank', 'wallet', 'crypto') THEN
            RAISE EXCEPTION 'Invalid funding account type % for lend transaction', funding_type;
        END IF;

        -- Explicit same-account prevention
        IF NEW.receivable_account_id = NEW.funding_account_id THEN
            RAISE EXCEPTION 'Receivable account and funding account cannot be the same';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_lend_account
BEFORE INSERT OR UPDATE ON public.transactions_lend
FOR EACH ROW
EXECUTE FUNCTION public.validate_lend_account();

-- =========================================
-- 17. Function: validate_transfer_accounts
-- =========================================
-- Purpose:
--   Ensures that any inserted or updated transfer transaction has valid source and destination accounts.
--
-- Behavior:
--   - Trigger fires BEFORE INSERT or UPDATE on transactions_transfer
--   - Retrieves the account type for both from_account and to_account from the accounts table
--   - Checks that the source and destination accounts are not the same
--   - Optionally, additional restrictions can be enforced (e.g., preventing receivable-to-receivable transfers)
--   - Raises an exception if any validation fails, preventing the transaction from being saved
--
-- Parameters:
--   - Implicit NEW record (trigger variable) representing the transaction being inserted or updated
--
-- Returns:
--   - NEW record (if validation passes)
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass potential RLS restrictions and ensure consistent access to accounts
--   - Locks search_path to public to avoid role-mutable schema resolution issues
--   - Schema-qualified references (public.accounts) ensure predictable table resolution
CREATE OR REPLACE FUNCTION public.validate_transfer_accounts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    from_type account_type;
    to_type account_type;
BEGIN
    SELECT type INTO from_type
    FROM public.accounts
    WHERE id = NEW.from_account;

    SELECT type INTO to_type
    FROM public.accounts
    WHERE id = NEW.to_account;

    IF NEW.from_account = NEW.to_account THEN
        RAISE EXCEPTION 'Transfer cannot have the same source and destination account';
    END IF;

    -- Optionally restrict (example rule shown in comments)
    -- IF from_type = 'receivable' AND to_type = 'receivable' THEN
    --     RAISE EXCEPTION 'Invalid receivable to receivable transfer';
    -- END IF;

    RETURN NEW;
END;
$$;

-- =========================================
-- 18. Function: validate_adjustment_account
-- =========================================
-- Purpose:
--   Validates adjustment transactions; currently allows any account type without restriction.
--
-- Behavior:
--   - Trigger fires BEFORE INSERT or UPDATE on transactions_adjustment
--   - No account type checks are performed; all adjustment transactions are allowed
--
-- Parameters:
--   - Implicit NEW record (trigger variable) representing the transaction being inserted or updated
--
-- Returns:
--   - NEW record (always)
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass potential RLS restrictions
--   - Locks search_path to public to avoid role-mutable schema resolution issues
--   - Schema-qualified references (public.transactions_adjustment) ensure predictable table resolution
CREATE OR REPLACE FUNCTION public.validate_adjustment_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Allow any account type (no restriction)
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_adjustment_account
BEFORE INSERT OR UPDATE ON public.transactions_adjustment
FOR EACH ROW
EXECUTE FUNCTION public.validate_adjustment_account();

-- =========================================
-- 10. Function: setup_recurring_transaction
-- =========================================
-- Purpose:
--   Prepares and validates recurring transactions before insertion, ensuring
--   that they are correctly linked to a template transaction and have valid
--   scheduling parameters.
--
-- Behavior:
--   - Auto-populates action_by with the current authenticated user or the affected user if not provided
--   - Validates that the template transaction exists, belongs to the user, is not deleted, and passes RLS checks
--   - Ensures the recurrence interval is positive
--   - Sets next_occurrence to start_date if not explicitly provided
--   - Raises exceptions if validation fails
--
-- Parameters:
--   NEW (trigger record) - The new recurring transaction row being inserted
--
-- Returns:
--   NEW - The prepared and validated row ready for insertion
--
-- Notes:
--   - Trigger applied BEFORE INSERT on transactions_recurring
--   - Uses SECURITY DEFINER to ensure consistent validation regardless of RLS
--   - Ensures recurring transactions are correctly initialized and enforce business rules
-- =========================================
CREATE OR REPLACE FUNCTION public.setup_recurring_transaction() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    -- 1. Auto‑populate action_by if not provided
    IF NEW.action_by IS NULL THEN
        NEW.action_by := auth.uid();

        -- Fallback to the affected user if no authenticated user
        IF NEW.action_by IS NULL THEN
            NEW.action_by := NEW.user_id;
        END IF;
    END IF;

    -- 2. Validate that template transaction exists, belongs to user, and is active
    IF NOT EXISTS (
        SELECT 1 
        FROM transactions 
        WHERE id = NEW.transaction_template_id 
          AND user_id = NEW.user_id
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Template transaction does not exist, is deleted, or access denied';
    END IF;

    -- 3. Validate recurrence interval
    IF NEW.interval IS NULL OR NEW.interval <= 0 THEN
        RAISE EXCEPTION 'Recurrence interval must be a positive integer';
    END IF;

    -- 4. Ensure frequency is valid
    IF NEW.frequency IS NULL THEN
        RAISE EXCEPTION 'Recurrence frequency must be specified';
    END IF;

    -- 5. Set next_occurrence if not provided
    IF NEW.next_occurrence IS NULL THEN
        IF NEW.start_date IS NOT NULL THEN
            NEW.next_occurrence := NEW.start_date;
        ELSE
            NEW.next_occurrence := NOW();
        END IF;
    END IF;

    -- 6. Ensure amounts and currencies are valid
    IF NOT EXISTS (
        SELECT 1
        FROM transactions t
        WHERE t.id = NEW.transaction_template_id
          AND t.original_amount IS NOT NULL
          AND t.original_currency IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Template transaction must have original_amount and original_currency';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_setup_recurring
    BEFORE INSERT ON transactions_recurring
    FOR EACH ROW EXECUTE FUNCTION public.setup_recurring_transaction();

-- =========================================
-- 05. Function: process_soft_delete_transaction
-- =========================================
-- Purpose:
--   Handles comprehensive processing when a transaction is soft deleted,
--   including cascading soft deletes to detail tables and reversing account balances
--   to maintain accurate financial records.
--
-- Behavior:
--   - Checks if a transaction is being soft deleted (OLD.deleted_at IS NULL and NEW.deleted_at IS NOT NULL)
--   - Soft deletes all related transaction detail records in the relevant table:
--       * transactions_income
--       * transactions_expense
--       * transactions_investment
--       * transactions_borrow
--       * transactions_lend
--       * transactions_transfer
--       * transactions_adjustment
--   - Updates updated_at timestamps for all affected detail rows
--   - Calls reverse_transaction_balance_on_soft_delete() to adjust account balances accordingly
--   - Ensures that balances reflect the reversal of the deleted transaction
--
-- Parameters:
--   NEW (trigger record) - The row being updated
--   OLD (trigger record) - The previous state of the row
--
-- Returns:
--   NEW - The updated transaction row after cascading soft delete and balance reversal
--
-- Notes:
--   - Trigger applied AFTER UPDATE on transactions
--   - Uses SECURITY DEFINER to enforce consistent behavior regardless of RLS
--   - Maintains both referential integrity and correct financial balances during soft deletes
-- =========================================
CREATE OR REPLACE FUNCTION public.process_soft_delete_transaction()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    -- Only process if this is a soft delete (deleted_at being set)
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        BEGIN
            -- 1. Soft delete related transaction details
            CASE OLD.type
                WHEN 'income' THEN
                    UPDATE public.transactions_income
                    SET deleted_at = NEW.deleted_at, updated_at = NOW()
                    WHERE transaction_id = OLD.id AND deleted_at IS NULL;

                WHEN 'expense' THEN
                    UPDATE public.transactions_expense
                    SET deleted_at = NEW.deleted_at, updated_at = NOW()
                    WHERE transaction_id = OLD.id AND deleted_at IS NULL;

                WHEN 'investment' THEN
                    UPDATE public.transactions_investment
                    SET deleted_at = NEW.deleted_at, updated_at = NOW()
                    WHERE transaction_id = OLD.id AND deleted_at IS NULL;

                WHEN 'borrow' THEN
                    UPDATE public.transactions_borrow
                    SET deleted_at = NEW.deleted_at, updated_at = NOW()
                    WHERE transaction_id = OLD.id AND deleted_at IS NULL;

                WHEN 'lend' THEN
                    UPDATE public.transactions_lend
                    SET deleted_at = NEW.deleted_at, updated_at = NOW()
                    WHERE transaction_id = OLD.id AND deleted_at IS NULL;

                WHEN 'transfer' THEN
                    UPDATE public.transactions_transfer
                    SET deleted_at = NEW.deleted_at, updated_at = NOW()
                    WHERE transaction_id = OLD.id AND deleted_at IS NULL;

                WHEN 'adjustment' THEN
                    UPDATE public.transactions_adjustment
                    SET deleted_at = NEW.deleted_at, updated_at = NOW()
                    WHERE transaction_id = OLD.id AND deleted_at IS NULL;

                ELSE
                    RAISE WARNING 'Unknown transaction type % for ID %', OLD.type, OLD.id;
            END CASE;

            -- 2. Soft delete any recurring definition linked to this transaction
            UPDATE public.transactions_recurring
            SET deleted_at = NEW.deleted_at, updated_at = NOW()
            WHERE transaction_template_id = OLD.id AND deleted_at IS NULL;

            -- 3. Reverse balances for this transaction
            PERFORM reverse_transaction_balance_on_soft_delete(OLD.id, OLD.type);

            RAISE NOTICE 'Transaction % of type % was successfully soft deleted and related data processed.',
                OLD.id, OLD.type;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING 'Error processing soft delete for transaction %: %', OLD.id, SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$$;

-- Trigger
CREATE TRIGGER trg_process_soft_delete_transaction
AFTER UPDATE ON transactions
FOR EACH ROW
EXECUTE FUNCTION public.process_soft_delete_transaction();

-- =========================================
-- 06. Function: reverse_transaction_balance_on_soft_delete
-- =========================================
-- Purpose:
--   Reverses the balances of accounts affected by a transaction when the
--   transaction is soft deleted. Handles all transaction types including
--   transfers and ensures that account balances remain accurate.
--
-- Behavior:
--   - Processes non-transfer transaction types (income, expense, investment,
--     adjustment, borrow, lend) by iterating over transaction detail rows:
--       * Retrieves account type
--       * Updates account updated_at timestamp
--       * Calls reverse_account_balance() to adjust the account
--   - Processes transfer transactions separately:
--       * Retrieves from_account and to_account types
--       * Updates updated_at timestamps for both accounts
--       * Calls reverse_transfer_balances() to reverse the transfer
--   - Raises warnings if transaction or account is not found, or if transaction type is unknown
--
-- Parameters:
--   p_tx_id   UUID  - The ID of the transaction being reversed
--   p_tx_type TEXT  - The type of the transaction (income, expense, transfer, etc.)
--
-- Returns:
--   VOID - This function performs balance reversals and does not return a value
--
-- Notes:
--   - Uses SECURITY DEFINER to ensure consistent behavior regardless of RLS
--   - Updates the updated_at timestamp for all affected accounts
--   - Ensures financial integrity by reversing balances accurately across all transaction types
-- =========================================
CREATE OR REPLACE FUNCTION public.reverse_transaction_balance_on_soft_delete(
    p_tx_id UUID,
    p_tx_type transaction_type
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_original_amount NUMERIC;
    v_converted_amount NUMERIC;
    v_fees NUMERIC;
    v_to_account_type account_type;
    v_from_account_type account_type;
    v_to_account_id UUID;
    v_from_account_id UUID;
BEGIN
    BEGIN
        -- Fetch transaction amounts and fees
        SELECT original_amount, converted_amount, COALESCE(fees, 0)
        INTO v_original_amount, v_converted_amount, v_fees
        FROM public.transactions
        WHERE id = p_tx_id;

        IF v_original_amount IS NULL OR v_converted_amount IS NULL THEN
            RAISE EXCEPTION 'Transaction % missing amounts; reversal skipped.', p_tx_id;
        END IF;

        -- Use CASE for consistent pattern matching
        CASE p_tx_type

            WHEN 'income' THEN
                -- Reverse income: subtract converted amount + fees from account balance
                SELECT account_id INTO v_to_account_id
                FROM transactions_income
                WHERE transaction_id = p_tx_id;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'No income details found for transaction %.', p_tx_id;
                END IF;

                SELECT type INTO v_to_account_type
                FROM accounts
                WHERE id = v_to_account_id AND deleted_at IS NULL;

                UPDATE accounts SET updated_at = NOW() WHERE id = v_to_account_id;
                PERFORM set_account_balance(v_to_account_type, v_to_account_id, -v_converted_amount + COALESCE(v_fees, 0));

            WHEN 'expense' THEN
                -- Reverse expense: add converted amount - fees (if any)
                SELECT account_id INTO v_from_account_id
                FROM transactions_expense
                WHERE transaction_id = p_tx_id;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'No expense details found for transaction %.', p_tx_id;
                END IF;

                SELECT type INTO v_from_account_type
                FROM accounts
                WHERE id = v_from_account_id AND deleted_at IS NULL;

                UPDATE accounts SET updated_at = NOW() WHERE id = v_from_account_id;

                IF v_from_account_type = 'credit_card' THEN
                    PERFORM set_account_balance(v_from_account_type, v_from_account_id, -(v_converted_amount + COALESCE(v_fees, 0)));
                ELSE
                    PERFORM set_account_balance(v_from_account_type, v_from_account_id, v_converted_amount + COALESCE(v_fees, 0));
                END IF;

            WHEN 'investment' THEN
                -- Reverse investment: subtract converted amount + fees from investment account, add original amount to funding account
                SELECT investment_account_id, funding_account_id
                INTO v_to_account_id, v_from_account_id
                FROM transactions_investment
                WHERE transaction_id = p_tx_id;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'No investment details found for transaction %.', p_tx_id;
                END IF;

                IF v_to_account_id IS NOT NULL THEN
                    SELECT type INTO v_to_account_type
                    FROM accounts WHERE id = v_to_account_id AND deleted_at IS NULL;
                    UPDATE accounts SET updated_at = NOW() WHERE id = v_to_account_id;
                    PERFORM set_account_balance(v_to_account_type, v_to_account_id, -v_converted_amount);
                END IF;

                IF v_from_account_id IS NOT NULL THEN
                    SELECT type INTO v_from_account_type
                    FROM accounts WHERE id = v_from_account_id AND deleted_at IS NULL;
                    UPDATE accounts SET updated_at = NOW() WHERE id = v_from_account_id;
                    PERFORM set_account_balance(v_from_account_type, v_from_account_id, v_original_amount + COALESCE(v_fees, 0));
                END IF;

            WHEN 'adjustment' THEN
                -- Reverse adjustment: subtract converted amount + fees
                SELECT account_id INTO v_to_account_id
                FROM transactions_adjustment
                WHERE transaction_id = p_tx_id;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'No adjustment details found for transaction %.', p_tx_id;
                END IF;

                SELECT type INTO v_to_account_type
                FROM accounts WHERE id = v_to_account_id AND deleted_at IS NULL;

                UPDATE accounts SET updated_at = NOW() WHERE id = v_to_account_id;
                PERFORM set_account_balance(v_to_account_type, v_to_account_id, -v_converted_amount);

            WHEN 'borrow' THEN
                -- Reverse borrow: subtract original amount + fees from loan account, subtract converted amount from disbursement account
                SELECT disbursement_account_id, loan_account_id
                INTO v_to_account_id, v_from_account_id
                FROM transactions_borrow
                WHERE transaction_id = p_tx_id;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'No borrow details found for transaction %.', p_tx_id;
                END IF;

                IF v_to_account_id IS NOT NULL THEN
                    SELECT type INTO v_to_account_type
                    FROM accounts WHERE id = v_to_account_id AND deleted_at IS NULL;
                    UPDATE accounts SET updated_at = NOW() WHERE id = v_to_account_id;
                    PERFORM set_account_balance(v_to_account_type, v_to_account_id, -v_converted_amount);
                END IF;

                IF v_from_account_id IS NOT NULL THEN
                    SELECT type INTO v_from_account_type
                    FROM accounts WHERE id = v_from_account_id AND deleted_at IS NULL;
                    UPDATE accounts SET updated_at = NOW() WHERE id = v_from_account_id;
                    PERFORM set_account_balance(v_from_account_type, v_from_account_id, -(v_original_amount + COALESCE(v_fees, 0)));
                END IF;

            WHEN 'lend' THEN
                -- Reverse lend: subtract converted amount + fees from receivable account, add original amount to funding account
                SELECT receivable_account_id, funding_account_id
                INTO v_to_account_id, v_from_account_id
                FROM transactions_lend
                WHERE transaction_id = p_tx_id;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'No lend details found for transaction %.', p_tx_id;
                END IF;

                IF v_to_account_id IS NOT NULL THEN
                    SELECT type INTO v_to_account_type
                    FROM accounts WHERE id = v_to_account_id AND deleted_at IS NULL;
                    UPDATE accounts SET updated_at = NOW() WHERE id = v_to_account_id;
                    PERFORM set_account_balance(v_to_account_type, v_to_account_id, -v_converted_amount);
                END IF;

                IF v_from_account_id IS NOT NULL THEN
                    SELECT type INTO v_from_account_type
                    FROM accounts WHERE id = v_from_account_id AND deleted_at IS NULL;
                    UPDATE accounts SET updated_at = NOW() WHERE id = v_from_account_id;
                    PERFORM set_account_balance(v_from_account_type, v_from_account_id, v_original_amount + COALESCE(v_fees, 0));
                END IF;

            WHEN 'transfer' THEN
                -- Reverse transfer: reverse debit and credit accounts including fees
                SELECT to_account, from_account, fees
                INTO v_to_account_id, v_from_account_id, v_fees
                FROM public.transactions_transfer
                WHERE transaction_id = p_tx_id;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'Transfer transaction % not found for reversal.', p_tx_id;
                END IF;

                -- From account (outflow)
                SELECT type INTO v_to_account_type
                FROM public.accounts
                WHERE id = v_to_account_id AND deleted_at IS NULL;

                UPDATE accounts SET updated_at = NOW() WHERE id = v_to_account_id;

                IF v_to_account_type IN ('credit_card','loan') THEN
                    PERFORM set_account_balance(v_to_account_type, v_to_account_id, v_converted_amount);
                ELSE
                    PERFORM set_account_balance(v_to_account_type, v_to_account_id, -v_converted_amount);
                END IF;

                -- To account (inflow)
                SELECT type INTO v_from_account_type
                FROM public.accounts
                WHERE id = v_from_account_id AND deleted_at IS NULL;

                UPDATE accounts SET updated_at = NOW() WHERE id = v_from_account_id;

                IF v_from_account_type IN ('credit_card','loan') THEN
                    PERFORM set_account_balance(v_from_account_type, v_from_account_id, -(v_original_amount + COALESCE(v_fees, 0)));
                ELSE
                    PERFORM set_account_balance(v_from_account_type, v_from_account_id, v_original_amount + COALESCE(v_fees, 0));
                END IF;

            ELSE
                RAISE EXCEPTION 'Unknown transaction type % for reversal', p_tx_type;
        END CASE;

        RAISE NOTICE 'Reversal completed for transaction % of type %.', p_tx_id, p_tx_type;

    EXCEPTION
        WHEN OTHERS THEN
            RAISE WARNING 'Error reversing balances for transaction %: %', p_tx_id, SQLERRM;
    END;
END;
$$;


-- =========================================
-- GRANT PERMISSIONS FOR RLS FUNCTIONS
-- =========================================
GRANT EXECUTE ON FUNCTION validate_transaction_user() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_transfer_accounts() TO authenticated;
GRANT EXECUTE ON FUNCTION apply_transaction_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION process_soft_delete_transaction() TO authenticated;
GRANT EXECUTE ON FUNCTION setup_recurring_transaction() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_and_apply_exchange_rate() TO authenticated;

-- =========================================
-- COMMENTS AND DOCUMENTATION
-- =========================================
COMMENT ON FUNCTION apply_transaction_balance() IS 'RLS-compliant balance updates for transaction operations';
