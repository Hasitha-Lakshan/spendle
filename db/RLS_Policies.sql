-- =========================================
-- PROFILES
-- =========================================
DROP POLICY IF EXISTS select_own_profiles ON profiles;
DROP POLICY IF EXISTS insert_own_profiles ON profiles;
DROP POLICY IF EXISTS update_own_profiles ON profiles;
DROP POLICY IF EXISTS delete_own_profiles ON profiles;

-- =========================================
-- ACCOUNTS
-- =========================================
DROP POLICY IF EXISTS select_own_accounts ON accounts;
DROP POLICY IF EXISTS insert_own_accounts ON accounts;
DROP POLICY IF EXISTS update_own_accounts ON accounts;
DROP POLICY IF EXISTS delete_own_accounts ON accounts;

-- =========================================
-- SPECIALIZED ACCOUNTS
-- =========================================
DROP POLICY IF EXISTS select_own_cash_accounts ON cash_accounts;
DROP POLICY IF EXISTS insert_own_cash_accounts ON cash_accounts;
DROP POLICY IF EXISTS update_own_cash_accounts ON cash_accounts;
DROP POLICY IF EXISTS delete_own_cash_accounts ON cash_accounts;

DROP POLICY IF EXISTS select_own_bank_accounts ON bank_accounts;
DROP POLICY IF EXISTS insert_own_bank_accounts ON bank_accounts;
DROP POLICY IF EXISTS update_own_bank_accounts ON bank_accounts;
DROP POLICY IF EXISTS delete_own_bank_accounts ON bank_accounts;

DROP POLICY IF EXISTS select_own_credit_card_accounts ON credit_card_accounts;
DROP POLICY IF EXISTS insert_own_credit_card_accounts ON credit_card_accounts;
DROP POLICY IF EXISTS update_own_credit_card_accounts ON credit_card_accounts;
DROP POLICY IF EXISTS delete_own_credit_card_accounts ON credit_card_accounts;

DROP POLICY IF EXISTS select_own_loan_accounts ON loan_accounts;
DROP POLICY IF EXISTS insert_own_loan_accounts ON loan_accounts;
DROP POLICY IF EXISTS update_own_loan_accounts ON loan_accounts;
DROP POLICY IF EXISTS delete_own_loan_accounts ON loan_accounts;

DROP POLICY IF EXISTS select_own_investment_accounts ON investment_accounts;
DROP POLICY IF EXISTS insert_own_investment_accounts ON investment_accounts;
DROP POLICY IF EXISTS update_own_investment_accounts ON investment_accounts;
DROP POLICY IF EXISTS delete_own_investment_accounts ON investment_accounts;

DROP POLICY IF EXISTS select_own_crypto_accounts ON crypto_accounts;
DROP POLICY IF EXISTS insert_own_crypto_accounts ON crypto_accounts;
DROP POLICY IF EXISTS update_own_crypto_accounts ON crypto_accounts;
DROP POLICY IF EXISTS delete_own_crypto_accounts ON crypto_accounts;

DROP POLICY IF EXISTS select_own_wallet_accounts ON wallet_accounts;
DROP POLICY IF EXISTS insert_own_wallet_accounts ON wallet_accounts;
DROP POLICY IF EXISTS update_own_wallet_accounts ON wallet_accounts;
DROP POLICY IF EXISTS delete_own_wallet_accounts ON wallet_accounts;

DROP POLICY IF EXISTS select_own_receivable_accounts ON receivable_accounts;
DROP POLICY IF EXISTS insert_own_receivable_accounts ON receivable_accounts;
DROP POLICY IF EXISTS update_own_receivable_accounts ON receivable_accounts;
DROP POLICY IF EXISTS delete_own_receivable_accounts ON receivable_accounts;

-- =========================================
-- EXPENSE CATEGORIES & SUBCATEGORIES
-- =========================================
DROP POLICY IF EXISTS select_own_expense_categories ON expense_categories;
DROP POLICY IF EXISTS insert_own_expense_categories ON expense_categories;
DROP POLICY IF EXISTS update_own_expense_categories ON expense_categories;
DROP POLICY IF EXISTS delete_own_expense_categories ON expense_categories;

DROP POLICY IF EXISTS select_own_expense_subcategories ON expense_subcategories;
DROP POLICY IF EXISTS insert_own_expense_subcategories ON expense_subcategories;
DROP POLICY IF EXISTS update_own_expense_subcategories ON expense_subcategories;
DROP POLICY IF EXISTS delete_own_expense_subcategories ON expense_subcategories;

-- =========================================
-- INCOME SOURCES
-- =========================================
DROP POLICY IF EXISTS select_own_income_sources ON income_sources;
DROP POLICY IF EXISTS insert_own_income_sources ON income_sources;
DROP POLICY IF EXISTS update_own_income_sources ON income_sources;
DROP POLICY IF EXISTS delete_own_income_sources ON income_sources;

-- =========================================
-- TRANSACTIONS
-- =========================================
DROP POLICY IF EXISTS select_own_transactions ON transactions;
DROP POLICY IF EXISTS insert_own_transactions ON transactions;
DROP POLICY IF EXISTS update_own_transactions ON transactions;
DROP POLICY IF EXISTS delete_own_transactions ON transactions;

-- =========================================
-- TRANSACTION DETAIL TABLES
-- =========================================
DROP POLICY IF EXISTS select_own_transactions_income ON transactions_income;
DROP POLICY IF EXISTS insert_own_transactions_income ON transactions_income;
DROP POLICY IF EXISTS update_own_transactions_income ON transactions_income;
DROP POLICY IF EXISTS delete_own_transactions_income ON transactions_income;

DROP POLICY IF EXISTS select_own_transactions_expense ON transactions_expense;
DROP POLICY IF EXISTS insert_own_transactions_expense ON transactions_expense;
DROP POLICY IF EXISTS update_own_transactions_expense ON transactions_expense;
DROP POLICY IF EXISTS delete_own_transactions_expense ON transactions_expense;

DROP POLICY IF EXISTS select_own_transactions_investment ON transactions_investment;
DROP POLICY IF EXISTS insert_own_transactions_investment ON transactions_investment;
DROP POLICY IF EXISTS update_own_transactions_investment ON transactions_investment;
DROP POLICY IF EXISTS delete_own_transactions_investment ON transactions_investment;

DROP POLICY IF EXISTS select_own_transactions_borrow ON transactions_borrow;
DROP POLICY IF EXISTS insert_own_transactions_borrow ON transactions_borrow;
DROP POLICY IF EXISTS update_own_transactions_borrow ON transactions_borrow;
DROP POLICY IF EXISTS delete_own_transactions_borrow ON transactions_borrow;

DROP POLICY IF EXISTS select_own_transactions_lend ON transactions_lend;
DROP POLICY IF EXISTS insert_own_transactions_lend ON transactions_lend;
DROP POLICY IF EXISTS update_own_transactions_lend ON transactions_lend;
DROP POLICY IF EXISTS delete_own_transactions_lend ON transactions_lend;

DROP POLICY IF EXISTS select_own_transactions_transfer ON transactions_transfer;
DROP POLICY IF EXISTS insert_own_transactions_transfer ON transactions_transfer;
DROP POLICY IF EXISTS update_own_transactions_transfer ON transactions_transfer;
DROP POLICY IF EXISTS delete_own_transactions_transfer ON transactions_transfer;

DROP POLICY IF EXISTS select_own_transactions_adjustment ON transactions_adjustment;
DROP POLICY IF EXISTS insert_own_transactions_adjustment ON transactions_adjustment;
DROP POLICY IF EXISTS update_own_transactions_adjustment ON transactions_adjustment;
DROP POLICY IF EXISTS delete_own_transactions_adjustment ON transactions_adjustment;

-- =========================================
-- COUNTERPARTIES
-- =========================================
DROP POLICY IF EXISTS select_own_counterparties ON counterparties;
DROP POLICY IF EXISTS insert_own_counterparties ON counterparties;
DROP POLICY IF EXISTS update_own_counterparties ON counterparties;
DROP POLICY IF EXISTS delete_own_counterparties ON counterparties;

-- =========================================
-- AUDIT LOGS
-- =========================================
DROP POLICY IF EXISTS select_audit_logs_admins ON audit_logs;
DROP POLICY IF EXISTS insert_audit_logs_admins ON audit_logs;
DROP POLICY IF EXISTS update_audit_logs_admins ON audit_logs;
DROP POLICY IF EXISTS delete_audit_logs_admins ON audit_logs;

-- =========================================
-- ENABLE RLS ON ALL USER-SPECIFIC TABLES
-- =========================================
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE cash_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_card_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE investment_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE crypto_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE receivable_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_subcategories ENABLE ROW LEVEL SECURITY;
ALTER TABLE income_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE counterparties ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions_income ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions_expense ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions_investment ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions_borrow ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions_lend ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions_transfer ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions_adjustment ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- =========================================
-- UTILITY FUNCTION
-- =========================================
CREATE OR REPLACE FUNCTION current_user_id() RETURNS UUID AS $$
BEGIN
    RETURN auth.uid();
END;
$$ LANGUAGE plpgsql STABLE;

-- =========================================
-- PROFILES
-- =========================================
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
-- TRANSACTIONS
-- =========================================
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
-- COUNTERPARTIES
-- =========================================
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
-- AUDIT LOGS
-- =========================================
-- Only allow admins to SELECT from audit_logs
CREATE POLICY select_audit_logs_admins ON audit_logs
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
            FROM profiles p
            WHERE p.user_id = auth.uid() AND p.is_admin = TRUE
        )
    );

-- Only allow admins to INSERT into audit_logs
CREATE POLICY insert_audit_logs_admins ON audit_logs
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM profiles p
            WHERE p.user_id = auth.uid() AND p.is_admin = TRUE
        )
    );

-- Only allow admins to UPDATE audit_logs
CREATE POLICY update_audit_logs_admins ON audit_logs
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1
            FROM profiles p
            WHERE p.user_id = auth.uid() AND p.is_admin = TRUE
        )
    );

-- Only allow admins to DELETE from audit_logs
CREATE POLICY delete_audit_logs_admins ON audit_logs
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1
            FROM profiles p
            WHERE p.user_id = auth.uid() AND p.is_admin = TRUE
        )
    );
