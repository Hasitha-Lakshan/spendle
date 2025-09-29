CREATE OR REPLACE FUNCTION public.get_exchange_rate(
    p_from_currency VARCHAR,
    p_to_currency VARCHAR
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_from_currency = p_to_currency THEN
        RETURN 1; -- No conversion needed
    END IF;

    SELECT rate INTO v_rate
    FROM public.exchange_rates
    WHERE from_currency = p_from_currency
      AND to_currency = p_to_currency
    ORDER BY updated_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No exchange rate found from % to %', p_from_currency, p_to_currency;
    END IF;

    RETURN v_rate;
END;
$$;
