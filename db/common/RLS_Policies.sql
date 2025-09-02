-- =========================================
-- Spendle RLS Policies
-- =========================================
-- This file defines row-level security policies for the Spendle schema.
-- It enforces per-user access, soft-delete for users, and admin soft/hard-delete.
-- =========================================

-- =========================================
-- PROFILES
-- =========================================
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_profiles ON profiles
    FOR SELECT USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY insert_own_profiles ON profiles
    FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY update_own_profiles ON profiles
    FOR UPDATE USING (user_id = auth.uid() AND deleted_at IS NULL)
    WITH CHECK (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_own_profiles ON profiles
    FOR DELETE USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_admin_profiles_soft ON profiles
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NULL);
CREATE POLICY delete_admin_profiles_hard ON profiles
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NOT NULL);

-- =========================================
-- ACCOUNTS
-- =========================================
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_accounts ON accounts
    FOR SELECT USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY insert_own_accounts ON accounts
    FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY update_own_accounts ON accounts
    FOR UPDATE USING (user_id = auth.uid() AND deleted_at IS NULL)
    WITH CHECK (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY soft_delete_own_accounts ON accounts
    FOR UPDATE USING (user_id = auth.uid() AND deleted_at IS NULL)
    WITH CHECK (user_id = auth.uid());
CREATE POLICY delete_own_accounts ON accounts
    FOR DELETE USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_admin_accounts_soft ON accounts
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NULL);
CREATE POLICY delete_admin_accounts_hard ON accounts
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NOT NULL);

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
        -- Enable RLS on the table
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', tbl);

        -- Drop existing policies if they exist
        EXECUTE format('DROP POLICY IF EXISTS select_own_%1$I ON %1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS insert_own_%1$I ON %1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS update_own_%1$I ON %1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS delete_own_%1$I ON %1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS delete_admin_%1$I_soft ON %1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS delete_admin_%1$I_hard ON %1$I;', tbl);

        -- Create SELECT policy
        EXECUTE format($f$
            CREATE POLICY select_own_%1$I ON %1$I
            FOR SELECT USING (
                EXISTS (
                    SELECT 1 FROM accounts a
                    WHERE a.id = %1$I.account_id
                    AND a.user_id = auth.uid()
                    AND a.deleted_at IS NULL
                )
            );
        $f$, tbl);

        -- Create INSERT policy
        EXECUTE format($f$
            CREATE POLICY insert_own_%1$I ON %1$I
            FOR INSERT WITH CHECK (
                EXISTS (
                    SELECT 1 FROM accounts a
                    WHERE a.id = %1$I.account_id
                    AND a.user_id = auth.uid()
                    AND a.deleted_at IS NULL
                )
            );
        $f$, tbl);

        -- Create UPDATE policy
        EXECUTE format($f$
            CREATE POLICY update_own_%1$I ON %1$I
            FOR UPDATE USING (
                EXISTS (
                    SELECT 1 FROM accounts a
                    WHERE a.id = %1$I.account_id
                    AND a.user_id = auth.uid()
                    AND a.deleted_at IS NULL
                )
            );
        $f$, tbl);

        -- Create DELETE policy with soft-delete safeguard
        EXECUTE format($f$
            CREATE POLICY delete_own_%1$I ON %1$I
            FOR DELETE USING (
                EXISTS (
                    SELECT 1 FROM accounts a
                    WHERE a.id = %1$I.account_id
                    AND a.user_id = auth.uid()
                    AND a.deleted_at IS NULL
                )
                AND %1$I.deleted_at IS NULL
            );
        $f$, tbl);

        EXECUTE format($f$
            CREATE POLICY delete_admin_%1$I_soft ON %1$I
            FOR DELETE USING (public.check_admin_permissions() AND %1$I.deleted_at IS NULL);
        $f$, tbl);

        EXECUTE format($f$
            CREATE POLICY delete_admin_%1$I_hard ON %1$I
            FOR DELETE USING (public.check_admin_permissions() AND %1$I.deleted_at IS NOT NULL);
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
    FOR SELECT USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY insert_own_expense_categories ON expense_categories
    FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY update_own_expense_categories ON expense_categories
    FOR UPDATE USING (user_id = auth.uid() AND deleted_at IS NULL)
    WITH CHECK (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_own_expense_categories ON expense_categories
    FOR DELETE USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_admin_expense_categories_soft ON expense_categories
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NULL);
CREATE POLICY delete_admin_expense_categories_hard ON expense_categories
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NOT NULL);

CREATE POLICY select_own_expense_subcategories ON expense_subcategories
    FOR SELECT USING (EXISTS (SELECT 1 FROM expense_categories ec WHERE ec.id = expense_subcategories.category_id AND ec.user_id = auth.uid() AND ec.deleted_at IS NULL));
CREATE POLICY insert_own_expense_subcategories ON expense_subcategories
    FOR INSERT WITH CHECK (EXISTS (SELECT 1 FROM expense_categories ec WHERE ec.id = expense_subcategories.category_id AND ec.user_id = auth.uid() AND ec.deleted_at IS NULL));
CREATE POLICY update_own_expense_subcategories ON expense_subcategories
    FOR UPDATE USING (EXISTS (SELECT 1 FROM expense_categories ec WHERE ec.id = expense_subcategories.category_id AND ec.user_id = auth.uid() AND ec.deleted_at IS NULL));
CREATE POLICY delete_own_expense_subcategories ON expense_subcategories
    FOR DELETE USING (EXISTS (SELECT 1 FROM expense_categories ec WHERE ec.id = expense_subcategories.category_id AND ec.user_id = auth.uid() AND ec.deleted_at IS NULL) AND expense_subcategories.deleted_at IS NULL);
CREATE POLICY delete_admin_expense_subcategories_soft ON expense_subcategories
    FOR DELETE USING (public.check_admin_permissions() AND expense_subcategories.deleted_at IS NULL);
CREATE POLICY delete_admin_expense_subcategories_hard ON expense_subcategories
    FOR DELETE USING (public.check_admin_permissions() AND expense_subcategories.deleted_at IS NOT NULL);

-- =========================================
-- INCOME SOURCES
-- =========================================
ALTER TABLE income_sources ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_income_sources ON income_sources
    FOR SELECT USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY insert_own_income_sources ON income_sources
    FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY update_own_income_sources ON income_sources
    FOR UPDATE USING (user_id = auth.uid() AND deleted_at IS NULL)
    WITH CHECK (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_own_income_sources ON income_sources
    FOR DELETE USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_admin_income_sources_soft ON income_sources
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NULL);
CREATE POLICY delete_admin_income_sources_hard ON income_sources
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NOT NULL);

-- =========================================
-- COUNTERPARTIES
-- =========================================
ALTER TABLE counterparties ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_counterparties ON counterparties
    FOR SELECT USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY insert_own_counterparties ON counterparties
    FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY update_own_counterparties ON counterparties
    FOR UPDATE USING (user_id = auth.uid() AND deleted_at IS NULL)
    WITH CHECK (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_own_counterparties ON counterparties
    FOR DELETE USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_admin_counterparties_soft ON counterparties
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NULL);
CREATE POLICY delete_admin_counterparties_hard ON counterparties
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NOT NULL);

-- =========================================
-- TRANSACTIONS
-- =========================================
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_transactions ON transactions
    FOR SELECT USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY insert_own_transactions ON transactions
    FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY update_own_transactions ON transactions
    FOR UPDATE USING (user_id = auth.uid() AND deleted_at IS NULL)
    WITH CHECK (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_own_transactions ON transactions
    FOR DELETE USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_admin_transactions_soft ON transactions
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NULL);
CREATE POLICY delete_admin_transactions_hard ON transactions
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NOT NULL);

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
        -- Enable RLS on the table
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', tbl);

        -- Drop existing policies to allow safe re-runs
        EXECUTE format('DROP POLICY IF EXISTS select_own_%1$I ON %1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS insert_own_%1$I ON %1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS update_own_%1$I ON %1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS delete_own_%1$I ON %1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS delete_admin_%1$I_soft ON %1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS delete_admin_%1$I_hard ON %1$I;', tbl);

        -- Create SELECT policy
        EXECUTE format($f$
            CREATE POLICY select_own_%1$I ON %1$I
            FOR SELECT USING (
                EXISTS (
                    SELECT 1 FROM transactions t
                    WHERE t.id = %1$I.transaction_id
                    AND t.user_id = auth.uid()
                    AND t.deleted_at IS NULL
                )
            );
        $f$, tbl);

        -- Create INSERT policy
        EXECUTE format($f$
            CREATE POLICY insert_own_%1$I ON %1$I
            FOR INSERT WITH CHECK (
                EXISTS (
                    SELECT 1 FROM transactions t
                    WHERE t.id = %1$I.transaction_id
                    AND t.user_id = auth.uid()
                    AND t.deleted_at IS NULL
                )
            );
        $f$, tbl);

        -- Create UPDATE policy
        EXECUTE format($f$
            CREATE POLICY update_own_%1$I ON %1$I
            FOR UPDATE USING (
                EXISTS (
                    SELECT 1 FROM transactions t
                    WHERE t.id = %1$I.transaction_id
                    AND t.user_id = auth.uid()
                    AND t.deleted_at IS NULL
                )
            );
        $f$, tbl);

        -- Create DELETE policy with soft-delete safeguard
        EXECUTE format($f$
            CREATE POLICY delete_own_%1$I ON %1$I
            FOR DELETE USING (
                EXISTS (
                    SELECT 1 FROM transactions t
                    WHERE t.id = %1$I.transaction_id
                    AND t.user_id = auth.uid()
                    AND t.deleted_at IS NULL
                )
                AND %1$I.deleted_at IS NULL
            );
        $f$, tbl);

        EXECUTE format($f$
            CREATE POLICY delete_admin_%1$I_soft ON %1$I
            FOR DELETE USING (public.check_admin_permissions() AND %1$I.deleted_at IS NULL);
        $f$, tbl);

        EXECUTE format($f$
            CREATE POLICY delete_admin_%1$I_hard ON %1$I
            FOR DELETE USING (public.check_admin_permissions() AND %1$I.deleted_at IS NOT NULL);
        $f$, tbl);

    END LOOP;
END;
$$;

-- =========================================
-- RECURRING TRANSACTIONS
-- =========================================
ALTER TABLE transactions_recurring ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_transactions_recurring ON transactions_recurring
    FOR SELECT USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY insert_own_transactions_recurring ON transactions_recurring
    FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY update_own_transactions_recurring ON transactions_recurring
    FOR UPDATE USING (user_id = auth.uid() AND deleted_at IS NULL)
    WITH CHECK (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_own_transactions_recurring ON transactions_recurring
    FOR DELETE USING (user_id = auth.uid() AND deleted_at IS NULL);
CREATE POLICY delete_admin_transactions_recurring_soft ON transactions_recurring
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NULL);
CREATE POLICY delete_admin_transactions_recurring_hard ON transactions_recurring
    FOR DELETE USING (public.check_admin_permissions() AND deleted_at IS NOT NULL);

-- =========================================
-- AUDIT LOGS
-- =========================================
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_audit_logs_admins ON audit_logs
    FOR SELECT USING (check_admin_permissions());

CREATE POLICY insert_audit_logs_admins ON audit_logs
    FOR INSERT WITH CHECK (check_admin_permissions());

CREATE POLICY update_audit_logs_admins ON audit_logs
    FOR UPDATE USING (check_admin_permissions());

CREATE POLICY delete_audit_logs_admins ON audit_logs
    FOR DELETE USING (check_admin_permissions());

-- =========================================
-- API RATE LIMITS
-- =========================================
ALTER TABLE api_rate_limits ENABLE ROW LEVEL SECURITY;

-- Users can only select their own rows
CREATE POLICY select_own_api_rate_limits ON api_rate_limits
    FOR SELECT USING (user_id = auth.uid());

-- Users can only insert rows for themselves
CREATE POLICY insert_own_api_rate_limits ON api_rate_limits
    FOR INSERT WITH CHECK (user_id = auth.uid());
    
-- Users can only update their own rows
CREATE POLICY update_own_api_rate_limits ON api_rate_limits
    FOR UPDATE USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
    
-- Users can only delete their own rows
CREATE POLICY delete_own_api_rate_limits ON api_rate_limits
    FOR DELETE USING (user_id = auth.uid());
