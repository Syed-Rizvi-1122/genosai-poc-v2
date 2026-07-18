# SBP Board Governance & IRAR Automation — Use Case 13: IRAR Auto-Generation & Board Governance

---

## 1. Professional Introduction
This document outlines the design, architectural framework, and compliance mapping for **Use Case 13 (UC13): IRAR Auto-Generation & Board Governance Engine**. Built as a core component of the State Bank of Pakistan (SBP) Compliance Automation Sandbox, this system automates the intake, compilation, narrative drafting, validation, and multi-tier approval routing of the annual Internal Risk Assessment Report (IRAR).

This implementation translates the regulatory mandates of **Regulation 1 (Risk-Based Approach) and Regulation 13 (Internal Controls) of the State Bank of Pakistan (SBP) AML/CFT/CPF Regulations** into a deterministic, config-driven, and fully audited technology stack. Using **n8n** for unified workflow orchestration, **PostgreSQL** for state tracking and records retention, **Groq GenAI completions (Llama 3.3 70B)** for narrative drafting, and SMTP for secure pre-review notifications, this sandbox replicates the compliance gatekeeping required of retail banks.

---

## 2. Table of Contents
1. [Professional Introduction](#1-professional-introduction)
2. [Executive Purpose & Regulatory Philosophy](#3-executive-purpose--regulatory-philosophy)
3. [Regulatory Mapping & Reference Matrix](#4-regulatory-mapping--reference-matrix)
4. [Use Case Process Map & Logic Matrix](#5-use-case-process-map--logic-matrix)
5. [Database Schema & Retention Rules](#6-database-schema--retention-rules)
6. [Flow-by-Flow Technical Architecture](#7-flow-by-flow-technical-architecture)
7. [Nitty-Gritty Node Configuration Details](#8-nitty-gritty-node-configuration-details)
8. [Automated Test Scenarios & Verification](#9-automated-test-scenarios--verification)

---

## 3. Executive Purpose & Regulatory Philosophy

The Internal Risk Assessment Report (IRAR) is a bank's most critical regulatory document. It aggregates risk exposures across all operational dimensions and details the controls in place to mitigate money laundering, terrorist financing, and proliferation financing (ML/TF/PF) threats. 

SBP AML/CFT/CPF Regulations establish strict standards to ensure the IRAR is not a static paper exercise, but an active governance tool:
* **Decoupled Asynchronous Data Entry:** To reflect real bank operations, data entry is decoupled by organizational role. The HR/Training team logs employee training snapshots, the Compliance officer records external regulator circulars, and the automated pipeline aggregates PEP (UC3) and STR (UC5) metrics independently.
* **Generative Narrative Compilation:** Gathers internal, external, onboarding, and training metrics, feeding them into a generative AI LLM completion prompt to draft risk narratives across 8 SBP-specified dimensions.
* **Mandatory Category Validation:** SBP regulations require that the bank's action plans address gaps across all 5 mandatory compliance areas. The workflow programmatically enforces that any submitted action plan covers all 5 categories, returning a validation failure block if any category is neglected.
* **Two-Tier Non-Delegable Governance Approvals:**
  1. **Tier 1 (Board Level):** The Board of Directors must review and formally approve the IRAR document. This responsibility cannot be delegated.
  2. **Tier 2 (Senior Management):** Senior management must review and sign off on the specific SOP and policy procedure text modifications that result from the SBP action plan.
* **10-Year Record Retention:** All finalized IRAR documents, Board decks, logs, and approvals must be archived and retrievable for at least **10 years** for SBP regulatory audits.

---

## 4. Regulatory Mapping & Reference Matrix

The compliance engine enforces strict alignment with **SBP AML/CFT/CPF Regulations 1 and 13**:

| Regulatory Directive | Clause Reference | Workflow Implementation Mechanism |
| :--- | :--- | :--- |
| **Comprehensive Risk Identification** | Reg 1 §2 | AI engine drafts narrative texts across 8 SBP risk dimensions (Customers, Products, Services, Delivery Channels, Technologies, Staff, Transnational TF, Emerging Risks). |
| **BoD Non-Delegable Approval** | Reg 1 §8 | Tier 1 Board approval webhook requires explicit Board vote and logs Board meeting reference details. |
| **Senior Management SOP Review** | Reg 1 §12 | Tier 2 approval webhook requires senior management sign-off on SOP text updates for each action item. |
| **Proportionality Gating** | Reg 1 §9 & §11 | Gap Analysis records capture explicit text fields documenting how the bank's size, nature, and complexity were weighed. |
| **Rejected Case Intake** | Reg 13 §3 | Flow A automatically performs an HTTP call to the UC1 metrics endpoint to retrieve rejected case counts, challenged risk revisions, and closed relationships. |
| **Internal Control Pillars** | Reg 13 §1(a)-(c) | Enforces SBP categories checks, ensuring action plans cover Business Strategy, Policy, SOPs, Training, and Resources. |
| **10-Year Retention Auditing** | Reg 1 §7 | Computes the retention expiration date dynamically in the database as exactly `10 years` after the value date for all archived reports. |

---

## 5. Use Case Process Map & Logic Matrix

The n8n canvas is divided into 5 independent sub-flows that act as decoupled transactional routes:

```
FLOW A: Cycle Intake & Data Snapshots
A1: Cron / Event Trigger ──► [Insert Cycle] ──► [Agg UC3/UC5] ──► [Fetch UC1] ──► [Set status: DRAFTING]
A2: HR Webhook ──► [Insert Staff Snapshot]
A3: Compliance Webhook ──► [Insert SBP NRA Inputs]

FLOW B: LLM Risk Narrative Compilation
[Webhook: Start Draft] ──► [Get Context] ──► [LLM Groq Completion] ──► [Insert Narrative Drafts]
[Webhook: Analyst Edit] ──► [Update Narrative Text]

FLOW C: Gaps & Action Plan Enforcement
[Webhook: Enter Gaps] ──► [Insert Gap & Proportionality]
[Webhook: Action Item] ──► [Insert Recommendation] ──► [Count Categories] ──► [IF: All 5 pillars covered?]
                                                                                ├── Yes ──► [Respond 200: Validated]
                                                                                └── No  ──► [Respond 400: Failed]

FLOW D: Two-Tier Governance Approvals
[Webhook: Pre-Review] ──► [Set Pre-Review Status] ──► [Send Alert Email]
[Webhook: Decision] ──► [Insert Decision Log] ──► [IF: Pre-Review Approved?]
                                                           ├── Yes ──► [Set status: BOD_APPROVAL]
                                                           └── No  ──► [Set status: DRAFTING]
[Webhook: BoD Vote] ──► [Insert BoD Vote Log] ──► [IF: Board Approved?]
                                                           ├── Yes ──► [Set status: SOP_APPROVAL]
                                                           └── No  ──► [Set status: DRAFTING]
[Webhook: SOP Update] ──► [Insert SOP Log] ──► [Archive Cycle] ──► [Save Archive Log (retention = 10 years)]

FLOW E: UC1 Metrics Read Endpoint
[Webhook: Fetch Metrics] ──► [Query Database UC1 tables] ──► [Respond Metrics JSON]
```

---

## 6. Database Schema & Retention Rules

The database schema (`009_uc13_schema.sql`) implements SBP auditing structures:
* **`irar_cycles`**: Tracks cycle references, trigger types, and state transitions (`DATA_AGGREGATION`, `DRAFTING`, `SENIOR_MGMT_PREREVIEW`, `BOD_APPROVAL`, `SOP_APPROVAL`, `ARCHIVED`).
* **`irar_internal_metrics_snapshot`**: Holds aggregate counts for STRs (UC5), CTRs (UC5), PEPs (UC3), and TFS Match counts.
* **`irar_external_inputs`**: Manual entries documenting regulatory circulars, SBP directives, and FMU circular links with mandatory source attribution.
* **`irar_rejected_case_inputs`**: Sourced onboarding counts from UC1 (rejected, revised, and closed cases).
* **`irar_employee_risk_snapshot`**: HR-entered metrics capturing F&PT compliance and training completion rates.
* **`irar_risk_narrative`**: Holds both generative drafts and human edits for SBP's 8 compliance categories.
* **`irar_gap_analysis`**: Identified gaps, severity logs, and explicit proportionality rationales.
* **`irar_action_plan_items`**: Categorized action items tagged under one of the 5 internal control pillars.
* **`irar_senior_mgmt_prereview` & `irar_bod_approval`**: Governance decision history and meeting references.
* **`irar_archive`**: Finished reports, Board decks, and dynamic 10-year retention dates.

### 6.1 Retention Expiry Calculation
Upon successful archiving (Node 45), the database calculates the mandatory retention date as:
$$\text{retention\_until} = \text{now()::date} + \text{interval '10 years'}$$

---

## 7. Flow-by-Flow Technical Architecture

### 7.1 Flow A: Intake & Aggregation
* **Trigger Nodes (Nodes 1 & 2):** Periodical schedule or event-driven webhook starts the cycle.
* **Cycle Record (Node 3):** Generates a unique cycle reference string and saves it.
* **Aggregation (Nodes 4–7 & 10–11):** Queries UC5 tables for transaction metrics and UC3 tables for PEP matching metrics. Performs an HTTP GET call to the local UC1 webhook to fetch CDD statistics and saves the aggregated snapshots.
* **Manual Inputs (Nodes 8–9 & 12–13):** Exposes endpoints for decoupled manual HR and Compliance inputs.
* **Intake Close (Node 14):** Transitions cycle status to `DRAFTING` once the initial aggregations run.

### 7.2 Flow B: Generative Narratives
* **Start Drafting (Nodes 15 & 16):** Compliance officer webhook queries database for the aggregated context of the cycle.
* **LLM Completion (Node 17):** Feeds context into a Groq chat completions API request (Llama-3.3-70b-versatile) using n8n's expression mode.
* **Save Drafts (Node 18):** Iterates over SBP's 8 risk dimensions and inserts narratives into the DB with single-quote escaping.
* **Analyst Edits (Nodes 19 & 20):** Receives manual analyst edits and updates narrative text records.

### 7.3 Flow C: Gaps & Validation
* **Gap Analysis (Nodes 21 & 22):** Records bank gaps with mandatory proportionality fields.
* **Action Recommendation (Nodes 23 & 24):** Inserts plan items under specific SBP categories.
* **Validation (Nodes 25–28):** Counts logged categories and checks if all 5 categories have items. If yes, triggers `Respond: Validation Passed` (`200 OK`). If no, triggers `Respond: Validation Failed` (`400 Bad Request`).

### 7.4 Flow D: Approvals & Archival
* **Pre-Review Routing (Nodes 29–31):** Exposes pre-review start, updates cycle status, and sends a styled HTML email alert to senior management.
* **Pre-Review Decision (Nodes 32–36):** Evaluates management's decision. If approved, sets status to `BOD_APPROVAL`. If rejected, returns to `DRAFTING`.
* **Board Approval (Nodes 37–41):** Evaluates BoD's vote. If approved, sets status to `SOP_APPROVAL`. If rejected, returns status to `DRAFTING`.
* **SOP Finalization & Archive (Nodes 42–45):** Ingests final SOP references, updates cycle status to `ARCHIVED`, computes the 10-year retention limit, and logs archive entries.

---

## 8. Nitty-Gritty Node Configuration Details

* **Node Count:** 48 nodes on a single n8n canvas.
* **Groq Completion Expression:** Configured with JS Expression mode using template literal backticks (`` ` ``) to handle multiline formatting and avoid JSON double-quote escaping syntax crashes:
  ```javascript
  {{
  {
    "model": "llama-3.3-70b-versatile",
    "messages": [
      {
        "role": "system",
        "content": "You are a professional bank AML/CFT compliance analyst..."
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
* **Status Updates via SQL Subqueries:** Since the incoming payload for SOP Approval only has `action_plan_item_id`, the transition update queries the parent `cycle_id` dynamically to complete the state update:
  ```sql
  UPDATE irar_cycles
  SET status = 'ARCHIVED',
      closed_at = now()
  WHERE id = (
    SELECT cycle_id 
    FROM irar_action_plan_items 
    WHERE id = {{ $json.action_plan_item_id }}
  )
  RETURNING *;
  ```
* **HTML Email Notification:** Node 31 utilizes responsive HTML styling, containing structural tables and buttons styled with gradient borders to notify senior managers of pending IRARs.

---

## 9. Automated Test Scenarios & Verification

All automated verification scenarios reside in `tests/uc13_governance/`:

```bash
# 1. Scheduled Complete Path — Executed, Approved (both tiers), and Archived
./tests/uc13_governance/test_uc13_governance.sh tests/uc13_governance/payloads/01_scheduled_complete_path.json

# 2. Missing Source Attribution — Preventive Database Constraint Rejection
./tests/uc13_governance/test_uc13_governance.sh tests/uc13_governance/payloads/02_missing_source_attribution.json

# 3. Missing SBP Category — Validation Block (Fails 5-pillar count, HTTP 400)
./tests/uc13_governance/test_uc13_governance.sh tests/uc13_governance/payloads/03_missing_action_plan_category.json

# 4. Pre-Review Rejection — Loops status back to DRAFTING
./tests/uc13_governance/test_uc13_governance.sh tests/uc13_governance/payloads/04_senior_mgmt_loopback.json

# 5. BoD Approved, SOP Rejected — Loops status back to DRAFTING
./tests/uc13_governance/test_uc13_governance.sh tests/uc13_governance/payloads/05_bod_approve_sop_reject.json

# 6. UC1 Metrics Unreachable — Graceful Fallback (aggregates without CDD metrics)
./tests/uc13_governance/test_uc13_governance.sh tests/uc13_governance/payloads/06_uc1_unreachable.json
```
