# SBP CDD/KYC Compliance Automation — Use Case 1: Customer Onboarding & CDD Orchestration

---

## 1. Professional Introduction
This document outlines the design, architectural framework, and compliance mapping for **Use Case 1 (UC1): Customer Onboarding & CDD Orchestration**. Built as a core component of the State Bank of Pakistan (SBP) Compliance Automation Sandbox, this system automates the intake, screening, document verification, risk profiling, and account provisioning workflows required for financial institutions operating under SBP jurisdiction.

This implementation translates the regulatory mandates of the **State Bank of Pakistan (SBP) AML/CFT/CPF Regulations** into a deterministic, config-driven, and fully audited technology stack. Using **n8n** for workflow orchestration, **PostgreSQL** for state and configuration management, and automated test runners to execute regulatory scenarios, this sandbox replicates the operational reality of a compliance office in a retail bank.

---

## 2. Table of Contents
1. [Professional Introduction](#1-professional-introduction)
2. [Executive Purpose & Regulatory Philosophy](#3-executive-purpose--regulatory-philosophy)
3. [Regulatory Mapping & Reference Matrix](#4-regulatory-mapping--reference-matrix)
4. [Customer Documents & Intake Requirements](#5-customer-documents--intake-requirements)
5. [Database Schema & Config-Driven Architecture](#6-database-schema--config-driven-architecture)
6. [Step-by-Step Technical Execution Flow](#7-step-by-step-technical-execution-flow)
7. [Nitty-Gritty Node Configuration Details](#8-nitty-gritty-node-configuration-details)
8. [Automated Test Scenarios & Verification](#9-automated-test-scenarios--verification)

---

## 3. Executive Purpose & Regulatory Philosophy
In legacy banking systems, Customer Due Diligence (CDD) is a fragmented process. Branch officers collect paperwork, compliance officers manually query watchlists, and risk managers use subjective judgment to assign risk scores. This manual process causes operational delays, high false-positive rates, and audit gaps.

**Use Case 1** solves this by establishing a **deterministic, zero-trust onboarding gate**:
* **Config-Driven Validity:** Document checklists, risk rules, and sanction filters are configured in database tables rather than hardcoded in the application layer.
* **Immediate Risk Escalation:** High-risk triggers (e.g., PEPs, Trusts, NPOs) are routed automatically to senior management for review.
* **No Bypass Sanctions Block:** Any sanctions match triggers a hard freeze of assets and rejects the account instantly, complying with SBP TFS regulations.
* **Automated Account Provisioning:** Accounts are created and active only when all regulatory checks and required compliance steps are marked complete in the audit trail.

---

## 4. Regulatory Mapping & Reference Matrix

The workflow enforces compliance with the following sections of the **State Bank of Pakistan (SBP) AML/CFT/CPF Regulations**:

| Regulatory Directive | SBP Clause Reference | Workflow Implementation Mechanism |
| :--- | :--- | :--- |
| **Risk-Based Approach (RBA)** | Regulation 1 §1–§4 | Automatically loads Internal Risk Assessment & Rating (IRAR) parameters based on nationality, customer type, product type, and business nature. |
| **Customer Due Diligence (CDD)** | Regulation 2 §1–§9 | Dictates mandatory verification of identity documents, address, and source of income via config tables. |
| **Identification of Beneficial Owners (BO)** | Regulation 2 §10–§12 | Executes three-tiered beneficial ownership validation (Ownership → Control → Senior Official fallback). |
| **NGO/NPO/Trust Screening** | Regulation 6 §1–§7 | Marks these categories as high risk, enforces mandatory Enhanced Due Diligence (EDD), and prevents auto-activation of accounts. |
| **PEP Approvals** | Regulation 5 §1 | Detects PEP associations and routes cases to Senior Management. |
| **Targeted Financial Sanctions (TFS)** | Regulations 10 & 11 | Screens names against UNSC and national proscribed lists. A positive match triggers an immediate asset freeze and blocks the onboarding process. |
| **Simplified Due Diligence (SDD)** | Regulation 2 §14 / Annexure I | Grants low-risk individuals (salary accounts, basic banking) faster onboarding with deferred document requirements. |

---

## 5. Customer Documents & Intake Requirements

During intake, the system collects structured customer profiles and documents based on the customer type. This meets the standards of **SBP Regulations Annexure II**:

```
                                          ┌──────────────┐
                                          │ Customer ID  │
                                          └──────┬───────┘
                                                 │
                        ┌────────────────────────┼────────────────────────┐
                        ▼                        ▼                        ▼
                ┌──────────────┐         ┌──────────────┐         ┌──────────────┐
                │  Individual  │         │   Company    │         │  Trust / NGO │
                └──────┬───────┘         └──────┬───────┘         └──────┬───────┘
                       │                        │                        │
                       ├─► CNIC / Passport      ├─► Certificate of Inc.  ├─► Trust Deed
                       └─► Proof of Income      ├─► Memo & Articles      ├─► SECP License
                                                ├─► Form A / Form 29     ├─► Trustee List
                                                └─► Board Resolution     └─► Governing Docs
```

### 5.1 Individual Accounts
* **Documents Collected:** Identity Document (CNIC/NICOP/Passport) + Proof of Income/Profession.
* **Regulatory Reason (Annexure II Sr. 1):** Essential for verifying identity and source of funds.
* **Usage:** Enforces identity check (NADRA Verisys stub) and verifies that the provided income source matches the customer profile.

### 5.2 Limited Company Accounts
* **Documents Collected:** Certificate of Incorporation + Memorandum & Articles of Association + Form-II/B-29 (Directors List) + Board Resolution + CNIC of all Directors/Signatories.
* **Regulatory Reason (Annexure II Sr. 5):** Necessary to verify the corporate identity, authorized signers, and corporate structure.
* **Usage:** Enforces document validation rules. Checks that the submitting applicant is listed as an authorized signer or director.

### 5.3 Trusts / Clubs / Societies
* **Documents Collected:** Trust Deed / Charter Document + Certificate of Registration + List of Trustees/Governing Body members + Identity documents of Settlor, Trustees, and Beneficiaries.
* **Regulatory Reason (Annexure II Sr. 9 & Regulation 6):** Verifies the trust's legal status, trustees, settlor, and beneficiaries.
* **Usage:** Enforces mandatory EDD. Enforces document collection rules and ensures that all listed trustees undergo identity screening.

### 5.4 NGOs / NPOs / Charities
* **Documents Collected:** SECP License/Registration + Memorandum of Association + NGO Charter + Financial Statements + CNIC of all Governing Body members.
* **Regulatory Reason (Annexure II Sr. 10 & Regulation 6):** Ensures the legal registration of charity organizations to mitigate money laundering risks.
* **Usage:** Triggers high-risk EDD. Verifies SECP registration and enforces review of the organization's charter and financial statements.

### 5.5 Minor Accounts
* **Documents Collected:** Form-B (Birth Certificate) + Guardian's CNIC + Court Appointment Order (if applicable).
* **Regulatory Reason (Annexure II Sr. 14):** Confirms the minor's identity and establishes the legal authority of the guardian.
* **Usage:** Ensures the legal guardian is linked to the case as an authorized signer, and validates the court order if the guardian is court-appointed.

---

## 6. Database Schema & Config-Driven Architecture

The database schema uses configuration tables to keep the system flexible. To add new customer types or documents, you update the database configuration instead of modifying the n8n workflow code.

```
       ┌──────────────────────┐         ┌──────────────────────┐
       │   customer_types     ├────────►│  document_checklist  │
       └──────────┬───────────┘         └──────────────────────┘
                  │
                  ▼
       ┌──────────────────────┐         ┌──────────────────────┐
       │     cdd_cases        │◄────────┤       customers      │
       └──────────┬───────────┘         └──────────────────────┘
                  │
                  ▼
       ┌──────────────────────┐
       │       accounts       │
       └──────────────────────┘
```

### 6.1 Configuration Schema
```sql
-- RE Types Config
CREATE TABLE re_types (
    id SERIAL PRIMARY KEY,
    code VARCHAR(20) UNIQUE NOT NULL,                            -- 'BANK', 'DFI', etc.
    name VARCHAR(100) NOT NULL,
    allows_legal_persons BOOLEAN NOT NULL DEFAULT TRUE,
    allows_third_party_cdd_reliance BOOLEAN NOT NULL DEFAULT TRUE,
    ngo_trust_regulation_applicable BOOLEAN NOT NULL DEFAULT TRUE
);

-- Customer Types Config
CREATE TABLE customer_types (
    id SERIAL PRIMARY KEY,
    code VARCHAR(30) UNIQUE NOT NULL,                            -- 'INDIVIDUAL', 'COMPANY', 'NGO_NPO', etc.
    name VARCHAR(100) NOT NULL,
    legal_category VARCHAR(20) NOT NULL,                         -- 'NATURAL_PERSON', 'LEGAL_PERSON'
    requires_beneficial_owner_check BOOLEAN NOT NULL DEFAULT FALSE,
    requires_governing_body_cdd BOOLEAN NOT NULL DEFAULT FALSE,
    mandatory_edd BOOLEAN NOT NULL DEFAULT FALSE,
    annexure_ii_row INT
);

-- Document Requirements Map
CREATE TABLE document_checklist_config (
    id SERIAL PRIMARY KEY,
    customer_type_id INT REFERENCES customer_types(id),
    document_type VARCHAR(100) NOT NULL,                          -- 'IDENTITY_DOCUMENT', 'TRUST_DEED', etc.
    is_mandatory BOOLEAN NOT NULL DEFAULT TRUE,
    applies_to_role VARCHAR(50),                                 -- 'CUSTOMER', 'DIRECTOR', 'TRUSTEE'
    regulation_ref VARCHAR(100)
);

-- Internal Risk Assessment & Rating (IRAR) Matrix
CREATE TABLE irar_risk_weights (
    id SERIAL PRIMARY KEY,
    version VARCHAR(10) NOT NULL DEFAULT 'V1',
    dimension VARCHAR(50) NOT NULL,                              -- 'CUSTOMER_TYPE', 'GEOGRAPHY', 'PRODUCT'
    value_key VARCHAR(100) NOT NULL,                             -- 'NGO_NPO', 'NON_RESIDENT', 'CORP_ACCOUNT'
    risk_score NUMERIC(5,2) NOT NULL,                            -- Raw score (0 to 100)
    dimension_weight NUMERIC(3,2) NOT NULL                       -- Percentage weight (e.g. 0.35)
);
```

### 6.2 Transactional Schema
```sql
-- Onboarding Cases
CREATE TABLE cdd_cases (
    id SERIAL PRIMARY KEY,
    case_ref VARCHAR(30) UNIQUE NOT NULL,
    re_type_id INT REFERENCES re_types(id),
    customer_type_id INT REFERENCES customer_types(id),
    is_occasional_customer BOOLEAN NOT NULL DEFAULT FALSE,
    current_phase VARCHAR(40) NOT NULL DEFAULT 'INTAKE',          -- 'INTAKE', 'DOC_COLLECTION', etc.
    status VARCHAR(20) NOT NULL DEFAULT 'IN_PROGRESS',            -- 'IN_PROGRESS', 'APPROVED', 'REJECTED'
    suspicion_flag BOOLEAN DEFAULT FALSE,
    sdd_eligibility_basis VARCHAR(100),
    opened_at TIMESTAMP NOT NULL DEFAULT now(),
    closed_at TIMESTAMP
);

-- Customer Profiles Linked to Cases
CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id),
    role VARCHAR(20) NOT NULL DEFAULT 'PRIMARY',                 -- 'PRIMARY', 'GUARDIAN', 'DIRECTOR'
    full_name VARCHAR(200) NOT NULL,
    date_of_birth DATE,
    identity_doc_type VARCHAR(30),                               -- 'CNIC', 'NICOP', 'PASSPORT', 'FORM_B'
    identity_doc_number VARCHAR(50),
    nationality_status VARCHAR(20),                              -- 'RESIDENT', 'NON_RESIDENT'
    profession_source_of_income VARCHAR(200),
    purpose_of_relationship TEXT
);

-- Risk Metrics and Decisions
CREATE TABLE case_risk_scores (
    id SERIAL PRIMARY KEY,
    case_id INT REFERENCES cdd_cases(id) UNIQUE,
    aggregated_score NUMERIC(5,2) NOT NULL,
    assigned_risk_tier VARCHAR(10) NOT NULL,                      -- 'LOW', 'MEDIUM', 'HIGH'
    due_diligence_type VARCHAR(10) NOT NULL,                     -- 'SDD', 'CDD', 'EDD'
    trigger_basis TEXT NOT NULL
);
```

---

## 7. Step-by-Step Technical Execution Flow

The workflow contains **47 nodes** split across two entry points: **Intake & Screening** and **Manager Approval Callback**.

```
[Flow A: Intake Webhook]
   │
   ▼
[Check RE Type & Code Checklists]
   │
   ▼
[Check Mandatory Docs & Attestation]
   │
   ▼
[Identity Verification (NADRA Stub)]
   │
   ▼
[Sanctions Screen (TFS Block)]
   │
   ▼
[Load IRAR Config & Score Risk]
   │
   ▼
[Is High Risk / EDD Triggered?]
   ├── Yes ──► [Set Case: PENDING_APPROVAL] ──► [Return 200: Case Reference]
   └── No  ──► [Auto-Approve CDD/SDD] ──────► [Create Account & Return 200]

[Flow B: Manager Approval Webhook]
   │
   ▼
[Retrieve Case State by Ref]
   │
   ▼
[Is Decision APPROVED?]
   ├── Yes ──► [Create Account] ──► [Return Account Details]
   └── No  ──► [Set Case: REJECTED] ──► [Return Rejection Status]
```

### Phase 1: Intake & RE Type Validation (Nodes 1–4)
* **Action:** The system receives the JSON onboarding packet. It validates that the requesting entity's type matches the configuration in `re_customer_type_applicability`.
* **Regulatory Reason:** Prevents institutions from offering unauthorized services to restricted client types.

### Phase 2: Document Verification (Nodes 5–12)
* **Action:** Compiles the required document checklist based on the customer type. It then checks the uploaded documents to verify that mandatory documents are present and attested.
* **Regulatory Reason (Annexure II):** Confirms that all legally required onboarding documents are present and verified.

### Phase 3: Identity Verification (Nodes 13–17)
* **Action:** Verifies the CNIC or Form-B against a mock identity register (simulating a NADRA Verisys or biometric API check).
* **Regulatory Reason (Reg 2 §1):** Ensures the customer is a real person and that the identity details are valid.

### Phase 4: Screening (Nodes 18–28)
* **Action:** Performs fuzzy-name matching against a local database containing Sanctions (TFS) and PEP watchlists.
* **Regulatory Reason (Regulations 10, 11 & Regulation 5):** Blocks sanctioned individuals immediately and flags PEP profiles for senior approval.

### Phase 5: Risk Profiling & Due Diligence Classification (Nodes 29–33)
* **Action:** Calculates a weighted risk score (0-100) using the IRAR configuration. Based on this score, it classifies the case into a risk tier:
  * **Low Risk (Score < 30):** SDD pathway (allows deferred verification if applicable).
  * **Medium Risk (Score 30–69):** CDD pathway.
  * **High Risk (Score ≥ 70):** EDD pathway. Enforces mandatory Senior Management approval.
* **Regulatory Reason (Regulation 1):** Applies risk-tiered compliance rules to customer files.

### Phase 6: Manager Approval & Account Activation (Nodes 34–47)
* **Action:** If the case requires approval (due to high risk, PEP, or Trust/NGO status), it enters a `PENDING_APPROVAL` state. The system waits for an asynchronous manager decision webhook. Once approved, the system generates an IBAN, activates the account, and logs the final audit trail.
* **Regulatory Reason (Reg 5 §1 & Reg 6 §1):** Ensures senior management signs off on high-risk accounts before they are activated.

---

## 8. Nitty-Gritty Node Configuration Details

The workflow is built in n8n using standard node types. Key configurations include:

### 8.1 Document Checklist Evaluation (Node 8 - Code)
* **Type:** `n8n-nodes-base.code`
* **Purpose:** Runs a JavaScript evaluation to compare the uploaded files with the mandatory document requirements.
* **Logic:**
```javascript
const mandatoryDocs = $input.all().filter(r => r.json.is_mandatory);
const uploadedDocs = $('Webhook Trigger').first().json.body.documents || [];

let missing = [];
for (let req of mandatoryDocs) {
  let found = uploadedDocs.find(u => u.document_type === req.json.document_type);
  if (!found) {
    missing.push(`${req.json.document_type} is missing`);
  } else if (!found.is_attested) {
    missing.push(`${req.json.document_type} is present but not attested`);
  }
}
return { missing_count: missing.length, details: missing };
```

### 8.2 Risk Scoring Calculation (Node 30 - Code)
* **Type:** `n8n-nodes-base.code`
* **Purpose:** Performs a weighted risk calculation by aggregating risk points loaded from the database:
```javascript
const weights = $('Load IRAR Config').all();
let totalScore = 0;
let triggers = [];

// Customer Type Evaluation
const cTypeWeight = weights.find(w => w.json.dimension === 'CUSTOMER_TYPE' && w.json.value_key === cddCase.customer_type);
if (cTypeWeight) {
  totalScore += parseFloat(cTypeWeight.json.risk_score) * parseFloat(cTypeWeight.json.dimension_weight);
}
// Geography Evaluation
const geoWeight = weights.find(w => w.json.dimension === 'GEOGRAPHY' && w.json.value_key === primaryCustomer.nationality_status);
if (geoWeight) {
  totalScore += parseFloat(geoWeight.json.risk_score) * parseFloat(geoWeight.json.dimension_weight);
}

let tier = 'MEDIUM';
if (totalScore < 30) tier = 'LOW';
if (totalScore >= 70) tier = 'HIGH';

return { aggregated_score: totalScore.toFixed(2), assigned_risk_tier: tier };
```

---

## 9. Automated Test Scenarios & Verification

The integration script `/tests/uc1_onboarding/test_onboarding.sh` verifies the workflow using the following test cases:

```
[Execute Test Runner]
   │
   ├─► Payload 1: Low-Risk Individual ──► SDD Path ────────► Account Created Immediately (200)
   ├─► Payload 2: High-Risk NGO ─────────► EDD Path ────────► Returns PENDING_APPROVAL (200)
   ├─► Payload 3: Sanctions Match ──────► TFS Trigger ──────► 403 Frozen Status
   └─► Payload 4: Missing Docs ──────────► Doc Check Gate ──► 422 Unprocessable Details
```

### Test Scenario 1: Individual Low Risk (SDD Path)
* **Payload:** `01_individual_low_risk.json`
* **Details:** Resident Pakistani opening a salary account.
* **Expected Result:** Qualifies for SDD. Account is created immediately, returning a standard IBAN and `LOW` risk rating.

### Test Scenario 2: High-Risk NGO (EDD Path)
* **Payload:** `04_ngo_high_risk.json`
* **Details:** SECP registered NGO.
* **Expected Result:** Enforces mandatory EDD. The API returns a `PENDING_APPROVAL` status. The account remains locked until the manager approval webhook is called.

### Test Scenario 3: Targeted Financial Sanctions Match (TFS Block)
* **Payload:** `07_sanctions_match.json`
* **Details:** Customer name contains a proscribed name match (e.g., "Abdul Qadir Mujahid").
* **Expected Result:** Enforces TFS block. The API returns an HTTP `403 Forbidden` status with details of the sanctions match. The case is marked `REJECTED` in the database, and the account is blocked.

### Test Scenario 4: Attestation Check Fail
* **Payload:** `08_missing_documents.json`
* **Details:** Company onboarding submission is missing the Board Resolution document.
* **Expected Result:** Enforces document validation rules. The API returns an HTTP `422 Unprocessable Entity` status listing the missing documents.
