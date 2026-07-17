# PRD: UC8 — Wire Transfer Data Completeness & Compliance Engine
**GenosAI AML/CFT/CPF Compliance Automation — Final Year Project**
**Target build tool:** Google Antigravity IDE
**Stack:** n8n (Docker) + PostgreSQL (Docker)
**Status:** v1 — Phase 1 (POC) scope

---

## 1. Objective

Build an automated compliance gateway for wire transfers that dynamically identifies the bank's role (Ordering, Intermediary, or Beneficiary) per transaction and enforces the specific data completeness rules mandated by **SBP AML/CFT/CPF Regulation 11**.

---

## 2. Scope

### 2.1 In Scope
* **Exemption Checking:** Automatically identifies and bypasses interbank settlement transfers acting on their own behalf (§1).
* **Role Routing:** Classifies the transaction direction (OUTGOING, FORWARDING, INCOMING) and routes it to the correct track.
* **Ordering Track (Outgoing):**
  * Verifies originator's KYC status (cross-linking with UC1).
  * Validates the 5 mandatory message fields for individual transfers (§3): Originator Name, Originator Account/Ref, Originator CNIC/Passport, Beneficiary Name, Beneficiary Account/Ref.
  * Validates the batch-level originator reference and traceable beneficiary information for batch files (§4).
  * Prevents the transfer from being sent if any required data is missing.
* **Intermediary Track (Forwarding):**
  * Preserves and forwards incoming fields exactly as received (§9a).
  * Checks incoming cross-border transfers for missing fields (§9c).
  * Places incomplete transfers on hold, requiring human analyst review to execute, reject, or suspend (§9d).
* **Beneficiary Track (Incoming):**
  * Verifies receiving customer's KYC (reusing UC1 CDD).
  * Places incoming transfers with incomplete originator/beneficiary information on hold.
  * Triggers STR reviews via UC5 for suspicious cases.
* **Correspondent Tracking:** Logs and alerts on counterparty institutions that repeatedly send incomplete transfers.
* **Retention Scheduling:** Dynamically calculates retention duration: `10 years` past transaction completion or filing date (whichever is later).

### 2.2 Out of Scope
* Integration with live international payment clearings (e.g. real SWIFT networks or RTGS).
* Real-time automated querying of correspondent bank databases (mocked using internal tables).

---

## 3. Actors

| Actor | Role |
|---|---|
| Core Banking System (CBS) | Originates customer transfer instructions and receives incoming ones. |
| SWIFT / Payment Gateway | Ingests raw messages (e.g., MT103, pain.001) for intermediary and beneficiary processing. |
| Compliance Analyst | Reviews held transfers, decides on releasing/rejecting/suspending, and logs rationales. |
| System (n8n) | Conducts automated field validations, enforces preventive blocks, and manages hold states. |

---

## 4. Database Schema (PostgreSQL)

```sql
-- ============================================================================
-- UC8 WIRE TRANSFER TABLES
-- ============================================================================

-- Wire Transfers Ledger
CREATE TABLE wire_transfers (
    id SERIAL PRIMARY KEY,
    transaction_ref VARCHAR(50) UNIQUE NOT NULL,      -- SWIFT message ID or payment reference
    sending_institution VARCHAR(100) NOT NULL,
    receiving_institution VARCHAR(100) NOT NULL,
    is_interbank_exemption BOOLEAN NOT NULL DEFAULT FALSE, -- Reg 11 §1 interbank settlement
    transfer_type VARCHAR(20) NOT NULL,                -- 'INDIVIDUAL', 'BATCH'
    direction VARCHAR(20) NOT NULL,                    -- 'OUTGOING' (Ordering), 'FORWARDING' (Intermediary), 'INCOMING' (Beneficiary)
    originator_customer_id INT,                        -- FK to UC1's customers.id (if local)
    amount NUMERIC(18,2) NOT NULL,
    currency VARCHAR(10) NOT NULL DEFAULT 'PKR',
    value_date DATE NOT NULL,
    purpose_of_transfer TEXT,
    originator_beneficiary_relationship TEXT,          -- SBP reconstruction requirement (§2b)
    
    -- Originator SBP message fields (§3)
    originator_name VARCHAR(200),
    originator_account_ref VARCHAR(100),
    originator_id_doc_number VARCHAR(50),              -- CNIC, Passport, etc.
    
    -- Beneficiary SBP message fields (§3)
    beneficiary_name VARCHAR(200),
    beneficiary_account_ref VARCHAR(100),
    beneficiary_id_doc_number VARCHAR(50),
    
    transfer_status VARCHAR(30) NOT NULL DEFAULT 'PENDING_CHECK', 
    -- 'PENDING_CHECK', 'SENT', 'EXECUTED', 'HELD_COMPLETENESS', 'REJECTED', 'SUSPENDED'
    
    flagged_for_cdd_failure BOOLEAN NOT NULL DEFAULT FALSE,
    flagged_for_str_review BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    retention_until DATE                               -- computed transaction execution/filing + 10 years
);

-- Compliance Analyst Gating Queue
CREATE TABLE wire_transfer_holds (
    id SERIAL PRIMARY KEY,
    wire_transfer_id INT REFERENCES wire_transfers(id),
    role_at_bank VARCHAR(20) NOT NULL,                 -- 'INTERMEDIARY', 'BENEFICIARY'
    hold_reason TEXT,                                  -- description of missing fields
    review_status VARCHAR(30) NOT NULL DEFAULT 'PENDING_REVIEW', 
    -- 'PENDING_REVIEW', 'APPROVED_RELEASE', 'APPROVED_REJECT', 'SUSPENDED_STR_ESCALATION'
    reviewed_by VARCHAR(100),
    reviewed_at TIMESTAMP,
    rationale TEXT,                                    -- mandatory compliance officer rationale
    logged_at TIMESTAMP NOT NULL DEFAULT now()
);

-- Correspondent Bank Completeness Tracking Log
CREATE TABLE correspondent_completeness_logs (
    id SERIAL PRIMARY KEY,
    institution_name VARCHAR(100) NOT NULL,
    wire_transfer_id INT REFERENCES wire_transfers(id),
    missing_fields_count INT NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT now()
);
```

---

## 5. Flow-by-Flow Technical Design

### 5.1 Flow 1: Scope, Exemption, & Role Router (Phase 0)
* **Intake:** Ingests the wire transfer payload via Webhook.
* **Exemption Evaluation:** Checks if `sending_institution` and `receiving_institution` are local SBP REs and acting on their own behalf. If true, status is set to `EXECUTED` (Exempted) and workflow terminates.
* **Role Check:** 
  * If `sending_institution` = 'Genos Bank' (this bank) -> routes to **Ordering Track**.
  * If `receiving_institution` = 'Genos Bank' (this bank) -> routes to **Beneficiary Track**.
  * Else -> routes to **Intermediary Track**.

### 5.2 Flow 2: Ordering Track (Phase 1)
* **CDD Validation:** Verifies that the originator's customer record exists and is active.
* **Field Completeness Check:**
  * For **Individual** transfers: checks that Originator Name, Account Reference, CNIC/Passport, and Beneficiary Name/Account are populated.
  * For **Batch** transfers: checks that Originator Account/Reference and Beneficiary details are populated.
* **Intake Gate:**
  * If any field is missing -> status is updated to `REJECTED` and returns `400 BAD_REQUEST`. Outgoing transfer is preventively blocked.
  * If all fields are present -> status is updated to `SENT` and returns `200 OK`.

### 5.3 Flow 3: Intermediary Track (Phase 2)
* **Completeness Check:** Inspects incoming message fields.
* **Routing Gate:**
  * If complete -> status updated to `EXECUTED` (forwarded exactly as received) and returns `200 OK`.
  * If incomplete -> status updated to `HELD_COMPLETENESS`, logs a hold reason in `wire_transfer_holds`, sends email alert to compliance, and returns `202 HELD`.

### 5.4 Flow 4: Beneficiary Track (Phase 3)
* **Beneficiary CDD:** Checks if local beneficiary has completed CDD.
* **Completeness Check:** Checks if incoming originator fields are complete.
* **Routing Gate:**
  * If CDD is complete and fields are present -> status updated to `EXECUTED` (funds credited) and returns `200 OK`.
  * If incomplete or CDD failed -> status updated to `HELD_COMPLETENESS`, logs hold reason, sends email alert, and returns `202 HELD`.

### 5.5 Flow 5: Analyst Hold Review & Action Gating
* **Intake:** Analyst submits action (`APPROVED_RELEASE` / `APPROVED_REJECT` / `SUSPENDED_STR_ESCALATION`) and mandatory rationale.
* **Escalation Gating:**
  * If `APPROVED_RELEASE` -> status updated to `EXECUTED` (funds released).
  * If `APPROVED_REJECT` -> status updated to `REJECTED`.
  * If `SUSPENDED_STR_ESCALATION` -> status updated to `SUSPENDED`, flags `flagged_for_str_review = TRUE`, and invokes **UC5 STR intake webhook** (`CROSS_UC_FINDING` trigger) to create an investigation case.
* **Logging & Retention:** Logs decision in `wire_transfer_holds`, updates `wire_transfers.retention_until` to `now() + 10 years`.
