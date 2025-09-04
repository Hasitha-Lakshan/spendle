-- =========================================
-- 01. Trigger Function: cleanup_expense_subcategories
-- =========================================
-- Purpose:
--   Automatically soft deletes all subcategories of an expense category
--   when the parent category is soft deleted. Ensures only the category
--   owner or an admin can trigger this operation.
--
-- Parameters:
--   Triggered automatically BEFORE UPDATE on expense_categories
--   OLD - The existing row before update
--   NEW - The updated row
--
-- Returns:
--   NEW - The updated expense category row
--
-- Notes:
--   - SECURITY DEFINER is used to allow proper permission checks for
--     admins and owners
--   - Only executes when a category is transitioning from not deleted
--     to soft deleted (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
--   - Updates deleted_at and updated_at for all non-deleted subcategories
--   - Ensures RLS and ownership rules are respected
-- =========================================
CREATE OR REPLACE FUNCTION cleanup_expense_subcategories()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current_user UUID;
BEGIN
    v_current_user := auth.uid();

    -- Only run if category was just soft deleted
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        -- Only allow if current user is owner of category or admin
        IF EXISTS (SELECT 1 FROM expense_categories ec
                   WHERE ec.id = OLD.id
                     AND ec.user_id = v_current_user)
           OR public.check_admin_permissions() THEN

            -- Soft delete all subcategories
            UPDATE public.expense_subcategories
            SET deleted_at = NEW.deleted_at,
                updated_at = NOW()
            WHERE category_id = OLD.id
              AND deleted_at IS NULL;

        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cleanup_expense_subcategories
BEFORE UPDATE ON expense_categories
FOR EACH ROW
EXECUTE FUNCTION cleanup_expense_subcategories();
