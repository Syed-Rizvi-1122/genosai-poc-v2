# PRD: UC1 — Customer Onboarding & CDD Orchestration (POC)
**GenosAI AML/CFT/CPF Compliance Automation — Final Year Project**
**Target build tool:** Google Antigravity IDE
**Stack:** n8n (Docker) + PostgreSQL (Docker)
**Status:** v1 — Phase 1 (POC) scope

---

## 1. Objective

Build a rule-driven (deterministic-first) customer onboarding and CDD workflow in n8n, backed by a PostgreSQL schema, that automates the manual CDD process defined in SBP AML/CFT/CPF Regulations, Regulation 1 (Risk Based Approach), Regulation 2 (CDD), Regulation 5 (PEPs), Annexure I, and Annexure II.

The system must be architected to *conceptually* support all 8 RE types and all 14 Annexure II customer categories (via config-driven tables), but only 4 customer-type paths will be fully wired end-to-end in this POC phase.

## 2. Scope

### 2.1 In scope (fully built, tested, demoable)
- **RE type:** Bank (only)
- **Customer types (5, not 4 — correction from earlier draft):**
  1. Individual (incl. Walk-in/Occasional Customer)
  2. Limited Company / Corporation
  3. Trust / Club / Society (`customer_types.code = 'TRUST_CLUB_SOCIETY'`, Annexure II Sr.9) — mandatory EDD
  4. NGO / NPO / Charity (`customer_types.code = 'NGO_NPO'`, Annexure II Sr.10) — mandatory EDD, **separate document set from Trust**
  5. Minor Account

**Correction note:** an earlier draft of this PRD merged Trust and NGO into one "TRUST_NGO" type sharing one document checklist. That was wrong — Annexure II gives them genuinely different document requirements (Trust needs a Trust Deed/Instrument of Trust; NGO needs SECP registration/license, Memorandum & Articles of Association, and Incorporation Form-II or B-29). The schema in Section 4 already correctly lists them as two separate `customer_types` rows — Section 6 below now reflects that correctly too.

### 2.2 In schema, not wired (future phase — represented via config tables only)
- Joint Account, Sole Proprietorship, Small Business/Freelance, Partnership, LLP, Branch/Liaison Office of Foreign Company, Agent's Account, Executors/Administrators, Mentally Disordered Person Account
- RE types: DFI, MFB, EC/EC-B, PSO, PSP, EMI, TPSP

### 2.3 Out of scope entirely for this POC
- Real NADRA Verisys / biometric API integration (mock/stub this — return a simulated verification response)
- Real PEP/sanctions list subscription (use a static seeded table of sample PEP/DP/PP names for demo)
- Core Banking System integration (account creation = insert into local `accounts` table, not a real CBS)

---

## 3. Actors

| Actor | Role |
|---|---|
| Applicant | Person/entity being onboarded |
| Branch Officer | Initiates case, collects documents |
| Compliance Analyst | Reviews CDD file, runs screening, sets risk tier |
| Senior Management (Approver) | Approves EDD/PEP cases before activation |
| System (n8n) | Orchestrates phase transitions, runs deterministic checks |

---

## 4. Database Schema (PostgreSQL)

Design principle: **config-driven, not hardcoded** — applicability of document requirements and EDD triggers by customer-type/RE-type live in data (tables), not in n8n workflow logic, so adding a 15th customer type later is a data insert, not a workflow rebuild.

```sql
-- ============================================
-- REFERENCE / CONFIG TABLES
-- ============================================

CREATE TABLE re_types (
    id SERIAL PRIMARY KEY,
    code VARCHAR(20) UNIQUE NOT NULL,          -- 'BANK','DFI','MFB','EC','PSO','PSP','EMI','TPSP'
    name VARCHAR(100) NOT NULL,
    allows_legal_persons BOOLEAN NOT NULL DEFAULT TRUE,   -- FALSE for EC/EC-B (Def. #27)
    allows_third_party_cdd_reliance BOOLEAN NOT NULL DEFAULT TRUE, -- FALSE for EC/EC-B (Reg 3 §1)
    ngo_trust_regulation_applicable BOOLEAN NOT NULL DEFAULT TRUE, -- FALSE for EC/EC-B (Reg 6 §7)
    notes TEXT
);

CREATE TABLE customer_types (
    id SERIAL PRIMARY KEY,
    code VARCHAR(30) UNIQUE NOT NULL,          -- 'INDIVIDUAL','JOINT','SOLE_PROP','SMALL_BIZ',
                                                -- 'PARTNERSHIP','LLP','COMPANY','FOREIGN_BRANCH',
                                                -- 'TRUST_CLUB_SOCIETY','NGO_NPO','AGENT',
                                                -- 'EXECUTOR_ADMIN','MINOR','MENTALLY_DISORDERED'
    name VARCHAR(100) NOT NULL,
    legal_category VARCHAR(20) NOT NULL,       -- 'NATURAL_PERSON','LEGAL_PERSON','LEGAL_ARRANGEMENT'
    requires_beneficial_owner_check BOOLEAN NOT NULL DEFAULT FALSE,
    requires_governing_body_cdd BOOLEAN NOT NULL DEFAULT FALSE, -- trust/NGO/club
    mandatory_edd BOOLEAN NOT NULL DEFAULT FALSE,   -- TRUE for NGO/NPO/Trust (Reg 6 §1)
    annexure_ii_row INT,                        -- reference to Sr. No in Annexure II
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
    document_type VARCHAR(100) NOT NULL,        -- e.g. 'IDENTITY_DOCUMENT','PARTNERSHIP_DEED'
    is_mandatory BOOLEAN NOT NULL DEFAULT TRUE,
    applies_to_role VARCHAR(50),                 -- 'CUSTOMER','ALL_PARTNERS','ALL_DIRECTORS',
                                                  -- 'GOVERNING_BODY','GUARDIAN', etc.
    regulation_ref VARCHAR(100)                  -- e.g. 'Annexure II Sr.7'
);

-- ============================================
-- CORE CDD CASE / CUSTOMER TABLES
-- ============================================

CREATE TABLE cdd_cases (
    id SERIAL PRIMARY KEY,
    case_ref VARCHAR(30) UNIQUE NOT NULL,        -- e.g. CDD-2026-000123
    re_type_id INT REFERENCES re_types(id),
    customer_type_id INT REFERENCES customer_types(id),
    is_occasional_customer BOOLEAN NOT NULL DEFAULT FALSE,
    current_phase VARCHAR(40) NOT NULL DEFAULT 'INTAKE',
    -- INTAKE, RE_TYPE_GATE, DOC_COLLECTION, IDENTITY_VERIFICATION,
    -- BENEFICIAL_OWNERSHIP, PEP_SCREENING, TFS_SCREENING, RISK_PROFILING,
    -- DD_DETERMINATION, APPROVAL, ACCOUNT_CREATION, COMPLETE, REJECTED
    status VARCHAR(20) NOT NULL DEFAULT 'IN_PROGRESS', -- IN_PROGRESS, APPROVED, REJECTED, ON_HOLD
    opened_at TIMESTAMP NOT NULL DEFAULT now(),
    closed_at TIMESTAMP
);

CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    role VARCHAR(20) NOT NULL DEFAULT 'PRIMARY',  -- PRIMARY, GUARDIAN, DIRECTOR, TRUSTEE, etc.
    full_name VARCHAR(200) NOT NULL,
    mother_maiden_name VARCHAR(200),
    father_spouse_name VARCHAR(200),
    date_of_birth DATE,
    place_of_birth VARCHAR(100),
    permanent_address TEXT,
    current_mailing_address TEXT,
    identity_doc_type VARCHAR(30),               -- CNIC, SNIC, NICOP, PASSPORT, POC, ARC, POR, FORM_B
    identity_doc_number VARCHAR(50),
    identity_doc_issue_date DATE,
    identity_doc_expiry_date DATE,
    contact_mobile VARCHAR(20),
    contact_landline VARCHAR(20),
    email VARCHAR(100),
    nationality_status VARCHAR(20),               -- RESIDENT, NON_RESIDENT
    profession_source_of_income VARCHAR(200),
    purpose_of_relationship TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE legal_entity_details (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    registration_number VARCHAR(50),
    ntn VARCHAR(30),
    date_of_incorporation DATE,
    place_of_incorporation VARCHAR(100),
    nature_of_business TEXT,
    registered_address TEXT,
    expected_monthly_turnover NUMERIC(18,2),
    expected_transaction_count INT
);

CREATE TABLE trust_ngo_details (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    entity_subtype VARCHAR(20),                    -- 'TRUST','NGO','NPO','CHARITY','CLUB','SOCIETY'
    trust_category VARCHAR(20),                     -- 'PUBLIC','PRIVATE' (trusts only)
    settlor_name VARCHAR(200),
    settlor_customer_id INT REFERENCES customers(id),
    objects_of_trust TEXT,
    beneficiary_class_description TEXT,
    financial_statements_reviewed BOOLEAN DEFAULT FALSE
);

CREATE TABLE minor_account_details (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    minor_customer_id INT REFERENCES customers(id),
    guardian_customer_id INT REFERENCES customers(id),
    guardian_type VARCHAR(20) NOT NULL,             -- 'PARENT','COURT_APPOINTED'
    court_order_ref VARCHAR(100)
);

CREATE TABLE beneficial_owners (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    customer_id INT REFERENCES customers(id),        -- links to a 'customers' row with role
    identification_tier VARCHAR(20) NOT NULL,         -- 'OWNERSHIP','CONTROL','SENIOR_OFFICIAL'
                                                        -- per Reg 2 §10(a)/(b)/(c) fallback logic
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
    verification_source VARCHAR(50),                  -- 'NADRA_VERISYS','BIOMETRIC','GAZETTED_OFFICER'
    verified_at TIMESTAMP,
    uploaded_at TIMESTAMP NOT NULL DEFAULT now()
);

-- ============================================
-- SCREENING / RISK / DECISION TABLES
-- ============================================

CREATE TABLE pep_watchlist_seed (        -- static demo seed table, stand-in for real PEP DB
    id SERIAL PRIMARY KEY,
    full_name VARCHAR(200),
    pep_category VARCHAR(20),             -- 'DOMESTIC','FOREIGN','INTL_ORG'
    position_title VARCHAR(200)
);

CREATE TABLE sanctions_watchlist_seed (  -- static demo seed table, stand-in for UNSC/ATA lists
    id SERIAL PRIMARY KEY,
    full_name VARCHAR(200),
    list_type VARCHAR(10)                 -- 'UNSC','ATA'
);

CREATE TABLE pep_screening_results (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    customer_id INT REFERENCES customers(id),
    screened_at TIMESTAMP NOT NULL DEFAULT now(),
    is_pep BOOLEAN NOT NULL DEFAULT FALSE,
    pep_category VARCHAR(20),
    match_confidence NUMERIC(5,2)
);

CREATE TABLE tfs_screening_results (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    customer_id INT REFERENCES customers(id),
    screened_at TIMESTAMP NOT NULL DEFAULT now(),
    match_found BOOLEAN NOT NULL DEFAULT FALSE,
    list_type VARCHAR(10),
    action_taken VARCHAR(30),              -- 'NONE','FROZEN','ESCALATED'
    frozen_at TIMESTAMP,
    fmu_reported_at TIMESTAMP,
    sbp_reported_at TIMESTAMP,
    reported_within_48h BOOLEAN
);

CREATE TABLE risk_profile (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    risk_tier VARCHAR(10) NOT NULL,          -- 'LOW','MEDIUM','HIGH'
    score NUMERIC(6,2),
    scoring_factors JSONB,                   -- e.g. {"customer_type":10,"geography":5,"pep":30}
    assigned_by VARCHAR(100),
    assigned_at TIMESTAMP NOT NULL DEFAULT now(),
    next_review_date DATE
);

-- Reference table: the 8 EDD measures per Reg 2 §17(a)-(h) — NOT a free-text field.
-- Every EDD case must have explicit rows in dd_determination_measures below.
CREATE TABLE edd_measures_reference (
    code VARCHAR(20) PRIMARY KEY,              -- 'EDD_A'..'EDD_H'
    description TEXT NOT NULL,
    regulation_ref VARCHAR(30) NOT NULL
);
-- Seed: EDD_A: Additional customer info (occupation, assets, public DB checks) - Reg 2 §17(a)
--       EDD_B: Additional info on intended nature of business relationship - Reg 2 §17(b)
--       EDD_C: Info on source of funds - Reg 2 §17(c)
--       EDD_D: Additional info on reasons/purpose of transaction - Reg 2 §17(d)
--       EDD_E: Establish source of funds/wealth to rule out proceeds of crime - Reg 2 §17(e)
--       EDD_F: Senior management approval to commence/continue relationship - Reg 2 §17(f)
--       EDD_G: Enhanced ongoing monitoring (frequency + pattern review) - Reg 2 §17(g)
--       EDD_H: First payment via customer's own-name account at similarly-regulated bank - Reg 2 §17(h)

-- Reference table: the 3 SDD measures per Reg 2 §18(a)-(c)
CREATE TABLE sdd_measures_reference (
    code VARCHAR(20) PRIMARY KEY,              -- 'SDD_A'..'SDD_C'
    description TEXT NOT NULL,
    regulation_ref VARCHAR(30) NOT NULL
);
-- Seed: SDD_A: Verify customer/BO identity AFTER business relationship established - Reg 2 §18(a)
--       SDD_B: Reduce ongoing monitoring degree, based on monetary threshold - Reg 2 §18(b)
--       SDD_C: Infer (do not explicitly collect) purpose/nature from transaction type - Reg 2 §18(c)
-- HARD RULE: SDD is NEVER applied if there is any suspicion of ML/TF/PF (Reg 2 §19) —
-- enforce this as a workflow guard, not just a UI hint.

CREATE TABLE dd_determination (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    dd_type VARCHAR(10) NOT NULL,             -- 'SDD','CDD','EDD'
    trigger_reason TEXT,                       -- e.g. 'PEP','NGO_MANDATORY','HIGH_RISK_TIER'
    senior_mgmt_approval_required BOOLEAN DEFAULT FALSE,
    senior_mgmt_approved_by VARCHAR(100),
    senior_mgmt_approved_at TIMESTAMP
);

-- Junction table: which specific measures were actually applied/completed for this case.
-- This is what makes EDD/SDD real and auditable instead of a hollow label.
CREATE TABLE dd_determination_measures (
    id SERIAL PRIMARY KEY,
    dd_determination_id INT REFERENCES dd_determination(id),
    measure_code VARCHAR(20) NOT NULL,          -- FK-like ref to edd_measures_reference or sdd_measures_reference
    is_completed BOOLEAN DEFAULT FALSE,
    evidence_ref VARCHAR(300),                  -- doc/file reference or note proving the measure was done
    completed_at TIMESTAMP
);

CREATE TABLE approvals (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    approver_name VARCHAR(100),
    approver_role VARCHAR(50),
    decision VARCHAR(20),                     -- 'APPROVED','REJECTED','RETURNED_FOR_INFO'
    decision_at TIMESTAMP,
    comments TEXT
);

CREATE TABLE accounts (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    account_number VARCHAR(30) UNIQUE,
    opened_at TIMESTAMP,
    status VARCHAR(20) DEFAULT 'ACTIVE'        -- ACTIVE, DEBIT_BLOCKED, CLOSED
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
```

### 4.1 Seed data required for POC (insert on setup)
- `re_types`: all 8 rows, with correct boolean flags per Section 8.2 of this doc.
- `customer_types`: all 14 rows, flagged correctly (`mandatory_edd = TRUE` for NGO/NPO and Trust rows; `requires_beneficial_owner_check = TRUE` for Company, Partnership, LLP, Trust, NGO, Foreign Branch).
- `document_checklist_config`: populate fully for the 4 in-scope customer types from Annexure II (Individual, Company, Trust/NGO, Minor) — see Section 6.
- `pep_watchlist_seed` / `sanctions_watchlist_seed`: 5–10 fake demo names each for testing match/no-match paths.

---

## 5. n8n Workflow — Step-by-Step (Phase 0 → 10, scoped to Bank + 4 customer types)

Build as **one parent workflow with a Switch node branching into 4 sub-workflows** (one per customer type) after the common intake/gate steps, then rejoining for screening/risk/approval, which are common to all types.

### Phase 0 — Intake & Gate
1. **Webhook Trigger** — receives onboarding application payload (JSON: customer_type_code, applicant fields, RE type — hardcode `re_type = BANK` for POC).
2. **Postgres Node — Lookup** `re_customer_type_applicability` — confirm `is_applicable = TRUE` for (Bank, submitted customer_type). If FALSE → **respond and stop** ("not applicable for this RE type").
3. **Postgres Node — Insert** new row into `cdd_cases` (`current_phase = 'DOC_COLLECTION'`).

### Phase 1 — Document Collection Check
4. **Postgres Node — Lookup** `document_checklist_config` for this customer_type — returns the required document list.
5. **IF Node** — compare submitted documents (from payload) against required list.
   - Missing required doc → **respond** "incomplete submission, missing: [list]" → case stays `ON_HOLD`.
   - Complete → proceed.
6. **Postgres Node — Insert** each submitted document into `documents` table.

### Phase 2 — Identity Verification (mocked)
**Important correction:** identity verification timing is NOT always "before account creation." Per Reg 2 §18(a), an SDD-eligible customer's identity/BO can be verified **after** the relationship is established. So this phase runs in two modes:

7. **Postgres Node — Lookup** preliminary risk indicator (a lightweight pre-score using only customer_type + geography, run BEFORE full Phase 6 scoring) to decide: is this customer *provisionally* SDD-track or not?
   - If provisionally low-risk (no PEP flag yet, not NGO/Trust, domestic individual) → **mark `verification_deferred = TRUE`** on the case, skip full verification now, proceed to account creation with a flag, and schedule verification as a follow-up task (still required, just not gating).
   - Otherwise (Company, Trust/NGO always, or any uncertain case) → verification is gating, proceed as below.
8. **Switch Node** by customer_type (for gating verification path):
   - Individual/Minor/Guardian → **HTTP Request node (mock)** simulating NADRA Verisys call → returns `{verified: true/false}`.
   - Company/Trust/NGO → **Function node** validates registration number format + presence of MOA/AOA or Trust Deed doc records (no external API in POC).
9. **Postgres Node — Update** `documents.verified_at`, `verification_source`.
10. If verification fails → case → `REJECTED`, stop.
11. **Hard guard (Reg 2 §19):** if at ANY later phase (screening, risk profiling) a suspicion of ML/TF/PF is raised, and `verification_deferred = TRUE` was set — immediately force verification to become gating and block further progress until resolved. SDD status is revoked the moment suspicion exists.

### Phase 3 — Beneficial Ownership (Company, Trust/NGO only — skip for Individual, Minor)
10. **IF Node** — `customer_types.requires_beneficial_owner_check = TRUE`?
    - **Company path:** Function node applies 3-tier fallback logic (Reg 2 §10): check ownership % field first (tier=OWNERSHIP); if none >25%, check control-indicator field (tier=CONTROL); if none, default to senior_managing_official field (tier=SENIOR_OFFICIAL). Insert into `beneficial_owners`.
    - **Trust/NGO path:** Insert settlor, trustee(s), protector, beneficiary-class rows directly from `trust_ngo_details` into `beneficial_owners`.

### Phase 4 — PEP Screening (all customer types, including guardian for Minor, all directors/trustees for entities)
11. **Postgres Node** — for every `customers` row in this case (primary + any BO/guardian/trustee rows), string-match `full_name` against `pep_watchlist_seed`.
12. **Insert** results into `pep_screening_results`.
13. **IF Node** — any match, OR `customer_types.mandatory_edd = TRUE` (NGO/Trust) → flag `edd_required = TRUE` downstream.

### Phase 5 — TFS/Sanctions Screening
14. **Postgres Node** — match all case-linked `customers` names against `sanctions_watchlist_seed`.
15. **IF Node** — match found:
    - Update `tfs_screening_results` (`action_taken = 'FROZEN'`, `frozen_at = now()`).
    - **Set Node** compute `reported_within_48h` deadline timestamp = `frozen_at + 48h` (for demo/reporting purposes — actual FMU/SBP reporting is external and out of scope for POC automation).
    - Case → `REJECTED` / on-hold pending investigation, stop main path.
    - No match → proceed.

### Phase 6 — Risk Profiling
16. **Function Node** — deterministic scoring: base score by customer_type + modifiers (PEP +30, NGO/Trust +20, foreign nationality +10, etc. — define exact rubric with your team). Output `risk_tier`.
17. **Postgres Node — Insert** into `risk_profile`.

### Phase 7 — DD Determination
18. **Switch Node** on `risk_tier` + `edd_required` flag from Phase 4, AND enforce the Reg 2 §19 guard (never SDD if any suspicion flag exists anywhere in the case so far):
    - `LOW`, not mandatory-EDD, no suspicion flag → `SDD`
    - `HIGH` or PEP or NGO/Trust or any suspicion flag → `EDD` (set `senior_mgmt_approval_required = TRUE`)
    - else → `CDD`
19. **Postgres Node — Insert** into `dd_determination`.
20. **This is the step that was previously hollow — now made concrete:**
    - **If EDD:** insert one row into `dd_determination_measures` for EACH of EDD_A through EDD_H that applies to this case (not necessarily all 8 — e.g. EDD_H only applies if a first-payment rule is relevant to the product). At minimum, EDD_E (source of funds/wealth) and EDD_F (senior mgmt approval) are always required for every EDD case. Each measure then needs its own micro-step:
      - EDD_C/EDD_E (source of funds/wealth) → **Form/Webhook node** requesting this info from the branch officer if not already in `customers.profession_source_of_income`; block progression until populated.
      - EDD_G (enhanced monitoring) → **Postgres Node** sets a flag on the eventual `accounts` row (`monitoring_tier = 'ENHANCED'`) so downstream transaction-monitoring workflows (UC5, when you build it) can pick this up.
      - EDD_F is satisfied by Phase 8 below.
    - **If SDD:** insert rows for SDD_A (linked to the `verification_deferred` flag from Phase 2), SDD_B (set a reduced monitoring threshold value on the future account), and SDD_C (mark `purpose_of_relationship` as system-inferred from transaction-type category rather than requiring a filled free-text field from the applicant).
    - **If CDD:** no measures table entries needed — CDD is the regulatory baseline (Phases 1-6 already constitute it), no extra add-on steps.

### Phase 8 — Approval
21. **IF Node** — `senior_mgmt_approval_required = TRUE`?
    - TRUE → **Wait/Webhook node** pausing workflow until an external "approve/reject" callback hits a second webhook (simulating a manager clicking approve in a simple UI/Postman call for demo). Insert into `approvals`. On approval, mark the EDD_F row in `dd_determination_measures` as `is_completed = TRUE`.
    - FALSE → auto-proceed (compliance-officer-equivalent auto-sign-off, logged in `audit_log`).
22. **Guard before proceeding to Phase 9:** for EDD cases, verify ALL rows in `dd_determination_measures` for this case have `is_completed = TRUE` before allowing account creation. If any measure is incomplete, case stays `ON_HOLD`.

### Phase 9 — Account Creation
21. **Postgres Node — Insert** into `accounts` (`account_number` generated e.g. via Function node), `case.status = 'APPROVED'`, `current_phase = 'COMPLETE'`.

### Phase 10 — Response
22. **Respond to Webhook** — return case summary JSON (case_ref, status, risk_tier, dd_type, account_number if created).

### Cross-cutting
- **Every Postgres write** should also insert a row into `audit_log` (use n8n's "Execute Workflow" sub-workflow pattern for a reusable audit-logging step, called after each phase).

---

## 6. Document Checklist Config — Seed Values for the 4 In-Scope Customer Types

| customer_type | document_type | applies_to_role | regulation_ref |
|---|---|---|---|
| INDIVIDUAL | IDENTITY_DOCUMENT | CUSTOMER | Annexure II Sr.1 |
| COMPANY | IDENTITY_DOCUMENT | ALL_DIRECTORS | Annexure II Sr.7 |
| COMPANY | BOARD_RESOLUTION | — | Annexure II Sr.7 |
| COMPANY | MEMORANDUM_ARTICLES_OF_ASSOCIATION | — | Annexure II Sr.7 |
| COMPANY | FORM_A_OR_B | — | Annexure II Sr.7 |
| COMPANY | INCORPORATION_FORM_II_OR_FORM_29 | — | Annexure II Sr.7 |
| TRUST_CLUB_SOCIETY | IDENTITY_DOCUMENT | GOVERNING_BODY (members/BoD/trustees) + SETTLOR/PROTECTOR/BENEFICIARIES | Annexure II Sr.9 |
| TRUST_CLUB_SOCIETY | DECLARATION_ON_ULTIMATE_CONTROL_PURPOSE_SOURCE_OF_FUNDS | GOVERNING_BODY | Annexure II Sr.9 |
| TRUST_CLUB_SOCIETY | CERTIFICATE_OF_REGISTRATION_OR_INSTRUMENT_OF_TRUST | — | Annexure II Sr.9 |
| TRUST_CLUB_SOCIETY | BY_LAWS_RULES_REGULATIONS | — | Annexure II Sr.9 |
| TRUST_CLUB_SOCIETY | GOVERNING_BODY_RESOLUTION_TO_OPEN_ACCOUNT | — | Annexure II Sr.9 |
| NGO_NPO | IDENTITY_DOCUMENT | GOVERNING_BODY (members/BoD/trustees) + AUTHORIZED_SIGNATORIES | Annexure II Sr.10 |
| NGO_NPO | REGISTRATION_DOCUMENTS_OR_SECP_LICENSE | — | Annexure II Sr.10 |
| NGO_NPO | MEMORANDUM_ARTICLES_OF_ASSOCIATION | — | Annexure II Sr.10 |
| NGO_NPO | INCORPORATION_FORM_II_OR_B29 | — | Annexure II Sr.10 |
| NGO_NPO | GOVERNING_BODY_RESOLUTION_TO_OPEN_ACCOUNT | — | Annexure II Sr.10 |
| NGO_NPO | ANNUAL_FINANCIAL_STATEMENTS_OR_DISCLOSURES | — | Annexure II Sr.10 (used to assess source/use-of-funds risk per Reg 6) |
| MINOR | IDENTITY_DOCUMENT | CUSTOMER | Annexure II Sr.13 |
| MINOR | IDENTITY_DOCUMENT | GUARDIAN | Annexure II Sr.13 |
| MINOR | COURT_GUARDIAN_ORDER | — | Annexure II Sr.13 (conditional: only if court-appointed) |

(Full 14-type table left as future-phase config work — noted in Section 2.2.)

---

## 7. Test Scenarios (for demo)

1. **Individual, low risk, no PEP/sanctions match** → should go SDD track: `verification_deferred = TRUE`, account created before full verification, SDD_A/B/C measure rows inserted, no senior mgmt approval needed.
2. **Individual who later triggers a suspicion flag after being provisionally SDD** → confirms the Reg 2 §19 guard: verification becomes gating retroactively, SDD is revoked, case blocks until resolved.
3. **Company, no BO ownership >25% found** → tests 3-tier BO fallback to senior_managing_official, should still complete on CDD or EDD track depending on risk score.
4. **Trust (Trust/Club/Society type), mandatory EDD** → confirms correct Trust-specific document set (Trust Instrument, not SECP license), forces EDD path with EDD_E/EDD_F/EDD_G measures populated, senior management approval wait step.
5. **NGO/NPO, mandatory EDD** → confirms correct NGO-specific document set (SECP registration, MOA, Form-II/B-29, annual financials — different from Trust's set), forces EDD path.
6. **Minor with court-appointed guardian** → tests guardian sub-record + court order document requirement.
7. **Any customer type matched against sanctions_watchlist_seed** → should freeze and halt, not proceed to account creation.
8. **Missing mandatory document** → should return incomplete-submission response at Phase 1, not proceed further.
9. **EDD case where senior management approves, but a required EDD measure (e.g. source of funds) is still `is_completed = FALSE`** → account creation must still be blocked per the Phase 8 guard, proving the measures table — not just the approval — gates progression.

---

## 8. Traceability (for sandbox pitch documentation)

| PRD Section | Regulation Clause |
|---|---|
| Phase 0 gate | Def. #27, Reg 3 §1, Reg 6 §7 (RE-type carve-outs) |
| Phase 1 doc collection | Annexure II |
| Phase 2 identity verification | Reg 2 §3-5, Def. #8 |
| Phase 3 beneficial ownership | Reg 2 §9-11 |
| Phase 4 PEP screening | Reg 5 §1 |
| Phase 5 TFS screening | Reg 4 §3, §7 |
| Phase 6-7 risk & DD determination | Reg 1, Reg 2 §16-19 |
| Phase 8 approval | Reg 2 §17(f), Reg 5 §1(b) |
| Numbered accounts prohibition | Reg 2 §12 (enforce: never expose sequential/numbered account as customer-facing identifier) |

---

## 9. Notes for Antigravity

- Build the Postgres schema first as a migration script (`/db/migrations/001_init.sql`), then seed script (`/db/seed/001_seed_config.sql`), before touching n8n.
- Keep all n8n credentials (Postgres connection) in `.env`, never hardcoded — this repo may end up public/semi-public for a sandbox submission.
- Use n8n's built-in "Postgres" node type, not raw HTTP calls to Postgres.
- Export the finished workflow as JSON into `/n8n/workflows/uc1_onboarding_cdd.json` for version control.
