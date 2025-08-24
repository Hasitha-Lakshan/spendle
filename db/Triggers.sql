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
-- 1. ENHANCED AUDIT LOGGING WITH DUAL USER TRACKING
-- =========================================
CREATE OR REPLACE FUNCTION log_audit() RETURNS TRIGGER AS $$
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
        INSERT INTO audit_logs(user_id, action_by, table_name, record_id, action, new_data)
        VALUES (affected_user_id, actor_user_id, TG_TABLE_NAME, NEW.id, 'INSERT', row_to_json(NEW));
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_logs(user_id, action_by, table_name, record_id, action, old_data, new_data)
        VALUES (affected_user_id, actor_user_id, TG_TABLE_NAME, NEW.id, 'UPDATE', row_to_json(OLD), row_to_json(NEW));
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO audit_logs(user_id, action_by, table_name, record_id, action, old_data)
        VALUES (affected_user_id, actor_user_id, TG_TABLE_NAME, OLD.id, 'DELETE', row_to_json(OLD));
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

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
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

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
CREATE OR REPLACE FUNCTION insert_profile_defaults() RETURNS TRIGGER AS $$
BEGIN
    -- Only insert defaults if not already inserted
    IF NOT NEW.defaults_inserted THEN
        -- Create default cash account
        INSERT INTO accounts(user_id, account_name, type, currency)
        VALUES (NEW.user_id, 'Cash Wallet', 'cash', 'USD');

        -- Create default expense category
        INSERT INTO expense_categories(user_id, name) VALUES (NEW.user_id, 'General');
        
        -- Create default income source
        INSERT INTO income_sources(user_id, name) VALUES (NEW.user_id, 'Salary');

        -- Mark defaults as inserted
        UPDATE profiles SET defaults_inserted = TRUE WHERE id = NEW.id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_profiles_defaults
    AFTER INSERT ON profiles
    FOR EACH ROW EXECUTE FUNCTION insert_profile_defaults();

-- =========================================
-- 4. SPECIALIZED ACCOUNT SYNC WITH PROPER FIELD INITIALIZATION
-- =========================================
CREATE OR REPLACE FUNCTION insert_specialized_account() 
RETURNS TRIGGER AS $$
BEGIN
    CASE NEW.type
        WHEN 'cash' THEN
            INSERT INTO cash_accounts(account_id, balance, status, location, notes) 
            VALUES (NEW.id, 0, 'active', 'Wallet', 'Default cash account');
        WHEN 'bank' THEN
            INSERT INTO bank_accounts(account_id, bank_name, account_no, balance, status, branch, account_holder_name, interest_rate, notes) 
            VALUES (NEW.id, 'UNKNOWN', '0000', 0, 'active', NULL, NULL, NULL, 'Default bank account');
        WHEN 'credit_card' THEN
            INSERT INTO credit_card_accounts(account_id, card_number, current_balance, status, card_type, credit_limit, billing_cycle, interest_rate, notes) 
            VALUES (NEW.id, '0000', 0, 'active', NULL, NULL, NULL, NULL, 'Default credit card');
        WHEN 'loan' THEN
            INSERT INTO loan_accounts(account_id, outstanding_amount, status, loan_type, principal_amount, interest_rate, term_months, start_date, end_date, notes) 
            VALUES (NEW.id, 0, 'active', NULL, NULL, NULL, NULL, NULL, NULL, 'Default loan account');
        WHEN 'investment' THEN
            INSERT INTO investment_accounts(account_id, portfolio_value, status, investment_type, institution_name, account_no, notes) 
            VALUES (NEW.id, 0, 'active', NULL, NULL, NULL, 'Default investment account');
        WHEN 'crypto' THEN
            INSERT INTO crypto_accounts(account_id, crypto_wallet_address, balance, status, exchange_name, notes) 
            VALUES (NEW.id, 'pending', 0, 'active', NULL, 'Default crypto account');
        WHEN 'wallet' THEN
            INSERT INTO wallet_accounts(account_id, wallet_name, balance, status, provider, notes) 
            VALUES (NEW.id, 'Default', 0, 'active', NULL, 'Default wallet account');
        WHEN 'receivable' THEN
            INSERT INTO receivable_accounts(account_id, amount_due, status, customer_name, invoice_no, principal_amount, due_date, notes) 
            VALUES (NEW.id, 0, 'pending', NULL, NULL, NULL, NULL, 'Default receivable account');
        ELSE
            RAISE EXCEPTION 'Unknown account type: %', NEW.type;
    END CASE;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_insert_specialized_account
    AFTER INSERT ON accounts
    FOR EACH ROW EXECUTE FUNCTION insert_specialized_account();

-- =========================================
-- 5. COMPREHENSIVE ACCOUNT BALANCE UPDATES FOR ALL SPECIFIC FIELDS
-- =========================================
CREATE OR REPLACE FUNCTION apply_transaction_balance() RETURNS TRIGGER AS $$
DECLARE
    v_amount NUMERIC;
    v_account_type account_type;
    v_account_id UUID;
BEGIN
    -- Get transaction amount
    SELECT amount INTO v_amount FROM transactions WHERE id = NEW.transaction_id;
    
    -- Determine account ID based on transaction type
    IF TG_TABLE_NAME = 'transactions_transfer' THEN
        -- Handle transfer separately as it has two accounts
        RETURN NEW;
    ELSE
        v_account_id := NEW.account_id;
    END IF;
    
    -- Get account type
    SELECT type INTO v_account_type FROM accounts WHERE id = v_account_id;
    
    -- Update main accounts table timestamp
    UPDATE accounts SET updated_at = NOW() WHERE id = v_account_id;
    
    -- Handle different transaction types with specific field updates
    IF TG_TABLE_NAME = 'transactions_income' THEN
        -- Income increases account balances
        CASE v_account_type
            WHEN 'cash' THEN
                UPDATE cash_accounts 
                SET balance = balance + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'bank' THEN
                UPDATE bank_accounts 
                SET balance = balance + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'wallet' THEN
                UPDATE wallet_accounts 
                SET balance = balance + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'crypto' THEN
                UPDATE crypto_accounts 
                SET balance = balance + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'investment' THEN
                UPDATE investment_accounts 
                SET portfolio_value = portfolio_value + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'receivable' THEN
                UPDATE receivable_accounts 
                SET amount_due = amount_due + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            -- Income typically doesn't go to credit cards or loans directly
        END CASE;

    ELSIF TG_TABLE_NAME = 'transactions_expense' THEN
        -- Expenses decrease account balances or increase liabilities
        CASE v_account_type
            WHEN 'cash' THEN
                UPDATE cash_accounts 
                SET balance = balance - v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'bank' THEN
                UPDATE bank_accounts 
                SET balance = balance - v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'wallet' THEN
                UPDATE wallet_accounts 
                SET balance = balance - v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'crypto' THEN
                UPDATE crypto_accounts 
                SET balance = balance - v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'credit_card' THEN
                UPDATE credit_card_accounts 
                SET current_balance = current_balance + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'investment' THEN
                UPDATE investment_accounts 
                SET portfolio_value = portfolio_value - v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;

    ELSIF TG_TABLE_NAME = 'transactions_investment' THEN
        -- Investment transactions affect portfolio value
        CASE v_account_type
            WHEN 'investment' THEN
                UPDATE investment_accounts 
                SET portfolio_value = portfolio_value + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'cash' THEN
                -- Investment from cash reduces cash balance
                UPDATE cash_accounts 
                SET balance = balance - v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'bank' THEN
                -- Investment from bank reduces bank balance
                UPDATE bank_accounts 
                SET balance = balance - v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;

    ELSIF TG_TABLE_NAME = 'transactions_adjustment' THEN
        -- Adjustments can be positive or negative
        CASE v_account_type
            WHEN 'cash' THEN
                UPDATE cash_accounts 
                SET balance = balance + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'bank' THEN
                UPDATE bank_accounts 
                SET balance = balance + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'wallet' THEN
                UPDATE wallet_accounts 
                SET balance = balance + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'crypto' THEN
                UPDATE crypto_accounts 
                SET balance = balance + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'credit_card' THEN
                UPDATE credit_card_accounts 
                SET current_balance = current_balance - v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'investment' THEN
                UPDATE investment_accounts 
                SET portfolio_value = portfolio_value + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'loan' THEN
                UPDATE loan_accounts 
                SET outstanding_amount = outstanding_amount - v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
            WHEN 'receivable' THEN
                UPDATE receivable_accounts 
                SET amount_due = amount_due + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;

    ELSIF TG_TABLE_NAME = 'transactions_borrow' THEN
        -- Borrowing increases outstanding amount
        CASE v_account_type
            WHEN 'loan' THEN
                UPDATE loan_accounts 
                SET outstanding_amount = outstanding_amount + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;

    ELSIF TG_TABLE_NAME = 'transactions_lend' THEN
        -- Lending increases amount due
        CASE v_account_type
            WHEN 'receivable' THEN
                UPDATE receivable_accounts 
                SET amount_due = amount_due + v_amount, 
                    updated_at = NOW() 
                WHERE account_id = v_account_id;
        END CASE;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

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
-- 6. ENHANCED TRANSFER BALANCE HANDLING WITH SPECIFIC FIELD UPDATES
-- =========================================
CREATE OR REPLACE FUNCTION apply_transfer_balances()
RETURNS TRIGGER AS $$
DECLARE
    from_acc_type account_type;
    to_acc_type account_type;
    v_amount NUMERIC;
BEGIN
    -- Get transaction amount and account types with NULL safety
    SELECT COALESCE(amount, 0) INTO v_amount 
    FROM transactions 
    WHERE id = NEW.transaction_id;
    IF v_amount IS NULL THEN
        RAISE EXCEPTION 'Transaction amount is NULL for id: %', NEW.transaction_id;
    END IF;

    SELECT type INTO from_acc_type 
    FROM accounts 
    WHERE id = NEW.from_account;
    IF from_acc_type IS NULL THEN
        RAISE EXCEPTION 'Account type is NULL for from_account: %', NEW.from_account;
    END IF;

    SELECT type INTO to_acc_type 
    FROM accounts 
    WHERE id = NEW.to_account;
    IF to_acc_type IS NULL THEN
        RAISE EXCEPTION 'Account type is NULL for to_account: %', NEW.to_account;
    END IF;

    -- Update timestamps for both accounts
    UPDATE accounts SET updated_at = NOW() WHERE id IN (NEW.from_account, NEW.to_account);

    -- =========================================
    -- Decrease balance from from_account (outflow) - Update specific fields
    -- =========================================
    CASE from_acc_type
        WHEN 'cash' THEN
            UPDATE cash_accounts 
            SET balance = balance - NEW.fees - v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'bank' THEN
            UPDATE bank_accounts 
            SET balance = balance - NEW.fees - v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'wallet' THEN
            UPDATE wallet_accounts 
            SET balance = balance - NEW.fees - v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'crypto' THEN
            UPDATE crypto_accounts 
            SET balance = balance - NEW.fees - v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'credit_card' THEN
            UPDATE credit_card_accounts 
            SET current_balance = current_balance + v_amount + NEW.fees, 
                updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'loan' THEN
            -- Transfer from loan reduces outstanding amount (payment)
            UPDATE loan_accounts 
            SET outstanding_amount = outstanding_amount - v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'investment' THEN
            UPDATE investment_accounts 
            SET portfolio_value = portfolio_value - v_amount - NEW.fees, 
                updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        WHEN 'receivable' THEN
            UPDATE receivable_accounts 
            SET amount_due = amount_due - v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.from_account;
        ELSE
            RAISE EXCEPTION 'Unknown account type for from_account: %', from_acc_type;
    END CASE;

    -- Optional: track fees separately in audit_logs if needed
    -- INSERT INTO audit_logs(user_id, action, reference_table, reference_id, details, created_at)
    -- VALUES (NEW.action_by, 'transfer_fee', 'transactions_transfer', NEW.id, NEW.fees::TEXT, NOW());

    -- =========================================
    -- Increase balance to to_account (inflow) - Update specific fields
    -- =========================================
    CASE to_acc_type
        WHEN 'cash' THEN
            UPDATE cash_accounts 
            SET balance = balance + v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'bank' THEN
            UPDATE bank_accounts 
            SET balance = balance + v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'wallet' THEN
            UPDATE wallet_accounts 
            SET balance = balance + v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'crypto' THEN
            UPDATE crypto_accounts 
            SET balance = balance + v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'credit_card' THEN
            -- Transfer to credit card reduces outstanding balance (payment)
            UPDATE credit_card_accounts 
            SET current_balance = current_balance - v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'loan' THEN
            -- Transfer to loan increases outstanding amount (new borrowing)
            UPDATE loan_accounts 
            SET outstanding_amount = outstanding_amount + v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'investment' THEN
            UPDATE investment_accounts 
            SET portfolio_value = portfolio_value + v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        WHEN 'receivable' THEN
            UPDATE receivable_accounts 
            SET amount_due = amount_due + v_amount, 
                updated_at = NOW() 
            WHERE account_id = NEW.to_account;
        ELSE
            RAISE EXCEPTION 'Unknown account type for to_account: %', to_acc_type;
    END CASE;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_apply_transfer_balances
    AFTER INSERT ON transactions_transfer
    FOR EACH ROW EXECUTE FUNCTION apply_transfer_balances();

-- =========================================
-- 7. COMPREHENSIVE SOFT DELETE ENFORCEMENT
-- =========================================
CREATE OR REPLACE FUNCTION enforce_soft_delete() RETURNS TRIGGER AS $$
BEGIN
    -- Update the deleted_at timestamp instead of hard delete
    EXECUTE format('UPDATE %I SET deleted_at = NOW(), updated_at = NOW() WHERE id = $1', TG_TABLE_NAME) USING OLD.id;
    RETURN NULL; -- Prevent actual delete
END;
$$ LANGUAGE plpgsql;

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
CREATE OR REPLACE FUNCTION cleanup_specialized_account() RETURNS TRIGGER AS $$
BEGIN
    -- When an account is soft deleted, also soft delete the specialized account
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        CASE OLD.type
            WHEN 'cash' THEN
                UPDATE cash_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'bank' THEN
                UPDATE bank_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'credit_card' THEN
                UPDATE credit_card_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'loan' THEN
                UPDATE loan_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'investment' THEN
                UPDATE investment_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'crypto' THEN
                UPDATE crypto_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'wallet' THEN
                UPDATE wallet_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
            WHEN 'receivable' THEN
                UPDATE receivable_accounts 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE account_id = OLD.id AND deleted_at IS NULL;
        END CASE;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cleanup_specialized_account
    AFTER UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION cleanup_specialized_account();

-- =========================================
-- 9. TRANSACTION DETAIL CLEANUP ON TRANSACTION SOFT DELETE
-- =========================================
CREATE OR REPLACE FUNCTION cleanup_transaction_details() RETURNS TRIGGER AS $$
BEGIN
    -- When a transaction is soft deleted, also soft delete its details
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        CASE OLD.type
            WHEN 'income' THEN
                UPDATE transactions_income 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE transaction_id = OLD.id AND deleted_at IS NULL;
            WHEN 'expense' THEN
                UPDATE transactions_expense 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE transaction_id = OLD.id AND deleted_at IS NULL;
            WHEN 'investment' THEN
                UPDATE transactions_investment 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE transaction_id = OLD.id AND deleted_at IS NULL;
            WHEN 'borrow' THEN
                UPDATE transactions_borrow 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE transaction_id = OLD.id AND deleted_at IS NULL;
            WHEN 'lend' THEN
                UPDATE transactions_lend 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE transaction_id = OLD.id AND deleted_at IS NULL;
            WHEN 'transfer' THEN
                UPDATE transactions_transfer 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE transaction_id = OLD.id AND deleted_at IS NULL;
            WHEN 'adjustment' THEN
                UPDATE transactions_adjustment 
                SET deleted_at = NEW.deleted_at, updated_at = NOW() 
                WHERE transaction_id = OLD.id AND deleted_at IS NULL;
        END CASE;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cleanup_transaction_details
    AFTER UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION cleanup_transaction_details();

-- =========================================
-- 10. BALANCE REVERSAL ON SOFT DELETE WITH SPECIFIC FIELD UPDATES
-- =========================================
CREATE OR REPLACE FUNCTION reverse_balance_on_soft_delete() RETURNS TRIGGER AS $$
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
                -- Get income transaction details
                SELECT * INTO tx_details FROM transactions_income WHERE transaction_id = NEW.id;
                IF FOUND THEN
                    SELECT type INTO acc_type FROM accounts WHERE id = tx_details.account_id;
                    UPDATE accounts SET updated_at = NOW() WHERE id = tx_details.account_id;
                    
                    CASE acc_type
                        WHEN 'cash' THEN 
                            UPDATE cash_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'bank' THEN 
                            UPDATE bank_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'wallet' THEN 
                            UPDATE wallet_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'crypto' THEN 
                            UPDATE crypto_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'investment' THEN 
                            UPDATE investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'receivable' THEN 
                            UPDATE receivable_accounts 
                            SET amount_due = COALESCE(amount_due,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                    END CASE;
                END IF;
                
            WHEN 'expense' THEN
                -- Get expense transaction details
                SELECT * INTO tx_details FROM transactions_expense WHERE transaction_id = NEW.id;
                IF FOUND THEN
                    SELECT type INTO acc_type FROM accounts WHERE id = tx_details.account_id;
                    UPDATE accounts SET updated_at = NOW() WHERE id = tx_details.account_id;
                    
                    CASE acc_type
                        WHEN 'cash' THEN 
                            UPDATE cash_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'bank' THEN 
                            UPDATE bank_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'wallet' THEN 
                            UPDATE wallet_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'crypto' THEN 
                            UPDATE crypto_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'credit_card' THEN 
                            UPDATE credit_card_accounts 
                            SET current_balance = COALESCE(current_balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'investment' THEN 
                            UPDATE investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                    END CASE;
                END IF;
                
            WHEN 'investment' THEN
                -- Get investment transaction details
                SELECT * INTO tx_details FROM transactions_investment WHERE transaction_id = NEW.id;
                IF FOUND THEN
                    SELECT type INTO acc_type FROM accounts WHERE id = tx_details.account_id;
                    UPDATE accounts SET updated_at = NOW() WHERE id = tx_details.account_id;
                    
                    CASE acc_type
                        WHEN 'investment' THEN 
                            UPDATE investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'cash' THEN 
                            UPDATE cash_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'bank' THEN 
                            UPDATE bank_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                    END CASE;
                END IF;
                
            WHEN 'adjustment' THEN
                -- Get adjustment transaction details
                SELECT * INTO tx_details FROM transactions_adjustment WHERE transaction_id = NEW.id;
                IF FOUND THEN
                    SELECT type INTO acc_type FROM accounts WHERE id = tx_details.account_id;
                    UPDATE accounts SET updated_at = NOW() WHERE id = tx_details.account_id;
                    
                    CASE acc_type
                        WHEN 'cash' THEN 
                            UPDATE cash_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'bank' THEN 
                            UPDATE bank_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'wallet' THEN 
                            UPDATE wallet_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'crypto' THEN 
                            UPDATE crypto_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'credit_card' THEN 
                            UPDATE credit_card_accounts 
                            SET current_balance = COALESCE(current_balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'investment' THEN 
                            UPDATE investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'loan' THEN 
                            UPDATE loan_accounts 
                            SET outstanding_amount = COALESCE(outstanding_amount,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                        WHEN 'receivable' THEN 
                            UPDATE receivable_accounts 
                            SET amount_due = COALESCE(amount_due,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = tx_details.account_id;
                    END CASE;
                END IF;
                
            WHEN 'borrow' THEN
                -- Get borrow transaction details
                SELECT * INTO tx_details FROM transactions_borrow WHERE transaction_id = NEW.id;
                IF FOUND THEN
                    UPDATE loan_accounts 
                    SET outstanding_amount = COALESCE(outstanding_amount,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                    WHERE account_id = tx_details.account_id;
                    UPDATE accounts SET updated_at = NOW() WHERE id = tx_details.account_id;
                END IF;
                
            WHEN 'lend' THEN
                -- Get lend transaction details
                SELECT * INTO tx_details FROM transactions_lend WHERE transaction_id = NEW.id;
                IF FOUND THEN
                    UPDATE receivable_accounts 
                    SET amount_due = COALESCE(amount_due,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                    WHERE account_id = tx_details.account_id;
                    UPDATE accounts SET updated_at = NOW() WHERE id = tx_details.account_id;
                END IF;
                
            WHEN 'transfer' THEN
                -- Get transfer transaction details
                SELECT * INTO transfer_details FROM transactions_transfer WHERE transaction_id = NEW.id;
                IF FOUND THEN
                    SELECT type INTO from_acc_type FROM accounts WHERE id = transfer_details.from_account;
                    SELECT type INTO to_acc_type FROM accounts WHERE id = transfer_details.to_account;
                    
                    UPDATE accounts SET updated_at = NOW() 
                    WHERE id IN (transfer_details.from_account, transfer_details.to_account);
                    
                    -- Reverse from_account changes (add back what was subtracted)
                    CASE from_acc_type
                        WHEN 'cash' THEN
                            UPDATE cash_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(transfer_details.fees,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'bank' THEN
                            UPDATE bank_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(transfer_details.fees,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'wallet' THEN
                            UPDATE wallet_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(transfer_details.fees,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'crypto' THEN
                            UPDATE crypto_accounts 
                            SET balance = COALESCE(balance,0) + COALESCE(transfer_details.fees,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'credit_card' THEN
                            UPDATE credit_card_accounts 
                            SET current_balance = COALESCE(current_balance,0) - COALESCE(NEW.amount,0) - COALESCE(transfer_details.fees,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'loan' THEN
                            UPDATE loan_accounts 
                            SET outstanding_amount = COALESCE(outstanding_amount,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'investment' THEN
                            UPDATE investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) + COALESCE(NEW.amount,0) + COALESCE(transfer_details.fees,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                        WHEN 'receivable' THEN
                            UPDATE receivable_accounts 
                            SET amount_due = COALESCE(amount_due,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.from_account;
                    END CASE;
                    
                    -- Reverse to_account changes (subtract what was added)
                    CASE to_acc_type
                        WHEN 'cash' THEN
                            UPDATE cash_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'bank' THEN
                            UPDATE bank_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'wallet' THEN
                            UPDATE wallet_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'crypto' THEN
                            UPDATE crypto_accounts 
                            SET balance = COALESCE(balance,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'credit_card' THEN
                            UPDATE credit_card_accounts 
                            SET current_balance = COALESCE(current_balance,0) + COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'loan' THEN
                            UPDATE loan_accounts 
                            SET outstanding_amount = COALESCE(outstanding_amount,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'investment' THEN
                            UPDATE investment_accounts 
                            SET portfolio_value = COALESCE(portfolio_value,0) - COALESCE(NEW.amount,0), updated_at = NOW() 
                            WHERE account_id = transfer_details.to_account;
                        WHEN 'receivable' THEN
                            UPDATE receivable_accounts 
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reverse_balance_soft_delete
    AFTER UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION reverse_balance_on_soft_delete();

-- =========================================
-- 11. COMPREHENSIVE VALIDATION CHECKS
-- =========================================
CREATE OR REPLACE FUNCTION validate_transaction_user() RETURNS TRIGGER AS $$
DECLARE 
    v_account_user UUID;
    v_tx_user UUID;
BEGIN
    -- Get account user and transaction user
    SELECT user_id INTO v_account_user FROM accounts WHERE id = NEW.account_id;
    SELECT user_id INTO v_tx_user FROM transactions WHERE id = NEW.transaction_id;
    
    IF v_account_user IS NULL OR v_tx_user IS NULL THEN
        RAISE EXCEPTION 'Account or transaction not found';
    END IF;

    IF v_account_user <> v_tx_user THEN
        RAISE EXCEPTION 'Transaction user_id (%) does not match account user_id (%)', v_tx_user, v_account_user;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

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
CREATE OR REPLACE FUNCTION validate_transfer_accounts() RETURNS TRIGGER AS $$
DECLARE 
    from_user UUID;
    to_user UUID;
    tx_user UUID;
BEGIN
    SELECT user_id INTO from_user FROM accounts WHERE id = NEW.from_account;
    SELECT user_id INTO to_user FROM accounts WHERE id = NEW.to_account;
    SELECT user_id INTO tx_user FROM transactions WHERE id = NEW.transaction_id;
    
    IF from_user IS NULL OR to_user IS NULL OR tx_user IS NULL THEN
        RAISE EXCEPTION 'Accounts or transaction not found';
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_tx_transfer_validate
    BEFORE INSERT ON transactions_transfer
    FOR EACH ROW EXECUTE FUNCTION validate_transfer_accounts();

-- =========================================
-- 12. COUNTERPARTY UNIQUENESS RULES
-- =========================================
CREATE OR REPLACE FUNCTION enforce_counterparty_unique() RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM counterparties
        WHERE user_id = NEW.user_id 
          AND name = NEW.name 
          AND type = NEW.type 
          AND deleted_at IS NULL
          AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
    ) THEN
        RAISE EXCEPTION 'Counterparty with name "%" and type "%" already exists for this user', NEW.name, NEW.type;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_counterparty_unique
    BEFORE INSERT OR UPDATE ON counterparties
    FOR EACH ROW EXECUTE FUNCTION enforce_counterparty_unique();

-- =========================================
-- 13. AUTO STATUS UPDATES WITH SPECIFIC FIELD LOGIC
-- =========================================
CREATE OR REPLACE FUNCTION update_receivable_status() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.amount_due <= 0 THEN
        NEW.status = 'paid';
    ELSIF NEW.due_date IS NOT NULL AND NEW.due_date < CURRENT_DATE THEN
        NEW.status = 'overdue';
    ELSE
        NEW.status = 'pending';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_receivable_status
    BEFORE INSERT OR UPDATE ON receivable_accounts
    FOR EACH ROW EXECUTE FUNCTION update_receivable_status();

-- Loan status management
CREATE OR REPLACE FUNCTION update_loan_status() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.outstanding_amount <= 0 THEN
        NEW.status = 'closed';
    ELSIF NEW.end_date IS NOT NULL AND NEW.end_date < CURRENT_DATE AND NEW.outstanding_amount > 0 THEN
        NEW.status = 'defaulted';
    ELSE
        NEW.status = 'active';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loan_status
    BEFORE INSERT OR UPDATE ON loan_accounts
    FOR EACH ROW EXECUTE FUNCTION update_loan_status();

-- =========================================
-- 14. CURRENCY VALIDATION
-- =========================================
CREATE OR REPLACE FUNCTION enforce_currency_match() RETURNS TRIGGER AS $$
DECLARE
    v_account_currency VARCHAR(10);
    v_tx_currency VARCHAR(10);
BEGIN
    -- Get transaction currency
    SELECT currency INTO v_tx_currency FROM transactions WHERE id = NEW.transaction_id;
    
    IF v_tx_currency IS NULL THEN
        RAISE EXCEPTION 'Transaction currency not found';
    END IF;

    -- For transfer transactions, check both accounts
    IF TG_TABLE_NAME = 'transactions_transfer' THEN
        SELECT currency INTO v_account_currency FROM accounts WHERE id = NEW.from_account;
        IF v_tx_currency <> v_account_currency THEN
            RAISE EXCEPTION 'Transaction currency (%) must match from_account currency (%)', v_tx_currency, v_account_currency;
        END IF;
        
        SELECT currency INTO v_account_currency FROM accounts WHERE id = NEW.to_account;
        IF v_tx_currency <> v_account_currency THEN
            RAISE EXCEPTION 'Transaction currency (%) must match to_account currency (%)', v_tx_currency, v_account_currency;
        END IF;
    ELSE
        -- For other transaction types, check the account
        SELECT currency INTO v_account_currency FROM accounts WHERE id = NEW.account_id;
        IF v_tx_currency <> v_account_currency THEN
            RAISE EXCEPTION 'Transaction currency (%) must match account currency (%)', v_tx_currency, v_account_currency;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

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
-- 15. RECURRING TRANSACTIONS WITH AUTO action_by POPULATION
-- =========================================
CREATE OR REPLACE FUNCTION setup_recurring_transaction() RETURNS TRIGGER AS $$
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
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Template transaction does not exist, is deleted, or does not belong to user';
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_setup_recurring
    BEFORE INSERT ON transactions_recurring
    FOR EACH ROW EXECUTE FUNCTION setup_recurring_transaction();

-- =========================================
-- 16. RECURRING TRANSACTION PROCESSING ENGINE
-- =========================================
CREATE OR REPLACE FUNCTION process_recurring_transactions()
RETURNS TABLE(processed_count INTEGER, new_transaction_ids UUID[]) AS $$
DECLARE
    rec RECORD;
    new_tx_id UUID;
    template_tx RECORD;
    processed_count INTEGER := 0;
    new_tx_ids UUID[] := ARRAY[]::UUID[];
BEGIN
    FOR rec IN
        SELECT r.* FROM transactions_recurring r
        WHERE r.deleted_at IS NULL
          AND r.next_occurrence <= CURRENT_DATE
          AND (r.end_date IS NULL OR r.next_occurrence <= r.end_date)
    LOOP
        -- Get the template transaction
        SELECT * INTO template_tx FROM transactions 
        WHERE id = rec.transaction_template_id AND deleted_at IS NULL;

        IF NOT FOUND THEN
            RAISE WARNING 'Template transaction % not found or deleted for recurring transaction %', 
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
$$ LANGUAGE plpgsql;
    
-- =========================================
-- 17. CREDIT LIMIT AND BALANCE VALIDATIONS
-- =========================================
CREATE OR REPLACE FUNCTION validate_credit_limit() RETURNS TRIGGER AS $$
BEGIN
    -- Warn if current balance exceeds credit limit
    IF NEW.credit_limit IS NOT NULL AND NEW.current_balance > NEW.credit_limit THEN
        RAISE WARNING 'Credit card balance (%) exceeds credit limit (%) for account %', 
            NEW.current_balance, NEW.credit_limit, NEW.account_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_credit_limit
    BEFORE INSERT OR UPDATE ON credit_card_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_credit_limit();

-- Account balance validation with warnings for negative balances
CREATE OR REPLACE FUNCTION validate_account_balance() RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

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
CREATE OR REPLACE FUNCTION validate_subcategory_ownership() RETURNS TRIGGER AS $$
DECLARE
    category_user_id UUID;
    transaction_user_id UUID;
BEGIN
    -- Get the user_id from the parent category
    SELECT ec.user_id INTO category_user_id 
    FROM expense_categories ec 
    WHERE ec.id = NEW.category_id AND ec.deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Parent expense category does not exist or is deleted';
    END IF;

    -- For expense transactions, validate that the category belongs to the transaction user
    IF TG_TABLE_NAME = 'transactions_expense' THEN
        SELECT t.user_id INTO transaction_user_id
        FROM transactions t
        WHERE t.id = NEW.transaction_id;

        IF category_user_id <> transaction_user_id THEN
            RAISE EXCEPTION 'Expense category must belong to the same user as the transaction';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_subcategory
    BEFORE INSERT OR UPDATE ON expense_subcategories
    FOR EACH ROW EXECUTE FUNCTION validate_subcategory_ownership();

CREATE TRIGGER trg_validate_expense_category
    BEFORE INSERT OR UPDATE ON transactions_expense
    FOR EACH ROW EXECUTE FUNCTION validate_subcategory_ownership();

-- =========================================
-- 19. ADMIN PRIVILEGES LOGGING
-- =========================================
CREATE OR REPLACE FUNCTION log_admin_changes() RETURNS TRIGGER AS $$
BEGIN
    -- Log when admin privileges are granted or revoked
    IF OLD.is_admin IS DISTINCT FROM NEW.is_admin THEN
        INSERT INTO audit_logs(user_id, action_by, table_name, record_id, action, old_data, new_data)
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_log_admin_changes
    AFTER UPDATE ON profiles
    FOR EACH ROW EXECUTE FUNCTION log_admin_changes();

-- =========================================
-- 20. UTILITY FUNCTIONS FOR MAINTENANCE
-- =========================================
-- Function to recalculate account balances (for data integrity checks)
CREATE OR REPLACE FUNCTION recalculate_account_balance(p_account_id UUID)
RETURNS DECIMAL(36,18) AS $$
DECLARE
    calculated_balance DECIMAL(36,18) := 0;
    acc_type account_type;
    acc_currency TEXT;
BEGIN
    SELECT type, currency INTO acc_type, acc_currency FROM accounts WHERE id = p_account_id AND deleted_at IS NULL;

    -- Calculate balance based on transaction history for specific account types
    CASE acc_type
        WHEN 'cash', 'bank', 'wallet', 'crypto' THEN
         -- For standard balance accounts: income(+), expense(-), adjustment(+/-)
            SELECT COALESCE(SUM(
                CASE 
                    WHEN t.type = 'income' THEN t.amount
                    WHEN t.type = 'expense' THEN -t.amount
                    WHEN t.type = 'adjustment' THEN t.amount
                    ELSE 0
                END), 0) INTO calculated_balance
            FROM transactions t
            LEFT JOIN transactions_income ti ON t.id = ti.transaction_id AND ti.account_id = p_account_id
            LEFT JOIN transactions_expense te ON t.id = te.transaction_id AND te.account_id = p_account_id
            LEFT JOIN transactions_adjustment ta ON t.id = ta.transaction_id AND ta.account_id = p_account_id
            WHERE (ti.account_id = p_account_id OR te.account_id = p_account_id OR ta.account_id = p_account_id)
            AND t.deleted_at IS NULL
            AND t.currency = acc_currency;

            -- Add transfer effects
            SELECT calculated_balance + COALESCE(SUM(
                CASE 
                    WHEN tt.from_account = p_account_id THEN -(t.amount + tt.fees)
                    WHEN tt.to_account = p_account_id THEN t.amount
                    ELSE 0
                END), 0) INTO calculated_balance
            FROM transactions t
            JOIN transactions_transfer tt ON t.id = tt.transaction_id
            WHERE (tt.from_account = p_account_id OR tt.to_account = p_account_id)
            AND t.deleted_at IS NULL;

        WHEN 'credit_card' THEN
            -- For credit cards: expense(+), payment/adjustment(-) 
            SELECT COALESCE(SUM(
                CASE 
                    WHEN t.type = 'expense' THEN t.amount
                    WHEN t.type = 'adjustment' THEN -t.amount
                    ELSE 0
                END), 0) INTO calculated_balance
            FROM transactions t
            LEFT JOIN transactions_expense te ON t.id = te.transaction_id AND te.account_id = p_account_id
            LEFT JOIN transactions_adjustment ta ON t.id = ta.transaction_id AND ta.account_id = p_account_id
            WHERE (te.account_id = p_account_id OR ta.account_id = p_account_id)
            AND t.deleted_at IS NULL;

        WHEN 'loan' THEN
            -- For loans: borrow(+), repayment(-)
            SELECT COALESCE(SUM(
                CASE 
                    WHEN t.type = 'borrow' THEN t.amount
                    WHEN t.type = 'adjustment' THEN -t.amount
                    ELSE 0
                END), 0) INTO calculated_balance
            FROM transactions t
            LEFT JOIN transactions_borrow tb ON t.id = tb.transaction_id AND tb.account_id = p_account_id
            LEFT JOIN transactions_adjustment ta ON t.id = ta.transaction_id AND ta.account_id = p_account_id
            WHERE (tb.account_id = p_account_id OR ta.account_id = p_account_id)
            AND t.deleted_at IS NULL;

        WHEN 'investment' THEN
            -- For investments: investment(+), income(+), adjustment(+/-)
            SELECT COALESCE(SUM(
                CASE 
                    WHEN t.type = 'investment' THEN t.amount
                    WHEN t.type = 'income' THEN t.amount
                    WHEN t.type = 'adjustment' THEN t.amount
                    ELSE 0
                END), 0) INTO calculated_balance
            FROM transactions t
            LEFT JOIN transactions_investment ti ON t.id = ti.transaction_id AND ti.account_id = p_account_id
            LEFT JOIN transactions_income tin ON t.id = tin.transaction_id AND tin.account_id = p_account_id
            LEFT JOIN transactions_adjustment ta ON t.id = ta.transaction_id AND ta.account_id = p_account_id
            WHERE (ti.account_id = p_account_id OR tin.account_id = p_account_id OR ta.account_id = p_account_id)
            AND t.deleted_at IS NULL;

        WHEN 'receivable' THEN
            -- For receivables: lend(+), payment(-), adjustment(+/-)
            SELECT COALESCE(SUM(
                CASE 
                    WHEN t.type = 'lend' THEN t.amount
                    WHEN t.type = 'adjustment' THEN t.amount
                    ELSE 0
                END), 0) INTO calculated_balance
            FROM transactions t
            LEFT JOIN transactions_lend tl ON t.id = tl.transaction_id AND tl.account_id = p_account_id
            LEFT JOIN transactions_adjustment ta ON t.id = ta.transaction_id AND ta.account_id = p_account_id
            WHERE (tl.account_id = p_account_id OR ta.account_id = p_account_id)
            AND t.deleted_at IS NULL;
    END CASE;

    RETURN calculated_balance;
END;
$$ LANGUAGE plpgsql;

-- Function to update specific account balance field
CREATE OR REPLACE FUNCTION update_account_balance_field(p_account_id UUID, p_new_balance DECIMAL(36,18))
RETURNS BOOLEAN AS $$
DECLARE
    acc_type account_type;
    updated_rows INTEGER;
BEGIN
    SELECT type INTO acc_type FROM accounts WHERE id = p_account_id AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Update the appropriate balance field based on account type
    CASE acc_type
        WHEN 'cash' THEN
            UPDATE cash_accounts 
            SET balance = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'bank' THEN
            UPDATE bank_accounts 
            SET balance = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'wallet' THEN
            UPDATE wallet_accounts 
            SET balance = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'crypto' THEN
            UPDATE crypto_accounts 
            SET balance = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'credit_card' THEN
            UPDATE credit_card_accounts 
            SET current_balance = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'loan' THEN
            UPDATE loan_accounts 
            SET outstanding_amount = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'investment' THEN
            UPDATE investment_accounts 
            SET portfolio_value = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        WHEN 'receivable' THEN
            UPDATE receivable_accounts 
            SET amount_due = p_new_balance, updated_at = NOW() 
            WHERE account_id = p_account_id;
            GET DIAGNOSTICS updated_rows = ROW_COUNT;

        ELSE
            RETURN FALSE;
    END CASE;

    -- Update main account timestamp
    UPDATE accounts SET updated_at = NOW() WHERE id = p_account_id;

    RETURN updated_rows > 0;
END;
$$ LANGUAGE plpgsql;

-- Function to clean up orphaned specialized accounts with specific field handling
CREATE OR REPLACE FUNCTION cleanup_orphaned_specialized_accounts()
RETURNS INTEGER AS $$
DECLARE
    cleanup_count INTEGER := 0;
    total_count INTEGER := 0;
BEGIN
    -- Clean up each specialized account type
    UPDATE cash_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (SELECT id FROM accounts WHERE deleted_at IS NULL)
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE bank_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (SELECT id FROM accounts WHERE deleted_at IS NULL)
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE credit_card_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (SELECT id FROM accounts WHERE deleted_at IS NULL)
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE loan_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (SELECT id FROM accounts WHERE deleted_at IS NULL)
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE investment_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (SELECT id FROM accounts WHERE deleted_at IS NULL)
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE crypto_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (SELECT id FROM accounts WHERE deleted_at IS NULL)
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE wallet_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (SELECT id FROM accounts WHERE deleted_at IS NULL)
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    UPDATE receivable_accounts 
    SET deleted_at = NOW(), updated_at = NOW() 
    WHERE account_id NOT IN (SELECT id FROM accounts WHERE deleted_at IS NULL)
    AND deleted_at IS NULL;
    GET DIAGNOSTICS cleanup_count = ROW_COUNT;
    total_count := total_count + cleanup_count;

    RETURN total_count;
END;
$$ LANGUAGE plpgsql;

-- =========================================
-- 21. UNIFIED BALANCE VIEW WITH SPECIFIC FIELDS
-- =========================================
CREATE OR REPLACE VIEW v_account_balances AS
SELECT 
    a.id AS account_id,
    a.user_id,
    a.account_name,
    a.type,
    a.currency,
    CASE a.type
        WHEN 'cash' THEN ca.balance
        WHEN 'bank' THEN ba.balance
        WHEN 'wallet' THEN wa.balance
        WHEN 'crypto' THEN cra.balance
        WHEN 'credit_card' THEN -cca.current_balance  -- Show as negative liability
        WHEN 'loan' THEN -la.outstanding_amount       -- Show as negative liability
        WHEN 'investment' THEN ia.portfolio_value
        WHEN 'receivable' THEN ra.amount_due
    END AS current_balance,
    CASE a.type
        WHEN 'cash' THEN ca.status
        WHEN 'bank' THEN ba.status
        WHEN 'wallet' THEN wa.status
        WHEN 'crypto' THEN cra.status
        WHEN 'credit_card' THEN cca.status
        WHEN 'loan' THEN la.status
        WHEN 'investment' THEN ia.status
        WHEN 'receivable' THEN ra.status
    END AS account_status,
    -- Additional type-specific information
    CASE a.type
        WHEN 'credit_card' THEN cca.credit_limit
        WHEN 'loan' THEN la.principal_amount
        ELSE NULL
    END AS credit_limit_or_principal,
    a.created_at,
    a.updated_at,
    GREATEST(
        a.updated_at,
        COALESCE(ca.updated_at, '1970-01-01'::timestamptz),
        COALESCE(ba.updated_at, '1970-01-01'::timestamptz),
        COALESCE(wa.updated_at, '1970-01-01'::timestamptz),
        COALESCE(cra.updated_at, '1970-01-01'::timestamptz),
        COALESCE(cca.updated_at, '1970-01-01'::timestamptz),
        COALESCE(la.updated_at, '1970-01-01'::timestamptz),
        COALESCE(ia.updated_at, '1970-01-01'::timestamptz),
        COALESCE(ra.updated_at, '1970-01-01'::timestamptz)
    ) AS last_activity
FROM accounts a
LEFT JOIN cash_accounts ca ON a.id = ca.account_id AND ca.deleted_at IS NULL
LEFT JOIN bank_accounts ba ON a.id = ba.account_id AND ba.deleted_at IS NULL
LEFT JOIN wallet_accounts wa ON a.id = wa.account_id AND wa.deleted_at IS NULL
LEFT JOIN crypto_accounts cra ON a.id = cra.account_id AND cra.deleted_at IS NULL
LEFT JOIN credit_card_accounts cca ON a.id = cca.account_id AND cca.deleted_at IS NULL
LEFT JOIN loan_accounts la ON a.id = la.account_id AND la.deleted_at IS NULL
LEFT JOIN investment_accounts ia ON a.id = ia.account_id AND ia.deleted_at IS NULL
LEFT JOIN receivable_accounts ra ON a.id = ra.account_id AND ra.deleted_at IS NULL
WHERE a.deleted_at IS NULL;

-- =========================================
-- 22. SCHEDULED RECURRING TRANSACTION PROCESSING
-- =========================================
CREATE OR REPLACE FUNCTION schedule_recurring_processing()
RETURNS TEXT AS $$
DECLARE
    result_record RECORD;
    processing_result TEXT;
BEGIN
    -- Process all due recurring transactions
    SELECT processed_count, new_transaction_ids INTO result_record 
    FROM process_recurring_transactions();

    processing_result := format('Processed %s recurring transactions at %s. New transaction IDs: %s',
        result_record.processed_count,
        NOW()::TEXT,
        COALESCE(array_to_string(result_record.new_transaction_ids, ', '), 'none')
    );

    -- Log the processing result in audit logs
    INSERT INTO audit_logs(user_id, action_by, table_name, record_id, action, new_data)
    VALUES (
        '00000000-0000-0000-0000-000000000000'::UUID, -- System user
        '00000000-0000-0000-0000-000000000000'::UUID, -- System action
        'system',
        gen_random_uuid(),
        'RECURRING_PROCESSING',
        jsonb_build_object(
            'processed_count', result_record.processed_count,
            'new_transaction_ids', result_record.new_transaction_ids,
            'processed_at', NOW()
        )
    );

    RETURN processing_result;
END;
$$ LANGUAGE plpgsql;

-- =========================================
-- 23. DATA INTEGRITY CHECK FUNCTIONS
-- =========================================
CREATE OR REPLACE FUNCTION check_balance_integrity(p_account_id UUID DEFAULT NULL)
RETURNS TABLE(
    account_id UUID,
    account_name TEXT,
    account_type account_type,
    current_balance DECIMAL(36,18),
    calculated_balance DECIMAL(36,18),
    difference DECIMAL(36,18),
    needs_correction BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        a.id AS account_id,
        a.account_name::TEXT,
        a.type AS account_type,
        vab.current_balance,
        recalculate_account_balance(a.id) AS calculated_balance,
        (vab.current_balance - recalculate_account_balance(a.id)) AS difference,
        (ABS(vab.current_balance - recalculate_account_balance(a.id)) > 0.01) AS needs_correction
    FROM accounts a
    JOIN v_account_balances vab ON a.id = vab.account_id
    WHERE a.deleted_at IS NULL
    AND (p_account_id IS NULL OR a.id = p_account_id)
    ORDER BY ABS(vab.current_balance - recalculate_account_balance(a.id)) DESC;
END;
$$ LANGUAGE plpgsql;

-- Function to fix balance discrepancies
CREATE OR REPLACE FUNCTION fix_balance_discrepancies(p_account_id UUID DEFAULT NULL)
RETURNS TABLE(
    account_id UUID,
    old_balance DECIMAL(36,18),
    new_balance DECIMAL(36,18),
    corrected BOOLEAN
) AS $$
DECLARE
    acc_record RECORD;
BEGIN
    FOR acc_record IN
        SELECT * FROM check_balance_integrity(p_account_id)
        WHERE needs_correction = TRUE
    LOOP
        RETURN QUERY
        SELECT 
            acc_record.account_id,
            acc_record.current_balance AS old_balance,
            acc_record.calculated_balance AS new_balance,
            update_account_balance_field(acc_record.account_id, acc_record.calculated_balance) AS corrected;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Note: Uncomment the following line if pg_cron extension is available
-- SELECT cron.schedule('process-recurring', '0 0 * * *', 'SELECT schedule_recurring_processing();');

-- ======================================================
-- END OF COMPREHENSIVE TRIGGERS FILE
-- ======================================================