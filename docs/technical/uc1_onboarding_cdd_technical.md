# UC1: Customer Onboarding & CDD Orchestration — Technical Document

**Version:** 1.0  
**Workflow File:** `n8n/workflows/uc1_onboarding_cdd.json`  
**Schema File:** `db/init/001_schema.sql`  
**Seed File:** `db/init/002_seed_config.sql`  
**Node Count:** 49  
**Flows:** 2 (Intake & Screening + Manager Approval Callback)

---

## 1. Executive Summary

### 1.1 Problem Statement
When a new customer approaches a bank to open an account, the bank must perform Customer Due Diligence (CDD) before activating the account. In legacy banking systems, this process is fragmented: branch officers collect paperwork, compliance officers manually query watchlists, and risk managers use subjective judgment to assign risk scores. This causes delays, high false-positive rates, and audit gaps.

### 1.2 What This Workflow Does
UC1 automates the **end-to-end customer onboarding pipeline**: from intake and document validation, through identity verification, sanctions screening, PEP checks, risk scoring, due diligence classification, senior management approval routing, to final account creation.

### 1.3 SBP Regulatory Basis
- **Regulation 1** — Risk-Based Approach (IRAR-driven risk scoring)
- **Regulation 2** — Customer Due Diligence (document verification, beneficial ownership)
- **Regulation 5** — PEP screening and senior management approvals
- **Regulation 6** — NGO/NPO/Trust mandatory Enhanced Due Diligence
- **Regulations 10 & 11** — Targeted Financial Sanctions screening
- **Annexure I** — Customer data fields specification
- **Annexure II** — Document requirements per customer type

### 1.4 Target Users
| Role | Interaction |
|---|---|
| Branch Officer | Submits onboarding payload via the intake webhook |
| Compliance Analyst | Reviews automated screening results |
| Senior Management | Approves high-risk cases via the approval webhook |
| Auditor | Reads audit_log table for compliance verification |

---

## 2. Regulatory Mapping & Reference Matrix

| # | Regulatory Directive | SBP Clause | Workflow Node(s) | Implementation |
|---|---|---|---|---|
| 1 | Risk-Based Approach | Reg 1 §1–§4 | Node 27–28 | Loads IRAR config, calculates weighted risk score across customer type, geography, PEP status, and ownership complexity |
| 2 | Customer Due Diligence | Reg 2 §1–§9 | Nodes 7–12 | Config-driven document checklist validation per customer type |
| 3 | Beneficial Ownership | Reg 2 §10–§12 | Node 18 | Three-tiered BO identification: Ownership (>25%) → Control → Senior Official fallback |
| 4 | PEP Detection | Reg 5 §1 | Nodes 44–45 | Exact-match name screening against PEP watchlist seed |
| 5 | NGO/Trust Mandatory EDD | Reg 6 §1–§7 | Node 28 | `mandatory_edd = true` flag on customer_types config forces EDD path |
| 6 | Targeted Financial Sanctions | Reg 10 & 11 | Nodes 21–25 | Screens against UNSC/ATA sanctions lists; match triggers immediate asset freeze |
| 7 | Simplified Due Diligence | Reg 2 §14 / Annexure I | Node 28 | Low-risk individuals (<25 score) routed to SDD with deferred verification |
| 8 | Senior Management Sign-off | Reg 5 §1(b) | Nodes 31, 46–48 | High-risk/PEP/NGO/Trust cases require async manager approval before account activation |

---

## 3. Process Flow Diagram

### 3.1 Flow A: Intake & Screening (47 nodes)

```
POST /webhook/uc1-onboarding
   │
   ▼
[Node 1: Webhook Trigger] ──► [Node 2: RE Type Gate Lookup]
                                       │
                              [Node 3: IF: Applicable?]
                                 ├── No  ──► [Node 4: Respond: Not Applicable (400)]
                                 └── Yes ──► [Node 5: Insert CDD Case]
                                                │
                                       [Node 6: Insert Primary Customer]
                                                │
                                       [Node 7: Load Document Checklist]
                                                │
                                       [Node 8: Check Documents & Attestation]
                                                │
                                       [Node 9: IF: Documents Complete?]
                                          ├── No ──► [Node 10: Block: Missing Documents]
                                          │              └──► [Node 11: Respond: Incomplete Docs (422)]
                                          └── Yes ──► [Node 12: Insert Documents]
                                                          │
                                                 [Node 13: Identity Verification (Mock)]
                                                          │
                                                 [Node 14: IF: Verification Passed?]
                                                    ├── No ──► [Node 15: Case → REJECTED]
                                                    │              └──► [Node 16: Respond: Verification Failed (422)]
                                                    └── Yes ──► [Node 17: Update Verification Status]
                                                                    │
                                                           [Node 18: Beneficial Ownership Check]
                                                                    │
                                                           [Node 19: Insert BO Records]
                                                                    │
                                                           [Node 44: PEP Screening]
                                                                    │
                                                           [Node 45: Process PEP Results]
                                                                    │
                                                           [Node 20: Insert PEP Results]
                                                                    │
                                                           [Node 21: TFS Screening]
                                                                    │
                                                           [Node 22: Process TFS Results]
                                                                    │
                                                           [Node 23: IF: No Sanctions Match?]
                                                              ├── No ──► [Node 24: FREEZE & Reject]
                                                              │              └──► [Node 25: Respond: Frozen (403)]
                                                              └── Yes ──► [Node 26: Insert TFS Clear Results]
                                                                              │
                                                                     [Node 27: Load IRAR Config]
                                                                              │
                                                                     [Node 28: Risk Profiling & DD Determination]
                                                                              │
                                                                     [Node 29: Insert Risk & DD]
                                                                              │
                                                                     [Node 30: Insert DD Measures]
                                                                              │
                                                                     [Node 31: IF: Sr Mgmt Approval Needed?]
                                                                        ├── Yes ──► [Node 46: Respond: Pending Approval (202)]
                                                                        └── No  ──► [Node 36: Auto-Approve (CDD/SDD)]
                                                                                        │
                                                                               [Node 37: Check All Measures Complete]
                                                                                        │
                                                                               [Node 38: IF: Measures Complete?]
                                                                                  ├── No ──► [Node 39: Block] → [Node 40: Respond (422)]
                                                                                  └── Yes ──► [Node 41: Generate Account Number]
                                                                                                  │
                                                                                         [Node 42: Create Account]
                                                                                                  │
                                                                                         [Node 43: Respond: Success (201)]
```

### 3.2 Flow B: Manager Approval Callback (3 nodes + shared downstream)

```
POST /webhook/uc1-approve-case
   │
   ▼
[Node 47: Manager Approval Webhook] ──► [Node 48: Get Case Details by Ref]
                                                │
                                       [Node 32: Process Approval Decision]
                                                │
                                       [Node 33: IF: Approved?]
                                          ├── No  ──► [Node 34: Case → REJECTED] → [Node 35: Respond (403)]
                                          └── Yes ──► [Node 37: Check All Measures Complete]
                                                          │ (continues to Node 38–43 as above)
```

---

## 4. Database Schema & ERD

### 4.1 Configuration Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `irar_config` | IRAR risk scoring weights and thresholds | `weight_pep_match`, `threshold_low_max`, `threshold_medium_max`, `edd_mandatory_for_ngo_trust` |
| `re_types` | Regulated Entity types (Bank, DFI, MFB, etc.) | `code`, `allows_legal_persons`, `allows_third_party_cdd_reliance` |
| `customer_types` | Customer categories | `code`, `legal_category`, `mandatory_edd`, `requires_beneficial_owner_check` |
| `re_customer_type_applicability` | Maps which RE types can onboard which customer types | `re_type_id`, `customer_type_id`, `is_applicable` |
| `document_checklist_config` | Required documents per customer type | `customer_type_id`, `document_type`, `is_mandatory`, `applies_to_role` |

### 4.2 Transactional Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `cdd_cases` | Tracks each onboarding case | `case_ref`, `current_phase`, `status`, `suspicion_flag`, `verification_deferred` |
| `customers` | Customer profiles linked to cases | `full_name`, `identity_doc_type`, `nationality_status`, `profession_source_of_income` |
| `legal_entity_details` | Company-specific details | `registration_number`, `ntn`, `nature_of_business` |
| `trust_ngo_details` | Trust/NGO-specific details | `entity_subtype`, `settlor_name`, `objects_of_trust` |
| `minor_account_details` | Minor account-specific details | `guardian_type`, `court_order_ref` |
| `beneficial_owners` | Beneficial ownership records | `identification_tier` (OWNERSHIP/CONTROL/SENIOR_OFFICIAL), `ownership_percentage` |
| `documents` | Uploaded document records | `document_type`, `is_attested`, `verification_source` |
| `pep_screening_results` | PEP screening outcomes | `is_pep`, `pep_category`, `relationship_to_pep` |
| `tfs_screening_results` | TFS/Sanctions screening outcomes | `match_found`, `list_type`, `action_taken` |
| `risk_profile` | Calculated risk tier and score | `risk_tier`, `score`, `scoring_factors` (JSONB) |
| `dd_determination` | Due diligence classification | `dd_type` (SDD/CDD/EDD), `trigger_reason` |
| `dd_determination_measures` | Individual DD measures applied | `measure_code`, `is_completed`, `evidence_ref` |
| `approvals` | Manager approval/rejection records | `approver_name`, `approver_role`, `decision` |
| `accounts` | Activated accounts | `account_number`, `monitoring_tier`, `status` |
| `audit_log` | Full audit trail | `entity_type`, `action`, `actor`, `details` (JSONB) |

### 4.3 ERD Relationships

```
re_types ──┐
           ├──► re_customer_type_applicability
customer_types ─┘
           │
           └──► document_checklist_config
           └──► cdd_cases ──► customers ──► beneficial_owners
                    │              │              └──► documents
                    │              └──► pep_screening_results
                    │              └──► tfs_screening_results
                    ├──► risk_profile
                    ├──► dd_determination ──► dd_determination_measures
                    ├──► approvals
                    ├──► accounts
                    └──► audit_log
```

---

## 5. API / Webhook Reference

### 5.1 Endpoint: Onboarding Intake

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc1-onboarding` |
| **Response Mode** | `Respond to Webhook node` (explicit response nodes) |
| **Content-Type** | `application/json` |

#### Request Body Schema

```json
{
  "customer_type_code": "INDIVIDUAL | COMPANY | NGO_NPO | TRUST_CLUB_SOCIETY | MINOR | ...",
  "is_occasional_customer": false,
  "suspicion_flag": false,
  "applicant": {
    "full_name": "string (required)",
    "mother_maiden_name": "string",
    "father_spouse_name": "string",
    "date_of_birth": "YYYY-MM-DD | null",
    "place_of_birth": "string",
    "permanent_address": "string",
    "current_mailing_address": "string",
    "identity_doc_type": "CNIC | NICOP | PASSPORT | FORM_B | ...",
    "identity_doc_number": "string",
    "identity_doc_issue_date": "YYYY-MM-DD",
    "identity_doc_expiry_date": "YYYY-MM-DD",
    "contact_mobile": "string",
    "contact_landline": "string",
    "email": "string",
    "nationality_status": "RESIDENT | NON_RESIDENT",
    "profession_source_of_income": "string",
    "purpose_of_relationship": "string",
    "next_of_kin": "string",
    "fatca_crs_declared": true
  },
  "beneficial_owners": [
    {
      "full_name": "string",
      "ownership_percentage": 10.00,
      "has_control": false
    }
  ],
  "senior_managing_official": {
    "full_name": "string",
    "ownership_percentage": 0.00,
    "role": "SENIOR_OFFICIAL"
  },
  "documents": [
    {
      "document_type": "IDENTITY_DOCUMENT | BOARD_RESOLUTION | TRUST_DEED | ...",
      "applies_to_role": "CUSTOMER | ALL_DIRECTORS | GOVERNING_BODY | null",
      "file_ref": "/path/to/file.pdf",
      "is_attested": true,
      "attested_by": "string | null",
      "verification_source": "NADRA_VERISYS | BIOMETRIC | GAZETTED_OFFICER"
    }
  ]
}
```

#### Response Schemas

**Success (HTTP 201):**
```json
{
  "status": "APPROVED",
  "case_ref": "CDD-2026-000123",
  "risk_tier": "LOW",
  "risk_score": 10.00,
  "dd_type": "SDD",
  "dd_trigger": "No triggers — standard CDD path",
  "account_number": "PK-1ABC2D-XYZ789",
  "monitoring_tier": "STANDARD",
  "irar_version": "V1",
  "verification_deferred": false
}
```

**Pending Approval (HTTP 202):**
```json
{
  "status": "PENDING_APPROVAL",
  "case_ref": "CDD-2026-000124",
  "reason": "Case requires senior management approval (EDD/PEP/Trust/NGO/High Risk)"
}
```

**Not Applicable (HTTP 400):**
```json
{
  "status": "REJECTED",
  "reason": "Customer type not applicable for this RE type (Bank)",
  "customer_type_code": "INVALID_CODE"
}
```

**Missing Documents (HTTP 422):**
```json
{
  "status": "ON_HOLD",
  "case_ref": "CDD-2026-000125",
  "reason": "Incomplete mandatory documents",
  "missing_documents": ["BOARD_RESOLUTION is missing", "TRUST_DEED is present but not attested"]
}
```

**Sanctions Match / Frozen (HTTP 403):**
```json
{
  "status": "FROZEN",
  "case_ref": "CDD-2026-000126",
  "reason": "TFS/Sanctions match detected — account frozen per Reg 4 §7",
  "matches": [{"customer_name": "...", "list_type": "UNSC"}]
}
```

**Verification Failed (HTTP 422):**
```json
{
  "status": "REJECTED",
  "case_ref": "CDD-2026-000127",
  "reason": "Identity verification failed"
}
```

#### Example curl

```bash
curl -s -X POST http://localhost:5678/webhook/uc1-onboarding \
  -H "Content-Type: application/json" \
  -d @tests/uc1_onboarding/payloads/01_individual_low_risk.json
```

---

### 5.2 Endpoint: Manager Approval

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc1-approve-case` |
| **Response Mode** | `Respond to Webhook node` |
| **Content-Type** | `application/json` |

#### Request Body Schema

```json
{
  "case_ref": "CDD-2026-000124",
  "decision": "APPROVED | REJECTED",
  "approver_name": "Compliance Officer",
  "approver_role": "SENIOR_MANAGEMENT"
}
```

#### Response Schemas

**Approved (HTTP 201):**
```json
{
  "status": "APPROVED",
  "case_ref": "CDD-2026-000124",
  "risk_tier": "HIGH",
  "dd_type": "EDD",
  "account_number": "PK-1DEF3G-HIJ456",
  "monitoring_tier": "ENHANCED"
}
```

**Rejected (HTTP 403):**
```json
{
  "status": "REJECTED",
  "case_ref": "CDD-2026-000124",
  "reason": "Rejected by senior management"
}
```

#### Example curl

```bash
curl -s -X POST http://localhost:5678/webhook/uc1-approve-case \
  -H "Content-Type: application/json" \
  -d '{"case_ref": "CDD-2026-000124", "decision": "APPROVED", "approver_name": "Compliance Officer", "approver_role": "SENIOR_MANAGEMENT"}'
```

---

## 6. Node-by-Node Configuration

### Flow A: Intake & Screening

---

#### Node 1: Webhook Trigger

| Property | Value |
|---|---|
| **Type** | `webhook` |
| **Method** | `POST` |
| **Path** | `uc1-onboarding` |
| **Response Mode** | `Respond to Webhook node` |
| **Receives** | Raw HTTP POST body with onboarding payload |
| **Forwards** | `$json.body.*` — the parsed request body to all downstream nodes |

---

#### Node 2: RE Type Gate Lookup

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Operation** | Execute Query |
| **Receives** | `$json.body.customer_type_code` from Node 1 |
| **Forwards** | RE type config flags: `is_applicable`, `re_type_id`, `customer_type_id`, `mandatory_edd`, `requires_beneficial_owner_check`, etc. |

**SQL Query:**
```sql
SELECT 
  rca.is_applicable, 
  rt.code as re_code, 
  rt.name as re_name, 
  rt.allows_legal_persons, 
  ct.code as ct_code, 
  ct.name as ct_name, 
  ct.legal_category, 
  ct.requires_beneficial_owner_check, 
  ct.requires_governing_body_cdd, 
  ct.mandatory_edd, 
  ct.id as customer_type_id, 
  rt.id as re_type_id 
FROM re_customer_type_applicability rca 
JOIN re_types rt ON rca.re_type_id = rt.id 
JOIN customer_types ct ON rca.customer_type_id = ct.id 
WHERE rt.code = 'BANK' AND ct.code = '{{ $json.body.customer_type_code }}' 
LIMIT 1;
```

---

#### Node 3: IF: Applicable?

| Property | Value |
|---|---|
| **Type** | `if` |
| **Condition** | `{{ $json.is_applicable }}` equals `true` |
| **Output 0 (True)** | → Node 5: Insert CDD Case |
| **Output 1 (False)** | → Node 4: Respond: Not Applicable |

---

#### Node 4: Respond: Not Applicable

| Property | Value |
|---|---|
| **Type** | `respondToWebhook` |
| **HTTP Code** | `400` |
| **Receives** | Customer type code from webhook |
| **Response Body** | `{ "status": "REJECTED", "reason": "Customer type not applicable for this RE type (Bank)" }` |

---

#### Node 5: Insert CDD Case

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Operation** | Execute Query |
| **Receives** | `re_type_id`, `customer_type_id` from Node 2; `is_occasional_customer`, `suspicion_flag` from Node 1 |
| **Forwards** | `id`, `case_ref`, `suspicion_flag` of the newly created case |

**SQL Query:**
```sql
INSERT INTO cdd_cases (
  case_ref, re_type_id, customer_type_id, 
  is_occasional_customer, suspicion_flag, 
  current_phase, status
) VALUES ( 
  'CDD-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('cdd_cases_id_seq')::text, 6, '0'), 
  {{ $('RE Type Gate Lookup').item.json.re_type_id }}, 
  {{ $('RE Type Gate Lookup').item.json.customer_type_id }}, 
  {{ $('Webhook Trigger').item.json.body.is_occasional_customer || false }}, 
  {{ $('Webhook Trigger').item.json.body.suspicion_flag || false }}, 
  'DOC_COLLECTION', 
  'IN_PROGRESS' 
) RETURNING id, case_ref, suspicion_flag;
```

---

#### Node 6: Insert Primary Customer

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Operation** | Execute Query |
| **Receives** | `case_id` from Node 5; applicant fields from Node 1 webhook body |
| **Forwards** | All applicant fields plus `case_id`, `customer_id`, RE type flags, and customer type flags |

**SQL Query:**
```sql
INSERT INTO customers (
  case_id, role, full_name, mother_maiden_name, father_spouse_name,
  date_of_birth, place_of_birth, permanent_address, current_mailing_address,
  identity_doc_type, identity_doc_number, identity_doc_issue_date,
  identity_doc_expiry_date, contact_mobile, contact_landline, email,
  nationality_status, profession_source_of_income, purpose_of_relationship,
  next_of_kin, fatca_crs_declared
) VALUES (
  {{ $json.id }},
  'PRIMARY',
  '{{ $('Webhook Trigger').item.json.body.applicant.full_name }}',
  -- ... all Annexure I fields mapped from webhook body ...
) RETURNING id as customer_id;

SELECT 
  {{ $json.id }} as case_id,
  '{{ $('Insert CDD Case').item.json.case_ref }}' as case_ref,
  -- ... merged output of all fields for downstream use ...
```

---

#### Node 7: Load Document Checklist

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Operation** | Execute Query |
| **Receives** | `customer_type_id` from Node 2 |
| **Forwards** | Array of mandatory document requirements (`document_type`, `is_mandatory`, `applies_to_role`) |

**SQL Query:**
```sql
SELECT document_type, is_mandatory, applies_to_role, condition_description, regulation_ref 
FROM document_checklist_config 
WHERE customer_type_id = {{ $('RE Type Gate Lookup').item.json.customer_type_id }} 
  AND is_mandatory = TRUE;
```

---

#### Node 8: Check Documents & Attestation

| Property | Value |
|---|---|
| **Type** | `code` (JavaScript) |
| **Mode** | Run Once for All Items |
| **Receives** | Mandatory doc list from Node 7; uploaded docs from webhook body |
| **Forwards** | `missing_count`, `missing_details[]`, plus all upstream data (case_id, case_ref, customer_type_code, etc.) |

**JavaScript Code:**
```javascript
const mandatoryDocs = $input.all().filter(r => r.json.is_mandatory);
const uploadedDocs = $('Webhook Trigger').first().json.body.documents || [];
const caseData = $('Insert Primary Customer').first().json;

let missing = [];
for (let req of mandatoryDocs) {
  let found = uploadedDocs.find(u => u.document_type === req.json.document_type);
  if (!found) {
    missing.push(`${req.json.document_type} is missing`);
  } else if (!found.is_attested && !found.verification_source) {
    missing.push(`${req.json.document_type} is present but not attested or verified`);
  }
}

return [{
  json: {
    ...caseData,
    customer_type_code: $('RE Type Gate Lookup').first().json.ct_code,
    mandatory_edd: $('RE Type Gate Lookup').first().json.mandatory_edd,
    requires_beneficial_owner_check: $('RE Type Gate Lookup').first().json.requires_beneficial_owner_check,
    missing_count: missing.length,
    missing_details: missing
  }
}];
```

---

#### Node 9: IF: Documents Complete?

| Property | Value |
|---|---|
| **Type** | `if` |
| **Condition** | `{{ $json.missing_count }}` equals `0` |
| **Output 0 (True)** | → Node 12: Insert Documents |
| **Output 1 (False)** | → Node 10: Block: Missing Documents |

---

#### Node 10: Block: Missing Documents

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Receives** | `case_id` and missing document details |
| **Does** | Updates case status to `ON_HOLD`, logs the block action in `audit_log` |

---

#### Node 11: Respond: Incomplete Docs

| Property | Value |
|---|---|
| **Type** | `respondToWebhook` |
| **HTTP Code** | `422` |
| **Response Body** | Returns `ON_HOLD` status with list of missing/unattested documents |

---

#### Node 12: Insert Documents

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Receives** | Document array from webhook body, `case_id` and `customer_id` |
| **Does** | Bulk-inserts all uploaded documents into the `documents` table |

---

#### Node 13: Identity Verification (Mock)

| Property | Value |
|---|---|
| **Type** | `code` (JavaScript) |
| **Receives** | Customer data, customer type code, document type |
| **Does** | Simulates NADRA Verisys / biometric verification. For SDD-eligible individuals, marks verification as deferred. For minors, validates Form-B. |
| **Forwards** | `verification_passed`, `verification_deferred`, `verification_method`, and all upstream data |

---

#### Node 14: IF: Verification Passed?

| Property | Value |
|---|---|
| **Type** | `if` |
| **Condition** | `{{ $json.verification_passed }}` equals `true` |
| **Output 0 (True)** | → Node 17: Update Verification Status |
| **Output 1 (False)** | → Node 15: Case → REJECTED |

---

#### Node 15–16: Rejection Path (Verification Failed)

| Node | Does |
|---|---|
| Node 15 | Updates `cdd_cases` status to `REJECTED`, phase to `REJECTED` |
| Node 16 | Returns HTTP 422 with rejection reason |

---

#### Node 17: Update Verification Status

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Updates `cdd_cases.current_phase` to `BENEFICIAL_OWNERSHIP` and sets `verification_deferred` flag |

---

#### Node 18: Beneficial Ownership Check

| Property | Value |
|---|---|
| **Type** | `code` (JavaScript) |
| **Receives** | Customer type code, `requires_beneficial_owner_check` flag, `beneficial_owners[]` array from webhook |
| **Does** | Implements **Reg 2 §10(a)-(c)** three-tiered BO identification: |
|  | 1. **Ownership tier**: Finds natural persons with controlling ownership interest (>25%) |
|  | 2. **Control tier**: If no majority owner, identifies persons exercising control through other means |
|  | 3. **Senior Official fallback**: If neither found, falls back to the senior managing official |
| **Forwards** | `bo_records[]` array with `identification_tier` set per record |

---

#### Node 19: Insert BO Records

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Uses a PL/pgSQL `DO $$ ... $$` block to iterate over the BO records JSON array and insert each into `beneficial_owners` table |

---

#### Node 44: PEP Screening

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Joins `customers` against `pep_watchlist_seed` using exact name matching (case-insensitive via `LOWER()`) |
| **Forwards** | Array of customers with `is_pep`, `pep_category`, `relationship_type`, `position_title` |

**SQL Query:**
```sql
SELECT 
  c.id as customer_id, c.full_name, c.role, 
  CASE WHEN pw.id IS NOT NULL THEN TRUE ELSE FALSE END as is_pep,
  pw.pep_category, pw.relationship_type, pw.related_pep_name, pw.position_title 
FROM customers c 
LEFT JOIN pep_watchlist_seed pw ON LOWER(c.full_name) = LOWER(pw.full_name) 
WHERE c.case_id = {{ $('Check Documents & Attestation').item.json.case_id }};
```

---

#### Node 45: Process PEP Results

| Property | Value |
|---|---|
| **Type** | `code` (JavaScript) |
| **Does** | Filters PEP matches, sets `has_pep_match` and `edd_from_pep` flags |
| **Forwards** | Merged data with `pep_matches[]`, `all_screened_persons[]`, and `edd_from_pep` boolean |

---

#### Node 20: Insert PEP Results

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Bulk-inserts PEP screening results into `pep_screening_results` table via PL/pgSQL loop |

---

#### Node 21: TFS Screening

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Joins `customers` against `sanctions_watchlist_seed` using exact name matching |
| **Forwards** | Array with `is_sanctioned`, `list_type` per customer |

**SQL Query:**
```sql
SELECT 
  c.id as customer_id, c.full_name, c.role, 
  CASE WHEN sw.id IS NOT NULL THEN TRUE ELSE FALSE END as is_sanctioned,
  sw.list_type 
FROM customers c 
LEFT JOIN sanctions_watchlist_seed sw ON LOWER(c.full_name) = LOWER(sw.full_name) 
WHERE c.case_id = {{ $('Check Documents & Attestation').item.json.case_id }};
```

---

#### Node 22: Process TFS Results

| Property | Value |
|---|---|
| **Type** | `code` (JavaScript) |
| **Does** | Separates sanctioned matches from clear results. Sets `has_sanctions_match` flag. |
| **Forwards** | `tfs_matches[]`, `all_tfs_screened[]`, `has_sanctions_match` |

---

#### Node 23: IF: No Sanctions Match?

| Property | Value |
|---|---|
| **Type** | `if` |
| **Condition** | `{{ $json.has_sanctions_match }}` equals `false` |
| **Output 0 (True = no match)** | → Node 26: Insert TFS Clear Results |
| **Output 1 (False = match found)** | → Node 24: FREEZE & Reject |

---

#### Node 24–25: Sanctions Freeze Path

| Node | Does |
|---|---|
| Node 24 | Inserts TFS results with `action_taken = 'FROZEN'`, updates case to `REJECTED`, logs asset freeze in audit_log |
| Node 25 | Returns HTTP 403 with freeze details and matched sanctions list type |

---

#### Node 26: Insert TFS Clear Results

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Inserts clear TFS screening results with `action_taken = 'NONE'` |

---

#### Node 27: Load IRAR Config

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Loads the active IRAR configuration (`is_active = TRUE`) with all risk weights and thresholds |

**SQL Query:**
```sql
SELECT * FROM irar_config WHERE is_active = TRUE LIMIT 1;
```

---

#### Node 28: Risk Profiling & DD Determination

| Property | Value |
|---|---|
| **Type** | `code` (JavaScript) |
| **Receives** | Upstream data (PEP results, TFS results, customer type, nationality) + IRAR config weights |
| **Does** | **This is the core risk scoring engine.** Calculates a weighted score (0–100) based on: |
|  | - Customer type weight (NGO/Trust = high, Company = medium) |
|  | - PEP match weight |
|  | - Geography weight (non-resident = higher) |
|  | - Ownership complexity weight |
|  | Determines risk tier: LOW (<25), MEDIUM (25–55), HIGH (>55) |
|  | Determines DD type: SDD (low, no suspicion), CDD (medium), EDD (high/PEP/NGO/Trust) |
|  | Determines if senior management approval is needed |
| **Forwards** | `risk_tier`, `risk_score`, `dd_type`, `dd_trigger_reason`, `needs_senior_approval`, `scoring_factors` |

---

#### Node 29: Insert Risk & DD

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Inserts risk profile and DD determination records. Creates the `dd_determination` with `dd_type` and `trigger_reason`. |

---

#### Node 30: Insert DD Measures

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Uses PL/pgSQL to insert the appropriate DD measures (EDD_A through EDD_H for EDD, SDD_A through SDD_C for SDD) into `dd_determination_measures` |

---

#### Node 31: IF: Sr Mgmt Approval Needed?

| Property | Value |
|---|---|
| **Type** | `if` |
| **Condition** | `{{ $json.needs_senior_approval }}` equals `true` |
| **Output 0 (True)** | → Node 46: Respond: Pending Approval |
| **Output 1 (False)** | → Node 36: Auto-Approve |

---

#### Node 36: Auto-Approve (CDD/SDD)

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Inserts an auto-approval record into `approvals` table with `approver_name = 'Auto-Approved'` and logs in `audit_log` |

---

#### Node 37: Check All Measures Complete

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Joins `cdd_cases`, `risk_profile`, `dd_determination`, and `dd_determination_measures` to check if all required DD measures are completed. For EDD cases, specifically checks if measure `EDD_F` is completed. |
| **Forwards** | `all_measures_complete`, `total_measures`, `completed_measures`, plus case/risk/DD metadata |

---

#### Node 38: IF: Measures Complete?

| Property | Value |
|---|---|
| **Type** | `if` |
| **Condition** | `{{ $json.all_measures_complete }}` equals `true` |
| **Output 0 (True)** | → Node 41: Generate Account Number |
| **Output 1 (False)** | → Node 39: Block |

---

#### Node 39–40: Measures Incomplete Block

| Node | Does |
|---|---|
| Node 39 | Updates case status to `ON_HOLD`, logs the block in audit_log |
| Node 40 | Returns HTTP 422 with measures completion status |

---

#### Node 41: Generate Account Number

| Property | Value |
|---|---|
| **Type** | `code` (JavaScript) |
| **Does** | Generates a unique account number (`PK-{timestamp}-{random}`). Sets `monitoring_tier` to `ENHANCED` for EDD cases, `STANDARD` otherwise. |

---

#### Node 42: Create Account

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Inserts the account record, updates case to `APPROVED` / `COMPLETE`, logs in audit_log |

---

#### Node 43: Respond: Success

| Property | Value |
|---|---|
| **Type** | `respondToWebhook` |
| **HTTP Code** | `201` |
| **Response Body** | Full success response with account number, risk tier, DD type, monitoring tier |

---

#### Node 46: Respond: Pending Approval

| Property | Value |
|---|---|
| **Type** | `respondToWebhook` |
| **HTTP Code** | `202` |
| **Response Body** | Returns case_ref and reason for pending status |

---

### Flow B: Manager Approval Callback

#### Node 47: Manager Approval Webhook

| Property | Value |
|---|---|
| **Type** | `webhook` |
| **Method** | `POST` |
| **Path** | `uc1-approve-case` |
| **Response Mode** | `Respond to Webhook node` |

---

#### Node 48: Get Case Details by Ref

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Looks up case, risk profile, and DD determination by `case_ref` |

**SQL Query:**
```sql
SELECT 
  c.id as case_id, c.status, c.current_phase, 
  rp.risk_tier, dd.dd_type, dd.id as dd_determination_id 
FROM cdd_cases c
LEFT JOIN risk_profile rp ON c.id = rp.case_id 
LEFT JOIN dd_determination dd ON c.id = dd.case_id 
WHERE c.case_ref = '{{ $('Manager Approval Webhook').first().json.body.case_ref }}'
ORDER BY dd.id DESC LIMIT 1;
```

---

#### Node 32: Process Approval Decision

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Inserts the manager's decision into `approvals` table and logs in `audit_log` |

---

#### Node 33–35: Approval Decision Gate

| Node | Does |
|---|---|
| Node 33 | IF: Approved? — routes based on manager decision |
| Node 34 | If rejected: updates case to REJECTED |
| Node 35 | Returns HTTP 403 with rejection status |

If approved, flow continues to Node 37 → 38 → 41 → 42 → 43 (same as Flow A).

---

#### Node 49: Send Compliance Email

| Property | Value |
|---|---|
| **Type** | `emailSend` |
| **Credentials** | AML SMTP (Gmail) |
| **Does** | Sends styled HTML compliance notification email upon account creation |

---

## 7. Error Handling & Edge Cases

| Error Condition | How It's Handled | HTTP Code | Response |
|---|---|---|---|
| Invalid customer type code | Node 2 returns empty result; Node 3 routes to rejection | `400` | Not Applicable |
| Missing mandatory documents | Node 8 compiles missing list; Node 9 routes to block | `422` | ON_HOLD with missing list |
| Identity verification failure | Node 13 returns `verification_passed = false`; Node 14 routes to rejection | `422` | REJECTED |
| Sanctions match (UNSC/ATA) | Node 22 detects match; Node 23 routes to freeze | `403` | FROZEN with match details |
| EDD measures incomplete | Node 37 checks completion; Node 38 routes to block | `422` | ON_HOLD with measure counts |
| Manager rejects case | Node 33 routes to rejection path | `403` | REJECTED |
| Suspicion flag on SDD-eligible | Node 28 forces CDD/EDD even if score is low (Reg 2 §19) | N/A | Internal routing change |

---

## 8. Security & Access Control

### 8.1 Credential Management
| Credential | Type | Usage |
|---|---|---|
| `AML Postgres` (ID: `jAJgSFNohrcTMvPV`) | PostgreSQL | All database operations |
| `AML SMTP` (ID: `8Rb60oaV0VVNTtzH`) | SMTP/Gmail | Compliance notification emails |

### 8.2 Access Control
- **Intake webhook** (`uc1-onboarding`): Open — accepts any POST with valid JSON
- **Approval webhook** (`uc1-approve-case`): Open — but approval records are logged with `approver_name` and `approver_role` for audit
- **Audit trail**: Every state transition, approval, and account creation is logged in `audit_log` with actor identity and JSONB details

### 8.3 Data Protection
- Sanctions screening results with `action_taken = 'FROZEN'` trigger immediate asset freeze
- No account can be created without passing through all screening gates (sanctions, PEP, risk, DD)
- The workflow is deterministic — there is no bypass mechanism for any screening step

---

## 9. Automated Test Scenarios & Verification

Test scripts are located in `tests/uc1_onboarding/`.

| # | Payload File | Scenario | Expected Path | Expected HTTP Code |
|---|---|---|---|---|
| 1 | `01_individual_low_risk.json` | Resident Pakistani, salary account | SDD → Auto-approve → Account created | `201` |
| 2 | `02_individual_suspicion_flag.json` | Individual with `suspicion_flag = true` | EDD (suspicion overrides SDD) → Pending approval | `202` |
| 3 | `03_company_no_majority_bo.json` | Company, no >25% owner | BO fallback to Senior Official → CDD/EDD | `201` or `202` |
| 4 | `04_trust_mandatory_edd.json` | Trust entity | Mandatory EDD → Pending approval | `202` |
| 5 | `05_ngo_mandatory_edd.json` | SECP-registered NGO | Mandatory EDD → Pending approval | `202` |
| 6 | `06_minor_court_guardian.json` | Minor with court-appointed guardian | Validates guardian docs → CDD | `201` |
| 7 | `07_sanctions_match.json` | Name matches proscribed list | TFS freeze → Account blocked | `403` |
| 8 | `08_missing_documents.json` | Company missing Board Resolution | Doc check fails → ON_HOLD | `422` |
| 9 | `09_edd_incomplete_measures.json` | EDD required but measures incomplete | Measures gate blocks | `422` |

### Running Tests

```bash
# Individual test
cd tests/uc1_onboarding
./test_onboarding.sh payloads/01_individual_low_risk.json APPROVED

# The second argument (APPROVED/REJECTED) is used for the manager approval callback
# If the case completes immediately (SDD/CDD), the approval step is skipped
```

---

## 10. Cross-UC Integration

### 10.1 Outbound Dependencies (UC1 provides to other UCs)

| Target UC | What UC1 Provides | Mechanism |
|---|---|---|
| **UC3** | Customer records in `customers` table | UC3 reads `customers` table for PEP rescreening |
| **UC8** | CDD case status (`APPROVED`/`REJECTED`) | UC8 queries `cdd_cases.status` to verify originator/beneficiary CDD before processing wire transfers |
| **UC13** | Rejected case metrics | UC13 calls `GET /webhook/uc1-compliance-metrics` to fetch rejected case counts, risk rating revisions, and closed relationships |

### 10.2 Inbound Dependencies (UC1 consumes from other UCs)

| Source UC | What UC1 Consumes | Mechanism |
|---|---|---|
| None | UC1 is the entry point — it has no upstream dependencies | — |

### 10.3 Shared Database Tables

| Table | Used By |
|---|---|
| `customers` | UC1 (creates), UC3 (reads for screening), UC5 (reads for STR context) |
| `cdd_cases` | UC1 (creates/updates), UC8 (reads status), UC13 (counts) |
| `pep_watchlist_seed` | UC1 (screens against), UC3 (uses as watchlist source) |
| `sanctions_watchlist_seed` | UC1 (screens against) |
