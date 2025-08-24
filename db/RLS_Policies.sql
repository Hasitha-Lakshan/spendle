-- =========================================
-- Spendle RLS Policies
-- =========================================
-- This file defines row-level security policies for the Spendle schema.
-- It enforces per-user access and admin-only access where appropriate.
-- =========================================

-- =========================================
-- Utility Function
-- =========================================
CREATE OR REPLACE FUNCTION public.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT auth.uid();
$$;

-- =========================================
-- PROFILES
-- =========================================
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_profiles ON profiles
    FOR SELECT USING (user_id = current_user_id());
CREATE POLICY insert_own_profiles ON profiles
    FOR INSERT WITH CHECK (user_id = current_user_id());
CREATE POLICY update_own_profiles ON profiles
    FOR UPDATE USING (user_id = current_user_id())
    WITH CHECK (user_id = current_user_id());
CREATE POLICY delete_own_profiles ON profiles
    FOR DELETE USING (user_id = current_user_id());

-- =========================================
-- ACCOUNTS
-- =========================================
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_accounts ON accounts
    FOR SELECT USING (user_id = current_user_id() AND deleted_at IS NULL);
CREATE POLICY insert_own_accounts ON accounts
    FOR INSERT WITH CHECK (user_id = current_user_id());

CREATE POLICY update_own_accounts ON accounts
    FOR UPDATE
    USING (
        user_id = current_user_id() AND deleted_at IS NULL AND
        NOT EXISTS (
            SELECT 1 FROM transactions t
            WHERE t.user_id = accounts.user_id AND t.deleted_at IS NULL AND
            (
                t.id IN (SELECT transaction_id FROM transactions_income WHERE account_id = accounts.id AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_expense WHERE account_id = accounts.id AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_investment WHERE account_id = accounts.id AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_borrow WHERE account_id = accounts.id AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_lend WHERE account_id = accounts.id AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_transfer WHERE (from_account = accounts.id OR to_account = accounts.id) AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_adjustment WHERE account_id = accounts.id AND deleted_at IS NULL)
            )
        )
    )
    WITH CHECK (user_id = current_user_id());

CREATE POLICY delete_own_accounts ON accounts
    FOR DELETE
    USING (
        user_id = current_user_id() AND
        NOT EXISTS (
            SELECT 1 FROM transactions t
            WHERE t.user_id = accounts.user_id AND t.deleted_at IS NULL AND
            (
                t.id IN (SELECT transaction_id FROM transactions_income WHERE account_id = accounts.id AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_expense WHERE account_id = accounts.id AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_investment WHERE account_id = accounts.id AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_borrow WHERE account_id = accounts.id AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_lend WHERE account_id = accounts.id AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_transfer WHERE (from_account = accounts.id OR to_account = accounts.id) AND deleted_at IS NULL) OR
                t.id IN (SELECT transaction_id FROM transactions_adjustment WHERE account_id = accounts.id AND deleted_at IS NULL)
            )
        )
    );

-- =========================================
-- SPECIALIZED ACCOUNTS
-- Inherit user_id check from accounts
-- =========================================
DO $$
DECLARE
    specialized_accounts TEXT[] := ARRAY[
        'cash_accounts', 'bank_accounts', 'credit_card_accounts', 'loan_accounts',
        'investment_accounts', 'crypto_accounts', 'wallet_accounts', 'receivable_accounts'
    ];
    tbl TEXT;
BEGIN
    FOREACH tbl IN ARRAY specialized_accounts LOOP
        EXECUTE format($f$
            ALTER TABLE %1$I ENABLE ROW LEVEL SECURITY;

            CREATE POLICY select_own_%1$I ON %1$I
            FOR SELECT USING (EXISTS (SELECT 1 FROM accounts a WHERE a.id = %1$I.account_id AND a.user_id = current_user_id() AND a.deleted_at IS NULL));

            CREATE POLICY insert_own_%1$I ON %1$I
            FOR INSERT WITH CHECK (EXISTS (SELECT 1 FROM accounts a WHERE a.id = %1$I.account_id AND a.user_id = current_user_id() AND a.deleted_at IS NULL));

            CREATE POLICY update_own_%1$I ON %1$I
            FOR UPDATE USING (EXISTS (SELECT 1 FROM accounts a WHERE a.id = %1$I.account_id AND a.user_id = current_user_id() AND a.deleted_at IS NULL));

            CREATE POLICY delete_own_%1$I ON %1$I
            FOR DELETE USING (EXISTS (SELECT 1 FROM accounts a WHERE a.id = %1$I.account_id AND a.user_id = current_user_id() AND a.deleted_at IS NULL));
        $f$, tbl);
    END LOOP;
END;
$$;

-- =========================================
-- EXPENSE CATEGORIES & SUBCATEGORIES
-- =========================================
ALTER TABLE expense_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_subcategories ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_expense_categories ON expense_categories
    FOR SELECT USING (user_id = current_user_id() AND deleted_at IS NULL);
CREATE POLICY insert_own_expense_categories ON expense_categories
    FOR INSERT WITH CHECK (user_id = current_user_id());
CREATE POLICY update_own_expense_categories ON expense_categories
    FOR UPDATE USING (user_id = current_user_id() AND deleted_at IS NULL)
    WITH CHECK (user_id = current_user_id());
CREATE POLICY delete_own_expense_categories ON expense_categories
    FOR DELETE USING (user_id = current_user_id());

CREATE POLICY select_own_expense_subcategories ON expense_subcategories
    FOR SELECT USING (EXISTS (SELECT 1 FROM expense_categories ec WHERE ec.id = expense_subcategories.category_id AND ec.user_id = current_user_id() AND ec.deleted_at IS NULL));
CREATE POLICY insert_own_expense_subcategories ON expense_subcategories
    FOR INSERT WITH CHECK (EXISTS (SELECT 1 FROM expense_categories ec WHERE ec.id = expense_subcategories.category_id AND ec.user_id = current_user_id() AND ec.deleted_at IS NULL));
CREATE POLICY update_own_expense_subcategories ON expense_subcategories
    FOR UPDATE USING (EXISTS (SELECT 1 FROM expense_categories ec WHERE ec.id = expense_subcategories.category_id AND ec.user_id = current_user_id() AND ec.deleted_at IS NULL));
CREATE POLICY delete_own_expense_subcategories ON expense_subcategories
    FOR DELETE USING (EXISTS (SELECT 1 FROM expense_categories ec WHERE ec.id = expense_subcategories.category_id AND ec.user_id = current_user_id() AND ec.deleted_at IS NULL));

-- =========================================
-- INCOME SOURCES
-- =========================================
ALTER TABLE income_sources ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_income_sources ON income_sources
    FOR SELECT USING (user_id = current_user_id() AND deleted_at IS NULL);
CREATE POLICY insert_own_income_sources ON income_sources
    FOR INSERT WITH CHECK (user_id = current_user_id());
CREATE POLICY update_own_income_sources ON income_sources
    FOR UPDATE USING (user_id = current_user_id() AND deleted_at IS NULL)
    WITH CHECK (user_id = current_user_id());
CREATE POLICY delete_own_income_sources ON income_sources
    FOR DELETE USING (user_id = current_user_id());

-- =========================================
-- COUNTERPARTIES
-- =========================================
ALTER TABLE counterparties ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_counterparties ON counterparties
    FOR SELECT USING (user_id = current_user_id() AND deleted_at IS NULL);
CREATE POLICY insert_own_counterparties ON counterparties
    FOR INSERT WITH CHECK (user_id = current_user_id());
CREATE POLICY update_own_counterparties ON counterparties
    FOR UPDATE USING (user_id = current_user_id() AND deleted_at IS NULL)
    WITH CHECK (user_id = current_user_id());
CREATE POLICY delete_own_counterparties ON counterparties
    FOR DELETE USING (user_id = current_user_id() AND deleted_at IS NULL);

-- =========================================
-- TRANSACTIONS
-- =========================================
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_transactions ON transactions
    FOR SELECT USING (user_id = current_user_id() AND deleted_at IS NULL);
CREATE POLICY insert_own_transactions ON transactions
    FOR INSERT WITH CHECK (user_id = current_user_id());
CREATE POLICY update_own_transactions ON transactions
    FOR UPDATE USING (user_id = current_user_id() AND deleted_at IS NULL)
    WITH CHECK (user_id = current_user_id());
CREATE POLICY delete_own_transactions ON transactions
    FOR DELETE USING (user_id = current_user_id());

-- =========================================
-- TRANSACTION DETAIL TABLES
-- =========================================
DO $$
DECLARE
    trans_details TEXT[] := ARRAY[
        'transactions_income', 'transactions_expense', 'transactions_investment',
        'transactions_borrow', 'transactions_lend', 'transactions_transfer', 'transactions_adjustment'
    ];
    tbl TEXT;
BEGIN
    FOREACH tbl IN ARRAY trans_details LOOP
        EXECUTE format($f$
            ALTER TABLE %1$I ENABLE ROW LEVEL SECURITY;

            CREATE POLICY select_own_%1$I ON %1$I
            FOR SELECT USING (EXISTS (SELECT 1 FROM transactions t WHERE t.id = %1$I.transaction_id AND t.user_id = current_user_id() AND t.deleted_at IS NULL));

            CREATE POLICY insert_own_%1$I ON %1$I
            FOR INSERT WITH CHECK (EXISTS (SELECT 1 FROM transactions t WHERE t.id = %1$I.transaction_id AND t.user_id = current_user_id() AND t.deleted_at IS NULL));

            CREATE POLICY update_own_%1$I ON %1$I
            FOR UPDATE USING (EXISTS (SELECT 1 FROM transactions t WHERE t.id = %1$I.transaction_id AND t.user_id = current_user_id() AND t.deleted_at IS NULL));

            CREATE POLICY delete_own_%1$I ON %1$I
            FOR DELETE USING (EXISTS (SELECT 1 FROM transactions t WHERE t.id = %1$I.transaction_id AND t.user_id = current_user_id() AND t.deleted_at IS NULL));
        $f$, tbl);
    END LOOP;
END;
$$;

-- =========================================
-- RECURRING TRANSACTIONS
-- =========================================
ALTER TABLE transactions_recurring ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_transactions_recurring ON transactions_recurring
    FOR SELECT USING (user_id = current_user_id() AND deleted_at IS NULL);
CREATE POLICY insert_own_transactions_recurring ON transactions_recurring
    FOR INSERT WITH CHECK (user_id = current_user_id());
CREATE POLICY update_own_transactions_recurring ON transactions_recurring
    FOR UPDATE USING (user_id = current_user_id() AND deleted_at IS NULL)
    WITH CHECK (user_id = current_user_id());
CREATE POLICY delete_own_transactions_recurring ON transactions_recurring
    FOR DELETE USING (user_id = current_user_id());

-- =========================================
-- AUDIT LOGS
-- =========================================
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_audit_logs_admins ON audit_logs
    FOR SELECT
    USING (EXISTS (
        SELECT 1 
        FROM profiles p 
        WHERE p.user_id = (SELECT auth.uid()) AND p.is_admin = TRUE
    ));

CREATE POLICY insert_audit_logs_admins ON audit_logs
    FOR INSERT
    WITH CHECK (EXISTS (
        SELECT 1 
        FROM profiles p 
        WHERE p.user_id = (SELECT auth.uid()) AND p.is_admin = TRUE
    ));

CREATE POLICY update_audit_logs_admins ON audit_logs
    FOR UPDATE
    USING (EXISTS (
        SELECT 1 
        FROM profiles p 
        WHERE p.user_id = (SELECT auth.uid()) AND p.is_admin = TRUE
    ));

CREATE POLICY delete_audit_logs_admins ON audit_logs
    FOR DELETE
    USING (EXISTS (
        SELECT 1 
        FROM profiles p 
        WHERE p.user_id = (SELECT auth.uid()) AND p.is_admin = TRUE
    ));
