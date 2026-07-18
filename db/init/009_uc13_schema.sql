-- ============================================================================
-- UC13: IRAR Auto-Generation & BoD Governance — Database Schema
-- GenosAI AML/CFT/CPF Compliance Automation POC v2
--
-- Regulation References:
--   Reg 1 (Risk Based Approach), Reg 13 (Internal Controls)
-- ============================================================================

-- ============================================
-- CYCLE / TRIGGER
-- ============================================

CREATE TABLE irar_cycles (
    id SERIAL PRIMARY KEY,
    cycle_ref VARCHAR(30) UNIQUE NOT NULL,       -- e.g. IRAR-2026-Q3
    trigger_type VARCHAR(30) NOT NULL,           -- 'SCHEDULED','EVENT_NRA_UPDATE','EVENT_EMERGING_THREAT','EVENT_REGULATOR_FEEDBACK'
    trigger_note TEXT,
    status VARCHAR(30) NOT NULL DEFAULT 'DATA_AGGREGATION',
    -- DATA_AGGREGATION, DRAFTING, SENIOR_MGMT_PREREVIEW, BOD_APPROVAL, SOP_APPROVAL, ARCHIVED
    opened_at TIMESTAMP NOT NULL DEFAULT now(),
    closed_at TIMESTAMP,
    CONSTRAINT chk_trigger_type CHECK (trigger_type IN ('SCHEDULED','EVENT_NRA_UPDATE','EVENT_EMERGING_THREAT','EVENT_REGULATOR_FEEDBACK')),
    CONSTRAINT chk_status CHECK (status IN ('DATA_AGGREGATION', 'DRAFTING', 'SENIOR_MGMT_PREREVIEW', 'BOD_APPROVAL', 'SOP_APPROVAL', 'ARCHIVED'))
);

-- ============================================
-- DATA AGGREGATION INPUTS
-- ============================================

-- Internal metrics — pulled by reference from UC3/UC5 tables, not duplicated wholesale.
CREATE TABLE irar_internal_metrics_snapshot (
    id SERIAL PRIMARY KEY,
    cycle_id INT NOT NULL REFERENCES irar_cycles(id) ON DELETE CASCADE,
    metric_key VARCHAR(50) NOT NULL,             -- 'STR_FILED_COUNT','CTR_FILED_COUNT','PEP_DESIGNATION_COUNT',
                                                   -- 'TFS_MATCH_COUNT','AUDIT_FINDINGS_COUNT'
    metric_value NUMERIC NOT NULL,
    source_table_ref VARCHAR(100),                -- e.g. 'uc5.str_filings', 'uc3.pep_designations' — for traceability
    snapshot_at TIMESTAMP NOT NULL DEFAULT now()
);

-- External inputs that have NO automated feed — mandatory manual, source-attributed entry.
CREATE TABLE irar_external_inputs (
    id SERIAL PRIMARY KEY,
    cycle_id INT NOT NULL REFERENCES irar_cycles(id) ON DELETE CASCADE,
    input_type VARCHAR(30) NOT NULL,              -- 'NRA_UPDATE','MAJOR_INCIDENT_INTELLIGENCE','REGULATOR_FEEDBACK'
    description TEXT NOT NULL,
    source_attribution VARCHAR(200) NOT NULL,      -- mandatory: e.g. 'SBP NRA 2025 Update', 'FMU circular ref X'
    relevance_note TEXT,
    entered_by VARCHAR(100) NOT NULL,
    entered_at TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT chk_input_type CHECK (input_type IN ('NRA_UPDATE','MAJOR_INCIDENT_INTELLIGENCE','REGULATOR_FEEDBACK'))
);

-- Reg 13 §3 data — now sourced live from UC1 via HTTP call, not a permanent placeholder.
CREATE TABLE irar_rejected_case_inputs (
    id SERIAL PRIMARY KEY,
    cycle_id INT NOT NULL REFERENCES irar_cycles(id) ON DELETE CASCADE,
    rejected_case_count INT NOT NULL,
    risk_rating_revision_count INT NOT NULL,
    ml_tf_pf_closure_count INT NOT NULL,
    source_endpoint VARCHAR(200) DEFAULT 'UC1 /webhook/uc1-compliance-metrics',
    fetched_at TIMESTAMP NOT NULL DEFAULT now()
);

-- Employee-category risk data (simplified proxy for POC)
CREATE TABLE irar_employee_risk_snapshot (
    id SERIAL PRIMARY KEY,
    cycle_id INT NOT NULL REFERENCES irar_cycles(id) ON DELETE CASCADE,
    training_completion_rate NUMERIC(5,2) NOT NULL,  -- % of relevant staff with current AML/CFT/CPF training
    fpt_noncompliance_count INT NOT NULL,            -- staff flagged against Fit & Proper Test requirements
    screening_flags_count INT NOT NULL,               -- staff flagged in DP/PP screening (Reg 13 §9)
    snapshot_at TIMESTAMP NOT NULL DEFAULT now()
);

-- ============================================
-- DRAFTING
-- ============================================

CREATE TABLE irar_risk_narrative (
    id SERIAL PRIMARY KEY,
    cycle_id INT NOT NULL REFERENCES irar_cycles(id) ON DELETE CASCADE,
    risk_dimension VARCHAR(30) NOT NULL,             -- 'CUSTOMERS','PRODUCTS','SERVICES','DELIVERY_CHANNELS',
                                                       -- 'TECHNOLOGIES','EMPLOYEE_CATEGORIES','TRANSNATIONAL_TF','EMERGING_RISKS' (Reg 1 §2)
    llm_draft_text TEXT,
    human_edited_text TEXT,
    edited_by VARCHAR(100),
    edited_at TIMESTAMP,
    CONSTRAINT chk_risk_dimension CHECK (risk_dimension IN ('CUSTOMERS','PRODUCTS','SERVICES','DELIVERY_CHANNELS','TECHNOLOGIES','EMPLOYEE_CATEGORIES','TRANSNATIONAL_TF','EMERGING_RISKS'))
);

CREATE TABLE irar_gap_analysis (
    id SERIAL PRIMARY KEY,
    cycle_id INT NOT NULL REFERENCES irar_cycles(id) ON DELETE CASCADE,
    identified_risk TEXT NOT NULL,
    existing_control TEXT,
    gap_description TEXT,
    proportionality_note TEXT,                        -- explicit: how RE size/nature/complexity was weighed (Reg 1 §9, §11)
    severity VARCHAR(10) NOT NULL,                     -- 'LOW','MEDIUM','HIGH'
    CONSTRAINT chk_severity CHECK (severity IN ('LOW','MEDIUM','HIGH'))
);

-- Five explicit, separately-tracked output categories per Reg 1 §8 + Reg 13 §1(a)-(c)
CREATE TABLE irar_action_plan_items (
    id SERIAL PRIMARY KEY,
    cycle_id INT NOT NULL REFERENCES irar_cycles(id) ON DELETE CASCADE,
    category VARCHAR(40) NOT NULL,                     -- 'BUSINESS_STRATEGY_RISK_APPETITE','POLICY_FRAMEWORK','SOP_PROCEDURE_MANUAL',
                                                           -- 'EMPLOYEE_RISK_UNDERSTANDING','RESOURCE_ADEQUACY'
    recommendation TEXT NOT NULL,
    target_completion_date DATE NOT NULL,
    owner VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PROPOSED',      -- PROPOSED, APPROVED, IN_PROGRESS, COMPLETE
    CONSTRAINT chk_category CHECK (category IN ('BUSINESS_STRATEGY_RISK_APPETITE','POLICY_FRAMEWORK','SOP_PROCEDURE_MANUAL','EMPLOYEE_RISK_UNDERSTANDING','RESOURCE_ADEQUACY')),
    CONSTRAINT chk_action_status CHECK (status IN ('PROPOSED','APPROVED','IN_PROGRESS','COMPLETE'))
);

-- ============================================
-- APPROVAL CHAIN (two distinct tiers)
-- ============================================

CREATE TABLE irar_senior_mgmt_prereview (
    id SERIAL PRIMARY KEY,
    cycle_id INT NOT NULL REFERENCES irar_cycles(id) ON DELETE CASCADE,
    reviewer_name VARCHAR(100) NOT NULL,
    decision VARCHAR(30) NOT NULL,                       -- 'APPROVED_FOR_BOD','RETURNED_FOR_REVISION'
    comments TEXT,
    decided_at TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT chk_prereview_decision CHECK (decision IN ('APPROVED_FOR_BOD','RETURNED_FOR_REVISION'))
);

-- Tier 1: BoD approves the IRAR document itself (Reg 1 §8) — mandatory, non-delegable.
CREATE TABLE irar_bod_approval (
    id SERIAL PRIMARY KEY,
    cycle_id INT NOT NULL REFERENCES irar_cycles(id) ON DELETE CASCADE,
    decision VARCHAR(30) NOT NULL,                        -- 'APPROVED','RETURNED_FOR_REVISION'
    approved_by VARCHAR(100) NOT NULL,                     -- BoD chair/secretary logging the board's decision
    meeting_ref VARCHAR(100),
    decided_at TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT chk_bod_decision CHECK (decision IN ('APPROVED','RETURNED_FOR_REVISION'))
);

-- Tier 2: Senior Management approves the resulting SOP/procedure TEXT (Reg 1 §12) — separate from BoD's IRAR approval.
CREATE TABLE irar_sop_approval (
    id SERIAL PRIMARY KEY,
    action_plan_item_id INT NOT NULL REFERENCES irar_action_plan_items(id) ON DELETE CASCADE,  -- links to specific SOP_PROCEDURE_MANUAL item
    approved_by VARCHAR(100) NOT NULL,
    decision VARCHAR(30) NOT NULL,                          -- 'APPROVED','RETURNED_FOR_REVISION'
    updated_sop_reference VARCHAR(200),
    decided_at TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT chk_sop_decision CHECK (decision IN ('APPROVED','RETURNED_FOR_REVISION'))
);

-- ============================================
-- ARCHIVAL
-- ============================================

CREATE TABLE irar_archive (
    id SERIAL PRIMARY KEY,
    cycle_id INT NOT NULL REFERENCES irar_cycles(id) ON DELETE CASCADE,
    final_document_ref VARCHAR(300) NOT NULL,
    bod_deck_ref VARCHAR(300) NOT NULL,
    archived_at TIMESTAMP NOT NULL DEFAULT now(),
    retention_until DATE NOT NULL,                           -- computed per same 10-year pattern as UC5/UC8
    available_for_sbp_inspection BOOLEAN NOT NULL DEFAULT TRUE -- Reg 1 §7
);
