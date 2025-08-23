# 📊 Spendle – Database Schema

## Overview

This database schema supports **Spendle**, which handles:

* Income, expenses, investments (stocks, bonds, crypto), borrowings, lendings, and transfers.
* All account types: cash, bank, credit card, loan, investment, crypto, wallet, receivable.
* Audit logs for all CRUD operations.

The schema is **normalized**, **scalable**, and **extensible** for future requirements.

---

## 🔑 Core Entities

### 1. **Users (Supabase default table)**

* Managed by Supabase Auth.
* Stores authentication credentials (email, password hash, etc.).
* Not directly modifiable by triggers.

---

### 2. **Profiles**

Stores user-specific metadata and triggers default categories/sources creation.

| Column             | Type      | Constraints                       | Description                                             |
| ------------------ | --------- | --------------------------------- | ------------------------------------------------------- |
| id                 | UUID (PK) | DEFAULT gen\_random\_uuid()       | Unique profile ID                                       |
| user\_id           | UUID (FK) | UNIQUE, REFERENCES auth.users(id) | Linked Supabase user                                    |
| defaults\_inserted | BOOLEAN   | DEFAULT FALSE                     | Indicates if default categories/income sources inserted |
| deleted\_at        | TIMESTAMP | NULLABLE                          | Soft delete timestamp                                   |
| created\_at        | TIMESTAMP | DEFAULT NOW()                     | Creation timestamp                                      |

---

## 💼 Accounts

All financial accounts belong to a user. Types include **cash, bank, credit\_card, loan, investment, crypto, wallet, receivable**.

| Column        | Type         | Constraints                   | Description           |
| ------------- | ------------ | ----------------------------- | --------------------- |
| id            | UUID (PK)    | DEFAULT gen\_random\_uuid()   | Unique account ID     |
| user\_id      | UUID (FK)    | REFERENCES profiles(user\_id) | Owner of account      |
| account\_name | VARCHAR(100) | NOT NULL                      | Name given by user    |
| account\_type | VARCHAR(50)  | NOT NULL                      | Type of account       |
| currency      | VARCHAR(10)  | NOT NULL                      | e.g., USD, LKR, BTC   |
| deleted\_at   | TIMESTAMP    | NULLABLE                      | Soft delete timestamp |
| created\_at   | TIMESTAMP    | DEFAULT NOW()                 | Creation timestamp    |
| updated\_at   | TIMESTAMP    | DEFAULT NOW()                 | Last updated          |

---

### 2a. **Cash Accounts**

| Column      | Type      | Constraints             | Description               |
| ----------- | --------- | ----------------------- | ------------------------- |
| account\_id | UUID (PK) | REFERENCES accounts(id) | Links to base account     |
| location    | VARCHAR   | NULLABLE                | Physical cash location    |
| balance     | NUMERIC   | DEFAULT 0               | Derived from transactions |
| status      | VARCHAR   | DEFAULT 'active'        | active/inactive/frozen    |
| notes       | TEXT      | NULLABLE                | Free text                 |
| created\_at | TIMESTAMP | DEFAULT NOW()           | Creation timestamp        |
| updated\_at | TIMESTAMP | DEFAULT NOW()           | Last update timestamp     |
| deleted\_at | TIMESTAMP | NULLABLE                | Soft delete               |

---

### 2b. **Bank Accounts**

| Column                | Type      | Constraints             | Description               |
| --------------------- | --------- | ----------------------- | ------------------------- |
| account\_id           | UUID (PK) | REFERENCES accounts(id) | Links to base account     |
| bank\_name            | VARCHAR   | NOT NULL                | Bank name                 |
| account\_no           | VARCHAR   | NOT NULL                | Bank account number       |
| branch                | VARCHAR   | NULLABLE                | Branch info               |
| account\_holder\_name | VARCHAR   | NULLABLE                | Holder’s legal name       |
| balance               | NUMERIC   | DEFAULT 0               | Derived from transactions |
| interest\_rate        | NUMERIC   | NULLABLE                | Optional, can be updated  |
| status                | VARCHAR   | DEFAULT 'active'        | active/inactive           |
| notes                 | TEXT      | NULLABLE                | Free text                 |
| created\_at           | TIMESTAMP | DEFAULT NOW()           | Creation timestamp        |
| updated\_at           | TIMESTAMP | DEFAULT NOW()           | Last updated              |
| deleted\_at           | TIMESTAMP | NULLABLE                | Soft delete               |

---

### 2c. **Credit Card Accounts**

| Column           | Type      | Constraints             | Description               |
| ---------------- | --------- | ----------------------- | ------------------------- |
| account\_id      | UUID (PK) | REFERENCES accounts(id) | Links to base account     |
| card\_number     | VARCHAR   | NOT NULL                | Card identifier           |
| card\_type       | VARCHAR   | NULLABLE                | Visa, Mastercard, etc.    |
| credit\_limit    | NUMERIC   | NULLABLE                | Max credit                |
| current\_balance | NUMERIC   | DEFAULT 0               | Derived from transactions |
| billing\_cycle   | VARCHAR   | NULLABLE                | Billing cycle info        |
| interest\_rate   | NUMERIC   | NULLABLE                | Optional                  |
| status           | VARCHAR   | DEFAULT 'active'        | active/inactive           |
| notes            | TEXT      | NULLABLE                | Free text                 |
| created\_at      | TIMESTAMP | DEFAULT NOW()           | Creation timestamp        |
| updated\_at      | TIMESTAMP | DEFAULT NOW()           | Last update               |
| deleted\_at      | TIMESTAMP | NULLABLE                | Soft delete               |

---

### 2d. **Loan Accounts**

| Column              | Type      | Constraints             | Description                 |
| ------------------- | --------- | ----------------------- | --------------------------- |
| account\_id         | UUID (PK) | REFERENCES accounts(id) | Links to base account       |
| loan\_type          | VARCHAR   | NULLABLE                | Personal, home, car, etc.   |
| principal\_amount   | NUMERIC   | NULLABLE                | Original loan amount        |
| outstanding\_amount | NUMERIC   | NULLABLE                | Remaining balance (derived) |
| interest\_rate      | NUMERIC   | NULLABLE                | Interest rate               |
| term\_months        | INT       | NULLABLE                | Loan term in months         |
| start\_date         | DATE      | NULLABLE                | Loan start date             |
| end\_date           | DATE      | NULLABLE                | Loan end date               |
| status              | VARCHAR   | DEFAULT 'active'        | active/closed/defaulted     |
| notes               | TEXT      | NULLABLE                | Free text                   |
| created\_at         | TIMESTAMP | DEFAULT NOW()           | Creation timestamp          |
| updated\_at         | TIMESTAMP | DEFAULT NOW()           | Last update                 |
| deleted\_at         | TIMESTAMP | NULLABLE                | Soft delete                 |

---

### 2e. **Investment Accounts**

| Column            | Type      | Constraints             | Description                    |
| ----------------- | --------- | ----------------------- | ------------------------------ |
| account\_id       | UUID (PK) | REFERENCES accounts(id) | Links to base account          |
| investment\_type  | VARCHAR   | NULLABLE                | Stock, bond, mutual fund, etc. |
| institution\_name | VARCHAR   | NULLABLE                | Investment institution         |
| account\_no       | VARCHAR   | NULLABLE                | Account number                 |
| portfolio\_value  | NUMERIC   | DEFAULT 0               | Derived from transactions      |
| status            | VARCHAR   | DEFAULT 'active'        | active/inactive                |
| notes             | TEXT      | NULLABLE                | Free text                      |
| created\_at       | TIMESTAMP | DEFAULT NOW()           | Creation timestamp             |
| updated\_at       | TIMESTAMP | DEFAULT NOW()           | Last update                    |
| deleted\_at       | TIMESTAMP | NULLABLE                | Soft delete                    |

---

### 2f. **Crypto Accounts**

| Column                  | Type      | Constraints             | Description               |
| ----------------------- | --------- | ----------------------- | ------------------------- |
| account\_id             | UUID (PK) | REFERENCES accounts(id) | Links to base account     |
| crypto\_wallet\_address | VARCHAR   | NOT NULL                | Wallet identifier         |
| exchange\_name          | VARCHAR   | NULLABLE                | Exchange/platform name    |
| balance                 | NUMERIC   | DEFAULT 0               | Derived from transactions |
| status                  | VARCHAR   | DEFAULT 'active'        | active/inactive           |
| notes                   | TEXT      | NULLABLE                | Free text                 |
| created\_at             | TIMESTAMP | DEFAULT NOW()           | Creation timestamp        |
| updated\_at             | TIMESTAMP | DEFAULT NOW()           | Last update               |
| deleted\_at             | TIMESTAMP | NULLABLE                | Soft delete               |

---

### 2g. **Wallet Accounts**

| Column       | Type      | Constraints             | Description               |
| ------------ | --------- | ----------------------- | ------------------------- |
| account\_id  | UUID (PK) | REFERENCES accounts(id) | Links to base account     |
| wallet\_name | VARCHAR   | NOT NULL                | Wallet name               |
| provider     | VARCHAR   | NULLABLE                | Wallet provider           |
| balance      | NUMERIC   | DEFAULT 0               | Derived from transactions |
| status       | VARCHAR   | DEFAULT 'active'        | active/inactive           |
| notes        | TEXT      | NULLABLE                | Free text                 |
| created\_at  | TIMESTAMP | DEFAULT NOW()           | Creation timestamp        |
| updated\_at  | TIMESTAMP | DEFAULT NOW()           | Last update               |
| deleted\_at  | TIMESTAMP | NULLABLE                | Soft delete               |

---

### 2h. **Receivable Accounts**

| Column            | Type      | Constraints             | Description                 |
| ----------------- | --------- | ----------------------- | --------------------------- |
| account\_id       | UUID (PK) | REFERENCES accounts(id) | Links to base account       |
| customer\_name    | VARCHAR   | NULLABLE                | Customer name               |
| invoice\_no       | VARCHAR   | NULLABLE                | Invoice number              |
| principal\_amount | NUMERIC   | NULLABLE                | Original amount             |
| amount\_due       | NUMERIC   | NULLABLE                | Remaining balance (derived) |
| due\_date         | DATE      | NULLABLE                | Payment due date            |
| status            | VARCHAR   | DEFAULT 'pending'       | pending/paid/overdue        |
| notes             | TEXT      | NULLABLE                | Free text                   |
| created\_at       | TIMESTAMP | DEFAULT NOW()           | Creation timestamp          |
| updated\_at       | TIMESTAMP | DEFAULT NOW()           | Last update                 |
| deleted\_at       | TIMESTAMP | NULLABLE                | Soft delete                 |

---

### 3. **Expense Categories & Subcategories**

**Expense Categories** (top-level):

| Column      | Type      | Constraints                   | Description       |
| ----------- | --------- | ----------------------------- | ----------------- |
| id          | UUID (PK) | DEFAULT gen\_random\_uuid()   | Category ID       |
| user\_id    | UUID (FK) | REFERENCES profiles(user\_id) | Owner             |
| name        | VARCHAR   | NOT NULL                      | Category name     |
| deleted\_at | TIMESTAMP | NULLABLE                      | Soft delete       |
| created\_at | TIMESTAMP | DEFAULT NOW()                 | Created timestamp |

**Expense Subcategories** (linked to categories):

| Column       | Type      | Constraints                        | Description       |
| ------------ | --------- | ---------------------------------- | ----------------- |
| id           | UUID (PK) | DEFAULT gen\_random\_uuid()        | Subcategory ID    |
| category\_id | UUID (FK) | REFERENCES expense\_categories(id) | Parent category   |
| name         | VARCHAR   | NOT NULL                           | Subcategory name  |
| deleted\_at  | TIMESTAMP | NULLABLE                           | Soft delete       |
| created\_at  | TIMESTAMP | DEFAULT NOW()                      | Created timestamp |

---

### 4. **Income Sources**

| Column      | Type      | Constraints                   | Description        |
| ----------- | --------- | ----------------------------- | ------------------ |
| id          | UUID (PK) | DEFAULT gen\_random\_uuid()   | Source ID          |
| user\_id    | UUID (FK) | REFERENCES profiles(user\_id) | Owner              |
| name        | VARCHAR   | NOT NULL                      | Income source name |
| deleted\_at | TIMESTAMP | NULLABLE                      | Soft delete        |
| created\_at | TIMESTAMP | DEFAULT NOW()                 | Created timestamp  |

---

### 5. **Transaction Tables**

All transactions link to **user\_id** and **account\_id**, using **transaction\_type** and **transaction\_direction** enums.

#### 5a. **Base Transactions**

| Column      | Type                   | Constraints                   | Description                                               |
| ----------- | ---------------------- | ----------------------------- | --------------------------------------------------------- |
| id          | UUID (PK)              | DEFAULT gen\_random\_uuid()   | Transaction ID                                            |
| user\_id    | UUID (FK)              | REFERENCES profiles(user\_id) | Owner                                                     |
| type        | transaction\_type      | NOT NULL                      | income/expense/investment/borrow/lend/transfer/adjustment |
| direction   | transaction\_direction | NOT NULL                      | inflow/outflow                                            |
| amount      | DECIMAL(36,18)         | NOT NULL                      | Amount                                                    |
| currency    | VARCHAR(10)            | NOT NULL                      | Currency                                                  |
| notes       | TEXT                   | NULLABLE                      | Optional note                                             |
| deleted\_at | TIMESTAMP              | NULLABLE                      | Soft delete                                               |
| created\_at | TIMESTAMP              | DEFAULT NOW()                 | Created timestamp                                         |
| updated\_at | TIMESTAMP              | DEFAULT NOW()                 | Last update                                               |

---

#### 5b. **Counterparties**

| Column      | Type               | Constraints                 | Description                  |
| ----------- | ------------------ | --------------------------- | ---------------------------- |
| id          | UUID (PK)          | DEFAULT gen\_random\_uuid() | Counterparty ID              |
| user\_id    | UUID (FK)          | REFERENCES profiles(id)     | Owner                        |
| name        | VARCHAR            | NOT NULL                    | Counterparty name            |
| type        | counterparty\_type | NOT NULL                    | person/merchant/company/etc. |
| created\_at | TIMESTAMP          | DEFAULT NOW()               | Creation timestamp           |
| updated\_at | TIMESTAMP          | DEFAULT NOW()               | Last update                  |
| deleted\_at | TIMESTAMP          | NULLABLE                    | Soft delete                  |

---

#### 5c. **Income Transactions**

| Column          | Type      | Constraints                    | Description            |
| --------------- | --------- | ------------------------------ | ---------------------- |
| id              | UUID (PK) | DEFAULT gen\_random\_uuid()    | Income transaction ID  |
| transaction\_id | UUID (FK) | REFERENCES transactions(id)    | Base transaction       |
| account\_id     | UUID (FK) | REFERENCES accounts(id)        | Receiving account      |
| source\_id      | UUID (FK) | REFERENCES income\_sources(id) | Optional income source |
| notes           | TEXT      | NULLABLE                       | Optional               |
| created\_at     | TIMESTAMP | DEFAULT NOW()                  | Creation timestamp     |
| updated\_at     | TIMESTAMP | DEFAULT NOW()                  | Last update            |
| deleted\_at     | TIMESTAMP | NULLABLE                       | Soft delete            |

---

#### 5d. **Expense Transactions**

| Column          | Type            | Constraints                           | Description                        |
| --------------- | --------------- | ------------------------------------- | ---------------------------------- |
| id              | UUID (PK)       | DEFAULT gen\_random\_uuid()           | Expense transaction ID             |
| transaction\_id | UUID (FK)       | REFERENCES transactions(id)           | Base transaction                   |
| account\_id     | UUID (FK)       | REFERENCES accounts(id)               | Paying account                     |
| category\_id    | UUID (FK)       | REFERENCES expense\_subcategories(id) | Optional category                  |
| payment\_method | payment\_method | DEFAULT 'other'                       | cash/bank/card/crypto/wallet/other |
| recurring       | BOOLEAN         | DEFAULT FALSE                         | Recurring expense                  |
| created\_at     | TIMESTAMP       | DEFAULT NOW()                         | Creation timestamp                 |
| updated\_at     | TIMESTAMP       | DEFAULT NOW()                         | Last update                        |
| deleted\_at     | TIMESTAMP       | NULLABLE                              | Soft delete                        |

---

#### 5e. **Investment Transactions**

| Column          | Type        | Constraints                 | Description                |
| --------------- | ----------- | --------------------------- | -------------------------- |
| id              | UUID (PK)   | DEFAULT gen\_random\_uuid() | Investment transaction ID  |
| transaction\_id | UUID (FK)   | REFERENCES transactions(id) | Base transaction           |
| account\_id     | UUID (FK)   | REFERENCES accounts(id)     | Account holding investment |
| asset\_type     | VARCHAR     | NULLABLE                    | e.g., stock, crypto, bond  |
| asset\_symbol   | VARCHAR     | NULLABLE                    | Asset ticker symbol        |
| platform        | VARCHAR     | NULLABLE                    | Platform or exchange       |
| risk\_level     | risk\_level | DEFAULT 'medium'            | Low/medium/high risk       |
| created\_at     | TIMESTAMP   | DEFAULT NOW()               | Creation timestamp         |
| updated\_at     | TIMESTAMP   | DEFAULT NOW()               | Last update                |
| deleted\_at     | TIMESTAMP   | NULLABLE                    | Soft delete                |

---

#### 5f. **Borrow Transactions**

| Column           | Type         | Constraints                   | Description           |
| ---------------- | ------------ | ----------------------------- | --------------------- |
| id               | UUID (PK)    | DEFAULT gen\_random\_uuid()   | Borrow transaction ID |
| transaction\_id  | UUID (FK)    | REFERENCES transactions(id)   | Base transaction      |
| account\_id      | UUID (FK)    | REFERENCES accounts(id)       | Receiving account     |
| counterparty\_id | UUID (FK)    | REFERENCES counterparties(id) | Lender                |
| interest\_rate   | DECIMAL(5,2) | NULLABLE                      | Interest rate         |
| due\_date        | DATE         | NULLABLE                      | Optional due date     |
| collateral       | TEXT         | NULLABLE                      | Optional collateral   |
| created\_at      | TIMESTAMP    | DEFAULT NOW()                 | Creation timestamp    |
| updated\_at      | TIMESTAMP    | DEFAULT NOW()                 | Last update           |
| deleted\_at      | TIMESTAMP    | NULLABLE                      | Soft delete           |

---

#### 5g. **Lend Transactions**

| Column | Type | Constraints | Description |
| ------ | ---- | ----------- | ----------- |
| id     |      |             |             |


UUID (PK) | DEFAULT gen\_random\_uuid()     | Lend transaction ID                |
\| transaction\_id| UUID (FK) | REFERENCES transactions(id)  | Base transaction                   |
\| account\_id    | UUID (FK) | REFERENCES accounts(id)      | Lending account                     |
\| counterparty\_id| UUID (FK)| REFERENCES counterparties(id)| Borrower                             |
\| interest\_rate | DECIMAL(5,2) | NULLABLE                  | Interest rate                       |
\| due\_date      | DATE      | NULLABLE                     | Optional due date                   |
\| collateral    | TEXT      | NULLABLE                     | Optional collateral                 |
\| created\_at    | TIMESTAMP | DEFAULT NOW()                | Creation timestamp                  |
\| updated\_at    | TIMESTAMP | DEFAULT NOW()                | Last update                         |
\| deleted\_at    | TIMESTAMP | NULLABLE                     | Soft delete                         |

---

#### 5h. **Transfer Transactions**

| Column          | Type      | Constraints                 | Description             |
| --------------- | --------- | --------------------------- | ----------------------- |
| id              | UUID (PK) | DEFAULT gen\_random\_uuid() | Transfer transaction ID |
| transaction\_id | UUID (FK) | REFERENCES transactions(id) | Base transaction        |
| from\_account   | UUID (FK) | REFERENCES accounts(id)     | Sending account         |
| to\_account     | UUID (FK) | REFERENCES accounts(id)     | Receiving account       |
| notes           | TEXT      | NULLABLE                    | Optional note           |
| created\_at     | TIMESTAMP | DEFAULT NOW()               | Creation timestamp      |
| updated\_at     | TIMESTAMP | DEFAULT NOW()               | Last update             |
| deleted\_at     | TIMESTAMP | NULLABLE                    | Soft delete             |

---

### 6. **Relationships (Simplified ERD)**

* **Users → Profiles → Accounts → Transactions**
* **Profiles → Expense\_Categories → Expense\_Subcategories**
* **Profiles → Income\_Sources**
* **Accounts → All transaction tables**
* **Counterparties → Borrow / Lend Transactions**
* **Transaction → Base → Income / Expense / Investment / Borrow / Lend / Transfer**

---

### 7. **Best Practices**

1. Use **UUIDs** for all primary keys.
2. Use **foreign key constraints** for referential integrity.
3. Soft delete (`deleted_at`) for recoverability.
4. Keep **all balances derived** from transactions.
5. Maintain **audit logs** for all modifications.
6. Use **triggers** on `profiles` to insert default categories & income sources.
7. Currency normalization or exchange rate mapping for multi-currency support.
