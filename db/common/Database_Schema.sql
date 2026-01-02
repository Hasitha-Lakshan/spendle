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
-- Create Schemas
-- =========================================
-- Create finance schema for all financial tables and types
CREATE SCHEMA IF NOT EXISTS finance;                        
-- Create audit schema for audit tables
CREATE SCHEMA IF NOT EXISTS audit;                          
-- Create tables and RPCs exposed or supporting API logic
CREATE SCHEMA IF NOT EXISTS api;                            
-- Create purely internal helper functions not tied to a specific domain
CREATE SCHEMA IF NOT EXISTS util;                           
-- Create core schema for core related tables
CREATE SCHEMA IF NOT EXISTS core;                           

-- =========================================
-- Enum Types
-- =========================================
CREATE TYPE finance.account_type AS ENUM (
  'cash','bank','credit_card','loan','investment','crypto','wallet','receivable'
);

CREATE TYPE finance.transaction_type AS ENUM (
  'income','expense','investment','borrow','lend','transfer','adjustment'
);

CREATE TYPE finance.payment_method AS ENUM ('cash','bank','card','crypto','wallet','other');

CREATE TYPE finance.risk_level AS ENUM ('low','medium','high');

CREATE TYPE finance.transfer_method AS ENUM (
    'cash',               -- Cash to Cash
    'deposit',            -- Cash to Bank
    'payment',            -- Cash/Credit Card to Credit Card or others
    'repay',              -- Cash/Credit Card/Loan to Loan
    'invest',             -- Cash/Bank/Credit Card/Loan to Investment
    'exchange',           -- Cash/Bank/Credit Card/Loan/Investment/Crypto to Crypto
    'wallet',             -- Cash/Bank/Credit Card/Loan/Investment/Crypto to Wallet
    'receive',            -- Cash/Bank/Credit Card/Loan/Investment/Crypto/Wallet to Receivable
    'withdrawal',        -- Bank to Cash
    'cash_advance',      -- Credit Card to Cash
    'bank_payment',      -- Credit Card to Bank
    'loan',               -- Loan to Loan
    'divest',             -- Investment to Cash
    'cash_out',          -- Crypto/Wallet to Cash
    'crypto',            -- Crypto to Crypto
    'bank_transfer',     -- Bank/Loan/Investment/Crypto/Wallet to Bank
    'receivable',        -- Receivable to Receivable
    'other'              -- Default / Unspecified transfer method
);

CREATE TYPE finance.counterparty_type AS ENUM ('person','merchant','company','bank','government','organization','other');

-- Recurrence frequency for the recurring engine
CREATE TYPE finance.recurrence_frequency AS ENUM ('daily','weekly','monthly','yearly');

-- =========================================
-- Users and Profiles
-- =========================================
-- Profiles are linked to Supabase auth.users
CREATE TABLE core.profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id),    -- references auth.users(id) indirectly
  defaults_inserted BOOLEAN DEFAULT FALSE,                   -- flag to indicate if default accounts/categories are inserted
  is_admin BOOLEAN DEFAULT FALSE,                            -- flag to indicate if the user has admin privileges
  deleted_at timestamptz NULL DEFAULT NULL,                  -- soft delete timestamp
  created_at timestamptz DEFAULT now(),                      -- creation timestamp
  updated_at timestamptz DEFAULT now()
);

-- =========================================
-- Accounts
-- =========================================
-- Generic accounts table containing all types of financial accounts
CREATE TABLE finance.accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES core.profiles(id), -- account owner
  account_name VARCHAR(100) NOT NULL,  -- display name for the account
  type finance.account_type NOT NULL,   -- type: cash, bank, credit_card, loan, investment, crypto, wallet, receivable
  currency VARCHAR(10) NOT NULL,       -- currency used in this account, e.g., USD, LKR, BTC
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- =========================================
-- Counterparties
-- =========================================
CREATE TABLE finance.counterparties (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES core.profiles(id),
  name VARCHAR(255) NOT NULL,
  type finance.counterparty_type NOT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- =========================================
-- Specialized Accounts
-- =========================================

-- Cash Accounts
CREATE TABLE finance.cash_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  location VARCHAR(100),                -- physical location of the cash
  balance DECIMAL(36,18) DEFAULT 0,     -- current cash balance
  status VARCHAR(20) DEFAULT 'active',  -- status: active, inactive, frozen
  notes TEXT,                           -- additional info
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_cash_balance_nonnegative CHECK (balance >= 0)
);

-- Bank Accounts
CREATE TABLE finance.bank_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
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
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_bank_balance_nonnegative CHECK (balance >= 0)
);

-- Credit Card Accounts
CREATE TABLE finance.credit_card_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  card_number VARCHAR(20) NOT NULL,
  card_type VARCHAR(50),            -- e.g., Visa, Mastercard
  credit_limit DECIMAL(36,18),
  current_balance DECIMAL(36,18) DEFAULT 0, -- positive = amount owed, negative = credit balance
  billing_cycle VARCHAR(20),
  interest_rate DECIMAL(36,18),
  status VARCHAR(20) DEFAULT 'active',
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL,

  CONSTRAINT chk_credit_limit CHECK (
    credit_limit IS NULL OR current_balance <= credit_limit
  )
);

-- Loan Accounts
CREATE TABLE finance.loan_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  loan_type VARCHAR(50),            -- personal, home, car, etc.
  principal_amount DECIMAL(36,18),
  outstanding_amount DECIMAL(36,18),       -- remaining amount to repay
  interest_rate DECIMAL(36,18),
  term_months INT,
  start_date DATE,
  end_date DATE,
  status VARCHAR(20) DEFAULT 'active', -- active, closed, defaulted
  counterparty_id UUID REFERENCES finance.counterparties(id),  -- lender
  collateral TEXT,                                     -- pledged collateral
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_loan_outstanding_nonnegative CHECK (outstanding_amount >= 0)
);

-- Investment Accounts
CREATE TABLE finance.investment_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  investment_type VARCHAR(50),      -- stocks, bonds, mutual funds, etc.
  institution_name VARCHAR(100),
  account_no VARCHAR(50),
  portfolio_value DECIMAL(36,18) DEFAULT 0,
  status VARCHAR(20) DEFAULT 'active',
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_investment_portfolio_nonnegative CHECK (portfolio_value >= 0)
);

-- Crypto Accounts
CREATE TABLE finance.crypto_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  crypto_wallet_address VARCHAR(100) NOT NULL,
  exchange_name VARCHAR(100),
  balance DECIMAL(36,18) DEFAULT 0,
  status VARCHAR(20) DEFAULT 'active',
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_crypto_balance_nonnegative CHECK (balance >= 0)
);

-- Wallet Accounts
CREATE TABLE finance.wallet_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  wallet_name VARCHAR(50) NOT NULL,
  provider VARCHAR(50),
  balance DECIMAL(36,18) DEFAULT 0,
  status VARCHAR(20) DEFAULT 'active',
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_wallet_balance_nonnegative CHECK (balance >= 0)
);

-- Receivable Accounts
CREATE TABLE finance.receivable_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  invoice_no VARCHAR(50),
  principal_amount DECIMAL(36,18),
  amount_due DECIMAL(36,18),
  due_date DATE,
  status VARCHAR(20) DEFAULT 'pending',
  counterparty_id UUID REFERENCES finance.counterparties(id),  -- who owes the receivable
  notes TEXT,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_receivable_amount_nonnegative CHECK (amount_due >= 0)
);

-- =========================================
-- Expense Categories and Subcategories
-- =========================================
CREATE TABLE finance.expense_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES core.profiles(id),
  name VARCHAR(100) NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE finance.expense_subcategories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id UUID NOT NULL REFERENCES finance.expense_categories(id),
  name VARCHAR(100) NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- =========================================
-- Income Sources
-- =========================================
CREATE TABLE finance.income_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES core.profiles(id),
  name VARCHAR(100) NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- =========================================
-- Transactions
-- =========================================
-- Base Transactions Table
CREATE TABLE finance.transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES core.profiles(id),
  transaction_date DATE NOT NULL,    -- BUSINESS DATE (when money actually moved)
  type finance.transaction_type NOT NULL,
  original_amount DECIMAL(36,18) NOT NULL,
  original_currency VARCHAR(10) NOT NULL,
  exchange_rate DECIMAL(36,18),
  converted_amount DECIMAL(36,18),
  converted_currency VARCHAR(10),
  original_fees DECIMAL(36,18) DEFAULT 0,
  converted_fees DECIMAL(36,18) DEFAULT 0,
  notes TEXT,
  is_recurring BOOLEAN NOT NULL DEFAULT FALSE,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),

  -- Stored / derived columns
  transaction_month DATE,           -- first day of month (derived)
  type_amount_jsonb JSONB,          -- JSONB for type + amount queries
  is_recent BOOLEAN DEFAULT TRUE,    -- last 30 days flag

  CONSTRAINT chk_transaction_date_reasonable CHECK (
    transaction_date >= DATE '2000-01-01'
    AND transaction_date <= CURRENT_DATE + INTERVAL '1 year'
  ),

  CONSTRAINT chk_fees_non_negative CHECK (
    original_fees >= 0
    AND (converted_fees IS NULL OR converted_fees >= 0)
  )
);

-- =========================================
-- Transaction Types Details
-- =========================================

-- Income Transactions
CREATE TABLE finance.transactions_income (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES finance.transactions(id),
  account_id UUID NOT NULL REFERENCES finance.accounts(id),
  source_id UUID REFERENCES finance.income_sources(id), -- link to source of income
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Expense Transactions
CREATE TABLE finance.transactions_expense (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES finance.transactions(id),
  account_id UUID NOT NULL REFERENCES finance.accounts(id),
  category_id UUID REFERENCES finance.expense_subcategories(id),
  payment_method finance.payment_method DEFAULT 'other',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Investment Transactions
CREATE TABLE finance.transactions_investment (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES finance.transactions(id),
  -- The account used to fund the investment (cash, bank, wallet)
  funding_account_id UUID NOT NULL REFERENCES finance.accounts(id),
  -- The destination investment account (stocks, bonds, crypto, etc.)
  investment_account_id UUID NOT NULL REFERENCES finance.accounts(id),
  asset_type VARCHAR(50),         -- stock, bond, crypto, etc.
  asset_symbol VARCHAR(50),
  platform VARCHAR(100),
  risk_level finance.risk_level DEFAULT 'medium',

  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Borrow Transactions
CREATE TABLE finance.transactions_borrow (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES finance.transactions(id),
  -- The loan liability account (what you owe)
  loan_account_id UUID NOT NULL REFERENCES finance.accounts(id),
  -- Where the borrowed funds are deposited (cash, bank, wallet)
  disbursement_account_id UUID NOT NULL REFERENCES finance.accounts(id),

  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Lend Transactions
CREATE TABLE finance.transactions_lend (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES finance.transactions(id),
  -- The account you use to lend out money (cash, bank, wallet)
  funding_account_id UUID NOT NULL REFERENCES finance.accounts(id),
  -- The receivable account representing what’s owed to you
  receivable_account_id UUID NOT NULL REFERENCES finance.accounts(id),
  interest_rate DECIMAL(5,2),
  due_date DATE,
  collateral TEXT,

  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Transfer Transactions
CREATE TABLE finance.transactions_transfer (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES finance.transactions(id),
  from_account UUID NOT NULL REFERENCES finance.accounts(id),
  to_account UUID NOT NULL REFERENCES finance.accounts(id),
  transfer_method finance.transfer_method DEFAULT 'other',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL,
  CONSTRAINT chk_transfer_accounts_distinct CHECK (from_account <> to_account)
);

-- Adjustment Transactions
CREATE TABLE finance.transactions_adjustment (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES finance.transactions(id),
  account_id UUID NOT NULL REFERENCES finance.accounts(id),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- 1. Exchange Rates
CREATE TABLE finance.exchange_rates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES core.profiles(id),
  from_currency VARCHAR(10) NOT NULL,
  to_currency VARCHAR(10) NOT NULL,
  rate NUMERIC NOT NULL CHECK (rate > 0),
  source TEXT DEFAULT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- ============================================
-- Recurring Transactions Schema
-- ============================================

-- Table to store recurrence definitions
CREATE TABLE finance.transactions_recurring (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_template_id UUID NOT NULL REFERENCES finance.transactions(id), -- Links to base transaction definition
    frequency finance.recurrence_frequency NOT NULL,   -- daily, weekly, monthly, yearly
    interval INT NOT NULL DEFAULT 1,           -- every N days/weeks/months
    start_date DATE NOT NULL,
    end_date DATE,                             -- optional, NULL = no end
    next_occurrence DATE NOT NULL,      -- next due date
    user_id UUID NOT NULL REFERENCES core.profiles(id), -- owner of the recurring transaction (business ownership)
    updated_by TEXT NOT NULL DEFAULT 'system:unknown',  -- who created or last modified the recurring rule
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    deleted_at timestamptz DEFAULT NULL,

  CONSTRAINT chk_transactions_recurring_actor CHECK (
    executed_by ~ '^(user|admin):[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    OR executed_by ~ '^system:[a-z_]+$'
  )
);

-- =========================================
-- Audit Logs
-- =========================================
CREATE TABLE audit.audit_logs (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES core.profiles(id),   -- affected user (context)
  executed_by TEXT NOT NULL DEFAULT 'system:unknown',   -- who performed the action
  table_name TEXT NOT NULL,
  record_id UUID NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE','SOFT_DELETE', 'ADMIN_PRIVILEGE_CHANGE')),
  old_data JSONB,
  new_data JSONB,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),

  CONSTRAINT chk_audit_actor CHECK (
    executed_by ~ '^(user|admin):[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    OR executed_by ~ '^system:[a-z_]+$'
  )
);

-- =========================================
-- System Job Logs
-- =========================================
CREATE TABLE IF NOT EXISTS public.system_job_logs (
    id BIGSERIAL PRIMARY KEY,                     -- internal unique identifier
    job_name TEXT NOT NULL,                       -- name of the scheduled job
    executed_by TEXT NOT NULL DEFAULT 'system',   -- actor performing the job
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),-- when job started
    finished_at TIMESTAMPTZ,                      -- when job finished
    status TEXT NOT NULL DEFAULT 'completed',     -- 'completed', 'failed', 'partial'
    result_summary TEXT,                          -- human-readable summary
    details JSONB,                                -- structured data: counts, IDs, errors
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =========================================
-- Audit Table Registry
-- =========================================
CREATE TABLE IF NOT EXISTS audit.audit_table_registry (
    id BIGSERIAL PRIMARY KEY,
    table_schema TEXT NOT NULL,
    table_name TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),

    CONSTRAINT uq_table_schema_name UNIQUE (table_schema, table_name)
);

-- =========================================
-- API Rate Limits
-- =========================================
CREATE TABLE IF NOT EXISTS api.api_rate_limits (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES core.profiles(id),
    endpoint VARCHAR(100) NOT NULL,
    request_count INTEGER DEFAULT 1,
    last_request_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at timestamptz DEFAULT now(),

    CONSTRAINT api_rate_limits_user_endpoint_unique UNIQUE (user_id, endpoint)
);

-- Auto-populate audit_table_registry with existing tables
INSERT INTO audit.audit_table_registry (table_schema, table_name) VALUES
  ('core','profiles'),
  ('finance','accounts'),
  ('finance','cash_accounts'),
  ('finance','bank_accounts'),
  ('finance','credit_card_accounts'),
  ('finance','loan_accounts'),
  ('finance','investment_accounts'),
  ('finance','crypto_accounts'),
  ('finance','wallet_accounts'),
  ('finance','receivable_accounts'),
  ('finance','counterparties'),
  ('finance','expense_categories'),
  ('finance','expense_subcategories'),
  ('finance','income_sources'),
  ('finance','transactions'),
  ('finance','transactions_income'),
  ('finance','transactions_expense'),
  ('finance','transactions_investment'),
  ('finance','transactions_borrow'),
  ('finance','transactions_lend'),
  ('finance','transactions_transfer'),
  ('finance','transactions_adjustment'),
  ('finance','exchange_rates'),
  ('finance','transactions_recurring'),
  ('api','api_rate_limits')
ON CONFLICT DO NOTHING;

-- =========================================
-- Partial UNIQUE index
-- =========================================

-- Enforce uniqueness only for active rows of exchange_rates
-- Enforce uniqueness only for active exchange rates per user and currency pair
CREATE UNIQUE INDEX exchange_rates_user_from_to_active_unique
ON finance.exchange_rates (user_id, from_currency, to_currency)
WHERE deleted_at IS NULL;

-- Enforce uniqueness only for active accounts per user, account name, and type
CREATE UNIQUE INDEX accounts_user_name_type_active_unique
ON finance.accounts (user_id, lower(account_name), type)
WHERE deleted_at IS NULL;

-- Enforce uniqueness only for active expense categories per user
CREATE UNIQUE INDEX expense_categories_user_name_active_unique
ON finance.expense_categories (user_id, lower(name))
WHERE deleted_at IS NULL;

-- Enforce uniqueness only for active expense subcategories per category
CREATE UNIQUE INDEX expense_subcategories_category_name_active_unique
ON finance.expense_subcategories (category_id, lower(name))
WHERE deleted_at IS NULL;

-- Enforce uniqueness only for active income sources per user
CREATE UNIQUE INDEX income_sources_user_name_active_unique
ON finance.income_sources (user_id, lower(name))
WHERE deleted_at IS NULL;

-- Enforce uniqueness only for active counterparties per user and type
CREATE UNIQUE INDEX counterparties_user_name_type_active_unique
ON finance.counterparties (user_id, lower(name), type)
WHERE deleted_at IS NULL;

-- Enforce uniqueness only for active recurring transaction templates
CREATE UNIQUE INDEX transactions_recurring_template_active_unique
ON finance.transactions_recurring (transaction_template_id)
WHERE deleted_at IS NULL;


-- =========================================
-- Indexes (FKs, common filters, JSONB, partial soft-delete on key tables)
-- =========================================

-- ----- Foreign key indexes  -----
CREATE INDEX idx_accounts_user_id ON finance.accounts(user_id);
CREATE INDEX idx_expense_categories_user_id ON finance.expense_categories(user_id);
CREATE INDEX idx_expense_subcategories_category_id ON finance.expense_subcategories(category_id);
CREATE INDEX idx_income_sources_user_id ON finance.income_sources(user_id);
CREATE INDEX idx_counterparties_user_id ON finance.counterparties(user_id);

CREATE INDEX idx_tx_user_id ON finance.transactions(user_id);
CREATE INDEX idx_tx_type ON finance.transactions(type);
CREATE INDEX idx_tx_user_currency ON finance.transactions(user_id, original_currency);
CREATE INDEX idx_transactions_user_transaction_date ON finance.transactions(user_id, transaction_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_transactions_user_type_transaction_date ON finance.transactions(user_id, type, transaction_date DESC) WHERE deleted_at IS NULL;

CREATE INDEX idx_txi_txid ON finance.transactions_income(transaction_id);
CREATE INDEX idx_txi_account_id ON finance.transactions_income(account_id);
CREATE INDEX idx_txi_source_id ON finance.transactions_income(source_id);

CREATE INDEX idx_txe_txid ON finance.transactions_expense(transaction_id);
CREATE INDEX idx_txe_account_id ON finance.transactions_expense(account_id);
CREATE INDEX idx_txe_category_id ON finance.transactions_expense(category_id);

CREATE INDEX idx_txin_txid ON finance.transactions_investment(transaction_id);
CREATE INDEX idx_txin_funding_account_id ON finance.transactions_investment(funding_account_id);
CREATE INDEX idx_txin_investment_account_id ON finance.transactions_investment(investment_account_id);

CREATE INDEX idx_txb_txid ON finance.transactions_borrow(transaction_id);
CREATE INDEX idx_txb_loan_account_id ON finance.transactions_borrow(loan_account_id);
CREATE INDEX idx_txb_disbursement_account_id ON finance.transactions_borrow(disbursement_account_id);

CREATE INDEX idx_txl_txid ON finance.transactions_lend(transaction_id);
CREATE INDEX idx_txl_funding_account_id ON finance.transactions_lend(funding_account_id);
CREATE INDEX idx_txl_receivable_account_id ON finance.transactions_lend(receivable_account_id);

CREATE INDEX idx_txt_txid ON finance.transactions_transfer(transaction_id);
CREATE INDEX idx_txt_from_account ON finance.transactions_transfer(from_account);
CREATE INDEX idx_txt_to_account ON finance.transactions_transfer(to_account);

CREATE INDEX idx_txa_txid ON finance.transactions_adjustment(transaction_id);
CREATE INDEX idx_txa_account_id ON finance.transactions_adjustment(account_id);

-- Recurring engine FKs
CREATE INDEX idx_transactions_recurring_user_id ON finance.transactions_recurring(user_id);
CREATE INDEX idx_transactions_recurring_next_occurrence ON finance.transactions_recurring(next_occurrence);
CREATE INDEX idx_transactions_recurring_deleted_at ON finance.transactions_recurring(deleted_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_transactions_recurring_updated_by ON finance.transactions_recurring(updated_by);

-- ----- Compound indexes likely to be used -----
CREATE INDEX idx_tx_user_created ON finance.transactions(user_id, created_at DESC);
CREATE INDEX idx_tx_user_type_created ON finance.transactions(user_id, type, created_at DESC);

-- ----- Partial indexes for soft-deletes (key tables only) -----
CREATE INDEX idx_accounts_active ON finance.accounts(user_id, type) WHERE deleted_at IS NULL;
CREATE INDEX idx_transactions_active ON finance.transactions(user_id, created_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_counterparties_active ON finance.counterparties(user_id, type) WHERE deleted_at IS NULL;
CREATE INDEX idx_expense_categories_active ON finance.expense_categories(user_id, name) WHERE deleted_at IS NULL;
CREATE INDEX idx_expense_subcategories_active ON finance.expense_subcategories(category_id, name) WHERE deleted_at IS NULL;
CREATE INDEX idx_income_sources_active ON finance.income_sources(user_id, name) WHERE deleted_at IS NULL;

-- ----- Audit log indexes -----
CREATE INDEX idx_audit_user_table_record ON audit.audit_logs(user_id, table_name, record_id);
CREATE INDEX idx_audit_old_original_amount ON audit.audit_logs ((old_data->>'original_amount'));
CREATE INDEX idx_audit_new_original_amount ON audit.audit_logs ((new_data->>'original_amount'));
CREATE INDEX idx_audit_old_converted_amount ON audit.audit_logs ((old_data->>'converted_amount'));
CREATE INDEX idx_audit_new_converted_amount ON audit.audit_logs ((new_data->>'converted_amount'));
CREATE INDEX idx_audit_executed_by ON audit.audit_logs(executed_by);
CREATE INDEX idx_audit_created_at ON audit.audit_logs(created_at);

-- JSONB GIN indexes (generic keys)
CREATE INDEX idx_audit_old_data_gin ON audit.audit_logs USING gin (old_data);
CREATE INDEX idx_audit_new_data_gin ON audit.audit_logs USING gin (new_data);

-- ----- API Rate Limits -----
CREATE INDEX idx_rate_limits_user_endpoint ON api.api_rate_limits(user_id, endpoint, last_request_at);

-- ----- Partial indexes for soft-deletes -----
CREATE INDEX IF NOT EXISTS idx_accounts_user_deleted 
ON finance.accounts(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_user_deleted 
ON finance.transactions(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_profiles_user_admin_deleted 
ON core.profiles(user_id, is_admin, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_expense_categories_user_deleted 
ON finance.expense_categories(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_income_sources_user_deleted 
ON finance.income_sources(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_counterparties_user_deleted 
ON finance.counterparties(user_id, deleted_at) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_recurring_user_deleted 
ON finance.transactions_recurring(user_id, deleted_at) WHERE deleted_at IS NULL;

-- ----- Additional indexes -----
CREATE INDEX idx_exchange_rates ON finance.exchange_rates(from_currency, to_currency);
CREATE INDEX idx_transactions_is_recent ON finance.transactions(transaction_date DESC) 
WHERE is_recent = true AND deleted_at IS NULL;

-- Create extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS hstore;

-- Create the system user for audit logging
-- This user will be used for system-initiated actions
-- Replace with actual UUID with the UUID(00000000-0000-0000-0000-000000000000) of below functions/triggers:
-- public.log_audit()
-- public.cleanup_soft_deleted_records_internal(older_than_days INTEGER DEFAULT 90)
-- public.schedule_recurring_processing()

-- Then execute the following to add the system_user flag to the raw_user_meta_data:
-- UPDATE auth.users
-- SET raw_user_meta_data = jsonb_build_object('system_user', true)
-- WHERE id = '9c6c6a9e-0c2e-4c35-9b62-1d4e2b5c4a88';
