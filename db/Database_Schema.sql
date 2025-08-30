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
-- Enum Types
-- =========================================
CREATE TYPE account_type AS ENUM (
  'cash','bank','credit_card','loan','investment','crypto','wallet','receivable'
);

CREATE TYPE transaction_type AS ENUM (
  'income','expense','investment','borrow','lend','transfer','adjustment'
);

CREATE TYPE payment_method AS ENUM ('cash','bank','card','crypto','wallet','other');

CREATE TYPE risk_level AS ENUM ('low','medium','high');

CREATE TYPE transfer_method AS ENUM ('wire','bank_transfer','paypal','crypto','other');

CREATE TYPE counterparty_type AS ENUM ('person','merchant','company','bank','government','organization','other');

CREATE TYPE transaction_direction AS ENUM ('inflow','outflow','neutral','unknown');

-- Recurrence frequency for the recurring engine
CREATE TYPE recurrence_frequency AS ENUM ('daily','weekly','monthly','yearly');

-- =========================================
-- Users and Profiles
-- =========================================
-- Profiles are linked to Supabase auth.users
CREATE TABLE profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE,               -- references auth.users(id) indirectly
  defaults_inserted BOOLEAN DEFAULT FALSE,    -- flag to indicate if default accounts/categories are inserted
  is_admin BOOLEAN DEFAULT FALSE,             -- flag to indicate if the user has admin privileges
  deleted_at timestamptz NULL DEFAULT NULL,   -- soft delete timestamp
  created_at timestamptz DEFAULT now(),        -- creation timestamp
  updated_at timestamptz DEFAULT now()
);

-- =========================================
-- Accounts
-- =========================================
-- Generic accounts table containing all types of financial accounts
CREATE TABLE accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE, -- account owner
  account_name VARCHAR(100) NOT NULL,  -- display name for the account
  type account_type NOT NULL,   -- type: cash, bank, credit_card, loan, investment, crypto, wallet, receivable
  currency VARCHAR(10) NOT NULL,       -- currency used in this account, e.g., USD, LKR, BTC
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- =========================================
-- Specialized Accounts
-- =========================================

-- Cash Accounts
CREATE TABLE cash_accounts (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  location VARCHAR(100),                -- physical location of the cash
  balance DECIMAL(36,18) DEFAULT 0,     -- current cash balance
  status VARCHAR(20) DEFAULT 'active',  -- status: active, inactive, frozen
  notes TEXT,                           -- additional info
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Bank Accounts
CREATE TABLE bank_accounts (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  bank_name VARCHAR(100) NOT NULL,
  account_no VARCHAR(50) NOT NULL,
  branch VARCHAR(50),
  account_holder_name VARCHAR(100),
  balance DECIMAL(36,18) DEFAULT 0,
  interest_rate DECIMAL(36,18),
  status VARCHAR(20) DEFAULT 'active',
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Credit Card Accounts
CREATE TABLE credit_card_accounts (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  card_number VARCHAR(20) NOT NULL,
  card_type VARCHAR(50),            -- e.g., Visa, Mastercard
  credit_limit DECIMAL(36,18),
  current_balance DECIMAL(36,18) DEFAULT 0, -- outstanding balance
  billing_cycle VARCHAR(20),
  interest_rate DECIMAL(36,18),
  status VARCHAR(20) DEFAULT 'active',
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Loan Accounts
CREATE TABLE loan_accounts (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  loan_type VARCHAR(50),            -- personal, home, car, etc.
  principal_amount DECIMAL(36,18),
  outstanding_amount DECIMAL(36,18),       -- remaining amount to repay
  interest_rate DECIMAL(36,18),
  term_months INT,
  start_date DATE,
  end_date DATE,
  status VARCHAR(20) DEFAULT 'active', -- active, closed, defaulted
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Investment Accounts
CREATE TABLE investment_accounts (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  investment_type VARCHAR(50),      -- stocks, bonds, mutual funds, etc.
  institution_name VARCHAR(100),
  account_no VARCHAR(50),
  portfolio_value DECIMAL(36,18) DEFAULT 0,
  status VARCHAR(20) DEFAULT 'active',
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Crypto Accounts
CREATE TABLE crypto_accounts (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  crypto_wallet_address VARCHAR(100) NOT NULL,
  exchange_name VARCHAR(100),
  balance DECIMAL(36,18) DEFAULT 0,
  status VARCHAR(20) DEFAULT 'active',
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Wallet Accounts
CREATE TABLE wallet_accounts (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  wallet_name VARCHAR(50) NOT NULL,
  provider VARCHAR(50),
  balance DECIMAL(36,18) DEFAULT 0,
  status VARCHAR(20) DEFAULT 'active',
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Receivable Accounts
CREATE TABLE receivable_accounts (
  account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  customer_name VARCHAR(100),
  invoice_no VARCHAR(50),
  principal_amount DECIMAL(36,18),
  amount_due DECIMAL(36,18),
  due_date DATE,
  status VARCHAR(20) DEFAULT 'pending',
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- =========================================
-- Expense Categories and Subcategories
-- =========================================
CREATE TABLE expense_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  name VARCHAR(100) NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE expense_subcategories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id UUID NOT NULL REFERENCES expense_categories(id) ON DELETE CASCADE,
  name VARCHAR(100) NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now()
);

-- =========================================
-- Income Sources
-- =========================================
CREATE TABLE income_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  name VARCHAR(100) NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now()
);

-- =========================================
-- Counterparties
-- =========================================
CREATE TABLE counterparties (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  name VARCHAR(255) NOT NULL,
  type counterparty_type NOT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- =========================================
-- Transactions
-- =========================================
-- Base Transactions Table
CREATE TABLE transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
  type transaction_type NOT NULL,
  amount DECIMAL(36,18) NOT NULL,
  currency VARCHAR(10) NOT NULL,
  notes TEXT,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),

  -- Stored columns for indexes
  created_month DATE,               -- month for aggregation
  type_amount_jsonb JSONB,          -- JSONB for type + amount queries
  is_recent BOOLEAN DEFAULT TRUE    -- last 30 days flag
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
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Expense Transactions
CREATE TABLE transactions_expense (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  account_id UUID NOT NULL REFERENCES accounts(id),
  category_id UUID REFERENCES expense_subcategories(id),
  payment_method payment_method DEFAULT 'other',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
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
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
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
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
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
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Transfer Transactions
CREATE TABLE transactions_transfer (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  from_account UUID NOT NULL REFERENCES accounts(id),
  to_account UUID NOT NULL REFERENCES accounts(id),
  transfer_method transfer_method DEFAULT 'other',
  fees DECIMAL(36,18) DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL,
  CONSTRAINT chk_transfer_accounts_distinct CHECK (from_account <> to_account)
);

-- Adjustment Transactions
CREATE TABLE transactions_adjustment (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  account_id UUID NOT NULL REFERENCES accounts(id),
  reason TEXT, -- reason for adjustment
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- ============================================
-- Recurring Transactions Schema
-- ============================================

-- Table to store recurrence definitions
CREATE TABLE transactions_recurring (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Links to base transaction definition
    transaction_template_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,

    -- Recurrence metadata
    frequency recurrence_frequency NOT NULL,   -- daily, weekly, monthly, yearly
    interval INT NOT NULL DEFAULT 1,           -- every N days/weeks/months
    start_date DATE NOT NULL,
    end_date DATE,                             -- optional, NULL = no end
    next_occurrence timestamptz NOT NULL,      -- next due date

    -- Ownership & actor semantics
    user_id UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE, -- affected user
    action_by UUID NOT NULL REFERENCES auth.users(id),                    -- actor (creator)

    -- Auditing
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    deleted_at timestamptz DEFAULT NULL
);

-- =========================================
-- Audit Logs
-- =========================================
CREATE TABLE audit_logs (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,   -- affected user (context)
  action_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE, -- who performed the action
  table_name TEXT NOT NULL,
  record_id UUID NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE','SOFT_DELETE')),
  old_data JSONB,
  new_data JSONB,
  created_at timestamptz DEFAULT now()
);

-- =========================================
-- API Rate Limits
-- =========================================
CREATE TABLE IF NOT EXISTS api_rate_limits (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    endpoint VARCHAR(100) NOT NULL,
    request_count INTEGER DEFAULT 1,
    window_start TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);


-- =========================================
-- CONSTRAINTS
-- =========================================

-- Add UNIQUE constraints needed for ON CONFLICT in default inserts
ALTER TABLE expense_categories
  ADD CONSTRAINT expense_categories_user_name_unique UNIQUE (user_id, name);

ALTER TABLE expense_subcategories
  ADD CONSTRAINT expense_subcategories_category_name_unique UNIQUE (category_id, name);

-- Add UNIQUE constraint for income_sources
ALTER TABLE income_sources
  ADD CONSTRAINT income_sources_user_name_unique UNIQUE (user_id, name);


-- =========================================
-- Indexes (FKs, common filters, JSONB, partial soft-delete on key tables)
-- =========================================

-- ----- Foreign key indexes  -----
CREATE INDEX idx_accounts_user_id ON accounts(user_id);
CREATE INDEX idx_expense_categories_user_id ON expense_categories(user_id);
CREATE INDEX idx_expense_subcategories_category_id ON expense_subcategories(category_id);
CREATE INDEX idx_income_sources_user_id ON income_sources(user_id);
CREATE INDEX idx_counterparties_user_id ON counterparties(user_id);

CREATE INDEX idx_tx_user_id ON transactions(user_id);
CREATE INDEX idx_tx_type ON transactions(type);
CREATE INDEX idx_tx_user_currency ON transactions(user_id, currency);
CREATE INDEX idx_tx_created_at ON transactions(created_at);

CREATE INDEX idx_txi_txid ON transactions_income(transaction_id);
CREATE INDEX idx_txi_account_id ON transactions_income(account_id);
CREATE INDEX idx_txi_source_id ON transactions_income(source_id);

CREATE INDEX idx_txe_txid ON transactions_expense(transaction_id);
CREATE INDEX idx_txe_account_id ON transactions_expense(account_id);
CREATE INDEX idx_txe_category_id ON transactions_expense(category_id);

CREATE INDEX idx_txin_txid ON transactions_investment(transaction_id);
CREATE INDEX idx_txin_account_id ON transactions_investment(account_id);

CREATE INDEX idx_txb_txid ON transactions_borrow(transaction_id);
CREATE INDEX idx_txb_account_id ON transactions_borrow(account_id);
CREATE INDEX idx_txb_counterparty_id ON transactions_borrow(counterparty_id);

CREATE INDEX idx_txl_txid ON transactions_lend(transaction_id);
CREATE INDEX idx_txl_account_id ON transactions_lend(account_id);
CREATE INDEX idx_txl_counterparty_id ON transactions_lend(counterparty_id);

CREATE INDEX idx_txt_txid ON transactions_transfer(transaction_id);
CREATE INDEX idx_txt_from_account ON transactions_transfer(from_account);
CREATE INDEX idx_txt_to_account ON transactions_transfer(to_account);

CREATE INDEX idx_txa_txid ON transactions_adjustment(transaction_id);
CREATE INDEX idx_txa_account_id ON transactions_adjustment(account_id);

-- Recurring engine FKs
CREATE INDEX idx_transactions_recurring_user_id ON transactions_recurring(user_id);
CREATE INDEX idx_transactions_recurring_next_occurrence ON transactions_recurring(next_occurrence);
CREATE INDEX idx_transactions_recurring_deleted_at ON transactions_recurring(deleted_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_transactions_recurring_action_by ON transactions_recurring(action_by);

-- ----- Compound indexes likely to be used -----
CREATE INDEX idx_tx_user_created ON transactions(user_id, created_at DESC);
CREATE INDEX idx_tx_user_type_created ON transactions(user_id, type, created_at DESC);

-- ----- Partial indexes for soft-deletes (key tables only) -----
CREATE INDEX idx_accounts_active ON accounts(user_id, type) WHERE deleted_at IS NULL;
CREATE INDEX idx_transactions_active ON transactions(user_id, created_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_counterparties_active ON counterparties(user_id, type) WHERE deleted_at IS NULL;
CREATE INDEX idx_expense_categories_active ON expense_categories(user_id, name) WHERE deleted_at IS NULL;
CREATE INDEX idx_expense_subcategories_active ON expense_subcategories(category_id, name) WHERE deleted_at IS NULL;
CREATE INDEX idx_income_sources_active ON income_sources(user_id, name) WHERE deleted_at IS NULL;

-- ----- Audit log indexes -----
CREATE INDEX idx_audit_user_table_record ON audit_logs(user_id, table_name, record_id);
CREATE INDEX idx_audit_old_amount ON audit_logs ((old_data->>'amount'));
CREATE INDEX idx_audit_new_amount ON audit_logs ((new_data->>'amount'));
CREATE INDEX idx_audit_action_by ON audit_logs(action_by);
CREATE INDEX idx_audit_created_at ON audit_logs(created_at);

-- JSONB GIN indexes (generic keys)
CREATE INDEX idx_audit_old_data_gin ON audit_logs USING gin (old_data);
CREATE INDEX idx_audit_new_data_gin ON audit_logs USING gin (new_data);

CREATE INDEX idx_rate_limits_user_endpoint ON api_rate_limits(user_id, endpoint, window_start);

CREATE INDEX IF NOT EXISTS idx_accounts_user_deleted 
ON accounts(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_user_deleted 
ON transactions(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_profiles_user_admin_deleted 
ON profiles(user_id, is_admin, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_expense_categories_user_deleted 
ON expense_categories(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_income_sources_user_deleted 
ON income_sources(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_counterparties_user_deleted 
ON counterparties(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_recurring_user_deleted 
ON transactions_recurring(user_id, deleted_at) WHERE deleted_at IS NULL;