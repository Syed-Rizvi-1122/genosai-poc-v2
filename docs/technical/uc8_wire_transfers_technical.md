# UC8: Wire Transfer Data Completeness & Compliance — Technical Document

**Version:** 1.0  
**Workflow File:** `n8n/workflows/uc8_wire_transfers.json`  
**Schema File:** `db/init/007_uc8_schema.sql`  
**Seed File:** `db/init/008_uc8_seed.sql`  
**Node Count:** 49  
**Flows:** 2 (Intake & Role-Based Routing + Analyst Hold Action Gate)

---

## 1. Executive Summary

### 1.1 Problem Statement
Wire transfers are one of the highest risk channels for cross-border and domestic movement of illicit funds. SBP AML/CFT/CPF Regulation 11 establishes strict data completeness and verification standards for financial institutions depending on their role in the payment chain: **Ordering** (sending money out), **Intermediary** (forwarding), or **Beneficiary** (receiving money in).

### 1.2 What This Workflow Does
UC8 automates the real-time compliance gatekeeping of wire transfers. It dynamically determines the bank's role per transaction, enforces the corresponding data completeness policy, implements interbank settlement exemptions, manages hold queues for incomplete data, and enables analyst actions including STR escalation to UC5.

### 1.3 Key Regulatory Distinction
- **Ordering Bank (Outgoing):** Can PREVENT the transfer from leaving. Missing data = **hard block** (HTTP 400).
- **Intermediary/Beneficiary Bank (Incoming/Forwarding):** Cannot prevent the sending bank from initiating the transfer. Missing data = **hold** (HTTP 202), alert compliance, wait for analyst action.
- **Interbank Settlements:** Own-behalf transfers between SBP-regulated entities are **exempt** from all originator/beneficiary checks (Reg 11 §1).

### 1.4 SBP Regulatory Basis
- **Regulation 11 §1** — Interbank exemption
- **Regulation 11 §2(a)** — CDD prerequisite for ordering
- **Regulation 11 §2(b) & §3** — Ordering field completeness
- **Regulation 11 §4 & §5** — Intermediary field preservation
- **Regulation 11 §7** — Beneficiary verification
- **Regulation 11 §8** — Analyst gate and STR escalation
- **Regulation 11 §9** — 10-year record retention

### 1.5 Target Users
| Role | Interaction |
|---|---|
| Payment Processing System | Submits wire transfer payloads via intake webhook |
| Compliance Analyst | Reviews held transfers via analyst action webhook |
| UC5 STR Pipeline | Receives cross-UC escalation via HTTP POST |

---

## 2. Regulatory Mapping & Reference Matrix

| # | Directive | SBP Clause | Nodes | Implementation |
|---|---|---|---|---|
| 1 | Interbank Exemption | Reg 11 §1 | 3–5 | Checks `is_interbank_exemption` flag; bypasses all checks, sets status to `EXECUTED` |
| 2 | CDD Prerequisite | Reg 11 §2(a) | 7–10 | Outgoing transfers require originator CDD status = `APPROVED` |
| 3 | Ordering Field Completeness | Reg 11 §2(b) & §3 | 11–16 | JS code checks originator (name, account, ID doc) and beneficiary (name, account) |
| 4 | Intermediary Field Preservation | Reg 11 §4 & §5 | 17–25 | Checks forwarding completeness; logs correspondent bank failure rate |
| 5 | Beneficiary Verification | Reg 11 §7 | 26–36 | Checks beneficiary CDD status and incoming originator data completeness |
| 6 | Analyst Gate & STR Escalation | Reg 11 §8 | 37–49 | Three analyst actions: RELEASE, REJECT, or SUSPENDED_STR_ESCALATION |
| 7 | 10-Year Record Retention | Reg 11 §9 | 15, 19, 41, 44, 47 | `retention_until = now()::date + interval '10 years'` on all executed/rejected transfers |

---

## 3. Process Flow Diagrams

### 3.1 Flow A: Intake & Role-Based Routing (Nodes 1–36)

```
POST /webhook/uc8-wire-intake
   │
   ▼
[Node 1: Webhook — Wire Transfer Intake]
   │
   ▼
[Node 2: Insert Raw Transfer (status: PENDING_CHECK)]
   │
   ▼
[Node 3: IF: Interbank Exemption?]
   ├── Yes → [Node 4: Set EXECUTED (Exempt)] → [Node 5: Respond: Interbank Exempt (200)]
   └── No  ↓
[Node 6: Switch: Role Router (direction)]
   │
   ├── Output 0: OUTGOING (Ordering Bank) ──────────────────────────────────────
   │   [Node 7: Lookup Originator CDD]
   │       │
   │   [Node 8: IF: CDD Approved?]
   │       ├── No  → [Node 9: Block CDD Failure] → [Node 10: Respond: CDD Block (400)]
   │       └── Yes → [Node 11: Verify Outgoing Fields (JS Code)]
   │                     │
   │                 [Node 12: IF: Outgoing Fields Complete?]
   │                     ├── No  → [Node 13: Reject Outgoing] → [Node 14: Respond: Rejected (400)]
   │                     └── Yes → [Node 15: Send Outgoing (SENT + 10yr retention)]
   │                                   → [Node 16: Respond: Outgoing Sent (200)]
   │
   ├── Output 1: FORWARDING (Intermediary Bank) ────────────────────────────────
   │   [Node 17: Verify Forwarding Fields (JS Code)]
   │       │
   │   [Node 18: IF: Forwarding Complete?]
   │       ├── Yes → [Node 19: Forward Complete (EXECUTED + retention)]
   │       │              → [Node 20: Respond: Forward Success (200)]
   │       └── No  → [Node 21: Set Forward Hold (HELD_COMPLETENESS)]
   │                     → [Node 22: Insert Hold Record]
   │                     → [Node 23: Log Correspondent Incompleteness]
   │                     → [Node 24: Send Email: Hold Alert]
   │                     → [Node 25: Respond: Forwarding Hold (202)]
   │
   └── Output 2: INCOMING (Beneficiary Bank) ───────────────────────────────────
       [Node 26: Lookup Beneficiary CDD]
           │
       [Node 27: IF: Beneficiary CDD Approved?]
           ├── No  → [Node 31: Set Beneficiary Hold] → [Node 32: Insert Hold Record]
           │              → [Node 34: Log Correspondent] → [Node 35: Email] → [Node 36: Respond (202)]
           └── Yes → [Node 33: Verify Incoming Fields (JS Code)]
                         │
                     [Node 28: IF: Incoming Fields Complete?]
                         ├── Yes → [Node 29: Beneficiary Complete (EXECUTED)]
                         │              → [Node 30: Respond: Complete (200)]
                         └── No  → [Node 31: Set Beneficiary Hold] → ... (same hold path)
```

### 3.2 Flow B: Analyst Hold Action Gate (Nodes 37–49)

```
POST /webhook/uc8-analyst-action
   │
   ▼
[Node 37: Webhook: Analyst Hold Action]
   │
   ▼
[Node 38: Lookup Hold Details (JOIN wire_transfers)]
   │
   ▼
[Node 39: Switch: Analyst Action]
   │
   ├── Output 0: APPROVED_RELEASE
   │   [Node 40: Update Hold Release] → [Node 41: Release Funds (EXECUTED + 10yr)]
   │       → [Node 42: Respond: Released (200)]
   │
   ├── Output 1: APPROVED_REJECT
   │   [Node 43: Update Hold Reject] → [Node 44: Reject Funds (REJECTED + 10yr)]
   │       → [Node 45: Respond: Rejected (200)]
   │
   └── Output 2: SUSPENDED_STR_ESCALATION
       [Node 46: Update Hold Suspend] → [Node 47: Suspend Funds (SUSPENDED + flagged_for_str_review)]
           → [Node 48: HTTP POST to UC5 STR (Cross-UC Finding)]
           → [Node 49: Respond: Suspended (200)]
```

---

## 4. Database Schema & ERD

### 4.1 Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `wire_transfers` | Core ledger with all transfer data | `transaction_ref`, `direction` (OUTGOING/FORWARDING/INCOMING), `transfer_status`, `is_interbank_exemption`, originator/beneficiary fields, `retention_until` |
| `wire_transfer_holds` | Hold queue for incomplete transfers | `role_at_bank` (INTERMEDIARY/BENEFICIARY), `hold_reason`, `review_status`, `rationale` (CHECK constraint) |
| `correspondent_completeness_logs` | Tracks correspondent banks sending incomplete data | `institution_name`, `missing_fields_count` |

### 4.2 Status Lifecycle

```
PENDING_CHECK → SENT (Ordering, complete)
PENDING_CHECK → EXECUTED (Intermediary/Beneficiary complete, or Interbank exempt)
PENDING_CHECK → REJECTED (Ordering, incomplete)
PENDING_CHECK → HELD_COMPLETENESS (Intermediary/Beneficiary, incomplete)
HELD_COMPLETENESS → EXECUTED (Analyst releases)
HELD_COMPLETENESS → REJECTED (Analyst rejects)
HELD_COMPLETENESS → SUSPENDED (Analyst escalates to STR)
```

### 4.3 ERD

```
wire_transfers ──► wire_transfer_holds
      │
      └──► correspondent_completeness_logs

wire_transfers.originator_customer_id → customers (UC1)
```

### 4.4 Retention Formula

Upon any terminal status (`SENT`, `EXECUTED`, `REJECTED`, `SUSPENDED`):
```sql
retention_until = now()::date + interval '10 years'
```

---

## 5. API / Webhook Reference

### 5.1 Endpoint: Wire Transfer Intake

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc8-wire-intake` |
| **Response Mode** | `Respond to Webhook node` |

#### Request Body Schema

```json
{
  "transaction_ref": "SWIFT-2026-LHR-0045",
  "sending_institution": "Habib Bank Limited",
  "receiving_institution": "United Bank Limited",
  "is_interbank_exemption": false,
  "transfer_type": "INDIVIDUAL | BATCH",
  "direction": "OUTGOING | FORWARDING | INCOMING",
  "originator_customer_id": 1,
  "amount": 5000000,
  "currency": "PKR",
  "value_date": "2026-07-15",
  "purpose_of_transfer": "Supplier payment for raw materials",
  "originator_name": "Apex Holdings Pvt Ltd",
  "originator_account_ref": "PK-HBL-1234567890",
  "originator_id_doc_number": "3520298765432",
  "beneficiary_name": "Karachi Textiles Ltd",
  "beneficiary_account_ref": "PK-UBL-0987654321",
  "beneficiary_id_doc_number": "4210112345678"
}
```

#### Response Schemas

| Outcome | HTTP | Status Key |
|---|---|---|
| Interbank exempt | `200` | `EXEMPT` |
| Outgoing sent (complete) | `200` | `SENT` |
| Outgoing blocked (CDD) | `400` | `BLOCKED_CDD_INCOMPLETE` |
| Outgoing rejected (fields) | `400` | `REJECTED` with `missing_fields[]` |
| Intermediary forwarded | `200` | `FORWARDED` |
| Intermediary held | `202` | `HELD_COMPLETENESS` with `hold_id` |
| Beneficiary credited | `200` | `CREDITED` |
| Beneficiary held | `202` | `HELD_COMPLETENESS` with `hold_id` |

#### Example curl

```bash
curl -s -X POST http://localhost:5678/webhook/uc8-wire-intake \
  -H "Content-Type: application/json" \
  -d @tests/uc8_wire_transfers/payloads/01_outgoing_compliant.json
```

---

### 5.2 Endpoint: Analyst Hold Action

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc8-analyst-action` |
| **Response Mode** | `Respond to Webhook node` |

#### Request Body Schema

```json
{
  "hold_id": 1,
  "action": "APPROVED_RELEASE | APPROVED_REJECT | SUSPENDED_STR_ESCALATION",
  "reviewer_name": "Compliance Analyst Ahmed",
  "rationale": "Originator data verified via correspondent bank follow-up"
}
```

#### Response Schemas

| Action | HTTP | Status Key |
|---|---|---|
| `APPROVED_RELEASE` | `200` | `APPROVED_RELEASE` — funds released, transfer set to EXECUTED |
| `APPROVED_REJECT` | `200` | `APPROVED_REJECT` — funds terminated, transfer set to REJECTED |
| `SUSPENDED_STR_ESCALATION` | `200` | `SUSPENDED_STR_ESCALATION` — transfer suspended, UC5 STR case triggered |

---

## 6. Node-by-Node Configuration

### Flow A: Intake & Routing

#### Node 1: Webhook — Wire Transfer Intake

| Property | Value |
|---|---|
| **Type** | `webhook` |
| **Method** | `POST` |
| **Path** | `uc8-wire-intake` |
| **Response Mode** | `Respond to Webhook node` |
| **Forwards** | `$json.body.*` — all transfer fields |

---

#### Node 2: Insert Raw Transfer

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Receives** | All transfer fields from webhook body |
| **Forwards** | Inserted record with `id`, `transaction_ref`, `direction` |

```sql
INSERT INTO wire_transfers (
  transaction_ref, sending_institution, receiving_institution,
  is_interbank_exemption, transfer_type, direction,
  originator_customer_id, amount, currency, value_date,
  purpose_of_transfer, originator_beneficiary_relationship,
  originator_name, originator_account_ref, originator_id_doc_number,
  beneficiary_name, beneficiary_account_ref, beneficiary_id_doc_number,
  transfer_status
) VALUES (
  '{{ $json.body.transaction_ref }}',
  '{{ $json.body.sending_institution }}',
  '{{ $json.body.receiving_institution }}',
  {{ $json.body.is_interbank_exemption || false }},
  '{{ $json.body.transfer_type }}',
  '{{ $json.body.direction }}',
  {{ $json.body.originator_customer_id || 'NULL' }},
  {{ $json.body.amount }},
  '{{ $json.body.currency || 'PKR' }}',
  '{{ $json.body.value_date }}',
  '{{ $json.body.purpose_of_transfer || '' }}',
  '{{ $json.body.originator_beneficiary_relationship || '' }}',
  '{{ $json.body.originator_name || '' }}',
  '{{ $json.body.originator_account_ref || '' }}',
  '{{ $json.body.originator_id_doc_number || '' }}',
  '{{ $json.body.beneficiary_name || '' }}',
  '{{ $json.body.beneficiary_account_ref || '' }}',
  '{{ $json.body.beneficiary_id_doc_number || '' }}',
  'PENDING_CHECK'
) RETURNING *;
```

---

#### Node 3: IF: Interbank Exemption?

| Property | Value |
|---|---|
| **Type** | `if` |
| **Condition** | `{{ $json.is_interbank_exemption }}` equals `true` |
| **Output 0 (True)** | → Node 4: Set Exempt |
| **Output 1 (False)** | → Node 6: Switch: Role Router |

---

#### Node 4: Postgres — Set Exempt

```sql
UPDATE wire_transfers
SET transfer_status = 'EXECUTED',
    retention_until = now()::date + interval '10 years'
WHERE id = {{ $json.id }}
RETURNING *;
```

---

#### Node 6: Switch: Role Router

| Property | Value |
|---|---|
| **Type** | `switch` |
| **Routes on** | `{{ $json.direction }}` |
| **Output 0** | `OUTGOING` → Ordering track (Nodes 7–16) |
| **Output 1** | `FORWARDING` → Intermediary track (Nodes 17–25) |
| **Output 2** | `INCOMING` → Beneficiary track (Nodes 26–36) |

---

### Ordering Track (Nodes 7–16)

#### Node 7: Lookup Originator CDD

```sql
SELECT c.id, cc.status, cc.case_ref
FROM customers c
JOIN cdd_cases cc ON c.case_id = cc.id
WHERE c.id = {{ $('Insert Raw Transfer').first().json.originator_customer_id }};
```

#### Node 8: IF: CDD Approved?

| Condition | `{{ $json.status }}` equals `APPROVED` |
|---|---|
| **True** | → Node 11: Verify Outgoing Fields |
| **False** | → Node 9: Block CDD Failure |

#### Node 9: Block CDD Failure

```sql
UPDATE wire_transfers
SET transfer_status = 'REJECTED',
    flagged_for_cdd_failure = TRUE,
    retention_until = now()::date + interval '10 years'
WHERE id = {{ $('Insert Raw Transfer').first().json.id }}
RETURNING *;
```

#### Node 11: Verify Outgoing Fields (Key JS Node)

```javascript
const wt = $('Insert Raw Transfer').first().json;
let isComplete = true;
let missing = [];

// Originator fields (Reg 11 §3)
if (!wt.originator_name) { isComplete = false; missing.push('originator_name'); }
if (!wt.originator_account_ref) { isComplete = false; missing.push('originator_account_ref'); }

// For individual transfers, originator ID doc is mandatory (§3(a))
if (wt.transfer_type === 'INDIVIDUAL') {
  if (!wt.originator_id_doc_number) { isComplete = false; missing.push('originator_id_doc_number'); }
}

// Beneficiary fields
if (!wt.beneficiary_name) { isComplete = false; missing.push('beneficiary_name'); }
if (!wt.beneficiary_account_ref) { isComplete = false; missing.push('beneficiary_account_ref'); }

return { is_complete: isComplete, missing_fields: missing };
```

#### Node 15: Send Outgoing

```sql
UPDATE wire_transfers
SET transfer_status = 'SENT',
    retention_until = now()::date + interval '10 years'
WHERE id = {{ $('Insert Raw Transfer').first().json.id }}
RETURNING *;
```

---

### Intermediary Track (Nodes 17–25)

#### Node 17: Verify Forwarding Fields (JS Code)

```javascript
const wt = $('Insert Raw Transfer').first().json;
let isComplete = true;
let missing = [];

if (!wt.originator_name) { isComplete = false; missing.push('originator_name'); }
if (!wt.originator_account_ref) { isComplete = false; missing.push('originator_account_ref'); }
if (!wt.beneficiary_name) { isComplete = false; missing.push('beneficiary_name'); }
if (!wt.beneficiary_account_ref) { isComplete = false; missing.push('beneficiary_account_ref'); }

return { is_complete: isComplete, missing_fields: missing };
```

#### Node 22: Insert Hold Record

```sql
INSERT INTO wire_transfer_holds (wire_transfer_id, role_at_bank, hold_reason, review_status)
VALUES (
  {{ $('Insert Raw Transfer').first().json.id }},
  'INTERMEDIARY',
  'Missing fields: {{ $('Verify Forwarding Fields').first().json.missing_fields.join(", ") }}',
  'PENDING_REVIEW'
) RETURNING *;
```

#### Node 23: Log Correspondent Incompleteness

```sql
INSERT INTO correspondent_completeness_logs (institution_name, wire_transfer_id, missing_fields_count)
VALUES (
  '{{ $('Insert Raw Transfer').first().json.sending_institution }}',
  {{ $('Insert Raw Transfer').first().json.id }},
  {{ $('Verify Forwarding Fields').first().json.missing_fields.length }}
);
```

---

### Beneficiary Track (Nodes 26–36)

#### Node 26: Lookup Beneficiary CDD

```sql
SELECT cc.status, cc.case_ref
FROM customers c
JOIN cdd_cases cc ON c.case_id = cc.id
WHERE c.full_name = '{{ $('Insert Raw Transfer').first().json.beneficiary_name }}'
ORDER BY cc.id DESC LIMIT 1;
```

#### Node 32: Insert Hold Record (Beneficiary)

```sql
INSERT INTO wire_transfer_holds (wire_transfer_id, role_at_bank, hold_reason, review_status)
VALUES (
  {{ $('Insert Raw Transfer').first().json.id }},
  'BENEFICIARY',
  CASE 
    WHEN '{{ $('Lookup Beneficiary CDD').first().json.status }}' != 'APPROVED'
      THEN 'Beneficiary CDD incomplete'
    ELSE 'Missing fields: {{ $('Verify Incoming Fields').first().json.missing_fields.join(", ") }}'
  END,
  'PENDING_REVIEW'
) RETURNING *;
```

> **Note:** The `CASE WHEN` statement dynamically records the correct hold reason depending on whether it was CDD failure or missing originator data.

#### Node 33: Verify Incoming Fields (JS Code)

```javascript
const wt = $('Insert Raw Transfer').first().json;
let isComplete = true;
let missing = [];

if (!wt.originator_name) { isComplete = false; missing.push('originator_name'); }
if (!wt.originator_account_ref) { isComplete = false; missing.push('originator_account_ref'); }
if (!wt.originator_id_doc_number) { isComplete = false; missing.push('originator_id_doc_number'); }

return { is_complete: isComplete, missing_fields: missing };
```

---

### Flow B: Analyst Hold Action Gate (Nodes 37–49)

#### Node 37: Webhook: Analyst Hold Action

| Property | Value |
|---|---|
| **Type** | `webhook` |
| **Method** | `POST` |
| **Path** | `uc8-analyst-action` |
| **Receives** | `hold_id`, `action`, `reviewer_name`, `rationale` |

#### Node 38: Lookup Hold Details

```sql
SELECT h.*, w.transaction_ref, w.direction, w.originator_customer_id
FROM wire_transfer_holds h
JOIN wire_transfers w ON h.wire_transfer_id = w.id
WHERE h.id = {{ $json.body.hold_id }};
```

#### Node 39: Switch: Analyst Action

| Property | Value |
|---|---|
| **Type** | `switch` |
| **Routes on** | `{{ $('Webhook: Analyst Hold Action').first().json.body.action }}` |
| **Output 0** | `APPROVED_RELEASE` → Release track |
| **Output 1** | `APPROVED_REJECT` → Reject track |
| **Output 2** | `SUSPENDED_STR_ESCALATION` → STR escalation track |

#### Node 40: Update Hold Release

```sql
UPDATE wire_transfer_holds
SET review_status = 'APPROVED_RELEASE',
    reviewed_by = '{{ $('Webhook: Analyst Hold Action').first().json.body.reviewer_name }}',
    reviewed_at = now(),
    rationale = '{{ $('Webhook: Analyst Hold Action').first().json.body.rationale }}'
WHERE id = {{ $json.id }}
RETURNING *;
```

#### Node 41: Release Funds

```sql
UPDATE wire_transfers
SET transfer_status = 'EXECUTED',
    retention_until = now()::date + interval '10 years'
WHERE id = {{ $json.wire_transfer_id }}
RETURNING *;
```

#### Node 47: Suspend Funds

```sql
UPDATE wire_transfers
SET transfer_status = 'SUSPENDED',
    flagged_for_str_review = TRUE,
    retention_until = now()::date + interval '10 years'
WHERE id = {{ $json.wire_transfer_id }}
RETURNING *;
```

#### Node 48: HTTP Request: Trigger UC5 STR

| Property | Value |
|---|---|
| **Type** | `httpRequest` |
| **Method** | `POST` |
| **URL** | `http://localhost:5678/webhook/uc5-str-cross-uc` |
| **Body** | Sends transfer details as a `CROSS_UC_FINDING` trigger to the UC5 STR pipeline |

This is the **cross-UC integration point** — it creates an automated STR case in UC5 based on the suspicious wire transfer hold.

---

## 7. Error Handling & Edge Cases

| Error Condition | Handled By | HTTP | Outcome |
|---|---|---|---|
| Interbank exemption | Node 3 routes to exempt path | `200` | Status set to EXECUTED, all checks bypassed |
| Originator CDD not approved | Node 8 routes to CDD block | `400` | Hard block — transfer cannot leave the bank |
| Missing originator fields (ordering) | Node 12 routes to rejection | `400` | Hard block — transfer rejected |
| Missing fields (intermediary) | Node 18 routes to hold | `202` | Funds held, correspondent bank logged |
| Beneficiary CDD incomplete | Node 27 routes to hold | `202` | Funds held, compliance alerted |
| Missing originator data (beneficiary) | Node 28 routes to hold | `202` | Funds held, correspondent logged |
| Analyst releases hold | Node 41 sets EXECUTED | `200` | Funds released with 10-year retention |
| Analyst rejects hold | Node 44 sets REJECTED | `200` | Funds terminated with retention |
| Analyst escalates to STR | Nodes 46-48 | `200` | Transfer suspended, UC5 STR case auto-created |

---

## 8. Security & Access Control

### 8.1 Credential Management
| Credential | Type | Usage |
|---|---|---|
| `AML Postgres` | PostgreSQL | All database operations (49 nodes) |
| `AML SMTP` | SMTP/Gmail | Hold alert emails for intermediary and beneficiary tracks |

### 8.2 Access Design
- **Intake webhook** (`uc8-wire-intake`): Designed to be called by the payment processing system
- **Analyst webhook** (`uc8-analyst-action`): Designed for compliance analyst use only
- **Hold rationale constraint**: `wire_transfer_holds.rationale` has a CHECK constraint: `review_status = 'PENDING_REVIEW' OR length(trim(rationale)) > 0` — analysts cannot close a hold without documenting a rationale

### 8.3 Data Integrity
- `retention_until` is computed on every terminal status transition (never left NULL)
- `correspondent_completeness_logs` builds a failure history per institution for risk-rating purposes
- `flagged_for_str_review = TRUE` is set as a permanent flag when a transfer is escalated

---

## 9. Automated Test Scenarios & Verification

Test scripts: `tests/uc8_wire_transfers/test_uc8_wire_transfers.sh`

| # | Payload | Scenario | Expected Path | Expected HTTP |
|---|---|---|---|---|
| 1 | `01_outgoing_compliant.json` | Outgoing with valid CDD and complete fields | SENT with 10-year retention | `200` |
| 2 | `02_outgoing_missing_originator_id.json` | Outgoing missing originator ID doc | Hard block → REJECTED | `400` |
| 3 | `03_intermediary_hold_release.json` | Intermediary receives incomplete data | HELD → analyst releases → EXECUTED | `202` then `200` |
| 4 | `04_beneficiary_escalate_str.json` | Beneficiary receives suspicious transfer | HELD → analyst escalates → UC5 STR case created | `202` then `200` |
| 5 | `05_interbank_settlement_exempt.json` | Own-behalf settlement between two SBP banks | All checks bypassed → EXECUTED | `200` |

### Running Tests

```bash
cd tests/uc8_wire_transfers
./test_uc8_wire_transfers.sh payloads/01_outgoing_compliant.json
```

---

## 10. Cross-UC Integration

### 10.1 Inbound Dependencies

| Source UC | What UC8 Consumes | Mechanism |
|---|---|---|
| **UC1** | `customers` table (customer profiles) | Looks up originator/beneficiary customer IDs |
| **UC1** | `cdd_cases` table (CDD status) | Verifies CDD is `APPROVED` before allowing ordering/beneficiary transfers |

### 10.2 Outbound Dependencies

| Target UC | What UC8 Provides | Mechanism |
|---|---|---|
| **UC5** | STR escalation for suspicious wire transfers | Node 48 makes HTTP POST to `http://localhost:5678/webhook/uc5-str-cross-uc` with `CROSS_UC_FINDING` trigger type |

### 10.3 Cross-UC HTTP Call Details

When an analyst selects `SUSPENDED_STR_ESCALATION`:
1. Node 46 updates the hold status to `SUSPENDED_STR_ESCALATION`
2. Node 47 updates the transfer to `SUSPENDED` and sets `flagged_for_str_review = TRUE`
3. **Node 48** makes an HTTP POST to UC5's cross-UC webhook:
   - **URL:** `http://localhost:5678/webhook/uc5-str-cross-uc`
   - **Body:** Transfer details including `transaction_ref`, `originator_customer_id`, hold reason
   - **Effect:** UC5 creates a new STR case with `trigger_type = 'CROSS_UC_FINDING'`

### 10.4 Shared Database Tables

| Table | Owner | Also Used By |
|---|---|---|
| `customers` | UC1 | UC8 reads for CDD lookup |
| `cdd_cases` | UC1 | UC8 reads status |
| `wire_transfers` | UC8 | Standalone |
| `wire_transfer_holds` | UC8 | Standalone |
