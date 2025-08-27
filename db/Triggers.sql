-- ======================================================
-- Triggers & Functions
-- ======================================================
-- This file defines all triggers and functions for:
--   Audit logs with dual user tracking (user_id + action_by)
--   Auto-updated timestamps
--   Default setup for new profiles
--   Specialized account sync with proper field updates
--   Account balance updates for ALL specific fields per account type
--   Comprehensive soft delete with cascading cleanup
--   Business validations
--   Counterparty rules
--   Auto status updates
--   Recurring transaction processing with action_by auto-population
-- ======================================================

-- =========================================
-- 1. AUDIT LOGGING WITH DUAL USER TRACKING
-- =========================================
-- =========================================
CREATE OR REPLACE FUNCTION log_audit() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    affected_user_id UUID;
    actor_user_id UUID;
BEGIN
    -- Get the affected user ID from the record
    IF TG_OP = 'DELETE' THEN
        affected_user_id := OLD.user_id;
    ELSE
        affected_user_id := NEW.user_id;
    END IF;
    
    -- Get the actor (current authenticated user) - can be same or different from affected user
    actor_user_id := auth.uid();
    
    -- If no authenticated user, use the affected user as fallback (for system operations)
    IF actor_user_id IS NULL THEN
        actor_user_id := affected_user_id;
    END IF;

    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.audit_logs(user_id, action_by, table_name, record_id, action, new_data)
        VALUES (affected_user_id, actor_user_id, TG_TABLE_NAME, NEW.id, 'INSERT', row_to_json(NEW));
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO public.audit_logs(user_id, action_by, table_name, record_id, action, old_data, new_data)
        VALUES (affected_user_id, actor_user_id, TG_TABLE_NAME, NEW.id, 'UPDATE', row_to_json(OLD), row_to_json(NEW));
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO public.audit_logs(user_id, action_by, table_name, record_id, action, old_data)
        VALUES (affected_user_id, actor_user_id, TG_TABLE_NAME, OLD.id, 'DELETE', row_to_json(OLD));
    END IF;

    RETURN NULL;
END;
$$;

-- Create audit triggers for all major tables
DO $$
DECLARE 
    t text;
BEGIN
    FOR t IN 
        SELECT tablename FROM pg_tables 
        WHERE schemaname = 'public' 
        AND tablename NOT IN ('audit_logs') 
        AND tablename ~ '^(profiles|accounts|.*_accounts|transactions.*|expense_.*|income_sources|counterparties)$'
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_%I ON %I;', t, t);
        EXECUTE format('CREATE TRIGGER trg_audit_%I AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION log_audit();', t, t);
    END LOOP;
END$$;

-- =========================================
-- 2. AUTO UPDATE updated_at TIMESTAMPS
-- =========================================
CREATE OR REPLACE FUNCTION set_updated_at() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

-- Apply to all tables with updated_at column
DO $$
DECLARE 
    t text;
BEGIN
    FOR t IN 
        SELECT tablename FROM pg_tables t1
        WHERE schemaname = 'public'
        AND EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'public' 
            AND table_name = t1.tablename 
            AND column_name = 'updated_at'
        )
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%I_updated ON %I;', t, t);
        EXECUTE format('CREATE TRIGGER trg_%I_updated BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
    END LOOP;
END$$;

-- =========================================
-- 3. DEFAULT SETUP FOR NEW PROFILES
-- =========================================
CREATE OR REPLACE FUNCTION insert_profile_defaults() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    default_account_id UUID;
    default_category_id UUID;
    default_source_id UUID;
BEGIN
    -- Only insert defaults if not already inserted
    IF NOT COALESCE(NEW.defaults_inserted, FALSE) THEN
        -- Create default cash account
        INSERT INTO accounts(user_id, account_name, type, currency)
        VALUES (NEW.user_id, 'Cash Wallet', 'cash', 'USD')
        RETURNING id INTO default_account_id;

        -- Create default cash account details
        INSERT INTO cash_accounts(account_id, location, balance, status, notes)
        VALUES (default_account_id, 'Wallet', 0, 'active', 'Default cash account');

        -- Create default expense category
        INSERT INTO expense_categories(user_id, name) 
        VALUES (NEW.user_id, 'General')
        RETURNING id INTO default_category_id;
        
        -- Create default expense subcategory
        INSERT INTO expense_subcategories(category_id, name)
        VALUES (default_category_id, 'Miscellaneous');
        
        -- Create default income source
        INSERT INTO income_sources(user_id, name) 
        VALUES (NEW.user_id, 'Salary')
        RETURNING id INTO default_source_id;

        -- Mark defaults as inserted
        UPDATE profiles 
        SET defaults_inserted = TRUE,
            updated_at = NOW()
        WHERE user_id = NEW.user_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_insert_profile_defaults
    AFTER INSERT ON profiles
    FOR EACH ROW
    WHEN (NEW.defaults_inserted IS FALSE OR NEW.defaults_inserted IS NULL)
    EXECUTE FUNCTION insert_profile_defaults();

-- =========================================
-- 4. SPECIALIZED ACCOUNT SYNC WITH PROPER FIELD INITIALIZATION
-- =========================================
CREATE OR REPLACE FUNCTION insert_specialized_account() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    CASE NEW.type
        WHEN 'cash' THEN
            INSERT INTO public.cash_accounts(account_id, balance, status, location, notes) 
            VALUES (NEW.id, 0, 'active', 'Wallet', 'Default cash account');
        WHEN 'bank' THEN
            INSERT INTO public.bank_accounts(account_id, bank_name, account_no, balance, status, branch, account_holder_name, interest_rate, notes) 
            VALUES (NEW.id, 'UNKNOWN', '0000', 0, 'active', NULL, NULL, NULL, 'Default bank account');
        WHEN 'credit_card' THEN
            INSERT INTO public.credit_card_accounts(account_id, card_number, current_balance, status, card_type, credit_limit, billing_cycle, interest_rate, notes) 
            VALUES (NEW.id, '0000', 0, 'active', NULL, NULL, NULL, NULL, 'Default credit card');
        WHEN 'loan' THEN
            INSERT INTO public.loan_accounts(account_id, outstanding_amount, status, loan_type, principal_amount, interest_rate, term_months, start_date, end_date, notes) 
            VALUES (NEW.id, 0, 'active', NULL, NULL, NULL, NULL, NULL, NULL, 'Default loan account');
        WHEN 'investment' THEN
            INSERT INTO public.investment_accounts(account_id, portfolio_value, status, investment_type, institution_name, account_no, notes) 
            VALUES (NEW.id, 0, 'active', NULL, NULL, NULL, 'Default investment account');
        WHEN 'crypto' THEN
            INSERT INTO public.crypto_accounts(account_id, crypto_wallet_address, balance, status, exchange_name, notes) 
            VALUES (NEW.id, 'pending', 0, 'active', NULL, 'Default crypto account');
        WHEN 'wallet' THEN
            INSERT INTO public.wallet_accounts(account_id, wallet_name, balance, status, provider, notes) 
            VALUES (NEW.id, 'Default', 0, 'active', NULL, 'Default wallet account');
        WHEN 'receivable' THEN
            INSERT INTO public.receivable_accounts(account_id, amount_due, status, customer_name, invoice_no, principal_amount, due_date, notes) 
            VALUES (NEW.id, 0, 'pending', NULL, NULL, NULL, NULL, 'Default receivable account');
        ELSE
            RAISE EXCEPTION 'Unknown account type: %', NEW.type;
    END CASE;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_insert_specialized_account
    AFTER INSERT ON accounts
    FOR EACH ROW EXECUTE FUNCTION insert_specialized_account();

-- =========================================
-- 5. COMPREHENSIVE ACCOUNT BALANCE UPDATES FOR ALL SPECIFIC FIELDS
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
-- 6. ENHANCED TRANSFER BALANCE HANDLING
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

DROP TRIGGER IF EXISTS trigger_apply_transfer_balances ON transactions_transfer;
CREATE TRIGGER trigger_apply_transfer_balances
    AFTER INSERT ON transactions_transfer
    FOR EACH ROW 
    EXECUTE FUNCTION apply_transfer_balances();

-- =========================================
-- 7. COMPREHENSIVE SOFT DELETE ENFORCEMENT
-- =========================================
CREATE OR REPLACE FUNCTION enforce_soft_delete() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Update the deleted_at timestamp instead of hard delete
    EXECUTE format(
        'UPDATE %I SET deleted_at = NOW(), updated_at = NOW() WHERE id = $1',
        TG_TABLE_NAME
    ) USING OLD.id;

    RETURN NULL; -- Prevent actual delete
END;
$$;

-- Apply to all major tables
CREATE TRIGGER trg_profiles_no_delete
    BEFORE DELETE ON profiles
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_accounts_no_delete
    BEFORE DELETE ON accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_no_delete
    BEFORE DELETE ON transactions
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_counterparties_no_delete
    BEFORE DELETE ON counterparties
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_expense_categories_no_delete
    BEFORE DELETE ON expense_categories
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_expense_subcategories_no_delete
    BEFORE DELETE ON expense_subcategories
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_income_sources_no_delete
    BEFORE DELETE ON income_sources
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_recurring_no_delete
    BEFORE DELETE ON transactions_recurring
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

-- Soft delete for specialized account tables
CREATE TRIGGER trg_cash_accounts_no_delete
    BEFORE DELETE ON cash_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_bank_accounts_no_delete
    BEFORE DELETE ON bank_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_credit_card_accounts_no_delete
    BEFORE DELETE ON credit_card_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_loan_accounts_no_delete
    BEFORE DELETE ON loan_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_investment_accounts_no_delete
    BEFORE DELETE ON investment_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_crypto_accounts_no_delete
    BEFORE DELETE ON crypto_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_wallet_accounts_no_delete
    BEFORE DELETE ON wallet_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_receivable_accounts_no_delete
    BEFORE DELETE ON receivable_accounts
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

-- Soft delete for transaction detail tables
CREATE TRIGGER trg_transactions_income_no_delete
    BEFORE DELETE ON transactions_income
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_expense_no_delete
    BEFORE DELETE ON transactions_expense
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_investment_no_delete
    BEFORE DELETE ON transactions_investment
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_borrow_no_delete
    BEFORE DELETE ON transactions_borrow
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_lend_no_delete
    BEFORE DELETE ON transactions_lend
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_transfer_no_delete
    BEFORE DELETE ON transactions_transfer
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

CREATE TRIGGER trg_transactions_adjustment_no_delete
    BEFORE DELETE ON transactions_adjustment
    FOR EACH ROW EXECUTE FUNCTION enforce_soft_delete();

-- =========================================
-- 8. CASCADING SOFT DELETE CLEANUP
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
-- 9. TRANSACTION DETAIL CLEANUP ON TRANSACTION SOFT DELETE
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
-- 10. BALANCE REVERSAL ON SOFT DELETE
-- =========================================
CREATE OR REPLACE FUNCTION reverse_balance_on_soft_delete() 
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
        
        -- Handle different transaction types with specific field reversals
        CASE NEW.type
            WHEN 'income' THEN
                SELECT * INTO tx_details 
                FROM public.transactions_income 
                WHERE transaction_id = NEW.id
                  AND EXISTS (
                      SELECT 1 FROM public.accounts a 
                      WHERE a.id = transactions_income.account_id 
                        AND a.user_id = auth.uid()
                        AND a.deleted_at IS NULL
                  );
                IF FOUND THEN
                    SELECT type INTO acc_type 
                    FROM public.accounts 
                    WHERE id = tx_details.account_id 
                      AND user_id = auth.uid()
                      AND deleted_at IS NULL;

                    UPDATE public.accounts 
                    SET updated_at = NOW() 
                    WHERE id = tx_details.account_id;

                    CASE acc_type
                        WHEN 'cash' THEN 
                            UPDATE public.cash_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'bank' THEN 
                            UPDATE public.bank_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'wallet' THEN 
                            UPDATE public.wallet_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'crypto' THEN 
                            UPDATE public.crypto_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'investment' THEN 
                            UPDATE public.investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'receivable' THEN 
                            UPDATE public.receivable_accounts 
                            SET amount_due = COALESCE(amount_due,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                    END CASE;
                END IF;

            WHEN 'expense' THEN
            -- Get expense transaction details
                SELECT * INTO tx_details 
                FROM public.transactions_expense 
                WHERE transaction_id = NEW.id
                  AND EXISTS (
                      SELECT 1 FROM public.accounts a 
                      WHERE a.id = transactions_expense.account_id 
                        AND a.user_id = auth.uid()
                        AND a.deleted_at IS NULL
                  );
                IF FOUND THEN
                    SELECT type INTO acc_type 
                    FROM public.accounts 
                    WHERE id = tx_details.account_id 
                      AND user_id = auth.uid()
                      AND deleted_at IS NULL;

                    UPDATE public.accounts 
                    SET updated_at = NOW() 
                    WHERE id = tx_details.account_id;

                    CASE acc_type
                        WHEN 'cash' THEN 
                            UPDATE public.cash_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'bank' THEN 
                            UPDATE public.bank_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'wallet' THEN 
                            UPDATE public.wallet_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'crypto' THEN 
                            UPDATE public.crypto_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'credit_card' THEN 
                            UPDATE public.credit_card_accounts 
                            SET current_balance = COALESCE(current_balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'investment' THEN 
                            UPDATE public.investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                    END CASE;
                END IF;

            WHEN 'investment' THEN
            -- Get investment transaction details
                SELECT * INTO tx_details 
                FROM public.transactions_investment 
                WHERE transaction_id = NEW.id
                  AND EXISTS (
                      SELECT 1 FROM public.accounts a 
                      WHERE a.id = transactions_investment.account_id 
                        AND a.user_id = auth.uid()
                        AND a.deleted_at IS NULL
                  );
                IF FOUND THEN
                    SELECT type INTO acc_type 
                    FROM public.accounts 
                    WHERE id = tx_details.account_id 
                      AND user_id = auth.uid()
                      AND deleted_at IS NULL;

                    UPDATE public.accounts 
                    SET updated_at = NOW() 
                    WHERE id = tx_details.account_id;

                    CASE acc_type
                        WHEN 'investment' THEN 
                            UPDATE public.investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'cash' THEN 
                            UPDATE public.cash_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'bank' THEN 
                            UPDATE public.bank_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                    END CASE;
                END IF;

            WHEN 'adjustment' THEN
            -- Get adjustment transaction details
                SELECT * INTO tx_details 
                FROM public.transactions_adjustment 
                WHERE transaction_id = NEW.id
                  AND EXISTS (
                      SELECT 1 FROM public.accounts a 
                      WHERE a.id = transactions_adjustment.account_id 
                        AND a.user_id = auth.uid()
                        AND a.deleted_at IS NULL
                  );
                IF FOUND THEN
                    SELECT type INTO acc_type 
                    FROM public.accounts 
                    WHERE id = tx_details.account_id 
                      AND user_id = auth.uid()
                      AND deleted_at IS NULL;

                    UPDATE public.accounts 
                    SET updated_at = NOW() 
                    WHERE id = tx_details.account_id;

                    CASE acc_type
                        WHEN 'cash' THEN 
                            UPDATE public.cash_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'bank' THEN 
                            UPDATE public.bank_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'wallet' THEN 
                            UPDATE public.wallet_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'crypto' THEN 
                            UPDATE public.crypto_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'credit_card' THEN 
                            UPDATE public.credit_card_accounts 
                            SET current_balance = COALESCE(current_balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'investment' THEN 
                            UPDATE public.investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'loan' THEN 
                            UPDATE public.loan_accounts 
                            SET outstanding_amount = COALESCE(outstanding_amount,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'receivable' THEN 
                            UPDATE public.receivable_accounts 
                            SET amount_due = COALESCE(amount_due,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                    END CASE;
                END IF;

            WHEN 'borrow' THEN
            -- Get borrow transaction details
                SELECT * INTO tx_details 
                FROM public.transactions_borrow 
                WHERE transaction_id = NEW.id
                  AND EXISTS (
                      SELECT 1 FROM public.accounts a 
                      WHERE a.id = transactions_borrow.account_id 
                        AND a.user_id = auth.uid()
                        AND a.deleted_at IS NULL
                  );
                IF FOUND THEN
                    UPDATE public.loan_accounts 
                    SET outstanding_amount = COALESCE(outstanding_amount,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                    WHERE account_id = tx_details.account_id;

                    UPDATE public.accounts 
                    SET updated_at = NOW() 
                    WHERE id = tx_details.account_id;
                END IF;

            WHEN 'lend' THEN
            -- Get lend transaction details
                SELECT * INTO tx_details 
                FROM public.transactions_lend 
                WHERE transaction_id = NEW.id
                  AND EXISTS (
                      SELECT 1 FROM public.accounts a 
                      WHERE a.id = transactions_lend.account_id 
                        AND a.user_id = auth.uid()
                        AND a.deleted_at IS NULL
                  );
                IF FOUND THEN
                    UPDATE public.receivable_accounts 
                    SET amount_due = COALESCE(amount_due,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                    WHERE account_id = tx_details.account_id;

                    UPDATE public.accounts 
                    SET updated_at = NOW() 
                    WHERE id = tx_details.account_id;
                END IF;

            WHEN 'transfer' THEN
            -- Get transfer transaction details
                SELECT * INTO transfer_details 
                FROM public.transactions_transfer 
                WHERE transaction_id = NEW.id
                  AND EXISTS (
                      SELECT 1 FROM public.accounts a1 
                      WHERE a1.id = transactions_transfer.from_account 
                        AND a1.user_id = auth.uid()
                        AND a1.deleted_at IS NULL
                  )
                  AND EXISTS (
                      SELECT 1 FROM public.accounts a2 
                      WHERE a2.id = transactions_transfer.to_account 
                        AND a2.user_id = auth.uid()
                        AND a2.deleted_at IS NULL
                  );
                IF FOUND THEN
                    SELECT type INTO from_acc_type 
                    FROM public.accounts 
                    WHERE id = transfer_details.from_account 
                      AND user_id = auth.uid()
                      AND deleted_at IS NULL;

                    SELECT type INTO to_acc_type 
                    FROM public.accounts 
                    WHERE id = transfer_details.to_account 
                      AND user_id = auth.uid()
                      AND deleted_at IS NULL;

                    UPDATE public.accounts 
                    SET updated_at = NOW() 
                    WHERE id IN (transfer_details.from_account, transfer_details.to_account);

                    -- Reverse from_account changes (add back what was subtracted)
                    CASE from_acc_type
                        WHEN 'cash' THEN
                            UPDATE public.cash_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(transfer_details.fees,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'bank' THEN
                            UPDATE public.bank_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(transfer_details.fees,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'wallet' THEN
                            UPDATE public.wallet_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(transfer_details.fees,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'crypto' THEN
                            UPDATE public.crypto_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(transfer_details.fees,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'credit_card' THEN
                            UPDATE public.credit_card_accounts 
                            SET current_balance = COALESCE(current_balance,0) - COALESCE(NEW.amount,0) - COALESCE(transfer_details.fees,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'loan' THEN
                            UPDATE public.loan_accounts 
                            SET outstanding_amount = COALESCE(outstanding_amount,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'investment' THEN
                            UPDATE public.investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) + COALESCE(NEW.amount,0) + COALESCE(transfer_details.fees,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'receivable' THEN
                            UPDATE public.receivable_accounts 
                            SET amount_due = COALESCE(amount_due,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                    END CASE;

                    -- Reverse to_account changes
                    CASE to_acc_type
                        WHEN 'cash' THEN
                            UPDATE public.cash_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'bank' THEN
                            UPDATE public.bank_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'wallet' THEN
                            UPDATE public.wallet_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'crypto' THEN
                            UPDATE public.crypto_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'credit_card' THEN
                            UPDATE public.credit_card_accounts 
                            SET current_balance = COALESCE(current_balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'loan' THEN
                            UPDATE public.loan_accounts 
                            SET outstanding_amount = COALESCE(outstanding_amount,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'investment' THEN
                            UPDATE public.investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'receivable' THEN
                            UPDATE public.receivable_accounts 
                            SET amount_due = COALESCE(amount_due,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                    END CASE;

                    -- Log fees reversal explicitly for audit
                    -- INSERT INTO audit_logs(user_id, action_by, action, created_at)
                    -- VALUES (NULL, NEW.created_by, format('Reversed transfer fees %s for transaction %s', COALESCE(transfer_details.fees,0), NEW.id), NOW());
                END IF;
        END CASE;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reverse_balance_soft_delete
    AFTER UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION reverse_balance_on_soft_delete();

-- =========================================
-- 11. COMPREHENSIVE VALIDATION CHECKS
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

-- Transfer validation (both accounts must belong to same user)
CREATE OR REPLACE FUNCTION validate_transfer_accounts() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE 
    from_user UUID;
    to_user UUID;
    tx_user UUID;
BEGIN
    -- Get users with RLS checks
    SELECT user_id INTO from_user 
    FROM accounts 
    WHERE id = NEW.from_account 
    AND user_id = auth.uid()
    AND deleted_at IS NULL;
    
    SELECT user_id INTO to_user 
    FROM accounts 
    WHERE id = NEW.to_account 
    AND user_id = auth.uid()
    AND deleted_at IS NULL;
    
    SELECT user_id INTO tx_user 
    FROM transactions 
    WHERE id = NEW.transaction_id 
    AND user_id = auth.uid()
    AND deleted_at IS NULL;
    
    IF from_user IS NULL OR to_user IS NULL OR tx_user IS NULL THEN
        RAISE EXCEPTION 'Accounts or transaction not found or access denied';
    END IF;

    IF from_user <> to_user OR from_user <> tx_user THEN
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
-- 12. COUNTERPARTY UNIQUENESS RULES (RLS COMPLIANT)
-- =========================================
CREATE OR REPLACE FUNCTION public.enforce_counterparty_unique()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 
        FROM public.counterparties
        WHERE user_id = NEW.user_id
          AND user_id = auth.uid() -- RLS check
          AND name = NEW.name 
          AND type = NEW.type 
          AND deleted_at IS NULL
          AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
    ) THEN
        RAISE EXCEPTION 'Counterparty with name "%" and type "%" already exists for this user',
            NEW.name, NEW.type;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_counterparty_unique
    BEFORE INSERT OR UPDATE ON counterparties
    FOR EACH ROW EXECUTE FUNCTION enforce_counterparty_unique();

-- =========================================
-- 13. AUTO STATUS UPDATES
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

-- Loan status management
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
-- 14. CURRENCY VALIDATION (RLS COMPLIANT)
-- =========================================
CREATE OR REPLACE FUNCTION enforce_currency_match() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_account_currency VARCHAR(10);
    v_tx_currency VARCHAR(10);
BEGIN
    -- Get transaction currency
    SELECT currency INTO v_tx_currency 
    FROM public.transactions 
    WHERE id = NEW.transaction_id 
      AND user_id = auth.uid()
      AND deleted_at IS NULL;
    
    IF v_tx_currency IS NULL THEN
        RAISE EXCEPTION 'Transaction not found or access denied';
    END IF;

    -- For transfer transactions, check both accounts
    IF TG_TABLE_NAME = 'transactions_transfer' THEN
        SELECT currency INTO v_account_currency 
        FROM public.accounts 
        WHERE id = NEW.from_account 
          AND user_id = auth.uid()
          AND deleted_at IS NULL;
        
        IF v_account_currency IS NULL THEN
            RAISE EXCEPTION 'From account not found or access denied';
        END IF;
        
        IF v_tx_currency <> v_account_currency THEN
            RAISE EXCEPTION 'Transaction currency (%) must match from_account currency (%)', v_tx_currency, v_account_currency;
        END IF;
        
        SELECT currency INTO v_account_currency 
        FROM public.accounts 
        WHERE id = NEW.to_account 
          AND user_id = auth.uid()
          AND deleted_at IS NULL;
        
        IF v_account_currency IS NULL THEN
            RAISE EXCEPTION 'To account not found or access denied';
        END IF;
        
        IF v_tx_currency <> v_account_currency THEN
            RAISE EXCEPTION 'Transaction currency (%) must match to_account currency (%)', v_tx_currency, v_account_currency;
        END IF;
    ELSE
        -- For other transaction types, check the account
        SELECT currency INTO v_account_currency 
        FROM public.accounts 
        WHERE id = NEW.account_id 
          AND user_id = auth.uid()
          AND deleted_at IS NULL;
        
        IF v_account_currency IS NULL THEN
            RAISE EXCEPTION 'Account not found or access denied';
        END IF;
        
        IF v_tx_currency <> v_account_currency THEN
            RAISE EXCEPTION 'Transaction currency (%) must match account currency (%)', v_tx_currency, v_account_currency;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

-- Apply currency validation to all transaction detail tables
CREATE TRIGGER trg_currency_match_income
    BEFORE INSERT OR UPDATE ON transactions_income
    FOR EACH ROW EXECUTE FUNCTION enforce_currency_match();

CREATE TRIGGER trg_currency_match_expense
    BEFORE INSERT OR UPDATE ON transactions_expense
    FOR EACH ROW EXECUTE FUNCTION enforce_currency_match();

CREATE TRIGGER trg_currency_match_investment
    BEFORE INSERT OR UPDATE ON transactions_investment
    FOR EACH ROW EXECUTE FUNCTION enforce_currency_match();

CREATE TRIGGER trg_currency_match_adjustment
    BEFORE INSERT OR UPDATE ON transactions_adjustment
    FOR EACH ROW EXECUTE FUNCTION enforce_currency_match();

CREATE TRIGGER trg_currency_match_borrow
    BEFORE INSERT OR UPDATE ON transactions_borrow
    FOR EACH ROW EXECUTE FUNCTION enforce_currency_match();

CREATE TRIGGER trg_currency_match_lend
    BEFORE INSERT OR UPDATE ON transactions_lend
    FOR EACH ROW EXECUTE FUNCTION enforce_currency_match();

CREATE TRIGGER trg_currency_match_transfer
    BEFORE INSERT OR UPDATE ON transactions_transfer
    FOR EACH ROW EXECUTE FUNCTION enforce_currency_match();

-- =========================================
-- 15. RECURRING TRANSACTIONS
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
-- 16. RECURRING TRANSACTION PROCESSING
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
    v_current_user UUID;
BEGIN
    v_current_user := auth.uid();

    FOR rec IN
        SELECT r.* FROM transactions_recurring r
        WHERE r.deleted_at IS NULL
          AND r.user_id = v_current_user
          AND r.next_occurrence <= CURRENT_DATE
          AND (r.end_date IS NULL OR r.next_occurrence <= r.end_date)
    LOOP
        -- Get the template transaction
        SELECT * INTO template_tx 
        FROM transactions 
        WHERE id = rec.transaction_template_id 
          AND user_id = v_current_user
          AND deleted_at IS NULL;

        IF NOT FOUND THEN
            RAISE WARNING 'Template transaction % not found, deleted, or access denied for recurring transaction %', 
                rec.transaction_template_id, rec.id;
            CONTINUE;
        END IF;
        
        -- Create a new transaction based on template
        INSERT INTO transactions (user_id, type, amount, currency, notes)
        VALUES (
            template_tx.user_id,
            template_tx.type,
            template_tx.amount,
            template_tx.currency,
            COALESCE(template_tx.notes, '') || ' [Auto-recurring ' || rec.id::text || ']'
        ) RETURNING id INTO new_tx_id;
        
        -- Copy transaction details based on type
        CASE template_tx.type
            WHEN 'income' THEN
                INSERT INTO transactions_income (transaction_id, account_id, source_id, notes)
                SELECT new_tx_id, account_id, source_id, 'Auto-generated from recurring'
                FROM transactions_income 
                WHERE transaction_id = rec.transaction_template_id AND deleted_at IS NULL;
                
            WHEN 'expense' THEN
                INSERT INTO transactions_expense (transaction_id, account_id, category_id, payment_method)
                SELECT new_tx_id, account_id, category_id, payment_method
                FROM transactions_expense 
                WHERE transaction_id = rec.transaction_template_id AND deleted_at IS NULL;
                
            WHEN 'investment' THEN
                INSERT INTO transactions_investment (transaction_id, account_id, asset_type, asset_symbol, platform, risk_level)
                SELECT new_tx_id, account_id, asset_type, asset_symbol, platform, risk_level
                FROM transactions_investment 
                WHERE transaction_id = rec.transaction_template_id AND deleted_at IS NULL;
                
            WHEN 'adjustment' THEN
                INSERT INTO transactions_adjustment (transaction_id, account_id, reason)
                SELECT new_tx_id, account_id, 'Auto-generated recurring adjustment'
                FROM transactions_adjustment 
                WHERE transaction_id = rec.transaction_template_id AND deleted_at IS NULL;
        END CASE;

        -- Advance next_occurrence based on frequency
        UPDATE transactions_recurring
        SET 
            next_occurrence = CASE rec.frequency
                WHEN 'daily'   THEN rec.next_occurrence + (rec.interval || ' days')::interval
                WHEN 'weekly'  THEN rec.next_occurrence + (rec.interval || ' weeks')::interval
                WHEN 'monthly' THEN rec.next_occurrence + (rec.interval || ' months')::interval
                WHEN 'yearly'  THEN rec.next_occurrence + (rec.interval || ' years')::interval
            END,
            updated_at = NOW()
        WHERE id = rec.id;
        
        processed_count := processed_count + 1;
        new_tx_ids := array_append(new_tx_ids, new_tx_id);
        
        RAISE NOTICE 'Created recurring transaction % from template % (recurring ID: %)', 
            new_tx_id, rec.transaction_template_id, rec.id;
    END LOOP;
    
    RETURN QUERY SELECT processed_count, new_tx_ids;
END;
$$;
    
-- =========================================
-- 17. CREDIT LIMIT AND BALANCE VALIDATIONS
-- =========================================
CREATE OR REPLACE FUNCTION validate_credit_limit() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Warn if current balance exceeds credit limit
    IF NEW.credit_limit IS NOT NULL AND NEW.current_balance > NEW.credit_limit THEN
        RAISE WARNING 'Credit card balance (%) exceeds credit limit (%) for account %', 
            NEW.current_balance, NEW.credit_limit, NEW.account_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_credit_limit
    BEFORE INSERT OR UPDATE ON credit_card_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_credit_limit();

-- Account balance validation with warnings for negative balances
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
                RAISE WARNING 'Cash account % has negative balance: %', NEW.account_id, NEW.balance;
            END IF;
        WHEN 'bank_accounts' THEN
            IF NEW.balance < 0 THEN
                RAISE WARNING 'Bank account % has negative balance: %', NEW.account_id, NEW.balance;
            END IF;
        WHEN 'wallet_accounts' THEN
            IF NEW.balance < 0 THEN
                RAISE WARNING 'Wallet account % has negative balance: %', NEW.account_id, NEW.balance;
            END IF;
        WHEN 'crypto_accounts' THEN
            IF NEW.balance < 0 THEN
                RAISE WARNING 'Crypto account % has negative balance: %', NEW.account_id, NEW.balance;
            END IF;
    END CASE;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_cash_balance
    BEFORE UPDATE ON cash_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

CREATE TRIGGER trg_validate_bank_balance
    BEFORE UPDATE ON bank_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

CREATE TRIGGER trg_validate_wallet_balance
    BEFORE UPDATE ON wallet_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

CREATE TRIGGER trg_validate_crypto_balance
    BEFORE UPDATE ON crypto_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_balance();

-- =========================================
-- 18. SUBCATEGORY VALIDATION
-- =========================================
CREATE OR REPLACE FUNCTION validate_subcategory_ownership() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
    category_user_id UUID;
    transaction_user_id UUID;
BEGIN
    -- Get the user_id from the parent category
    SELECT ec.user_id INTO category_user_id 
    FROM public.expense_categories ec 
    WHERE ec.id = NEW.category_id 
      AND ec.user_id = auth.uid()
      AND ec.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Parent expense category does not exist, is deleted, or access denied';
    END IF;

    -- For expense transactions, validate that the category belongs to the transaction user
    IF TG_TABLE_NAME = 'transactions_expense' THEN
        SELECT t.user_id INTO transaction_user_id
        FROM public.transactions t
        WHERE t.id = NEW.transaction_id
          AND t.user_id = auth.uid()
          AND t.deleted_at IS NULL;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Transaction not found or access denied';
        END IF;

        IF category_user_id <> transaction_user_id THEN
            RAISE EXCEPTION 'Expense category must belong to the same user as the transaction';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_subcategory
    BEFORE INSERT OR UPDATE ON expense_subcategories
    FOR EACH ROW EXECUTE FUNCTION validate_subcategory_ownership();

CREATE TRIGGER trg_validate_expense_category
    BEFORE INSERT OR UPDATE ON transactions_expense
    FOR EACH ROW EXECUTE FUNCTION validate_subcategory_ownership();

-- =========================================
-- 19. ADMIN PRIVILEGES LOGGING
-- =========================================
CREATE OR REPLACE FUNCTION log_admin_changes() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- Log when admin privileges are granted or revoked
    IF OLD.is_admin IS DISTINCT FROM NEW.is_admin THEN
        INSERT INTO public.audit_logs(user_id, action_by, table_name, record_id, action, old_data, new_data)
        VALUES (
            NEW.user_id,
            COALESCE(auth.uid(), NEW.user_id),
            'profiles',
            NEW.id,
            'ADMIN_PRIVILEGE_CHANGE',
            jsonb_build_object('is_admin', OLD.is_admin),
            jsonb_build_object('is_admin', NEW.is_admin)
        );

        RAISE NOTICE 'Admin privilege changed for user % from % to %', 
            NEW.user_id, OLD.is_admin, NEW.is_admin;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_log_admin_changes
    AFTER UPDATE ON profiles
    FOR EACH ROW EXECUTE FUNCTION log_admin_changes();

-- =========================================
-- 20. TRANSACTIONS GENERATED COLUMNS TRIGGERS
-- =========================================

-- 1. Set created_month
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

-- 2. Set type_amount_jsonb
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

-- 3. Set is_recent
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

-- Combined triggers
CREATE TRIGGER trg_transactions_set_created_month
BEFORE INSERT OR UPDATE ON transactions
FOR EACH ROW
EXECUTE FUNCTION public.set_created_month();

CREATE TRIGGER trg_transactions_set_jsonb
BEFORE INSERT OR UPDATE ON transactions
FOR EACH ROW
EXECUTE FUNCTION public.set_type_amount_jsonb();

CREATE TRIGGER trg_transactions_set_is_recent
BEFORE INSERT OR UPDATE ON transactions
FOR EACH ROW
EXECUTE FUNCTION public.set_is_recent();


-- =========================================
-- 21. VALIDATE ACCOUNT MODIFICATIONS
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
            t.id IN (SELECT transaction_id FROM transactions_investment WHERE account_id = OLD.id AND deleted_at IS NULL) OR
            t.id IN (SELECT transaction_id FROM transactions_borrow WHERE account_id = OLD.id AND deleted_at IS NULL) OR
            t.id IN (SELECT transaction_id FROM transactions_lend WHERE account_id = OLD.id AND deleted_at IS NULL) OR
            t.id IN (SELECT transaction_id FROM transactions_transfer WHERE (from_account = OLD.id OR to_account = OLD.id) AND deleted_at IS NULL) OR
            t.id IN (SELECT transaction_id FROM transactions_adjustment WHERE account_id = OLD.id AND deleted_at IS NULL)
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
DROP TRIGGER IF EXISTS trg_validate_account_update ON accounts;
CREATE TRIGGER trg_validate_account_update
    BEFORE UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_modification();

DROP TRIGGER IF EXISTS trg_validate_account_delete ON accounts;
CREATE TRIGGER trg_validate_account_delete
    BEFORE DELETE ON accounts
    FOR EACH ROW EXECUTE FUNCTION validate_account_modification();

-- =========================================
-- 22. CREATE PROFILE ON NEW USER SIGN UP
-- =========================================
-- Insert profile if it doesn't exist
-- CREATE OR REPLACE FUNCTION public.insert_profile_if_not_exists()
-- RETURNS TRIGGER
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = public, pg_temp
-- AS $$
-- BEGIN
--     -- Insert a new profile only if no profile exists for this user_id
--     INSERT INTO public.profiles (user_id)
--     VALUES (NEW.id)
--     ON CONFLICT (user_id) DO NOTHING;

--     RETURN NEW;
-- END;
-- $$;

-- -- 2. Trigger on auth.users
-- CREATE TRIGGER trigger_insert_profile
-- AFTER INSERT ON auth.users
-- FOR EACH ROW
-- EXECUTE FUNCTION public.insert_profile_if_not_exists();

-- =========================================
-- GRANT PERMISSIONS FOR RLS FUNCTIONS
-- =========================================

-- Grant execute permissions to authenticated users for all functions
GRANT EXECUTE ON FUNCTION log_audit() TO authenticated;
GRANT EXECUTE ON FUNCTION set_updated_at() TO authenticated;
GRANT EXECUTE ON FUNCTION insert_profile_defaults() TO authenticated;
GRANT EXECUTE ON FUNCTION insert_specialized_account() TO authenticated;
GRANT EXECUTE ON FUNCTION apply_transaction_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION apply_transfer_balances() TO authenticated;
GRANT EXECUTE ON FUNCTION enforce_soft_delete() TO authenticated;
GRANT EXECUTE ON FUNCTION cleanup_specialized_account() TO authenticated;
GRANT EXECUTE ON FUNCTION cleanup_transaction_details() TO authenticated;
GRANT EXECUTE ON FUNCTION reverse_balance_on_soft_delete() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_transaction_user() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_transfer_accounts() TO authenticated;
GRANT EXECUTE ON FUNCTION enforce_counterparty_unique() TO authenticated;
GRANT EXECUTE ON FUNCTION update_receivable_status() TO authenticated;
GRANT EXECUTE ON FUNCTION update_loan_status() TO authenticated;
GRANT EXECUTE ON FUNCTION enforce_currency_match() TO authenticated;
GRANT EXECUTE ON FUNCTION setup_recurring_transaction() TO authenticated;
GRANT EXECUTE ON FUNCTION process_recurring_transactions() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_credit_limit() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_account_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_subcategory_ownership() TO authenticated;
GRANT EXECUTE ON FUNCTION log_admin_changes() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_account_modification() TO authenticated;

-- =========================================
-- COMMENTS AND DOCUMENTATION
-- =========================================

COMMENT ON FUNCTION log_audit() IS 'RLS-compliant audit logging with dual user tracking';
COMMENT ON FUNCTION apply_transaction_balance() IS 'RLS-compliant balance updates for transaction operations';
COMMENT ON FUNCTION apply_transfer_balances() IS 'RLS-compliant balance updates for transfer operations';
COMMENT ON FUNCTION process_recurring_transactions() IS 'RLS-compliant recurring transaction processing';

-- ======================================================
-- END OF TRIGGERS AND FUNCTIONS
-- ======================================================