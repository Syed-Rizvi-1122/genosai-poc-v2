# PRD: UC3 — PEP Lifecycle Monitoring & Enhanced Due Diligence (POC)
**GenosAI AML/CFT/CPF Compliance Automation — Final Year Project**
**Target build tool:** Google Antigravity IDE
**Stack:** n8n (Docker) + PostgreSQL (Docker)
**Status:** v1 — Phase 1 (POC) scope
**Scope:** Ongoing/existing-customer PEP discovery only. Onboarding-time PEP screening belongs to UC1 (`pep_screening_results` table, Phase 4 there) and is reused, not duplicated, here.

---

## 1. Objective

Build a rule-driven, human-gated re-screening workflow that continuously monitors already-onboarded customers and their beneficial owners/directors/trustees for newly-acquired PEP status, close-associate links, or family-member links — and enforces mandatory EDD + senior management approval per Regulation 5, with **zero auto-clearing of any match**.

## 2. Scope

### 2.1 In scope
- Periodic (scheduled) and event-triggered re-screening of all existing customers + linked BOs/directors/trustees (pulled from UC1's tables).
- Explicit close-associate (Def #12) and family-member (Def #28) classification logic — not a generic relationship graph.
- Explicit junior/middle-ranking exclusion check (Def #52(d)).
- 100% human review queue for every match (confidence score used only for triage ordering).
- Source-of-wealth/source-of-funds evidence collection and reconciliation (not just a questionnaire).
- Senior management approval workflow.
- Enhanced monitoring flag propagation (for future UC5 handoff).
- Risk-tiered periodic re-certification scheduling.
- Monitoring-intensity step-down workflow (NOT a PEP-status removal — see Section 8).

### 2.2 Out of scope for this POC
- Real PEP/adverse-media data feed integration (use a static seeded demo table, same pattern as UC1).
- Automated news/media scraping (mentioned as an "AI Opportunity" in the original blueprint, but requires external data licensing — flagged as future work, not built here).
- Actual STR filing (UC7 in your numbering, not built yet).

---

## 3. Actors

| Actor | Role |
|---|---|
| Compliance Analyst | Reviews every match, applies close-associate/family/seniority tests, requests source-of-wealth evidence |
| Senior Management (Approver) | Approves/rejects continuation of relationship with confirmed PEP |
| System (n8n) | Orchestrates re-screening triggers, builds analyst queue, tracks case state — never auto-decides a match |

---

## 4. Database Schema (PostgreSQL)

This schema **extends** the UC1 schema — it does not duplicate `customers`, `beneficial_owners`, or `cdd_cases`. Assumes UC1's tables already exist in the same database.

```sql
-- ============================================
-- REFERENCE TABLES
-- ============================================

-- Static demo seed table, stand-in for a real PEP/adverse-media data feed
CREATE TABLE pep_watchlist_source (
    id SERIAL PRIMARY KEY,
    full_name VARCHAR(200) NOT NULL,
    date_of_birth DATE,
    nationality VARCHAR(50),
    position_title VARCHAR(300),
    pep_category VARCHAR(20) NOT NULL,     -- 'FOREIGN','DOMESTIC','INTL_ORG'
    seniority_level VARCHAR(20),            -- 'SENIOR','JUNIOR_MIDDLE'  -- pre-tagged for Def #52(d) filtering
    source_note TEXT,
    last_updated TIMESTAMP DEFAULT now()
);

-- ============================================
-- RE-SCREENING CYCLE / TRIGGER TABLES
-- ============================================

CREATE TABLE rescreening_cycles (
    id SERIAL PRIMARY KEY,
    cycle_type VARCHAR(20) NOT NULL,        -- 'SCHEDULED','EVENT_TRIGGERED'
    trigger_reason VARCHAR(100),            -- e.g. 'MONTHLY_BATCH','PROFILE_UPDATE','BO_CHANGE','REACTIVATION'
    triggered_at TIMESTAMP NOT NULL DEFAULT now(),
    status VARCHAR(20) DEFAULT 'RUNNING'    -- RUNNING, COMPLETE
);

CREATE TABLE rescreening_candidates (
    id SERIAL PRIMARY KEY,
    cycle_id INT REFERENCES rescreening_cycles(id),
    customer_id INT NOT NULL,               -- FK to UC1's customers.id (primary, BO, director, trustee, etc.)
    person_role VARCHAR(30),                -- 'PRIMARY_CUSTOMER','BENEFICIAL_OWNER','DIRECTOR','TRUSTEE','GOVERNING_BODY_MEMBER'
    added_at TIMESTAMP DEFAULT now()
);

-- ============================================
-- SCREENING / MATCH REVIEW TABLES
-- ============================================

CREATE TABLE pep_match_candidates (
    id SERIAL PRIMARY KEY,
    rescreening_candidate_id INT REFERENCES rescreening_candidates(id),
    pep_watchlist_source_id INT REFERENCES pep_watchlist_source(id),
    match_confidence NUMERIC(5,2) NOT NULL,  -- name/DOB similarity score — TRIAGE ONLY, never a decision input
    matched_at TIMESTAMP NOT NULL DEFAULT now(),
    -- review_status is the single source of truth; nothing auto-resolves this.
    review_status VARCHAR(20) NOT NULL DEFAULT 'PENDING_REVIEW',
    -- PENDING_REVIEW, CONFIRMED_MATCH, REJECTED_NOT_SAME_PERSON, INCONCLUSIVE_NEEDS_INFO
    reviewed_by VARCHAR(100),
    reviewed_at TIMESTAMP,
    reviewer_notes TEXT
);

-- Explicit close-associate / family-member classification (Def #12 / Def #28)
-- Populated by the analyst as a checklist, never inferred automatically.
CREATE TABLE relationship_classification (
    id SERIAL PRIMARY KEY,
    pep_match_candidate_id INT REFERENCES pep_match_candidates(id),
    classification_type VARCHAR(20) NOT NULL,  -- 'DIRECT_PEP','CLOSE_ASSOCIATE','FAMILY_MEMBER'
    -- Close associate sub-tests (Def #12) — analyst checks which applies, if any:
    test_joint_beneficial_ownership BOOLEAN DEFAULT FALSE,     -- Def #12(a)
    test_entity_set_up_for_pep_benefit BOOLEAN DEFAULT FALSE,  -- Def #12(b)
    test_reasonably_known_close_connection BOOLEAN DEFAULT FALSE, -- Def #12(c)
    -- Family member sub-tests (Def #28) — ONLY these three qualify, nothing else:
    test_is_spouse BOOLEAN DEFAULT FALSE,                       -- Def #28(a)
    test_is_lineal_descendant_ascendant BOOLEAN DEFAULT FALSE,  -- Def #28(b)
    test_is_sibling BOOLEAN DEFAULT FALSE,                      -- Def #28(b)
    classified_by VARCHAR(100),
    classified_at TIMESTAMP
);

-- Def #52(d) seniority/exclusion gate — mandatory before any formal PEP designation
CREATE TABLE seniority_exclusion_check (
    id SERIAL PRIMARY KEY,
    pep_match_candidate_id INT REFERENCES pep_match_candidates(id),
    role_verified TEXT,                      -- the actual position/title checked
    is_senior_enough BOOLEAN,                -- TRUE = qualifies, FALSE = excluded per Def #52(d)
    checked_by VARCHAR(100),
    checked_at TIMESTAMP
);

-- ============================================
-- FORMAL PEP DESIGNATION & EDD TABLES
-- ============================================

CREATE TABLE pep_designations (
    id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,                -- FK to UC1's customers.id
    pep_match_candidate_id INT REFERENCES pep_match_candidates(id),
    designation_type VARCHAR(20) NOT NULL,    -- 'DIRECT_PEP','CLOSE_ASSOCIATE','FAMILY_MEMBER'
    pep_category VARCHAR(20),                 -- 'FOREIGN','DOMESTIC','INTL_ORG'
    designated_at TIMESTAMP NOT NULL DEFAULT now(),
    -- Per Def #52 "is or has been" — this designation does NOT expire on its own.
    -- There is no status_end_date / is_active-false auto-transition in this table by design.
    is_active BOOLEAN NOT NULL DEFAULT TRUE   -- can only be set FALSE by an explicit senior-mgmt-logged decision (see monitoring_intensity_log), never automatically
);

CREATE TABLE source_of_wealth_evidence (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT REFERENCES pep_designations(id),
    evidence_type VARCHAR(100),               -- 'BANK_STATEMENT','ASSET_DECLARATION','SALARY_DISCLOSURE','BUSINESS_OWNERSHIP_PROOF','OTHER'
    file_ref VARCHAR(300),
    declared_source TEXT,
    reconciled BOOLEAN DEFAULT FALSE,          -- TRUE only after analyst reconciles declared vs evidenced source
    reconciliation_notes TEXT,
    reviewed_by VARCHAR(100),
    reviewed_at TIMESTAMP
);

CREATE TABLE pep_senior_mgmt_approvals (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT REFERENCES pep_designations(id),
    decision VARCHAR(20),                      -- 'CONTINUE_RELATIONSHIP','EXIT_RELATIONSHIP'
    approver_name VARCHAR(100),
    approver_role VARCHAR(50),
    decision_at TIMESTAMP,
    comments TEXT
);

CREATE TABLE enhanced_monitoring_flags (
    id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,                  -- FK to UC1's customers.id / eventual accounts.id
    pep_designation_id INT REFERENCES pep_designations(id),
    monitoring_tier VARCHAR(20) NOT NULL DEFAULT 'ENHANCED', -- 'ENHANCED','STANDARD' (after step-down)
    set_at TIMESTAMP NOT NULL DEFAULT now(),
    set_by VARCHAR(100)
);

-- Tracks monitoring-INTENSITY changes only — never removes the underlying PEP designation.
CREATE TABLE monitoring_intensity_log (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT REFERENCES pep_designations(id),
    previous_tier VARCHAR(20),
    new_tier VARCHAR(20),
    reason TEXT,                                -- e.g. 'Left public office, 18-month internal observation period completed'
    approved_by VARCHAR(100),                    -- must be senior management, per same principle as Phase 7
    approved_at TIMESTAMP
);

CREATE TABLE recertification_schedule (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT REFERENCES pep_designations(id),
    risk_tier VARCHAR(10),                        -- drives frequency; higher risk = shorter interval
    next_recertification_date DATE NOT NULL,
    last_recertified_at TIMESTAMP,
    last_recertified_by VARCHAR(100)
);

CREATE TABLE audit_log_uc3 (
    id SERIAL PRIMARY KEY,
    pep_designation_id INT,
    entity_type VARCHAR(50),
    entity_id INT,
    action VARCHAR(100),
    actor VARCHAR(100),
    details JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);
```

### 4.1 Seed data required for POC
- `pep_watchlist_source`: 8-10 demo entries — mix of `seniority_level = 'SENIOR'` and a few `'JUNIOR_MIDDLE'` entries specifically to test the Def #52(d) exclusion gate, plus at least one `FOREIGN`, one `DOMESTIC`, one `INTL_ORG` for category coverage.

---

## 5. n8n Workflow — Step-by-Step

### Phase 0 — Trigger
1. **Cron/Schedule Trigger node** — monthly (or your chosen cadence) batch trigger → creates a `rescreening_cycles` row (`cycle_type = 'SCHEDULED'`).
2. **Webhook Trigger node** (separate entry point) — fires on customer-profile-update or beneficial-owner-change events from UC1's system → creates a `rescreening_cycles` row (`cycle_type = 'EVENT_TRIGGERED'`).

### Phase 1 — Candidate Compilation
3. **Postgres Node** — query UC1's `customers` + `beneficial_owners` tables for all active, non-rejected records due for re-screening (scheduled) or matching the event's customer_id (event-triggered).
4. **Postgres Node — Insert** each into `rescreening_candidates` with correct `person_role`.

### Phase 2 — Name Screening
5. **Postgres Node** — for each candidate, fuzzy-match `full_name` (+ DOB if available) against `pep_watchlist_source`.
6. **Function Node** — compute `match_confidence` score (simple similarity metric is fine for POC — this is triage-only, not decision-making).
7. **Postgres Node — Insert** any match above a low sensitivity floor (deliberately low threshold, since false negatives are worse than false positives here) into `pep_match_candidates` with `review_status = 'PENDING_REVIEW'`.

### Phase 3 — Human Review Queue (no auto-clear, ever)
8. **No automatic branching happens here.** The workflow stops advancing this candidate and simply surfaces it in an analyst queue (a simple list view — e.g., a Postgres view or a lightweight front-end table, out of n8n's scope to build a UI; recommend a minimal admin page or even direct DB queries for POC demo purposes).
9. Analyst manually sets `review_status` via a webhook/form submission (**Webhook Trigger node**, second entry point) to one of: `CONFIRMED_MATCH`, `REJECTED_NOT_SAME_PERSON`, `INCONCLUSIVE_NEEDS_INFO`.
10. If `INCONCLUSIVE_NEEDS_INFO` → case stays open, no further phases run until re-submitted.
11. If `REJECTED_NOT_SAME_PERSON` → **Postgres Node — Insert** into `audit_log_uc3` (documented rationale required in `reviewer_notes`), workflow ends for this candidate.
12. If `CONFIRMED_MATCH` → proceed to Phase 4.

### Phase 4 — Relationship Classification (only if candidate is not the primary named PEP but a linked person)
13. **Webhook/Form node** — analyst submits which Def #12 / Def #28 sub-tests apply → **Postgres Node — Insert** into `relationship_classification`.
14. **IF Node** — if `person_role != 'PRIMARY_CUSTOMER'` and none of the close-associate or family-member sub-tests are TRUE → this is not actually a qualifying relationship under SBP's definitions; case closes here (logged), does not proceed to formal designation.

### Phase 5 — Seniority/Exclusion Gate
15. **Webhook/Form node** — analyst submits verified role/title + `is_senior_enough` decision → **Postgres Node — Insert** into `seniority_exclusion_check`.
16. **IF Node** — `is_senior_enough = FALSE` → case closes here (documented as excluded per Def #52(d)), does not proceed.

### Phase 6 — Formal PEP Designation
17. **Postgres Node — Insert** into `pep_designations` (`designation_type`, `pep_category` pulled from the matched `pep_watchlist_source` row, `is_active = TRUE`).

### Phase 7 — Source of Wealth / Source of Funds
18. **Webhook/Form node** — branch/compliance requests evidence from customer, analyst logs submissions → **Postgres Node — Insert** into `source_of_wealth_evidence`.
19. **IF Node** — all required evidence rows have `reconciled = TRUE`? If not, case stays `ON_HOLD` (no auto-timeout — a human must resolve it).

### Phase 8 — Senior Management Approval
20. **Webhook Trigger node** — senior management submits decision → **Postgres Node — Insert** into `pep_senior_mgmt_approvals`.
21. **IF Node** — `decision = 'EXIT_RELATIONSHIP'` → trigger an off-boarding process (out of scope for UC3 itself — hand off to an account-closure workflow) and set `pep_designations.is_active` handling per your team's exit policy.
22. `decision = 'CONTINUE_RELATIONSHIP'` → proceed.

### Phase 9 — Enhanced Monitoring Activation
23. **Postgres Node — Insert** into `enhanced_monitoring_flags` (`monitoring_tier = 'ENHANCED'`).

### Phase 10 — Re-certification Scheduling
24. **Function Node** — compute `next_recertification_date` based on `pep_category`/risk tier (e.g., Foreign PEP → 6 months, Domestic PEP → 12 months — define your own rubric with your team; not an SBP-mandated number, document it as a policy choice).
25. **Postgres Node — Insert** into `recertification_schedule`.

### Monitoring-Intensity Step-Down (separate, manually-triggered sub-flow — NOT automatic, NOT a status removal)
26. Triggered only by an explicit senior-management request (e.g., "this person left office 18 months ago, requesting review").
27. **Webhook Trigger + Postgres Insert** into `monitoring_intensity_log` (requires `approved_by`).
28. `enhanced_monitoring_flags.monitoring_tier` updated to `'STANDARD'`.
29. **`pep_designations.is_active` and the underlying record are NOT deleted or expired** — per Def #52's "is or has been" language, the designation remains on file permanently; only the *monitoring intensity* changes.

---

## 6. Test Scenarios (for demo)

1. **New Foreign PEP match on a Company's director** → full path through Phases 2–9, confirms EDD trigger + senior mgmt approval + enhanced monitoring flag.
2. **Match against a `JUNIOR_MIDDLE` seniority-level seed entry** → should be excluded at Phase 5 (Def #52(d)) even though the name matched.
3. **Analyst rejects a match as "not the same person"** → case closes with logged rationale, no designation created.
4. **A beneficial owner's sibling is identified as connected to a PEP** → tests the family-member sub-test (`test_is_sibling`), confirms only spouse/lineal/sibling qualify — a cousin or friend candidate should fail Phase 4's gate.
5. **Source-of-wealth evidence submitted but not reconciled** → case must stay `ON_HOLD` at Phase 7, cannot reach senior management approval.
6. **Monitoring-intensity step-down request** → confirms `pep_designations` row is untouched/still `is_active = TRUE`, only `enhanced_monitoring_flags.monitoring_tier` changes, and a senior-management approver is required.

---

## 7. Traceability

| PRD Section | Regulation / Definition |
|---|---|
| Phase 2-3 human-only review | Reg 5 §1(a) + your team's design principle (human final decision) |
| Phase 4 relationship classification | Def #12 (close associate), Def #28 (family member) |
| Phase 5 seniority gate | Def #52(d) |
| Phase 6 designation | Reg 5 §1(a), Def #52(a)-(c) |
| Phase 7 source of wealth/funds | Reg 5 §1(c) — "establish, by appropriate means" |
| Phase 8 approval | Reg 5 §1(b) |
| Phase 9 enhanced monitoring | Reg 5 §1(d) |
| Monitoring step-down (not designation removal) | Def #52 "is or has been" — confirmed via full-document search, no cooling-off/expiry provision exists anywhere in the Regulations |

---

## 8. Notes for Antigravity

- This schema assumes UC1's `customers`, `beneficial_owners`, `cdd_cases` tables already exist — build UC1's migration first if not already applied.
- Do **not** implement any auto-approval, auto-clear, or auto-expiry logic anywhere in this workflow — every state transition that matters (match confirmation, relationship classification, seniority determination, approval, monitoring step-down) requires a human-submitted webhook/form action logged with an actor identity and timestamp. This is a deliberate design constraint, not an oversight.
