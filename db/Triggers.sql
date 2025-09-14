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

GRANT EXECUTE ON FUNCTION enforce_counterparty_unique() TO authenticated;
GRANT EXECUTE ON FUNCTION setup_recurring_transaction() TO authenticated;
GRANT EXECUTE ON FUNCTION process_recurring_transactions() TO authenticated;
GRANT EXECUTE ON FUNCTION validate_subcategory_ownership() TO authenticated;



-- ======================================================
-- END OF TRIGGERS AND FUNCTIONS
-- ======================================================