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
