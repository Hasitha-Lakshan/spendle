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

CREATE TRIGGER trigger_apply_transfer_balances
    AFTER INSERT ON transactions_transfer
    FOR EACH ROW 
    EXECUTE FUNCTION apply_transfer_balances();

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
GRANT EXECUTE ON FUNCTION apply_transaction_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION apply_transfer_balances() TO authenticated;
GRANT EXECUTE ON FUNCTION cleanup_transaction_details() TO authenticated;
GRANT EXECUTE ON FUNCTION reverse_balance_on_soft_delete() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_transaction_user() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_transfer_accounts() TO authenticated;
GRANT EXECUTE ON FUNCTION enforce_counterparty_unique() TO authenticated;
GRANT EXECUTE ON FUNCTION setup_recurring_transaction() TO authenticated;
GRANT EXECUTE ON FUNCTION process_recurring_transactions() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_subcategory_ownership() TO authenticated;

-- =========================================
-- COMMENTS AND DOCUMENTATION
-- =========================================

COMMENT ON FUNCTION apply_transaction_balance() IS 'RLS-compliant balance updates for transaction operations';
COMMENT ON FUNCTION apply_transfer_balances() IS 'RLS-compliant balance updates for transfer operations';
COMMENT ON FUNCTION process_recurring_transactions() IS 'RLS-compliant recurring transaction processing';

-- ======================================================
-- END OF TRIGGERS AND FUNCTIONS
-- ======================================================