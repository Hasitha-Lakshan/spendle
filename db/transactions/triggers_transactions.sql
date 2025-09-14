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
    -- Get account user and transaction user
    SELECT user_id INTO v_account_user 
    FROM public.accounts 
    WHERE id = NEW.account_id 
      AND user_id = auth.uid()
      AND deleted_at IS NULL;
    
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

-- =========================================
-- 02. Function: validate_transfer_accounts
-- =========================================
-- Purpose:
--   Ensures that both accounts involved in a transfer belong to the same user
--   and validates that the transfer is allowed. Prevents unauthorized or invalid transfers.
--
-- Behavior:
--   - Checks that both "from" and "to" accounts exist and are not deleted
--   - Ensures both accounts belong to the same user as the transaction/user
--   - Prevents transfers where the source and destination accounts are identical
--   - Raises exceptions if any of the above validations fail
--
-- Parameters:
--   NEW (trigger record) - The new transfer row being inserted
--
-- Returns:
--   NEW - The original row if validation passes
--
-- Notes:
--   - Trigger is applied BEFORE INSERT on transactions_transfer
--   - Uses SECURITY DEFINER to enforce consistent validation regardless of RLS
--   - Ensures account ownership consistency and prevents self-transfers
-- =========================================
CREATE OR REPLACE FUNCTION validate_transfer_accounts() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE 
    from_user UUID;
    to_user UUID;
BEGIN
    -- Get account users based on NEW.user_id instead of querying transactions
    SELECT user_id INTO from_user 
    FROM accounts 
    WHERE id = NEW.from_account
      AND deleted_at IS NULL;

    SELECT user_id INTO to_user 
    FROM accounts 
    WHERE id = NEW.to_account
      AND deleted_at IS NULL;

    IF from_user IS NULL OR to_user IS NULL THEN
        RAISE EXCEPTION 'Accounts not found or access denied';
    END IF;

    -- Both accounts must belong to the same user as the transaction/user
    IF from_user <> to_user OR from_user <> NEW.user_id THEN
        RAISE EXCEPTION 'Transfer accounts must belong to the same user as the transaction';
    END IF;

    -- Prevent transfers from an account to itself
    IF NEW.from_account = NEW.to_account THEN
        RAISE EXCEPTION 'Cannot transfer from an account to itself';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tx_transfer_validate
    BEFORE INSERT ON transactions_transfer
    FOR EACH ROW EXECUTE FUNCTION validate_transfer_accounts();


-- =========================================
-- 03. TRANSACTIONS GENERATED COLUMNS TRIGGERS
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
        'amount', NEW.amount
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


-- =========================================
-- 04. Function: apply_transaction_balance
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
CREATE OR REPLACE FUNCTION apply_transaction_balance() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_amount NUMERIC;
    v_account_type account_type;
    v_account_id UUID;
    v_user_id UUID;
BEGIN
    -- Get transaction amount and user_id
    SELECT amount, user_id INTO v_amount, v_user_id 
    FROM public.transactions 
    WHERE id = NEW.transaction_id 
      AND user_id = auth.uid()
      AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found or access denied';
    END IF;
    
    -- Determine account ID based on transaction type
    IF TG_TABLE_NAME = 'transactions_transfer' THEN
        -- Handle transfer separately as it has two accounts
        RETURN NEW;
    ELSE
        v_account_id := NEW.account_id;
    END IF;
    
    -- Get account type
    SELECT type INTO v_account_type 
    FROM public.accounts 
    WHERE id = v_account_id 
      AND user_id = auth.uid()
      AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account not found or access denied';
    END IF;
    
    -- Update main accounts table timestamp
    UPDATE public.accounts 
    SET updated_at = NOW() 
    WHERE id = v_account_id;
    
    -- Handle different transaction types with specific field updates
    IF TG_TABLE_NAME = 'transactions_income' THEN
        CASE v_account_type
            WHEN 'cash' THEN
                UPDATE public.cash_accounts 
                SET balance = balance + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'bank' THEN
                UPDATE public.bank_accounts 
                SET balance = balance + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'wallet' THEN
                UPDATE public.wallet_accounts 
                SET balance = balance + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'crypto' THEN
                UPDATE public.crypto_accounts 
                SET balance = balance + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'investment' THEN
                UPDATE public.investment_accounts 
                SET portfolio_value = portfolio_value + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'receivable' THEN
                UPDATE public.receivable_accounts 
                SET amount_due = amount_due + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;

    ELSIF TG_TABLE_NAME = 'transactions_expense' THEN
        CASE v_account_type
            WHEN 'cash' THEN
                UPDATE public.cash_accounts 
                SET balance = balance - v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'bank' THEN
                UPDATE public.bank_accounts 
                SET balance = balance - v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'wallet' THEN
                UPDATE public.wallet_accounts 
                SET balance = balance - v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'crypto' THEN
                UPDATE public.crypto_accounts 
                SET balance = balance - v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'credit_card' THEN
                UPDATE public.credit_card_accounts 
                SET current_balance = current_balance + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'investment' THEN
                UPDATE public.investment_accounts 
                SET portfolio_value = portfolio_value - v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;

    ELSIF TG_TABLE_NAME = 'transactions_investment' THEN
        CASE v_account_type
            WHEN 'investment' THEN
                UPDATE public.investment_accounts 
                SET portfolio_value = portfolio_value + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'cash' THEN
                UPDATE public.cash_accounts 
                SET balance = balance - v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'bank' THEN
                UPDATE public.bank_accounts 
                SET balance = balance - v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;

    ELSIF TG_TABLE_NAME = 'transactions_adjustment' THEN
        CASE v_account_type
            WHEN 'cash' THEN
                UPDATE public.cash_accounts 
                SET balance = balance + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'bank' THEN
                UPDATE public.bank_accounts 
                SET balance = balance + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'wallet' THEN
                UPDATE public.wallet_accounts 
                SET balance = balance + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'crypto' THEN
                UPDATE public.crypto_accounts 
                SET balance = balance + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'credit_card' THEN
                UPDATE public.credit_card_accounts 
                SET current_balance = current_balance - v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'investment' THEN
                UPDATE public.investment_accounts 
                SET portfolio_value = portfolio_value + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'loan' THEN
                UPDATE public.loan_accounts 
                SET outstanding_amount = outstanding_amount - v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'receivable' THEN
                UPDATE public.receivable_accounts 
                SET amount_due = amount_due + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;

    ELSIF TG_TABLE_NAME = 'transactions_borrow' THEN
        CASE v_account_type
            WHEN 'loan' THEN
                UPDATE public.loan_accounts 
                SET outstanding_amount = outstanding_amount + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;

    ELSIF TG_TABLE_NAME = 'transactions_lend' THEN
        CASE v_account_type
            WHEN 'receivable' THEN
                UPDATE public.receivable_accounts 
                SET amount_due = amount_due + v_amount, updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;
    END IF;

    RETURN NEW;
END;
$$;

-- Attach to all transaction detail tables
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

-- =========================================
-- 05. Function: apply_transfer_balances
-- =========================================
-- Purpose:
--   Handles comprehensive balance updates for transfers between accounts,
--   ensuring that both the source (from_account) and destination (to_account)
--   reflect accurate balances according to the transaction amount and fees.
--
-- Behavior:
--   - Retrieves the transfer amount and user_id with RLS enforcement
--   - Validates that both from_account and to_account exist, are not deleted,
--     and belong to the current user
--   - Updates the updated_at timestamp for both accounts
--   - Decreases balance (or adjusts relevant field) in from_account based on account type
--   - Increases balance (or adjusts relevant field) in to_account based on account type
--   - Handles all account types including cash, bank, wallet, crypto, credit_card, loan,
--     investment, and receivable
--   - Raises exceptions if any account is missing or of an unknown type
--   - Optionally allows tracking transfer fees in audit logs
--
-- Parameters:
--   NEW (trigger record) - The newly inserted transfer row
--
-- Returns:
--   NEW - The original row after updating balances of both accounts
--
-- Notes:
--   - Trigger applied AFTER INSERT on transactions_transfer
--   - Uses SECURITY DEFINER to ensure consistent balance updates regardless of RLS
--   - Ensures full integrity of transfers across different account types
-- =========================================
CREATE OR REPLACE FUNCTION apply_transfer_balances()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    from_acc_type account_type;
    to_acc_type account_type;
    v_amount NUMERIC;
    v_user_id UUID;
BEGIN
    -- Get transaction amount and user_id with RLS check
    SELECT COALESCE(amount, 0), user_id INTO v_amount, v_user_id 
    FROM transactions 
    WHERE id = NEW.transaction_id
    AND user_id = auth.uid()
    AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found or access denied';
    END IF;

    -- Get account types with RLS checks
    SELECT type INTO from_acc_type 
    FROM accounts 
    WHERE id = NEW.from_account
    AND user_id = auth.uid()
    AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'From account not found or access denied';
    END IF;

    SELECT type INTO to_acc_type 
    FROM accounts 
    WHERE id = NEW.to_account
    AND user_id = auth.uid()
    AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'To account not found or access denied';
    END IF;

    -- Update timestamps for both accounts (RLS enforced automatically)
    UPDATE accounts 
    SET updated_at = NOW() 
    WHERE id IN (NEW.from_account, NEW.to_account);

    -- Decrease balance from from_account (outflow)
    CASE from_acc_type
        WHEN 'cash' THEN
            UPDATE cash_accounts 
            SET balance = balance - NEW.fees - v_amount, updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'bank' THEN
            UPDATE bank_accounts 
            SET balance = balance - NEW.fees - v_amount, updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'wallet' THEN
            UPDATE wallet_accounts 
            SET balance = balance - NEW.fees - v_amount, updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'crypto' THEN
            UPDATE crypto_accounts 
            SET balance = balance - NEW.fees - v_amount, updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'credit_card' THEN
            UPDATE credit_card_accounts 
            SET current_balance = current_balance + v_amount + NEW.fees, updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'loan' THEN
            -- Transfer from loan reduces outstanding amount (payment)
            UPDATE loan_accounts 
            SET outstanding_amount = outstanding_amount - v_amount, updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'investment' THEN
            UPDATE investment_accounts 
            SET portfolio_value = portfolio_value - v_amount - NEW.fees, updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'receivable' THEN
            UPDATE receivable_accounts 
            SET amount_due = amount_due - v_amount, updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        ELSE
            RAISE EXCEPTION 'Unknown account type for from_account: %', from_acc_type;
    END CASE;

    -- Optional: track fees separately in audit_logs if needed
    -- INSERT INTO audit_logs(user_id, action, reference_table, reference_id, details, created_at)
    -- VALUES (NEW.action_by, 'transfer_fee', 'transactions_transfer', NEW.id, NEW.fees::TEXT, NOW());

    -- Increase balance to to_account (inflow)
    CASE to_acc_type
        WHEN 'cash' THEN
            UPDATE cash_accounts 
            SET balance = balance + v_amount, updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'bank' THEN
            UPDATE bank_accounts 
            SET balance = balance + v_amount, updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'wallet' THEN
            UPDATE wallet_accounts 
            SET balance = balance + v_amount, updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'crypto' THEN
            UPDATE crypto_accounts 
            SET balance = balance + v_amount, updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'credit_card' THEN
            -- Transfer to credit card reduces outstanding balance (payment)
            UPDATE credit_card_accounts 
            SET current_balance = current_balance - v_amount, updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'loan' THEN
            -- Transfer to loan increases outstanding amount (new borrowing)
            UPDATE loan_accounts 
            SET outstanding_amount = outstanding_amount + v_amount, updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'investment' THEN
            UPDATE investment_accounts 
            SET portfolio_value = portfolio_value + v_amount, updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'receivable' THEN
            UPDATE receivable_accounts 
            SET amount_due = amount_due + v_amount, updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        ELSE
            RAISE EXCEPTION 'Unknown account type for to_account: %', to_acc_type;
    END CASE;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_apply_transfer_balances
    AFTER INSERT ON transactions_transfer
    FOR EACH ROW 
    EXECUTE FUNCTION apply_transfer_balances();

-- =========================================
-- 06. Function: cleanup_transaction_details
-- =========================================
-- Purpose:
--   Automatically soft deletes all related transaction detail records
--   whenever a transaction is soft deleted, maintaining data consistency
--   across all transaction tables.
--
-- Behavior:
--   - Checks if a transaction is being soft deleted (OLD.deleted_at IS NULL and NEW.deleted_at IS NOT NULL)
--   - Soft deletes the corresponding row(s) in the relevant transaction detail table:
--       * transactions_income
--       * transactions_expense
--       * transactions_investment
--       * transactions_borrow
--       * transactions_lend
--       * transactions_transfer
--       * transactions_adjustment
--   - Updates the updated_at timestamp for each affected row
--   - Ensures that only non-deleted detail rows are affected
--
-- Parameters:
--   NEW (trigger record) - The row being updated
--   OLD (trigger record) - The previous state of the row
--
-- Returns:
--   NEW - The updated transaction row after cascading soft delete
--
-- Notes:
--   - Trigger applied AFTER UPDATE on transactions
--   - Uses SECURITY DEFINER to enforce consistent behavior regardless of RLS
--   - Maintains referential integrity for soft deletes without hard deletion
-- =========================================
CREATE OR REPLACE FUNCTION public.cleanup_transaction_details() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    -- When a transaction is soft deleted, also soft delete its details
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
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
        END CASE;
    END IF;
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cleanup_transaction_details
    AFTER UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION cleanup_transaction_details();

-- =========================================
-- 07. Function: handle_soft_delete_and_reverse_balance
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
--   - Calls reverse_balance_on_soft_delete_core() to adjust account balances accordingly
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
CREATE OR REPLACE FUNCTION handle_soft_delete_and_reverse_balance()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    tx_details RECORD;
    acc_type account_type;
    transfer_details RECORD;
    from_acc_type account_type;
    to_acc_type account_type;
BEGIN
    -- Only process if this is a soft delete (deleted_at being set)
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN

        -- 1. Soft delete transaction details
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
        END CASE;

        -- 2. Reverse balances
        PERFORM reverse_balance_on_soft_delete_core(NEW.id, NEW.type);

    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_handle_soft_delete_and_reverse_balance
    AFTER UPDATE ON transactions
    FOR EACH ROW
    EXECUTE FUNCTION handle_soft_delete_and_reverse_balance();

-- =========================================
-- 08. Function: reverse_balance_on_soft_delete_core
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
CREATE OR REPLACE FUNCTION reverse_balance_on_soft_delete_core(p_tx_id UUID, p_tx_type TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    tx_details RECORD;
    transfer_details RECORD;
    acc_type account_type;
    from_acc_type account_type;
    to_acc_type account_type;
BEGIN
    -- Handle non-transfer transaction types
    IF p_tx_type = 'income' THEN
        FOR tx_details IN
            SELECT * FROM transactions_income WHERE transaction_id = p_tx_id
        LOOP
            SELECT type INTO acc_type 
            FROM public.accounts 
            WHERE id = tx_details.account_id AND deleted_at IS NULL;

            UPDATE public.accounts SET updated_at = NOW()
            WHERE id = tx_details.account_id;

            PERFORM reverse_account_balance(acc_type, tx_details.account_id, tx_details.amount);
        END LOOP;

    ELSIF p_tx_type = 'expense' THEN
        FOR tx_details IN
            SELECT * FROM transactions_expense WHERE transaction_id = p_tx_id
        LOOP
            SELECT type INTO acc_type 
            FROM public.accounts 
            WHERE id = tx_details.account_id AND deleted_at IS NULL;

            UPDATE public.accounts SET updated_at = NOW()
            WHERE id = tx_details.account_id;

            PERFORM reverse_account_balance(acc_type, tx_details.account_id, tx_details.amount);
        END LOOP;

    ELSIF p_tx_type = 'investment' THEN
        FOR tx_details IN
            SELECT * FROM transactions_investment WHERE transaction_id = p_tx_id
        LOOP
            SELECT type INTO acc_type 
            FROM public.accounts 
            WHERE id = tx_details.account_id AND deleted_at IS NULL;

            UPDATE public.accounts SET updated_at = NOW()
            WHERE id = tx_details.account_id;

            PERFORM reverse_account_balance(acc_type, tx_details.account_id, tx_details.amount);
        END LOOP;

    ELSIF p_tx_type = 'adjustment' THEN
        FOR tx_details IN
            SELECT * FROM transactions_adjustment WHERE transaction_id = p_tx_id
        LOOP
            SELECT type INTO acc_type 
            FROM public.accounts 
            WHERE id = tx_details.account_id AND deleted_at IS NULL;

            UPDATE public.accounts SET updated_at = NOW()
            WHERE id = tx_details.account_id;

            PERFORM reverse_account_balance(acc_type, tx_details.account_id, tx_details.amount);
        END LOOP;

    ELSIF p_tx_type = 'borrow' THEN
        FOR tx_details IN
            SELECT * FROM transactions_borrow WHERE transaction_id = p_tx_id
        LOOP
            SELECT type INTO acc_type 
            FROM public.accounts 
            WHERE id = tx_details.account_id AND deleted_at IS NULL;

            UPDATE public.accounts SET updated_at = NOW()
            WHERE id = tx_details.account_id;

            PERFORM reverse_account_balance(acc_type, tx_details.account_id, tx_details.amount);
        END LOOP;

    ELSIF p_tx_type = 'lend' THEN
        FOR tx_details IN
            SELECT * FROM transactions_lend WHERE transaction_id = p_tx_id
        LOOP
            SELECT type INTO acc_type 
            FROM public.accounts 
            WHERE id = tx_details.account_id AND deleted_at IS NULL;

            UPDATE public.accounts SET updated_at = NOW()
            WHERE id = tx_details.account_id;

            PERFORM reverse_account_balance(acc_type, tx_details.account_id, tx_details.amount);
        END LOOP;

    ELSIF p_tx_type = 'transfer' THEN
        -- Handle transfer separately
        SELECT * INTO transfer_details
        FROM public.transactions_transfer
        WHERE transaction_id = p_tx_id
          AND deleted_at IS NULL;

        IF NOT FOUND THEN
            RAISE WARNING 'Transfer transaction % not found for reversal', p_tx_id;
            RETURN;
        END IF;

        SELECT type INTO from_acc_type FROM accounts WHERE id = transfer_details.from_account;
        SELECT type INTO to_acc_type FROM accounts WHERE id = transfer_details.to_account;

        UPDATE accounts
        SET updated_at = NOW()
        WHERE id IN (transfer_details.from_account, transfer_details.to_account);

        PERFORM reverse_transfer_balances(from_acc_type, to_acc_type, transfer_details);

    ELSE
        RAISE WARNING 'Unknown transaction type %, skipping reversal', p_tx_type;
    END IF;

END;
$$;

-- =========================================
-- 09. Function: reverse_account_balance
-- =========================================
-- Purpose:
--   Reverses the balance or relevant field of a specific account based on
--   its account type. Typically used during transaction soft deletes to
--   maintain accurate financial records.
--
-- Behavior:
--   - Determines the account type (cash, bank, wallet, crypto, credit_card,
--     investment, loan, receivable)
--   - Subtracts the specified amount from the appropriate field:
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
--   p_amount      NUMERIC      - Amount to reverse/subtract
--
-- Returns:
--   VOID - This function performs balance reversal and does not return a value
--
-- Notes:
--   - Uses SECURITY DEFINER to enforce consistent behavior regardless of RLS
--   - Ensures financial integrity by accurately reversing balances for all account types
-- =========================================
CREATE OR REPLACE FUNCTION public.reverse_account_balance(
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
            SET balance = balance - p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;
        WHEN 'bank' THEN
            UPDATE public.bank_accounts
            SET balance = balance - p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;
        WHEN 'wallet' THEN
            UPDATE public.wallet_accounts
            SET balance = balance - p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;
        WHEN 'crypto' THEN
            UPDATE public.crypto_accounts
            SET balance = balance - p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;
        WHEN 'credit_card' THEN
            UPDATE public.credit_card_accounts
            SET current_balance = current_balance - p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;
        WHEN 'investment' THEN
            UPDATE public.investment_accounts
            SET portfolio_value = portfolio_value - p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;
        WHEN 'loan' THEN
            UPDATE public.loan_accounts
            SET outstanding_amount = outstanding_amount - p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;
        WHEN 'receivable' THEN
            UPDATE public.receivable_accounts
            SET amount_due = amount_due - p_amount, updated_at = NOW()
            WHERE account_id = p_account_id;
        ELSE
            RAISE EXCEPTION 'Unknown account type in reverse_account_balance: %', p_acc_type;
    END CASE;
END;
$$;

-- =========================================
-- 10. Function: reverse_transfer_balances
-- =========================================
-- Purpose:
--   Reverses the balances of both accounts involved in a transfer transaction
--   when the transfer is soft deleted or otherwise needs reversal. Ensures that
--   funds and fees are correctly restored or deducted according to account type.
--
-- Behavior:
--   - Adjusts the "from_account" by adding back the transfer amount plus any fees:
--       * Handles all account types: cash, bank, wallet, crypto, credit_card, loan, investment, receivable
--       * Updates updated_at timestamp
--       * Raises an exception for unknown from_account types
--   - Adjusts the "to_account" by subtracting the transfer amount:
--       * Handles all account types: cash, bank, wallet, crypto, credit_card, loan, investment, receivable
--       * Updates updated_at timestamp
--       * Raises an exception for unknown to_account types
--
-- Parameters:
--   p_from_acc_type account_type - Type of the source account
--   p_to_acc_type   account_type - Type of the destination account
--   p_transfer      RECORD       - The transfer record containing amount, fees, and account IDs
--
-- Returns:
--   VOID - This function performs balance reversals and does not return a value
--
-- Notes:
--   - Uses SECURITY DEFINER to ensure consistent behavior regardless of RLS
--   - Ensures financial integrity by accurately reversing transfers across all account types
--   - Correctly handles fees for the source account during reversal
-- =========================================
CREATE OR REPLACE FUNCTION public.reverse_transfer_balances(
    p_from_acc_type account_type,
    p_to_acc_type account_type,
    p_transfer RECORD
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    -- Reverse "from" account (add back amount + fees if any)
    CASE p_from_acc_type
        WHEN 'cash' THEN
            UPDATE public.cash_accounts
            SET balance = balance + p_transfer.amount + p_transfer.fees,
                updated_at = NOW()
            WHERE account_id = p_transfer.from_account;
        WHEN 'bank' THEN
            UPDATE public.bank_accounts
            SET balance = balance + p_transfer.amount + p_transfer.fees,
                updated_at = NOW()
            WHERE account_id = p_transfer.from_account;
        WHEN 'wallet' THEN
            UPDATE public.wallet_accounts
            SET balance = balance + p_transfer.amount + p_transfer.fees,
                updated_at = NOW()
            WHERE account_id = p_transfer.from_account;
        WHEN 'crypto' THEN
            UPDATE public.crypto_accounts
            SET balance = balance + p_transfer.amount + p_transfer.fees,
                updated_at = NOW()
            WHERE account_id = p_transfer.from_account;
        WHEN 'credit_card' THEN
            UPDATE public.credit_card_accounts
            SET current_balance = current_balance - (p_transfer.amount + p_transfer.fees),
                updated_at = NOW()
            WHERE account_id = p_transfer.from_account;
        WHEN 'loan' THEN
            UPDATE public.loan_accounts
            SET outstanding_amount = outstanding_amount + p_transfer.amount,
                updated_at = NOW()
            WHERE account_id = p_transfer.from_account;
        WHEN 'investment' THEN
            UPDATE public.investment_accounts
            SET portfolio_value = portfolio_value + p_transfer.amount + p_transfer.fees,
                updated_at = NOW()
            WHERE account_id = p_transfer.from_account;
        WHEN 'receivable' THEN
            UPDATE public.receivable_accounts
            SET amount_due = amount_due + p_transfer.amount,
                updated_at = NOW()
            WHERE account_id = p_transfer.from_account;
        ELSE
            RAISE EXCEPTION 'Unknown from_account type in reverse_transfer_balances: %', p_from_acc_type;
    END CASE;

    -- Reverse "to" account (subtract amount)
    CASE p_to_acc_type
        WHEN 'cash' THEN
            UPDATE public.cash_accounts
            SET balance = balance - p_transfer.amount,
                updated_at = NOW()
            WHERE account_id = p_transfer.to_account;
        WHEN 'bank' THEN
            UPDATE public.bank_accounts
            SET balance = balance - p_transfer.amount,
                updated_at = NOW()
            WHERE account_id = p_transfer.to_account;
        WHEN 'wallet' THEN
            UPDATE public.wallet_accounts
            SET balance = balance - p_transfer.amount,
                updated_at = NOW()
            WHERE account_id = p_transfer.to_account;
        WHEN 'crypto' THEN
            UPDATE public.crypto_accounts
            SET balance = balance - p_transfer.amount,
                updated_at = NOW()
            WHERE account_id = p_transfer.to_account;
        WHEN 'credit_card' THEN
            UPDATE public.credit_card_accounts
            SET current_balance = current_balance + p_transfer.amount,
                updated_at = NOW()
            WHERE account_id = p_transfer.to_account;
        WHEN 'loan' THEN
            UPDATE public.loan_accounts
            SET outstanding_amount = outstanding_amount - p_transfer.amount,
                updated_at = NOW()
            WHERE account_id = p_transfer.to_account;
        WHEN 'investment' THEN
            UPDATE public.investment_accounts
            SET portfolio_value = portfolio_value - p_transfer.amount,
                updated_at = NOW()
            WHERE account_id = p_transfer.to_account;
        WHEN 'receivable' THEN
            UPDATE public.receivable_accounts
            SET amount_due = amount_due - p_transfer.amount,
                updated_at = NOW()
            WHERE account_id = p_transfer.to_account;
        ELSE
            RAISE EXCEPTION 'Unknown to_account type in reverse_transfer_balances: %', p_to_acc_type;
    END CASE;

END;
$$;

-- =========================================
-- 11. Function: setup_recurring_transaction
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
CREATE OR REPLACE FUNCTION setup_recurring_transaction() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Auto-populate action_by if not provided
    IF NEW.action_by IS NULL THEN
        NEW.action_by := auth.uid();
        -- If no authenticated user, use the affected user
        IF NEW.action_by IS NULL THEN
            NEW.action_by := NEW.user_id;
        END IF;
    END IF;
    
    -- Validate that template transaction exists and belongs to user
    IF NOT EXISTS (
        SELECT 1 FROM transactions 
        WHERE id = NEW.transaction_template_id 
          AND user_id = NEW.user_id
          AND user_id = auth.uid()
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Template transaction does not exist, is deleted, or access denied';
    END IF;
    
    -- Validate frequency and interval
    IF NEW.interval <= 0 THEN
        RAISE EXCEPTION 'Interval must be positive';
    END IF;
    
    -- Set next_occurrence if not provided
    IF NEW.next_occurrence IS NULL THEN
        NEW.next_occurrence := NEW.start_date;
    END IF;
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_setup_recurring
    BEFORE INSERT ON transactions_recurring
    FOR EACH ROW EXECUTE FUNCTION setup_recurring_transaction();

-- =========================================
-- 12. Function: process_recurring_transactions
-- =========================================
-- Purpose:
--   Processes all active recurring transactions that are due, creating new
--   transactions based on their template transactions while maintaining
--   detailed records and advancing the recurrence schedule.
--
-- Behavior:
--   - Loops through all active recurring transactions that are due (next_occurrence <= CURRENT_DATE)
--   - For each recurring transaction:
--       * Retrieves the template transaction with SECURITY DEFINER privileges
--       * Inserts a new transaction row copying relevant fields from the template
--       * Copies associated detail records into the corresponding transaction detail table
--       * Advances the next_occurrence based on frequency and interval
--       * Updates updated_at timestamp for the recurring transaction
--       * Tracks the number of processed transactions and IDs of new transactions
--   - Raises warnings if the template transaction is missing or deleted
--   - Supports all transaction types: income, expense, investment, adjustment, borrow, lend, transfer
--
-- Parameters:
--   None - This function operates on all eligible recurring transactions
--
-- Returns:
--   TABLE(processed_count INTEGER, new_transaction_ids UUID[])
--     processed_count     - Number of recurring transactions successfully processed
--     new_transaction_ids - Array of UUIDs of newly created transactions
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass RLS restrictions and access all template transactions
--   - Ensures accurate replication of transaction details for each recurring transaction
--   - Logs notices for each created transaction for audit/debug purposes
-- =========================================
CREATE OR REPLACE FUNCTION process_recurring_transactions()
RETURNS TABLE(processed_count INTEGER, new_transaction_ids UUID[]) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    rec RECORD;
    new_tx_id UUID;
    template_tx RECORD;
    processed_count INTEGER := 0;
    new_tx_ids UUID[] := ARRAY[]::UUID[];
BEGIN
    -- Loop all active recurring transactions regardless of RLS context
    FOR rec IN
        SELECT r.* 
        FROM transactions_recurring r
        WHERE r.deleted_at IS NULL
          AND r.next_occurrence <= CURRENT_DATE
          AND (r.end_date IS NULL OR r.next_occurrence <= r.end_date)
    LOOP
        -- Use template transaction with definer privileges
        SELECT * INTO template_tx 
        FROM transactions 
        WHERE id = rec.transaction_template_id
          AND deleted_at IS NULL;

        IF NOT FOUND THEN
            RAISE WARNING 'Template transaction % not found, deleted, or access denied for recurring transaction %', 
                rec.transaction_template_id, rec.id;
            CONTINUE;
        END IF;

        -- Insert new transaction
        INSERT INTO transactions (user_id, type, amount, currency, notes)
        VALUES (
            template_tx.user_id,
            template_tx.type,
            template_tx.amount,
            template_tx.currency,
            COALESCE(template_tx.notes, '') || ' [Auto-recurring ' || rec.id::text || ']'
        ) RETURNING id INTO new_tx_id;

        -- Copy details (same as before)
        CASE template_tx.type
            WHEN 'income' THEN
                INSERT INTO transactions_income (transaction_id, account_id, source_id, notes)
                SELECT new_tx_id, account_id, source_id, 'Auto-generated from recurring'
                FROM transactions_income WHERE transaction_id = template_tx.id AND deleted_at IS NULL;
            WHEN 'expense' THEN
                INSERT INTO transactions_expense (transaction_id, account_id, category_id, payment_method)
                SELECT new_tx_id, account_id, category_id, payment_method
                FROM transactions_expense WHERE transaction_id = template_tx.id AND deleted_at IS NULL;
            WHEN 'investment' THEN
                INSERT INTO transactions_investment (transaction_id, account_id, asset_type, asset_symbol, platform, risk_level)
                SELECT new_tx_id, account_id, asset_type, asset_symbol, platform, risk_level
                FROM transactions_investment WHERE transaction_id = template_tx.id AND deleted_at IS NULL;
            WHEN 'adjustment' THEN
                INSERT INTO transactions_adjustment (transaction_id, account_id, reason)
                SELECT new_tx_id, account_id, 'Auto-generated recurring adjustment'
                FROM transactions_adjustment WHERE transaction_id = template_tx.id AND deleted_at IS NULL;
            WHEN 'borrow' THEN
                INSERT INTO transactions_borrow (transaction_id, account_id, lender_id, notes)
                SELECT new_tx_id, account_id, lender_id, 'Auto-generated from recurring borrow'
                FROM transactions_borrow WHERE transaction_id = template_tx.id AND deleted_at IS NULL;
            WHEN 'lend' THEN
                INSERT INTO transactions_lend (transaction_id, account_id, borrower_id, notes)
                SELECT new_tx_id, account_id, borrower_id, 'Auto-generated from recurring lend'
                FROM transactions_lend WHERE transaction_id = template_tx.id AND deleted_at IS NULL;
            WHEN 'transfer' THEN
                INSERT INTO transactions_transfer (transaction_id, from_account, to_account, fees, notes)
                SELECT new_tx_id, from_account, to_account, COALESCE(fees, 0), 'Auto-generated from recurring transfer'
                FROM transactions_transfer WHERE transaction_id = template_tx.id AND deleted_at IS NULL;
        END CASE;

        -- Advance next_occurrence
        UPDATE transactions_recurring
        SET next_occurrence = CASE rec.frequency
                WHEN 'daily'   THEN rec.next_occurrence + (rec.interval || ' days')::interval
                WHEN 'weekly'  THEN rec.next_occurrence + (rec.interval || ' weeks')::interval
                WHEN 'monthly' THEN rec.next_occurrence + (rec.interval || ' months')::interval
                WHEN 'yearly'  THEN rec.next_occurrence + (rec.interval || ' years')::interval
            END,
            updated_at = NOW()
        WHERE id = rec.id;

        processed_count := processed_count + 1;
        new_tx_ids := array_append(new_tx_ids, new_tx_id);
        RAISE NOTICE 'Created recurring transaction % from template % (recurring ID: %)', new_tx_id, rec.transaction_template_id, rec.id;
    END LOOP;

    RETURN QUERY SELECT processed_count, new_tx_ids;
END;
$$;


-- =========================================
-- GRANT PERMISSIONS FOR RLS FUNCTIONS
-- =========================================
GRANT EXECUTE ON FUNCTION validate_transaction_user() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_transfer_accounts() TO authenticated;
GRANT EXECUTE ON FUNCTION apply_transaction_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION apply_transfer_balances() TO authenticated;
GRANT EXECUTE ON FUNCTION handle_soft_delete_and_reverse_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION reverse_account_balance(account_type, uuid, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION reverse_transfer_balances(account_type, account_type, record) TO authenticated;
GRANT EXECUTE ON FUNCTION setup_recurring_transaction() TO authenticated;
GRANT EXECUTE ON FUNCTION process_recurring_transactions() TO authenticated;


-- =========================================
-- COMMENTS AND DOCUMENTATION
-- =========================================
COMMENT ON FUNCTION apply_transaction_balance() IS 'RLS-compliant balance updates for transaction operations';
COMMENT ON FUNCTION apply_transfer_balances() IS 'RLS-compliant balance updates for transfer operations';
COMMENT ON FUNCTION process_recurring_transactions() IS 'RLS-compliant recurring transaction processing';
