-- ================================
-- Spendle: Consolidated Functions
-- ================================
-- This file contains all client-invokable and helper functions for the Spendle application.
-- Updated to align with the new schema that uses:
-- - Normalized transaction structure with base transactions + detail tables
-- - Specialized account tables with proper balance fields
-- - Comprehensive RLS policies and triggers
-- - New recurring transaction system
-- ================================



-- ================================
-- 1. Transaction Analysis Functions
-- ================================



-- ================================
-- 3. Transaction Creation Functions
-- ================================



-- ================================
-- 4. Transfer Functions
-- ================================



-- ================================
-- 4. Recurring Transaction Functions
-- ================================









-- ================================
-- 6. Administrative Functions
-- ================================





-- =========================================
-- 9. REPORTING & DASHBOARD FUNCTIONS
-- =========================================

-- Get User Account Summary
-- Purpose: Provide summary stats by account type for the current user, 
--          including count and total balance grouped by type/currency.
-- Parameters: None
-- Returns: TABLE(account_type, account_count, total_balance, currency)
-- Security: DEFINER (executes with elevated rights but enforces user scope)
-- RLS: Only includes accounts owned by current user
CREATE OR REPLACE FUNCTION get_user_account_summary()
RETURNS TABLE(
    account_type account_type,
    account_count BIGINT,
    total_balance DECIMAL(36,18),
    currency VARCHAR(10)
) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current_user UUID;
BEGIN
    v_current_user := auth.uid();
    
    RETURN QUERY
    SELECT 
        a.type AS account_type,
        COUNT(*) AS account_count,
        SUM(vab.current_balance) AS total_balance,
        a.currency
    FROM accounts a
    JOIN v_account_balances vab ON a.id = vab.account_id
    WHERE a.user_id = v_current_user  -- RLS check
    AND a.deleted_at IS NULL
    GROUP BY a.type, a.currency
    ORDER BY a.type, a.currency;
END;
$$;




-- =========================================
-- 11. SCHEDULED PROCESSING FUNCTIONS
-- =========================================



-- =========================================
-- 3. UTILITY FUNCTIONS
-- =========================================

-- Get User's Default Currency
CREATE OR REPLACE FUNCTION get_user_default_currency(p_user_id UUID DEFAULT NULL)
RETURNS VARCHAR(10)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
DECLARE
    v_user_id UUID;
    v_currency VARCHAR(10);
BEGIN
    v_user_id := COALESCE(p_user_id, auth.uid());
    
    -- Get most commonly used currency by this user
    SELECT currency INTO v_currency
    FROM accounts 
    WHERE user_id = v_user_id AND deleted_at IS NULL
    GROUP BY currency 
    ORDER BY COUNT(*) DESC 
    LIMIT 1;
    
    RETURN COALESCE(v_currency, 'USD');
END;
$$;





-- Format Currency Amount
CREATE OR REPLACE FUNCTION format_currency_amount(
    p_amount DECIMAL(36,18),
    p_currency VARCHAR(10) DEFAULT 'USD'
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
    RETURN CASE p_currency
        WHEN 'USD' THEN '$' || TO_CHAR(p_amount, 'FM999,999,999,990.00')
        WHEN 'EUR' THEN '€' || TO_CHAR(p_amount, 'FM999,999,999,990.00')
        WHEN 'GBP' THEN '£' || TO_CHAR(p_amount, 'FM999,999,999,990.00')
        WHEN 'JPY' THEN '¥' || TO_CHAR(p_amount, 'FM999,999,999,990')
        WHEN 'LKR' THEN 'Rs. ' || TO_CHAR(p_amount, 'FM999,999,999,990.00')
        WHEN 'BTC' THEN TO_CHAR(p_amount, 'FM0.00000000') || ' BTC'
        WHEN 'ETH' THEN TO_CHAR(p_amount, 'FM0.000000') || ' ETH'
        ELSE TO_CHAR(p_amount, 'FM999,999,999,990.00') || ' ' || p_currency
    END;
END;
$$;

-- =========================================
-- 4. PERFORMANCE MONITORING FUNCTIONS
-- =========================================

-- Get Database Statistics
CREATE OR REPLACE FUNCTION get_user_database_stats(p_user_id UUID DEFAULT NULL)
RETURNS TABLE(
    user_id UUID,
    total_accounts INTEGER,
    total_transactions INTEGER,
    total_categories INTEGER,
    total_income_sources INTEGER,
    total_counterparties INTEGER,
    active_recurring_schedules INTEGER,
    last_transaction_date TIMESTAMPTZ,
    account_creation_date TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
STABLE
AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := COALESCE(p_user_id, auth.uid());
    
    RETURN QUERY
    SELECT 
        v_user_id,
        (SELECT COUNT(*)::INTEGER FROM accounts WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT COUNT(*)::INTEGER FROM transactions WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT COUNT(*)::INTEGER FROM expense_categories WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT COUNT(*)::INTEGER FROM income_sources WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT COUNT(*)::INTEGER FROM counterparties WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT COUNT(*)::INTEGER FROM transactions_recurring WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT MAX(created_at) FROM transactions WHERE user_id = v_user_id AND deleted_at IS NULL),
        (SELECT created_at FROM profiles WHERE user_id = v_user_id AND deleted_at IS NULL);
END;
$$;







-- Hard delete user profile and ALL associated data (admin only)
CREATE OR REPLACE FUNCTION hard_delete_user_profile(target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    current_user_id UUID;
    is_admin BOOLEAN;
    account_ids UUID[];
    account_id UUID;
BEGIN
    current_user_id := auth.uid();
    
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    
    -- Only admins can delete user profiles
    is_admin := check_admin_permissions();
    IF NOT is_admin THEN
        RAISE EXCEPTION 'Admin permissions required';
    END IF;
    
    -- Prevent self-deletion
    IF current_user_id = target_user_id THEN
        RAISE EXCEPTION 'Cannot delete your own profile';
    END IF;
    
    -- Get all account IDs for this user
    SELECT ARRAY(SELECT id FROM accounts WHERE user_id = target_user_id) INTO account_ids;
    
    -- Delete all accounts (this will cascade to transactions)
    FOREACH account_id IN ARRAY account_ids LOOP
        PERFORM hard_delete_account(account_id);
    END LOOP;
    
    -- Delete remaining user data
    DELETE FROM transactions_recurring WHERE user_id = target_user_id;
    DELETE FROM expense_subcategories WHERE category_id IN (
        SELECT id FROM expense_categories WHERE user_id = target_user_id
    );
    DELETE FROM expense_categories WHERE user_id = target_user_id;
    DELETE FROM income_sources WHERE user_id = target_user_id;
    DELETE FROM counterparties WHERE user_id = target_user_id;
    DELETE FROM api_rate_limits WHERE user_id = target_user_id;
    
    -- Delete the profile last
    DELETE FROM profiles WHERE user_id = target_user_id;
    
    RETURN TRUE;
END;
$$;

-- Specific hard delete functions for common operations







-- ================================
-- Grant Permissions
-- ================================

-- Grant execute permissions to authenticated users for client-facing functions
GRANT EXECUTE ON FUNCTION get_user_account_summary() TO authenticated;
GRANT EXECUTE ON FUNCTION check_admin_permissions() TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_default_currency(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION format_currency_amount(DECIMAL, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_database_stats(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION cleanup_old_rate_limits() TO authenticated;

-- ================================
-- Function Documentation
-- ================================
















COMMENT ON FUNCTION get_user_account_summary() IS 'RLS-compliant user account summary';



COMMENT ON FUNCTION get_user_default_currency(UUID) IS 'Get most commonly used currency for user';



-- ================================
-- END OF FUNCTIONS
-- ================================