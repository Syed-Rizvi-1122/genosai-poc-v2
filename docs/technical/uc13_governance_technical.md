# UC13: IRAR Auto-Generation & Board of Directors Governance — Technical Document

**Version:** 1.0  
**Workflow File:** `n8n/workflows/uc13_governance.json`  
**Schema File:** `db/init/009_uc13_schema.sql`  
**Seed File:** `db/init/010_uc13_seed.sql`  
**Node Count:** 48  
**Flows:** 11 Webhooks + 1 Scheduler (Cycle Trigger, External Inputs, Staff Snapshot, Drafting, Gap Analysis, Action Plans, Pre-Review, BoD Approval, SOP Approval, UC1 Metrics API, Scheduled Cadence)

---

## 1. Executive Summary

### 1.1 Problem Statement
SBP requires every Regulated Entity (RE) to produce an **Internal Risk Assessment Report (IRAR)** — a strategic document that assesses the institution's ML/TF/PF risk exposure, identifies control gaps, and produces action plans across five mandatory SBP categories. This document must be approved by the Board of Directors (BoD) and kept available for SBP inspection.

Traditionally, IRAR production is a manual, quarterly process involving months of data gathering, narrative drafting, committee reviews, and board presentations. UC13 automates this entire lifecycle.

### 1.2 What This Workflow Does
UC13 orchestrates the complete IRAR governance cycle:
1. **Data Aggregation** — Pulls metrics from UC3 (PEP designations), UC5 (STR/CTR filings), and UC1 (rejected cases) automatically
2. **LLM-Assisted Drafting** — Uses Groq (Llama 3.3 70B) to generate risk narrative drafts across 8 regulatory dimensions
3. **Human Editing** — Analyst reviews and edits LLM drafts before submission
4. **Gap Analysis & Action Plans** — Records identified risks and produces SBP-mandated 5-category action plans
5. **Three-Tier Approval** — Senior Management Pre-Review → BoD Approval → SOP Text Approval
6. **Archival** — Final document archived with 10-year retention and SBP inspection flag

### 1.3 SBP Regulatory Basis
- **Regulation 1 §2–§8** — IRAR framework: risk dimensions, BoD approval mandate
- **Regulation 1 §9, §11** — Proportionality principle
- **Regulation 1 §12** — Senior management SOP approval (separate from BoD)
- **Regulation 13 §1(a)-(c)** — Internal controls and action plan categories
- **Regulation 13 §3** — Rejected cases, risk rating revisions
- **Regulation 13 §9** — Employee screening (DP/PP, Fit & Proper)

### 1.4 Target Users
| Role | Interaction |
|---|---|
| System (Scheduler) | Triggers quarterly IRAR cycles |
| Compliance Team | Enters external inputs, staff snapshots, gap analysis |
| Compliance Analyst | Reviews and edits LLM-generated narratives |
| Senior Management | Pre-reviews IRAR document before BoD submission |
| Board of Directors | Approves/rejects the IRAR document |
| Senior Management | Approves resulting SOP/procedure text updates |

---

## 2. Regulatory Mapping & Reference Matrix

| # | Directive | SBP Clause | Nodes | Implementation |
|---|---|---|---|---|
| 1 | 8 Risk Dimensions | Reg 1 §2 | Node 17 | LLM generates narratives for CUSTOMERS, PRODUCTS, SERVICES, DELIVERY_CHANNELS, TECHNOLOGIES, EMPLOYEE_CATEGORIES, TRANSNATIONAL_TF, EMERGING_RISKS |
| 2 | BoD Approval Mandate | Reg 1 §8 | Nodes 33–35 | `irar_bod_approval` table with CHECK constraint on decision |
| 3 | Proportionality Principle | Reg 1 §9, §11 | Node 22 | `proportionality_note` field in gap analysis records |
| 4 | SOP Approval Separation | Reg 1 §12 | Nodes 36–37 | Separate `irar_sop_approval` table from BoD approval |
| 5 | 5 Action Plan Categories | Reg 13 §1(a)-(c) | Nodes 24–26 | Enforces all 5 SBP categories must be covered before validation passes |
| 6 | Rejected Case Metrics | Reg 13 §3 | Nodes 10–11 | HTTP call to UC1's `/webhook/uc1-compliance-metrics` endpoint |
| 7 | Employee Risk Screening | Reg 13 §9 | Nodes 12–13 | Staff risk snapshot with training, FPT, and DP/PP counts |
| 8 | 10-Year Retention | Reg 8 §3 | Node 45 | `retention_until = now() + 10 years`, `available_for_sbp_inspection = TRUE` |

---

## 3. Process Flow Diagrams

### 3.1 Phase 1: Cycle Trigger & Data Aggregation (Nodes 1–13)

```
Schedule Trigger (Quarterly) ──┐
                               ├──► [Node 3: Insert Cycle Record]
POST /webhook/uc13-cycle ──────┘
   │
   ▼
[Node 3: Insert Cycle Record (status: DATA_AGGREGATION)]
   │
   ├──► [Node 4: Aggregate UC5 Metrics] → [Node 5: Snap UC5 Metrics]
   ├──► [Node 6: Aggregate UC3 Metrics] → [Node 7: Snap UC3 Metrics]
   ├──► [Node 10: Fetch UC1 Metrics (HTTP)] → [Node 11: Insert UC1 Metrics Snapshot]
   │
POST /webhook/uc13-external-inputs
   └──► [Node 8: Webhook] → [Node 9: Insert External Inputs]

POST /webhook/uc13-staff-snapshot
   └──► [Node 12: Webhook] → [Node 13: Insert Staff Snapshot]
```

### 3.2 Phase 2: LLM Drafting (Nodes 14–20)

```
POST /webhook/uc13-start-drafting
   │
   ▼
[Node 14: Set Status DRAFTING] → [Node 15: Webhook: Start Drafting]
   │
   ▼
[Node 16: Get Aggregated Context (SQL)] → [Node 17: LLM Narrative Draft (Groq)]
   │
   ▼
[Node 18: Insert LLM Draft Narrative]

POST /webhook/uc13-edit-narrative
   └──► [Node 19: Webhook] → [Node 20: Update Narrative Text]
```

### 3.3 Phase 3: Gap Analysis & Action Plan (Nodes 21–26)

```
POST /webhook/uc13-gap-entry
   └──► [Node 21: Webhook] → [Node 22: Insert Gap Record]

POST /webhook/uc13-action-item
   └──► [Node 23: Webhook] → [Node 24: Insert Action Plan Item]
                                    │
                              [Node 25: Check Action Plan Categories]
                                    │
                              [Node 26: IF: All 5 SBP Categories Covered?]
                                 ├── Yes → [Node 38: Respond: Validation Passed (200)]
                                 └── No  → [Node 39: Respond: Validation Failed (400)]
```

### 3.4 Phase 4: Three-Tier Approval Chain (Nodes 27–45)

```
POST /webhook/uc13-pre-review
   └──► [Node 28: Set Status SENIOR_MGMT_PREREVIEW] → [Node 29: Send Email]

POST /webhook/uc13-prereview-decision
   └──► [Node 31: Insert Pre-Review Log]
             │
        [Node 32: IF: Pre-Review Approved?]
           ├── Yes → [Node 40: Set Status BOD_APPROVAL]
           └── No  → [Node 41: Set Status DRAFTING (back to revision)]

POST /webhook/uc13-bod-decision
   └──► [Node 34: Insert BoD Log]
             │
        [Node 35: IF: BoD Approved?]
           ├── Yes → [Node 42: Set Status SOP_APPROVAL]
           └── No  → [Node 43: Set Status DRAFTING (back to revision)]

POST /webhook/uc13-sop-decision
   └──► [Node 37: Insert SOP Approval Log]
             │
        [Node 44: Archive Cycle (set ARCHIVED)]
             │
        [Node 45: Save Archive Log (10-year retention)]
```

### 3.5 UC1 Compliance Metrics API (Nodes 46–48)

```
GET /webhook/uc1-compliance-metrics
   └──► [Node 47: Query Metrics (rejected cases, risk revisions, closures)]
             │
        [Node 48: Respond with JSON]
```

---

## 4. Database Schema & ERD

### 4.1 Cycle Management

| Table | Purpose | Key Columns |
|---|---|---|
| `irar_cycles` | Master cycle record | `cycle_ref`, `trigger_type` (CHECK: SCHEDULED/EVENT_NRA_UPDATE/EVENT_EMERGING_THREAT/EVENT_REGULATOR_FEEDBACK), `status` (CHECK: 6 valid states) |

### 4.2 Data Aggregation Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `irar_internal_metrics_snapshot` | Automated metrics from UC3/UC5 | `metric_key` (STR_FILED_COUNT, CTR_FILED_COUNT, PEP_DESIGNATION_COUNT, etc.), `source_table_ref` |
| `irar_external_inputs` | Manually entered external data | `input_type` (CHECK: NRA_UPDATE/MAJOR_INCIDENT_INTELLIGENCE/REGULATOR_FEEDBACK), `source_attribution` (mandatory) |
| `irar_rejected_case_inputs` | UC1 compliance metrics snapshot | `rejected_case_count`, `risk_rating_revision_count`, `ml_tf_pf_closure_count` |
| `irar_employee_risk_snapshot` | Staff risk data | `training_completion_rate`, `fpt_noncompliance_count`, `screening_flags_count` |

### 4.3 Drafting Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `irar_risk_narrative` | LLM and human-edited narratives | `risk_dimension` (CHECK: 8 SBP dimensions), `llm_draft_text`, `human_edited_text`, `edited_by` |
| `irar_gap_analysis` | Identified control gaps | `identified_risk`, `existing_control`, `gap_description`, `proportionality_note`, `severity` (CHECK: LOW/MEDIUM/HIGH) |
| `irar_action_plan_items` | SBP-mandated action plans | `category` (CHECK: 5 mandatory SBP categories), `recommendation`, `target_completion_date`, `owner`, `status` |

### 4.4 Approval Tables

| Table | Purpose | Key Columns |
|---|---|---|
| `irar_senior_mgmt_prereview` | Senior management pre-review | `decision` (CHECK: APPROVED_FOR_BOD/RETURNED_FOR_REVISION) |
| `irar_bod_approval` | Board of Directors approval | `decision` (CHECK: APPROVED/RETURNED_FOR_REVISION), `meeting_ref` |
| `irar_sop_approval` | SOP text approval (separate from BoD) | `action_plan_item_id`, `decision`, `updated_sop_reference` |

### 4.5 Archival

| Table | Purpose | Key Columns |
|---|---|---|
| `irar_archive` | Final archived documents | `final_document_ref`, `bod_deck_ref`, `retention_until`, `available_for_sbp_inspection` |

### 4.6 ERD

```
irar_cycles ──► irar_internal_metrics_snapshot
     │       ──► irar_external_inputs
     │       ──► irar_rejected_case_inputs
     │       ──► irar_employee_risk_snapshot
     │       ──► irar_risk_narrative
     │       ──► irar_gap_analysis
     │       ──► irar_action_plan_items ──► irar_sop_approval
     │       ──► irar_senior_mgmt_prereview
     │       ──► irar_bod_approval
     └─────────► irar_archive
```

---

## 5. API / Webhook Reference

### 5.1 Cycle Trigger

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc13-cycle` |

#### Request Body
```json
{
  "trigger_type": "SCHEDULED | EVENT_NRA_UPDATE | EVENT_EMERGING_THREAT | EVENT_REGULATOR_FEEDBACK",
  "trigger_note": "Quarterly scheduled IRAR review cycle Q3 2026"
}
```

---

### 5.2 External Inputs

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc13-external-inputs` |

#### Request Body
```json
{
  "cycle_id": 1,
  "input_type": "NRA_UPDATE | MAJOR_INCIDENT_INTELLIGENCE | REGULATOR_FEEDBACK",
  "description": "SBP updated its National Risk Assessment with new ML typologies",
  "source_attribution": "SBP NRA 2026 Update — Circular No. AML/2026/03",
  "relevance_note": "New typologies on trade-based ML via free zone entities",
  "entered_by": "Compliance Officer"
}
```

---

### 5.3 Staff Risk Snapshot

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc13-staff-snapshot` |

#### Request Body
```json
{
  "cycle_id": 1,
  "training_completion_rate": 92.5,
  "fpt_noncompliance_count": 2,
  "screening_flags_count": 1
}
```

---

### 5.4 Start Drafting (LLM Generation)

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc13-start-drafting` |

#### Request Body
```json
{
  "cycle_id": 1,
  "risk_dimension": "CUSTOMERS | PRODUCTS | SERVICES | DELIVERY_CHANNELS | TECHNOLOGIES | EMPLOYEE_CATEGORIES | TRANSNATIONAL_TF | EMERGING_RISKS"
}
```

---

### 5.5 Edit Narrative

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc13-edit-narrative` |

#### Request Body
```json
{
  "narrative_id": 1,
  "human_edited_text": "Analyst-revised risk narrative text...",
  "edited_by": "Compliance Analyst Ahmed"
}
```

---

### 5.6 Gap Analysis Entry

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc13-gap-entry` |

#### Request Body
```json
{
  "cycle_id": 1,
  "identified_risk": "Trade-based ML exposure through free zone clients",
  "existing_control": "Annual review of trade finance portfolios",
  "gap_description": "No real-time screening of trade documents against FATF red flags",
  "proportionality_note": "Bank has PKR 50B in trade finance — higher proportional exposure",
  "severity": "HIGH | MEDIUM | LOW"
}
```

---

### 5.7 Action Plan Item

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc13-action-item` |

#### Request Body
```json
{
  "cycle_id": 1,
  "category": "BUSINESS_STRATEGY_RISK_APPETITE | POLICY_FRAMEWORK | SOP_PROCEDURE_MANUAL | EMPLOYEE_RISK_UNDERSTANDING | RESOURCE_ADEQUACY",
  "recommendation": "Update AML/CFT policy to include trade-based ML typologies",
  "target_completion_date": "2026-12-31",
  "owner": "Chief Compliance Officer"
}
```

#### Response — Validation Passed (HTTP 200)
```json
{ "status": "success", "message": "Validation passed: SBP Action Plan covers all 5 mandatory categories." }
```

#### Response — Validation Failed (HTTP 400)
```json
{ "status": "error", "message": "Validation failed: SBP Action Plan must cover all 5 mandatory categories." }
```

---

### 5.8 Pre-Review Decision

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc13-prereview-decision` |

#### Request Body
```json
{
  "cycle_id": 1,
  "reviewer_name": "Head of Compliance",
  "decision": "APPROVED_FOR_BOD | RETURNED_FOR_REVISION",
  "comments": "Approved for Board submission"
}
```

---

### 5.9 BoD Decision

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc13-bod-decision` |

#### Request Body
```json
{
  "cycle_id": 1,
  "decision": "APPROVED | RETURNED_FOR_REVISION",
  "approved_by": "Board Secretary",
  "meeting_ref": "BoD-2026-Q3-Meeting-15"
}
```

---

### 5.10 SOP Decision

| Property | Value |
|---|---|
| **Method** | `POST` |
| **Path** | `/webhook/uc13-sop-decision` |

#### Request Body
```json
{
  "action_plan_item_id": 3,
  "approved_by": "Head of Operations",
  "decision": "APPROVED | RETURNED_FOR_REVISION",
  "updated_sop_reference": "SOP-AML-2026-v2.1"
}
```

---

### 5.11 UC1 Compliance Metrics (Consumed by UC13)

| Property | Value |
|---|---|
| **Method** | `GET` |
| **Path** | `/webhook/uc1-compliance-metrics` |
| **Owner** | This endpoint is DEFINED in UC13 but serves UC1 data |

#### Response (HTTP 200)
```json
{
  "rejected_case_count": 12,
  "risk_rating_revision_count": 3,
  "ml_tf_pf_closure_count": 1
}
```

---

## 6. Node-by-Node Configuration

### Phase 1: Cycle Trigger & Data Aggregation

#### Node 1: Webhook: Event Cycle Trigger

| Property | Value |
|---|---|
| **Type** | `webhook` |
| **Method** | `POST` |
| **Path** | `uc13-cycle` |
| **Receives** | `trigger_type`, `trigger_note` |

#### Node 2: Schedule Trigger — Periodical Cadence

| Property | Value |
|---|---|
| **Type** | `scheduleTrigger` |
| **Schedule** | Quarterly (configurable) |
| **Forwards** | Default `trigger_type = 'SCHEDULED'` |

#### Node 3: Insert Cycle Record

```sql
INSERT INTO irar_cycles (cycle_ref, trigger_type, trigger_note, status)
VALUES (
  'IRAR-' || to_char(now(), 'YYYY-MM-DD') || '-' || substring(md5(random()::text) from 1 for 4),
  COALESCE('{{ $json.trigger_type || $json.body.trigger_type }}', 'SCHEDULED'),
  COALESCE('{{ $json.trigger_note || $json.body.trigger_note }}', 'Quarterly scheduled cycle'),
  'DATA_AGGREGATION'
) RETURNING *;
```

#### Node 4: Aggregate UC5 Metrics

```sql
SELECT
  (SELECT COUNT(*) FROM str_cases WHERE review_status = 'FILED') AS str_filed_count,
  (SELECT COUNT(*) FROM ctr_filings) AS ctr_filed_count,
  (SELECT COUNT(*) FROM str_cases WHERE review_status = 'CLOSED_NOT_SUSPICIOUS') AS str_closed_count,
  (SELECT COUNT(*) FROM ctr_candidates WHERE data_accuracy_status = 'CORRECTION_NEEDED') AS ctr_correction_count;
```

#### Node 5: Snap UC5 Metrics

```sql
INSERT INTO irar_internal_metrics_snapshot (cycle_id, metric_key, metric_value, source_table_ref) VALUES
  ({{ $('Insert Cycle Record').first().json.id }}, 'STR_FILED_COUNT', {{ $json.str_filed_count }}, 'uc5.str_cases'),
  ({{ $('Insert Cycle Record').first().json.id }}, 'CTR_FILED_COUNT', {{ $json.ctr_filed_count }}, 'uc5.ctr_filings'),
  ({{ $('Insert Cycle Record').first().json.id }}, 'STR_CLOSED_COUNT', {{ $json.str_closed_count }}, 'uc5.str_cases'),
  ({{ $('Insert Cycle Record').first().json.id }}, 'CTR_CORRECTION_COUNT', {{ $json.ctr_correction_count }}, 'uc5.ctr_candidates');
```

#### Node 6: Aggregate UC3 Metrics

```sql
SELECT
  (SELECT COUNT(*) FROM pep_designations WHERE is_active = TRUE) AS active_pep_count,
  (SELECT COUNT(*) FROM pep_match_candidates WHERE review_status = 'PENDING_REVIEW') AS pending_pep_review_count,
  (SELECT COUNT(*) FROM tfs_screening_results WHERE match_found = TRUE) AS tfs_match_count;
```

#### Node 7: Snap UC3 Metrics (same pattern as Node 5)

#### Node 10: Fetch UC1 Metrics (HTTP Call)

| Property | Value |
|---|---|
| **Type** | `httpRequest` |
| **Method** | `GET` |
| **URL** | `http://localhost:5678/webhook/uc1-compliance-metrics` |
| **Does** | Calls the UC1 compliance metrics endpoint defined in Nodes 46–48 |

#### Node 11: Insert UC1 Metrics Snapshot

```sql
INSERT INTO irar_rejected_case_inputs (cycle_id, rejected_case_count, risk_rating_revision_count, ml_tf_pf_closure_count)
VALUES (
  {{ $('Insert Cycle Record').first().json.id }},
  {{ $json.rejected_case_count }},
  {{ $json.risk_rating_revision_count }},
  {{ $json.ml_tf_pf_closure_count }}
);
```

---

### Phase 2: LLM Drafting

#### Node 14: Set Status DRAFTING

```sql
UPDATE irar_cycles SET status = 'DRAFTING' WHERE id = {{ $json.body.cycle_id }} RETURNING *;
```

#### Node 16: Get Aggregated Context

```sql
SELECT
  c.cycle_ref,
  json_agg(DISTINCT jsonb_build_object('key', m.metric_key, 'value', m.metric_value)) AS metrics,
  json_agg(DISTINCT jsonb_build_object('type', e.input_type, 'desc', e.description, 'source', e.source_attribution)) AS externals,
  json_agg(DISTINCT jsonb_build_object('risk', g.identified_risk, 'gap', g.gap_description)) AS gaps
FROM irar_cycles c
LEFT JOIN irar_internal_metrics_snapshot m ON c.id = m.cycle_id
LEFT JOIN irar_external_inputs e ON c.id = e.cycle_id
LEFT JOIN irar_gap_analysis g ON c.id = g.cycle_id
WHERE c.id = {{ $json.body.cycle_id }}
GROUP BY c.cycle_ref;
```

#### Node 17: LLM Narrative Draft (Groq Completion) — KEY NODE

| Property | Value |
|---|---|
| **Type** | `httpRequest` |
| **Method** | `POST` |
| **URL** | `https://api.groq.com/openai/v1/chat/completions` |
| **Model** | `llama-3.3-70b-versatile` |
| **Headers** | `Authorization: Bearer {{ $credentials.groqApi }}` |

**System Prompt (summary):**
> You are a compliance risk officer drafting an Internal Risk Assessment Report (IRAR) section for a bank regulated by the State Bank of Pakistan. You will be given aggregated compliance metrics and must produce a structured risk narrative for a specific risk dimension. Output as JSON with fields: risk_dimension, narrative_text, key_findings[], recommendations[].

**User Prompt:** Includes the aggregated metrics from Node 16 and the `risk_dimension` from the webhook body.

**Response Format:** JSON forced via `response_format: { type: "json_object" }`

#### Node 18: Insert LLM Draft Narrative

```sql
INSERT INTO irar_risk_narrative (cycle_id, risk_dimension, llm_draft_text)
VALUES (
  {{ $json.body.cycle_id }},
  '{{ $json.body.risk_dimension }}',
  '{{ $json.choices[0].message.content }}'
) RETURNING *;
```

---

### Phase 3: Action Plan Validation

#### Node 25: Check Action Plan Categories

```sql
SELECT
  COUNT(CASE WHEN category = 'BUSINESS_STRATEGY_RISK_APPETITE' THEN 1 END) as strat_count,
  COUNT(CASE WHEN category = 'POLICY_FRAMEWORK' THEN 1 END) as policy_count,
  COUNT(CASE WHEN category = 'SOP_PROCEDURE_MANUAL' THEN 1 END) as sop_count,
  COUNT(CASE WHEN category = 'EMPLOYEE_RISK_UNDERSTANDING' THEN 1 END) as train_count,
  COUNT(CASE WHEN category = 'RESOURCE_ADEQUACY' THEN 1 END) as res_count
FROM irar_action_plan_items
WHERE cycle_id = {{ $json.cycle_id }};
```

#### Node 26: IF: Enforce SBP Categories?

| Property | Value |
|---|---|
| **Type** | `if` |
| **Conditions (ALL must be true)** | `strat_count > 0` AND `policy_count > 0` AND `sop_count > 0` AND `train_count > 0` AND `res_count > 0` |
| **Output 0 (True)** | → Node 38: Respond: Validation Passed (200) |
| **Output 1 (False)** | → Node 39: Respond: Validation Failed (400) |

---

### Phase 4: Approval Chain

#### Node 31: Insert Pre-Review Log

```sql
INSERT INTO irar_senior_mgmt_prereview (cycle_id, reviewer_name, decision, comments)
VALUES (
  {{ $json.body.cycle_id }},
  '{{ $json.body.reviewer_name }}',
  '{{ $json.body.decision }}',
  '{{ $json.body.comments }}'
) RETURNING *;
```

#### Node 32: IF: Pre-Review Approved?

| Condition | `{{ $json.decision }}` equals `APPROVED_FOR_BOD` |
|---|---|
| **True** | → Node 40: Set Status BOD_APPROVAL |
| **False** | → Node 41: Set Status DRAFTING (revision loop) |

#### Node 34: Insert BoD Log

```sql
INSERT INTO irar_bod_approval (cycle_id, decision, approved_by, meeting_ref)
VALUES (
  {{ $json.body.cycle_id }},
  '{{ $json.body.decision }}',
  '{{ $json.body.approved_by }}',
  '{{ $json.body.meeting_ref }}'
) RETURNING *;
```

#### Node 37: Insert SOP Approval Log

```sql
INSERT INTO irar_sop_approval (action_plan_item_id, approved_by, decision, updated_sop_reference)
VALUES (
  {{ $json.body.action_plan_item_id }},
  '{{ $json.body.approved_by }}',
  '{{ $json.body.decision }}',
  '{{ $json.body.updated_sop_reference }}'
) RETURNING *;
```

#### Node 44: Archive Cycle

```sql
UPDATE irar_cycles
SET status = 'ARCHIVED', closed_at = now()
WHERE id = (
  SELECT cycle_id FROM irar_action_plan_items WHERE id = {{ $json.action_plan_item_id }}
) RETURNING *;
```

#### Node 45: Save Archive Log

```sql
INSERT INTO irar_archive (cycle_id, final_document_ref, bod_deck_ref, retention_until, available_for_sbp_inspection)
VALUES (
  {{ $json.id }},
  'http://localhost:9000/archives/' || '{{ $json.cycle_ref }}' || '-FINAL.pdf',
  'http://localhost:9000/archives/' || '{{ $json.cycle_ref }}' || '-DECK.pdf',
  now()::date + interval '10 years',
  true
) RETURNING *;
```

---

### UC1 Metrics Endpoint (Nodes 46–48)

#### Node 47: Query Metrics

```sql
SELECT
  (SELECT COUNT(*) FROM cdd_cases WHERE status = 'REJECTED') as rejected_case_count,
  (SELECT COUNT(*) FROM approvals WHERE decision = 'RETURNED_FOR_INFO') as risk_rating_revision_count,
  (SELECT COUNT(*) FROM accounts WHERE status = 'CLOSED') as ml_tf_pf_closure_count;
```

---

## 7. Error Handling & Edge Cases

| Error Condition | Handled By | HTTP | Outcome |
|---|---|---|---|
| Action plan missing SBP categories | Node 26 validation gate | `400` | Blocks progression until all 5 categories are covered |
| Pre-review returns for revision | Node 32 routes to DRAFTING status | N/A | Cycle loops back for analyst revision |
| BoD returns for revision | Node 35 routes to DRAFTING status | N/A | Cycle loops back to pre-review stage |
| Groq API key invalid | LLM call returns 401 error | N/A | Workflow error — requires API key configuration |
| UC1 metrics endpoint unreachable | HTTP request node fails | N/A | Workflow error — UC1 workflow must be active |
| Missing external input attribution | DB CHECK constraint enforces `source_attribution NOT NULL` | N/A | Insert fails at database level |

### Revision Loop Design

If either Senior Management Pre-Review or BoD returns the document for revision, the cycle status is reset to `DRAFTING`. This allows the compliance team to re-enter the drafting phase, revise narratives, update gap analysis, and re-submit through the approval chain without creating a new cycle.

---

## 8. Security & Access Control

### 8.1 Credential Management
| Credential | Type | Usage |
|---|---|---|
| `AML Postgres` | PostgreSQL | All database operations |
| `AML SMTP` | SMTP/Gmail | Pre-review alert emails |
| `Groq API` | HTTP Bearer Token | LLM narrative generation (Llama 3.3 70B) |

### 8.2 LLM Security
- **Output format:** `response_format: { type: "json_object" }` forces structured JSON output (prevents freeform text injection)
- **Human-in-the-loop:** LLM output is stored in `llm_draft_text`; final text goes to `human_edited_text` only after analyst review via Node 20
- **No auto-submission:** LLM drafts never flow directly to approval — analyst must explicitly edit and submit

### 8.3 Approval Integrity
- `irar_bod_approval.decision` has a CHECK constraint: `'APPROVED' or 'RETURNED_FOR_REVISION'`
- `irar_sop_approval` is a **separate** approval from BoD — SOP text must be independently approved by Senior Management per Reg 1 §12
- All decisions are recorded with `decided_at` timestamps and actor names

---

## 9. Automated Test Scenarios & Verification

Test scripts: `tests/uc13_governance/test_uc13_governance.sh`

| # | Payload | Scenario | Expected Path |
|---|---|---|---|
| 1 | `01_scheduled_complete_path.json` | Full quarterly cycle: trigger → aggregate → draft → gap → action plan → pre-review → BoD → SOP → archive | Complete lifecycle through all 6 status transitions |
| 2 | `02_event_nra_update.json` | Event-triggered cycle from NRA update | Cycle created with `EVENT_NRA_UPDATE` trigger |
| 3 | `03_missing_action_plan_category.json` | Action plan missing RESOURCE_ADEQUACY | Validation fails at Node 26 (HTTP 400) |
| 4 | `04_prereview_revision.json` | Senior management returns for revision | Cycle status resets to DRAFTING |
| 5 | `05_bod_rejection.json` | Board returns for revision | Cycle status resets to DRAFTING |

### Running Tests

```bash
cd tests/uc13_governance
./test_uc13_governance.sh payloads/01_scheduled_complete_path.json
```

---

## 10. Cross-UC Integration

### 10.1 Inbound Dependencies — Data Aggregation

UC13 is the **consumer of all other UCs**. It aggregates metrics from across the entire compliance platform:

| Source UC | Data Consumed | Mechanism | Node |
|---|---|---|---|
| **UC1** | Rejected case count, risk rating revisions, ML/TF/PF closures | HTTP GET to `/webhook/uc1-compliance-metrics` | Node 10 |
| **UC3** | Active PEP designations, pending reviews, TFS matches | Direct SQL query on UC3 tables | Node 6 |
| **UC5** | STR filed count, CTR filed count, STR closures | Direct SQL query on UC5 tables | Node 4 |

### 10.2 Outbound Dependencies

| Target UC | What UC13 Provides | Mechanism |
|---|---|---|
| None | UC13 is the terminal governance layer — it consumes but does not produce data for other UCs | — |

### 10.3 Integration Architecture

```
UC1 (Onboarding) ──── HTTP GET ────► UC13 (Governance)
UC3 (PEP Lifecycle) ── SQL Direct ──► UC13 (Governance)
UC5 (STR/CTR) ──────── SQL Direct ──► UC13 (Governance)
UC8 (Wire Transfers) ── (via UC5) ──► UC13 (Governance)
```

> **Design Note:** UC13 uses HTTP for UC1 metrics (demonstrating cross-workflow API integration) but direct SQL for UC3/UC5 metrics (demonstrating shared-database integration). Both patterns are valid in n8n architectures.

### 10.4 Shared Database Tables

| Table | Owner | Read By UC13 |
|---|---|---|
| `str_cases` | UC5 | Node 4 aggregates STR counts |
| `ctr_filings` | UC5 | Node 4 aggregates CTR counts |
| `ctr_candidates` | UC5 | Node 4 counts correction-needed |
| `pep_designations` | UC3 | Node 6 counts active designations |
| `pep_match_candidates` | UC3 | Node 6 counts pending reviews |
| `tfs_screening_results` | UC1 | Node 6 counts TFS matches |
| `cdd_cases` | UC1 | Node 47 counts rejections |
| `approvals` | UC1 | Node 47 counts revisions |
| `accounts` | UC1 | Node 47 counts closures |
