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
GRANT EXECUTE ON FUNCTION public.get_exchange_rate(VARCHAR, VARCHAR) TO authenticated;

-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION public.get_exchange_rate(VARCHAR, VARCHAR)
IS 'Retrieves the most recent exchange rate between two currencies. Both parameters are required and must be valid ISO 4217 codes. Returns 1 if the currencies are identical. Raises an exception if not found.';