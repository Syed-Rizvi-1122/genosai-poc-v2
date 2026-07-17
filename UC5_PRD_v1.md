# PRD: UC5 — Suspicious Transaction Investigation & STR/CTR Pipeline (POC)
**GenosAI AML/CFT/CPF Compliance Automation — Final Year Project**
**Target build tool:** Google Antigravity IDE
**Stack:** n8n (Docker) + PostgreSQL (Docker)
**Status:** v1 — Phase 1 (POC) scope
**Design principle:** CTR and STR are two genuinely separate tracks — a mandatory deterministic filing vs. a judgment-based investigation. Do not merge them into one pipeline.

---

## 1. Objective

Build two coordinated but structurally distinct n8n workflows:
1. **CTR track** — deterministic threshold-check → data compile → human accuracy-check → file → retain.
2. **STR track** — multi-source trigger → case build → 100%-human-reviewed investigation → confidentiality-gated approval chain → file → retain.

## 2. Scope

### 2.1 In scope
- CTR: threshold evaluation (as a configurable value, not hardcoded), data compilation, human accuracy check, filing record, retention tracking.
- STR: multi-trigger case creation, human-only triage queue (no auto-close of any severity), investigation logging, LLM-assisted (human-reviewed) narrative drafting placeholder, access-controlled confidentiality model, two-tier approval (analyst + compliance officer), filing record, retention tracking.
- Explicit "unknown value" handling for CTR threshold and STR/CTR filing deadlines — stored as configuration, clearly marked TBD, sourced from AML Act 2010 §7 or FMU circular (not available in the uploaded Regulations document).

### 2.2 Out of scope for this POC
- Real FMU e-reporting portal integration (mock the filing submission — log it, don't actually transmit).
- Real TMS pattern-detection engine (POC uses a simplified rule: e.g. transaction > configurable amount OR customer flagged from another UC as a stand-in trigger).
- Actual row-level security/DB permissions enforcement (document the access-control design in Section 6, but for a POC a simpler "restricted_view" flag + application-layer filtering is acceptable — full RLS is a production hardening step).

---

## 3. Actors

| Actor | Role |
|---|---|
| Teller/Branch System | Source of cash transactions (CTR trigger) |
| TMS (simplified, mocked) | Source of pattern/threshold alerts (STR trigger) |
| Compliance Analyst | Reviews every STR case (100%, no exceptions), investigates, drafts/edits narrative |
| Compliance Officer | Second-tier sign-off before any STR filing |
| Front-line/Relationship Manager | Explicitly must NOT have visibility into STR case status (access-control target) |
| System (n8n) | Orchestrates both tracks, enforces the human-gates, never auto-decides an STR outcome |

---

## 4. Database Schema (PostgreSQL)

```sql
-- ============================================
-- SHARED CONFIG (both tracks)
-- ============================================

-- Explicit config table for regulator-set numbers — now populated with SOURCED, VERIFIED values.
CREATE TABLE regulatory_thresholds_config (
    id SERIAL PRIMARY KEY,
    config_key VARCHAR(50) UNIQUE NOT NULL,   -- 'CTR_THRESHOLD_PKR','STR_FILING_DEADLINE','CTR_FILING_DEADLINE_DAYS'
    config_value NUMERIC,
    config_value_text VARCHAR(50),             -- for non-numeric values like STR's "promptly"
    is_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
    source_note TEXT
);
-- Seed values (sourced 17-Jul-2026, verify against current FMU circulars before production use):
-- ('CTR_THRESHOLD_PKR', 2000000, NULL, TRUE, 'FMU Guidelines for Filing CTRs; threshold per FMU notification dated 21-Jan-2015 under AML Act 2010 s.7')
-- ('CTR_THRESHOLD_PKR_EXCHANGE_COMPANY_AGGREGATE', 2000000, NULL, TRUE, 'CTR-A variant for ECs: multi-currency transactions AGGREGATING to PKR 2M+, per same FMU guidelines')
-- ('CTR_FILING_DEADLINE_DAYS', 7, NULL, TRUE, 'AML Act 2010 s.7(3): "not later than seven working days" after the currency transaction')
-- ('STR_FILING_DEADLINE', NULL, 'PROMPTLY_NO_FIXED_DAYS', TRUE, 'AML Act 2010 s.7(1) proviso: "STRs shall be filed... promptly" — no fixed day-count specified in the Act')
-- ('RECORD_RETENTION_YEARS_STR_CTR', 10, NULL, TRUE, 'NOTE: Act s.7(4) anchors this to "after reporting of transaction"; SBP Reg 8 §3 anchors it to "completion of the transaction" — these are different anchor dates. Use the LATER of the two computed dates to satisfy both.')

-- ============================================
-- CTR TRACK
-- ============================================

CREATE TABLE transactions (
    id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,               -- FK to UC1's customers.id
    account_id INT,                          -- FK to UC1's accounts.id
    transaction_type VARCHAR(30),            -- 'CASH_DEPOSIT','CASH_WITHDRAWAL','WIRE','OTHER'
    amount NUMERIC(18,2) NOT NULL,
    currency VARCHAR(10) DEFAULT 'PKR',
    branch_code VARCHAR(20),
    channel VARCHAR(30),                     -- 'BRANCH_TELLER','ATM','DIGITAL'
    executed_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE ctr_candidates (
    id SERIAL PRIMARY KEY,
    transaction_id INT REFERENCES transactions(id),
    threshold_applied NUMERIC,                -- snapshot of regulatory_thresholds_config value at flag-time, for audit
    flagged_at TIMESTAMP NOT NULL DEFAULT now(),
    -- deterministic — no review_status enum needed for "should we file", only for data accuracy:
    data_accuracy_status VARCHAR(20) DEFAULT 'PENDING_CHECK', -- PENDING_CHECK, VERIFIED, CORRECTION_NEEDED
    verified_by VARCHAR(100),
    verified_at TIMESTAMP
);

CREATE TABLE ctr_filings (
    id SERIAL PRIMARY KEY,
    ctr_candidate_id INT REFERENCES ctr_candidates(id),
    filed_at TIMESTAMP,
    filing_reference VARCHAR(50),             -- mock FMU submission reference
    retention_until DATE                       -- computed = transaction executed_at + 10 years, Reg 8 §3
);

-- ============================================
-- STR TRACK
-- ============================================

CREATE TABLE str_case_triggers (
    id SERIAL PRIMARY KEY,
    trigger_type VARCHAR(30) NOT NULL,        -- 'TMS_ALERT','MANUAL_STAFF_OBSERVATION','CROSS_UC_FINDING','CDD_FAILURE_OR_TIPOFF_RISK'
    trigger_subtype VARCHAR(30),               -- for CDD_FAILURE_OR_TIPOFF_RISK only: 'CDD_INCOMPLETE_S7D1' or 'CDD_WOULD_TIPOFF_S7D2'
    source_reference VARCHAR(100),            -- e.g. a UC3 pep_designation_id, a TMS alert id, or a note referencing the UC1 case (manual, not FK-linked)
    customer_id INT NOT NULL,                 -- FK to UC1's customers.id
    triggered_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE str_cases (
    id SERIAL PRIMARY KEY,
    trigger_id INT REFERENCES str_case_triggers(id),
    case_ref VARCHAR(30) UNIQUE NOT NULL,
    customer_id INT NOT NULL,
    -- triage score exists ONLY for queue ordering, never for auto-deciding anything:
    triage_severity_score NUMERIC(5,2),
    -- review_status is the single source of truth; nothing here auto-resolves:
    review_status VARCHAR(30) NOT NULL DEFAULT 'PENDING_FIRST_REVIEW',
    -- PENDING_FIRST_REVIEW, UNDER_INVESTIGATION, NEEDS_MORE_INFO, CLOSED_NOT_SUSPICIOUS, RECOMMENDED_FOR_FILING
    -- CONFIDENTIALITY FLAG — this is what drives the access-control gate:
    is_confidential BOOLEAN NOT NULL DEFAULT TRUE,   -- TRUE from case creation; controls visibility (see Section 6)
    opened_at TIMESTAMP NOT NULL DEFAULT now(),
    closed_at TIMESTAMP
);

CREATE TABLE str_investigation_log (
    id SERIAL PRIMARY KEY,
    str_case_id INT REFERENCES str_cases(id),
    analyst_name VARCHAR(100),
    transaction_history_reviewed JSONB,        -- snapshot of relevant transactions pulled in
    background_purpose_findings TEXT,           -- Reg 2 §21(e) "as far as possible" examination notes
    narrative_draft TEXT,                        -- LLM-assisted draft, human-editable
    narrative_edited_by_human BOOLEAN DEFAULT FALSE,
    logged_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE str_analyst_decisions (
    id SERIAL PRIMARY KEY,
    str_case_id INT REFERENCES str_cases(id),
    decision VARCHAR(30) NOT NULL,             -- 'FILE_STR','CLOSE_NOT_SUSPICIOUS','NEEDS_MORE_INFO'
    rationale TEXT NOT NULL,                    -- mandatory even for "close" decisions
    decided_by VARCHAR(100) NOT NULL,
    decided_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE str_compliance_officer_signoff (
    id SERIAL PRIMARY KEY,
    str_case_id INT REFERENCES str_cases(id),
    decision VARCHAR(20) NOT NULL,             -- 'APPROVED','RETURNED_FOR_REVISION'
    officer_name VARCHAR(100) NOT NULL,
    comments TEXT,
    decided_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE str_filings (
    id SERIAL PRIMARY KEY,
    str_case_id INT REFERENCES str_cases(id),
    filed_at TIMESTAMP,
    filing_reference VARCHAR(50),
    retention_until DATE                        -- computed = last reviewed transaction's date + 10 years, Reg 8 §3
);

-- Access log — every read of a confidential STR case gets logged, so tipping-off
-- can be audited/detected even at the application layer (POC-level control, not full RLS).
CREATE TABLE str_access_log (
    id SERIAL PRIMARY KEY,
    str_case_id INT REFERENCES str_cases(id),
    accessed_by VARCHAR(100),
    accessed_by_role VARCHAR(50),               -- must be 'COMPLIANCE_ANALYST' or 'COMPLIANCE_OFFICER' — anything else is a violation to flag
    accessed_at TIMESTAMP NOT NULL DEFAULT now()
);
```

### 4.1 Seed data required
- `regulatory_thresholds_config`: 3 rows, `is_confirmed = FALSE`, `config_value = NULL` — deliberately incomplete, do not fill with a guessed number.
- `transactions`: a handful of demo transactions, some above/below an arbitrarily-chosen *demo-only* threshold you set locally for testing (clearly label this as a test value, not the real regulatory figure, in your demo narration).

---

## 5. n8n Workflow — Step-by-Step

### 5A. CTR Track

1. **Postgres Trigger / Cron polling node** — watches new rows in `transactions` (or webhook from a mock teller system).
2. **Postgres Node — Lookup** `regulatory_thresholds_config` for `CTR_THRESHOLD_PKR` (confirmed value: PKR 2,000,000, per FMU notification dated 21-Jan-2015). For Exchange Companies specifically, also check `CTR_THRESHOLD_PKR_EXCHANGE_COMPANY_AGGREGATE` for multi-currency transactions that aggregate to PKR 2M+ even if no single currency leg alone crosses the threshold.
3. **IF Node** — `transaction.amount >= threshold` and `transaction_type` involves cash → **Postgres Node — Insert** into `ctr_candidates`.
4. **Postgres Node** — compile required fields into a structured payload (Function node formats it FMU-style — exact format TBD from FMU's own template, not in this document).
5. **Webhook/Form node** — compliance officer confirms data accuracy → **Postgres Node — Update** `ctr_candidates.data_accuracy_status = 'VERIFIED'`.
6. **IF Node** — if `CORRECTION_NEEDED` → loop back to Step 4 with corrected data.
7. **Postgres Node — Insert** into `ctr_filings` (mock `filing_reference`, compute `retention_until = transaction.executed_at + 10 years`).

### 5B. STR Track

8. **Four trigger entry points (Webhook nodes):**
   - TMS alert webhook → `trigger_type = 'TMS_ALERT'`
   - Manual staff-observation form webhook → `trigger_type = 'MANUAL_STAFF_OBSERVATION'`
   - Cross-UC finding webhook (e.g. called from UC3's workflow when a PEP source-of-wealth gap looks serious) → `trigger_type = 'CROSS_UC_FINDING'`
   - **CDD failure / tip-off-risk form webhook (AML Act 2010 s.7D)** → `trigger_type = 'CDD_FAILURE_OR_TIPOFF_RISK'`, with `trigger_subtype` set to `'CDD_INCOMPLETE_S7D1'` (CDD couldn't be completed — relationship not opened/terminated, STR must be promptly considered) or `'CDD_WOULD_TIPOFF_S7D2'` (pursuing CDD itself would tip off the customer — CDD is skipped, STR filed directly). **This is a manual entry point, not wired to UC1's workflow** — a compliance analyst raises it directly, regardless of where the underlying CDD situation happened.
9. **Postgres Node — Insert** into `str_case_triggers`, then **Insert** into `str_cases` (`review_status = 'PENDING_FIRST_REVIEW'`, `is_confidential = TRUE` by default). **Exception:** if `trigger_subtype = 'CDD_WOULD_TIPOFF_S7D2'`, the suspicion is already legally established at trigger time (that's what s.7D(2) means) — this case should skip straight to `review_status = 'RECOMMENDED_FOR_FILING'` after a lightweight analyst confirmation (Step 12-14 still run, but the `'CLOSE_NOT_SUSPICIOUS'` outcome should not be offered for this subtype, since the Act itself already establishes the suspicion — the only open question is filing mechanics, not whether to file.
10. **Postgres Node** — aggregate customer profile + transaction history (pull from UC1 tables + `transactions`) into a case-context payload.
11. **Function Node** — compute `triage_severity_score` (simple rule-based scoring for POC — document your rubric). **This score is written to the case for queue-sorting only — no branch in the workflow reads it to auto-close anything.**
12. **Webhook/Form node (analyst-facing)** — analyst opens the case (this read event **must** be logged: **Postgres Node — Insert** into `str_access_log` with `accessed_by_role` validated as `'COMPLIANCE_ANALYST'`).
13. **Webhook/Form node** — analyst submits investigation findings → **Postgres Node — Insert** into `str_investigation_log` (including narrative — if LLM-drafted, `narrative_edited_by_human` must be confirmable, not just assumed).
14. **Webhook/Form node** — analyst submits final decision → **Postgres Node — Insert** into `str_analyst_decisions`. `rationale` is a required field at the DB level (NOT NULL) — cannot submit a decision without one, for any outcome including "close."
15. **IF Node** — `decision = 'CLOSE_NOT_SUSPICIOUS'` → **Postgres Node — Update** `str_cases.review_status = 'CLOSED_NOT_SUSPICIOUS'`, `closed_at = now()`. End of this case's path (still logged, still human-reviewed — not the same as the removed "auto-close").
16. **IF Node** — `decision = 'NEEDS_MORE_INFO'` → case stays open, loops back to Step 13.
17. **IF Node** — `decision = 'FILE_STR'` → **Postgres Node — Update** `str_cases.review_status = 'RECOMMENDED_FOR_FILING'`, proceed to Step 18.
18. **Webhook/Form node (compliance-officer-facing only — access-gated)** — officer opens case (logged to `str_access_log` with role validated as `'COMPLIANCE_OFFICER'`), submits sign-off → **Postgres Node — Insert** into `str_compliance_officer_signoff`.
19. **IF Node** — `decision = 'RETURNED_FOR_REVISION'` → loops back to Step 13 with officer's comments attached.
20. **IF Node** — `decision = 'APPROVED'` → **Postgres Node — Insert** into `str_filings` (mock `filing_reference`, compute `retention_until`).

### Access-control enforcement note (Step 12, 18, and any future dashboard)
Any n8n node or downstream application view that serves case data to a "front-line/relationship-manager" role must **explicitly filter out** any `str_cases` row where `is_confidential = TRUE`. For the POC, implement this as an application-layer check (Function node validating the requester's role before returning data) — document in your write-up that production would harden this with real Postgres row-level security policies.

---

## 6. Test Scenarios

1. **Cash transaction above the local demo threshold** → CTR track flags automatically, no human judgment on the "should we file" decision, only on data accuracy.
2. **Cash transaction below threshold** → correctly not flagged.
3. **TMS-alert-triggered STR case, analyst reviews and decides "close, not suspicious"** → confirms case is closed via human decision (logged with rationale), not silently auto-dropped.
4. **Manually-observed suspicious activity (no TMS alert at all)** → confirms STR track works from non-TMS trigger sources.
5. **A simulated front-line/relationship-manager role attempts to view an `is_confidential = TRUE` case** → must be blocked/filtered; this test specifically validates the tipping-off control exists.
6. **Analyst submits a "close" decision with an empty rationale** → should fail at the DB constraint level (`NOT NULL` on `rationale`), proving the mandatory-documentation rule is enforced, not just suggested.
7. **Compliance officer returns a case for revision** → loops back correctly, doesn't silently file.

---

## 7. Traceability

| PRD Section | Regulation / Definition |
|---|---|
| CTR deterministic flagging | Reg 7 (file per Act §7) — exact threshold sourced externally, not in this doc |
| TMS as STR trigger source | Reg 12 §6 (previously missing from blueprint's citation list) |
| Investigation "as far as possible" | Reg 2 §21(e) — corrected citation (blueprint said Reg 1 §21(e), doesn't exist) |
| Confidentiality/access control | Reg 13 §4(d) — tipping-off prohibition, applies to STR specifically, not CTR |
| 10-year retention (both tracks) | Reg 8 §3 |
| Human-only review, no auto-close | Your team's own design principle + general prudence given STR's legal weight |
| CDD-failure / CDD-would-tipoff triggers | AML Act 2010 s.7D(1) and s.7D(2) — deliberately not wired to UC1 in this POC, manual trigger entry point only |

---

## 8. Notes for Antigravity

- Do NOT hardcode a CTR threshold or STR/CTR filing deadline anywhere in code — always read from `regulatory_thresholds_config`, and keep `is_confirmed = FALSE` visible/loud (e.g., a startup warning log) until a real project member updates it with a sourced value.
- Do NOT implement any workflow path that closes or files an STR case without a human-submitted decision logged in `str_analyst_decisions` or `str_compliance_officer_signoff`.
- Treat `is_confidential` on `str_cases` as a hard filter, not a UI-only suggestion — any query serving case lists to a non-compliance role must exclude confidential rows at the query level.
