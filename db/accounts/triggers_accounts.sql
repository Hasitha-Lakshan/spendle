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
CREATE OR REPLACE FUNCTION finance.account_has_active_transactions_internal(
    p_account_id UUID,
    p_profile_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
STABLE
AS $$
BEGIN
    -- Validate inputs
    IF p_account_id IS NULL THEN
        RAISE EXCEPTION 'p_account_id cannot be null'
            USING ERRCODE = '22004'; -- null_value_not_allowed
    END IF;

    IF p_profile_id IS NULL THEN
        RAISE EXCEPTION 'p_profile_id cannot be null'
            USING ERRCODE = '28000'; -- invalid_authorization_specification
    END IF;

    -- Check for any active transactions (short-circuit with EXISTS)
    RETURN EXISTS (
        SELECT 1
        FROM finance.transactions t
        WHERE t.profile_id = p_profile_id
          AND t.deleted_at IS NULL
          AND (
              EXISTS (
                  SELECT 1
                  FROM finance.transactions_income ti
                  WHERE ti.transaction_id = t.id
                    AND ti.account_id = p_account_id
                    AND ti.deleted_at IS NULL
              )
              OR EXISTS (
                  SELECT 1
                  FROM finance.transactions_expense te
                  WHERE te.transaction_id = t.id
                    AND te.account_id = p_account_id
                    AND te.deleted_at IS NULL
              )
              OR EXISTS (
                  SELECT 1
                  FROM finance.transactions_investment ti
                  WHERE ti.transaction_id = t.id
                    AND (ti.funding_account_id = p_account_id
                         OR ti.investment_account_id = p_account_id)
                    AND ti.deleted_at IS NULL
              )
              OR EXISTS (
                  SELECT 1
                  FROM finance.transactions_borrow tb
                  WHERE tb.transaction_id = t.id
                    AND (tb.loan_account_id = p_account_id
                         OR tb.disbursement_account_id = p_account_id)
                    AND tb.deleted_at IS NULL
              )
              OR EXISTS (
                  SELECT 1
                  FROM finance.transactions_lend tl
                  WHERE tl.transaction_id = t.id
                    AND (tl.funding_account_id = p_account_id
                         OR tl.receivable_account_id = p_account_id)
                    AND tl.deleted_at IS NULL
              )
              OR EXISTS (
                  SELECT 1
                  FROM finance.transactions_transfer tt
                  WHERE tt.transaction_id = t.id
                    AND (tt.from_account = p_account_id
                         OR tt.to_account = p_account_id)
                    AND tt.deleted_at IS NULL
              )
              OR EXISTS (
                  SELECT 1
                  FROM finance.transactions_adjustment ta
                  WHERE ta.transaction_id = t.id
                    AND ta.account_id = p_account_id
                    AND ta.deleted_at IS NULL
              )
          )
    );
END;
$$;

-- =========================================
-- 02. Function: validate_account_balance
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
CREATE OR REPLACE FUNCTION finance.validate_account_balance() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
BEGIN
    -- Validate account balances according to account type
    CASE TG_TABLE_NAME
        WHEN 'cash_accounts' THEN
            IF NEW.balance IS NULL OR NEW.balance < 0 THEN
                RAISE EXCEPTION 'Cash account balance cannot be negative or empty.'
                    USING ERRCODE = '22023';
            END IF;

        WHEN 'bank_accounts' THEN
            IF NEW.balance IS NULL OR NEW.balance < 0 THEN
                RAISE EXCEPTION 'Bank account balance cannot be negative or empty.'
                    USING ERRCODE = '22023';
            END IF;

        WHEN 'wallet_accounts' THEN
            IF NEW.balance IS NULL OR NEW.balance < 0 THEN
                RAISE EXCEPTION 'Wallet account balance cannot be negative or empty.'
                    USING ERRCODE = '22023';
            END IF;

        WHEN 'crypto_accounts' THEN
            IF NEW.balance IS NULL OR NEW.balance < 0 THEN
                RAISE EXCEPTION 'Crypto account balance cannot be negative or empty.'
                    USING ERRCODE = '22023';
            END IF;

        WHEN 'credit_card_accounts' THEN
            -- Notice if negative current balance
            IF NEW.current_balance IS NOT NULL AND NEW.current_balance < 0 THEN
                RAISE NOTICE 'Your credit card balance is negative. Please review your payments.';
            END IF;

            -- Error if exceeding credit limit
            IF NEW.credit_limit IS NOT NULL AND NEW.current_balance > NEW.credit_limit THEN
                RAISE EXCEPTION 'Your credit card balance exceeds the allowed limit.'
                    USING ERRCODE = '22023';
            END IF;

        WHEN 'loan_accounts' THEN
            IF NEW.outstanding_amount IS NULL OR NEW.outstanding_amount < 0 THEN
                RAISE EXCEPTION 'Loan balance cannot be negative or empty.'
                    USING ERRCODE = '22023';
            END IF;

        WHEN 'investment_accounts' THEN
            IF NEW.portfolio_value IS NULL OR NEW.portfolio_value < 0 THEN
                RAISE EXCEPTION 'Investment account value cannot be negative or empty.'
                    USING ERRCODE = '22023';
            END IF;

        WHEN 'receivable_accounts' THEN
            IF NEW.amount_due IS NULL OR NEW.amount_due < 0 THEN
                RAISE EXCEPTION 'Receivable amount cannot be negative or empty.'
                    USING ERRCODE = '22023';
            END IF;

        ELSE
            RAISE EXCEPTION 'Account type is not recognized.'
                USING ERRCODE = 'P0002';
    END CASE;

    RETURN NEW;
END;
$$;

-- Create triggers on each specialized account table (fully schema-qualified)

-- Cash
CREATE TRIGGER trg_0100_validate_cash_balance
BEFORE INSERT OR UPDATE ON finance.cash_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.validate_account_balance();

-- Bank
CREATE TRIGGER trg_0100_validate_bank_balance
BEFORE INSERT OR UPDATE ON finance.bank_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.validate_account_balance();

-- Wallet
CREATE TRIGGER trg_0100_validate_wallet_balance
BEFORE INSERT OR UPDATE ON finance.wallet_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.validate_account_balance();

-- Crypto
CREATE TRIGGER trg_0100_validate_crypto_balance
BEFORE INSERT OR UPDATE ON finance.crypto_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.validate_account_balance();

-- Credit Card
CREATE TRIGGER trg_0100_validate_credit_card_balance
BEFORE INSERT OR UPDATE ON finance.credit_card_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.validate_account_balance();

-- Loan
CREATE TRIGGER trg_0100_validate_loan_balance
BEFORE INSERT OR UPDATE ON finance.loan_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.validate_account_balance();

-- Investment
CREATE TRIGGER trg_0100_validate_investment_balance
BEFORE INSERT OR UPDATE ON finance.investment_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.validate_account_balance();

-- Receivable
CREATE TRIGGER trg_0100_validate_receivable_balance
BEFORE INSERT OR UPDATE ON finance.receivable_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.validate_account_balance();

-- =========================================
-- 03. Function: update_receivable_status
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
CREATE OR REPLACE FUNCTION finance.update_receivable_status() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
BEGIN
    -- Ensure amount_due is not null
    IF NEW.amount_due IS NULL THEN
        RAISE EXCEPTION 'amount_due cannot be NULL in receivable_accounts'
            USING ERRCODE = '23502'; -- not_null_violation
    END IF;

    -- Update receivable status based on amount_due and due_date
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

-- Create trigger on receivable_accounts table (fully schema-qualified)
CREATE TRIGGER trg_0101_receivable_status
BEFORE INSERT OR UPDATE ON finance.receivable_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.update_receivable_status();

-- =========================================
-- 04. Function: update_loan_status
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
CREATE OR REPLACE FUNCTION finance.update_loan_status() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
BEGIN
    -- Ensure outstanding_amount is not NULL
    IF NEW.outstanding_amount IS NULL THEN
        RAISE EXCEPTION 'outstanding_amount cannot be NULL in loan_accounts'
            USING ERRCODE = '23502'; -- not_null_violation
    END IF;

    -- Update loan status based on outstanding_amount and end_date
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

-- Create trigger on loan_accounts table (fully schema-qualified)
CREATE TRIGGER trg_0101_loan_status
BEFORE INSERT OR UPDATE ON finance.loan_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.update_loan_status();

-- =========================================
-- 05. Function: prevent_balance_change_if_transactions
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
CREATE OR REPLACE FUNCTION finance.prevent_balance_change_if_transactions()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
DECLARE
    v_balance_changed BOOLEAN := FALSE;
    v_profile_id UUID;
BEGIN
    -- Resolve profile_id from parent account record
    SELECT a.profile_id
    INTO v_profile_id
    FROM finance.accounts a
    WHERE a.id = OLD.account_id; -- it it comes from soft-delete or hard-delete account record is already soft-deleted.

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'prevent_balance_change_if_transactions: account % not found in finance.accounts',
            OLD.account_id
            USING ERRCODE = 'P0002';
    END IF;

    -- Only enforce if account has active transactions
    IF finance.account_has_active_transactions_internal(OLD.account_id, v_profile_id) THEN

        -- Detect balance or related changes per account type
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
                RAISE EXCEPTION
                    'prevent_balance_change_if_transactions: unhandled table %',
                    TG_TABLE_NAME
                    USING ERRCODE = 'P0002';
        END CASE;

        -- Prevent balance modifications
        IF v_balance_changed THEN
            RAISE EXCEPTION
                'Cannot modify account balances when transactions exist for account %',
                OLD.account_id
                USING ERRCODE = '45000';
        END IF;

        -- Prevent soft delete
        IF TG_OP = 'UPDATE'
           AND OLD.deleted_at IS NULL
           AND NEW.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION
                'Cannot soft-delete account with existing transactions for account %',
                OLD.account_id
                USING ERRCODE = '45000';
        END IF;

        -- Prevent hard delete
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION
                'Cannot delete account with existing transactions for account %',
                OLD.account_id
                USING ERRCODE = '45000';
        END IF;

    END IF;

    -- Return appropriate row
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

-- Create triggers on each specialized account table (fully schema-qualified)

-- Cash
CREATE TRIGGER trg_0102_prevent_cash_balance_change
BEFORE UPDATE OR DELETE ON finance.cash_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_balance_change_if_transactions();

-- Bank
CREATE TRIGGER trg_0102_prevent_bank_balance_change
BEFORE UPDATE OR DELETE ON finance.bank_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_balance_change_if_transactions();

-- Wallet
CREATE TRIGGER trg_0102_prevent_wallet_balance_change
BEFORE UPDATE OR DELETE ON finance.wallet_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_balance_change_if_transactions();

-- Crypto
CREATE TRIGGER trg_0102_prevent_crypto_balance_change
BEFORE UPDATE OR DELETE ON finance.crypto_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_balance_change_if_transactions();

-- Credit Card
CREATE TRIGGER trg_0102_prevent_credit_card_balance_change
BEFORE UPDATE OR DELETE ON finance.credit_card_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_balance_change_if_transactions();

-- Investment
CREATE TRIGGER trg_0102_prevent_investment_balance_change
BEFORE UPDATE OR DELETE ON finance.investment_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_balance_change_if_transactions();

-- Loan
CREATE TRIGGER trg_0102_prevent_loan_balance_change
BEFORE UPDATE OR DELETE ON finance.loan_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_balance_change_if_transactions();

-- Receivable
CREATE TRIGGER trg_0102_prevent_receivable_balance_change
BEFORE UPDATE OR DELETE ON finance.receivable_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_balance_change_if_transactions();

-- =========================================
-- 06. Function: prevent_specialized_soft_delete
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
CREATE OR REPLACE FUNCTION finance.prevent_specialized_soft_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
BEGIN
    -- Block direct soft-delete unless parent trigger flagged it
    IF OLD.deleted_at IS NULL
       AND NEW.deleted_at IS NOT NULL
       AND current_setting('app.allow_specialized_soft_delete', true) IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'Direct soft-delete on table % for account id % is not allowed. Use parent account operations',
            TG_TABLE_NAME, OLD.account_id
            USING ERRCODE = '45000'; -- user-defined exception
    END IF;

    RETURN NEW;
END;
$$;

-- Cash
CREATE TRIGGER trg_0103_prevent_cash_soft_delete
BEFORE UPDATE ON finance.cash_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_specialized_soft_delete();

-- Bank
CREATE TRIGGER trg_0103_prevent_bank_soft_delete
BEFORE UPDATE ON finance.bank_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_specialized_soft_delete();

-- Credit Card
CREATE TRIGGER trg_0103_prevent_credit_card_soft_delete
BEFORE UPDATE ON finance.credit_card_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_specialized_soft_delete();

-- Loan
CREATE TRIGGER trg_0103_prevent_loan_soft_delete
BEFORE UPDATE ON finance.loan_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_specialized_soft_delete();

-- Investment
CREATE TRIGGER trg_0103_prevent_investment_soft_delete
BEFORE UPDATE ON finance.investment_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_specialized_soft_delete();

-- Crypto
CREATE TRIGGER trg_0103_prevent_crypto_soft_delete
BEFORE UPDATE ON finance.crypto_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_specialized_soft_delete();

-- Wallet
CREATE TRIGGER trg_0103_prevent_wallet_soft_delete
BEFORE UPDATE ON finance.wallet_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_specialized_soft_delete();

-- Receivable
CREATE TRIGGER trg_0103_prevent_receivable_soft_delete
BEFORE UPDATE ON finance.receivable_accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_specialized_soft_delete();

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
CREATE OR REPLACE FUNCTION finance.prevent_account_type_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
BEGIN
    -- Prevent changing account type after creation
    IF NEW.type IS DISTINCT FROM OLD.type THEN
        RAISE EXCEPTION
            'Account type cannot be changed for account % (from % to %)',
            OLD.id, OLD.type, NEW.type
            USING ERRCODE = '45000';
    END IF;

    RETURN NEW;
END;
$$;

-- Create trigger on accounts table (fully schema-qualified)
CREATE TRIGGER trg_0100_prevent_account_type_change
BEFORE UPDATE ON finance.accounts
FOR EACH ROW
EXECUTE FUNCTION finance.prevent_account_type_change();

-- =========================================
-- 08. Function: validate_account_modification
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
CREATE OR REPLACE FUNCTION finance.validate_account_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
BEGIN
    -- Only enforce rules if account has active transactions
    IF finance.account_has_active_transactions_internal(OLD.id, OLD.profile_id) THEN

        -- Handle UPDATE operations
        IF TG_OP = 'UPDATE' THEN
            -- Prevent modification of currency
            IF OLD.currency IS DISTINCT FROM NEW.currency THEN
                RAISE EXCEPTION
                    'Cannot modify account currency when transactions exist for account %',
                    OLD.id
                    USING ERRCODE = '45000';
            END IF;

            -- Prevent soft delete
            IF OLD.deleted_at IS NULL
               AND NEW.deleted_at IS NOT NULL THEN
                RAISE EXCEPTION
                    'Cannot soft-delete account with existing transactions for account %',
                    OLD.id
                    USING ERRCODE = '45000';
            END IF;
        END IF;

        -- Handle DELETE operations
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION
                'Cannot hard-delete account with existing transactions for account %',
                OLD.id
                USING ERRCODE = '45000';
        END IF;
    END IF;

    -- Return the appropriate row
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

-- Add triggers for account validation
CREATE TRIGGER trg_0101_validate_account_modification
BEFORE UPDATE OR DELETE ON finance.accounts
FOR EACH ROW
EXECUTE FUNCTION finance.validate_account_modification();

-- =========================================
-- 09. Function: soft_delete_specialized_account
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
CREATE OR REPLACE FUNCTION finance.soft_delete_specialized_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance
VOLATILE
AS $$
BEGIN
    -- Set allow_specialized_soft_delete flag
    PERFORM set_config('app.allow_specialized_soft_delete', 'true', true);

    -- Soft-delete propagation
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        CASE OLD.type
            WHEN 'cash' THEN
                UPDATE finance.cash_accounts
                SET deleted_at = NEW.deleted_at, updated_at = NOW()
                WHERE account_id = OLD.id AND deleted_at IS NULL;

            WHEN 'bank' THEN
                UPDATE finance.bank_accounts
                SET deleted_at = NEW.deleted_at, updated_at = NOW()
                WHERE account_id = OLD.id AND deleted_at IS NULL;

            WHEN 'credit_card' THEN
                UPDATE finance.credit_card_accounts
                SET deleted_at = NEW.deleted_at, updated_at = NOW()
                WHERE account_id = OLD.id AND deleted_at IS NULL;

            WHEN 'loan' THEN
                UPDATE finance.loan_accounts
                SET deleted_at = NEW.deleted_at, updated_at = NOW()
                WHERE account_id = OLD.id AND deleted_at IS NULL;

            WHEN 'investment' THEN
                UPDATE finance.investment_accounts
                SET deleted_at = NEW.deleted_at, updated_at = NOW()
                WHERE account_id = OLD.id AND deleted_at IS NULL;

            WHEN 'crypto' THEN
                UPDATE finance.crypto_accounts
                SET deleted_at = NEW.deleted_at, updated_at = NOW()
                WHERE account_id = OLD.id AND deleted_at IS NULL;

            WHEN 'wallet' THEN
                UPDATE finance.wallet_accounts
                SET deleted_at = NEW.deleted_at, updated_at = NOW()
                WHERE account_id = OLD.id AND deleted_at IS NULL;

            WHEN 'receivable' THEN
                UPDATE finance.receivable_accounts
                SET deleted_at = NEW.deleted_at, updated_at = NOW()
                WHERE account_id = OLD.id AND deleted_at IS NULL;

            ELSE
                RAISE EXCEPTION 'Unknown account type % in soft_delete_specialized_account for account %', 
                    OLD.type, OLD.id
                    USING ERRCODE = '45000'; -- user-defined exception
        END CASE;
    END IF;

    RETURN NEW;
END;
$$;

-- Create trigger on accounts table (fully schema-qualified)
CREATE TRIGGER trg_0150_cleanup_specialized_account
AFTER UPDATE ON finance.accounts
FOR EACH ROW EXECUTE FUNCTION finance.soft_delete_specialized_account();
