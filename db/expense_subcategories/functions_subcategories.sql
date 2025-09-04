CREATE OR REPLACE FUNCTION public.create_expense_subcategory(
    p_category_id UUID,
    p_name TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_subcategory_id UUID;
BEGIN
    INSERT INTO expense_subcategories (category_id, name)
    VALUES (p_category_id, p_name)
    RETURNING id INTO v_subcategory_id;

    -- audit handled by AFTER INSERT trigger
    RETURN v_subcategory_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_expense_subcategory(
    p_subcategory_id UUID,
    p_new_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
    -- Only update subcategories that are not soft deleted
    UPDATE expense_subcategories
    SET name = COALESCE(p_new_name, name)
    WHERE id = p_subcategory_id
      AND deleted_at IS NULL;

    -- audit handled by AFTER UPDATE trigger
    RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.soft_delete_expense_subcategory(
    p_subcategory_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
    -- Only soft delete subcategory that is not already deleted
    UPDATE expense_subcategories
    SET deleted_at = NOW(),
        updated_at = NOW()
    WHERE id = p_subcategory_id
      AND deleted_at IS NULL;

    -- audit handled by AFTER DELETE trigger
    RETURN FOUND;
END;
$$;

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
