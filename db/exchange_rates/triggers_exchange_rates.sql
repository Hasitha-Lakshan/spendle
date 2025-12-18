-- =========================================
-- 01. Function: exchange_rate_permission_trigger
-- =========================================
-- Purpose:
--   Enforces row-level permissions for the exchange_rates table by
--   validating ownership and preventing operations on soft-deleted rows.
--   Intended to be used as a trigger on UPDATE or DELETE events.
--
-- Triggered Events:
--   UPDATE, DELETE on exchange_rates
--
-- Behavior:
--   - Raises an exception if an UPDATE or DELETE is attempted on a row
--     that has already been soft-deleted (deleted_at IS NOT NULL)
--   - Raises an exception if the current user (auth.uid()) is not the
--     owner of the row and does not have admin permissions
--   - Allows the operation if the user is the owner or has admin rights
--
-- Notes:
--   - SECURITY DEFINER ensures the trigger executes with the privileges
--     of its owner
--   - Uses public.check_admin_permissions() to allow admin override
--   - Returns NEW for UPDATE operations, allowing the operation to proceed
--   - Prevents accidental or unauthorized modification or deletion of exchange rates
-- =========================================
CREATE OR REPLACE FUNCTION public.exchange_rate_permission_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_hard_delete BOOLEAN := (current_setting('app.hard_delete', true) = 'on');
BEGIN
    -- Skip permission checks if hard delete mode is active
    IF v_hard_delete THEN
        RETURN OLD;
    END IF;

    -- Prevent acting on already soft-deleted rows
    IF OLD.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'Exchange rate % is already deleted', OLD.id
            USING ERRCODE = 'P0002';
    END IF;

    -- Enforce ownership or admin permission
    IF NOT (OLD.user_id = v_user_id OR public.check_admin_permissions()) THEN
        RAISE EXCEPTION 'Permission denied for exchange rate %', OLD.id
            USING ERRCODE = '42501';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        RETURN NEW;
    ELSE
        RETURN OLD;
    END IF;
END;
$$;

-- For updates (e.g., rate, source)
CREATE TRIGGER exchange_rates_before_update
BEFORE UPDATE ON public.exchange_rates
FOR EACH ROW
EXECUTE FUNCTION public.exchange_rate_permission_trigger();

-- For soft deletes (deleted_at)
CREATE TRIGGER exchange_rates_before_delete
BEFORE DELETE ON public.exchange_rates
FOR EACH ROW
EXECUTE FUNCTION public.exchange_rate_permission_trigger();

-- =========================================
-- 02. Function: validate_currency_code
-- =========================================
-- Purpose:
--   Ensures that currency codes in the accounts and exchange_rates tables
--   conform to the ISO 4217 3-letter uppercase standard.
--   Intended to be used as a BEFORE INSERT or BEFORE UPDATE trigger.
--
-- Triggered Events:
--   INSERT, UPDATE on accounts
--   INSERT, UPDATE on exchange_rates
--
-- Behavior:
--   - For accounts:
--       • Validates that the 'currency' field contains exactly three
--         uppercase letters (A–Z).
--       • Raises an exception if the value is invalid.
--   - For exchange_rates:
--       • Validates that 'from_currency' and 'to_currency' are present
--         and match the same 3-letter uppercase format.
--       • Raises an exception if either field is invalid.
--
-- Notes:
--   - Helps maintain data integrity and prevents invalid or malformed
--     currency codes from being stored.
--   - Can be extended to support additional tables or ISO validation logic.
--   - Returns NEW to allow valid rows to be inserted or updated.
-- =========================================
CREATE OR REPLACE FUNCTION public.validate_currency_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    -- Validate accounts table currency
    IF TG_TABLE_NAME = 'accounts' THEN
        IF NEW.currency IS NOT NULL AND NEW.currency !~ '^[A-Z]{3}$' THEN
            RAISE EXCEPTION 'Invalid currency code: %', NEW.currency;
        END IF;
    END IF;

    -- Validate exchange_rates table currencies
    IF TG_TABLE_NAME = 'exchange_rates' THEN
        IF NEW.from_currency IS NULL OR NEW.from_currency !~ '^[A-Z]{3}$' THEN
            RAISE EXCEPTION 'Invalid from_currency code: %', NEW.from_currency;
        END IF;
        IF NEW.to_currency IS NULL OR NEW.to_currency !~ '^[A-Z]{3}$' THEN
            RAISE EXCEPTION 'Invalid to_currency code: %', NEW.to_currency;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- Trigger for accounts table
CREATE TRIGGER trg_validate_account_currency
BEFORE INSERT OR UPDATE ON accounts
FOR EACH ROW
EXECUTE FUNCTION public.validate_currency_code();

-- Trigger for exchange_rates table
CREATE TRIGGER trg_validate_exchange_rate_currency
BEFORE INSERT OR UPDATE ON exchange_rates
FOR EACH ROW
EXECUTE FUNCTION public.validate_currency_code();


-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION public.exchange_rate_permission_trigger()
IS 'Enforces ownership and admin permissions on exchange_rates before UPDATE or DELETE.';

COMMENT ON FUNCTION public.validate_currency_code()
IS $$
Validates currency codes before INSERT or UPDATE on accounts or exchange_rates tables.
For accounts: ensures `currency` is a 3-letter uppercase code (ISO 4217).
For exchange_rates: ensures `from_currency` and `to_currency` are valid 3-letter uppercase codes.
Raises an exception if any currency code is invalid.
$$;

COMMENT ON FUNCTION public.prevent_duplicate_exchange_rate()
IS $$
Prevents duplicate exchange rates for the same user.
Checks before INSERT or UPDATE on exchange_rates:
1. `from_currency` and `to_currency` cannot be the same.
2. A user cannot have more than one active row with the same `from_currency → to_currency` pair.
Raises an exception if the rule is violated.
$$;
