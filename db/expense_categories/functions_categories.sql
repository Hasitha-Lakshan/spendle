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
