-- =========================================
-- 01. Function: create_income_source
-- =========================================
-- Purpose:
--   Creates a new income source for the currently authenticated user.
--   The source name is provided by the caller.
--   Audit logging is handled separately by an AFTER INSERT trigger.
--
-- Parameters:
--   p_name TEXT - The name of the income source to create
--
-- Returns:
--   UUID - The unique ID of the newly created income source
--
-- Notes:
--   - Uses auth.uid() to automatically associate the source with the current user
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on income_sources are respected
--   - Duplicate handling should be enforced at the RLS or application level
-- =========================================
CREATE OR REPLACE FUNCTION public.create_income_source(
    p_name TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_source_id UUID;
BEGIN
    INSERT INTO income_sources (user_id, name)
    VALUES (auth.uid(), p_name)
    RETURNING id INTO v_source_id;

    -- audit handled by AFTER INSERT trigger
    RETURN v_source_id;
END;
$$;

-- =========================================
-- 02. Function: get_income_sources
-- =========================================
-- Purpose:
--   Retrieves all non-deleted income sources for the current user.
--   Returns the data as a structured JSONB array.
--
-- Parameters:
--   None
--
-- Returns:
--   JSONB - An array of income sources, each containing:
--     - id, name, created_at, updated_at
--
-- Notes:
--   - SECURITY INVOKER is used so that RLS policies on income_sources are respected
--   - Soft-deleted sources (deleted_at IS NOT NULL) are excluded
--   - Results are ordered by name
-- =========================================
CREATE OR REPLACE FUNCTION public.get_income_sources()
RETURNS JSONB
LANGUAGE sql
SECURITY INVOKER
AS $$
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', s.id,
            'name', s.name,
            'created_at', s.created_at,
            'updated_at', s.updated_at
        )
        ORDER BY s.name
    )
    FROM public.income_sources s
    WHERE s.deleted_at IS NULL;
$$;

-- =========================================
-- 03. Function: update_income_source
-- =========================================
-- Purpose:
--   Updates the name of an existing, non-deleted income source for the
--   currently authenticated user. Audit logging and timestamp updates
--   are handled by triggers.
--
-- Parameters:
--   p_source_id UUID - The ID of the income source to update
--   p_new_name TEXT  - The new name (optional, pass NULL to keep existing)
--
-- Returns:
--   BOOLEAN - TRUE if the source was updated, FALSE if no matching
--             non-deleted source was found
--
-- Notes:
--   - SECURITY INVOKER ensures RLS policies are respected
--   - Soft-deleted sources cannot be updated
--   - updated_at handled by BEFORE UPDATE trigger
--   - Audit logging handled by AFTER UPDATE trigger
-- =========================================
CREATE OR REPLACE FUNCTION public.update_income_source(
    p_source_id UUID,
    p_new_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
    -- Only update sources that are not soft deleted
    UPDATE income_sources
    SET name = COALESCE(p_new_name, name)
    WHERE id = p_source_id
      AND deleted_at IS NULL;

    -- audit handled by AFTER UPDATE trigger
    RETURN FOUND;
END;
$$;

-- =========================================
-- 04. Function: soft_delete_income_source
-- =========================================
-- Purpose:
--   Soft deletes an income source by marking it as deleted (deleted_at timestamp).
--   The source can only be soft deleted if it belongs to the currently authenticated user
--   or if the caller has admin privileges. Income sources with existing related
--   transactions cannot be soft deleted.
--
-- Parameters:
--   p_source_id UUID - The ID of the income source to soft delete
--
-- Returns:
--   BOOLEAN - TRUE if the soft delete was performed, FALSE if the source was
--             already soft deleted or did not exist
--
-- Notes:
--   - SECURITY DEFINER is used so the function can check permissions and bypass RLS
--     for admin operations.
--   - User ownership is verified using auth.uid().
--   - Admin privileges are checked via public.check_admin_permissions().
--   - Related transactions in transactions_income prevent soft deletion.
--   - Audit logging and enforcement of deleted_at timestamps are handled by triggers.
-- =========================================
CREATE OR REPLACE FUNCTION public.soft_delete_income_source(
    p_source_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_exists BOOLEAN;
BEGIN
    -- Check if the income source exists, belongs to the user, or user is admin
    IF NOT (
        EXISTS (
            SELECT 1
            FROM income_sources
            WHERE id = p_source_id
              AND user_id = v_user_id
              AND deleted_at IS NULL
        )
        OR public.check_admin_permissions()
    ) THEN
        RAISE EXCEPTION 'Permission denied to soft delete income source %', p_source_id
            USING ERRCODE = '42501';
    END IF;

    -- Check for related transactions
    IF EXISTS (
        SELECT 1
        FROM transactions_income
        WHERE source_id = p_source_id
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Cannot soft delete income source %: related transactions exist', p_source_id
            USING ERRCODE = '45000';
    END IF;

    -- Check if source exists and is not already soft deleted
    SELECT true INTO v_exists
    FROM income_sources
    WHERE id = p_source_id
      AND deleted_at IS NULL;

    -- Perform soft delete
    DELETE FROM income_sources
    WHERE id = p_source_id
      AND deleted_at IS NULL;

    RETURN COALESCE(v_exists, false);
END;
$$;

-- =========================================
-- 05. Function: hard_delete_income_source
-- =========================================
-- Purpose:
--   Permanently deletes an income source from the database.
--   Only income sources that have been previously soft deleted
--   can be hard deleted. Related transactions are protected by a
--   BEFORE DELETE trigger and cannot be bypassed.
--
-- Parameters:
--   p_source_id UUID - The ID of the income source to hard delete
--
-- Returns:
--   BOOLEAN - TRUE if the hard delete was successful
--
-- Notes:
--   - SECURITY DEFINER is used to allow the function to bypass
--     RLS for admin operations.
--   - Admin privileges are verified via public.check_admin_permissions().
--   - The function sets a session variable 'app.hard_delete' to
--     bypass soft-delete triggers during deletion.
--   - An exception is raised if the source is not soft deleted,
--     or if the deletion fails for any reason.
--   - Audit logging and integrity checks for related transactions
--     are handled by triggers.
-- =========================================
CREATE OR REPLACE FUNCTION public.hard_delete_income_source(
    p_source_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Only admins can hard delete
    IF NOT public.check_admin_permissions() THEN
        RAISE EXCEPTION 'Only admins can hard delete income sources';
    END IF;

    -- Ensure the source is already soft deleted
    IF NOT EXISTS (
        SELECT 1
        FROM income_sources
        WHERE id = p_source_id
          AND deleted_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Income source % is not soft deleted and cannot be hard deleted', p_source_id
            USING ERRCODE = '45000';
    END IF;

    -- Enable hard delete flag (to bypass soft delete trigger if needed)
    PERFORM set_config('app.hard_delete', 'on', true);

    -- Perform the hard delete
    DELETE FROM income_sources
    WHERE id = p_source_id;

    -- Reset flag
    PERFORM set_config('app.hard_delete', 'off', true);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hard delete failed: source not found';
    END IF;

    RETURN TRUE;
END;
$$;

-- =========================================
-- 06. Function: get_income_sources_summary
-- =========================================
-- Purpose:
--   Returns a JSONB summary of active income sources.
--
-- Parameters:
--   None
--
-- Returns:
--   JSONB - A JSON object containing the number of active (non-deleted)
--           income sources. Example:
--             {
--               "active_income_sources": 5
--             }
--
-- Notes:
--   - SECURITY INVOKER ensures RLS policies are respected
--   - Soft-deleted sources are excluded automatically
-- =========================================
CREATE OR REPLACE FUNCTION public.get_income_sources_summary()
RETURNS JSONB
LANGUAGE sql
SECURITY INVOKER
AS $$
    SELECT jsonb_build_object(
        'active_income_sources', (SELECT COUNT(*) FROM income_sources WHERE deleted_at IS NULL)
    );
$$;
