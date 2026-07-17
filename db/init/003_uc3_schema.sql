-- ============================================================================
-- UC3: PEP Lifecycle Monitoring & Enhanced Due Diligence — Database Schema
-- GenosAI AML/CFT/CPF Compliance Automation POC v2
--
-- Regulation References:
--   Reg 5 (PEPs), Def #12 (Close Associate), Def #28 (Family Member),
--   Def #52 (PEP Definition + Seniority Exclusion), Reg 8 (Record Keeping)
--
-- Design Principle: This schema EXTENDS UC1's tables (customers, beneficial_owners,
-- cdd_cases). It does NOT duplicate them. UC1 migration must run first.
--
-- Human-Gated: Every state transition that matters (match confirmation,
-- relationship classification, seniority determination, approval, monitoring
-- step-down) requires a human-submitted webhook action logged with actor
-- identity and timestamp. There is NO auto-clear, auto-approve, or auto-expire
-- logic anywhere in this schema by design.
-- ============================================================================

-- ============================================================================
-- REFERENCE TABLES
-- ============================================================================

-- Static demo seed table — stand-in for a real PEP/adverse-media data feed.
-- In production, this would be replaced by an API integration to a commercial
-- PEP screening provider (e.g., World-Check, Dow Jones, etc.)
CREATE TABLE IF NOT EXISTS pep_watchlist_source (
    id SERIAL PRIMARY KEY,
    full_name VARCHAR(200) NOT NULL,
    date_of_birth DATE,
    nationality VARCHAR(50),
    position_title VARCHAR(300),
    pep_category VARCHAR(20) NOT NULL,          -- 'FOREIGN','DOMESTIC','INTL_ORG' (Def #52(a)-(c))
    seniority_level VARCHAR(20),                -- 'SENIOR','JUNIOR_MIDDLE' — pre-tagged for Def #52(d) filtering
    source_note TEXT,
    last_updated TIMESTAMP DEFAULT now()
);

-- ============================================================================
-- RE-SCREENING CYCLE / TRIGGER TABLES
-- ============================================================================
-- Tracks each re-screening run. Two trigger types:
--   SCHEDULED  — monthly batch (or other cadence), screens ALL active customers
--   EVENT_TRIGGERED — fires on profile update, BO change, reactivation, etc.

CREATE TABLE IF NOT EXISTS rescreening_cycles (
    id SERIAL PRIMARY KEY,
    cycle_type VARCHAR(20) NOT NULL,             -- 'SCHEDULED','EVENT_TRIGGERED'
    trigger_reason VARCHAR(100),                 -- e.g. 'MONTHLY_BATCH','PROFILE_UPDATE','BO_CHANGE','REACTIVATION'
    triggered_at TIMESTAMP NOT NULL DEFAULT now(),
    status VARCHAR(20) DEFAULT 'RUNNING',        -- RUNNING, COMPLETE
    completed_at TIMESTAMP
);

-- Links individual customers/BOs to a specific re-screening cycle.
-- person_role distinguishes the capacity in which this person is being screened.
CREATE TABLE IF NOT EXISTS rescreening_candidates (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES rescreening_cycles(id),
    customer_id INT NOT NULL,                    -- FK to UC1's customers.id
    person_role VARCHAR(30),                     -- 'PRIMARY_CUSTOMER','BENEFICIAL_OWNER','DIRECTOR','TRUSTEE','GOVERNING_BODY_MEMBER'
    added_at TIMESTAMP DEFAULT now()
);

-- ============================================================================
-- SCREENING / MATCH REVIEW TABLES
-- ============================================================================

-- Raw fuzzy-match results. match_confidence is used ONLY for triage ordering
-- in the analyst queue — it is never a decision input. Every match sits at
-- PENDING_REVIEW until a human explicitly resolves it.
CREATE TABLE IF NOT EXISTS pep_match_candidates (
    id SERIAL PRIMARY KEY,
    rescreening_candidate_id INT REFERENCES rescreening_candidates(id),
    pep_watchlist_source_id INT REFERENCES pep_watchlist_source(id),
    match_confidence NUMERIC(5,2) NOT NULL,      -- name/DOB similarity score — TRIAGE ONLY
    matched_at TIMESTAMP NOT NULL DEFAULT now(),
    -- review_status is the single source of truth; nothing auto-resolves this.
    review_status VARCHAR(30) NOT NULL DEFAULT 'PENDING_REVIEW',
    -- PENDING_REVIEW, CONFIRMED_MATCH, REJECTED_NOT_SAME_PERSON, INCONCLUSIVE_NEEDS_INFO
    reviewed_by VARCHAR(100),
    reviewed_at TIMESTAMP,
    reviewer_notes TEXT
);

-- Explicit close-associate / family-member classification (Def #12 / Def #28).
-- Populated by the analyst as a checklist, never inferred automatically.
-- This is NOT a generic "relationship graph" — it enforces the exact sub-tests
-- defined in the SBP regulations.
CREATE TABLE IF NOT EXISTS relationship_classification (
    id SERIAL PRIMARY KEY,
    pep_match_candidate_id INT REFERENCES pep_match_candidates(id),
    classification_type VARCHAR(20) NOT NULL,    -- 'DIRECT_PEP','CLOSE_ASSOCIATE','FAMILY_MEMBER'

    -- Close associate sub-tests (Def #12) — analyst checks which applies, if any:
    test_joint_beneficial_ownership BOOLEAN DEFAULT FALSE,        -- Def #12(a)
    test_entity_set_up_for_pep_benefit BOOLEAN DEFAULT FALSE,     -- Def #12(b)
    test_reasonably_known_close_connection BOOLEAN DEFAULT FALSE,  -- Def #12(c)

    -- Family member sub-tests (Def #28) — ONLY these three qualify:
    test_is_spouse BOOLEAN DEFAULT FALSE,                          -- Def #28(a)
    test_is_lineal_descendant_ascendant BOOLEAN DEFAULT FALSE,     -- Def #28(b)
    test_is_sibling BOOLEAN DEFAULT FALSE,                         -- Def #28(b)

    classified_by VARCHAR(100),
    classified_at TIMESTAMP
);

-- Def #52(d) seniority/exclusion gate — mandatory check before any formal
-- PEP designation. If the matched person holds a junior or middle-ranking
-- position, they are excluded from PEP classification per the regulation.
CREATE TABLE IF NOT EXISTS seniority_exclusion_check (
    id SERIAL PRIMARY KEY,
    pep_match_candidate_id INT REFERENCES pep_match_candidates(id),
    role_verified TEXT,                           -- the actual position/title checked
    is_senior_enough BOOLEAN,                    -- TRUE = qualifies as PEP, FALSE = excluded per Def #52(d)
    checked_by VARCHAR(100),
    checked_at TIMESTAMP
);

-- ============================================================================
-- FORMAL PEP DESIGNATION & EDD TABLES
-- ============================================================================

-- Once a match survives all gates (human review → relationship classification
-- → seniority check), a formal PEP designation is created here.
-- Per Def #52 "is or has been" — this designation does NOT expire on its own.
-- is_active can ONLY be set FALSE by an explicit senior-management-logged
-- decision, never automatically.
CREATE TABLE IF NOT EXISTS pep_designations (
    id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,                    -- FK to UC1's customers.id
    pep_match_candidate_id INT REFERENCES pep_match_candidates(id),
    designation_type VARCHAR(20) NOT NULL,        -- 'DIRECT_PEP','CLOSE_ASSOCIATE','FAMILY_MEMBER'
    pep_category VARCHAR(20),                     -- 'FOREIGN','DOMESTIC','INTL_ORG'
    designated_at TIMESTAMP NOT NULL DEFAULT now(),
    is_active BOOLEAN NOT NULL DEFAULT TRUE       -- see comment above — never auto-set to FALSE
);

-- Source-of-wealth / source-of-funds evidence collection (Reg 5 §1(c)).
-- The analyst logs each piece of evidence submitted by the customer.
-- reconciled = TRUE only after the analyst has verified the declared source
-- against the documentary evidence.
CREATE TABLE IF NOT EXISTS source_of_wealth_evidence (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT REFERENCES pep_designations(id),
    evidence_type VARCHAR(100),                   -- 'BANK_STATEMENT','ASSET_DECLARATION','SALARY_DISCLOSURE','BUSINESS_OWNERSHIP_PROOF','OTHER'
    file_ref VARCHAR(300),
    declared_source TEXT,
    reconciled BOOLEAN DEFAULT FALSE,             -- TRUE only after analyst reconciles declared vs evidenced source
    reconciliation_notes TEXT,
    reviewed_by VARCHAR(100),
    reviewed_at TIMESTAMP
);

-- Senior management approval for continuing the business relationship
-- with a confirmed PEP (Reg 5 §1(b)).
CREATE TABLE IF NOT EXISTS pep_senior_mgmt_approvals (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT REFERENCES pep_designations(id),
    decision VARCHAR(30),                          -- 'CONTINUE_RELATIONSHIP','EXIT_RELATIONSHIP'
    approver_name VARCHAR(100),
    approver_role VARCHAR(50),
    decision_at TIMESTAMP,
    comments TEXT
);

-- Enhanced monitoring flag propagation (Reg 5 §1(d)).
-- When a PEP designation is confirmed and approved, the customer's account
-- gets flagged for enhanced ongoing monitoring.
CREATE TABLE IF NOT EXISTS enhanced_monitoring_flags (
    id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,                      -- FK to UC1's customers.id
    pep_designation_id INT REFERENCES pep_designations(id),
    monitoring_tier VARCHAR(20) NOT NULL DEFAULT 'ENHANCED', -- 'ENHANCED','STANDARD' (after step-down)
    set_at TIMESTAMP NOT NULL DEFAULT now(),
    set_by VARCHAR(100)
);

-- Tracks monitoring-INTENSITY changes only — never removes the underlying
-- PEP designation. Per Def #52's "is or has been" language, the designation
-- remains on file permanently; only the monitoring intensity changes.
CREATE TABLE IF NOT EXISTS monitoring_intensity_log (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT REFERENCES pep_designations(id),
    previous_tier VARCHAR(20),
    new_tier VARCHAR(20),
    reason TEXT,                                    -- e.g. 'Left public office, 18-month internal observation period completed'
    approved_by VARCHAR(100),                        -- must be senior management
    approved_at TIMESTAMP
);

-- Risk-tiered periodic re-certification scheduling.
-- Drives the next recertification date based on PEP category:
--   Foreign PEP → 6 months
--   Domestic PEP / Intl Org PEP → 12 months
--   Close Associate / Family Member → 12 months
CREATE TABLE IF NOT EXISTS recertification_schedule (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT REFERENCES pep_designations(id),
    risk_tier VARCHAR(10),                            -- drives frequency
    next_recertification_date DATE NOT NULL,
    last_recertified_at TIMESTAMP,
    last_recertified_by VARCHAR(100)
);

-- UC3-specific audit log. Separate from UC1's audit_log to avoid
-- cross-contamination and allow independent querying.
CREATE TABLE IF NOT EXISTS audit_log_uc3 (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT,
    entity_type VARCHAR(50),
    entity_id INT,
    action VARCHAR(100),
    actor VARCHAR(100),
    details JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);
