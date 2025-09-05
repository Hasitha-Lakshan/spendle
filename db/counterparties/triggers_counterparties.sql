-- =========================================
-- 01. Function: prevent_invalid_counterparty_hard_delete
-- =========================================
-- Purpose:
--   Prevents hard deletion of a counterparty if it has related borrow or lend
--   transactions. Ensures data integrity by enforcing that such counterparties
--   can only be soft-deleted.
--
-- Trigger:
--   trg_prevent_invalid_counterparty_hard_delete
--   - Fired BEFORE DELETE on counterparties
--   - Executes FOR EACH ROW to check individual counterparty rows
--
-- Notes:
--   - Raises an exception with ERRCODE '45000' if related transactions exist.
--   - Ensures referential integrity and prevents orphaned transaction records.
--   - Works in conjunction with soft-delete logic to safely remove counterparties.
-- =========================================
CREATE OR REPLACE FUNCTION prevent_invalid_counterparty_hard_delete()
RETURNS trigger AS $$
BEGIN
  -- If counterparty has related borrow or lend transactions → forbid hard delete
  IF EXISTS (SELECT 1 FROM transactions_borrow WHERE counterparty_id = OLD.id)
     OR EXISTS (SELECT 1 FROM transactions_lend WHERE counterparty_id = OLD.id) THEN
    RAISE EXCEPTION 'Counterparty % has related transactions and can only be soft-deleted', OLD.id
      USING ERRCODE = '45000';
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_invalid_counterparty_hard_delete
  BEFORE DELETE ON counterparties
  FOR EACH ROW
  EXECUTE FUNCTION prevent_invalid_counterparty_hard_delete();
