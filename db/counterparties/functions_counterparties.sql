-- =========================================
-- 01. Function: create_counterparty
-- =========================================
-- Purpose:
--   Creates a new counterparty for the currently authenticated user.
--   The counterparty name and type are provided by the caller.
--   Audit logging is handled separately by an AFTER INSERT trigger.
--
-- Parameters:
--   p_name TEXT              - The name of the counterparty to create
--   p_type counterparty_type - The type of the counterparty (e.g. supplier, customer)
--
-- Returns:
--   UUID - The unique ID of the newly created counterparty
--
-- Notes:
--   - Uses auth.uid() to automatically associate the counterparty with the
--     current user
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on counterparties are respected
--   - Duplicate handling should be enforced at the RLS or application level
-- =========================================
CREATE OR REPLACE FUNCTION public.create_counterparty(
    p_name TEXT,
    p_type counterparty_type
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_counterparty_id UUID;
BEGIN
    INSERT INTO counterparties (user_id, name, type)
    VALUES (auth.uid(), p_name, p_type)
    RETURNING id INTO v_counterparty_id;

    -- audit handled by AFTER INSERT trigger
    RETURN v_counterparty_id;
END;
$$;

-- =========================================
-- 02. Function: get_counterparties
-- =========================================
-- Purpose:
--   Retrieves all non-deleted counterparties for the current user.
--   Returns the data as a structured JSONB array.
--
-- Parameters:
--   None
--
-- Returns:
--   JSONB - An array of counterparties, each containing:
--     - id, name, type, created_at, updated_at
--
-- Notes:
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on counterparties are respected
--   - Soft-deleted counterparties (deleted_at IS NOT NULL) are excluded
--   - Results are ordered by name
-- =========================================
CREATE OR REPLACE FUNCTION public.get_counterparties()
RETURNS JSONB
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', c.id,
            'name', c.name,
            'type', c.type,
            'created_at', c.created_at,
            'updated_at', c.updated_at
        )
        ORDER BY c.name
    )
    FROM public.counterparties c
    WHERE c.deleted_at IS NULL;
$$;

-- =========================================
-- 03. Function: update_counterparty
-- =========================================
-- Purpose:
--   Updates the name and/or type of an existing, non-deleted counterparty
--   for the currently authenticated user. Audit logging and timestamp
--   updates are handled by triggers.
--
-- Parameters:
--   p_counterparty_id UUID      - The ID of the counterparty to update
--   p_new_name TEXT             - The new name (optional, pass NULL to keep existing)
--   p_new_type counterparty_type- The new type (optional, pass NULL to keep existing)
--
-- Returns:
--   BOOLEAN - TRUE if the counterparty was updated, FALSE if no matching
--             non-deleted counterparty was found
--
-- Notes:
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on counterparties are respected
--   - Soft-deleted counterparties cannot be updated
--   - updated_at handled by BEFORE UPDATE trigger
--   - Audit logging handled by AFTER UPDATE trigger
-- =========================================
CREATE OR REPLACE FUNCTION public.update_counterparty(
    p_counterparty_id UUID,
    p_new_name TEXT,
    p_new_type counterparty_type
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
    -- Only update counterparties that are not soft deleted
    UPDATE counterparties
    SET
        name = COALESCE(p_new_name, name),
        type = COALESCE(p_new_type, type)
    WHERE id = p_counterparty_id
      AND deleted_at IS NULL;

    -- audit handled by AFTER UPDATE trigger
    RETURN FOUND;
END;
$$;

-- =========================================
-- 04. Function: soft_delete_counterparty
-- =========================================
-- Purpose:
--   Performs a soft delete of a counterparty by setting its deleted_at timestamp
--   (via triggers) instead of physically removing the row from the table.
--   Ensures that only the owner of the counterparty or an admin can perform
--   the soft delete.
--
-- Parameters:
--   p_counterparty_id UUID - The unique ID of the counterparty to soft delete
--
-- Returns:
--   BOOLEAN - TRUE if the counterparty existed and was soft-deleted,
--             FALSE if the counterparty did not exist or was already deleted.
--
-- Notes:
--   - SECURITY DEFINER is used to allow the function to bypass RLS for
--     permission checking while still enforcing ownership/admin validation.
--   - Ownership is validated against auth.uid() and admin status is checked
--     via public.check_admin_permissions().
--   - Actual soft delete is enforced by the BEFORE DELETE trigger on
--     the counterparties table.
CREATE OR REPLACE FUNCTION public.soft_delete_counterparty(
    p_counterparty_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
    v_exists BOOLEAN;
BEGIN
    v_user_id := auth.uid();

    -- Ownership / admin check
    IF NOT (
        EXISTS (
            SELECT 1
            FROM counterparties c
            WHERE c.id = p_counterparty_id
              AND c.user_id = v_user_id
              AND c.deleted_at IS NULL
        )
        OR public.check_admin_permissions()
    ) THEN
        RAISE EXCEPTION 'Permission denied: cannot delete this counterparty'
            USING ERRCODE = '42501';
    END IF;

    -- Check if row exists before delete
    SELECT true INTO v_exists
    FROM counterparties
    WHERE id = p_counterparty_id
      AND deleted_at IS NULL;

    DELETE FROM counterparties
    WHERE id = p_counterparty_id
      AND deleted_at IS NULL;

    RETURN COALESCE(v_exists, false);
END;
$$;

-- =========================================
-- 05. Function: hard_delete_counterparty
-- =========================================
-- Purpose:
--   Permanently deletes a soft-deleted counterparty.
--   Only admins are allowed to perform this operation.
--
-- Parameters:
--   p_counterparty_id UUID - The ID of the counterparty to permanently delete
--
-- Returns:
--   BOOLEAN - TRUE if the counterparty was successfully deleted,
--             FALSE if no matching soft-deleted counterparty was found
--
-- Notes:
--   - SECURITY DEFINER is used to allow admin-only deletion
--   - Admin privileges are verified using check_admin_permissions()
--   - Sets app.hard_delete flag ON to bypass soft delete enforcement
--   - Only counterparties with deleted_at IS NOT NULL can be deleted
--   - Raises an exception if no matching soft-deleted counterparty is found
-- =========================================
CREATE OR REPLACE FUNCTION public.hard_delete_counterparty(
    p_counterparty_id UUID
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
        RAISE EXCEPTION 'Only admins can hard delete counterparties'
            USING ERRCODE = '42501';
    END IF;

    -- Enable hard delete mode
    PERFORM set_config('app.hard_delete', 'on', true);

    -- Delete soft-deleted counterparty
    DELETE FROM counterparties
    WHERE id = p_counterparty_id
      AND deleted_at IS NOT NULL
    RETURNING 1 INTO v_deleted_count;

    -- Reset flag
    PERFORM set_config('app.hard_delete', 'off', true);

    IF v_deleted_count IS NULL THEN
        RAISE EXCEPTION 'Hard delete failed: counterparty not found or not soft deleted';
    END IF;

    RETURN TRUE;
END;
$$;

-- =========================================
-- 06. Function: get_counterparty_summary
-- =========================================
-- Purpose:
--   Returns a JSONB summary of active counterparties grouped by type.
--   Only counterparties that have not been soft-deleted (deleted_at IS NULL)
--   are included in the summary.
--
-- Parameters:
--   None
--
-- Returns:
--   JSONB - A JSON object mapping each counterparty type (as text) to
--           the number of active counterparties of that type.
--           Example:
--             {
--               "person": 5,
--               "company": 3,
--               "merchant": 2,
--               "bank": 1
--             }
--
-- Notes:
--   - SECURITY INVOKER ensures that row-level security (RLS) policies
--     on the counterparties table are respected.
--   - Soft-deleted counterparties are excluded automatically by the
--     WHERE deleted_at IS NULL clause.
-- =========================================
CREATE OR REPLACE FUNCTION public.get_counterparty_summary()
RETURNS JSONB
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_object_agg(type, count)::jsonb
    FROM (
        SELECT type::text, COUNT(*) AS count
        FROM public.counterparties
        WHERE deleted_at IS NULL
        GROUP BY type
    ) t;
$$;
