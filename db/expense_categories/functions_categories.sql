-- =========================================
-- 01. Function: create_expense_category
-- =========================================
-- Purpose:
--   Creates a new expense category for the currently authenticated user.
--   The category name is provided by the caller. Audit logging is handled
--   separately by an AFTER INSERT trigger.
--
-- Parameters:
--   p_name TEXT - The name of the expense category to create
--
-- Returns:
--   UUID - The unique ID of the newly created expense category
--
-- Notes:
--   - Uses auth.uid() to automatically associate the category with the
--     current user
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on the expense_categories table are respected
--   - Safe to call multiple times; duplicate handling should be managed
--     at the application or RLS level if needed
-- =========================================
CREATE OR REPLACE FUNCTION public.create_expense_category(
    p_name TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER  -- relies on RLS
AS $$
DECLARE
    v_category_id UUID;
BEGIN
    INSERT INTO expense_categories (user_id, name)
    VALUES (auth.uid(), p_name)
    RETURNING id INTO v_category_id;

    -- audit handled by AFTER INSERT trigger
    RETURN v_category_id;
END;
$$;

-- =========================================
-- 02. Function: get_expense_categories_with_subcategories
-- =========================================
-- Purpose:
--   Retrieves all non-deleted expense categories along with their
--   associated subcategories for the current user.
--   Returns the data as a structured JSONB array.
--
-- Parameters:
--   None
--
-- Returns:
--   JSONB - An array of expense categories, each containing:
--     - id, name, created_at, updated_at
--     - subcategories: array of JSON objects with id, name, created_at, updated_at
--
-- Notes:
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on expense_categories and expense_subcategories are respected
--   - Subcategories with deleted_at IS NOT NULL are excluded
--   - Returns an empty array for categories without subcategories
--   - Results are ordered by category name and subcategory name
-- =========================================
CREATE OR REPLACE FUNCTION public.get_expense_categories_with_subcategories()
RETURNS JSONB
LANGUAGE sql
SECURITY INVOKER  -- respects RLS
AS $$
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', c.id,
            'name', c.name,
            'created_at', c.created_at,
            'updated_at', c.updated_at,
            'subcategories', COALESCE(
                (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'id', sc.id,
                            'name', sc.name,
                            'created_at', sc.created_at,
                            'updated_at', sc.updated_at
                        )
                        ORDER BY sc.name
                    )
                    FROM public.expense_subcategories sc
                    WHERE sc.category_id = c.id
                      AND sc.deleted_at IS NULL
                ), '[]'::jsonb
            )
        )
        ORDER BY c.name
    )
    FROM public.expense_categories c
    WHERE c.deleted_at IS NULL;
$$;

-- =========================================
-- 03. Function: update_expense_category
-- =========================================
-- Purpose:
--   Updates the name of an existing, non-deleted expense category
--   for the currently authenticated user. Audit logging and timestamp
--   updates are handled by triggers.
--
-- Parameters:
--   p_category_id UUID - The ID of the expense category to update
--   p_new_name TEXT    - The new name to assign to the category
--
-- Returns:
--   BOOLEAN - TRUE if the category was updated, FALSE if no matching
--             non-deleted category was found
--
-- Notes:
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on expense_categories are respected
--   - Soft-deleted categories (deleted_at IS NOT NULL) cannot be updated
--   - Audit logging is handled by an AFTER UPDATE trigger
--   - updated_at timestamp is handled automatically by a BEFORE UPDATE trigger
-- =========================================
CREATE OR REPLACE FUNCTION public.update_expense_category(
    p_category_id UUID,
    p_new_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER  -- relies on RLS
AS $$
BEGIN
    -- Only update categories that are not soft deleted
    UPDATE expense_categories
    SET name = COALESCE(p_new_name, name)
    WHERE id = p_category_id
      AND deleted_at IS NULL;

    -- audit handled by AFTER UPDATE trigger
    -- updated_at handled by BEFORE UPDATE trigger
    RETURN FOUND;
END;
$$;

-- =========================================
-- 04. Function: soft_delete_expense_category
-- =========================================
-- Purpose:
--   Soft deletes an expense category for the current user or an admin.
--   Prevents deletion if any subcategory has associated transactions.
--   Also triggers automatic soft deletion of related subcategories.
--
-- Parameters:
--   p_category_id UUID - The ID of the expense category to soft delete
--
-- Returns:
--   BOOLEAN - TRUE if the category was successfully soft deleted,
--             FALSE if no matching non-deleted category was found
--
-- Notes:
--   - SECURITY DEFINER is used to allow admin override while enforcing
--     ownership and RLS for normal users
--   - Ownership or admin privileges are verified before deletion
--   - Categories with subcategories that have transactions cannot be deleted
--   - Audit logging and automatic subcategory soft deletion are handled
--     by triggers
--   - updated_at timestamp is updated during the operation
-- =========================================
CREATE OR REPLACE FUNCTION public.soft_delete_expense_category(
    p_category_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rows INT;
    v_subcategory_count INT;
    v_user_id UUID;
BEGIN
    -- Get current user
    v_user_id := auth.uid();

    -- Ownership / admin check
    IF NOT (
        EXISTS (
            SELECT 1
            FROM expense_categories ec
            WHERE ec.id = p_category_id
              AND ec.user_id = v_user_id
              AND ec.deleted_at IS NULL
        )
        OR public.check_admin_permissions()
    ) THEN
        RAISE EXCEPTION 'Permission denied: cannot delete this expense category'
            USING ERRCODE = '42501';
    END IF;

    -- Check if any subcategory has transactions
    SELECT COUNT(*)
    INTO v_subcategory_count
    FROM expense_subcategories sc
    JOIN transactions_expense te ON te.category_id = sc.id
    WHERE sc.category_id = p_category_id
      AND sc.deleted_at IS NULL
      AND te.deleted_at IS NULL;

    IF v_subcategory_count > 0 THEN
        RAISE EXCEPTION 'Cannot delete category: one or more subcategories have transactions';
    END IF;

    -- Soft delete the category itself
    -- Trigger will automatically soft delete subcategories
    UPDATE expense_categories
    SET deleted_at = NOW(),
        updated_at = NOW()
    WHERE id = p_category_id
      AND deleted_at IS NULL
    RETURNING 1 INTO v_rows;

    -- Return TRUE if category was soft deleted
    RETURN v_rows IS NOT NULL;
END;
$$;

-- =========================================
-- 05. Function: hard_delete_expense_category
-- =========================================
-- Purpose:
--   Permanently deletes a soft-deleted expense category and its
--   associated subcategories. Only admins are allowed to perform
--   this operation.
--
-- Parameters:
--   p_category_id UUID - The ID of the soft-deleted expense category to permanently delete
--
-- Returns:
--   BOOLEAN - TRUE if the category and its subcategories were successfully deleted
--
-- Notes:
--   - SECURITY DEFINER is used to allow admin-only deletion
--   - Admin privileges are verified using check_admin_permissions()
--   - Sets app.hard_delete flag ON to enable triggers or logic that
--     depend on hard delete mode, and resets it OFF afterwards
--   - Only soft-deleted subcategories and categories (deleted_at IS NOT NULL)
--     are eligible for permanent deletion
--   - Raises an exception if the category was not found or not soft-deleted
-- =========================================
CREATE OR REPLACE FUNCTION public.hard_delete_expense_category(
    p_category_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_deleted_count INT;
BEGIN
    -- Check admin
    IF NOT public.check_admin_permissions() THEN
        RAISE EXCEPTION 'Only admins can hard delete expense categories'
            USING ERRCODE = '42501';
    END IF;

    -- Enable hard delete mode
    PERFORM set_config('app.hard_delete', 'on', true);

    -- Delete soft-deleted subcategories
    DELETE FROM expense_subcategories
    WHERE category_id = p_category_id
      AND deleted_at IS NOT NULL;

    -- Delete the category itself and capture affected rows
    DELETE FROM expense_categories
    WHERE id = p_category_id
      AND deleted_at IS NOT NULL
    RETURNING 1 INTO v_deleted_count;

    -- Reset flag
    PERFORM set_config('app.hard_delete', 'off', true);

    -- Raise error if nothing was deleted
    IF v_deleted_count IS NULL THEN
        RAISE EXCEPTION 'Hard delete failed: category not found or not soft deleted';
    END IF;

    RETURN TRUE;
END;
$$;

-- =========================================
-- 06. Function: get_expense_types_summary
-- =========================================
-- Purpose:
--   Returns a summary of expense categories and subcategories for the
--   current user, counting only non-deleted (active) entries.
--
-- Parameters:
--   None
--
-- Returns:
--   JSONB - An object containing:
--     - active_categories: count of non-deleted expense categories
--     - active_subcategories: count of non-deleted expense subcategories
--
-- Notes:
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on expense_categories and expense_subcategories are respected
--   - Only entries with deleted_at IS NULL are counted
--   - Useful for dashboards or quick summaries of the user's expense types
-- =========================================
CREATE OR REPLACE FUNCTION public.get_expense_types_summary()
RETURNS JSONB
LANGUAGE sql
SECURITY INVOKER  -- respects RLS
AS $$
    SELECT jsonb_build_object(
        'active_categories', (SELECT COUNT(*) FROM expense_categories WHERE deleted_at IS NULL),
        'active_subcategories', (SELECT COUNT(*) FROM expense_subcategories WHERE deleted_at IS NULL)
    );
$$;
