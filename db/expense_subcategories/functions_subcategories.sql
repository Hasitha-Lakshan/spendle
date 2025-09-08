-- =========================================
-- 01. Function: create_expense_subcategory
-- =========================================
-- Purpose:
--   Creates a new expense subcategory under a specified expense category.
--   Associates the subcategory with the given category ID. Audit logging
--   is handled separately by an AFTER INSERT trigger.
--
-- Parameters:
--   p_category_id UUID - The ID of the parent expense category
--   p_name TEXT        - The name of the subcategory to create
--
-- Returns:
--   UUID - The unique ID of the newly created expense subcategory
--
-- Notes:
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on expense_subcategories are respected
--   - Audit logging for creation is automatically handled by triggers
--   - Safe to call multiple times; duplicate handling should be managed
--     at the application or RLS level if needed
-- =========================================
CREATE OR REPLACE FUNCTION public.create_expense_subcategory(
    p_category_id UUID,
    p_name TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_subcategory_id UUID;
BEGIN
    INSERT INTO public.expense_subcategories (category_id, name)
    VALUES (p_category_id, p_name)
    RETURNING id INTO v_subcategory_id;

    -- audit handled by AFTER INSERT trigger
    RETURN v_subcategory_id;
END;
$$;

-- =========================================
-- 02. Function: update_expense_subcategory
-- =========================================
-- Purpose:
--   Updates the name of an existing, non-deleted expense subcategory.
--   Audit logging is handled separately by an AFTER UPDATE trigger.
--
-- Parameters:
--   p_subcategory_id UUID - The ID of the expense subcategory to update
--   p_new_name TEXT       - The new name to assign to the subcategory
--
-- Returns:
--   BOOLEAN - TRUE if the subcategory was updated, FALSE if no matching
--             non-deleted subcategory was found
--
-- Notes:
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on expense_subcategories are respected
--   - Soft-deleted subcategories (deleted_at IS NOT NULL) cannot be updated
--   - Audit logging is handled by an AFTER UPDATE trigger
-- =========================================
CREATE OR REPLACE FUNCTION public.update_expense_subcategory(
    p_subcategory_id UUID,
    p_new_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
    -- Only update subcategories that are not soft deleted
    UPDATE public.expense_subcategories
    SET name = COALESCE(p_new_name, name)
    WHERE id = p_subcategory_id
      AND deleted_at IS NULL;

    -- audit handled by AFTER UPDATE trigger
    RETURN FOUND;
END;
$$;

-- =========================================
-- 03. Function: soft_delete_expense_subcategory
-- =========================================
-- Purpose:
--   Soft deletes an expense subcategory by setting deleted_at and
--   updated_at timestamps. Audit logging is handled separately by a
--   trigger.
--
-- Parameters:
--   p_subcategory_id UUID - The ID of the expense subcategory to soft delete
--
-- Returns:
--   BOOLEAN - TRUE if the subcategory was successfully soft deleted,
--             FALSE if it was already deleted or not found
--
-- Notes:
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on expense_subcategories are respected
--   - Only subcategories that are not already soft deleted are updated
--   - Audit logging is handled by an AFTER DELETE trigger
-- =========================================
CREATE OR REPLACE FUNCTION public.soft_delete_expense_subcategory(
    p_subcategory_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
    -- Only soft delete subcategory that is not already deleted
    UPDATE public.expense_subcategories
    SET deleted_at = NOW(),
        updated_at = NOW()
    WHERE id = p_subcategory_id
      AND deleted_at IS NULL;

    -- audit handled by AFTER DELETE trigger
    RETURN FOUND;
END;
$$;

-- =========================================
-- 04. Function: hard_delete_expense_subcategory
-- =========================================
-- Purpose:
--   Permanently deletes a soft-deleted expense subcategory. Only admins
--   are allowed to perform this operation.
--
-- Parameters:
--   p_subcategory_id UUID - The ID of the soft-deleted subcategory to permanently delete
--
-- Returns:
--   BOOLEAN - TRUE if the subcategory was successfully hard deleted
--
-- Notes:
--   - SECURITY DEFINER is used to allow admin-only deletion
--   - Admin privileges are verified using check_admin_permissions()
--   - Sets app.hard_delete flag ON to enable triggers or logic that
--     depend on hard delete mode, and resets it OFF afterwards
--   - Only soft-deleted subcategories (deleted_at IS NOT NULL) are eligible
--     for permanent deletion
--   - Raises an exception if the subcategory was not found or not soft-deleted
-- =========================================
CREATE OR REPLACE FUNCTION public.hard_delete_expense_subcategory(
    p_subcategory_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_deleted_count INT;
BEGIN
    IF NOT public.check_admin_permissions() THEN
        RAISE EXCEPTION 'Only admins can hard delete expense subcategories'
            USING ERRCODE = '42501';
    END IF;

    PERFORM set_config('app.hard_delete', 'on', true);

    DELETE FROM expense_subcategories
    WHERE id = p_subcategory_id
      AND deleted_at IS NOT NULL
    RETURNING 1 INTO v_deleted_count;

    PERFORM set_config('app.hard_delete', 'off', true);

    IF v_deleted_count IS NULL THEN
        RAISE EXCEPTION 'Hard delete failed: subcategory not found or not soft deleted';
    END IF;

    RETURN TRUE;
END;
$$;
