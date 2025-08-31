-- =========================================
-- 01. Function: initialize_user_defaults
-- =========================================
-- Purpose:
--   Ensures a user profile exists and inserts default data for new users,
--   including base accounts, expense categories, subcategories, and income sources.
--   Marks defaults as inserted to prevent duplicates.
--
-- Parameters:
--   p_user_id UUID - The ID of the user to initialize
--
-- Returns:
--   JSONB - Object indicating user_id and that defaults were inserted
--
-- Notes:
--   - Uses create_account to insert default accounts
--   - Prevents duplicate inserts using ON CONFLICT
--   - Safe for repeated calls; defaults are only inserted once
-- =========================================
CREATE OR REPLACE FUNCTION initialize_user_defaults(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
VOLATILE
AS $$
DECLARE
    profile_exists BOOLEAN;
    defaults_flag BOOLEAN;
    default_category_id UUID;
BEGIN
    -- Check if profile exists and whether defaults are already inserted
    SELECT EXISTS(SELECT 1 FROM profiles WHERE user_id = p_user_id),
           COALESCE((SELECT defaults_inserted FROM profiles WHERE user_id = p_user_id), FALSE)
    INTO profile_exists, defaults_flag;

    -- If profile does not exist, create it
    IF NOT profile_exists THEN
        INSERT INTO profiles(user_id, defaults_inserted)
        VALUES (p_user_id, FALSE)
        ON CONFLICT (user_id) DO NOTHING;

        -- Re-fetch flags after insert
        SELECT EXISTS(SELECT 1 FROM profiles WHERE user_id = p_user_id),
               COALESCE((SELECT defaults_inserted FROM profiles WHERE user_id = p_user_id), FALSE)
        INTO profile_exists, defaults_flag;
    END IF;

    -- If defaults not inserted, insert them
    IF NOT defaults_flag THEN
        -- Insert default accounts using create_account
        PERFORM create_account(p_user_id, 'Cash Wallet', 'cash', 'USD', '{}'::jsonb);
        PERFORM create_account(
            p_user_id,
            'Default Bank',
            'bank',
            'USD',
            '{"bank_name":"Default Bank","account_no":"0000","branch":"Main","account_holder_name":"User","balance":0}'::jsonb
        );

        -- Insert default expense category and subcategory
        INSERT INTO expense_categories(user_id, name)
        VALUES (p_user_id, 'General')
        ON CONFLICT (user_id, name) DO NOTHING
        RETURNING id INTO default_category_id;

        IF default_category_id IS NOT NULL THEN
            INSERT INTO expense_subcategories(category_id, name)
            VALUES (default_category_id, 'Miscellaneous')
            ON CONFLICT (category_id, name) DO NOTHING;
        END IF;

        -- Insert default income source
        INSERT INTO income_sources(user_id, name)
        VALUES (p_user_id, 'Salary')
        ON CONFLICT (user_id, name) DO NOTHING;

        -- Mark defaults as inserted
        UPDATE profiles
        SET defaults_inserted = TRUE, updated_at = NOW()
        WHERE user_id = p_user_id;
    END IF;

    -- Return JSON to Supabase
    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'defaults_inserted', TRUE
    );
END;
$$;


-- ================================
-- Grant Permissions
-- ================================
GRANT EXECUTE ON FUNCTION initialize_user_defaults(UUID) TO authenticated;



-- ================================
-- Function Documentation
-- ================================
COMMENT ON FUNCTION initialize_user_defaults(UUID) IS 
'Triggers default account and category creation for new users via existing trigger system';

