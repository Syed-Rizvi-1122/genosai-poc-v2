-- ============================================================================
-- UC5: Suspicious Transaction Investigation & STR/CTR Pipeline — Database Schema
-- GenosAI AML/CFT/CPF Compliance Automation POC v2
--
-- Regulation References:
--   Reg 7 (Reporting of Transactions — STRs/CTRs)
--   Reg 8 (Record Keeping — 10-year retention)
--   Reg 12 §6 (TMS as STR trigger source)
--   Reg 13 §4(d) (Tipping-off prohibition — STR confidentiality)
--   Reg 2 §21(e) (Examine unusual transactions "as far as possible")
--   AML Act 2010 §7 (CTR threshold, filing deadlines)
--   AML Act 2010 §7D (CDD failure / tip-off-risk STR triggers)
--
-- Design Principles:
--   1. CTR and STR are SEPARATE tracks — mandatory deterministic filing vs.
--      judgment-based investigation. They share only the config table.
--   2. NO workflow path closes or files an STR without a human-submitted
--      decision logged in str_analyst_decisions or str_compliance_officer_signoff.
--   3. CTR filing is deterministic — threshold check is mechanical,
--      human reviews data accuracy only (not the filing decision itself).
--   4. is_confidential on str_cases is a HARD filter — any query serving
--      case data to a non-compliance role MUST exclude confidential rows.
--   5. regulatory_thresholds_config values are NEVER hardcoded in workflow
--      logic — always read from this table at runtime.
-- ============================================================================

-- ============================================================================
-- SHARED CONFIG TABLE (Both CTR & STR Tracks)
-- ============================================================================
-- Stores regulator-set numbers that MUST NOT be hardcoded anywhere in the
-- workflow. Each row includes source attribution and a confirmation flag.
-- If is_confirmed = FALSE, the workflow should emit a warning.
--
-- Note: config_value is NUMERIC for thresholds/counts.
--       config_value_text is for non-numeric values (e.g. STR's "promptly").
--       Both can coexist — use whichever applies.

CREATE TABLE IF NOT EXISTS regulatory_thresholds_config (
    id SERIAL PRIMARY KEY,
    config_key VARCHAR(50) UNIQUE NOT NULL,
    config_value NUMERIC,
    config_value_text VARCHAR(100),
    is_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
    source_note TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

-- ============================================================================
-- CTR TRACK TABLES
-- ============================================================================

-- Transactions table — source of all financial activity.
-- In production, this would be fed by the core banking system (CBS).
-- For the POC, we seed demo transactions and accept webhook inserts.
-- This table is intentionally simple — it is a stand-in for the CBS feed.
CREATE TABLE IF NOT EXISTS transactions (
    id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,                    -- FK to UC1's customers.id
    account_id INT,                              -- FK to UC1's accounts.id (optional for POC)
    transaction_type VARCHAR(30) NOT NULL,        -- 'CASH_DEPOSIT','CASH_WITHDRAWAL','WIRE_INCOMING','WIRE_OUTGOING','OTHER'
    amount NUMERIC(18,2) NOT NULL,
    currency VARCHAR(10) NOT NULL DEFAULT 'PKR',
    branch_code VARCHAR(20),
    channel VARCHAR(30),                         -- 'BRANCH_TELLER','ATM','DIGITAL','COUNTER'
    description TEXT,
    executed_at TIMESTAMP NOT NULL DEFAULT now()
);

-- CTR candidates — transactions flagged for CTR filing.
-- The threshold_applied column snapshots the regulatory config value at flag-time
-- for audit purposes (if the threshold changes later, we know what was used).
-- data_accuracy_status is the ONLY human gate — the "should we file?" decision
-- is deterministic (amount >= threshold + cash type) and NOT subject to review.
CREATE TABLE IF NOT EXISTS ctr_candidates (
    id SERIAL PRIMARY KEY,
    transaction_id INT NOT NULL REFERENCES transactions(id),
    threshold_applied NUMERIC NOT NULL,          -- snapshot of CTR_THRESHOLD_PKR at flag-time
    flagged_at TIMESTAMP NOT NULL DEFAULT now(),
    data_accuracy_status VARCHAR(20) NOT NULL DEFAULT 'PENDING_CHECK',
        -- PENDING_CHECK: awaiting compliance review of data fields
        -- VERIFIED: data confirmed accurate, ready to file
        -- CORRECTION_NEEDED: data has errors, needs re-submission
    verified_by VARCHAR(100),
    verified_at TIMESTAMP
);

-- CTR filings — the actual filed CTR records.
-- filing_reference is a mock FMU submission reference (would be real in production).
-- retention_until is computed: MAX(transaction.executed_at, filed_at) + 10 years
-- (conservative approach per PRD — satisfies both Act §7(4) and Reg 8 §3 anchors).
CREATE TABLE IF NOT EXISTS ctr_filings (
    id SERIAL PRIMARY KEY,
    ctr_candidate_id INT NOT NULL REFERENCES ctr_candidates(id),
    filed_at TIMESTAMP NOT NULL DEFAULT now(),
    filing_reference VARCHAR(50) NOT NULL,       -- mock FMU submission reference
    retention_until DATE NOT NULL                -- computed = GREATEST(executed_at, filed_at) + 10 years
);

-- ============================================================================
-- STR TRACK TABLES
-- ============================================================================

-- STR case triggers — records the source event that created the case.
-- Four trigger types mirror the PRD's four webhook entry points.
-- For CDD_FAILURE_OR_TIPOFF_RISK, trigger_subtype distinguishes:
--   CDD_INCOMPLETE_S7D1: CDD couldn't be completed → STR must be considered
--   CDD_WOULD_TIPOFF_S7D2: pursuing CDD would tip off → skip CDD, file STR directly
CREATE TABLE IF NOT EXISTS str_case_triggers (
    id SERIAL PRIMARY KEY,
    trigger_type VARCHAR(30) NOT NULL,
        -- 'TMS_ALERT','MANUAL_STAFF_OBSERVATION','CROSS_UC_FINDING','CDD_FAILURE_OR_TIPOFF_RISK'
    trigger_subtype VARCHAR(30),
        -- For CDD_FAILURE_OR_TIPOFF_RISK only: 'CDD_INCOMPLETE_S7D1' or 'CDD_WOULD_TIPOFF_S7D2'
    source_reference VARCHAR(200),               -- e.g. TMS alert ID, UC3 designation ID, staff note
    customer_id INT NOT NULL,                    -- FK to UC1's customers.id
    details JSONB,                               -- flexible payload from the trigger source
    triggered_at TIMESTAMP NOT NULL DEFAULT now()
);

-- STR cases — the central case record.
-- review_status is the single source of truth; nothing auto-resolves.
-- is_confidential drives the access-control gate (Reg 13 §4(d)).
-- triage_severity_score is for queue-ordering ONLY — never for auto-deciding.
CREATE TABLE IF NOT EXISTS str_cases (
    id SERIAL PRIMARY KEY,
    trigger_id INT NOT NULL REFERENCES str_case_triggers(id),
    case_ref VARCHAR(30) UNIQUE NOT NULL,
    customer_id INT NOT NULL,
    triage_severity_score NUMERIC(5,2),
    review_status VARCHAR(30) NOT NULL DEFAULT 'PENDING_FIRST_REVIEW',
        -- PENDING_FIRST_REVIEW: case created, awaiting analyst pickup
        -- UNDER_INVESTIGATION: analyst has begun investigation
        -- NEEDS_MORE_INFO: analyst needs additional data
        -- CLOSED_NOT_SUSPICIOUS: human decision — not suspicious (still logged)
        -- RECOMMENDED_FOR_FILING: analyst recommends STR filing
        -- FILED: STR has been filed with FMU
    is_confidential BOOLEAN NOT NULL DEFAULT TRUE,
    opened_at TIMESTAMP NOT NULL DEFAULT now(),
    closed_at TIMESTAMP
);

-- STR investigation log — analyst's examination findings.
-- narrative_draft may be LLM-assisted but narrative_edited_by_human must be
-- explicitly confirmed (not assumed). Reg 2 §21(e) requires examination
-- "as far as possible" of background and purpose.
CREATE TABLE IF NOT EXISTS str_investigation_log (
    id SERIAL PRIMARY KEY,
    str_case_id INT NOT NULL REFERENCES str_cases(id),
    analyst_name VARCHAR(100) NOT NULL,
    transaction_history_reviewed JSONB,           -- snapshot of relevant transactions
    background_purpose_findings TEXT,             -- Reg 2 §21(e) examination notes
    narrative_draft TEXT,                          -- LLM-assisted draft, human-editable
    narrative_edited_by_human BOOLEAN NOT NULL DEFAULT FALSE,
    logged_at TIMESTAMP NOT NULL DEFAULT now()
);

-- STR analyst decisions — the human judgment gate.
-- rationale is NOT NULL — cannot submit a decision without documenting why,
-- even for "close not suspicious" outcomes.
CREATE TABLE IF NOT EXISTS str_analyst_decisions (
    id SERIAL PRIMARY KEY,
    str_case_id INT NOT NULL REFERENCES str_cases(id),
    decision VARCHAR(30) NOT NULL,
        -- 'FILE_STR','CLOSE_NOT_SUSPICIOUS','NEEDS_MORE_INFO'
    rationale TEXT NOT NULL CHECK (length(trim(rationale)) > 0),                      -- mandatory documentation for ALL outcomes
    decided_by VARCHAR(100) NOT NULL,
    decided_at TIMESTAMP NOT NULL DEFAULT now()
);

-- STR compliance officer sign-off — second-tier approval gate.
-- Only compliance officers can access this (enforced by access log role check).
CREATE TABLE IF NOT EXISTS str_compliance_officer_signoff (
    id SERIAL PRIMARY KEY,
    str_case_id INT NOT NULL REFERENCES str_cases(id),
    decision VARCHAR(30) NOT NULL,
        -- 'APPROVED','RETURNED_FOR_REVISION'
    officer_name VARCHAR(100) NOT NULL,
    comments TEXT,
    decided_at TIMESTAMP NOT NULL DEFAULT now()
);

-- STR filings — the actual filed STR records.
-- filing_reference is a mock FMU submission reference.
-- retention_until = last reviewed transaction date + 10 years (Reg 8 §3).
CREATE TABLE IF NOT EXISTS str_filings (
    id SERIAL PRIMARY KEY,
    str_case_id INT NOT NULL REFERENCES str_cases(id),
    filed_at TIMESTAMP NOT NULL DEFAULT now(),
    filing_reference VARCHAR(50) NOT NULL,
    retention_until DATE NOT NULL
);

-- STR access log — every read of a confidential STR case gets logged.
-- This is the POC-level tipping-off detection mechanism (Reg 13 §4(d)).
-- In production, this would be supplemented by Postgres RLS policies.
-- accessed_by_role MUST be 'COMPLIANCE_ANALYST' or 'COMPLIANCE_OFFICER' —
-- anything else is a violation to flag.
CREATE TABLE IF NOT EXISTS str_access_log (
    id SERIAL PRIMARY KEY,
    str_case_id INT NOT NULL REFERENCES str_cases(id),
    accessed_by VARCHAR(100) NOT NULL,
    accessed_by_role VARCHAR(50) NOT NULL,
    access_type VARCHAR(30) NOT NULL DEFAULT 'VIEW',
        -- 'VIEW','INVESTIGATE','DECIDE','SIGNOFF'
    accessed_at TIMESTAMP NOT NULL DEFAULT now()
);
