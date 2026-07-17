-- ============================================================================
-- UC1: Customer Onboarding & CDD Orchestration — Database Schema
-- GenosAI AML/CFT/CPF Compliance Automation POC v2
--
-- Regulation References:
--   Reg 1 (Risk Based Approach), Reg 2 (CDD), Reg 4 (TFS),
--   Reg 5 (PEPs), Reg 6 (NGO/NPO/Trust), Annexure I, Annexure II
--
-- Design Principle: Config-driven, not hardcoded. Adding a new customer type
-- or RE type is a data insert, not a workflow rebuild.
-- ============================================================================

-- n8n uses its own schema for internal metadata (referenced in docker-compose)
CREATE SCHEMA IF NOT EXISTS n8n_internal;

-- ============================================================================
-- IRAR CONFIG TABLE (Regulation 1 §2-§8)
-- ============================================================================
-- The Internal Risk Assessment Report (IRAR) is a BoD-approved document that
-- defines how the bank categorizes ML/TF/PF risk. This table codifies its
-- output as structured, queryable config that Phase 6 (Risk Profiling) uses
-- to calculate per-customer risk scores.
--
-- In real life: the IRAR is a periodic strategic document. Here we store its
-- risk scoring parameters so the workflow reads from config, not hardcoded logic.
-- ============================================================================

CREATE TABLE irar_config (
    id SERIAL PRIMARY KEY,
    config_version VARCHAR(20) NOT NULL,           -- e.g. 'V1', 'V2' — tracks IRAR revisions
    is_active BOOLEAN NOT NULL DEFAULT TRUE,        -- only one version active at a time
    approved_by VARCHAR(100),                       -- BoD approval reference (Reg 1 §8)
    approved_at TIMESTAMP,

    -- Risk scoring weights (used in Phase 6 risk calculation)
    -- These weights are added to the base score when the condition is true
    weight_customer_type_high NUMERIC(5,2) DEFAULT 20,    -- e.g. NGO/Trust/Charity
    weight_customer_type_medium NUMERIC(5,2) DEFAULT 10,  -- e.g. Company
    weight_pep_match NUMERIC(5,2) DEFAULT 30,             -- direct PEP match
    weight_pep_family NUMERIC(5,2) DEFAULT 20,            -- PEP family/close associate
    weight_foreign_nationality NUMERIC(5,2) DEFAULT 10,
    weight_high_risk_geography NUMERIC(5,2) DEFAULT 15,   -- Counter Measures Rules 2020
    weight_large_expected_turnover NUMERIC(5,2) DEFAULT 10,
    weight_complex_ownership NUMERIC(5,2) DEFAULT 10,     -- multi-layered BO structures

    -- Risk tier thresholds
    threshold_low_max NUMERIC(6,2) DEFAULT 25,       -- score 0-25 = LOW
    threshold_medium_max NUMERIC(6,2) DEFAULT 55,     -- score 26-55 = MEDIUM
    -- score above threshold_medium_max = HIGH

    -- DD assignment rules (Reg 1 §6)
    sdd_allowed_for_low BOOLEAN DEFAULT TRUE,
    edd_required_for_high BOOLEAN DEFAULT TRUE,
    edd_mandatory_for_ngo_trust BOOLEAN DEFAULT TRUE,   -- Conservative policy (Reg 6 §1)
    edd_mandatory_for_pep BOOLEAN DEFAULT TRUE,         -- Reg 5 §1

    -- Metadata
    regulation_ref VARCHAR(100) DEFAULT 'Reg 1 §2-§8',
    notes TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

-- ============================================================================
-- REFERENCE / CONFIG TABLES
-- ============================================================================

CREATE TABLE re_types (
    id SERIAL PRIMARY KEY,
    code VARCHAR(20) UNIQUE NOT NULL,               -- 'BANK','DFI','MFB','EC','EC_B','PSO','PSP','EMI','TPSP'
    name VARCHAR(100) NOT NULL,
    allows_legal_persons BOOLEAN NOT NULL DEFAULT TRUE,    -- FALSE for EC/EC-B (Def. #27)
    allows_third_party_cdd_reliance BOOLEAN NOT NULL DEFAULT TRUE, -- FALSE for EC/EC-B (Reg 3 §1)
    ngo_trust_regulation_applicable BOOLEAN NOT NULL DEFAULT TRUE, -- FALSE for EC/EC-B (Reg 6 §7)
    notes TEXT
);

CREATE TABLE customer_types (
    id SERIAL PRIMARY KEY,
    code VARCHAR(30) UNIQUE NOT NULL,
    -- Valid codes: 'INDIVIDUAL','JOINT','SOLE_PROP','SMALL_BIZ',
    --   'PARTNERSHIP','LLP','COMPANY','FOREIGN_BRANCH',
    --   'TRUST_CLUB_SOCIETY','NGO_NPO','AGENT',
    --   'EXECUTOR_ADMIN','MINOR','MENTALLY_DISORDERED'
    name VARCHAR(100) NOT NULL,
    legal_category VARCHAR(20) NOT NULL,            -- 'NATURAL_PERSON','LEGAL_PERSON','LEGAL_ARRANGEMENT'
    requires_beneficial_owner_check BOOLEAN NOT NULL DEFAULT FALSE,
    requires_governing_body_cdd BOOLEAN NOT NULL DEFAULT FALSE,   -- trust/NGO/club (Reg 6 §3)
    mandatory_edd BOOLEAN NOT NULL DEFAULT FALSE,
    -- NOTE on mandatory_edd: For NGO_NPO and TRUST_CLUB_SOCIETY, this is set to TRUE
    -- as a CONSERVATIVE POLICY CHOICE. Reg 6 §1 says "when the risks are higher" —
    -- our IRAR config (edd_mandatory_for_ngo_trust = TRUE) operationalizes this as
    -- "always" since risk-based NGO/Trust assessment is beyond POC scope.
    annexure_ii_row INT,                             -- reference to Sr. No in Annexure II
    notes TEXT
);

CREATE TABLE re_customer_type_applicability (
    id SERIAL PRIMARY KEY,
    re_type_id INT REFERENCES re_types(id),
    customer_type_id INT REFERENCES customer_types(id),
    is_applicable BOOLEAN NOT NULL DEFAULT TRUE,
    notes TEXT,
    UNIQUE(re_type_id, customer_type_id)
);

CREATE TABLE document_checklist_config (
    id SERIAL PRIMARY KEY,
    customer_type_id INT REFERENCES customer_types(id),
    document_type VARCHAR(100) NOT NULL,             -- e.g. 'IDENTITY_DOCUMENT','PARTNERSHIP_DEED'
    is_mandatory BOOLEAN NOT NULL DEFAULT TRUE,
    applies_to_role VARCHAR(50),
    -- Valid roles: 'CUSTOMER','ALL_PARTNERS','ALL_DIRECTORS',
    --   'GOVERNING_BODY','GUARDIAN','SETTLOR','PROTECTOR',
    --   'BENEFICIARIES','AUTHORIZED_SIGNATORIES','SENIOR_OFFICIAL'
    is_conditional BOOLEAN NOT NULL DEFAULT FALSE,   -- TRUE = only required under certain conditions
    condition_description TEXT,                        -- e.g. 'Only if court-appointed guardian'
    regulation_ref VARCHAR(100)                       -- e.g. 'Annexure II Sr.7'
);

-- ============================================================================
-- CORE CDD CASE / CUSTOMER TABLES
-- ============================================================================

CREATE TABLE cdd_cases (
    id SERIAL PRIMARY KEY,
    case_ref VARCHAR(30) UNIQUE NOT NULL,             -- e.g. CDD-2026-000123
    re_type_id INT REFERENCES re_types(id),
    customer_type_id INT REFERENCES customer_types(id),
    is_occasional_customer BOOLEAN NOT NULL DEFAULT FALSE,
    current_phase VARCHAR(40) NOT NULL DEFAULT 'INTAKE',
    -- Valid phases: INTAKE, RE_TYPE_GATE, DOC_COLLECTION, IDENTITY_VERIFICATION,
    --   BENEFICIAL_OWNERSHIP, PEP_SCREENING, TFS_SCREENING, RISK_PROFILING,
    --   DD_DETERMINATION, APPROVAL, ACCOUNT_CREATION, COMPLETE, REJECTED
    status VARCHAR(20) NOT NULL DEFAULT 'IN_PROGRESS',
    -- Valid statuses: IN_PROGRESS, APPROVED, REJECTED, ON_HOLD
    verification_deferred BOOLEAN NOT NULL DEFAULT FALSE,  -- SDD track: verify after relationship
    sdd_eligibility_basis VARCHAR(50),                 -- References IRAR config version (Issue #2)
    -- e.g. 'IRAR_CONFIG_V1' — documents WHY SDD was applied
    -- In production, this MUST reference the active IRAR per Reg 1 §6
    suspicion_flag BOOLEAN NOT NULL DEFAULT FALSE,     -- Reg 2 §19: if TRUE, SDD is NEVER allowed
    opened_at TIMESTAMP NOT NULL DEFAULT now(),
    closed_at TIMESTAMP
);

CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    role VARCHAR(20) NOT NULL DEFAULT 'PRIMARY',
    -- Valid roles: PRIMARY, GUARDIAN, DIRECTOR, TRUSTEE, SETTLOR,
    --   PROTECTOR (Issue #4), BENEFICIARY, AUTHORIZED_SIGNATORY,
    --   GOVERNING_BODY_MEMBER, SENIOR_OFFICIAL
    full_name VARCHAR(200) NOT NULL,
    mother_maiden_name VARCHAR(200),                   -- Annexure I #2
    father_spouse_name VARCHAR(200),                   -- Annexure I #8
    date_of_birth DATE,                                -- Annexure I #3
    place_of_birth VARCHAR(100),                       -- Annexure I #4
    permanent_address TEXT,                             -- Annexure I #5
    current_mailing_address TEXT,                       -- Annexure I #13
    identity_doc_type VARCHAR(30),
    -- Valid types: CNIC, SNIC, NICOP, SNICOP, PASSPORT, POC, ARC, POR, FORM_B
    -- Per Definition #34 in regulations
    identity_doc_number VARCHAR(50),                   -- Annexure I #6
    identity_doc_issue_date DATE,                      -- Annexure I #9
    identity_doc_expiry_date DATE,                     -- Annexure I #7
    -- NOTE (Annexure II Note 3): Production systems MUST generate alerts about
    -- CNIC expiry at least 1 month before actual date of expiry. This alert
    -- mechanism is deferred to UC5 (ongoing monitoring).
    contact_mobile VARCHAR(20),                        -- Annexure I #10
    contact_landline VARCHAR(20),                      -- Annexure I #10
    email VARCHAR(100),                                -- Annexure I #14
    nationality_status VARCHAR(20),                    -- Annexure I #15 (RESIDENT / NON_RESIDENT)
    profession_source_of_income VARCHAR(200),          -- Annexure I #17
    purpose_of_relationship TEXT,                       -- Annexure I #11
    next_of_kin VARCHAR(200),                          -- Annexure I #18 (Issue #3)
    fatca_crs_declared BOOLEAN DEFAULT FALSE,          -- Annexure I #16 (Issue #3)
    photo_ref VARCHAR(300),                            -- Annexure I #19 — passport-size photo ref
    live_photo_ref VARCHAR(300),                       -- Annexure I #20 — live photo for digital onboarding
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE legal_entity_details (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    registration_number VARCHAR(50),                   -- Annexure I D.1
    ntn VARCHAR(30),                                   -- Annexure I D.4
    date_of_incorporation DATE,                        -- Annexure I D.2
    place_of_incorporation VARCHAR(100),               -- Annexure I D.3
    nature_of_business TEXT,                            -- Annexure I D.5
    registered_address TEXT,                            -- Annexure I D.6
    expected_monthly_turnover NUMERIC(18,2),           -- Annexure I D.10
    expected_transaction_count INT                      -- Annexure I D.10
);

CREATE TABLE trust_ngo_details (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    entity_subtype VARCHAR(20),                         -- 'TRUST','NGO','NPO','CHARITY','CLUB','SOCIETY'
    trust_category VARCHAR(20),                         -- 'PUBLIC','PRIVATE' (Annexure I E.13, trusts only)
    settlor_name VARCHAR(200),                         -- Annexure I E.15
    settlor_customer_id INT REFERENCES customers(id),
    objects_of_trust TEXT,                              -- Annexure I E.16
    beneficiary_class_description TEXT,                 -- Annexure I E.18 / Def #11
    financial_statements_reviewed BOOLEAN DEFAULT FALSE -- Annexure II Sr.10 item 3
);

CREATE TABLE minor_account_details (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    minor_customer_id INT REFERENCES customers(id),
    guardian_customer_id INT REFERENCES customers(id),
    guardian_type VARCHAR(20) NOT NULL,                  -- 'PARENT','COURT_APPOINTED'
    court_order_ref VARCHAR(100)                         -- Annexure II Sr.13 item 2 (conditional)
);

CREATE TABLE beneficial_owners (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    customer_id INT REFERENCES customers(id),            -- links to a 'customers' row
    identification_tier VARCHAR(20) NOT NULL,
    -- Reg 2 §10(a)/(b)/(c) fallback logic:
    --   'OWNERSHIP'       — natural person with controlling ownership interest
    --   'CONTROL'         — natural person exercising control through other means
    --   'SENIOR_OFFICIAL' — relevant natural person holding senior managing position
    ownership_percentage NUMERIC(5,2),
    verified BOOLEAN DEFAULT FALSE,
    verification_method VARCHAR(50)
);

CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    customer_id INT REFERENCES customers(id),
    document_type VARCHAR(100) NOT NULL,
    file_ref VARCHAR(300),
    is_attested BOOLEAN DEFAULT FALSE,
    attested_by VARCHAR(100),
    -- Annexure II Note 1: Documents must be EITHER:
    --   (a) attested by Gazetted officer/Nazim/Administrator/RE officer after original seen, OR
    --   (b) verified via NADRA Verisys or Biometric Verification
    -- The workflow enforces: (is_attested AND attested_by IS NOT NULL) OR
    --   verification_source IN ('NADRA_VERISYS', 'BIOMETRIC')
    verification_source VARCHAR(50),                    -- 'NADRA_VERISYS','BIOMETRIC','GAZETTED_OFFICER'
    verified_at TIMESTAMP,
    uploaded_at TIMESTAMP NOT NULL DEFAULT now()
);

-- ============================================================================
-- SCREENING / RISK / DECISION TABLES
-- ============================================================================

-- Static demo seed table — stand-in for real PEP database
CREATE TABLE pep_watchlist_seed (
    id SERIAL PRIMARY KEY,
    full_name VARCHAR(200),
    pep_category VARCHAR(20),                           -- 'DOMESTIC','FOREIGN','INTL_ORG' (Def #52)
    relationship_type VARCHAR(30) NOT NULL DEFAULT 'DIRECT',
    -- 'DIRECT' — the person themselves is a PEP
    -- 'FAMILY_MEMBER' — spouse/lineal descendant/ascendant/sibling (Def #28)
    -- 'CLOSE_ASSOCIATE' — joint BO/business relations/connected person (Def #12)
    related_pep_name VARCHAR(200),                      -- if FAMILY_MEMBER or CLOSE_ASSOCIATE, who is the PEP
    position_title VARCHAR(200)
);

-- Static demo seed table — stand-in for UNSC/ATA sanctions lists
CREATE TABLE sanctions_watchlist_seed (
    id SERIAL PRIMARY KEY,
    full_name VARCHAR(200),
    list_type VARCHAR(10)                               -- 'UNSC','ATA'
);

CREATE TABLE pep_screening_results (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    customer_id INT REFERENCES customers(id),
    screened_at TIMESTAMP NOT NULL DEFAULT now(),
    is_pep BOOLEAN NOT NULL DEFAULT FALSE,
    pep_category VARCHAR(20),                           -- 'DOMESTIC','FOREIGN','INTL_ORG'
    relationship_to_pep VARCHAR(50),                    -- Issue #7: 'DIRECT','FAMILY_MEMBER','CLOSE_ASSOCIATE'
    match_confidence NUMERIC(5,2)
);

CREATE TABLE tfs_screening_results (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    customer_id INT REFERENCES customers(id),
    screened_at TIMESTAMP NOT NULL DEFAULT now(),
    match_found BOOLEAN NOT NULL DEFAULT FALSE,
    list_type VARCHAR(10),                              -- 'UNSC','ATA'
    action_taken VARCHAR(30),                           -- 'NONE','FROZEN','ESCALATED'
    frozen_at TIMESTAMP,
    fmu_reported_at TIMESTAMP,                          -- Reg 4 §7(b)
    sbp_reported_at TIMESTAMP,                          -- Reg 4 §7(c) — within 48h of freezing
    reported_within_48h BOOLEAN
);

CREATE TABLE risk_profile (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    irar_config_id INT REFERENCES irar_config(id),      -- Links to the IRAR version used
    risk_tier VARCHAR(10) NOT NULL,                     -- 'LOW','MEDIUM','HIGH'
    score NUMERIC(6,2),
    scoring_factors JSONB,
    -- e.g. {"customer_type":10,"pep":30,"geography":0,"turnover":0}
    assigned_by VARCHAR(100),
    assigned_at TIMESTAMP NOT NULL DEFAULT now(),
    next_review_date DATE
);

-- Reference table: the 8 EDD measures per Reg 2 §17(a)-(h)
CREATE TABLE edd_measures_reference (
    code VARCHAR(20) PRIMARY KEY,                       -- 'EDD_A'..'EDD_H'
    description TEXT NOT NULL,
    regulation_ref VARCHAR(30) NOT NULL
);

-- Reference table: the 3 SDD measures per Reg 2 §18(a)-(c)
CREATE TABLE sdd_measures_reference (
    code VARCHAR(20) PRIMARY KEY,                       -- 'SDD_A'..'SDD_C'
    description TEXT NOT NULL,
    regulation_ref VARCHAR(30) NOT NULL
);

CREATE TABLE dd_determination (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    dd_type VARCHAR(10) NOT NULL,                       -- 'SDD','CDD','EDD'
    trigger_reason TEXT,                                 -- e.g. 'PEP','NGO_MANDATORY','HIGH_RISK_TIER'
    senior_mgmt_approval_required BOOLEAN DEFAULT FALSE,
    senior_mgmt_approved_by VARCHAR(100),
    senior_mgmt_approved_at TIMESTAMP
);

-- Junction table: which specific EDD/SDD measures were applied to this case
-- This makes DD real and auditable — not just a hollow label
CREATE TABLE dd_determination_measures (
    id SERIAL PRIMARY KEY,
    dd_determination_id INT REFERENCES dd_determination(id),
    measure_code VARCHAR(20) NOT NULL,                  -- refs edd_measures_reference or sdd_measures_reference
    is_completed BOOLEAN DEFAULT FALSE,
    evidence_ref VARCHAR(300),                          -- doc/file reference proving measure was done
    completed_at TIMESTAMP
);

CREATE TABLE approvals (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    approver_name VARCHAR(100),
    approver_role VARCHAR(50),
    decision VARCHAR(20),                               -- 'APPROVED','REJECTED','RETURNED_FOR_INFO'
    decision_at TIMESTAMP,
    comments TEXT
);

CREATE TABLE accounts (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    account_number VARCHAR(30) UNIQUE,
    monitoring_tier VARCHAR(20) DEFAULT 'STANDARD',     -- 'STANDARD','ENHANCED' (EDD_G sets ENHANCED)
    opened_at TIMESTAMP,
    status VARCHAR(20) DEFAULT 'ACTIVE'                 -- ACTIVE, DEBIT_BLOCKED, CLOSED
);

CREATE TABLE audit_log (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    entity_type VARCHAR(50),
    entity_id INT,
    action VARCHAR(100),
    actor VARCHAR(100),
    details JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);
