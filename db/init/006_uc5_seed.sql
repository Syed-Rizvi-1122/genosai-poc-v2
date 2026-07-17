-- ============================================================================
-- UC5: Suspicious Transaction Investigation & STR/CTR Pipeline — Seed Data
-- GenosAI AML/CFT/CPF Compliance Automation POC v2
--
-- This file seeds:
--   1. regulatory_thresholds_config — sourced regulatory values
--   2. transactions — demo transactions for CTR/STR testing
--
-- NOTE: This seed data is for POC/demo purposes only.
--       Production values must be independently verified against current
--       FMU circulars and the AML Act 2010 before deployment.
-- ============================================================================

-- ============================================================================
-- 1. REGULATORY THRESHOLDS CONFIG
-- ============================================================================
-- Each row is sourced from a specific regulatory document.
-- is_confirmed = TRUE means the value has been traced to a cited source.
-- The workflow reads these at runtime — NEVER hardcodes them.

INSERT INTO regulatory_thresholds_config (config_key, config_value, config_value_text, is_confirmed, source_note)
VALUES
  (
    'CTR_THRESHOLD_PKR',
    2000000,
    NULL,
    TRUE,
    'FMU Guidelines for Filing CTRs; threshold per FMU notification dated 21-Jan-2015 under AML Act 2010 s.7. Cash transactions (deposits/withdrawals) of PKR 2,000,000 or more must be reported.'
  ),
  (
    'CTR_THRESHOLD_PKR_EXCHANGE_COMPANY_AGGREGATE',
    2000000,
    NULL,
    TRUE,
    'CTR-A variant for Exchange Companies: multi-currency transactions AGGREGATING to PKR 2M+, per same FMU guidelines. Not exercised in this POC (no EC simulation).'
  ),
  (
    'CTR_FILING_DEADLINE_DAYS',
    7,
    NULL,
    TRUE,
    'AML Act 2010 s.7(3): "not later than seven working days" after the currency transaction.'
  ),
  (
    'STR_FILING_DEADLINE',
    NULL,
    'PROMPTLY_NO_FIXED_DAYS',
    TRUE,
    'AML Act 2010 s.7(1) proviso: "STRs shall be filed... promptly" — no fixed day-count specified in the Act. Workflow does not enforce a deadline timer but flags aging cases.'
  ),
  (
    'RECORD_RETENTION_YEARS_STR_CTR',
    10,
    NULL,
    TRUE,
    'Reg 8 §3: "minimum period of ten years from completion of the transaction." Note: Act s.7(4) anchors retention to "after reporting" while Reg 8 §3 anchors to "completion." Implementation uses GREATEST(executed_at, filed_at) + 10 years to satisfy both.'
  )
ON CONFLICT (config_key) DO NOTHING;

-- ============================================================================
-- 2. DEMO TRANSACTIONS
-- ============================================================================
-- These transactions reference customers from UC1's seed data.
-- Customer IDs 1-5 should exist from UC1 seeding.
-- Mix of above/below threshold, cash/non-cash, various channels.
--
-- For testing: Transactions 1,2,5 should trigger CTR (cash >= 2M PKR).
--              Transactions 3,4,6 should NOT trigger CTR (below threshold or non-cash).
--              Transactions 7,8 are suspicious patterns for STR testing.

INSERT INTO transactions (customer_id, account_id, transaction_type, amount, currency, branch_code, channel, description, executed_at)
VALUES
  -- Transaction 1: CASH DEPOSIT above threshold → should trigger CTR
  (1, NULL, 'CASH_DEPOSIT', 2500000.00, 'PKR', 'BR-001', 'BRANCH_TELLER',
   'Large cash deposit — customer brought cash in person', now() - interval '2 days'),

  -- Transaction 2: CASH WITHDRAWAL above threshold → should trigger CTR
  (2, NULL, 'CASH_WITHDRAWAL', 3000000.00, 'PKR', 'BR-002', 'BRANCH_TELLER',
   'Large cash withdrawal — manager-approved counter withdrawal', now() - interval '1 day'),

  -- Transaction 3: CASH DEPOSIT below threshold → should NOT trigger CTR
  (1, NULL, 'CASH_DEPOSIT', 500000.00, 'PKR', 'BR-001', 'BRANCH_TELLER',
   'Regular salary deposit — below threshold', now() - interval '3 days'),

  -- Transaction 4: WIRE TRANSFER (non-cash) above threshold → should NOT trigger CTR
  (3, NULL, 'WIRE_INCOMING', 5000000.00, 'PKR', 'BR-003', 'DIGITAL',
   'International wire from overseas account — not cash, no CTR required', now() - interval '4 days'),

  -- Transaction 5: CASH DEPOSIT exactly at threshold → should trigger CTR (>=)
  (4, NULL, 'CASH_DEPOSIT', 2000000.00, 'PKR', 'BR-001', 'BRANCH_TELLER',
   'Cash deposit exactly at threshold boundary — edge case test', now() - interval '5 hours'),

  -- Transaction 6: CASH DEPOSIT just below threshold → should NOT trigger CTR
  (4, NULL, 'CASH_DEPOSIT', 1999999.99, 'PKR', 'BR-001', 'BRANCH_TELLER',
   'Cash deposit just below threshold — edge case test', now() - interval '6 hours'),

  -- Transaction 7: Suspicious pattern — structuring (for STR testing)
  (5, NULL, 'CASH_DEPOSIT', 1900000.00, 'PKR', 'BR-002', 'BRANCH_TELLER',
   'Deposit just under threshold — possible structuring for TMS alert test', now() - interval '1 day'),

  -- Transaction 8: Suspicious pattern — unusual large transaction (for STR testing)
  (5, NULL, 'WIRE_OUTGOING', 8000000.00, 'PKR', 'BR-002', 'DIGITAL',
   'Large outgoing wire to high-risk jurisdiction — TMS pattern alert test', now() - interval '12 hours')
ON CONFLICT DO NOTHING;
