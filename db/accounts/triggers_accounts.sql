-- =========================================
-- 01. Function: account_has_active_transactions_internal
-- =========================================
-- Purpose:
--   Checks whether a given account has any active (non-deleted) transactions 
--   across all transaction types, including income, expense, investment, 
--   borrow, lend, transfer, and adjustment.
--
-- Behavior:
--   - Returns TRUE if at least one active transaction exists for the account.
--   - Returns FALSE if no active transactions are found.
--
-- Parameters:
--   p_account_id UUID - The ID of the account to check.
--
-- Returns:
--   BOOLEAN - TRUE if the account has active transactions, FALSE otherwise.
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass Row-Level Security (RLS) policies.
--   - Checks deleted_at IS NULL in all relevant transaction tables to 
--     ensure only active transactions are considered.
--   - Designed as a helper function to centralize transaction existence 
--     checks for account validation, balance restrictions, and soft-delete protection.
--   - Marked STABLE to indicate it does not modify the database and can be safely used in triggers or queries.
-- =========================================
CREATE OR REPLACE FUNCTION public.account_has_active_transactions_internal(
    p_account_id UUID,
    p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
STABLE
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM transactions t
        WHERE t.user_id = p_user_id
          AND t.deleted_at IS NULL
          AND t.id IN (

              -- Income
              SELECT transaction_id
              FROM transactions_income
              WHERE account_id = p_account_id
                AND deleted_at IS NULL

              UNION ALL
              -- Expense
              SELECT transaction_id
              FROM transactions_expense
              WHERE account_id = p_account_id
                AND deleted_at IS NULL

              UNION ALL
              -- Investment
              SELECT transaction_id
              FROM transactions_investment
              WHERE (funding_account_id = p_account_id
                     OR investment_account_id = p_account_id)
                AND deleted_at IS NULL

              UNION ALL
              -- Borrow
              SELECT transaction_id
              FROM transactions_borrow
              WHERE (loan_account_id = p_account_id
                     OR disbursement_account_id = p_account_id)
                AND deleted_at IS NULL

              UNION ALL
              -- Lend
              SELECT transaction_id
              FROM transactions_lend
              WHERE (funding_account_id = p_account_id
                     OR receivable_account_id = p_account_id)
                AND deleted_at IS NULL

              UNION ALL
              -- Transfer
              SELECT transaction_id
              FROM transactions_transfer
              WHERE (from_account = p_account_id
                     OR to_account = p_account_id)
                AND deleted_at IS NULL

              UNION ALL
              -- Adjustment
              SELECT transaction_id
              FROM transactions_adjustment
              WHERE account_id = p_account_id
                AND deleted_at IS NULL
          )
    );
END;
$$;

-- =========================================
-- 02. Function: update_receivable_status
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
CREATE OR REPLACE FUNCTION public.update_receivable_status() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
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
    FOR EACH ROW EXECUTE FUNCTION public.update_receivable_status();

-- =========================================
-- 03. Function: update_loan_status
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
CREATE OR REPLACE FUNCTION public.update_loan_status() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
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
    FOR EACH ROW EXECUTE FUNCTION public.update_loan_status();

-- =========================================
-- 04. Function: validate_account_balance
-- =========================================
-- Purpose:
--   Monitors account balances for negative values in cash, bank, wallet, and crypto accounts.
--   Issues a WARNING or EXCEPTION if a negative balance is detected.
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
CREATE OR REPLACE FUNCTION public.validate_account_balance() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
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
    FOR EACH ROW EXECUTE FUNCTION public.validate_account_balance();

-- Bank
CREATE TRIGGER trg_validate_bank_balance
    BEFORE INSERT OR UPDATE ON bank_accounts
    FOR EACH ROW EXECUTE FUNCTION public.validate_account_balance();

-- Wallet
CREATE TRIGGER trg_validate_wallet_balance
    BEFORE INSERT OR UPDATE ON wallet_accounts
    FOR EACH ROW EXECUTE FUNCTION public.validate_account_balance();

-- Crypto
CREATE TRIGGER trg_validate_crypto_balance
    BEFORE INSERT OR UPDATE ON crypto_accounts
    FOR EACH ROW EXECUTE FUNCTION public.validate_account_balance();

-- Credit Card
CREATE TRIGGER trg_validate_credit_card_balance
    BEFORE INSERT OR UPDATE ON credit_card_accounts
    FOR EACH ROW EXECUTE FUNCTION public.validate_account_balance();

-- Loan
CREATE TRIGGER trg_validate_loan_balance
    BEFORE INSERT OR UPDATE ON loan_accounts
    FOR EACH ROW EXECUTE FUNCTION public.validate_account_balance();

-- Investment
CREATE TRIGGER trg_validate_investment_balance
    BEFORE INSERT OR UPDATE ON investment_accounts
    FOR EACH ROW EXECUTE FUNCTION public.validate_account_balance();

-- Receivable
CREATE TRIGGER trg_validate_receivable_balance
    BEFORE INSERT OR UPDATE ON receivable_accounts
    FOR EACH ROW EXECUTE FUNCTION public.validate_account_balance();



-- =========================================
-- 05. Function: validate_account_modification
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
CREATE OR REPLACE FUNCTION public.validate_account_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- Only check if there are active transactions
    IF public.account_has_active_transactions_internal(OLD.account_id, OLD.user_id) THEN
        -- Prevent modification of currency
        IF TG_OP = 'UPDATE' AND OLD.currency IS DISTINCT FROM NEW.currency THEN
            RAISE EXCEPTION 'Cannot modify account currency when transactions exist';
        END IF;

        -- Prevent soft delete
        IF TG_OP = 'UPDATE'
           AND OLD.deleted_at IS NULL
           AND NEW.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot soft-delete account with existing transactions';
        END IF;

        -- Prevent deletion
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'Cannot hard-delete account with existing transactions.';
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Add triggers for account validation
CREATE TRIGGER trg_validate_account_modification
BEFORE UPDATE OR DELETE ON accounts
FOR EACH ROW
EXECUTE FUNCTION public.validate_account_modification();

-- =========================================
-- 06. Function: prevent_balance_change_if_transactions
-- =========================================
-- Purpose:
--   Prevents modification of account balances, currency, or deletion/soft-delete
--   on accounts that have active (non-deleted) transactions.
--
-- Behavior:
--   - Triggered BEFORE UPDATE or DELETE on account tables.
--   - Checks if the account has any active transactions using
--     the helper function `account_has_active_transactions_internal`.
--   - Raises exceptions to block:
--       * Balance changes (per account type: cash, bank, credit card, loan, investment, crypto, wallet, receivable)
--       * Currency changes
--       * Hard deletes
--       * Soft deletes
--
-- Parameters:
--   NEW (trigger record) - The proposed new state of the account row.
--   OLD (trigger record) - The existing state of the account row.
--
-- Returns:
--   NEW or OLD depending on trigger operation; no changes are applied if constraints are violated.
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass Row-Level Security (RLS) policies.
--   - Relies on the centralized helper function `account_has_active_transactions_internal` to detect active transactions.
--   - Prevents accidental or unauthorized modifications to critical account data when transactions exist.
--   - Applied per account type via dedicated triggers.
-- =========================================
CREATE OR REPLACE FUNCTION public.prevent_balance_change_if_transactions()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_balance_changed BOOLEAN := FALSE;
BEGIN
    -- Only check if there are active transactions
    IF public.account_has_active_transactions_internal(OLD.account_id, OLD.user_id) THEN
        -- Detect balance changes per account type
        CASE TG_TABLE_NAME
            WHEN 'cash_accounts' THEN
                IF OLD.balance IS DISTINCT FROM NEW.balance THEN
                    v_balance_changed := TRUE;
                END IF;

            WHEN 'bank_accounts' THEN
                IF OLD.balance IS DISTINCT FROM NEW.balance THEN
                    v_balance_changed := TRUE;
                END IF;

            WHEN 'wallet_accounts' THEN
                IF OLD.balance IS DISTINCT FROM NEW.balance THEN
                    v_balance_changed := TRUE;
                END IF;

            WHEN 'crypto_accounts' THEN
                IF OLD.balance IS DISTINCT FROM NEW.balance THEN
                    v_balance_changed := TRUE;
                END IF;

            WHEN 'credit_card_accounts' THEN
                IF OLD.current_balance IS DISTINCT FROM NEW.current_balance
                   OR OLD.credit_limit IS DISTINCT FROM NEW.credit_limit
                   OR OLD.interest_rate IS DISTINCT FROM NEW.interest_rate THEN
                    v_balance_changed := TRUE;
                END IF;

            WHEN 'investment_accounts' THEN
                IF OLD.portfolio_value IS DISTINCT FROM NEW.portfolio_value THEN
                    v_balance_changed := TRUE;
                END IF;

            WHEN 'loan_accounts' THEN
                IF OLD.principal_amount IS DISTINCT FROM NEW.principal_amount
                   OR OLD.outstanding_amount IS DISTINCT FROM NEW.outstanding_amount
                   OR OLD.interest_rate IS DISTINCT FROM NEW.interest_rate THEN
                    v_balance_changed := TRUE;
                END IF;

            WHEN 'receivable_accounts' THEN
                IF OLD.principal_amount IS DISTINCT FROM NEW.principal_amount
                   OR OLD.amount_due IS DISTINCT FROM NEW.amount_due THEN
                    v_balance_changed := TRUE;
                END IF;
            ELSE
                -- Unhandled table
                RAISE EXCEPTION 'prevent_balance_change_if_transactions: unhandled table %', TG_TABLE_NAME;
        END CASE;

        IF v_balance_changed THEN
            RAISE EXCEPTION 'Cannot modify account balances when transactions exist';
        END IF;

        -- Prevent deletion
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'Cannot delete account with existing transactions.';
        END IF;

        -- Prevent soft delete
        IF TG_OP = 'UPDATE' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot soft-delete account with existing transactions';
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Cash
CREATE TRIGGER trg_prevent_cash_balance_change
BEFORE UPDATE OR DELETE ON cash_accounts
FOR EACH ROW EXECUTE FUNCTION public.prevent_balance_change_if_transactions();

-- Bank
CREATE TRIGGER trg_prevent_bank_balance_change
BEFORE UPDATE OR DELETE ON bank_accounts
FOR EACH ROW EXECUTE FUNCTION public.prevent_balance_change_if_transactions();

-- Wallet
CREATE TRIGGER trg_prevent_wallet_balance_change
BEFORE UPDATE OR DELETE ON wallet_accounts
FOR EACH ROW EXECUTE FUNCTION public.prevent_balance_change_if_transactions();

-- Crypto
CREATE TRIGGER trg_prevent_crypto_balance_change
BEFORE UPDATE OR DELETE ON crypto_accounts
FOR EACH ROW EXECUTE FUNCTION public.prevent_balance_change_if_transactions();

-- Credit Card
CREATE TRIGGER trg_prevent_credit_card_balance_change
BEFORE UPDATE OR DELETE ON credit_card_accounts
FOR EACH ROW EXECUTE FUNCTION public.prevent_balance_change_if_transactions();

-- Investment
CREATE TRIGGER trg_prevent_investment_balance_change
BEFORE UPDATE OR DELETE ON investment_accounts
FOR EACH ROW EXECUTE FUNCTION public.prevent_balance_change_if_transactions();

-- Loan
CREATE TRIGGER trg_prevent_loan_balance_change
BEFORE UPDATE OR DELETE ON loan_accounts
FOR EACH ROW EXECUTE FUNCTION public.prevent_balance_change_if_transactions();

-- Receivable
CREATE TRIGGER trg_prevent_receivable_balance_change
BEFORE UPDATE OR DELETE ON receivable_accounts
FOR EACH ROW EXECUTE FUNCTION public.prevent_balance_change_if_transactions();

-- =========================================
-- 07. Function: prevent_account_type_change
-- =========================================
-- Purpose:
--   Prevents changing an account’s type after it has been created.
--   Ensures structural integrity between the accounts table and its
--   specialized account tables.
--
-- Behavior:
--   - BEFORE UPDATE on accounts
--   - Compares OLD.type and NEW.type
--   - Raises an exception if an account type change is attempted
--
-- Parameters:
--   OLD - The existing account row before update
--   NEW - The updated account row
--
-- Returns:
--   NEW - The unchanged account row if no type modification is detected
--
-- Notes:
--   - Enforced at the database level to prevent accidental or malicious updates
--   - Uses IS DISTINCT FROM for NULL-safe comparison
--   - Prevents orphaned or inconsistent specialized account records
-- =========================================
CREATE OR REPLACE FUNCTION public.prevent_account_type_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- Prevent changing account type after creation
    IF NEW.type IS DISTINCT FROM OLD.type THEN
        RAISE EXCEPTION
            'Account type cannot be changed once created (from % to %)',
            OLD.type, NEW.type
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prevent_account_type_change
BEFORE UPDATE ON accounts
FOR EACH ROW
EXECUTE FUNCTION public.prevent_account_type_change();

-- =========================================
-- 08. Function: soft_delete_specialized_account
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
CREATE OR REPLACE FUNCTION public.soft_delete_specialized_account() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- Allow soft-delete operation on specialized accounts
    PERFORM set_config('app.allow_specialized_soft_delete', 'true', true);

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
            ELSE
                RAISE EXCEPTION 'Unknown account type % in soft_delete_specialized_account', OLD.type;
        END CASE;
    END IF;

    -- Reset the flag after operation
    PERFORM set_config('app.allow_specialized_soft_delete', 'false', true);
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cleanup_specialized_account
    AFTER UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION public.soft_delete_specialized_account();




-- =========================================
-- 09. Function: prevent_specialized_soft_delete
-- =========================================
-- Purpose:
--   Prevents direct soft-delete operations on specialized account tables
--   (cash, bank, credit card, loan, investment, crypto, wallet, receivable)
--   unless the parent account trigger explicitly allows it.
--
-- Behavior:
--   - Triggered BEFORE UPDATE on specialized account tables.
--   - Checks if a soft-delete is attempted (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL).
--   - Verifies the session-level flag 'app.allow_specialized_soft_delete' is set to 'true'.
--   - Raises an exception if a direct soft-delete is attempted without the flag.
--
-- Parameters:
--   NEW (trigger record) - The proposed new state of the specialized account row.
--   OLD (trigger record) - The existing state of the specialized account row.
--
-- Returns:
--   NEW - Only allows the update to proceed if the soft-delete is authorized via the parent account trigger.
--
-- Notes:
--   - Uses SECURITY DEFINER to bypass Row-Level Security (RLS) for enforcement.
--   - Relies on the parent account trigger (cleanup_specialized_account) to set the session flag.
--   - Ensures consistency between parent accounts and their specialized accounts.
--   - Applied per specialized account table via dedicated triggers.
-- =========================================
CREATE OR REPLACE FUNCTION public.prevent_specialized_soft_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- Block direct soft-delete unless parent trigger flagged it
    IF OLD.deleted_at IS NULL 
       AND NEW.deleted_at IS NOT NULL 
       AND current_setting('app.allow_specialized_soft_delete', true) IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'Direct soft-delete on % (id=%) is not allowed. Use parent account operations', TG_TABLE_NAME, OLD.account_id;
    END IF;

    RETURN NEW;
END;
$$;

-- Cash
CREATE TRIGGER trg_prevent_cash_soft_delete
BEFORE UPDATE ON cash_accounts
FOR EACH ROW
EXECUTE FUNCTION public.prevent_specialized_soft_delete();

-- Bank
CREATE TRIGGER trg_prevent_bank_soft_delete
BEFORE UPDATE ON bank_accounts
FOR EACH ROW
EXECUTE FUNCTION public.prevent_specialized_soft_delete();

-- Credit Card
CREATE TRIGGER trg_prevent_credit_card_soft_delete
BEFORE UPDATE ON credit_card_accounts
FOR EACH ROW
EXECUTE FUNCTION public.prevent_specialized_soft_delete();

-- Loan
CREATE TRIGGER trg_prevent_loan_soft_delete
BEFORE UPDATE ON loan_accounts
FOR EACH ROW
EXECUTE FUNCTION public.prevent_specialized_soft_delete();

-- Investment
CREATE TRIGGER trg_prevent_investment_soft_delete
BEFORE UPDATE ON investment_accounts
FOR EACH ROW
EXECUTE FUNCTION public.prevent_specialized_soft_delete();

-- Crypto
CREATE TRIGGER trg_prevent_crypto_soft_delete
BEFORE UPDATE ON crypto_accounts
FOR EACH ROW
EXECUTE FUNCTION public.prevent_specialized_soft_delete();

-- Wallet
CREATE TRIGGER trg_prevent_wallet_soft_delete
BEFORE UPDATE ON wallet_accounts
FOR EACH ROW
EXECUTE FUNCTION public.prevent_specialized_soft_delete();

-- Receivable
CREATE TRIGGER trg_prevent_receivable_soft_delete
BEFORE UPDATE ON receivable_accounts
FOR EACH ROW
EXECUTE FUNCTION public.prevent_specialized_soft_delete();
