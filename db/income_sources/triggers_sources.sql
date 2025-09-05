-- =========================================
-- 01. Trigger Function: prevent_invalid_income_source_hard_delete
-- =========================================
-- Purpose:
--   Prevents hard deletion of an income source if it has related transactions.
--   Ensures referential integrity by allowing only soft deletion for sources
--   that are referenced in transactions_income.
--
-- Trigger:
--   trg_prevent_invalid_income_source_hard_delete
--   BEFORE DELETE ON income_sources
--   FOR EACH ROW
--
-- Behavior:
--   - Checks if the income source being deleted (OLD.id) exists in transactions_income.
--   - If related transactions exist, raises an exception and blocks the hard delete.
--   - Returns OLD to allow the delete only if no related transactions exist.
--
-- Notes:
--   - This trigger enforces business rules to prevent accidental data loss.
--   - Works in conjunction with soft_delete_income_source() and hard_delete_income_source().
--   - ERRCODE 45000 is used for generic user-defined exceptions.
-- =========================================
CREATE OR REPLACE FUNCTION prevent_invalid_income_source_hard_delete()
RETURNS trigger AS $$
BEGIN
  -- Block hard delete if income source has related transactions
  IF EXISTS (SELECT 1 FROM transactions_income WHERE source_id = OLD.id) THEN
    RAISE EXCEPTION 'Income source % has related transactions and can only be soft-deleted', OLD.id
      USING ERRCODE = '45000';
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_invalid_income_source_hard_delete
  BEFORE DELETE ON income_sources
  FOR EACH ROW
  EXECUTE FUNCTION prevent_invalid_income_source_hard_delete();
