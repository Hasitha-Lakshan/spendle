-- =========================================
-- 01. Function: create_exchange_rate
-- =========================================
-- Purpose:
--   Creates a new exchange rate for the currently authenticated user.
--   The source, from_currency, to_currency, and rate are provided by the caller.
--   Audit logging can be handled separately by an AFTER INSERT trigger.
--
-- Parameters:
--   p_from_currency VARCHAR - The ISO currency code of the base currency
--   p_to_currency   VARCHAR - The ISO currency code of the target currency
--   p_rate          NUMERIC - The exchange rate from base to target currency (must be > 0)
--   p_source        TEXT    - Optional description or source of the rate (default NULL)
--
-- Returns:
--   UUID - The unique ID of the newly created exchange rate
--
-- Notes:
--   - Uses auth.uid() to automatically associate the exchange rate with
--     the current user
--   - SECURITY INVOKER is used so that row-level security (RLS) policies
--     on the exchange_rates table are respected
--   - Safe to call multiple times; duplicate handling (e.g., same currency pair)
--     should be managed at the application level or by table constraints
-- =========================================
CREATE OR REPLACE FUNCTION public.create_exchange_rate(
    p_from_currency VARCHAR,
    p_to_currency VARCHAR,
    p_rate NUMERIC,
    p_source TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER  -- relies on RLS
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rate_id UUID;
BEGIN
    INSERT INTO public.exchange_rates (user_id, from_currency, to_currency, rate, source)
    VALUES (auth.uid(), p_from_currency, p_to_currency, p_rate, p_source)
    RETURNING id INTO v_rate_id;

    -- audit can be handled by AFTER INSERT trigger if needed
    RETURN v_rate_id;
END;
$$;

-- =========================================
-- 02. Function: update_exchange_rate
-- =========================================
-- Purpose:
--   Updates an existing exchange rate for the currently authenticated user.
--   The rate and optional source can be modified. Only the owner or an admin
--   can update a given exchange rate. Audit logging can be handled separately
--   via triggers if needed.
--
-- Parameters:
--   p_rate_id UUID    - The unique ID of the exchange rate to update
--   p_rate    NUMERIC - The new exchange rate value (must be > 0)
--   p_source  TEXT    - Optional new description or source of the rate (default NULL)
--
-- Returns:
--   UUID - The unique ID of the updated exchange rate
--
-- Notes:
--   - Uses SECURITY INVOKER so that row-level security (RLS) policies on
--     the exchange_rates table are respected
--   - Will raise an exception if the row does not exist or the caller
--     does not have permission to update it
--   - Only affects rows where deleted_at IS NULL (i.e., not soft-deleted)
-- =========================================
CREATE OR REPLACE FUNCTION public.update_exchange_rate(
    p_rate_id UUID,
    p_rate NUMERIC,
    p_source TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER  -- relies on RLS
SET search_path = public, pg_temp
AS $$
DECLARE
    v_updated_id UUID;
BEGIN
    -- Update only rows belonging to the current user (RLS will enforce this)
    UPDATE public.exchange_rates
    SET 
        rate = p_rate,
        source = p_source,
        updated_at = now()
    WHERE id = p_rate_id
    RETURNING id INTO v_updated_id;

    IF v_updated_id IS NULL THEN
        RAISE EXCEPTION 'Exchange rate % not found or not accessible', p_rate_id;
    END IF;

    RETURN v_updated_id;
END;
$$;

-- =========================================
-- 03. Function: soft_delete_exchange_rate
-- =========================================
-- Purpose:
--   Soft deletes an existing exchange rate by setting its deleted_at timestamp.
--   Only the owner of the exchange rate or an admin can perform this operation.
--   Rows that are already soft-deleted cannot be deleted again.
--
-- Parameters:
--   p_rate_id UUID - The unique ID of the exchange rate to soft delete
--
-- Returns:
--   BOOLEAN - TRUE if the exchange rate was successfully soft deleted
--
-- Notes:
--   - SECURITY DEFINER is used to allow the function to check ownership/admin
--     permissions before applying the soft delete
--   - Raises an exception if the row does not exist or is already soft-deleted
--   - Raises a permission exception if the caller is neither the owner nor an admin
--   - Sets updated_at to NOW() when performing the soft delete
-- =========================================
CREATE OR REPLACE FUNCTION public.soft_delete_exchange_rate(
    p_rate_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_exists BOOLEAN;
BEGIN
    -- Check if the row exists and is not already soft-deleted
    SELECT EXISTS (
        SELECT 1
        FROM exchange_rates
        WHERE id = p_rate_id
          AND deleted_at IS NULL
    ) INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'Exchange rate % does not exist or is already deleted', p_rate_id
            USING ERRCODE = 'P0002';
    END IF;

    -- Ownership / admin check
    IF NOT EXISTS (
        SELECT 1
        FROM exchange_rates
        WHERE id = p_rate_id
          AND (user_id = v_user_id OR public.check_admin_permissions())
    ) THEN
        RAISE EXCEPTION 'Permission denied: cannot delete this exchange rate'
            USING ERRCODE = '42501';
    END IF;

    -- Soft delete the exchange rate
    UPDATE exchange_rates
    SET deleted_at = NOW(),
        updated_at = NOW()
    WHERE id = p_rate_id
      AND deleted_at IS NULL;

    RETURN TRUE;
END;
$$;

-- =========================================
-- 04. Function: hard_delete_exchange_rate
-- =========================================
-- Purpose:
--   Permanently deletes a soft-deleted exchange rate from the database.
--   Only users with admin privileges can perform this operation.
--   Ensures that only rows which have been previously soft-deleted (deleted_at IS NOT NULL)
--   are permanently removed.
--
-- Parameters:
--   p_rate_id UUID - The unique ID of the exchange rate to hard delete
--
-- Returns:
--   BOOLEAN - TRUE if the exchange rate was successfully hard deleted
--
-- Notes:
--   - SECURITY DEFINER is used to allow the function to bypass RLS checks for admin operations
--   - Enables the 'app.hard_delete' configuration flag during deletion; this can be used
--     by triggers to handle hard delete logic
--   - Raises an exception if the caller is not an admin
--   - Raises an exception if the row does not exist or is not soft-deleted
--   - Resets the 'app.hard_delete' flag after the operation
-- =========================================
CREATE OR REPLACE FUNCTION public.hard_delete_exchange_rate(
    p_rate_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_deleted_count INT;
BEGIN
    -- Only admins can hard delete
    IF NOT public.check_admin_permissions() THEN
        RAISE EXCEPTION 'Only admins can hard delete exchange rates'
            USING ERRCODE = '42501';
    END IF;

   -- Enable hard delete mode
    PERFORM set_config('app.hard_delete', 'on', true);

    -- Verify row exists and is soft-deleted
    IF NOT EXISTS (
        SELECT 1 FROM exchange_rates WHERE id = p_rate_id
    ) THEN
        RAISE EXCEPTION 'Exchange rate % does not exist', p_rate_id
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM exchange_rates WHERE id = p_rate_id AND deleted_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Exchange rate % is not soft deleted', p_rate_id
            USING ERRCODE = 'P0001';
    END IF;

    -- Hard delete (should succeed if triggers respect app.hard_delete)
    DELETE FROM exchange_rates
    WHERE id = p_rate_id
      AND deleted_at IS NOT NULL
    RETURNING 1 INTO v_deleted_count;

    -- Reset hard delete flag
    PERFORM set_config('app.hard_delete', 'off', true);

    -- Verify delete success
    IF v_deleted_count IS NULL THEN
        RAISE EXCEPTION 'Hard delete failed: row was blocked by RLS or trigger'
            USING ERRCODE = 'P0001';
    END IF;

    RETURN TRUE;
END;
$$;

-- =========================================
-- 05. Function: get_user_exchange_rates
-- =========================================
-- Purpose:
--   Retrieves all active (non-deleted) exchange rates belonging to the
--   currently authenticated user and returns them as a JSONB array.
--   Each element in the array includes key details about the exchange rate.
--
-- Returns:
--   JSONB - A JSON array of the user's active exchange rates. Each element includes:
--     • id (UUID)             - Unique ID of the exchange rate
--     • from_currency (TEXT)  - ISO currency code of the base currency
--     • to_currency (TEXT)    - ISO currency code of the target currency
--     • rate (NUMERIC)        - Exchange rate value
--     • source (TEXT)         - Optional description or rate source
--     • created_at (timestamptz) - Creation timestamp
--     • updated_at (timestamptz) - Last update timestamp
--
-- Notes:
--   - Uses auth.uid() to automatically filter exchange rates for the current user
--   - Excludes soft-deleted rows (deleted_at IS NULL)
--   - Returns an empty JSON array '[]' if the user has no exchange rates
--   - SECURITY INVOKER ensures that row-level security (RLS) policies are respected
-- =========================================
CREATE OR REPLACE FUNCTION public.get_user_exchange_rates()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_rates JSONB;
BEGIN
    SELECT jsonb_agg(
               jsonb_build_object(
                   'id', id,
                   'from_currency', from_currency,
                   'to_currency', to_currency,
                   'rate', rate,
                   'source', source,
                   'created_at', created_at,
                   'updated_at', updated_at
               )
           )
    INTO v_rates
    FROM public.exchange_rates
    WHERE deleted_at IS NULL
      AND user_id = auth.uid();

    -- Return empty array if no rows found
    RETURN COALESCE(v_rates, '[]'::jsonb);
END;
$$;

-- =========================================
-- 06. Function: get_exchange_rate
-- =========================================
-- Purpose:
--   Retrieves the latest active (non-deleted) exchange rate for a specific
--   currency pair (from_currency → to_currency) for the currently authenticated user.
--   If the currencies are identical, returns 1.
--
-- Parameters:
--   p_from_currency (VARCHAR) - ISO currency code of the source/base currency
--   p_to_currency   (VARCHAR) - ISO currency code of the target currency
--
-- Returns:
--   NUMERIC - The latest exchange rate value for the requested currency pair
--
-- Notes:
--   - Raises an exception if either currency parameter is missing or invalid
--   - Normalizes input to uppercase and trims whitespace
--   - Returns 1 if both currencies are identical
--   - Considers only rows where deleted_at IS NULL
--   - Checks that the rate belongs to the current user (auth.uid()) or that the
--     user has admin permissions (via public.check_admin_permissions())
--   - Orders rates by updated_at DESC and picks the latest one
--   - SECURITY DEFINER ensures that the function executes with the privileges
--     of its owner while still respecting RLS for normal users
-- =========================================
CREATE OR REPLACE FUNCTION public.get_exchange_rate(
    p_from_currency VARCHAR,
    p_to_currency VARCHAR
) 
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    -- === Step 1: Ensure parameters are provided ===
    IF p_from_currency IS NULL OR trim(p_from_currency) = '' THEN
        RAISE EXCEPTION 'The source currency is required.';
    END IF;

    IF p_to_currency IS NULL OR trim(p_to_currency) = '' THEN
        RAISE EXCEPTION 'The target currency is required.';
    END IF;

    -- === Step 2: Normalize and validate currency codes ===
    p_from_currency := UPPER(trim(p_from_currency));
    p_to_currency   := UPPER(trim(p_to_currency));

    IF NOT p_from_currency ~ '^[A-Z]{3}$' THEN
        RAISE EXCEPTION 'Invalid currency format: %', p_from_currency;
    END IF;

    IF NOT p_to_currency ~ '^[A-Z]{3}$' THEN
        RAISE EXCEPTION 'Invalid currency format: %', p_to_currency;
    END IF;

    -- === Step 3: Return 1 if currencies are identical ===
    IF p_from_currency = p_to_currency THEN
        RETURN 1;
    END IF;

    -- === Step 4: Fetch the latest exchange rate with user_id check ===
    SELECT rate INTO v_rate
    FROM public.exchange_rates
    WHERE from_currency = p_from_currency
      AND to_currency = p_to_currency
      AND deleted_at IS NULL
      AND (
          user_id = auth.uid()
          OR public.check_admin_permissions()
      )
    ORDER BY updated_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No exchange rate found from % to %', p_from_currency, p_to_currency;
    END IF;

    RETURN v_rate;
END;
$$;


-- ================================
-- Grant Permissions
-- ================================
GRANT EXECUTE ON FUNCTION public.create_exchange_rate(VARCHAR, VARCHAR, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_exchange_rate(UUID, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.soft_delete_exchange_rate(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hard_delete_exchange_rate(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_exchange_rates() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_exchange_rate(VARCHAR, VARCHAR) TO authenticated;


-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION public.create_exchange_rate(VARCHAR, VARCHAR, NUMERIC, TEXT)
IS 'Creates a new exchange rate for the current user. Returns the UUID of the newly created row.';

COMMENT ON FUNCTION public.update_exchange_rate(UUID, NUMERIC, TEXT)
IS 'Updates an existing exchange rate. Users can update their own rates; admins can update any rate. Returns the UUID of the updated row.';

COMMENT ON FUNCTION public.soft_delete_exchange_rate(UUID)
IS 'Soft deletes an exchange rate. Only the owner or admins can delete. Returns TRUE on success.';

COMMENT ON FUNCTION public.hard_delete_exchange_rate(UUID)
IS 'Hard deletes a soft-deleted exchange rate. Admins only. Returns TRUE on success.';

COMMENT ON FUNCTION public.get_user_exchange_rates()
IS 'Returns all non-deleted exchange rates of the current user as a JSONB array.';

COMMENT ON FUNCTION public.get_exchange_rate(VARCHAR, VARCHAR)
IS 'Retrieves the most recent exchange rate between two currencies. Both parameters are required and must be valid ISO 4217 codes. Returns 1 if the currencies are identical. Raises an exception if not found.';