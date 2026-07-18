# PRD: UC13 — IRAR Auto-Generation & BoD Governance Workflow (POC)
**GenosAI AML/CFT/CPF Compliance Automation — Final Year Project**
**Target build tool:** Google Antigravity IDE
**Stack:** n8n (Docker) + PostgreSQL (Docker)
**Status:** v1 — Phase 1 (POC) scope (Updated for full SBP Regulation 1 & 13 alignment)

---

## 1. Objective

Build a dual-triggered (scheduled + event-based) IRAR compilation workflow that aggregates internal operational data AND externally-sourced inputs (NRA, incident intelligence, regulator feedback), drafts a structured risk narrative and action plan with five explicit recommendation categories, and routes through a two-tier approval chain (senior management pre-review → BoD approval of the IRAR → separate senior management approval of resulting SOP/procedure updates).

## 2. Scope

### 2.1 In scope
- Scheduled and event-triggered IRAR cycle initiation.
- Data aggregation from UC3 (PEP counts) and UC5 (STR/CTR volumes) tables — reused, not duplicated.
- Manual, source-attributed entry for NRA updates, external incident intelligence, and SBP/FMU/LEA feedback (no automated feed exists for these).
- Employee-category risk data (training completion + F&PT status fields, seeded manually for POC).
- LLM-assisted (human-editable) narrative and gap-analysis drafting.
- Structured action plan with the five required recommendation categories.
- Two-tier approval: senior management pre-review, BoD approval, and separate senior management approval of resulting SOP/procedure text.
- Archival with retrieval-on-demand.
- Fetching live CDD metrics from UC1's `/webhook/uc1-compliance-metrics` endpoint (implementing SBP Regulation 13 §3 metrics integration).

### 2.2 Explicitly NOT built (documented as a recommendation only)
- Bidirectional feedback of IRAR risk-tier findings back into UC1's `risk_profile.scoring_factors` — documented as a future recommendation only, not built.
- Real external NRA/incident-intelligence data feeds — POC uses manual entry with mandatory source attribution instead.

---

## 3. Actors

| Actor | Role |
|---|---|
| Compliance Analyst | Initiates cycle, enters manual external inputs, reviews LLM-drafted narrative |
| Senior Management | Pre-reviews draft IRAR before BoD; separately approves resulting SOP/procedure updates |
| Board of Directors (BoD) | Approves the IRAR document itself — mandatory, non-delegable |
| System (n8n) | Orchestrates aggregation, drafting, and the two-tier approval sequence |

---

## 4. Database Schema (PostgreSQL)

```sql
-- ============================================
-- CYCLE / TRIGGER
-- ============================================

CREATE TABLE irar_cycles (
    id SERIAL PRIMARY KEY,
    cycle_ref VARCHAR(30) UNIQUE NOT NULL,       -- e.g. IRAR-2026-Q3
    trigger_type VARCHAR(20) NOT NULL,           -- 'SCHEDULED','EVENT_NRA_UPDATE','EVENT_EMERGING_THREAT','EVENT_REGULATOR_FEEDBACK'
    trigger_note TEXT,
    status VARCHAR(25) NOT NULL DEFAULT 'DATA_AGGREGATION',
    -- DATA_AGGREGATION, DRAFTING, SENIOR_MGMT_PREREVIEW, BOD_APPROVAL, SOP_APPROVAL, ARCHIVED
    opened_at TIMESTAMP NOT NULL DEFAULT now(),
    closed_at TIMESTAMP
);

-- ============================================
-- DATA AGGREGATION INPUTS
-- ============================================

-- Internal metrics — pulled by reference from UC3/UC5 tables, not duplicated wholesale.
CREATE TABLE irar_internal_metrics_snapshot (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES irar_cycles(id),
    metric_key VARCHAR(50) NOT NULL,             -- 'STR_FILED_COUNT','CTR_FILED_COUNT','PEP_DESIGNATION_COUNT',
                                                   -- 'TFS_MATCH_COUNT','AUDIT_FINDINGS_COUNT'
    metric_value NUMERIC,
    source_table_ref VARCHAR(100),                -- e.g. 'uc5.str_filings', 'uc3.pep_designations' — for traceability
    snapshot_at TIMESTAMP NOT NULL DEFAULT now()
);

-- External inputs that have NO automated feed — mandatory manual, source-attributed entry.
CREATE TABLE irar_external_inputs (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES irar_cycles(id),
    input_type VARCHAR(30) NOT NULL,              -- 'NRA_UPDATE','MAJOR_INCIDENT_INTELLIGENCE','REGULATOR_FEEDBACK'
    description TEXT NOT NULL,
    source_attribution VARCHAR(200) NOT NULL,      -- mandatory: e.g. 'SBP NRA 2025 Update', 'FMU circular ref X', 'SBP inspection finding ref Y'
    relevance_note TEXT,
    entered_by VARCHAR(100) NOT NULL,
    entered_at TIMESTAMP NOT NULL DEFAULT now()
);

-- Reg 13 §3 data — now sourced live from UC1 via HTTP call (see n8n Phase 1, step 6), not a permanent placeholder.
CREATE TABLE irar_rejected_case_inputs (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES irar_cycles(id),
    rejected_case_count INT,
    risk_rating_revision_count INT,
    ml_tf_pf_closure_count INT,
    source_endpoint VARCHAR(200) DEFAULT 'UC1 /webhook/uc1-compliance-metrics',
    fetched_at TIMESTAMP NOT NULL DEFAULT now()
);

-- Employee-category risk data (simplified proxy for POC)
CREATE TABLE irar_employee_risk_snapshot (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES irar_cycles(id),
    training_completion_rate NUMERIC(5,2),         -- % of relevant staff with current AML/CFT/CPF training
    fpt_noncompliance_count INT,                    -- staff flagged against Fit & Proper Test requirements
    screening_flags_count INT,                       -- staff flagged in DP/PP screening (Reg 13 §9)
    snapshot_at TIMESTAMP NOT NULL DEFAULT now()
);

-- ============================================
-- DRAFTING
-- ============================================

CREATE TABLE irar_risk_narrative (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES irar_cycles(id),
    risk_dimension VARCHAR(30) NOT NULL,             -- 'CUSTOMERS','PRODUCTS','SERVICES','DELIVERY_CHANNELS',
                                                       -- 'TECHNOLOGIES','EMPLOYEE_CATEGORIES','TRANSNATIONAL_TF','EMERGING_RISKS' (Reg 1 §2)
    llm_draft_text TEXT,
    human_edited_text TEXT,
    edited_by VARCHAR(100),
    edited_at TIMESTAMP
);

CREATE TABLE irar_gap_analysis (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES irar_cycles(id),
    identified_risk TEXT NOT NULL,
    existing_control TEXT,
    gap_description TEXT,
    proportionality_note TEXT,                        -- explicit: how RE size/nature/complexity was weighed (Reg 1 §9, §11)
    severity VARCHAR(10)                               -- 'LOW','MEDIUM','HIGH' — informational, not auto-deciding anything downstream
);

-- Five explicit, separately-tracked output categories per Reg 1 §8 + Reg 13 §1(a)-(c)
CREATE TABLE irar_action_plan_items (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES irar_cycles(id),
    category VARCHAR(40) NOT NULL,                     -- 'BUSINESS_STRATEGY_RISK_APPETITE','POLICY_FRAMEWORK','SOP_PROCEDURE_MANUAL',
                                                           -- 'EMPLOYEE_RISK_UNDERSTANDING','RESOURCE_ADEQUACY'
    recommendation TEXT NOT NULL,
    target_completion_date DATE,
    owner VARCHAR(100),
    status VARCHAR(20) DEFAULT 'PROPOSED'                -- PROPOSED, APPROVED, IN_PROGRESS, COMPLETE
);

-- ============================================
-- APPROVAL CHAIN (two distinct tiers)
-- ============================================

CREATE TABLE irar_senior_mgmt_prereview (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES irar_cycles(id),
    reviewer_name VARCHAR(100) NOT NULL,
    decision VARCHAR(25) NOT NULL,                       -- 'APPROVED_FOR_BOD','RETURNED_FOR_REVISION'
    comments TEXT,
    decided_at TIMESTAMP NOT NULL DEFAULT now()
);

-- Tier 1: BoD approves the IRAR document itself (Reg 1 §8) — mandatory, non-delegable.
CREATE TABLE irar_bod_approval (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES irar_cycles(id),
    decision VARCHAR(25) NOT NULL,                        -- 'APPROVED','RETURNED_FOR_REVISION'
    approved_by VARCHAR(100) NOT NULL,                     -- BoD chair/secretary logging the board's decision
    meeting_ref VARCHAR(100),
    decided_at TIMESTAMP NOT NULL DEFAULT now()
);

-- Tier 2: Senior Management approves the resulting SOP/procedure TEXT (Reg 1 §12) — separate from BoD's IRAR approval.
CREATE TABLE irar_sop_approval (
    id SERIAL PRIMARY KEY,
    action_plan_item_id INT REFERENCES irar_action_plan_items(id),  -- links to the specific SOP_PROCEDURE_MANUAL item
    approved_by VARCHAR(100) NOT NULL,
    decision VARCHAR(25) NOT NULL,                          -- 'APPROVED','RETURNED_FOR_REVISION'
    updated_sop_reference VARCHAR(200),
    decided_at TIMESTAMP NOT NULL DEFAULT now()
);

-- ============================================
-- ARCHIVAL
-- ============================================

CREATE TABLE irar_archive (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES irar_cycles(id),
    final_document_ref VARCHAR(300),
    bod_deck_ref VARCHAR(300),
    archived_at TIMESTAMP NOT NULL DEFAULT now(),
    retention_until DATE,                                    -- computed per the same 10-year pattern as UC5/UC8
    available_for_sbp_inspection BOOLEAN DEFAULT TRUE          -- Reg 1 §7
);
```

### 4.1 Seed data required
- `irar_external_inputs`: 2-3 demo rows with realistic `source_attribution` values (e.g. a mock NRA reference) to demonstrate the mandatory-attribution pattern.
- `irar_employee_risk_snapshot`: one demo row with plausible training/F&PT numbers.

---

## 5. n8n Workflow — Step-by-Step

### Phase 0 — Trigger
1. **Cron/Schedule node** — fires on the RE's chosen cadence → **Postgres Insert** into `irar_cycles` (`trigger_type = 'SCHEDULED'`).
2. **Webhook node(s)** — separate entry points for `EVENT_NRA_UPDATE`, `EVENT_EMERGING_THREAT`, `EVENT_REGULATOR_FEEDBACK` → each creates its own `irar_cycles` row with the correct `trigger_type`.

### Phase 1 — Data Aggregation
3. **Postgres Node** — query UC5's `str_filings`/`ctr_filings` for period counts → **Insert** into `irar_internal_metrics_snapshot`.
4. **Postgres Node** — query UC3's `pep_designations` and TFS screening counts for period counts → **Insert** into `irar_internal_metrics_snapshot`.
5. **Webhook/Form node** — compliance analyst manually enters NRA updates / incident intelligence / regulator feedback, each requiring a non-empty `source_attribution` (enforced `NOT NULL` at DB level) → **Insert** into `irar_external_inputs`.
6. **HTTP Request node** — calls UC1's `/webhook/uc1-compliance-metrics` endpoint → **Postgres Insert** into `irar_rejected_case_inputs` with the returned counts.
7. **Webhook/Form node** — HR/compliance enters employee training/F&PT/screening snapshot → **Insert** into `irar_employee_risk_snapshot`.
8. **Postgres Node — Update** `irar_cycles.status = 'DRAFTING'`.

### Phase 2 — Risk Narrative Drafting
9. **HTTP Request node (LLM call)** — for each of the 8 required dimensions (`CUSTOMERS`, `PRODUCTS`, `SERVICES`, `DELIVERY_CHANNELS`, `TECHNOLOGIES`, `EMPLOYEE_CATEGORIES`, `TRANSNATIONAL_TF`, `EMERGING_RISKS`), draft a narrative section using the aggregated data as context → **Insert** into `irar_risk_narrative` (`llm_draft_text` populated, `human_edited_text` left null until analyst edits).
10. **Webhook/Form node** — analyst reviews/edits each dimension's narrative → **Update** `irar_risk_narrative.human_edited_text`, `edited_by`, `edited_at`.

### Phase 3 — Gap Analysis
11. **Webhook/Form node** — analyst (optionally LLM-assisted) documents identified risks vs. existing controls, explicitly noting the proportionality reasoning → **Insert** into `irar_gap_analysis`.

### Phase 4 — Action Plan
12. **Webhook/Form node** — for each gap, analyst drafts a recommendation tagged to one of the 5 `category` values → **Insert** into `irar_action_plan_items`.
13. **IF Node** — guard: before proceeding, verify at least one `irar_action_plan_items` row exists for each of `BUSINESS_STRATEGY_RISK_APPETITE`, `POLICY_FRAMEWORK`, `SOP_PROCEDURE_MANUAL`, `EMPLOYEE_RISK_UNDERSTANDING`, and `RESOURCE_ADEQUACY` — if any category is empty, block progression and prompt the analyst (this enforces the SBP Reg 1 §8 rule structurally).

### Phase 5 — Senior Management Pre-Review
14. **Webhook node** — package narrative + gap analysis + action plan into a draft document → routed to senior management.
15. **Webhook/Form node** — senior management submits decision → **Insert** into `irar_senior_mgmt_prereview`.
16. **IF Node** — `RETURNED_FOR_REVISION` → loop back to Phase 2/3/4 as needed; `APPROVED_FOR_BOD` → proceed.

### Phase 6 — BoD Approval (Tier 1)
17. **Webhook node** — generate final IRAR document + BoD presentation deck (simple templated output for POC).
18. **Webhook/Form node** — BoD decision submitted (via board secretary) → **Insert** into `irar_bod_approval`.
19. **IF Node** — `RETURNED_FOR_REVISION` → loop back; `APPROVED` → proceed. **Update** `irar_cycles.status = 'SOP_APPROVAL'`.

### Phase 7 — Senior Management SOP Approval (Tier 2 — separate from Tier 1)
20. **Postgres Node** — for each `irar_action_plan_items` row where `category = 'SOP_PROCEDURE_MANUAL'`, route to senior management individually.
21. **Webhook/Form node** — senior management approves the actual updated SOP text → **Insert** into `irar_sop_approval`.

### Phase 8 — Archival
22. **Postgres Node — Insert** into `irar_archive` (`retention_until` computed, `available_for_sbp_inspection = TRUE`), **Update** `irar_cycles.status = 'ARCHIVED'`, `closed_at = now()`.

---

## 6. Test Scenarios

1. **Scheduled cycle runs end-to-end** with all data sources populated → completes through both approval tiers to archival.
2. **NRA-update-triggered cycle** with no `SOURCE_ATTRIBUTION` entered → should fail at the DB constraint level (`NOT NULL`), proving mandatory attribution is enforced.
3. **Action plan missing an required category item** → Phase 4's guard should block progression to Phase 5.
4. **Senior management returns the pre-review draft for revision** → confirms loop-back.
5. **BoD approves the IRAR, but a specific SOP item is later returned for revision by senior management** → confirms Tier 1 and Tier 2 are independently trackable.
6. **UC1's metrics endpoint is unreachable during Phase 1** → n8n's HTTP Request node should fail gracefully and flag the cycle (`irar_cycles.status` stays at `DATA_AGGREGATION` with an error note).

---

## 7. Traceability

| PRD Section | Regulation |
|---|---|
| Dual trigger | Reg 1 §7 |
| 8 risk dimensions | Reg 1 §2 (including transnational TF & emerging risks) |
| External inputs (NRA, incidents, regulator feedback) | Reg 1 §3 |
| Gap analysis vs. existing controls | Reg 1 §4 |
| Proportionality weighting | Reg 1 §9, §11 |
| 5 required action-plan categories | Reg 1 §8, Reg 13 §1(a)-(c) |
| BoD approval (Tier 1) | Reg 1 §8, §13 |
| Senior management approval of controls/procedures (Tier 2) | Reg 1 §12 |
| SBP-on-demand availability | Reg 1 §7 |
| SBP Reg 13 §3 metrics (Rejected/challenged cases) | Reg 13 §3 — live via UC1 metrics endpoint |
| Employee-category data | Reg 1 §2, Reg 13 §9 |

---

## 8. Notes for Antigravity

- Do not merge the BoD approval (`irar_bod_approval`) and the SOP-text approval (`irar_sop_approval`) into a single table or a single workflow gate — they are legally distinct approvers approving distinct things, per Reg 1 §8 vs §12.
- UC1's `/webhook/uc1-compliance-metrics` endpoint must be running (same Docker network) for Phase 1 to complete — if unreachable, fail the cycle loudly.
- `irar_external_inputs.source_attribution` should be a hard `NOT NULL` constraint.
