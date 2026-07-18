-- ============================================================================
-- UC13: IRAR Auto-Generation & BoD Governance — Seed Data
-- GenosAI AML/CFT/CPF Compliance Automation POC v2
-- ============================================================================

-- Seed a completed historical cycle to establish a realistic compliance history
INSERT INTO irar_cycles (id, cycle_ref, trigger_type, trigger_note, status, opened_at, closed_at)
VALUES (
    1, 
    'IRAR-2025-Q4', 
    'SCHEDULED', 
    'Mandatory annual entity risk assessment per SBP Reg 1 §2.', 
    'ARCHIVED', 
    '2025-12-15 09:00:00', 
    '2025-12-31 17:00:00'
);

-- Seed internal metrics snapshots for the historical cycle
INSERT INTO irar_internal_metrics_snapshot (cycle_id, metric_key, metric_value, source_table_ref)
VALUES 
    (1, 'STR_FILED_COUNT', 42, 'uc5.str_filings'),
    (1, 'CTR_FILED_COUNT', 184, 'uc5.ctr_filings'),
    (1, 'PEP_DESIGNATION_COUNT', 15, 'uc3.pep_designations'),
    (1, 'TFS_MATCH_COUNT', 2, 'uc1.tfs_screening_results'),
    (1, 'AUDIT_FINDINGS_COUNT', 3, 'internal_audit_log');

-- Seed external inputs with mandatory source attribution
INSERT INTO irar_external_inputs (cycle_id, input_type, description, source_attribution, relevance_note, entered_by)
VALUES 
    (1, 'NRA_UPDATE', 'National Risk Assessment 2025 flags mobile banking and online channels as high risk for TF facilitation.', 'Pakistan National Risk Assessment (NRA) 2025 §3.4', 'Requires enhanced monitoring of digital onboarding channels.', 'n8n_agent'),
    (1, 'REGULATOR_FEEDBACK', 'SBP inspection reports check-box compliance in transaction monitoring thresholds without custom logic.', 'SBP Inspection Report Ref Genos-2025-09', 'TMS alerts must incorporate customer risk rating profiles.', 'n8n_agent'),
    (1, 'MAJOR_INCIDENT_INTELLIGENCE', 'Emerging regional hawk-vendor warning of malware specifically targeting local retail remittance corridors.', 'FATF Red Flag Circular 12/2025', 'Requires strict validation of sender-beneficiary relationships.', 'n8n_agent');

-- Seed rejected case inputs representing UC1/Reg 13 §3 counts
INSERT INTO irar_rejected_case_inputs (cycle_id, rejected_case_count, risk_rating_revision_count, ml_tf_pf_closure_count)
VALUES (1, 14, 8, 3);

-- Seed employee risk snapshot
INSERT INTO irar_employee_risk_snapshot (cycle_id, training_completion_rate, fpt_noncompliance_count, screening_flags_count)
VALUES (1, 94.50, 0, 1);

-- Seed risk narratives across dimensions (8 dimensions total)
INSERT INTO irar_risk_narrative (cycle_id, risk_dimension, llm_draft_text, human_edited_text, edited_by, edited_at)
VALUES 
    (1, 'CUSTOMERS', 'Draft customer segment analysis...', 'Primary customer segments are domestic retail; NGO accounts representing 1.2% are gated with mandatory EDD.', 'compliance_analyst', '2025-12-20 14:00:00'),
    (1, 'PRODUCTS', 'Draft products analysis...', 'Products include standard checking, savings, and digital wallets. Digital wallets show rapid growth and higher exposure.', 'compliance_analyst', '2025-12-20 14:10:00'),
    (1, 'SERVICES', 'Draft services analysis...', 'Trade finance and bill payment services are standard. Remittances are gated via automated screening.', 'compliance_analyst', '2025-12-20 14:20:00'),
    (1, 'DELIVERY_CHANNELS', 'Draft delivery channels analysis...', 'Mobile application usage expanded by 40% in Q4. This aligns with the NRA concern regarding channel vulnerability.', 'compliance_analyst', '2025-12-20 14:30:00'),
    (1, 'TECHNOLOGIES', 'Draft technologies analysis...', 'BVS integration is fully active at branches. Digital customer onboarding is handled via automated API check rails.', 'compliance_analyst', '2025-12-20 14:40:00'),
    (1, 'EMPLOYEE_CATEGORIES', 'Draft employee analysis...', 'Staff training rate sits at 94.5%. Front-line branch tellers show the lowest completion rates due to high turnover.', 'compliance_analyst', '2025-12-20 14:50:00'),
    (1, 'TRANSNATIONAL_TF', 'Draft transnational TF analysis...', 'Border region branches show minor risk. Strict controls applied to foreign remittances.', 'compliance_analyst', '2025-12-20 15:00:00'),
    (1, 'EMERGING_RISKS', 'Draft emerging risks analysis...', 'Virtual asset exchanges and P2P networks represent a growing channel for bank account exploitation.', 'compliance_analyst', '2025-12-20 15:10:00');

-- Seed gap analysis with explicit proportionality notes
INSERT INTO irar_gap_analysis (cycle_id, identified_risk, existing_control, gap_description, proportionality_note, severity)
VALUES (
    1, 
    'Higher vulnerability of digital wallet channels for small-value rapid transactions.',
    'Threshold-based post-transaction review.',
    'Lack of real-time velocity gating for non-face-to-face customers.',
    'Proportionality considered: Given Genos Bank is a medium-sized retail institution, instant velocity blocks are applied dynamically on new digital wallets rather than legacy accounts.',
    'HIGH'
);

-- Seed action plan items (representing all 5 mandatory categories)
INSERT INTO irar_action_plan_items (id, cycle_id, category, recommendation, target_completion_date, owner, status)
VALUES 
    (1, 1, 'BUSINESS_STRATEGY_RISK_APPETITE', 'Reduce bank risk exposure threshold for high-value offshore correspondent wires.', '2026-06-30', 'Board Risk Committee', 'APPROVED'),
    (2, 1, 'POLICY_FRAMEWORK', 'Incorporate virtual assets red flag checklists into Board-approved AML/CFT policy.', '2026-03-31', 'Chief Compliance Officer', 'APPROVED'),
    (3, 1, 'SOP_PROCEDURE_MANUAL', 'Update Digital Wallet Onboarding SOP to require real-time velocity screening.', '2026-02-28', 'Head of Retail Operations', 'APPROVED'),
    (4, 1, 'EMPLOYEE_RISK_UNDERSTANDING', 'Deploy targeted short-module digital wallet compliance training to front-line branch tellers.', '2026-04-30', 'HR Training Lead', 'APPROVED'),
    (5, 1, 'RESOURCE_ADEQUACY', 'Acquire automated API screening licenses to support high-speed velocity checks.', '2026-05-31', 'Head of IT Compliance', 'APPROVED');

-- Seed governance approval logs
INSERT INTO irar_senior_mgmt_prereview (cycle_id, reviewer_name, decision, comments)
VALUES (1, 'Sarah Khan (COO)', 'APPROVED_FOR_BOD', 'Narrative reflects SBP inspection feedback accurately. Ready for BoD review.');

INSERT INTO irar_bod_approval (cycle_id, decision, approved_by, meeting_ref)
VALUES (1, 'APPROVED', 'Chairman Tariq Malik', 'BOD-MEETING-2025-04');

INSERT INTO irar_sop_approval (action_plan_item_id, approved_by, decision, updated_sop_reference)
VALUES (3, 'Sarah Khan (COO)', 'APPROVED', 'SOP-OPS-DIGITAL-V2.1');

-- Seed archival record with dynamic 10-year retention date calculation
INSERT INTO irar_archive (cycle_id, final_document_ref, bod_deck_ref, archived_at, retention_until, available_for_sbp_inspection)
VALUES (
    1, 
    'http://localhost:9000/archives/IRAR-2025-Q4-FINAL.pdf', 
    'http://localhost:9000/archives/IRAR-2025-Q4-DECK.pdf', 
    '2025-12-31 17:00:00', 
    '2035-12-31', 
    TRUE
);

-- Adjust sequence values to prevent duplicate key errors on new inserts
SELECT setval('irar_cycles_id_seq', (SELECT MAX(id) FROM irar_cycles));
SELECT setval('irar_action_plan_items_id_seq', (SELECT MAX(id) FROM irar_action_plan_items));
