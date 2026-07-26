# UC3: PEP Lifecycle Monitoring & Enhanced Due Diligence — Technical Document

**Version:** 1.0  
**Workflow File:** `n8n/workflows/uc3_pep_lifecycle.json`  
**Schema File:** `db/init/003_uc3_schema.sql`  
**Seed File:** `db/init/004_uc3_seed.sql`  
**Node Count:** 59  
**Flows:** 4 (Rescreening, Analyst Review, SOW & Approval, Step-Down)

---

## 1. Executive Summary

### 1.1 Problem Statement
After a customer is onboarded (UC1), the bank must **continuously monitor** whether any of its customers are or become Politically Exposed Persons (PEPs). PEPs — ministers, judges, military generals, central bank governors, etc. — represent a heightened ML/TF risk due to their susceptibility to corruption. SBP requires banks to apply Enhanced Due Diligence (EDD) to PEPs, their family members, and close associates.

### 1.2 Critical Regulatory Principle
**"Once a PEP, always a PEP"** (SBP Definition 52: "is or has been"). A PEP designation must remain active in the bank's records permanently. The bank *can* reduce monitoring intensity (ENHANCED → STANDARD) after an observation period, but the designation itself never expires.

### 1.3 What This Workflow Does
UC3 automates the complete PEP lifecycle: periodic/event-based rescreening using fuzzy name matching, compliance analyst review, relationship classification, seniority filtering, Source of Wealth verification, senior management approval, recertification scheduling, and monitoring intensity step-downs.

### 1.4 SBP Regulatory Basis
- **Definition 52** — PEP definition ("is or has been") and seniority exclusion (§d)
- **Definition 12** — Close Associate definition
- **Definition 28** — Family Member definition
- **Regulation 5 §1(b)** — Senior management approval
- **Regulation 5 §1(c)** — Source of Wealth verification
- **Regulation 5 §1(d)** — Monitoring intensity transitions

### 1.5 Target Users
| Role | Interaction |
|---|---|
| System (Scheduler) | Triggers monthly rescreening cycles |
| Compliance Analyst | Reviews matches, classifies relationships, submits SOW evidence |
| Senior Management | Approves/exits PEP relationships, authorizes step-downs |

---

## 2. Regulatory Mapping & Reference Matrix

| # | Regulatory Directive | SBP Clause | Workflow Node(s) | Implementation |
|---|---|---|---|---|
| 1 | PEP Definition | Def 52 | Node 33 | `pep_designations.is_active = TRUE` — designations never auto-expire |
| 2 | Close Associate Detection | Def 12 | Nodes 27–29 | Tests joint BO, entity-for-PEP benefit, and known close connection |
| 3 | Family Member Identification | Def 28 | Nodes 27–29 | Tests spouse, lineal descendant/ascendant, and sibling relationships |
| 4 | Seniority Exclusion | Def 52(d) | Nodes 30–31 | Junior/middle officials excluded from PEP classification |
| 5 | SOW Verification | Reg 5 §1(c) | Nodes 36–40 | All SOW evidence must be `reconciled = TRUE` before approval proceeds |
| 6 | Senior Management Approval | Reg 5 §1(b) | Node 41 | Requires CONTINUE_RELATIONSHIP or EXIT_RELATIONSHIP decision |
| 7 | Monitoring Step-Down | Reg 5 §1(d) | Nodes 54–55 | ENHANCED → STANDARD transition logged with full audit trail |
| 8 | Fuzzy Name Matching | Best Practice | Node 9 | PostgreSQL `pg_trgm` trigram matching with ≥60% confidence floor |

---

## 3. Process Flow Diagrams

### 3.1 Flow A: Scheduled/Event-Based Rescreening (Nodes 1–18)

```
Schedule Trigger (1st of month) ──┐
                                  ├──► [Node 3: Merge Triggers]
POST /webhook/uc3-rescreen  ──────┘
   │
   ▼
[Node 4: Insert Rescreening Cycle] → [Node 5: Get Active Customers]
   │
   ▼
[Node 6: Insert Rescreening Candidates] → [Node 7: Loop Over Candidates]
   │                                           │
   │                              [Node 8: Get Candidate Details]
   │                                           │
   │                              [Node 9: Fuzzy Match (pg_trgm ≥ 0.6)]
   │                                           │
   │                              [Node 10: IF: Match Found?]
   │                                 ├── Yes → [Node 11: Insert Match Candidate]
   │                                 └── No  → [back to loop]
   │                                           │
   │                              [Node 12: Loop Ends]
   ▼
[Node 58: Collapse to Single Item] → [Node 13: Complete Cycle]
   │
   ▼
[Node 57: Send Summary Email] → [Node 14: Respond: Screening Complete]
```

### 3.2 Flow B: Analyst Match & Classification (Nodes 15–35)

```
POST /webhook/uc3-analyst-review
   │
   ▼
[Node 16: Lookup Match Candidate] → [Node 17: IF: Match Exists?]
   │                                    ├── No  → [Node 18: Respond: Not Found (404)]
   │                                    └── Yes ↓
   ▼
[Node 19: IF: Decision = Confirm?]
   ├── No (REJECTED) → [Node 20: Update Status REJECTED] → [Node 21: Respond: Rejected (200)]
   └── Yes (CONFIRMED) ↓
[Node 22: Update Status CONFIRMED] → [Node 23: Get Watchlist Details]
   │
   ▼
[Node 24: Insert Match Record] → [Node 25: Insert Relationship Classification]
   │
   ▼
[Node 26: IF: Classification = DIRECT_PEP?]
   ├── Yes → [Node 27: Insert Seniority Check]
   │              │
   │         [Node 28: IF: Is Senior Enough?]
   │            ├── No  → [Node 29: Update EXCLUDED_DEF52D] → [Node 30: Respond: Excluded (200)]
   │            └── Yes → [Node 31: Create PEP Designation] → [Node 32: Respond: Designated (200)]
   │
   └── No (FAMILY_MEMBER / CLOSE_ASSOCIATE)
        → [Node 33: Create PEP Designation (non-direct)] → [Node 34: Respond: Designated (200)]
```

### 3.3 Flow C: SOW Verification & Senior Management Approval (Nodes 35–49)

```
POST /webhook/uc3-sow-action
   │
   ▼
[Node 36: IF: Action = submit_evidence?]
   ├── Yes → [Node 37: Insert SOW Evidence] → [Node 38: Respond: Evidence Submitted (200)]
   └── No (action = approve)
          ↓
[Node 39: Check All Evidence Reconciled]
   │
   ▼
[Node 40: IF: All Reconciled?]
   ├── No  → [Node 40b: Respond: ON_HOLD (422)]
   └── Yes → [Node 41: Insert Senior Mgmt Approval]
                │
                ▼
          [Node 42: IF: Continue Relationship?]
             ├── No  → [Node 43: Send Exit Email] → [Node 44: Respond: Exit Relationship]
             └── Yes → [Node 45: Get Designation Details]
                           │
                    [Node 46: Insert Enhanced Monitoring Flag]
                           │
                    [Node 47: Insert Recertification Schedule]
                           │
                    [Node 48: Send Lifecycle Complete Email]
                           │
                    [Node 49: Respond: Lifecycle Complete (200)]
```

### 3.4 Flow D: Monitoring Intensity Step-Down (Nodes 50–59)

```
POST /webhook/uc3-stepdown
   │
   ▼
[Node 51: Validate Designation Active]
   │
   ▼
[Node 52: IF: Designation Active?]
   ├── No  → [Node 53: Respond: Not Active (400)]
   └── Yes → [Node 54: Insert Monitoring Intensity Log]
                │
          [Node 55: Update Monitoring Tier to STANDARD]
                │
          [Node 59: Send Step-Down Email]
                │
          [Node 56: Respond: Step-Down Complete (200)]
```

---

## 4. Database Schema & ERD

### 4.1 Reference Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `pep_watchlist_source` | Static PEP watchlist seed data | `full_name`, `pep_category` (FOREIGN/DOMESTIC/INTL_ORG), `seniority_level` (SENIOR/JUNIOR_MIDDLE) |

### 4.2 Screening Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `rescreening_cycles` | Tracks each rescreening run | `cycle_type` (SCHEDULED/EVENT_TRIGGERED), `trigger_reason`, `status` |
| `rescreening_candidates` | Links customers to screening cycles | `cycle_id`, `customer_id`, `person_role` |
| `pep_match_candidates` | Raw fuzzy match results | `match_confidence`, `review_status` (PENDING_REVIEW/CONFIRMED_MATCH/REJECTED_NOT_SAME_PERSON) |
| `relationship_classification` | Analyst classification per Def 12/28 | `classification_type`, sub-test booleans for each regulatory definition |
| `seniority_exclusion_check` | Def 52(d) seniority gate | `is_senior_enough`, `role_verified` |

### 4.3 Designation Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `pep_designations` | Core PEP designation (never deleted) | `designation_type`, `pep_category`, `is_active` (always TRUE per "is or has been") |
| `source_of_wealth_evidence` | SOW documents and reconciliation | `evidence_type`, `reconciled`, `reconciliation_notes` |
| `pep_senior_mgmt_approvals` | Senior management approval decisions | `decision` (CONTINUE_RELATIONSHIP/EXIT_RELATIONSHIP), `approver_name` |
| `enhanced_monitoring_flags` | Current monitoring tier per customer | `monitoring_tier` (ENHANCED/STANDARD) |
| `monitoring_intensity_log` | Audit trail of tier transitions | `previous_tier`, `new_tier`, `reason`, `approved_by` |
| `recertification_schedule` | Next recertification dates | `risk_tier`, `next_recertification_date` |

### 4.4 ERD

```
pep_watchlist_source
       │
       └──► pep_match_candidates ──► relationship_classification
                │                   └──► seniority_exclusion_check
                │
                └──► pep_designations ──► source_of_wealth_evidence
                          │            └──► pep_senior_mgmt_approvals
                          ├──► enhanced_monitoring_flags
                          ├──► monitoring_intensity_log
                          └──► recertification_schedule

rescreening_cycles ──► rescreening_candidates ──► pep_match_candidates
```

---

## 5. API / Webhook Reference

### 5.1 Endpoint: Event-Based Rescreening Trigger

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc3-rescreen` |
| **Response Mode** | `Respond to Webhook node` |

#### Request Body

```json
{
  "trigger_reason": "BO_CHANGE | PROFILE_UPDATE | REACTIVATION | MONTHLY_BATCH"
}
```

#### Response (HTTP 200)

```json
{
  "status": "SCREENING_COMPLETE",
  "cycle_id": 15,
  "total_screened": 10,
  "matches_found": 2
}
```

---

### 5.2 Endpoint: Analyst Match Review

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc3-analyst-review` |
| **Response Mode** | `Respond to Webhook node` |

#### Request Body

```json
{
  "match_candidate_id": 5,
  "review_decision": "CONFIRMED_MATCH | REJECTED_NOT_SAME_PERSON",
  "reviewer_name": "Analyst Ahmed",
  "reviewer_notes": "Name and DOB match confirmed via passport verification",
  "classification_type": "DIRECT_PEP | FAMILY_MEMBER | CLOSE_ASSOCIATE",
  "test_joint_beneficial_ownership": false,
  "test_entity_set_up_for_pep_benefit": false,
  "test_reasonably_known_close_connection": false,
  "test_is_spouse": false,
  "test_is_lineal_descendant_ascendant": false,
  "test_is_sibling": true
}
```

#### Possible Responses

| Outcome | HTTP | Body Key |
|---|---|---|
| Match rejected | `200` | `"status": "REJECTED_NOT_SAME_PERSON"` |
| Excluded (junior) | `200` | `"status": "EXCLUDED_DEF52D"` |
| Designation created | `200` | `"status": "PEP_DESIGNATED"`, includes `designation_id` |
| Match not found | `404` | `"status": "NOT_FOUND"` |

---

### 5.3 Endpoint: SOW Action

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc3-sow-action` |
| **Response Mode** | `Respond to Webhook node` |

#### Request Body — Submit Evidence

```json
{
  "action": "submit_evidence",
  "designation_id": 3,
  "evidence_type": "ASSET_DECLARATION | SALARY_DISCLOSURE | BANK_STATEMENT | BUSINESS_OWNERSHIP_PROOF",
  "file_ref": "/docs/sow_assets.pdf",
  "declared_source": "Real estate holdings in DHA Phase 6",
  "reconciled": false,
  "reviewed_by": "Analyst Ahmed"
}
```

#### Request Body — Approve

```json
{
  "action": "approve",
  "designation_id": 3,
  "decision": "CONTINUE_RELATIONSHIP | EXIT_RELATIONSHIP",
  "approver_name": "Chief Compliance Officer",
  "approver_role": "SENIOR_MANAGEMENT",
  "comments": "All SOW evidence verified and reconciled"
}
```

#### Possible Responses

| Outcome | HTTP | Body Key |
|---|---|---|
| Evidence submitted | `200` | `"status": "EVIDENCE_SUBMITTED"` |
| SOW not reconciled | `422` | `"status": "ON_HOLD"`, `unreconciled_count` |
| Relationship exit | `200` | `"status": "EXIT_RELATIONSHIP"` |
| Lifecycle complete | `200` | `"status": "PEP_LIFECYCLE_COMPLETE"`, includes monitoring tier and recertification date |

---

### 5.4 Endpoint: Monitoring Step-Down

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc3-stepdown` |
| **Response Mode** | `Respond to Webhook node` |

#### Request Body

```json
{
  "designation_id": 3,
  "reason": "Left public office, 18-month observation period completed",
  "approved_by": "Chief Compliance Officer"
}
```

#### Possible Responses

| Outcome | HTTP | Body Key |
|---|---|---|
| Step-down complete | `200` | `"status": "STEP_DOWN_COMPLETE"`, `"designation_still_active": true` |
| Designation not active | `400` | `"status": "ERROR"` |

---

## 6. Node-by-Node Configuration

### Flow A: Rescreening

#### Node 1: Schedule Trigger — Monthly Batch

| Property | Value |
|---|---|
| **Type** | `scheduleTrigger` |
| **Schedule** | 1st of every month at midnight |
| **Forwards** | `{ "trigger_reason": "MONTHLY_BATCH" }` |

#### Node 2: Webhook Trigger — Event-Based

| Property | Value |
|---|---|
| **Type** | `webhook` |
| **Method** | `POST` |
| **Path** | `uc3-rescreen` |
| **Forwards** | `$json.body.trigger_reason` |

#### Node 3: Merge Triggers

| Property | Value |
|---|---|
| **Type** | `merge` |
| **Does** | Consolidates the schedule trigger and event webhook into a single execution path |

#### Node 4: Insert Rescreening Cycle

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Creates a new cycle record |

```sql
INSERT INTO rescreening_cycles (cycle_type, trigger_reason, status)
VALUES (
  CASE WHEN '{{ $json.trigger_reason }}' = 'MONTHLY_BATCH' THEN 'SCHEDULED' ELSE 'EVENT_TRIGGERED' END,
  '{{ $json.trigger_reason }}',
  'RUNNING'
) RETURNING id, cycle_type;
```

#### Node 5: Get Active Customers

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Retrieves all active customer and beneficial owner profiles for screening |

```sql
SELECT c.id AS customer_id, c.full_name, c.date_of_birth, c.role,
       cc.case_ref, cc.id AS case_id
FROM customers c
JOIN cdd_cases cc ON c.case_id = cc.id
WHERE cc.status = 'APPROVED';
```

#### Node 6: Insert Rescreening Candidates

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Bulk-inserts all active customers into `rescreening_candidates` for this cycle |

#### Node 7–12: Loop Over Candidates

| Node | Type | Does |
|---|---|---|
| 7 | `splitInBatches` | Iterates through each candidate one at a time |
| 8 | `postgres` | Retrieves full candidate details (name, DOB) for the current item |
| 9 | `postgres` | **Core fuzzy matching** — trigram similarity query against watchlist |
| 10 | `if` | Routes based on whether a match was found (match_confidence > 0) |
| 11 | `postgres` | Inserts match into `pep_match_candidates` with status `PENDING_REVIEW` |
| 12 | Loop back to Node 7 |

**Node 9 — Fuzzy Match Query (Key Node):**
```sql
SELECT
  pw.id AS pep_watchlist_source_id,
  pw.full_name AS watchlist_name,
  pw.pep_category,
  pw.seniority_level,
  ROUND((similarity(
    LOWER('{{ $json.full_name }}'),
    LOWER(pw.full_name)
  ) * 100)::numeric, 2) AS match_confidence
FROM pep_watchlist_source pw
WHERE similarity(
  LOWER('{{ $json.full_name }}'),
  LOWER(pw.full_name)
) >= 0.6
ORDER BY match_confidence DESC
LIMIT 1;
```

> **Critical Setting:** `Always Output Data = ON` to prevent loop hang when no match is found.

#### Node 58: Collapse to Single Item

| Property | Value |
|---|---|
| **Type** | `code` |
| **Mode** | Run Once for All Items |
| **Code** | `return [ $input.first() ];` |
| **Why** | After the loop, downstream nodes (update cycle, send email) must execute exactly once, not once per loop item |

#### Node 13: Complete Cycle

| Property | Value |
|---|---|
| **Type** | `postgres` |
| **Does** | Updates cycle status to `COMPLETE` |

```sql
UPDATE rescreening_cycles SET status = 'COMPLETE', completed_at = now()
WHERE id = {{ $('Insert Rescreening Cycle').first().json.id }};
```

---

### Flow B: Analyst Review (Nodes 15–34)

#### Node 15: Webhook Trigger — Analyst Review

| Property | Value |
|---|---|
| **Type** | `webhook` |
| **Method** | `POST` |
| **Path** | `uc3-analyst-review` |
| **Receives** | `match_candidate_id`, `review_decision`, `classification_type`, relationship sub-tests |

#### Node 16: Lookup Match Candidate

```sql
SELECT mc.id, mc.review_status, mc.match_confidence,
       rc.customer_id, rc.cycle_id, c.full_name,
       pw.pep_category, pw.seniority_level, pw.position_title
FROM pep_match_candidates mc
JOIN rescreening_candidates rc ON mc.rescreening_candidate_id = rc.id
JOIN customers c ON rc.customer_id = c.id
JOIN pep_watchlist_source pw ON mc.pep_watchlist_source_id = pw.id
WHERE mc.id = {{ $json.body.match_candidate_id }};
```

#### Node 19: IF: Decision = Confirm?

| Condition | `{{ $json.body.review_decision }}` equals `CONFIRMED_MATCH` |
|---|---|
| **Output 0 (True)** | → Node 22: Update Status CONFIRMED |
| **Output 1 (False)** | → Node 20: Update Status REJECTED |

#### Nodes 27–28: Seniority Gate (Def 52d)

| Node | Does |
|---|---|
| 27 | Inserts seniority check record into `seniority_exclusion_check` with `is_senior_enough` from watchlist data |
| 28 | IF: `seniority_level = 'SENIOR'`? If yes → create designation. If no → mark as EXCLUDED |

#### Node 31/33: Create PEP Designation

```sql
INSERT INTO pep_designations (
  customer_id, pep_match_candidate_id, designation_type, pep_category, is_active
) VALUES (
  {{ $json.customer_id }},
  {{ $('Webhook Trigger — Analyst Review').first().json.body.match_candidate_id }},
  '{{ $('Webhook Trigger — Analyst Review').first().json.body.classification_type }}',
  '{{ $json.pep_category }}',
  TRUE
) RETURNING id, designation_type, pep_category;
```

---

### Flow C: SOW & Approval (Nodes 35–49)

#### Node 37: Insert SOW Evidence

```sql
INSERT INTO source_of_wealth_evidence (
  pep_designation_id, evidence_type, file_ref, declared_source,
  reconciled, reviewed_by, reviewed_at
) VALUES (
  {{ $json.body.designation_id }},
  '{{ $json.body.evidence_type }}',
  '{{ $json.body.file_ref }}',
  '{{ $json.body.declared_source }}',
  {{ $json.body.reconciled || false }},
  '{{ $json.body.reviewed_by }}',
  now()
) RETURNING id;
```

#### Node 39: Check All Evidence Reconciled

```sql
SELECT
  COUNT(*) AS total_evidence,
  SUM(CASE WHEN reconciled = TRUE THEN 1 ELSE 0 END) AS reconciled_count,
  SUM(CASE WHEN reconciled = FALSE THEN 1 ELSE 0 END) AS unreconciled_count
FROM source_of_wealth_evidence
WHERE pep_designation_id = {{ $json.body.designation_id }};
```

#### Node 47: Insert Recertification Schedule

```sql
INSERT INTO recertification_schedule (
  pep_designation_id, risk_tier, next_recertification_date,
  last_recertified_at, last_recertified_by
) VALUES (
  {{ $json.designation_id }},
  '{{ $json.pep_category }}',
  CASE
    WHEN '{{ $json.pep_category }}' = 'FOREIGN'
      THEN (now() + INTERVAL '6 months')::date
      ELSE (now() + INTERVAL '12 months')::date
  END,
  now(),
  '{{ $('Webhook Trigger — SOW & Approval').first().json.body.approver_name }}'
) RETURNING id, risk_tier, next_recertification_date;
```

---

### Flow D: Step-Down (Nodes 50–59)

#### Node 51: Validate Designation Active

```sql
SELECT pd.id, pd.is_active, pd.designation_type, pd.pep_category,
       c.full_name AS customer_name, emf.monitoring_tier AS current_tier
FROM pep_designations pd
JOIN customers c ON pd.customer_id = c.id
LEFT JOIN enhanced_monitoring_flags emf ON emf.pep_designation_id = pd.id
WHERE pd.id = {{ $json.body.designation_id }};
```

#### Node 54: Insert Monitoring Intensity Log

```sql
INSERT INTO monitoring_intensity_log (
  pep_designation_id, previous_tier, new_tier, reason, approved_by, approved_at
) VALUES (
  {{ $json.body.designation_id }},
  '{{ $('Validate Designation Active').first().json.current_tier }}',
  'STANDARD',
  '{{ $json.body.reason }}',
  '{{ $json.body.approved_by }}',
  now()
) RETURNING id, previous_tier, new_tier;
```

#### Node 55: Update Monitoring Tier

```sql
UPDATE enhanced_monitoring_flags
SET monitoring_tier = 'STANDARD',
    set_at = now(),
    set_by = '{{ $json.body.approved_by }}'
WHERE pep_designation_id = {{ $json.body.designation_id }}
RETURNING id, customer_id, monitoring_tier;
```

---

## 7. Error Handling & Edge Cases

| Error Condition | How It's Handled | HTTP Code |
|---|---|---|
| Match candidate ID doesn't exist | Node 17 routes to 404 response | `404` |
| Analyst rejects as false positive | Status updated to REJECTED_NOT_SAME_PERSON; no designation created | `200` |
| Junior/middle official matched | Seniority gate blocks; status set to EXCLUDED_DEF52D | `200` |
| SOW evidence not reconciled | Approval blocked; returns unreconciled count | `422` |
| Step-down on inactive designation | Node 52 routes to error response | `400` |
| Senior management exits relationship | Sends exit email, returns EXIT_RELATIONSHIP status | `200` |
| Fuzzy match returns zero results | `Always Output Data = ON` prevents loop hang; candidate skipped | N/A |

---

## 8. Security & Access Control

### 8.1 Credential Management
| Credential | Type | Usage |
|---|---|---|
| `AML Postgres` | PostgreSQL | All database operations |
| `AML SMTP` | SMTP/Gmail | Notification emails at screening completion, lifecycle completion, and step-down |

### 8.2 Human-Gated Design
- **No auto-clear**: Every match sits at `PENDING_REVIEW` until a human analyst explicitly resolves it
- **No auto-approve**: Senior management must explicitly call the SOW approval webhook
- **No auto-expire**: PEP designations never auto-deactivate; step-downs require explicit senior management authorization
- **Audit trail**: Every decision is logged with `actor`, `timestamp`, and `notes`

### 8.3 Data Integrity
- `match_confidence` is used **only for triage ordering** — it is never a decision input
- `reconciled` flag on SOW evidence can only be set to `TRUE` by an analyst (never automatically)

---

## 9. Automated Test Scenarios & Verification

Test scripts: `tests/uc3_pep_lifecycle/test_pep_lifecycle.sh`

| # | Payload | Scenario | Expected Path | Expected HTTP |
|---|---|---|---|---|
| 1 | `01_foreign_pep_full_path.json` | Foreign PEP match on company director | Screen → Confirm → Designate → SOW → Approve → Enhanced Monitoring + Recertification | `200` |
| 2 | `02_junior_middle_exclusion.json` | Junior provincial tax officer | Screen → Confirm → Seniority gate blocks → EXCLUDED_DEF52D | `200` |
| 3 | `03_analyst_rejects_match.json` | False positive (different DOB) | Screen → Reject → No designation | `200` |
| 4 | `04_family_member_sibling_test.json` | Sibling of domestic PEP | Screen → Confirm → FAMILY_MEMBER classification → Designate | `200` |
| 5 | `05_sow_evidence_not_reconciled.json` | SOW docs uploaded but unreconciled | Screen → Confirm → Designate → SOW submitted → Approve blocked (ON_HOLD) | `422` |
| 6 | `06_monitoring_step_down.json` | Former PEP, 18 months post-office | Full lifecycle → Step-down to STANDARD → Designation stays active | `200` |

### Running Tests

```bash
cd tests/uc3_pep_lifecycle
./test_pep_lifecycle.sh payloads/01_foreign_pep_full_path.json
```

---

## 10. Cross-UC Integration

### 10.1 Inbound Dependencies

| Source UC | What UC3 Consumes | Mechanism |
|---|---|---|
| **UC1** | `customers` table (customer profiles) | Reads active customer records for rescreening |
| **UC1** | `cdd_cases` table (case status) | Filters to only screen customers with `APPROVED` status |
| **UC1** | `pep_watchlist_seed` | Shares the same seed table used in UC1 onboarding screening |

### 10.2 Outbound Dependencies

| Target UC | What UC3 Provides | Mechanism |
|---|---|---|
| **UC13** | PEP designation counts | UC13 queries `pep_designations`, `pep_match_candidates`, and `tfs_screening_results` for IRAR aggregation |
| **UC1** | Enhanced monitoring tier | `enhanced_monitoring_flags` table used to set account monitoring tier |

### 10.3 Shared Database Tables

| Table | Owner | Also Used By |
|---|---|---|
| `customers` | UC1 | UC3 reads for rescreening |
| `cdd_cases` | UC1 | UC3 filters by status |
| `pep_watchlist_source` | UC3 | Independent from UC1's `pep_watchlist_seed` |
| `pep_designations` | UC3 | UC13 counts |
| `enhanced_monitoring_flags` | UC3 | UC1 references for account monitoring |
