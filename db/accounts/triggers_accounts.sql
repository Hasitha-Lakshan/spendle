-- =========================================
-- 01. Function: update_receivable_status
-- =========================================
-- Purpose:
--   Automatically updates the status of a receivable account based on its
--   amount_due and due_date whenever a row is inserted or updated.
--
-- Behavior:
--   - If amount_due <= 0          → sets status to 'paid'
--   - If due_date is past today   → sets status to 'overdue'
--   - Otherwise                    → sets status to 'pending'
--
-- Parameters:
--   NEW (trigger record) - The new row being inserted or updated
--
-- Returns:
--   NEW - The modified row with updated status
--
-- Notes:
--   - Trigger is applied BEFORE INSERT OR UPDATE on receivable_accounts
--   - Uses SECURITY DEFINER to enforce consistent logic regardless of RLS
--   - Ensures receivable status is always accurate based on business rules
-- =========================================
CREATE OR REPLACE FUNCTION update_receivable_status() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.amount_due <= 0 THEN
        NEW.status := 'paid';
    ELSIF NEW.due_date IS NOT NULL AND NEW.due_date < CURRENT_DATE THEN
        NEW.status := 'overdue';
    ELSE
        NEW.status := 'pending';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_receivable_status
    BEFORE INSERT OR UPDATE ON receivable_accounts
    FOR EACH ROW EXECUTE FUNCTION update_receivable_status();

-- =========================================
-- 02. Function: update_loan_status
-- =========================================
-- Purpose:
--   Automatically updates the status of a loan account based on its
--   outstanding_amount and end_date whenever a row is inserted or updated.
--
-- Behavior:
--   - If outstanding_amount <= 0                  → sets status to 'closed'
--   - If end_date is past today AND amount > 0    → sets status to 'defaulted'
--   - Otherwise                                   → sets status to 'active'
--
-- Parameters:
--   NEW (trigger record) - The new row being inserted or updated
--
-- Returns:
--   NEW - The modified row with updated status
--
-- Notes:
--   - Trigger is applied BEFORE INSERT OR UPDATE on loan_accounts
--   - Uses SECURITY DEFINER to ensure logic executes correctly regardless of RLS
--   - Ensures loan status is always accurate based on business rules
-- =========================================
CREATE OR REPLACE FUNCTION update_loan_status() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.outstanding_amount <= 0 THEN
        NEW.status := 'closed';
    ELSIF NEW.end_date IS NOT NULL AND NEW.end_date < CURRENT_DATE AND NEW.outstanding_amount > 0 THEN
        NEW.status := 'defaulted';
    ELSE
        NEW.status := 'active';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loan_status
    BEFORE INSERT OR UPDATE ON loan_accounts
    FOR EACH ROW EXECUTE FUNCTION update_loan_status();

-- =========================================
-- 03. Function: validate_account_balance
-- =========================================
-- Purpose:
--   Monitors account balances for negative values in cash, bank, wallet, and crypto accounts.
--   Issues a WARNING if a negative balance is detected.
--
-- Behavior:
--   - Triggered BEFORE UPDATE on the respective account tables.
--   - Does not prevent updates; only provides warnings.
--
-- Parameters:
--   NEW (trigger record) - The account row being updated
--
-- Returns:
--   NEW - The row being processed, unchanged
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass RLS for validation
--   - Applied per account type via dedicated triggers
--   - Helps detect potential overdraft or accounting issues without enforcing strict constraints
-- =========================================
CREATE OR REPLACE FUNCTION validate_account_balance() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    CASE TG_TABLE_NAME
        WHEN 'cash_accounts' THEN
            IF NEW.balance < 0 THEN
                RAISE EXCEPTION 'Cash account % cannot have negative balance: %', NEW.account_id, NEW.balance;
            END IF;

        WHEN 'bank_accounts' THEN
            IF NEW.balance < 0 THEN
                RAISE EXCEPTION 'Bank account % cannot have negative balance: %', NEW.account_id, NEW.balance;
            END IF;

        WHEN 'wallet_accounts' THEN
            IF NEW.balance < 0 THEN
                RAISE EXCEPTION 'Wallet account % cannot have negative balance: %', NEW.account_id, NEW.balance;
            END IF;

        WHEN 'crypto_accounts' THEN
            IF NEW.balance < 0 THEN
                RAISE EXCEPTION 'Crypto account % cannot have negative balance: %', NEW.account_id, NEW.balance;
            END IF;

        WHEN 'credit_card_accounts' THEN
            -- Allow negative current_balance, just warn
            IF NEW.current_balance < 0 THEN
                RAISE WARNING 'Credit card account % has negative current balance: %', NEW.account_id, NEW.current_balance;
            END IF;
            IF NEW.credit_limit IS NOT NULL AND NEW.current_balance > NEW.credit_limit THEN
                RAISE EXCEPTION 'Credit card account % exceeds credit limit (%): current balance %', NEW.account_id, NEW.credit_limit, NEW.current_balance;
            END IF;

        WHEN 'loan_accounts' THEN
            IF NEW.outstanding_amount < 0 THEN
                RAISE EXCEPTION 'Loan account % cannot have negative outstanding amount: %', NEW.account_id, NEW.outstanding_amount;
            END IF;

        WHEN 'investment_accounts' THEN
            IF NEW.portfolio_value < 0 THEN
                RAISE EXCEPTION 'Investment account % cannot have negative portfolio value: %', NEW.account_id, NEW.portfolio_value;
            END IF;

        WHEN 'receivable_accounts' THEN
            IF NEW.amount_due < 0 THEN
                RAISE EXCEPTION 'Receivable account % cannot have negative amount due: %', NEW.account_id, NEW.amount_due;
            END IF;

        ELSE
            RAISE EXCEPTION 'Unknown account table: %', TG_TABLE_NAME;
    END CASE;

    RETURN NEW;
END;
$$;

-- Cash
CREATE TRIGGER trg_validate_cash_balance
    BEFORE INSERT OR UPDATE ON cash_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

-- Bank
CREATE TRIGGER trg_validate_bank_balance
    BEFORE INSERT OR UPDATE ON bank_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

-- Wallet
CREATE TRIGGER trg_validate_wallet_balance
    BEFORE INSERT OR UPDATE ON wallet_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

-- Crypto
CREATE TRIGGER trg_validate_crypto_balance
    BEFORE INSERT OR UPDATE ON crypto_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

-- Credit Card
CREATE TRIGGER trg_validate_credit_card_balance
    BEFORE INSERT OR UPDATE ON credit_card_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

-- Loan
CREATE TRIGGER trg_validate_loan_balance
    BEFORE INSERT OR UPDATE ON loan_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

-- Investment
CREATE TRIGGER trg_validate_investment_balance
    BEFORE INSERT OR UPDATE ON investment_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

-- Receivable
CREATE TRIGGER trg_validate_receivable_balance
    BEFORE INSERT OR UPDATE ON receivable_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

-- =========================================
-- 04. Function: validate_account_modification
-- =========================================
-- Purpose:
--   Prevents modification or deletion of accounts that have existing transactions.
--   Ensures data integrity by enforcing business rules for account updates.
--
-- Behavior:
--   - BEFORE UPDATE: Disallows changes to account type or currency if associated transactions exist.
--   - BEFORE DELETE: Disallows hard deletes if the account has any associated transactions; soft delete should be used instead.
--
-- Parameters:
--   OLD - The original account row before modification or deletion
--   NEW - The new account row being updated (NULL for deletes)
--
-- Returns:
--   COALESCE(NEW, OLD) - The row being processed
--
-- Notes:
--   - SECURITY DEFINER is used to bypass RLS for validation
--   - Checks all related transaction detail tables to enforce constraints
--   - Helps maintain consistency between accounts and transactions
-- =========================================
CREATE OR REPLACE FUNCTION validate_account_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Check if account has associated transactions
    IF EXISTS (
        SELECT 1 FROM transactions t
        WHERE t.user_id = OLD.user_id AND t.deleted_at IS NULL AND
        (
            t.id IN (SELECT transaction_id FROM transactions_income WHERE account_id = OLD.id AND deleted_at IS NULL) OR
            t.id IN (SELECT transaction_id FROM transactions_expense WHERE account_id = OLD.id AND deleted_at IS NULL) OR
            t.id IN (SELECT transaction_id FROM transactions_investment 
                     WHERE (investment_account_id = OLD.id OR funding_account_id = OLD.id) 
                       AND deleted_at IS NULL) OR
            t.id IN (SELECT transaction_id FROM transactions_borrow 
                     WHERE (loan_account_id = OLD.id OR disbursement_account_id = OLD.id) 
                       AND deleted_at IS NULL) OR
            t.id IN (SELECT transaction_id FROM transactions_lend 
                     WHERE (receivable_account_id = OLD.id OR funding_account_id = OLD.id) 
                       AND deleted_at IS NULL) OR
            t.id IN (SELECT transaction_id FROM transactions_transfer 
                     WHERE (from_account = OLD.id OR to_account = OLD.id) 
                       AND deleted_at IS NULL) OR
            t.id IN (SELECT transaction_id FROM transactions_adjustment 
                     WHERE account_id = OLD.id AND deleted_at IS NULL)
        )
    ) THEN
        IF TG_OP = 'UPDATE' AND (OLD.type != NEW.type OR OLD.currency != NEW.currency) THEN
            RAISE EXCEPTION 'Cannot modify account type or currency when transactions exist';
        ELSIF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'Cannot delete account with existing transactions. Use soft delete instead.';
        END IF;
    END IF;
    
    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Add triggers for account validation
CREATE TRIGGER trg_validate_account_update
    BEFORE UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_modification();

CREATE TRIGGER trg_validate_account_delete
    BEFORE DELETE ON accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_modification();

-- =========================================
-- 05. Function: cleanup_specialized_account
-- =========================================
-- Purpose:
--   Automatically soft deletes the corresponding specialized account when a parent account is soft deleted.
--   Ensures consistency between the accounts table and its specialized variants.
--
-- Behavior:
--   - AFTER UPDATE on accounts: Checks if deleted_at was set
--   - Soft deletes the relevant specialized account (cash, bank, credit_card, loan, investment, crypto, wallet, receivable)
--   - Updates the specialized account's updated_at timestamp to reflect the change
--
-- Parameters:
--   OLD - The original account row before update
--   NEW - The updated account row
--
-- Returns:
--   NEW - The updated account row
--
-- Notes:
--   - SECURITY DEFINER allows this trigger to bypass RLS when updating specialized accounts
--   - Only applies if the parent account was not previously deleted
-- =========================================
CREATE OR REPLACE FUNCTION cleanup_specialized_account() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- When an account is soft deleted, also soft delete the specialized account
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        CASE OLD.type
            WHEN 'cash' THEN
                UPDATE public.cash_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'bank' THEN
                UPDATE public.bank_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'credit_card' THEN
                UPDATE public.credit_card_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'loan' THEN
                UPDATE public.loan_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'investment' THEN
                UPDATE public.investment_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'crypto' THEN
                UPDATE public.crypto_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'wallet' THEN
                UPDATE public.wallet_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'receivable' THEN
                UPDATE public.receivable_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
        END CASE;
    END IF;
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cleanup_specialized_account
    AFTER UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION cleanup_specialized_account();

-- =========================================
-- GRANT PERMISSIONS FOR RLS FUNCTIONS
-- =========================================
GRANT EXECUTE ON FUNCTION update_receivable_status() TO authenticated;
GRANT EXECUTE ON FUNCTION update_loan_status() TO authenticated;
GRANT EXECUTE ON FUNCTION cleanup_specialized_account() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_account_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_account_modification() TO authenticated;
