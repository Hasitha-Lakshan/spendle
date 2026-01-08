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

CREATE TYPE audit.job_status AS ENUM ('completed', 'failed', 'partial');

-- =========================================
-- Users and Profiles
-- =========================================
-- Profiles are linked to Supabase auth.users
CREATE TABLE core.profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id),    -- references auth.users(id) indirectly
  defaults_inserted BOOLEAN DEFAULT FALSE NOT NULL,                   -- flag to indicate if default accounts/categories are inserted
  is_admin BOOLEAN DEFAULT FALSE NOT NULL,                            -- flag to indicate if the user has admin privileges
  deleted_at timestamptz NULL DEFAULT NULL,                  -- soft delete timestamp
  created_at timestamptz DEFAULT now() NOT NULL,                      -- creation timestamp
  updated_at timestamptz DEFAULT now() NOT NULL
);

-- =========================================
-- Accounts
-- =========================================
-- Generic accounts table containing all types of financial accounts
CREATE TABLE finance.accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID NOT NULL REFERENCES core.profiles(id), -- account owner
  account_name VARCHAR(100) NOT NULL,  -- display name for the account
  type finance.account_type NOT NULL,   -- type: cash, bank, credit_card, loan, investment, crypto, wallet, receivable
  currency VARCHAR(10) NOT NULL,       -- currency used in this account, e.g., USD, LKR, BTC
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

-- =========================================
-- Counterparties
-- =========================================
CREATE TABLE finance.counterparties (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID NOT NULL REFERENCES core.profiles(id),
  name VARCHAR(255) NOT NULL,
  type finance.counterparty_type NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL
);

-- =========================================
-- Specialized Accounts
-- =========================================

-- Cash Accounts
CREATE TABLE finance.cash_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  location VARCHAR(100),                -- physical location of the cash
  balance DECIMAL(36,18) DEFAULT 0 NOT NULL,     -- current cash balance
  status VARCHAR(20) DEFAULT 'active' NOT NULL,  -- status: active, inactive, frozen
  notes TEXT,                           -- additional info
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_cash_balance_nonnegative CHECK (balance >= 0)
);

-- Bank Accounts
CREATE TABLE finance.bank_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  bank_name VARCHAR(100) NOT NULL,
  account_no VARCHAR(50) NOT NULL,
  branch VARCHAR(50),
  account_holder_name VARCHAR(100) NOT NULL,
  balance DECIMAL(36,18) DEFAULT 0 NOT NULL,
  interest_rate DECIMAL(36,18) DEFAULT 0 NOT NULL,
  status VARCHAR(20) DEFAULT 'active' NOT NULL,
  notes TEXT,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_bank_balance_nonnegative CHECK (balance >= 0)
);

-- Credit Card Accounts
CREATE TABLE finance.credit_card_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  card_number VARCHAR(20) NOT NULL,
  card_type VARCHAR(50) NOT NULL,            -- e.g., Visa, Mastercard
  credit_limit DECIMAL(36,18) NOT NULL,
  current_balance DECIMAL(36,18) DEFAULT 0 NOT NULL, -- positive = amount owed, negative = credit balance
  billing_cycle VARCHAR(20),
  interest_rate DECIMAL(36,18) DEFAULT 0 NOT NULL,
  status VARCHAR(20) DEFAULT 'active' NOT NULL,
  notes TEXT,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,

  CONSTRAINT chk_credit_limit CHECK (
    current_balance <= credit_limit
  )
);

-- Loan Accounts
CREATE TABLE finance.loan_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  loan_type VARCHAR(50) NOT NULL,            -- personal, home, car, etc.
  principal_amount DECIMAL(36,18) NOT NULL,
  outstanding_amount DECIMAL(36,18) NOT NULL,       -- remaining amount to repay
  interest_rate DECIMAL(36,18) DEFAULT 0 NOT NULL,
  term_months INT,
  start_date DATE NOT NULL,
  end_date DATE,
  status VARCHAR(20) DEFAULT 'active' NOT NULL, -- active, closed, defaulted
  counterparty_id UUID REFERENCES finance.counterparties(id) NOT NULL,  -- lender
  collateral TEXT,                                     -- pledged collateral
  notes TEXT,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_loan_outstanding_nonnegative CHECK (outstanding_amount >= 0)
);

-- Investment Accounts
CREATE TABLE finance.investment_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  investment_type VARCHAR(50) NOT NULL,      -- stocks, bonds, mutual funds, etc.
  institution_name VARCHAR(100),
  account_no VARCHAR(50) NOT NULL,
  portfolio_value DECIMAL(36,18) DEFAULT 0 NOT NULL,
  status VARCHAR(20) DEFAULT 'active' NOT NULL,
  notes TEXT,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_investment_portfolio_nonnegative CHECK (portfolio_value >= 0)
);

-- Crypto Accounts
CREATE TABLE finance.crypto_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  crypto_wallet_address VARCHAR(100),
  exchange_name VARCHAR(100) NOT NULL,
  balance DECIMAL(36,18) DEFAULT 0 NOT NULL,
  status VARCHAR(20) DEFAULT 'active' NOT NULL,
  notes TEXT,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_crypto_balance_nonnegative CHECK (balance >= 0)
);

-- Wallet Accounts
CREATE TABLE finance.wallet_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  wallet_name VARCHAR(50) NOT NULL,
  provider VARCHAR(50) NOT NULL,
  balance DECIMAL(36,18) DEFAULT 0 NOT NULL,
  status VARCHAR(20) DEFAULT 'active' NOT NULL,
  notes TEXT,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_wallet_balance_nonnegative CHECK (balance >= 0)
);

-- Receivable Accounts
CREATE TABLE finance.receivable_accounts (
  account_id UUID PRIMARY KEY REFERENCES finance.accounts(id),
  invoice_no VARCHAR(50),
  principal_amount DECIMAL(36,18) NOT NULL,
  amount_due DECIMAL(36,18) NOT NULL,
  due_date DATE,
  status VARCHAR(20) DEFAULT 'pending' NOT NULL,
  counterparty_id UUID REFERENCES finance.counterparties(id) NOT NULL,  -- who owes the receivable
  notes TEXT,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  
  CONSTRAINT chk_receivable_amount_nonnegative CHECK (amount_due >= 0)
);

-- =========================================
-- Expense Categories and Subcategories
-- =========================================
CREATE TABLE finance.expense_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID NOT NULL REFERENCES core.profiles(id),
  name VARCHAR(100) NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

CREATE TABLE finance.expense_subcategories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id UUID NOT NULL REFERENCES finance.expense_categories(id),
  name VARCHAR(100) NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

-- =========================================
-- Income Sources
-- =========================================
CREATE TABLE finance.income_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID NOT NULL REFERENCES core.profiles(id),
  name VARCHAR(100) NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

-- =========================================
-- Transactions
-- =========================================
-- Base Transactions Table
CREATE TABLE finance.transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID NOT NULL REFERENCES core.profiles(id),
  transaction_date DATE NOT NULL,    -- BUSINESS DATE (when money actually moved)
  type finance.transaction_type NOT NULL,
  original_amount DECIMAL(36,18) NOT NULL,
  original_currency VARCHAR(10) NOT NULL,
  exchange_rate DECIMAL(36,18) NOT NULL,
  converted_amount DECIMAL(36,18) NOT NULL,
  converted_currency VARCHAR(10) NOT NULL,
  original_fees DECIMAL(36,18) DEFAULT 0 NOT NULL,
  converted_fees DECIMAL(36,18) DEFAULT 0 NOT NULL,
  notes TEXT,
  is_recurring BOOLEAN NOT NULL DEFAULT FALSE,
  deleted_at timestamptz NULL DEFAULT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,

  -- Stored / derived columns
  transaction_month DATE NOT NULL,           -- first day of month (derived)
  type_amount_jsonb JSONB NOT NULL,          -- JSONB for type + amount queries
  is_recent BOOLEAN DEFAULT TRUE NOT NULL,    -- last 30 days flag

  CONSTRAINT chk_transaction_date_reasonable CHECK (
    transaction_date >= DATE '2000-01-01'
    AND transaction_date <= CURRENT_DATE + INTERVAL '1 year'
  ),

  CONSTRAINT chk_fees_non_negative CHECK (
    original_fees >= 0 AND converted_fees >= 0
  )
);

-- =========================================
-- Transaction Types Details
-- =========================================

-- Income Transactions
CREATE TABLE finance.transactions_income (
  transaction_id UUID PRIMARY KEY REFERENCES finance.transactions(id),
  account_id UUID NOT NULL REFERENCES finance.accounts(id),
  source_id UUID REFERENCES finance.income_sources(id) NOT NULL, -- link to source of income
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Expense Transactions
CREATE TABLE finance.transactions_expense (
  transaction_id UUID PRIMARY KEY REFERENCES finance.transactions(id),
  account_id UUID NOT NULL REFERENCES finance.accounts(id),
  category_id UUID REFERENCES finance.expense_subcategories(id) NOT NULL,
  payment_method finance.payment_method DEFAULT 'other' NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Investment Transactions
CREATE TABLE finance.transactions_investment (
  transaction_id UUID PRIMARY KEY REFERENCES finance.transactions(id),
  -- The account used to fund the investment (cash, bank, wallet)
  funding_account_id UUID NOT NULL REFERENCES finance.accounts(id),
  -- The destination investment account (stocks, bonds, crypto, etc.)
  investment_account_id UUID NOT NULL REFERENCES finance.accounts(id),
  asset_type VARCHAR(50) NOT NULL,         -- stock, bond, crypto, etc.
  asset_symbol VARCHAR(50),
  platform VARCHAR(100) NOT NULL,
  risk_level finance.risk_level DEFAULT 'medium' NOT NULL,

  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Borrow Transactions
CREATE TABLE finance.transactions_borrow (
  transaction_id UUID PRIMARY KEY REFERENCES finance.transactions(id),
  -- The loan liability account (what you owe)
  loan_account_id UUID NOT NULL REFERENCES finance.accounts(id),
  -- Where the borrowed funds are deposited (cash, bank, wallet)
  disbursement_account_id UUID NOT NULL REFERENCES finance.accounts(id),

  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Lend Transactions
CREATE TABLE finance.transactions_lend (
  transaction_id UUID PRIMARY KEY REFERENCES finance.transactions(id),
  -- The account you use to lend out money (cash, bank, wallet)
  funding_account_id UUID NOT NULL REFERENCES finance.accounts(id),
  -- The receivable account representing what’s owed to you
  receivable_account_id UUID NOT NULL REFERENCES finance.accounts(id),
  interest_rate DECIMAL(5,2) DEFAULT 0 NOT NULL,
  due_date DATE,
  collateral TEXT,

  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL
);

-- Transfer Transactions
CREATE TABLE finance.transactions_transfer (
  transaction_id UUID PRIMARY KEY REFERENCES finance.transactions(id),
  from_account UUID NOT NULL REFERENCES finance.accounts(id),
  to_account UUID NOT NULL REFERENCES finance.accounts(id),
  transfer_method finance.transfer_method DEFAULT 'other' NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,
  CONSTRAINT chk_transfer_accounts_distinct CHECK (from_account <> to_account)
);

-- Adjustment Transactions
CREATE TABLE finance.transactions_adjustment (
  transaction_id UUID PRIMARY KEY REFERENCES finance.transactions(id),
  account_id UUID NOT NULL REFERENCES finance.accounts(id),
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL
);

-- 1. Exchange Rates
CREATE TABLE finance.exchange_rates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID NOT NULL REFERENCES core.profiles(id),
  from_currency VARCHAR(10) NOT NULL,
  to_currency VARCHAR(10) NOT NULL,
  rate NUMERIC NOT NULL CHECK (rate > 0),
  source TEXT DEFAULT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
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
    profile_id UUID NOT NULL REFERENCES core.profiles(id), -- owner of the recurring transaction (business ownership)
    updated_by TEXT NOT NULL DEFAULT 'system:unknown',  -- who created or last modified the recurring rule
    created_at timestamptz DEFAULT now() NOT NULL,
    updated_at timestamptz DEFAULT now() NOT NULL,
    deleted_at timestamptz DEFAULT NULL,

  CONSTRAINT chk_transactions_recurring_actor CHECK (
    updated_by ~ '^(user|admin):[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    OR updated_by ~ '^system:[a-z_]+$'
  )
);

-- =========================================
-- Audit Logs
-- =========================================
CREATE TABLE audit.audit_logs (
  id BIGSERIAL PRIMARY KEY,
  profile_id UUID REFERENCES core.profiles(id),   -- affected profile (context)
  executed_by TEXT NOT NULL DEFAULT 'system:unknown',   -- who performed the action
  table_name TEXT NOT NULL,
  record_id UUID NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE','SOFT_DELETE', 'ADMIN_PRIVILEGE_CHANGE')),
  old_data JSONB,
  new_data JSONB,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL

  CONSTRAINT chk_audit_actor CHECK (
    executed_by ~ '^(user|admin):[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    OR executed_by ~ '^system:[a-z_]+$'
  )
);

-- =========================================
-- System Job Logs
-- =========================================
CREATE TABLE IF NOT EXISTS audit.system_job_logs (
  id BIGSERIAL PRIMARY KEY,                     -- internal unique identifier
  job_name TEXT NOT NULL,                       -- name of the scheduled job
  executed_by TEXT NOT NULL DEFAULT 'system',   -- actor performing the job
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),-- when job started
  finished_at TIMESTAMPTZ,                      -- when job finished
  status audit.job_status NOT NULL DEFAULT 'completed',     -- 'completed', 'failed', 'partial'
  result_summary TEXT,                          -- human-readable summary
  details JSONB,                                -- structured data: counts, IDs, errors
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at timestamptz NULL DEFAULT NULL
);

-- =========================================
-- Audit Table Registry
-- =========================================
CREATE TABLE IF NOT EXISTS audit.audit_table_registry (
  id BIGSERIAL PRIMARY KEY,
  table_schema TEXT NOT NULL,
  table_name TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,

  CONSTRAINT uq_table_schema_name UNIQUE (table_schema, table_name)
);

-- =========================================
-- API Rate Limits
-- =========================================
CREATE TABLE IF NOT EXISTS api.api_rate_limits (
  id BIGSERIAL PRIMARY KEY,
  profile_id UUID NOT NULL REFERENCES core.profiles(id),
  endpoint VARCHAR(100) NOT NULL,
  request_count INTEGER DEFAULT 1 NOT NULL,
  last_request_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  deleted_at timestamptz NULL DEFAULT NULL,

  CONSTRAINT api_rate_limits_user_endpoint_unique UNIQUE (profile_id, endpoint)
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
-- Create extensions
-- =========================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS hstore;
