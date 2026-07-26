# UC5: Suspicious Transaction & Currency Transaction Reporting — Technical Document

**Version:** 1.0  
**Workflow Files:** `n8n/workflows/uc5_ctr_pipeline.json` (18 nodes) + `n8n/workflows/uc5_str_pipeline.json` (60 nodes)  
**Schema File:** `db/init/005_uc5_schema.sql`  
**Seed File:** `db/init/006_uc5_seed.sql`  
**Total Node Count:** 78  
**Flows:** 6 (CTR Intake, CTR Filing, STR Triage, STR Analyst Action, STR Officer Sign-Off, STR Access Check)

---

## 1. Executive Summary

### 1.1 Problem Statement
Banks must report two categories of financial transactions to Pakistan's Financial Monitoring Unit (FMU):
- **CTRs (Currency Transaction Reports):** Purely deterministic, threshold-based. Any single cash transaction ≥ PKR 2,000,000 must be filed. No compliance discretion.
- **STRs (Suspicious Transaction Reports):** Subjective, judgment-based, human-gated. Requires analyst investigation, written rationale, and compliance officer sign-off.

### 1.2 Critical Legal Constraint
**Tipping-off is a criminal offense** (AML Act 2010 §34). It is illegal to disclose to the customer (or unauthorized bank employees) that their account is under investigation. The workflow enforces strict role-based access controls on all STR data.

### 1.3 SBP Regulatory Basis
- **AML Act 2010 §7 / SBP Reg 7 §1-§2** — STR and CTR filing obligations
- **AML Act 2010 §7D** — CDD failure tip-off risk fast-track
- **AML Act 2010 §34 / SBP Reg 13 §4(d)** — Tipping-off prohibition
- **SBP Reg 2 §21(e)** — Mandatory written background examination
- **SBP Reg 8 §3** — 10-year record retention
- **SBP Reg 12 §6** — Two-tier sign-off (analyst + officer)

### 1.4 Target Users
| Role | Interaction |
|---|---|
| Core Banking System | Feeds transactions via CTR intake webhook |
| TMS / Staff / Other UCs | Creates STR cases via triage webhooks |
| Compliance Analyst | Investigates STR cases, records rationale, submits decisions |
| Compliance Officer | Reviews and signs off on STR filing recommendations |
| Relationship Manager | **BLOCKED** from accessing STR case data (tipping-off protection) |

---

## 2. Regulatory Mapping & Reference Matrix

| # | Directive | Clause | Nodes | Implementation |
|---|---|---|---|---|
| 1 | CTR threshold filing | AML Act §7 / Reg 7 §2 | CTR 4-5 | Config-driven ≥ PKR 2M check; deterministic flagging |
| 2 | STR investigation | AML Act §7 / Reg 7 §1 | STR 9-17 | Multi-channel triage with severity scoring |
| 3 | Written examination | Reg 2 §21(e) | STR 23-24 | Analyst must record `background_purpose_findings` |
| 4 | Mandatory rationale | Reg 7 / Reg 2 §21(e) | STR 59 | `rationale TEXT NOT NULL CHECK(length(trim(rationale)) > 0)` |
| 5 | Two-tier sign-off | Reg 5 §1(b) / Reg 12 §6 | STR 44-45 | Analyst recommends → Officer approves/returns |
| 6 | Tipping-off prohibition | AML Act §34 / Reg 13 §4(d) | STR 54-56 | Role-based access gate blocks non-compliance roles |
| 7 | CDD tip-off bypass | Reg 7 §1(d) / AML Act §7D(2) | STR 11 | `CDD_WOULD_TIPOFF` fast-tracks to `RECOMMENDED_FOR_FILING` |
| 8 | Record retention | AML Act §7D / Reg 8 §3 | CTR 16, STR 48-49 | `GREATEST(last_tx_date, filing_date) + 10 years` |

---

## 3. Process Flow Diagrams

### 3.1 CTR Pipeline (Workflow 1 — 18 nodes)

```
POST /webhook/uc5-ctr-intake
   │
   ▼
[Node 1: Webhook Trigger] → [Node 2: Insert Transaction]
   │
   ▼
[Node 3: Lookup CTR Threshold (from config table)]
   │
   ▼
[Node 4: IF: Cash Transaction?]
   ├── No  → [Node 5: Respond: Not Cash (200)]
   └── Yes → [Node 6: IF: Amount ≥ Threshold?]
                ├── No  → [Node 7: Respond: Below Threshold (200)]
                └── Yes → [Node 8: Insert CTR Candidate]
                              │
                         [Node 9: Send Email — CTR Flagged]
                              │
                         [Node 10: Respond: CTR Candidate Created (200)]

POST /webhook/uc5-ctr-verify
   │
   ▼
[Node 11: Webhook Trigger] → [Node 12: Update CTR Candidate Status]
   │
   ▼
[Node 15: IF: Data Verified?]
   ├── No  → [Node 13: Respond: Correction Needed (422)]
   └── Yes → [Node 14: Get Transaction Details]
                │
          [Node 16: Insert CTR Filing (FMU ref + retention)]
                │
          [Node 17: Send Email — CTR Filed]
                │
          [Node 18: Respond: CTR Filed (200)]
```

### 3.2 STR Investigation Pipeline (Workflow 2 — 60 nodes)

#### Triage Flow

```
POST /webhook/uc5-str-tms-alert    ─── [Set Trigger — TMS] ───────────────┐
POST /webhook/uc5-str-manual       ─── [Set Trigger — Manual] ────────────┤
POST /webhook/uc5-str-cross-uc     ─── [Set Trigger — Cross-UC] ──────────┤
POST /webhook/uc5-str-cdd-failure  ─── [Set Trigger — CDD Failure] ───────┘
                                                                           │
                                                                   [Node 9: Merge]
                                                                           │
                                                                   [Node 10: Insert STR Case Trigger]
                                                                           │
                                                                   [Node 11: Generate Case Ref]
                                                                           │
                                                                   [Node 12: Insert STR Case]
                                                                           │
                                                                   [Node 13: Aggregate Customer Profile]
                                                                           │
                                                                   [Node 14: Compute Triage Score]
                                                                           │
                                                                   [Node 15: Update Triage Score]
                                                                           │
                                                                   [Node 16: Send Email — New STR Case]
                                                                           │
                                                                   [Node 17: Respond: Case Created (200)]
```

#### Analyst Action Flow

```
POST /webhook/uc5-str-analyst-action
   │
   ▼
[Node 18: Webhook] → [Node 19: Validate Analyst Role]
   │
   ▼
[Node 20: IF: Valid Role?]
   ├── No  → [Node 21: Respond: Access Denied (403)]
   └── Yes → [Node 22: Log Access — Analyst]
                │
          [Node 23: IF: Action = Investigate?]
             ├── Yes → [Node 24: Insert Investigation Log]
             │              → [Node 25: Update Case — Under Investigation]
             │              → [Node 26: Respond: Investigation Logged (200)]
             └── No (decide)
                    → [Node 59: IF: Rationale Provided?]
                         ├── No  → [Node 60: Respond: Rationale Required (400)]
                         └── Yes → [Node 27: Insert Analyst Decision]
                                      │
                                [Node 28: IF: Close Not Suspicious?]
                                   ├── Yes → [Node 29: Update Case — Closed]
                                   │              → [Node 30: Respond: Case Closed (200)]
                                   └── No  → [Node 31: IF: Needs More Info?]
                                                ├── Yes → [Node 32: Update — Needs More Info]
                                                │              → [Node 33: Respond (200)]
                                                └── No  → [Node 34: Update — Recommended for Filing]
                                                               → [Node 35: Respond (200)]
```

#### Officer Sign-Off Flow

```
POST /webhook/uc5-str-officer-signoff
   │
   ▼
[Node 36: Webhook] → [Node 37: Validate Officer Role]
   │
   ▼
[Node 38: IF: Valid Officer Role?]
   ├── No  → [Node 39: Respond: Access Denied (403)]
   └── Yes → [Node 40: Log Access — Officer]
                → [Node 41: Validate Case Status]
                → [Node 42: IF: Case Ready?]
                     ├── No  → [Node 43: Respond: Case Not Ready (422)]
                     └── Yes → [Node 44: Insert Officer Sign-Off]
                                  │
                            [Node 45: IF: Officer Approved?]
                               ├── No  → [Node 46: Update — Returned]
                               │              → [Node 47: Respond: Returned (200)]
                               └── Yes → [Node 48: Get Retention Date]
                                            → [Node 49: Insert STR Filing]
                                            → [Node 50: Update Case — Filed]
                                            → [Node 51: Send Email — STR Filed]
                                            → [Node 52: Respond: STR Filed (200)]
```

#### Access Check Flow

```
POST /webhook/uc5-str-access-check
   │
   ▼
[Node 53: Webhook] → [Node 54: Check Access Role (JS)]
   │
   ▼
[Node 55: IF: Access Allowed?]
   ├── No  → [Node 56: Respond: Access Denied — Tipping-Off (403)]
   └── Yes → [Node 57: Log + Return Case Data]
                → [Node 58: Respond: Case Data (200)]
```

---

## 4. Database Schema & ERD

### 4.1 Configuration

| Table | Purpose |
|---|---|
| `regulatory_thresholds_config` | Config-driven CTR threshold (PKR 2,000,000), retention params |

### 4.2 CTR Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `transactions` | Financial ledger | `transaction_type`, `amount`, `currency`, `channel` |
| `ctr_candidates` | Flagged cash transactions | `threshold_applied` (snapshot), `data_accuracy_status` |
| `ctr_filings` | Filed CTR records | `filing_reference`, `retention_until` |

### 4.3 STR Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `str_case_triggers` | Entry source record | `trigger_type`, `trigger_subtype`, `details` (JSONB) |
| `str_cases` | Core case record | `review_status`, `triage_severity_score`, `is_confidential` |
| `str_investigation_log` | Analyst examination notes | `background_purpose_findings`, `narrative_draft` |
| `str_analyst_decisions` | Analyst recommendations | `decision`, `rationale` (NOT NULL + CHECK) |
| `str_compliance_officer_signoff` | Officer approvals | `decision` (APPROVED/RETURNED_FOR_REVISION) |
| `str_filings` | Filed STR records | `filing_reference`, `retention_until` |
| `str_access_log` | Tipping-off audit trail | `accessed_by_role`, `access_type` |

### 4.4 ERD

```
regulatory_thresholds_config

transactions ──► ctr_candidates ──► ctr_filings

str_case_triggers ──► str_cases ──► str_investigation_log
                          │       ──► str_analyst_decisions
                          │       ──► str_compliance_officer_signoff
                          │       ──► str_filings
                          └─────────► str_access_log
```

---

## 5. API / Webhook Reference

### 5.1 CTR Intake

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc5-ctr-intake` |

#### Request Body
```json
{
  "customer_id": 1,
  "account_id": 1,
  "transaction_type": "CASH_DEPOSIT | CASH_WITHDRAWAL | WIRE_INCOMING | WIRE_OUTGOING",
  "amount": 3000000,
  "currency": "PKR",
  "branch_code": "LHR-001",
  "channel": "BRANCH_TELLER",
  "description": "Cash deposit — sale proceeds"
}
```

#### Responses
| Outcome | HTTP | Status |
|---|---|---|
| Not a cash transaction | `200` | `NOT_CASH_TRANSACTION` |
| Below threshold | `200` | `BELOW_THRESHOLD` |
| CTR candidate created | `200` | `CTR_CANDIDATE_CREATED` with `candidate_id` |

### 5.2 CTR Verify

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc5-ctr-verify` |

#### Request Body
```json
{
  "candidate_id": 1,
  "accuracy_status": "VERIFIED | CORRECTION_NEEDED",
  "verified_by": "Compliance Analyst"
}
```

### 5.3 STR Triage (4 intake channels)

| Endpoint | Trigger Type |
|---|---|
| `POST /webhook/uc5-str-tms-alert` | TMS_ALERT |
| `POST /webhook/uc5-str-manual` | MANUAL_STAFF_OBSERVATION |
| `POST /webhook/uc5-str-cross-uc` | CROSS_UC_FINDING |
| `POST /webhook/uc5-str-cdd-failure` | CDD_FAILURE_OR_TIPOFF_RISK |

#### Request Body (all channels)
```json
{
  "customer_id": 1,
  "source_reference": "TMS-ALERT-2026-0045",
  "trigger_subtype": "CDD_INCOMPLETE_S7D1 | CDD_WOULD_TIPOFF_S7D2",
  "details": { "alert_type": "structuring", "amount": 5000000 }
}
```

### 5.4 STR Analyst Action

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc5-str-analyst-action` |

#### Request Body — Investigate
```json
{
  "str_case_id": 1,
  "action": "investigate",
  "analyst_name": "Analyst Ahmed",
  "analyst_role": "COMPLIANCE_ANALYST",
  "background_purpose_findings": "Customer has structured 5 deposits over 3 days...",
  "narrative_draft": "Suspicious structuring pattern detected..."
}
```

#### Request Body — Decide
```json
{
  "str_case_id": 1,
  "action": "decide",
  "analyst_name": "Analyst Ahmed",
  "analyst_role": "COMPLIANCE_ANALYST",
  "decision": "FILE_STR | CLOSE_NOT_SUSPICIOUS | NEEDS_MORE_INFO",
  "rationale": "Customer structuring pattern confirmed across 5 transactions..."
}
```

### 5.5 STR Officer Sign-Off

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc5-str-officer-signoff` |

#### Request Body
```json
{
  "str_case_id": 1,
  "officer_name": "Chief Compliance Officer",
  "officer_role": "COMPLIANCE_OFFICER",
  "decision": "APPROVED | RETURNED_FOR_REVISION",
  "comments": "Filing approved — clear structuring pattern"
}
```

### 5.6 STR Access Check

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc5-str-access-check` |

#### Request Body
```json
{
  "str_case_id": 1,
  "requester_name": "Branch Manager Ali",
  "requester_role": "RELATIONSHIP_MANAGER | COMPLIANCE_ANALYST | COMPLIANCE_OFFICER"
}
```

---

## 6. Node-by-Node Configuration

### CTR Pipeline

#### Node 1: Webhook Trigger — Transaction Intake
| Property | Value |
|---|---|
| **Type** | `webhook` |
| **Path** | `uc5-ctr-intake` |
| **Method** | `POST` |

#### Node 2: Insert Transaction
```sql
INSERT INTO transactions (customer_id, account_id, transaction_type, amount, currency, branch_code, channel, description)
VALUES (
  {{ $json.body.customer_id }}, {{ $json.body.account_id || 'NULL' }},
  '{{ $json.body.transaction_type }}', {{ $json.body.amount }},
  '{{ $json.body.currency || 'PKR' }}', '{{ $json.body.branch_code || '' }}',
  '{{ $json.body.channel || '' }}', '{{ $json.body.description || '' }}'
) RETURNING id, customer_id, transaction_type, amount;
```

#### Node 3: Lookup CTR Threshold
```sql
SELECT config_value AS ctr_threshold FROM regulatory_thresholds_config
WHERE config_key = 'CTR_THRESHOLD_PKR';
```

#### Node 4: IF: Cash Transaction?
| Condition | `{{ $('Insert Transaction').first().json.transaction_type }}` contains `CASH` |
|---|---|

#### Node 6: IF: Amount ≥ Threshold?
| Condition | `{{ $('Insert Transaction').first().json.amount }}` ≥ `{{ $json.ctr_threshold }}` |
|---|---|

#### Node 8: Insert CTR Candidate
```sql
INSERT INTO ctr_candidates (transaction_id, threshold_applied)
VALUES (
  {{ $('Insert Transaction').first().json.id }},
  {{ $json.ctr_threshold }}
) RETURNING id, transaction_id, threshold_applied, flagged_at;
```

#### Node 16: Insert CTR Filing
```sql
INSERT INTO ctr_filings (ctr_candidate_id, filing_reference, retention_until)
VALUES (
  {{ $('Update CTR Candidate Status').first().json.id }},
  'FMU-CTR-' || to_char(now(), 'YYYYMMDD-HH24MISS') || '-' || {{ $('Update CTR Candidate Status').first().json.id }},
  GREATEST(
    '{{ $json.executed_at }}'::date,
    now()::date
  ) + interval '10 years'
) RETURNING id, filing_reference, filed_at, retention_until;
```

---

### STR Pipeline

#### Nodes 1–8: Four Intake Channels + Set Nodes

Each of the 4 webhook nodes receives a different trigger type and feeds into a `Set` node that normalizes the trigger type:

| Webhook | Path | Set Value |
|---|---|---|
| Node 1 | `uc5-str-tms-alert` | `trigger_type = TMS_ALERT` |
| Node 3 | `uc5-str-manual` | `trigger_type = MANUAL_STAFF_OBSERVATION` |
| Node 5 | `uc5-str-cross-uc` | `trigger_type = CROSS_UC_FINDING` |
| Node 7 | `uc5-str-cdd-failure` | `trigger_type = CDD_FAILURE_OR_TIPOFF_RISK` |

#### Node 9: Merge
| Does | Consolidates all 4 intake channels into a single execution path |
|---|---|

#### Node 11: Generate Case Ref
```javascript
const triggerType = $json.trigger_type;
const triggerSubtype = $json.trigger_subtype || '';
const customerId = $json.customer_id;
const timestamp = Date.now().toString(36).toUpperCase();

const caseRef = 'STR-' + new Date().getFullYear() + '-' + timestamp;

// CDD_WOULD_TIPOFF fast-track: skip investigation, go straight to RECOMMENDED_FOR_FILING
const isFastTrack = (triggerSubtype === 'CDD_WOULD_TIPOFF_S7D2');
const initialStatus = isFastTrack ? 'RECOMMENDED_FOR_FILING' : 'PENDING_FIRST_REVIEW';

return [{
  json: {
    ...($json),
    case_ref: caseRef,
    initial_status: initialStatus,
    is_fast_track: isFastTrack
  }
}];
```

#### Node 14: Compute Triage Score
```javascript
const triggerType = $json.trigger_type;
let score = 50; // base

if (triggerType === 'TMS_ALERT') score += 20;
if (triggerType === 'CDD_FAILURE_OR_TIPOFF_RISK') score += 30;
if (triggerType === 'CROSS_UC_FINDING') score += 15;

// Cap at 100
score = Math.min(score, 100);

return [{ json: { ...$json, triage_severity_score: score } }];
```

#### Node 19: Validate Analyst Role (Key Security Node)
```javascript
const role = $json.body.analyst_role;
const allowedRoles = ['COMPLIANCE_ANALYST', 'COMPLIANCE_OFFICER'];

if (!allowedRoles.includes(role)) {
  return {
    json: {
      is_valid: false,
      message: 'ACCESS DENIED. Role "' + role + '" is not authorized to act on STR cases.',
      // ... audit fields ...
    }
  };
}
// ... pass through with is_valid = true ...
```

#### Node 54: Check Access Role (Tipping-Off Gate)
```javascript
const role = $json.body.requester_role;
const allowedRoles = ['COMPLIANCE_ANALYST', 'COMPLIANCE_OFFICER'];

if (!allowedRoles.includes(role)) {
  return {
    json: {
      is_allowed: false,
      message: 'ACCESS DENIED. Role "' + role + '" is not authorized to view STR case data. Per Reg 13 §4(d), front-line and relationship management staff must not access STR-related information.'
    }
  };
}
```

#### Node 48: Get Retention Date
```sql
SELECT
  GREATEST(
    COALESCE((SELECT MAX(t.executed_at) FROM transactions t WHERE t.customer_id = sc.customer_id), now()),
    now()
  )::date + interval '10 years' AS retention_until,
  sc.case_ref, sc.customer_id
FROM str_cases sc
WHERE sc.id = {{ $('Insert Officer Sign-Off').first().json.str_case_id }};
```

#### Node 49: Insert STR Filing
```sql
INSERT INTO str_filings (str_case_id, filing_reference, retention_until)
VALUES (
  {{ $('Insert Officer Sign-Off').first().json.str_case_id }},
  'FMU-STR-' || to_char(now(), 'YYYYMMDD-HH24MISS') || '-' || {{ str_case_id }},
  '{{ $json.retention_until }}'::date
) RETURNING id, str_case_id, filing_reference, filed_at, retention_until;
```

---

## 7. Error Handling & Edge Cases

| Error Condition | Handled By | HTTP Code |
|---|---|---|
| Non-cash transaction | Node 4 routes to bypass | `200` |
| Below CTR threshold | Node 6 routes to bypass | `200` |
| CTR data accuracy issue | Node 15 routes to correction | `422` |
| Invalid analyst role (RM, etc.) | Node 20 blocks access | `403` |
| Empty rationale on decision | Node 59 blocks submission | `400` |
| Case not in RECOMMENDED_FOR_FILING state | Node 42 blocks sign-off | `422` |
| Officer returns case for revision | Node 46 resets to UNDER_INVESTIGATION | `200` |
| Non-compliance role requests case data | Node 55 blocks access, logs attempt | `403` |
| CDD tip-off risk | Node 11 fast-tracks to RECOMMENDED_FOR_FILING | `200` |

---

## 8. Security & Access Control

### 8.1 Role-Based Access Matrix

| Role | Can Create STR | Can Investigate | Can Decide | Can Sign Off | Can View Data |
|---|---|---|---|---|---|
| COMPLIANCE_ANALYST | ✅ | ✅ | ✅ | ❌ | ✅ |
| COMPLIANCE_OFFICER | ✅ | ✅ | ✅ | ✅ | ✅ |
| RELATIONSHIP_MANAGER | ❌ | ❌ | ❌ | ❌ | ❌ (HTTP 403) |
| BRANCH_MANAGER | ❌ | ❌ | ❌ | ❌ | ❌ (HTTP 403) |

### 8.2 Audit Trail
- Every access attempt (allowed or denied) is logged in `str_access_log` with role, timestamp, and access type
- `str_cases.is_confidential = TRUE` by default for all cases
- `str_analyst_decisions.rationale` has a database CHECK constraint enforcing non-empty text

### 8.3 Credentials
| Credential | Usage |
|---|---|
| `AML Postgres` | All DB operations |
| `AML SMTP` | CTR flagging emails, CTR filing confirmations, STR case creation alerts, STR filing confirmations |

---

## 9. Automated Test Scenarios & Verification

### CTR Tests (`tests/uc5_str_ctr/test_uc5_ctr.sh`)

| # | Payload | Scenario | Expected |
|---|---|---|---|
| 1 | `01_cash_above_threshold.json` | PKR 3M cash deposit | Flagged → Verified → CTR Filed with 10-year retention |
| 2 | `02_cash_below_threshold.json` | PKR 500K cash deposit | Below threshold — bypassed |

### STR Tests (`tests/uc5_str_ctr/test_uc5_str.sh`)

| # | Payload | Scenario | Expected |
|---|---|---|---|
| 3 | `03_tms_alert_close.json` | TMS alert → investigated → closed | Case closed as not suspicious |
| 4 | `04_manual_observation.json` | Staff observes suspicious behavior | Full lifecycle → STR filed with FMU |
| 5 | `05_access_denied_frontline.json` | RM tries to access STR case | HTTP 403 — access blocked, attempt logged |
| 6 | `06_empty_rationale_reject.json` | Analyst submits decision with empty rationale | HTTP 400 — decision blocked |
| 7 | `07_officer_returns_revision.json` | Officer returns case to analyst | Status reset to UNDER_INVESTIGATION |

---

## 10. Cross-UC Integration

### 10.1 Inbound Dependencies

| Source UC | What UC5 Consumes | Mechanism |
|---|---|---|
| **UC1** | `customers` table (customer profiles) | STR cases reference customer_id |
| **UC8** | Wire transfer STR escalations | UC8 calls `POST /webhook/uc5-str-cross-uc` with `CROSS_UC_FINDING` trigger type |

### 10.2 Outbound Dependencies

| Target UC | What UC5 Provides | Mechanism |
|---|---|---|
| **UC13** | STR/CTR filing counts | UC13 queries `str_cases`, `ctr_filings` for IRAR aggregation |

### 10.3 Shared Database Tables

| Table | Owner | Also Used By |
|---|---|---|
| `customers` | UC1 | UC5 reads for customer profile |
| `transactions` | UC5 | UC13 counts |
| `str_cases` | UC5 | UC13 counts |
| `ctr_filings` | UC5 | UC13 counts |
