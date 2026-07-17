# Wire Transfer Compliance Engine — Use Case 8: Wire Transfer Data Completeness & Compliance

---

## 1. Professional Introduction
This document outlines the design, architectural framework, and compliance mapping for **Use Case 8 (UC8): Wire Transfer Data Completeness & Compliance Engine**. Built as a core component of the State Bank of Pakistan (SBP) Compliance Automation Sandbox, this system automates the verification, routing, and gating of wire transfers in real time. It dynamically identifies the bank's role per transaction (Ordering, Intermediary, or Beneficiary), enforces specific data completeness policies, implements interbank settlement exemptions, and manages analyst hold review actions, including Suspicious Transaction Report (STR) escalations.

This implementation translates the regulatory mandates of **Regulation 11 of the State Bank of Pakistan (SBP) AML/CFT/CPF Regulations** into a deterministic, config-driven, and fully audited technology stack. Using **n8n** for unified workflow orchestration, **PostgreSQL** for state tracking, logs, and ledger management, and automated test runners to execute regulatory scenarios, this sandbox replicates the compliance gatekeeping required of retail banks.

---

## 2. Table of Contents
1. [Professional Introduction](#1-professional-introduction)
2. [Executive Purpose & Regulatory Philosophy](#3-executive-purpose--regulatory-philosophy)
3. [Regulatory Mapping & Reference Matrix](#4-regulatory-mapping--reference-matrix)
4. [Wire Transfer Role-Based Policy Matrix](#5-wire-transfer-role-based-policy-matrix)
5. [Database Schema & Retention Rules](#6-database-schema--retention-rules)
6. [Flow-by-Flow Technical Architecture](#7-flow-by-flow-technical-architecture)
7. [Nitty-Gritty Node Configuration Details](#8-nitty-gritty-node-configuration-details)
8. [Automated Test Scenarios & Verification](#9-automated-test-scenarios--verification)

---

## 3. Executive Purpose & Regulatory Philosophy

Wire transfers represent one of the highest risk channels for rapid cross-border and domestic movement of illicit funds. SBP AML/CFT/CPF Regulation 11 establishes strict standards to prevent money launderers and terrorist financiers from using wire transfers anonymously. The regulation places different compliance obligations on financial institutions depending on where they sit in the payment chain.

A key operational challenge in compliance engineering is dynamically routing transactions through these distinct policy layers in real time:
* **Exemptions for Interbank Positions:** Under §1, settlement transfers between SBP regulated entities acting on their own behalf are exempt from originator and beneficiary data verification.
* **Preventative Gatekeeping for Ordering Banks:** Under §2 and §3, when acting as the Ordering Institution, the bank must block any transfer *before* it leaves the bank if required customer data is missing or CDD is incomplete. It is a hard block (returns HTTP 400).
* **Hold Gating for Intermediary/Beneficiary Banks:** Under §4, §5, and §7, when acting as an Intermediary or Beneficiary Institution, the bank cannot prevent the sending bank from initiating the transfer. If incoming data is incomplete, the bank must place the funds on hold (`HELD_COMPLETENESS`), log the correspondent bank's failure rates, alert compliance, and allow an analyst to release, reject, or escalate the hold to an STR case (cross-UC integration).
* **Anchored Record Retention:** Under §9, all wire transfer data must be archived and retrievable for at least **10 years** from the value date.

UC8 implements these requirements in a single, cohesive n8n workflow canvas with two independent entry triggers, ensuring that no transfer escapes compliance checks and that every hold is audited.

---

## 4. Regulatory Mapping & Reference Matrix

The compliance engine enforces strict alignment with **SBP AML/CFT/CPF Regulation 11**:

| Regulatory Directive | Clause Reference | Workflow Implementation Mechanism |
| :--- | :--- | :--- |
| **Interbank Exemption** | Reg 11 §1 | Bypasses checks if `sending_institution` and `receiving_institution` are REs and the transfer is on their own behalf. Sets status directly to `EXECUTED`. |
| **CDD Pre-requisite** | Reg 11 §2(a) | Outgoing transfers require the originator's CDD to be in `APPROVED` status. Incomplete CDD results in a hard block. |
| **Ordering Field Completeness** | Reg 11 §2(b) & §3 | Outgoing individual transfers must contain Originator (Name, Account, Doc ID) and Beneficiary (Name, Account). Outgoing batch transfers require verified account numbers. |
| **Intermediary Field Preservation** | Reg 11 §4 & §5 | Intermediary transfers must forward all received originator and beneficiary fields. Missing fields trigger `HELD_COMPLETENESS` and log correspondent failure. |
| **Beneficiary Verification & CDD** | Reg 11 §7 | Beneficiary bank must verify receiving customer CDD. Incomplete CDD or missing originator data triggers a hold status. |
| **Record Retention** | Reg 11 §9 | Computes the retention expiration date dynamically in the database as exactly `10 years` after the value date for all executed transfers. |
| **Analyst Gate Action & STR Escalation** | Reg 11 §8 | Analyst Hold Gate allows releasing, rejecting, or suspending the hold. Suspend action escalates to UC5 STR via HTTP webhook call. |

---

## 5. Wire Transfer Role-Based Policy Matrix

The workflow utilizes the transaction metadata to determine the bank's role:

```
                            ┌────────────────────────────────────┐
                            │      Ingest Wire payload via       │
                            │   POST /webhook/uc8-wire-intake    │
                            └─────────────────┬──────────────────┘
                                              │
                                   [IF: Interbank Exemption?]
                                     ├── Yes ──► [Set EXEMPT] ──► (200 OK)
                                     └── No
                                              │
                                    [Switch: Role Router]
                                              │
                      ┌───────────────────────┼───────────────────────┐
                      ▼                       ▼                       ▼
               [ ORDERING ]            [ INTERMEDIARY ]        [ BENEFICIARY ]
              (Outgoing Tx)            (Forwarding Tx)          (Incoming Tx)
                      │                       │                       │
               Check CDD &             Check Received          Check Beneficiary
             Complete Fields          Fields Complete           CDD Onboarding
                      │                       │                       │
               Fail: Hard Block        Fail: Log Hold &        Fail: Log Hold &
                  (400 Bad)           Alert (202 Accept)      Alert (202 Accept)
```

---

## 6. Database Schema & Retention Rules

The schema definition (`007_uc8_schema.sql`) implements the data tracking structures:
* **`wire_transfers`**: Financial ledger containing transaction metadata, direction, SBP exemption flags, CDD blocks, and the calculated `retention_until` timestamp.
* **`wire_transfer_holds`**: Captures held transactions, roles, specific hold reasons, analyst reviews, and rationales.
* **`correspondent_completeness_logs`**: Logs correspondent banks that transmit incomplete payments, maintaining failure statistics for risk-rating.

### 6.1 Retention Expiration Formula
Upon successful execution (`SENT` or `EXECUTED`), the database calculates the retention limit as:
$$\text{retention\_until} = \text{value\_date} + \text{interval '10 years'}$$

---

## 7. Flow-by-Flow Technical Architecture

### 7.1 Flow A: Intake & Gateway
1. **Intake Webhook (Node 1):** Receives the payload via `POST /webhook/uc8-wire-intake`.
2. **Ledger Ingestion (Node 2):** Inserts the transfer record in `PENDING_CHECK` state. Uses `.body.` parameter mapping.
3. **Exemption Check (Node 3):** Evaluates if the transfer is an own-behalf settlement between SBP member banks. If true, updates status to `EXECUTED` (Node 4) and returns HTTP 200 (Node 5).
4. **Role Routing (Node 6):** Inspects direction to route to Ordering (`0`), Intermediary (`1`), or Beneficiary (`2`) tracks.
5. **Ordering Track (Nodes 7–16):**
   * Verifies originator CDD status is `APPROVED`.
   * Checks field completeness (Individual vs. Batch) via Javascript.
   * If checks pass, sets status to `SENT` with a 10-year retention date and returns HTTP 200.
   * If checks fail, sets status to `REJECTED` and returns HTTP 400 Bad Request.
6. **Intermediary Track (Nodes 17–25):**
   * Verifies received fields are complete.
   * If complete, sets status to `EXECUTED` (Forwarded) with retention and returns HTTP 200.
   * If incomplete, sets status to `HELD_COMPLETENESS`, logs a review hold, logs correspondent bank failure, triggers a styled email notification, and returns HTTP 202 Accepted.
7. **Beneficiary Track (Nodes 26–36):**
   * Verifies beneficiary CDD status is `APPROVED`.
   * Verifies originator details are complete.
   * If complete, sets status to `EXECUTED` (Credited) and returns HTTP 200.
   * If CDD is incomplete or details are missing, sets status to `HELD_COMPLETENESS`, logs a hold, alerts compliance, and returns HTTP 202.

### 7.2 Flow B: Analyst Hold Action Gate
1. **Analyst Action Webhook (Node 37):** Ingests reviewer name, decision, and rationale via `POST /webhook/uc8-analyst-action`.
2. **Lookup Details (Node 38):** Joins the hold and transfer details. Uses `.body.` mapping to identify the hold ID.
3. **Switch Gating (Node 39):** Routes by action parameter:
   * **`APPROVED_RELEASE`:** Updates hold to released (Node 40), updates transfer to `EXECUTED` (Node 41), and returns HTTP 200 (Node 42).
   * **`APPROVED_REJECT`:** Updates hold to rejected (Node 43), terminates transfer to `REJECTED` (Node 44), and returns HTTP 200 (Node 45).
   * **`SUSPENDED_STR_ESCALATION`:** Updates hold to suspended (Node 46), updates transfer to `SUSPENDED` (Node 47), makes an HTTP POST request to the UC5 STR intake webhook (Node 48) to trigger an automated case (`CROSS_UC_FINDING`), and returns HTTP 200 (Node 49).

---

## 8. Nitty-Gritty Node Configuration Details

* **Node Count:** 49 nodes on a single canvas across 2 triggers.
* **Credentials:**Centralizes DB operations via `AML Postgres` and alerts via `AML SMTP`.
* **Webhook Body Parsing:** Utilizes the mandatory `.body` prefix (e.g. `{{ $json.body.transaction_ref }}`) on Webhook nodes (Node 1 and Node 37) to handle n8n's parsed request object structure.
* **Database CASE Gating:** In Node 33 (`Insert Hold Record (Beneficiary)`), implements an inline `CASE WHEN` statement to record separate hold reasons depending on whether the hold was caused by beneficiary CDD failure or missing originator data.
* **SMTP Styling:** Node 24 and Node 35 are configured with responsive HTML CSS cards, badges, and structural detail tables to present professional, clean, and legible compliance alerts.

---

## 9. Automated Test Scenarios & Verification

Verification of UC8 compliance routing is performed using the test suite in `tests/uc8_wire_transfers/`:

```bash
# 1. Outgoing Compliant Wire Transfer -> Executed & Sent
./tests/uc8_wire_transfers/test_uc8_wire_transfers.sh tests/uc8_wire_transfers/payloads/01_outgoing_compliant.json

# 2. Outgoing Non-Compliant Wire Transfer -> Preventively Blocked (HTTP 400)
./tests/uc8_wire_transfers/test_uc8_wire_transfers.sh tests/uc8_wire_transfers/payloads/02_outgoing_missing_originator_id.json

# 3. Intermediary Transfer placed on Hold -> Released by Analyst
./tests/uc8_wire_transfers/test_uc8_wire_transfers.sh tests/uc8_wire_transfers/payloads/03_intermediary_hold_release.json

# 4. Beneficiary Transfer placed on Hold -> Escalated to STR (Triggers UC5 cross-finding webhook)
./tests/uc8_wire_transfers/test_uc8_wire_transfers.sh tests/uc8_wire_transfers/payloads/04_beneficiary_escalate_str.json

# 5. Interbank own-behalf settlement position -> Exempted (Reg 11 §1)
./tests/uc8_wire_transfers/test_uc8_wire_transfers.sh tests/uc8_wire_transfers/payloads/05_interbank_settlement_exempt.json
```
