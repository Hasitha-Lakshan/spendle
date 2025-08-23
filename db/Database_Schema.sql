-- =========================================
-- Spendle Database Schema
-- =========================================
-- This schema defines the Spendle application database, which manages
-- user profiles, various types of financial accounts, transactions,
-- counterparties, categories, income sources, and audit logs.
-- The database is designed with relational integrity, using foreign keys,
-- enums, and timestamps for tracking creation and updates.
-- =========================================

-- =========================================
-- DROP TABLES
-- =========================================
DROP TABLE IF EXISTS transactions_adjustment CASCADE;
DROP TABLE IF EXISTS transactions_transfer CASCADE;
DROP TABLE IF EXISTS transactions_lend CASCADE;
DROP TABLE IF EXISTS transactions_borrow CASCADE;
DROP TABLE IF EXISTS transactions_investment CASCADE;
DROP TABLE IF EXISTS transactions_expense CASCADE;
DROP TABLE IF EXISTS transactions_income CASCADE;
DROP TABLE IF EXISTS transactions CASCADE;
DROP TABLE IF EXISTS counterparties CASCADE;
DROP TABLE IF EXISTS income_sources CASCADE;
DROP TABLE IF EXISTS expense_subcategories CASCADE;
DROP TABLE IF EXISTS expense_categories CASCADE;
DROP TABLE IF EXISTS receivable_accounts CASCADE;
DROP TABLE IF EXISTS wallet_accounts CASCADE;
DROP TABLE IF EXISTS crypto_accounts CASCADE;
DROP TABLE IF EXISTS investment_accounts CASCADE;
DROP TABLE IF EXISTS loan_accounts CASCADE;
DROP TABLE IF EXISTS credit_card_accounts CASCADE;
DROP TABLE IF EXISTS bank_accounts CASCADE;
DROP TABLE IF EXISTS cash_accounts CASCADE;
DROP TABLE IF EXISTS accounts CASCADE;
DROP TABLE IF EXISTS profiles CASCADE;
DROP TABLE IF EXISTS audit_logs CASCADE;

-- =========================================
-- DROP ENUM TYPES
-- =========================================
DROP TYPE IF EXISTS transaction_type CASCADE;
DROP TYPE IF EXISTS payment_method CASCADE;
DROP TYPE IF EXISTS risk_level CASCADE;
DROP TYPE IF EXISTS transfer_method CASCADE;
DROP TYPE IF EXISTS counterparty_type CASCADE;
DROP TYPE IF EXISTS transaction_direction CASCADE;

-- =========================================
-- Users and Profiles
-- =========================================
-- Profiles are linked to Supabase auth.users
CREATE TABLE profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE,             -- references auth.users.id indirectly
    defaults_inserted BOOLEAN DEFAULT FALSE,  -- flag to indicate if default accounts/categories are inserted
    is_admin BOOLEAN DEFAULT FALSE,           -- flag to indicate if the user has admin privileges
    deleted_at TIMESTAMP NULL DEFAULT NULL,   -- soft delete timestamp
    created_at TIMESTAMP DEFAULT NOW()        -- creation timestamp
);

-- =========================================
-- Accounts
-- =========================================
-- Generic accounts table containing all types of financial accounts
CREATE TABLE accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE, -- account owner
    account_name VARCHAR(100) NOT NULL,  -- display name for the account
    account_type VARCHAR(50) NOT NULL,   -- type: cash, bank, credit_card, loan, investment, crypto, wallet, receivable
    currency VARCHAR(10) NOT NULL,       -- currency used in this account, e.g., USD, LKR, BTC
    deleted_at TIMESTAMP NULL DEFAULT NULL, 
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- =========================================
-- Specialized Accounts
-- =========================================

-- Cash Accounts
CREATE TABLE cash_accounts (
    account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    location VARCHAR(100),                -- physical location of the cash
    balance NUMERIC DEFAULT 0,            -- current cash balance
    status VARCHAR(20) DEFAULT 'active',  -- status: active, inactive, frozen
    notes TEXT,                           -- additional info
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Bank Accounts
CREATE TABLE bank_accounts (
    account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    bank_name VARCHAR(100) NOT NULL,
    account_no VARCHAR(50) NOT NULL,
    branch VARCHAR(50),
    account_holder_name VARCHAR(100),
    balance NUMERIC DEFAULT 0,
    interest_rate NUMERIC,
    status VARCHAR(20) DEFAULT 'active',
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Credit Card Accounts
CREATE TABLE credit_card_accounts (
    account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    card_number VARCHAR(20) NOT NULL,
    card_type VARCHAR(50),            -- e.g., Visa, Mastercard
    credit_limit NUMERIC,
    current_balance NUMERIC DEFAULT 0, -- outstanding balance
    billing_cycle VARCHAR(20),
    interest_rate NUMERIC,
    status VARCHAR(20) DEFAULT 'active',
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Loan Accounts
CREATE TABLE loan_accounts (
    account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    loan_type VARCHAR(50),            -- personal, home, car, etc.
    principal_amount NUMERIC,
    outstanding_amount NUMERIC,       -- remaining amount to repay
    interest_rate NUMERIC,
    term_months INT,
    start_date DATE,
    end_date DATE,
    status VARCHAR(20) DEFAULT 'active', -- active, closed, defaulted
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Investment Accounts
CREATE TABLE investment_accounts (
    account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    investment_type VARCHAR(50),      -- stocks, bonds, mutual funds, etc.
    institution_name VARCHAR(100),
    account_no VARCHAR(50),
    portfolio_value NUMERIC DEFAULT 0,
    status VARCHAR(20) DEFAULT 'active',
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Crypto Accounts
CREATE TABLE crypto_accounts (
    account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    crypto_wallet_address VARCHAR(100) NOT NULL,
    exchange_name VARCHAR(100),
    balance NUMERIC DEFAULT 0,
    status VARCHAR(20) DEFAULT 'active',
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Wallet Accounts
CREATE TABLE wallet_accounts (
    account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    wallet_name VARCHAR(50) NOT NULL,
    provider VARCHAR(50),
    balance NUMERIC DEFAULT 0,
    status VARCHAR(20) DEFAULT 'active',
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Receivable Accounts
CREATE TABLE receivable_accounts (
    account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    customer_name VARCHAR(100),
    invoice_no VARCHAR(50),
    principal_amount NUMERIC,
    amount_due NUMERIC,
    due_date DATE,
    status VARCHAR(20) DEFAULT 'pending', -- pending, partially_paid, paid, overdue
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- =========================================
-- Expense Categories and Subcategories
-- =========================================
CREATE TABLE expense_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    deleted_at TIMESTAMP NULL DEFAULT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE expense_subcategories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id UUID NOT NULL REFERENCES expense_categories(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    deleted_at TIMESTAMP NULL DEFAULT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- =========================================
-- Income Sources
-- =========================================
CREATE TABLE income_sources (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    deleted_at TIMESTAMP NULL DEFAULT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- =========================================
-- Enum Types
-- =========================================
CREATE TYPE transaction_type AS ENUM (
    'income', 'expense', 'investment', 'borrow', 'lend', 'transfer', 'adjustment'
);

CREATE TYPE payment_method AS ENUM (
    'cash', 'bank', 'card', 'crypto', 'wallet', 'other'
);

CREATE TYPE risk_level AS ENUM (
    'low', 'medium', 'high'
);

CREATE TYPE transfer_method AS ENUM (
    'wire', 'bank_transfer', 'paypal', 'crypto', 'other'
);

CREATE TYPE counterparty_type AS ENUM (
    'person', 'merchant', 'company', 'bank', 'government', 'organization', 'other'
);

CREATE TYPE transaction_direction AS ENUM (
    'inflow', 'outflow'
);

-- =========================================
-- Transactions
-- =========================================
-- Base Transactions Table
CREATE TABLE transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
    type transaction_type NOT NULL,
    direction transaction_direction NOT NULL,  -- inflow or outflow
    amount DECIMAL(36,18) NOT NULL,
    currency VARCHAR(10) NOT NULL,
    notes TEXT,
    deleted_at TIMESTAMP NULL DEFAULT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Counterparties Table
CREATE TABLE counterparties (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, -- owner of counterparty
    name VARCHAR(255) NOT NULL,
    type counterparty_type NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- =========================================
-- Transaction Types Details
-- =========================================

-- Income Transactions
CREATE TABLE transactions_income (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id),
    source_id UUID REFERENCES income_sources(id), -- link to source of income
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Expense Transactions
CREATE TABLE transactions_expense (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id),
    category_id UUID REFERENCES expense_subcategories(id),
    payment_method payment_method DEFAULT 'other',
    recurring BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Investment Transactions
CREATE TABLE transactions_investment (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id),
    asset_type VARCHAR(50),           -- stock, bond, crypto, etc.
    asset_symbol VARCHAR(50),
    platform VARCHAR(100),
    risk_level risk_level DEFAULT 'medium',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Borrow Transactions
CREATE TABLE transactions_borrow (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id),
    counterparty_id UUID REFERENCES counterparties(id), -- lender
    interest_rate DECIMAL(5,2),
    due_date DATE,
    collateral TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Lend Transactions
CREATE TABLE transactions_lend (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id),
    counterparty_id UUID REFERENCES counterparties(id), -- borrower
    interest_rate DECIMAL(5,2),
    due_date DATE,
    collateral TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Transfer Transactions
CREATE TABLE transactions_transfer (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    from_account UUID NOT NULL REFERENCES accounts(id),
    to_account UUID NOT NULL REFERENCES accounts(id),
    transfer_method transfer_method DEFAULT 'other',
    fees DECIMAL(36,18) DEFAULT 0,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- Adjustment Transactions
CREATE TABLE transactions_adjustment (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id),
    reason TEXT, -- reason for adjustment
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP NULL DEFAULT NULL
);

-- =========================================
-- Audit Logs
-- =========================================
CREATE TABLE audit_logs (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    table_name TEXT NOT NULL,          -- table being modified
    record_id UUID NOT NULL,           -- primary key of the affected record
    action TEXT NOT NULL CHECK(action IN ('INSERT','UPDATE','DELETE','SOFT_DELETE')),
    old_data JSONB,                    -- previous state
    new_data JSONB,                    -- new state
    created_at TIMESTAMP DEFAULT NOW()
);

-- =========================================
-- Notes
-- =========================================
-- Accounts or account details can only be edited/deleted if there are no transactions
-- associated with that account.
