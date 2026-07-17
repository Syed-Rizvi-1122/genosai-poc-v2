# SBP STR & CTR Reporting Pipeline — Use Case 5: Suspicious Transaction & CTR Processing

---

## 1. Professional Introduction
This document outlines the design, architectural framework, and compliance mapping for **Use Case 5 (UC5): Suspicious Transaction Report (STR) Investigation & Currency Transaction Report (CTR) Pipeline**. Built as a core component of the State Bank of Pakistan (SBP) Compliance Automation Sandbox, this system automates the processing of high-volume financial transaction ledgers, coordinates deterministic threshold-based CTR filings, and orchestrates human-gated STR investigations to detect and prevent money laundering, terrorist financing, and proliferation financing.

This implementation translates the regulatory mandates of the **State Bank of Pakistan (SBP) AML/CFT/CPF Regulations** and the **Anti-Money Laundering Act 2010** into a deterministic, config-driven, and audited technology stack. Using **n8n** for workflow orchestration, **PostgreSQL** for state and configuration management, and automated test runners to execute regulatory scenarios, this sandbox replicates the operational reality of a compliance office in a retail bank.

---

## 2. Table of Contents
1. [Professional Introduction](#1-professional-introduction)
2. [Executive Purpose & Regulatory Philosophy](#3-executive-purpose--regulatory-philosophy)
3. [Regulatory Mapping & Reference Matrix](#4-regulatory-mapping--reference-matrix)
4. [Dual-Track Reporting Framework](#5-dual-track-reporting-framework)
5. [Database Schema & Config-Driven Architecture](#6-database-schema--config-driven-architecture)
6. [Flow-by-Flow Technical Architecture](#7-flow-by-flow-technical-architecture)
7. [Nitty-Gritty Node Configuration Details](#8-nitty-gritty-node-configuration-details)
8. [Automated Test Scenarios & Verification](#9-automated-test-scenarios--verification)

---

## 3. Executive Purpose & Regulatory Philosophy

Financial institutions serve as the primary gatekeepers of the formal financial system. The State Bank of Pakistan requires all regulated entities to report transactions that cross specific cash thresholds (CTRs) or that raise suspicion of criminal activity (STRs) to the **Financial Monitoring Unit (FMU)**.

A key operational challenge in compliance engineering is maintaining a strict architectural division between these two reporting tracks:
* **Currency Transaction Reports (CTRs):** Purely deterministic, objective, and threshold-based. There is no compliance discretion; any cash transaction meeting or exceeding the PKR 2,000,000 limit must be verified and filed within the statutory window.
* **Suspicious Transaction Reports (STRs):** Subjective, judgment-based, and human-gated. An STR case must never be auto-filed or auto-closed. It requires deep analyst investigation, written rationales, and compliance officer sign-offs.

Furthermore, STRs are governed by the strict legal principle of **Non-Disclosure (Tipping-off)**. It is a criminal offense to disclose to the customer or unauthorized bank employees that a transaction or account is under investigation. 

**Use Case 5** implements these requirements using a secure, multi-flow compliance framework:
* **Threshold Gating:** Automatically flags cash transactions meeting the config-driven limit.
* **Accuracy Checks:** Holds CTR filings in a review state until data accuracy is manually verified.
* **Multi-Channel STR Triage:** Ingests cases from TMS Alerts, Staff Observations, Cross-UC flags, and CDD failures.
* **Mandatory Rationale Validation:** Prevents decisions from being recorded without written compliance rationales.
* **Confidential Access Auditing:** Implements role-based access checks on STR cases, rejecting non-compliance roles (e.g., Relationship Managers) and logging every access attempt to prevent tipping-off.
* **Anchored Record Retention:** Dynamically calculates retention expiration dates as `GREATEST(last_transaction_date, filing_date) + 10 years` to meet SBP requirements.

---

## 4. Regulatory Mapping & Reference Matrix

The workflow enforces compliance with the following sections of the **AML Act 2010** and the **SBP AML/CFT/CPF Regulations**:

| Regulatory Directive | Clause Reference | Workflow Implementation Mechanism |
| :--- | :--- | :--- |
| **STR Reporting Obligation** | AML Act 2010 §7 / SBP Reg 7 §1 | Ingests alerts, generates cases, and holds them in `PENDING_FIRST_REVIEW` until an analyst and officer approve the filing. |
| **CTR Reporting Obligation** | AML Act 2010 §7 / SBP Reg 7 §2 | Automatically flags cash transactions meeting the config-driven limit (PKR 2M) and files a CTR after verification. |
| **Record Retention** | AML Act 2010 §7D / SBP Reg 8 §3 | Computes retention period dynamically in the database as `10 years` after the transaction or filing date (whichever is later). |
| **Tipping-off Prohibition** | AML Act 2010 §34 / SBP Reg 13 §4(d) | Blocks non-compliance roles from accessing STR cases, returning a `403 ACCESS_DENIED` and logging the audit attempt. |
| **Written Examination** | SBP Reg 2 §21(e) / Reg 12 §6 | Analyst must perform a background and purpose examination, record it in `str_investigation_log`, and write a rationale. |
| **Two-Tier Sign-off** | SBP Reg 5 §1(b) / Reg 12 §6 | Implements analyst recommendations and compliance officer sign-off approval loops before final submission. |
| **Tip-off Risk CDD Bypass** | SBP Reg 7 §1(d) / AML Act §7D(2) | If proceeding with CDD would tip off the customer, the system bypasses CDD and fast-tracks the case to `RECOMMENDED_FOR_FILING`. |

---

## 5. Dual-Track Reporting Framework

To ensure operational integrity and satisfy regulatory guidelines, the pipelines are divided into two distinct tracks:

```
                            ┌──────────────────────────────────┐
                            │    UC5 Ledgers & Intake Gate     │
                            └────────────────┬─────────────────┘
                                             │
                   ┌─────────────────────────┴─────────────────────────┐
                   ▼                                                   ▼
       ┌────────────────────────┐                          ┌────────────────────────┐
       │   CTR Pipeline Track   │                          │   STR Pipeline Track   │
       └───────────┬────────────┘                          └───────────┬────────────┘
                   │                                                   │
     Is Cash >= PKR 2,000,000?                             TMS / Staff Obs / CDD Fail?
                   │                                                   │
        ┌──────────┴──────────┐                             ┌──────────┴──────────┐
        ▼                     ▼                             ▼                     ▼
     [ Yes ]               [ No ]                 [ CDD Tip-off Risk ]    [ Normal Alert ]
        │                     │                             │                     │
  flag candidate        bypassed / end               fast-track filing     analyst triage
        │                                                   │                     │
  verify accuracy                                     officer sign-off     analyst investigation
        │                                                   │                     │
   fmu filing                                           fmu filing         officer sign-off
```

---

## 6. Database Schema & Config-Driven Architecture

The database schema extends the core onboarding and screening database with tables to manage the reporting pipelines:

```
                              ┌──────────────────────┐
                              │     transactions     │
                              └──────────┬───────────┘
                                         │
                ┌────────────────────────┴────────────────────────┐
                ▼                                                 ▼
    ┌──────────────────────┐                          ┌──────────────────────┐
    │    ctr_candidates    │                          │  str_case_triggers   │
    └──────────┬───────────┘                          └──────────┬───────────┘
               │                                                 │
    ┌──────────────────────┐                          ┌──────────────────────┐
    │     ctr_filings      │                          │      str_cases       │
    └──────────────────────┘                          └──────────┬───────────┘
                                                                 │
                                                ┌────────────────┼────────────────┐
                                                ▼                ▼                ▼
                                     ┌──────────────────────┐ ┌──────┴───────┐ ┌──┴───┐
                                     │str_investigation_log │ │str_access_log│ │filing│
                                     └──────────────────────┘ └──────────────┘ └──────┘
```

### 6.1 Schema Definition (`005_uc5_schema.sql`)
* **`regulatory_thresholds_config`**: Contains the configuration settings for CTR limits and retention parameters.
* **`transactions`**: Financial ledger capturing cash/wire inputs.
* **`ctr_candidates`**: Holds auto-flagged cash transactions awaiting validation.
* **`ctr_filings`**: Completed currency filings containing FMU mock references and retention deadlines.
* **`str_case_triggers`**: Records the entry source (e.g. CDD Failure) and flexible payload details.
* **`str_cases`**: Core case record storing status, triage scores, and confidentiality flags.
* **`str_investigation_log`**: Records analyst review details, including background examination and narrative drafts.
* **`str_analyst_decisions`**: Analyst recommendations (`FILE_STR` / `CLOSE_NOT_SUSPICIOUS`) with mandatory check-constrained rationales.
* **`str_compliance_officer_signoff`**: Second-tier decision details (`APPROVED` / `RETURNED_FOR_REVISION`).
* **`str_filings`**: Submissions containing the retention schedule.
* **`str_access_log`**: Audit log capturing who viewed the cases (RM, Analyst, Officer) to detect tipping-off.

---

## 7. Flow-by-Flow Technical Architecture

### 7.1 CTR Pipeline
1. **Intake Flow:** 
   * `Webhook — Transaction Intake` receives transaction details via `POST`.
   * `Insert Transaction` writes the ledger entry to the database.
   * `Lookup CTR Threshold` reads the configuration table.
   * `IF: Cash Transaction?` validates the transaction type.
   * `IF: Amount >= Threshold?` compares transaction values.
   * `Insert CTR Candidate` writes flagged records.
   * `Send Email` notifies the compliance queue.
2. **Filing Flow:**
   * `Webhook — CTR Verify` receives the review check from compliance.
   * `Update Status` writes the decision (`VERIFIED`).
   * `IF: Data Verified?` routes validated filings.
   * `Insert CTR Filing` generates FMU reference numbers and retention deadlines.
   * `Send Email` sends the filing confirmation.

### 7.2 STR Investigation Pipeline
1. **Triage Flow:**
   * Ingests entries from four webhook triggers (TMS, Manual, Cross-UC, CDD).
   * `Merge` node consolidates the entry points.
   * `Insert Case Trigger` records the source event.
   * `Generate Case Ref` calculates reference numbers and fast-tracks CDD bypass cases.
   * `Compute Triage Score` determines the priority score.
   * `Send Email` alerts the compliance officer.
2. **Analyst Actions:**
   * `Webhook — Analyst Action` receives investigation notes or final decisions.
   * `Validate Analyst Role` rejects front-line staff attempts.
   * `IF: Action = Investigate?` paths the request.
   * `Insert Rationale Provided?` blocks decisions submitted with empty strings.
   * `Insert Analyst Decision` writes recommendations.
3. **Officer Sign-off:**
   * `Webhook — Officer Sign-Off` receives approvals or rejections.
   * `IF: Officer Approved?` paths decisions.
   * `Update Case — Returned` handles re-revision states.
   * `Insert STR Filing` calculates final retention schedules and logs submissions.

---

## 8. Nitty-Gritty Node Configuration Details

* **Node Count:** 76 nodes across 2 workflows (6 flows total).
* **SMTP Credentials:** Integrates with the Gmail sandbox SMTP credentials (`8Rb60oaV0VVNTtzH`) to send rich, HTML-formatted email alerts at case creation and filing checkpoints.
* **PostgreSQL Nodes:** All DB transactions reuse the centralized `AML Postgres` credential (`jAJgSFNohrcTMvPV`).
* **Validation Nodes:** Implements `IF` nodes configured with `"Convert types where required"` set to **ON** to prevent type mismatch crashes when comparing database string types with JavaScript number types.

---

## 9. Automated Test Scenarios & Verification

Verification is performed using automated scripts located in `tests/uc5_str_ctr/`:

```bash
# 1. CTR cash above threshold (Flagged & Filed)
./tests/uc5_str_ctr/test_uc5_ctr.sh tests/uc5_str_ctr/payloads/01_cash_above_threshold.json

# 2. CTR cash below threshold (Bypassed)
./tests/uc5_str_ctr/test_uc5_ctr.sh tests/uc5_str_ctr/payloads/02_cash_below_threshold.json

# 3. STR TMS alert investigation & close (No suspicion)
./tests/uc5_str_ctr/test_uc5_str.sh tests/uc5_str_ctr/payloads/03_tms_alert_close.json

# 4. STR Manual Staff Observation -> Investigate -> Approve & File STR
./tests/uc5_str_ctr/test_uc5_str.sh tests/uc5_str_ctr/payloads/04_manual_observation.json

# 5. Access control check blocks Relationship Manager (RM)
./tests/uc5_str_ctr/test_uc5_str.sh tests/uc5_str_ctr/payloads/05_access_denied_frontline.json

# 6. Analyst decision fails when empty rationale is submitted
./tests/uc5_str_ctr/test_uc5_str.sh tests/uc5_str_ctr/payloads/06_empty_rationale_reject.json

# 7. Officer returns case to analyst for revision
./tests/uc5_str_ctr/test_uc5_str.sh tests/uc5_str_ctr/payloads/07_officer_returns_revision.json
```

All 7 compliance scenarios run successfully against the workflows, validating proper data storage, accurate retention calculations, role-based security, and regulatory compliance.
