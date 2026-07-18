# UC13: IRAR Auto-Generation & Board Governance — n8n Step-by-Step Build Guide

> **Written for compliance engineers and n8n builders.** Every click, every node, and every setting is documented step-by-step to build the board-level governance pipeline on the n8n canvas.

---

## Part 0: Prerequisites

### 0.1 Database Migration Setup
Before building, ensure the database schema migrations have been applied:
* **[009_uc13_schema.sql](file:///mnt/c/Important/Git_Folder/genos-poc-v2/db/init/009_uc13_schema.sql):** Defines the IRAR cycles, narratives, action items, approvals, and archive tables.
* **[010_uc13_seed.sql](file:///mnt/c/Important/Git_Folder/genos-poc-v2/db/init/010_uc13_seed.sql):** Seeds default historical cycles, SBP NRA inputs, and mock staff risk snapshots.

### 0.2 Open n8n
1. Open your browser → go to **http://localhost:5678**
2. Click **"Create Workflow"** → rename it to `UC13 - IRAR & Board Governance`

### 0.3 Postgres Connection
Every database node in this workflow reuses the **AML Postgres** credential:

| Field | Value |
|---|---|
| **Host** | `aml-postgres` |
| **Database** | `aml_local` |
| **User** | `aml_user` |
| **Password** | `aml_password` |
| **Port** | `5432` |
| **SSL** | `disable` |

### 0.4 SMTP Connection
For email alerts, reuse the **AML SMTP** credential:

| Field | Value |
|---|---|
| **Host** | `smtp.gmail.com` |
| **Port** | `465` |
| **SSL/TLS** | *Tick to Enable (SSL)* |
| **User** | `shazanali3210@gmail.com` |
| **Password** | `fuut kokl lprz yjix` *(Gmail App Password)* |

---

## Part 1: Workflow Architecture

This solution is built as a single n8n workflow containing **five independent entry points (flows)** on a single canvas:

### Flow A: Cycle Trigger & Data Aggregation
```
Flow A1: Automated Intake Track
Schedule / Event Triggers ──► [Insert Cycle] ──► [Agg UC5 Metrics] ──► [Snap UC5] ──► [Agg UC3 Metrics] ──► [Snap UC3] ──► [Fetch UC1] ──► [Insert UC1 Snap] ──► [Start Drafting Phase]

Flow A2: Independent External Inputs
[Webhook: Enter External Inputs] ──► [Insert External Inputs]

Flow A3: Independent Staff Risk Input
[Webhook: Enter Staff Risk Snapshot] ──► [Insert Staff Snapshot]
```
Allows independent, role-based manual entries to mimic real-life banking operations (e.g. HR uploading training metrics on their own timeline, while compliance notes external SBP NRA updates as they are published).

### Flow B: LLM-Assisted Risk Narrative
```
[Webhook: Start Drafting] ──► [Get Aggregated Context] ──► [LLM Mock Draft] ──► [Insert LLM Narratives]
                                                                                    
[Webhook: Analyst Edit] ──► [Update Narrative Text]
```
Gathers cycle metrics, feeds context into a mock LLM prompt to draft risk narratives across 8 SBP dimensions (including Transnational TF and Emerging Risks), and saves analyst edits.

### Flow C: Gap Analysis & Action Plan
```
[Webhook: Enter Gaps] ──► [Insert Gap Record]
                                                                                    
[Webhook: Action Item] ──► [Insert Action Item] ──► [Check Categories] ──► [IF: Enforce Categories?]
                                                                                ├── Yes ──► [Respond: Validation Passed]
                                                                                └── No  ──► [Respond: Validation Failed]
```
Logs gaps with proportionality arguments, inputs action plan recommendations, enforces that the plan covers all 5 mandatory SBP categories, and returns an HTTP status response to the analyst.

### Flow D: Two-Tier Governance Approvals
```
[Webhook: Pre-Review] ──► [Set Status Pre-Review] ──► [Send Pre-Review Email]
                                                                                    
[Webhook: Prereview Decision] ──► [Insert Pre-Review Log] ──► [IF: Pre-Review Approved?]
                                                                       ├── Yes ──► [Set Status BoD Review]
                                                                       └── No  ──► [Set Status Revision (Pre-Review)]

[Webhook: BoD Approval] ──► [Insert BoD Log] ──► [IF: BoD Approved?]
                                                           ├── Yes ──► [Set Status SOP Approval]
                                                           └── No  ──► [Set Status Revision (BoD)]

[Webhook: SOP Approval] ──► [Insert SOP Log] ──► [Archive Cycle] ──► [Save Archive Log]
```
Routes the IRAR draft to senior management for pre-review, updates database cycle status, triggers a non-delegable BoD vote (Tier 1), logs the Board decision, collects individual senior management SOP approvals (Tier 2), and archives the cycle with a calculated 10-year retention date.

### Flow E: UC1 Compliance Metrics Endpoint
```
[Webhook: UC1 Metrics] ──► [Query Metrics] ──► [Respond: Metrics]
```
Exposes a read-only endpoint that queries the database to return metrics of rejected onboarding cases, challenged risk ratings, and closed customer relationships.

---

## Part 2: Build It — Node by Node

---

## FLOW A: Cycle Trigger & Data Aggregation

---

### Node 1: Webhook: Event Cycle Trigger

Exposes the webhook to initiate the governance cycle based on ad-hoc external events.

1. Add a **Webhook** node to the canvas.
2. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc13-event-trigger`
   - **Response Mode:** `When Last Node Finishes`
3. Rename to **`Webhook: Event Cycle Trigger`**

---

### Node 2: Schedule Trigger: Periodical Cadence

Fires the IRAR compilation cycle automatically on a quarterly cadence.

1. Add a **Schedule Trigger** node to the canvas.
2. Set the following:
   - **Trigger Interval:** `Months`
   - **Months Between Triggers:** `3`
   - **Trigger at Day of Month:** `1`
   - **Trigger at Hour:** `1`
3. Rename to **`Schedule Trigger: Periodical Cadence`**

---

### Node 3: Insert Cycle Record

Creates the active IRAR cycle in the database.

1. Add a **Postgres** node to the canvas.
2. Connect both **Webhook: Event Cycle Trigger** and **Schedule Trigger: Periodical Cadence** outputs to this node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     INSERT INTO irar_cycles (cycle_ref, trigger_type, trigger_note, status)
     VALUES (
       'IRAR-' || to_char(now(), 'YYYY-MM-DD') || '-' || substring(md5(random()::text) from 1 for 4),
       COALESCE('{{ $json.body.trigger_type }}', 'SCHEDULED'),
       COALESCE('{{ $json.body.trigger_note }}', 'Scheduled quarterly assessment execution.'),
       'DATA_AGGREGATION'
     ) RETURNING *;
     ```
4. Rename to **`Insert Cycle Record`**

---

### Node 4: Aggregate UC5 Metrics

Queries the suspicious transaction logs for aggregate statistics.

1. Click the **+** on the right side of **Insert Cycle Record**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     SELECT 
       (SELECT COUNT(*) FROM str_filings) as str_filed_count,
       (SELECT COUNT(*) FROM ctr_filings) as ctr_filed_count;
     ```
4. Rename to **`Aggregate UC5 Metrics`**

---

### Node 5: Snap UC5 Metrics

Inserts the snapshot metrics for this cycle.

1. Click the **+** on the right side of **Aggregate UC5 Metrics**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     INSERT INTO irar_internal_metrics_snapshot (cycle_id, metric_key, metric_value, source_table_ref)
     VALUES 
       ({{ $('Insert Cycle Record').first().json.id }}, 'STR_FILED_COUNT', {{ $json.str_filed_count }}, 'uc5.str_filings'),
       ({{ $('Insert Cycle Record').first().json.id }}, 'CONTAINER_CTR_FILED_COUNT', {{ $json.ctr_filed_count }}, 'uc5.ctr_filings')
     RETURNING *;
     ```
4. Rename to **`Snap UC5 Metrics`**

---

### Node 6: Aggregate UC3 Metrics

Queries the watchlist and fuzzy matches database.

1. Click the **+** on the right side of **Snap UC5 Metrics**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     SELECT 
       (SELECT COUNT(*) FROM pep_designations WHERE is_active = true) as pep_designation_count,
       (SELECT COUNT(*) FROM tfs_screening_results WHERE match_found = true) as tfs_match_count;
     ```
4. Rename to **`Aggregate UC3 Metrics`**

---

### Node 7: Snap UC3 Metrics

Inserts the UC3 PEP snapshots.

1. Click the **+** on the right side of **Aggregate UC3 Metrics**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     INSERT INTO irar_internal_metrics_snapshot (cycle_id, metric_key, metric_value, source_table_ref)
     VALUES 
       ({{ $('Insert Cycle Record').first().json.id }}, 'PEP_DESIGNATION_COUNT', {{ $json.pep_designation_count }}, 'uc3.pep_designations'),
       ({{ $('Insert Cycle Record').first().json.id }}, 'TFS_MATCH_COUNT', {{ $json.tfs_match_count }}, 'uc3.tfs_screening_results')
     RETURNING *;
     ```
4. Rename to **`Snap UC3 Metrics`**

---

### Node 8: Webhook: Enter External Inputs

Form entry for manual SBP/NRA inputs (Compliance Officer role-based entry point).

1. Add a **Webhook** node to the canvas.
2. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc13-external-inputs`
   - **Response Mode:** `When Last Node Finishes`
3. Rename to **`Webhook: Enter External Inputs`**

---

### Node 9: Insert External Inputs

Records manual SBP NRA circular inputs.

1. Click the **+** on the right side of **Webhook: Enter External Inputs**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     INSERT INTO irar_external_inputs (cycle_id, input_type, description, source_attribution, entered_by)
     VALUES (
       {{ $json.body.cycle_id }},
       '{{ $json.body.input_type }}',
       '{{ $json.body.description }}',
       '{{ $json.body.source_attribution }}',
       '{{ $json.body.entered_by }}'
     ) RETURNING *;
     ```
4. Rename to **`Insert External Inputs`**

---

### Node 10: Fetch UC1 Metrics

Retrieves live metrics of rejected/challenged customer cases from the UC1 metrics endpoint.

1. Click the **+** on the right side of **Snap UC3 Metrics**.
2. Add an **HTTP Request** node.
3. Configure settings:
   - **Method:** `GET`
   - **URL:** `http://localhost:5678/webhook/uc1-compliance-metrics`
4. Rename to **`Fetch UC1 Metrics`**

---

### Node 11: Insert UC1 Metrics Snapshot

Writes the aggregated UC1 counts into local cycle metrics.

1. Click the **+** on the right side of **Fetch UC1 Metrics**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     INSERT INTO irar_rejected_case_inputs (cycle_id, rejected_case_count, risk_rating_revision_count, ml_tf_pf_closure_count)
     VALUES (
       {{ $('Insert Cycle Record').first().json.id }},
       {{ $json.rejected_case_count }},
       {{ $json.risk_rating_revision_count }},
       {{ $json.ml_tf_pf_closure_count }}
     ) RETURNING *;
     ```
4. Rename to **`Insert UC1 Metrics Snapshot`**

---

### Node 12: Webhook: Enter Staff Risk Snapshot

Captures HR employee training rates and F&PT non-compliance (HR role-based entry point).

1. Add a **Webhook** node to the canvas.
2. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc13-staff-risk`
   - **Response Mode:** `When Last Node Finishes`
3. Rename to **`Webhook: Enter Staff Risk Snapshot`**

---

### Node 13: Insert Staff Snapshot

Writes HR metrics into the database.

1. Click the **+** on the right side of **Webhook: Enter Staff Risk Snapshot**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     INSERT INTO irar_employee_risk_snapshot (cycle_id, training_completion_rate, fpt_noncompliance_count, screening_flags_count)
     VALUES (
       {{ $json.body.cycle_id }},
       {{ $json.body.training_completion_rate }},
       {{ $json.body.fpt_noncompliance_count }},
       {{ $json.body.screening_flags_count }}
     ) RETURNING *;
     ```
4. Rename to **`Insert Staff Snapshot`**

---

### Node 14: Start Drafting Phase

Updates the cycle status to DRAFTING.

1. Click the **+** on the right side of **Insert UC1 Metrics Snapshot**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     UPDATE irar_cycles
     SET status = 'DRAFTING'
     WHERE id = {{ $('Insert Cycle Record').first().json.id }}
     RETURNING *;
     ```
4. Rename to **`Start Drafting Phase`**

---

## FLOW B: LLM-Assisted Risk Narrative

---

### Node 15: Webhook: Start Drafting

Analytical webhook to initiate narrative generation.

1. Add a **Webhook** node to the canvas.
2. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc13-draft-start`
   - **Response Mode:** `When Last Node Finishes`
3. Rename to **`Webhook: Start Drafting`**

---

### Node 16: Get Aggregated Context

Gathers compiled cycle metadata for the LLM prompt.

1. Click the **+** on the right side of **Webhook: Start Drafting**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     SELECT 
       c.id,
       c.cycle_ref,
       COALESCE((SELECT json_agg(m) FROM irar_internal_metrics_snapshot m WHERE m.cycle_id = c.id), '[]'::json) as internal_metrics,
       COALESCE((SELECT json_agg(e) FROM irar_external_inputs e WHERE e.cycle_id = c.id), '[]'::json) as external_inputs,
       COALESCE((SELECT json_agg(r) FROM irar_rejected_case_inputs r WHERE r.cycle_id = c.id), '[]'::json) as rejected_metrics,
       COALESCE((SELECT json_agg(s) FROM irar_employee_risk_snapshot s WHERE s.cycle_id = c.id), '[]'::json) as staff_metrics
     FROM irar_cycles c
     WHERE c.id = {{ $json.body.cycle_id }};
     ```
4. Rename to **`Get Aggregated Context`**

---

### Node 17: LLM Narrative Draft (Groq Completion)

Executes a live call to the Groq completion API to generate risk narratives based on the cycle metrics.

1. Click the **+** on the right side of **Get Aggregated Context**.
2. Add an **HTTP Request** node.
3. Configure settings:
   - **Method:** `POST`
   - **URL:** `https://api.groq.com/openai/v1/chat/completions`
   - **Authentication:** `Header Auth` (Create/select a credential named `Groq API Header` with Name: `Authorization` and Value: `Bearer <your_groq_api_key_from_env>`)
   - **Body Parameters:** Switch the Body parameter mode from **Fixed** to **Expression** (by clicking the **Expression** tab at the top-right of the body input box) and paste the following JavaScript object expression:
     ```javascript
     {{
     {
       "model": "llama-3.3-70b-versatile",
       "messages": [
         {
           "role": "system",
           "content": "You are a professional bank AML/CFT compliance analyst. You compile the entity-level Internal Risk Assessment Report (IRAR) for SBP compliance.\n\nYou will be given the cycle context including internal metrics, external inputs, onboarding metrics, and employee metrics.\n\nGenerate draft narratives for the following 8 SBP dimensions:\n1. CUSTOMERS\n2. PRODUCTS\n3. SERVICES\n4. DELIVERY_CHANNELS\n5. TECHNOLOGIES\n6. EMPLOYEE_CATEGORIES\n7. TRANSNATIONAL_TF\n8. EMERGING_RISKS\n\nYou MUST return a JSON object with the exact keys: 'CUSTOMERS', 'PRODUCTS', 'SERVICES', 'DELIVERY_CHANNELS', 'TECHNOLOGIES', 'EMPLOYEE_CATEGORIES', 'TRANSNATIONAL_TF', 'EMERGING_RISKS'. The values must be the draft narrative paragraphs (2-3 sentences each) summarizing the risks based on the context.\nReturn ONLY the JSON object. Do not include markdown code block formatting or conversational text."
         },
         {
           "role": "user",
           "content": `Cycle Reference: ${$json.cycle_ref || ''}
     Internal Metrics: ${JSON.stringify($json.internal_metrics || [])}
     External SBP Inputs: ${JSON.stringify($json.external_inputs || [])}
     Rejected Cases (UC1): ${JSON.stringify($json.rejected_metrics || [])}
     HR Employee Snapshot: ${JSON.stringify($json.staff_metrics || [])}`
         }
       ],
       "response_format": { "type": "json_object" }
     }
     }}
     ```
4. Rename to **`LLM Narrative Draft (Groq Completion)`**

---

### Node 18: Insert LLM Draft Narrative

Parses the JSON response from Groq and inserts the draft text into the database with single-quote escaping.

1. Click the **+** on the right side of **LLM Narrative Draft (Groq Completion)**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     INSERT INTO irar_risk_narrative (cycle_id, risk_dimension, llm_draft_text)
     VALUES 
       ({{ $('Get Aggregated Context').first().json.id }}, 'CUSTOMERS', '{{ JSON.parse($json.choices[0].message.content).CUSTOMERS.replace(/'/g, "''") }}'),
       ({{ $('Get Aggregated Context').first().json.id }}, 'PRODUCTS', '{{ JSON.parse($json.choices[0].message.content).PRODUCTS.replace(/'/g, "''") }}'),
       ({{ $('Get Aggregated Context').first().json.id }}, 'SERVICES', '{{ JSON.parse($json.choices[0].message.content).SERVICES.replace(/'/g, "''") }}'),
       ({{ $('Get Aggregated Context').first().json.id }}, 'DELIVERY_CHANNELS', '{{ JSON.parse($json.choices[0].message.content).DELIVERY_CHANNELS.replace(/'/g, "''") }}'),
       ({{ $('Get Aggregated Context').first().json.id }}, 'TECHNOLOGIES', '{{ JSON.parse($json.choices[0].message.content).TECHNOLOGIES.replace(/'/g, "''") }}'),
       ({{ $('Get Aggregated Context').first().json.id }}, 'EMPLOYEE_CATEGORIES', '{{ JSON.parse($json.choices[0].message.content).EMPLOYEE_CATEGORIES.replace(/'/g, "''") }}'),
       ({{ $('Get Aggregated Context').first().json.id }}, 'TRANSNATIONAL_TF', '{{ JSON.parse($json.choices[0].message.content).TRANSNATIONAL_TF.replace(/'/g, "''") }}'),
       ({{ $('Get Aggregated Context').first().json.id }}, 'EMERGING_RISKS', '{{ JSON.parse($json.choices[0].message.content).EMERGING_RISKS.replace(/'/g, "''") }}')
     RETURNING *;
     ```
4. Rename to **`Insert LLM Draft Narrative`**

---

### Node 19: Webhook: Analyst Narrative Edit

Captures analyst adjustments to risk narratives.

1. Add a **Webhook** node to the canvas.
2. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc13-analyst-edit`
   - **Response Mode:** `When Last Node Finishes`
3. Rename to **`Webhook: Analyst Narrative Edit`**

---

### Node 20: Update Narrative Text

Saves revised narrative entries.

1. Click the **+** on the right side of **Webhook: Analyst Narrative Edit**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     UPDATE irar_risk_narrative
     SET human_edited_text = '{{ $json.body.edited_text }}',
         edited_by = '{{ $json.body.edited_by }}',
         edited_at = now()
     WHERE cycle_id = {{ $json.body.cycle_id }} AND risk_dimension = '{{ $json.body.risk_dimension }}'
     RETURNING *;
     ```
4. Rename to **`Update Narrative Text`**

---

## FLOW C: Gap Analysis & Action Plan

---

### Node 21: Webhook: Enter Gap Analysis

Analyst form to enter identified gaps and proportionality.

1. Add a **Webhook** node to the canvas.
2. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc13-gap-analysis`
   - **Response Mode:** `When Last Node Finishes`
3. Rename to **`Webhook: Enter Gap Analysis`**

---

### Node 22: Insert Gap Record

Inserts gaps along with mandatory proportionality rationale.

1. Click the **+** on the right side of **Webhook: Enter Gap Analysis**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     INSERT INTO irar_gap_analysis (cycle_id, identified_risk, existing_control, gap_description, proportionality_note, severity)
     VALUES (
       {{ $json.body.cycle_id }},
       '{{ $json.body.identified_risk }}',
       '{{ $json.body.existing_control }}',
       '{{ $json.body.gap_description }}',
       '{{ $json.body.proportionality_note }}',
       '{{ $json.body.severity }}'
     ) RETURNING *;
     ```
4. Rename to **`Insert Gap Record`**

---

### Node 23: Webhook: Enter Action Recommendations

Form to enter action plan items.

1. Add a **Webhook** node to the canvas.
2. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc13-action-item`
   - **Response Mode:** `Response to Webhook node`
3. Rename to **`Webhook: Enter Action Recommendations`**

---

### Node 24: Insert Action Plan Item

Inserts action items categorized into SBP buckets.

1. Click the **+** on the right side of **Webhook: Enter Action Recommendations**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     INSERT INTO irar_action_plan_items (cycle_id, category, recommendation, target_completion_date, owner)
     VALUES (
       {{ $json.body.cycle_id }},
       '{{ $json.body.category }}',
       '{{ $json.body.recommendation }}',
       '{{ $json.body.target_completion_date }}',
       '{{ $json.body.owner }}'
     ) RETURNING *;
     ```
4. Rename to **`Insert Action Plan Item`**

---

### Node 25: Check Action Plan Categories

Aggregates counts across the 5 mandatory compliance categories.

1. Click the **+** on the right side of **Insert Action Plan Item**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
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
4. Rename to **`Check Action Plan Categories`**

---

## Part 3: Pre-Flight Checks (Subsequent Nodes Unchanged)
