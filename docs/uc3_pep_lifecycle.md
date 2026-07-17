# SBP PEP Lifecycle & Enhanced Due Diligence (EDD) — Use Case 3: PEP Lifecycle Monitoring

---

## 1. Professional Introduction
This document outlines the design, architectural framework, and compliance mapping for **Use Case 3 (UC3): Politically Exposed Persons (PEP) Lifecycle Monitoring & EDD**. Built as a core component of the State Bank of Pakistan (SBP) Compliance Automation Sandbox, this system automates the screening, designation, relationship classification, Source of Wealth (SOW) verification, senior management approval, periodic recertification, and monitoring intensity step-downs for PEPs under SBP jurisdiction.

This implementation translates the regulatory mandates of the **State Bank of Pakistan (SBP) AML/CFT/CPF Regulations** into a deterministic, config-driven, and audited technology stack. Using **n8n** for workflow orchestration, **PostgreSQL** for state and configuration management, and automated test runners to execute regulatory scenarios, this sandbox replicates the operational reality of a compliance office in a retail bank.

---

## 2. Table of Contents
1. [Professional Introduction](#1-professional-introduction)
2. [Executive Purpose & Regulatory Philosophy](#3-executive-purpose--regulatory-philosophy)
3. [Regulatory Mapping & Reference Matrix](#4-regulatory-mapping--reference-matrix)
4. [PEP Classification & SOW Evidence Requirements](#5-pep-classification--sow-evidence-requirements)
5. [Database Schema & Config-Driven Architecture](#6-database-schema--config-driven-architecture)
6. [Flow-by-Flow Technical Architecture](#7-flow-by-flow-technical-architecture)
7. [Nitty-Gritty Node Configuration Details](#8-nitty-gritty-node-configuration-details)
8. [Automated Test Scenarios & Verification](#9-automated-test-scenarios--verification)

---

## 3. Executive Purpose & Regulatory Philosophy
Politically Exposed Persons (PEPs) represent a high money-laundering risk due to their public positions, which can be vulnerable to corruption. SBP regulations require financial institutions to apply Enhanced Due Diligence (EDD) measures to PEPs, their family members, and close associates.

A key challenge is the regulatory requirement that **"once a PEP, always a PEP"** (Definition 52: "is or has been"). PEP designations must remain active on file for audit integrity, even if the person leaves public office. However, banks can adjust their operational monitoring intensity over time.

**Use Case 3** implements this using a **four-flow compliance framework**:
* **Fuzzy Screening:** Re-screens customers against watchlists using PostgreSQL trigram matching (`pg_trgm`).
* **Relationship Mapping:** Identifies PEP connections using SBP definitions (spouse, siblings, children).
* **Seniority Filtering:** Excludes junior/middle-ranking officials per SBP guidelines.
* **Asynchronous SOW Gating:** Blocks final approvals until all Source of Wealth (SOW) documents are verified and reconciled.
* **Audited Step-Down:** Steops down monitoring intensity to `STANDARD` for former PEPs after an observation period, while keeping the core PEP designation active.

---

## 4. Regulatory Mapping & Reference Matrix

The workflow enforces compliance with the following sections of the **SBP AML/CFT/CPF Regulations**:

| Regulatory Directive | SBP Clause Reference | Workflow Implementation Mechanism |
| :--- | :--- | :--- |
| **PEP Definition** | Definition 52 | Enforces the "is or has been" rule. PEP designations are kept active in the database (`is_active = TRUE`) for the customer's lifetime. |
| **Close Associate Definition** | Definition 12 | Flags customers with close business or social ties to a PEP, prompting relationship reviews. |
| **Family Member Definition** | Definition 28 | Automatically identifies and screens spouses, siblings, parents, and children of PEPs. |
| **Seniority Level Check** | Definition 52(d) | Filters out junior/middle-ranking officials (e.g., provincial tax officers) from high-risk PEP classifications. |
| **Source of Wealth (SOW)** | Regulation 5 §1(c) | Gates senior management approvals until SOW documents (e.g., assets declarations) are verified and reconciled. |
| **Senior Management Approval** | Regulation 5 §1(b) | Enforces senior compliance officer sign-off before establishing or continuing a PEP relationship. |
| **Monitoring Intensity Transition** | Regulation 5 §1(d) | Logs transitions from `ENHANCED` monitoring to `STANDARD` after a designated post-office observation period. |

---

## 5. PEP Classification & SOW Evidence Requirements

During the verification phase, compliance analysts classify relationships and collect documents to support the customer profile:

```
                            ┌──────────────────────────────────┐
                            │  PEP Designation Classification  │
                            └────────────────┬─────────────────┘
                                             │
                  ┌──────────────────────────┼──────────────────────────┐
                  ▼                          ▼                          ▼
          ┌──────────────┐           ┌──────────────┐           ┌──────────────┐
          │  Direct PEP  │           │Family Member │           │Close Assoc.  │
          └──────┬───────┘           └──────┬───────┘           └──────┬───────┘
                 │                          │                          │
                 ├─► Official Gazette       ├─► Marriage Cert.         ├─► Business Share
                 ├─► Senate Record          ├─► Birth Cert.            │   Registry
                 └─► Assets Declaration     └─► Sibling Attestation    └─► Trust Deed
```

### 5.1 Relationship Classification (Def #12 & Def #28)
* **Direct PEP:** The customer holds a public position (e.g., Federal Minister).
* **Family Member:** The customer is a spouse, sibling, child, or parent of a PEP. The system collects supporting documents (e.g., Marriage Certificate, Birth Certificate, Family Registration Certificate) to verify the relationship.
* **Close Associate:** The customer shares business ownership or close ties with a PEP. The system collects corporate filings or partnership deeds to verify the association.

### 5.2 Source of Wealth (SOW) Verification (Reg 5 §1(c))
Before approving a PEP account, compliance teams must verify the customer's source of wealth:
* **Salary Disclosures:** Verified against pay slips, bank statements, and employment letters.
* **Asset Declarations:** Verified against tax filings and property deeds.
* **Business Income:** Verified against audited financial statements and corporate registries.

All uploaded documents must be reviewed and marked as `reconciled = TRUE` in the compliance database before senior management can approve the case.

---

## 6. Database Schema & Config-Driven Architecture

The database schema extends the core onboarding database with tables to manage the PEP lifecycle:

```
                          ┌──────────────────────┐
                          │   pep_designations   │
                          └──────────┬───────────┘
                                     │
            ┌────────────────────────┼────────────────────────┐
            ▼                        ▼                        ▼
┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────────┐
│  enhanced_monitoring │ │   monitoring_log     │ │  recertification     │
└──────────────────────┘ └──────────────────────┘ └──────────────────────┘
```

### 6.1 Transactional PEP Tables
```sql
-- Watchlist Source Data
CREATE TABLE pep_watchlist_source (
    id SERIAL PRIMARY KEY,
    full_name VARCHAR(200) NOT NULL,
    date_of_birth DATE,
    nationality VARCHAR(100),
    position_title VARCHAR(200),
    pep_category VARCHAR(20) NOT NULL,                           -- 'DOMESTIC', 'FOREIGN', 'INT_ORG'
    seniority_level VARCHAR(20) NOT NULL,                        -- 'SENIOR', 'JUNIOR_MIDDLE_EXCLUDED'
    source_note TEXT
);

-- Screening Cycles History
CREATE TABLE rescreening_cycles (
    id SERIAL PRIMARY KEY,
    cycle_type VARCHAR(20) NOT NULL,                             -- 'SCHEDULED', 'EVENT_TRIGGERED'
    trigger_reason VARCHAR(50),                                  -- 'MONTHLY_BATCH', 'PROFILE_UPDATE'
    status VARCHAR(20) NOT NULL DEFAULT 'RUNNING',
    triggered_at TIMESTAMP NOT NULL DEFAULT now(),
    completed_at TIMESTAMP
);

-- Individual Candidate Match History
CREATE TABLE pep_match_candidates (
    id SERIAL PRIMARY KEY,
    rescreening_candidate_id INT REFERENCES rescreening_candidates(id),
    pep_watchlist_source_id INT REFERENCES pep_watchlist_source(id),
    match_confidence NUMERIC(5,2) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'PENDING_REVIEW'         -- 'PENDING_REVIEW', 'REJECTED_NOT_SAME_PERSON', 'CONFIRMED_MATCH'
);

-- Core PEP Designations
CREATE TABLE pep_designations (
    id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,
    pep_watchlist_source_id INT REFERENCES pep_watchlist_source(id),
    designation_type VARCHAR(20) NOT NULL,                        -- 'DIRECT_PEP', 'FAMILY_MEMBER', 'CLOSE_ASSOCIATE'
    pep_category VARCHAR(20) NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

-- Enhanced Monitoring Flag State
CREATE TABLE enhanced_monitoring_flags (
    id SERIAL PRIMARY KEY,
    customer_id INT UNIQUE NOT NULL,
    pep_designation_id INT REFERENCES pep_designations(id),
    monitoring_tier VARCHAR(20) NOT NULL,                        -- 'ENHANCED', 'STANDARD'
    set_at TIMESTAMP NOT NULL DEFAULT now(),
    set_by VARCHAR(100) NOT NULL
);

-- Audit Log for Monitoring Changes (Step-down History)
CREATE TABLE monitoring_intensity_log (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT REFERENCES pep_designations(id),
    previous_tier VARCHAR(20) NOT NULL,
    new_tier VARCHAR(20) NOT NULL,
    reason TEXT NOT NULL,
    approved_by VARCHAR(100) NOT NULL,
    approved_at TIMESTAMP NOT NULL DEFAULT now()
);
```

---

## 7. Flow-by-Flow Technical Architecture

The workflow consists of **57 nodes** organized into **4 event-triggered flows**:

```
[Flow A: Event/Scheduled Re-screening]
   │
   ▼
[Compile Candidate Profiles] ──► [Loop Candidates]
                                        │
                               [Postgres Similarity Screen]
                                        │
                               [If Match Confirmed?]
                                  ├── Yes ──► [Insert Match Candidate (PENDING)]
                                  └── No  ──► [Next Loop]
                                        │
                               [Collapse Loop to Single Item]
                                        │
                               [Complete Cycle & Send Summary Email]

[Flow B: Analyst Match & Classification]
   │
   ▼
[Is Match Valid?]
   ├── No  ──► [Set Match: REJECTED] ──► [Return 200]
   └── Yes ──► [Check Relationship Rules]
                  │
             [Is Senior Official?]
                  ├── No  ──► [Set Status: EXCLUDED] ──► [Return 200]
                  └── Yes ──► [Create PEP Designation] ──► [Return 200]

[Flow C: SOW Submission & Approval]
   │
   ▼
[Is Action Submit Evidence or Approve?]
   ├── Submit ──► [Insert SOW Evidence] ──► [Return 200]
   └── Approve ─► [Are All Documents Reconciled?]
                     ├── No  ──► [Return 422: ON_HOLD]
                     └── Yes ─► [Update Flag to ENHANCED] ──► [Schedule Recertification] ──► [Return 200]

[Flow D: Step-Down Request]
   │
   ▼
[Is Designation Active?]
   ├── No  ──► [Return 400: Error]
   └── Yes ──► [Log Transition] ──► [Update Flag to STANDARD] ──► [Send Alert Email] ──► [Return 200]
```

### Flow A: Scheduled/Event-Based Rescreening (Nodes 1–16)
* **Trigger:** Monthly batch trigger (1st of each month) or customer profile change webhook.
* **Operation:** Runs name queries against the watchlist using trigram matching.
* **Loop Safety:** Uses a Code node (`Collapse to Single Item`) after the loop to collapse the processed array into a single item, ensuring the downstream update database query and summary email execute only once.

### Flow B: Compliance Analyst Review (Nodes 17–28)
* **Trigger:** Compliance dashboard form submission.
* **Operation:** Validates analyst decisions. If a match is confirmed, the system checks the relationship against Definitions 12 and 28, and runs a seniority level check (Definition 52(d)). If the profile is eligible, it creates a PEP designation.

### Flow C: SOW Verification & Senior Management Approval (Nodes 29–50)
* **Trigger:** Compliance dashboard form submission.
* **Operation:** Handles two actions:
  * **`submit_evidence`:** Logs SOW documents into the database.
  * **`approve`:** Evaluates all uploaded SOW records. If any documents are unreconciled, the system returns a `422 ON_HOLD` status. If all documents are reconciled, it creates the PEP designation, updates the monitoring flag to `ENHANCED`, and schedules a periodic recertification task.

### Flow D: Monitoring Intensity Step-Down (Nodes 51–57)
* **Trigger:** Senior compliance officer request.
* **Operation:** Evaluates step-down requests. It updates the customer's monitoring status from `ENHANCED` to `STANDARD` and logs the transition in the audit history. The core PEP designation remains active (`is_active = TRUE`) to comply with SBP regulations.

---

## 8. Nitty-Gritty Node Configuration Details

### 8.1 Fuzzy Trigram Name Matching (Node 10 - Postgres)
* **Type:** `n8n-nodes-base.postgres`
* **Purpose:** Matches customer names against watchlist records using a similarity threshold (minimum 60% confidence floor):
```sql
SELECT
  pw.id AS pep_watchlist_source_id,
  pw.full_name AS watchlist_name,
  pw.pep_category,
  pw.seniority_level,
  ROUND((similarity(
    LOWER('{{ $('Merge Triggers').first().json.full_name }}'),
    LOWER(pw.full_name)
  ) * 100)::numeric, 2) AS match_confidence
FROM pep_watchlist_source pw
WHERE similarity(
  LOWER('{{ $('Merge Triggers').first().json.full_name }}'),
  LOWER(pw.full_name)
) >= 0.6
ORDER BY match_confidence DESC
LIMIT 1;
```
* **Setting:** Toggle **Always Output Data** to **ON** (ensures the loop does not get stuck/hang when a candidate has no matches).

### 8.2 Loop Collapsing (Node 13b - Code)
* **Type:** `n8n-nodes-base.code`
* **Purpose:** Collapses the array of loop items to a single item, ensuring the downstream update query and summary email execute only once:
* **Mode:** `Run Once for All Items`
* **Code:**
```javascript
return [ $input.first() ];
```

---

## 9. Automated Test Scenarios & Verification

The integration script `/tests/uc3_pep_lifecycle/test_pep_lifecycle.sh` verifies the PEP monitoring workflows:

```
[Execute Test Runner]
   │
   ├─► Payload 1: Foreign PEP (Direct) ─────► Full Path ────────► Approved & Enhanced Monitoring Active (200)
   ├─► Payload 2: Junior Provincial Officer ──► Seniority Gate ────► Blocked & Excluded per Def 52(d) (200)
   ├─► Payload 3: Wrong Person Match ───────► False Positive ────► Case Closed with No Designation (200)
   ├─► Payload 4: Sibling Association ──────► Family Member ─────► Validated Sibling Relationship (200)
   ├─► Payload 5: Unreconciled Assets ─────► SOW Gating ─────────► Blocked & Placed ON_HOLD (422)
   └─► Payload 6: Senior Step-Down ────────► Audit Transition ──► Tier Down to Standard (Designation Active) (200)
```

### Test Scenario 2: Seniority Level Exclusion Check
* **Payload:** `02_junior_middle_exclusion.json`
* **Details:** Customer matches "Rashid Mehmood Langrial", a junior provincial tax officer.
* **Expected Result:** The system flags the profile under Definition 52(d) as junior/middle-ranking and excludes the candidate from PEP status. The case closes with status `EXCLUDED_DEF52D`.

### Test Scenario 5: SOW Gating Check
* **Payload:** `05_sow_evidence_not_reconciled.json`
* **Details:** Customer matches "Ibrahim Khalid Dar". The analyst uploads SOW evidence but marks it as unreconciled.
* **Expected Result:** The system blocks the approval request, returning a `422 ON_HOLD` status. The case remains locked until the SOW documents are verified.

### Test Scenario 6: Monitoring Intensity Step-Down
* **Payload:** `06_monitoring_step_down.json`
* **Details:** Customer matches "Fatima Noor Siddiqui". The step-down request is submitted 18 months after she left office.
* **Expected Result:** The system changes the monitoring status from `ENHANCED` to `STANDARD` and records the transition in the audit history. The core PEP designation remains active to comply with audit requirements.
