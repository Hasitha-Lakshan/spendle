-- =========================================
-- Spendle RLS Policies
-- =========================================
-- This file defines row-level security policies for the Spendle schema.
-- It enforces per-user access, soft-delete for users, and admin soft/hard-delete.
-- =========================================

-- =========================================
-- PROFILES
-- =========================================
ALTER TABLE core.profiles ENABLE ROW LEVEL SECURITY;

-- SELECT: user can see their own active profile
CREATE POLICY select_own_profiles ON core.profiles
    FOR SELECT
    USING (
        id = util.current_active_profile_id_internal()
    );

-- INSERT: user may create exactly their own profile
CREATE POLICY insert_own_profiles ON core.profiles
    FOR INSERT
    WITH CHECK (
        user_id = (SELECT auth.uid())
    );

-- UPDATE: user may update their own active profile
CREATE POLICY update_own_profiles ON core.profiles
    FOR UPDATE
    USING (
        id = util.current_active_profile_id_internal()
        AND deleted_at IS NULL
    )
    WITH CHECK (
        id = util.current_active_profile_id_internal()
        AND deleted_at IS NULL
    );

-- DELETE: admin-only hard delete after soft delete
CREATE POLICY delete_profiles_combined ON core.profiles
    FOR DELETE
    USING (
        deleted_at IS NOT NULL
        AND util.check_admin_permissions_internal()
    );

-- =========================================
-- ACCOUNTS
-- =========================================
ALTER TABLE finance.accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_accounts ON finance.accounts
    FOR SELECT USING (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL);
CREATE POLICY insert_own_accounts ON finance.accounts
    FOR INSERT WITH CHECK (profile_id = util.current_active_profile_id_internal());
CREATE POLICY update_accounts_combined ON finance.accounts
    FOR UPDATE
    USING (
        (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL)  -- normal update
        OR
        (profile_id = util.current_active_profile_id_internal())  -- soft-delete update
    )
    WITH CHECK (
        (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL)  -- normal update check
        OR
        (profile_id = util.current_active_profile_id_internal())  -- soft-delete check
    );
CREATE POLICY delete_accounts_combined ON finance.accounts
    FOR DELETE USING (
        deleted_at IS NOT NULL
        AND util.check_admin_permissions_internal()
    );

-- =========================================
-- SPECIALIZED ACCOUNTS
-- Inherit profile_id check from accounts
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
        EXECUTE format('ALTER TABLE finance.%I ENABLE ROW LEVEL SECURITY;', tbl);

        -- Drop existing policies if they exist
        EXECUTE format('DROP POLICY IF EXISTS select_own_%1$I ON finance.%1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS insert_own_%1$I ON finance.%1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS update_own_%1$I ON finance.%1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS delete_own_%1$I ON finance.%1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS delete_admin_%1$I_soft ON finance.%1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS delete_admin_%1$I_hard ON finance.%1$I;', tbl);

        -- Create SELECT policy
        EXECUTE format($f$
            CREATE POLICY select_own_%1$I ON finance.%1$I
            FOR SELECT USING (
                EXISTS (
                    SELECT 1 FROM finance.accounts a
                    WHERE a.id = finance.%1$I.account_id
                    AND a.profile_id = util.current_active_profile_id_internal()
                    AND a.deleted_at IS NULL
                )
            );
        $f$, tbl);

        -- Create INSERT policy
        EXECUTE format($f$
            CREATE POLICY insert_own_%1$I ON finance.%1$I
            FOR INSERT WITH CHECK (
                EXISTS (
                    SELECT 1 FROM finance.accounts a
                    WHERE a.id = finance.%1$I.account_id
                    AND a.profile_id = util.current_active_profile_id_internal()
                    AND a.deleted_at IS NULL
                )
            );
        $f$, tbl);

        -- Create UPDATE policy
        EXECUTE format($f$
            CREATE POLICY update_own_%1$I ON finance.%1$I
            FOR UPDATE USING (
                EXISTS (
                    SELECT 1 FROM finance.accounts a
                    WHERE a.id = finance.%1$I.account_id
                    AND a.profile_id = util.current_active_profile_id_internal()
                    AND a.deleted_at IS NULL
                )
            );
        $f$, tbl);

        -- Create DELETE policy with soft-delete safeguard
        EXECUTE format($f$
            CREATE POLICY delete_%1$I_combined ON finance.%1$I
            FOR DELETE USING (
                EXISTS (
                    SELECT 1 FROM finance.accounts a
                    WHERE a.id = finance.%1$I.account_id
                    AND a.deleted_at IS NOT NULL
                    AND util.check_admin_permissions_internal()
                )
            );
        $f$, tbl);
    END LOOP;
END;
$$;

-- =========================================
-- EXPENSE CATEGORIES & SUBCATEGORIES
-- =========================================
ALTER TABLE finance.expense_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE finance.expense_subcategories ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_expense_categories ON finance.expense_categories
    FOR SELECT USING (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL);
CREATE POLICY insert_own_expense_categories ON finance.expense_categories
    FOR INSERT WITH CHECK (profile_id = util.current_active_profile_id_internal());
CREATE POLICY update_own_expense_categories ON finance.expense_categories
    FOR UPDATE USING (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL)
    WITH CHECK (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL);
CREATE POLICY delete_expense_categories_combined ON finance.expense_categories
    FOR DELETE USING (
        deleted_at IS NOT NULL
        AND util.check_admin_permissions_internal()
    );

CREATE POLICY select_own_expense_subcategories ON finance.expense_subcategories
    FOR SELECT USING (EXISTS (
        SELECT 1 
        FROM finance.expense_categories ec 
        WHERE ec.id = finance.expense_subcategories.category_id 
        AND ec.profile_id = util.current_active_profile_id_internal() 
        AND ec.deleted_at IS NULL
    ));
CREATE POLICY insert_own_expense_subcategories ON finance.expense_subcategories
    FOR INSERT WITH CHECK (EXISTS (
        SELECT 1 
        FROM finance.expense_categories ec 
        WHERE ec.id = finance.expense_subcategories.category_id 
        AND ec.profile_id = util.current_active_profile_id_internal() 
        AND ec.deleted_at IS NULL
    ));
CREATE POLICY update_own_expense_subcategories ON finance.expense_subcategories
    FOR UPDATE USING (EXISTS (
        SELECT 1 
        FROM finance.expense_categories ec 
        WHERE ec.id = finance.expense_subcategories.category_id 
        AND ec.profile_id = util.current_active_profile_id_internal() 
        AND ec.deleted_at IS NULL
    ));
CREATE POLICY delete_expense_subcategories_combined ON finance.expense_subcategories
    FOR DELETE USING (EXISTS (
        SELECT 1 
        FROM finance.expense_categories ec
        WHERE ec.id = finance.expense_subcategories.category_id
        AND ec.deleted_at IS NOT NULL
        AND util.check_admin_permissions_internal()
    ));

-- =========================================
-- INCOME SOURCES
-- =========================================
ALTER TABLE finance.income_sources ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_income_sources ON finance.income_sources
    FOR SELECT USING (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL);
CREATE POLICY insert_own_income_sources ON finance.income_sources
    FOR INSERT WITH CHECK (profile_id = util.current_active_profile_id_internal());
CREATE POLICY update_own_income_sources ON finance.income_sources
    FOR UPDATE USING (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL)
    WITH CHECK (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL);
CREATE POLICY delete_income_sources_combined ON finance.income_sources
    FOR DELETE USING (
        deleted_at IS NOT NULL
        AND util.check_admin_permissions_internal()
    );

-- =========================================
-- COUNTERPARTIES
-- =========================================
ALTER TABLE finance.counterparties ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_own_counterparties ON finance.counterparties
    FOR SELECT USING (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL);
CREATE POLICY insert_own_counterparties ON finance.counterparties
    FOR INSERT WITH CHECK (profile_id = util.current_active_profile_id_internal());
CREATE POLICY update_own_counterparties ON finance.counterparties
    FOR UPDATE USING (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL)
    WITH CHECK (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL);
CREATE POLICY delete_counterparties_combined ON finance.counterparties
    FOR DELETE USING (
        deleted_at IS NOT NULL
        AND util.check_admin_permissions_internal()
    );

-- =========================================
-- TRANSACTIONS
-- =========================================
ALTER TABLE finance.transactions ENABLE ROW LEVEL SECURITY;

-- SELECT
CREATE POLICY select_transactions_combined ON finance.transactions
    FOR SELECT USING (
        (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL)
        OR util.check_admin_permissions_internal()
    );

-- INSERT
CREATE POLICY insert_transactions_combined ON finance.transactions
    FOR INSERT WITH CHECK (
        profile_id = util.current_active_profile_id_internal()
        OR util.check_admin_permissions_internal()
    );

-- UPDATE (normal update for active, soft-delete allowed, admin override)
CREATE POLICY update_transactions_combined ON finance.transactions
    FOR UPDATE
    USING (
        (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL)  -- normal update
        OR util.check_admin_permissions_internal()           -- admin override
    )
    WITH CHECK (
        (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL)  -- normal update
        OR (profile_id = util.current_active_profile_id_internal())                     -- soft-delete (owner can set deleted_at)
        OR util.check_admin_permissions_internal()           -- admin override
    );

-- DELETE (only admins, only if soft-deleted)
CREATE POLICY delete_transactions_combined ON finance.transactions
    FOR DELETE USING (
        util.check_admin_permissions_internal() AND deleted_at IS NOT NULL
    );

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
        -- Enable RLS
        EXECUTE format('ALTER TABLE finance.%I ENABLE ROW LEVEL SECURITY;', tbl);

        -- Drop old policies
        EXECUTE format('DROP POLICY IF EXISTS select_%1$I_combined ON finance.%1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS insert_%1$I_combined ON finance.%1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS update_%1$I_combined ON finance.%1$I;', tbl);
        EXECUTE format('DROP POLICY IF EXISTS delete_%1$I_combined ON finance.%1$I;', tbl);

        -- SELECT
        EXECUTE format($f$
            CREATE POLICY select_%1$I_combined ON finance.%1$I
            FOR SELECT USING (
                EXISTS (
                    SELECT 1 FROM finance.transactions t
                    WHERE t.id = finance.%1$I.transaction_id
                    AND t.profile_id = util.current_active_profile_id_internal()
                    AND t.deleted_at IS NULL
                )
                OR util.check_admin_permissions_internal()
            );
        $f$, tbl);

        -- INSERT
        EXECUTE format($f$
            CREATE POLICY insert_%1$I_combined ON finance.%1$I
            FOR INSERT WITH CHECK (
                EXISTS (
                    SELECT 1 FROM finance.transactions t
                    WHERE t.id = finance.%1$I.transaction_id
                    AND t.profile_id = util.current_active_profile_id_internal()
                    AND t.deleted_at IS NULL
                )
                OR util.check_admin_permissions_internal()
            );
        $f$, tbl);

        -- UPDATE
        EXECUTE format($f$
            CREATE POLICY update_%1$I_combined ON finance.%1$I
            FOR UPDATE
            USING (
                EXISTS (
                    SELECT 1 FROM finance.transactions t
                    WHERE t.id = finance.%1$I.transaction_id
                    AND t.profile_id = util.current_active_profile_id_internal()
                    AND t.deleted_at IS NULL
                )
                OR util.check_admin_permissions_internal()
            )
            WITH CHECK (
                EXISTS (
                    SELECT 1 FROM finance.transactions t
                    WHERE t.id = finance.%1$I.transaction_id
                    AND t.profile_id = util.current_active_profile_id_internal()
                    AND t.deleted_at IS NULL
                )
                OR util.check_admin_permissions_internal()
            );
        $f$, tbl);

        -- DELETE (only admins, only if parent transaction is soft deleted)
        EXECUTE format($f$
            CREATE POLICY delete_%1$I_combined ON finance.%1$I
            FOR DELETE USING (
                EXISTS (
                    SELECT 1 FROM finance.transactions t
                    WHERE t.id = finance.%1$I.transaction_id
                    AND t.deleted_at IS NOT NULL
                )
                AND util.check_admin_permissions_internal()
            );
        $f$, tbl);
    END LOOP;
END;
$$;

-- =========================================
-- TRANSACTIONS_RECURRING
-- =========================================
ALTER TABLE finance.transactions_recurring ENABLE ROW LEVEL SECURITY;

-- SELECT
CREATE POLICY select_transactions_recurring_combined ON finance.transactions_recurring
    FOR SELECT USING (
        (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL)
        OR util.check_admin_permissions_internal()
    );

-- INSERT
CREATE POLICY insert_transactions_recurring_combined ON finance.transactions_recurring
    FOR INSERT WITH CHECK (
        profile_id = util.current_active_profile_id_internal()
        OR util.check_admin_permissions_internal()
    );

-- UPDATE
CREATE POLICY update_transactions_recurring_combined ON finance.transactions_recurring
    FOR UPDATE
    USING (
        (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL) -- normal updates only
        OR util.check_admin_permissions_internal()
    )
    WITH CHECK (
        (profile_id = util.current_active_profile_id_internal() AND deleted_at IS NULL) -- normal updates only
        OR (profile_id = util.current_active_profile_id_internal())                     -- soft-delete allowed
        OR util.check_admin_permissions_internal()
    );

-- DELETE (only admins, only if soft-deleted)
CREATE POLICY delete_transactions_recurring_combined ON finance.transactions_recurring
    FOR DELETE USING (
        util.check_admin_permissions_internal() AND deleted_at IS NOT NULL
    );

-- =========================================
-- AUDIT LOGS
-- =========================================
ALTER TABLE audit.audit_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_audit_logs_admins ON audit.audit_logs
    FOR SELECT USING (util.check_admin_permissions_internal());

CREATE POLICY insert_audit_logs_admins ON audit.audit_logs
    FOR INSERT WITH CHECK (util.check_admin_permissions_internal());

CREATE POLICY update_audit_logs_admins ON audit.audit_logs
    FOR UPDATE USING (util.check_admin_permissions_internal());

CREATE POLICY delete_audit_logs_admins ON audit.audit_logs
    FOR DELETE USING (util.check_admin_permissions_internal());

-- =========================================
-- API RATE LIMITS
-- =========================================
ALTER TABLE api.api_rate_limits ENABLE ROW LEVEL SECURITY;

-- Users can only select their own rows
CREATE POLICY select_own_api_rate_limits ON api.api_rate_limits
    FOR SELECT USING (profile_id = util.current_active_profile_id_internal());

-- Users can only insert rows for themselves
CREATE POLICY insert_own_api_rate_limits ON api.api_rate_limits
    FOR INSERT WITH CHECK (profile_id = util.current_active_profile_id_internal());

-- Users can only update their own rows
CREATE POLICY update_own_api_rate_limits ON api.api_rate_limits
    FOR UPDATE USING (profile_id = util.current_active_profile_id_internal())
    WITH CHECK (profile_id = util.current_active_profile_id_internal());

-- Admins can only delete rows
CREATE POLICY delete_own_api_rate_limits ON api.api_rate_limits
    FOR DELETE USING (util.check_admin_permissions_internal());

-- =========================================
-- EXCHANGE_RATES RLS
-- =========================================
ALTER TABLE finance.exchange_rates ENABLE ROW LEVEL SECURITY;

-- Everyone can view their own non-deleted rates
CREATE POLICY select_exchange_rates ON finance.exchange_rates
    FOR SELECT
    USING (
        deleted_at IS NULL
        AND (
            profile_id = util.current_active_profile_id_internal()
            OR util.check_admin_permissions_internal()
        )
    );

-- Any authenticated user can insert their own rates
CREATE POLICY insert_exchange_rates ON finance.exchange_rates
    FOR INSERT
    WITH CHECK (
        profile_id = util.current_active_profile_id_internal()
        OR util.check_admin_permissions_internal()
    );

-- Combined update + soft delete policy
CREATE POLICY update_exchange_rates_combined ON finance.exchange_rates
    FOR UPDATE
    USING (
        (
            profile_id = util.current_active_profile_id_internal()
            AND deleted_at IS NULL
        )
        OR util.check_admin_permissions_internal()
    )
    WITH CHECK (
        (
            profile_id = util.current_active_profile_id_internal()
        )
        OR util.check_admin_permissions_internal()
    );

-- Hard delete: only admins, and only if already soft deleted
CREATE POLICY delete_exchange_rates ON finance.exchange_rates
    FOR DELETE
    USING (
        util.check_admin_permissions_internal()
        AND deleted_at IS NOT NULL
    );

-- =========================================
-- AUDIT TABLE REGISTRY
-- =========================================
ALTER TABLE audit.audit_table_registry ENABLE ROW LEVEL SECURITY;

-- Only admins can SELECT
CREATE POLICY select_audit_table_registry_admins
    ON audit.audit_table_registry
    FOR SELECT
    USING (util.check_admin_permissions_internal());

-- Only admins can INSERT
CREATE POLICY insert_audit_table_registry_admins
    ON audit.audit_table_registry
    FOR INSERT
    WITH CHECK (util.check_admin_permissions_internal());

-- Only admins can UPDATE
CREATE POLICY update_audit_table_registry_admins
    ON audit.audit_table_registry
    FOR UPDATE
    USING (util.check_admin_permissions_internal())
    WITH CHECK (util.check_admin_permissions_internal());

-- Only admins can DELETE
CREATE POLICY delete_audit_table_registry_admins
    ON audit.audit_table_registry
    FOR DELETE
    USING (util.check_admin_permissions_internal());
