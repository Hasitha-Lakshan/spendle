CREATE OR REPLACE FUNCTION soft_delete_exchange_rate()
RETURNS TRIGGER AS $$
BEGIN
    NEW.deleted_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_soft_delete_exchange_rate
BEFORE DELETE ON exchange_rates
FOR EACH ROW
EXECUTE FUNCTION soft_delete_exchange_rate();
