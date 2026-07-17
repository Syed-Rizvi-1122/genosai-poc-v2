-- ============================================================================
-- UC1: Customer Onboarding & CDD — Seed / Config Data
-- GenosAI AML/CFT/CPF Compliance Automation POC v2
-- ============================================================================

-- ============================================================================
-- 1. IRAR CONFIG (Regulation 1 §2-§8)
-- ============================================================================
-- This is the bank's Internal Risk Assessment Report parameters, codified.
-- In production, this would be updated when the BoD approves a new IRAR.

INSERT INTO irar_config (
    config_version, is_active, approved_by, approved_at,
    weight_customer_type_high, weight_customer_type_medium,
    weight_pep_match, weight_pep_family,
    weight_foreign_nationality, weight_high_risk_geography,
    weight_large_expected_turnover, weight_complex_ownership,
    threshold_low_max, threshold_medium_max,
    sdd_allowed_for_low, edd_required_for_high,
    edd_mandatory_for_ngo_trust, edd_mandatory_for_pep,
    notes
) VALUES (
    'V1', TRUE, 'BoD (POC Seed)', now(),
    20, 10,       -- customer_type weights
    30, 20,       -- PEP weights
    10, 15,       -- geography weights
    10, 10,       -- turnover & ownership complexity
    25, 55,       -- tier thresholds: 0-25=LOW, 26-55=MED, 56+=HIGH
    TRUE, TRUE,   -- SDD for low, EDD for high
    TRUE, TRUE,   -- mandatory EDD for NGO/Trust & PEP
    'POC seed IRAR config. Conservative approach: NGO/Trust always EDD (Reg 6 §1 policy choice). '
    'In production, update this when BoD approves revised IRAR per Reg 1 §7-§8.'
);

-- ============================================================================
-- 2. RE TYPES (8 regulated entity types)
-- ============================================================================

INSERT INTO re_types (code, name, allows_legal_persons, allows_third_party_cdd_reliance, ngo_trust_regulation_applicable, notes) VALUES
('BANK',  'Bank / Banking Company',                TRUE,  TRUE,  TRUE,  'Def #2-4. Primary RE type for this POC.'),
('DFI',   'Development Finance Institution',       TRUE,  TRUE,  TRUE,  NULL),
('MFB',   'Microfinance Bank',                     TRUE,  TRUE,  TRUE,  'Def #38'),
('EC',    'Exchange Company',                      FALSE, FALSE, FALSE, 'Def #27: ECs deal with natural persons only. Reg 3 §1 & Reg 6 §7 carve-outs.'),
('EC_B',  'Exchange Company of B Category',        FALSE, FALSE, FALSE, 'Same restrictions as EC.'),
('PSO',   'Payment Systems Operator',              TRUE,  TRUE,  TRUE,  'Def #55'),
('PSP',   'Payment Service Provider',              TRUE,  TRUE,  TRUE,  'Def #55'),
('EMI',   'Electronic Money Institution',          TRUE,  TRUE,  TRUE,  'Def #26'),
('TPSP',  'Third Party Payment Service Provider',  TRUE,  TRUE,  TRUE,  'Def #63');

-- ============================================================================
-- 3. CUSTOMER TYPES (14 types from Annexure II)
-- ============================================================================

INSERT INTO customer_types (code, name, legal_category, requires_beneficial_owner_check, requires_governing_body_cdd, mandatory_edd, annexure_ii_row, notes) VALUES
('INDIVIDUAL',          'Individual (incl. Walk-in/Occasional)',  'NATURAL_PERSON',     FALSE, FALSE, FALSE, 1,  'Annexure II Sr.1'),
('JOINT',               'Joint Account',                          'NATURAL_PERSON',     FALSE, FALSE, FALSE, 2,  'Annexure II Sr.2. CDD on each holder as individual.'),
('SOLE_PROP',           'Sole Proprietorship',                    'NATURAL_PERSON',     FALSE, FALSE, FALSE, 3,  'Annexure II Sr.3'),
('SMALL_BIZ',           'Small Business / Freelance Professional','NATURAL_PERSON',     FALSE, FALSE, FALSE, 4,  'Annexure II Sr.4'),
('PARTNERSHIP',         'Partnership',                            'LEGAL_PERSON',       TRUE,  FALSE, FALSE, 5,  'Annexure II Sr.5'),
('LLP',                 'Limited Liability Partnership',          'LEGAL_PERSON',       TRUE,  FALSE, FALSE, 6,  'Annexure II Sr.6'),
('COMPANY',             'Limited Company / Corporation',          'LEGAL_PERSON',       TRUE,  FALSE, FALSE, 7,  'Annexure II Sr.7'),
('FOREIGN_BRANCH',      'Branch/Liaison Office of Foreign Co.',   'LEGAL_PERSON',       TRUE,  FALSE, FALSE, 8,  'Annexure II Sr.8'),
('TRUST_CLUB_SOCIETY',  'Trust / Club / Society / Association',   'LEGAL_ARRANGEMENT',  TRUE,  TRUE,  TRUE,  9,  'Annexure II Sr.9. mandatory_edd=TRUE is a conservative policy choice per IRAR config.'),
('NGO_NPO',             'NGO / NPO / Charity',                   'LEGAL_ARRANGEMENT',  TRUE,  TRUE,  TRUE,  10, 'Annexure II Sr.10. mandatory_edd=TRUE is a conservative policy choice per IRAR config. Different doc set from Trust.'),
('AGENT',               'Agent Account',                          'NATURAL_PERSON',     FALSE, FALSE, FALSE, 11, 'Annexure II Sr.11'),
('EXECUTOR_ADMIN',      'Executors and Administrators',           'NATURAL_PERSON',     FALSE, FALSE, FALSE, 12, 'Annexure II Sr.12'),
('MINOR',               'Minor Account',                          'NATURAL_PERSON',     FALSE, FALSE, FALSE, 13, 'Annexure II Sr.13'),
('MENTALLY_DISORDERED', 'Mentally Disordered Person Account',     'NATURAL_PERSON',     FALSE, FALSE, FALSE, 14, 'Annexure II Sr.14');

-- ============================================================================
-- 4. RE-CUSTOMER TYPE APPLICABILITY (Bank × all 14 types for POC)
-- ============================================================================
-- EC/EC-B cannot serve legal persons (Def #27), so those are FALSE.
-- For POC, we only wire Bank. Other RE types are in schema for future phases.

INSERT INTO re_customer_type_applicability (re_type_id, customer_type_id, is_applicable, notes)
SELECT
    r.id,
    c.id,
    CASE
        WHEN r.code IN ('EC', 'EC_B') AND c.legal_category != 'NATURAL_PERSON' THEN FALSE
        ELSE TRUE
    END,
    CASE
        WHEN r.code IN ('EC', 'EC_B') AND c.legal_category != 'NATURAL_PERSON'
        THEN 'EC/EC-B cannot serve legal persons (Def #27)'
        ELSE NULL
    END
FROM re_types r
CROSS JOIN customer_types c;

-- ============================================================================
-- 5. DOCUMENT CHECKLIST CONFIG (5 in-scope customer types)
-- ============================================================================

-- ---- INDIVIDUAL (Annexure II Sr.1) ----
INSERT INTO document_checklist_config (customer_type_id, document_type, is_mandatory, applies_to_role, is_conditional, condition_description, regulation_ref) VALUES
((SELECT id FROM customer_types WHERE code = 'INDIVIDUAL'), 'IDENTITY_DOCUMENT', TRUE, 'CUSTOMER', FALSE, NULL, 'Annexure II Sr.1');

-- ---- COMPANY (Annexure II Sr.7) ----
INSERT INTO document_checklist_config (customer_type_id, document_type, is_mandatory, applies_to_role, is_conditional, condition_description, regulation_ref) VALUES
((SELECT id FROM customer_types WHERE code = 'COMPANY'), 'IDENTITY_DOCUMENT',                TRUE,  'ALL_DIRECTORS',  FALSE, NULL, 'Annexure II Sr.7 item 1'),
((SELECT id FROM customer_types WHERE code = 'COMPANY'), 'IDENTITY_DOCUMENT',                TRUE,  'AUTHORIZED_SIGNATORIES', FALSE, NULL, 'Annexure II Sr.7 item 1'),
((SELECT id FROM customer_types WHERE code = 'COMPANY'), 'BOARD_RESOLUTION',                 TRUE,  NULL,             FALSE, NULL, 'Annexure II Sr.7 item 2a'),
((SELECT id FROM customer_types WHERE code = 'COMPANY'), 'MEMORANDUM_ARTICLES_OF_ASSOCIATION',TRUE,  NULL,             FALSE, NULL, 'Annexure II Sr.7 item 2b'),
((SELECT id FROM customer_types WHERE code = 'COMPANY'), 'FORM_A_OR_B',                      TRUE,  NULL,             FALSE, NULL, 'Annexure II Sr.7 item 2c'),
((SELECT id FROM customer_types WHERE code = 'COMPANY'), 'INCORPORATION_FORM_II_OR_FORM_29', TRUE,  NULL,             FALSE, NULL, 'Annexure II Sr.7 item 2d');

-- ---- TRUST / CLUB / SOCIETY (Annexure II Sr.9) ----
INSERT INTO document_checklist_config (customer_type_id, document_type, is_mandatory, applies_to_role, is_conditional, condition_description, regulation_ref) VALUES
((SELECT id FROM customer_types WHERE code = 'TRUST_CLUB_SOCIETY'), 'IDENTITY_DOCUMENT',     TRUE,  'GOVERNING_BODY',          FALSE, NULL, 'Annexure II Sr.9 item 1a'),
((SELECT id FROM customer_types WHERE code = 'TRUST_CLUB_SOCIETY'), 'IDENTITY_DOCUMENT',     TRUE,  'AUTHORIZED_SIGNATORIES',  FALSE, NULL, 'Annexure II Sr.9 item 1b'),
((SELECT id FROM customer_types WHERE code = 'TRUST_CLUB_SOCIETY'), 'IDENTITY_DOCUMENT',     TRUE,  'SETTLOR',                 FALSE, NULL, 'Annexure II Sr.9 item 1c'),
((SELECT id FROM customer_types WHERE code = 'TRUST_CLUB_SOCIETY'), 'IDENTITY_DOCUMENT',     TRUE,  'PROTECTOR',               TRUE,  'Only if protector exists', 'Annexure II Sr.9 item 1c — Issue #4'),
((SELECT id FROM customer_types WHERE code = 'TRUST_CLUB_SOCIETY'), 'IDENTITY_DOCUMENT',     TRUE,  'BENEFICIARIES',           FALSE, NULL, 'Annexure II Sr.9 item 1c'),
((SELECT id FROM customer_types WHERE code = 'TRUST_CLUB_SOCIETY'), 'DECLARATION_ON_ULTIMATE_CONTROL_PURPOSE_SOURCE_OF_FUNDS', TRUE, 'GOVERNING_BODY', FALSE, NULL, 'Annexure II Sr.9 item 2'),
((SELECT id FROM customer_types WHERE code = 'TRUST_CLUB_SOCIETY'), 'CERTIFICATE_OF_REGISTRATION_OR_INSTRUMENT_OF_TRUST',     TRUE, NULL, FALSE, NULL, 'Annexure II Sr.9 item 3a'),
((SELECT id FROM customer_types WHERE code = 'TRUST_CLUB_SOCIETY'), 'BY_LAWS_RULES_REGULATIONS',                               TRUE, NULL, FALSE, NULL, 'Annexure II Sr.9 item 3b'),
((SELECT id FROM customer_types WHERE code = 'TRUST_CLUB_SOCIETY'), 'GOVERNING_BODY_RESOLUTION_TO_OPEN_ACCOUNT',               TRUE, NULL, FALSE, NULL, 'Annexure II Sr.9 item 3c');

-- ---- NGO / NPO / CHARITY (Annexure II Sr.10) ----
INSERT INTO document_checklist_config (customer_type_id, document_type, is_mandatory, applies_to_role, is_conditional, condition_description, regulation_ref) VALUES
((SELECT id FROM customer_types WHERE code = 'NGO_NPO'), 'IDENTITY_DOCUMENT',                   TRUE,  'GOVERNING_BODY',          FALSE, NULL, 'Annexure II Sr.10 item 1'),
((SELECT id FROM customer_types WHERE code = 'NGO_NPO'), 'IDENTITY_DOCUMENT',                   TRUE,  'AUTHORIZED_SIGNATORIES',  FALSE, NULL, 'Annexure II Sr.10 item 1'),
((SELECT id FROM customer_types WHERE code = 'NGO_NPO'), 'REGISTRATION_DOCUMENTS_OR_SECP_LICENSE', TRUE, NULL,                    FALSE, NULL, 'Annexure II Sr.10 item 2a'),
((SELECT id FROM customer_types WHERE code = 'NGO_NPO'), 'MEMORANDUM_ARTICLES_OF_ASSOCIATION',  TRUE,  NULL,                      FALSE, NULL, 'Annexure II Sr.10 item 2b'),
((SELECT id FROM customer_types WHERE code = 'NGO_NPO'), 'INCORPORATION_FORM_II_OR_B29',       TRUE,  NULL,                      FALSE, NULL, 'Annexure II Sr.10 item 2c'),
((SELECT id FROM customer_types WHERE code = 'NGO_NPO'), 'GOVERNING_BODY_RESOLUTION_TO_OPEN_ACCOUNT', TRUE, NULL,                FALSE, NULL, 'Annexure II Sr.10 item 2d'),
((SELECT id FROM customer_types WHERE code = 'NGO_NPO'), 'ANNUAL_FINANCIAL_STATEMENTS_OR_DISCLOSURES', TRUE, NULL,               FALSE, NULL, 'Annexure II Sr.10 item 3 — assess source/use-of-funds risk per Reg 6');

-- ---- MINOR (Annexure II Sr.13) ----
INSERT INTO document_checklist_config (customer_type_id, document_type, is_mandatory, applies_to_role, is_conditional, condition_description, regulation_ref) VALUES
((SELECT id FROM customer_types WHERE code = 'MINOR'), 'IDENTITY_DOCUMENT', TRUE,  'CUSTOMER',  FALSE, NULL, 'Annexure II Sr.13 item 1'),
((SELECT id FROM customer_types WHERE code = 'MINOR'), 'IDENTITY_DOCUMENT', TRUE,  'GUARDIAN',  FALSE, NULL, 'Annexure II Sr.13 item 1'),
((SELECT id FROM customer_types WHERE code = 'MINOR'), 'COURT_GUARDIAN_ORDER', TRUE, NULL,       TRUE,  'Only if court-appointed guardian (not natural parent)', 'Annexure II Sr.13 item 2');

-- ============================================================================
-- 6. EDD MEASURES REFERENCE (Reg 2 §17(a)-(h))
-- ============================================================================

INSERT INTO edd_measures_reference (code, description, regulation_ref) VALUES
('EDD_A', 'Obtain additional customer info: occupation, volume of assets, public DB checks, update identification more regularly', 'Reg 2 §17(a)'),
('EDD_B', 'Obtain additional info on intended nature of business relationship/transactions',                                      'Reg 2 §17(b)'),
('EDD_C', 'Obtain information on source of funds or source of wealth of the customer',                                            'Reg 2 §17(c)'),
('EDD_D', 'Obtain additional info on reasons for intended/performed transactions and purpose',                                     'Reg 2 §17(d)'),
('EDD_E', 'Take reasonable measures to establish source of funds/wealth — satisfy they are not proceeds from/for crime',           'Reg 2 §17(e)'),
('EDD_F', 'Obtain senior management approval to commence or continue the business relationship',                                  'Reg 2 §17(f)'),
('EDD_G', 'Conduct enhanced ongoing monitoring: review nature, frequency of controls, select transaction patterns for review',     'Reg 2 §17(g)'),
('EDD_H', 'Require first payment via account in customer own name at bank subject to similar CDD standards',                       'Reg 2 §17(h)');

-- ============================================================================
-- 7. SDD MEASURES REFERENCE (Reg 2 §18(a)-(c))
-- ============================================================================
-- HARD RULE: SDD is NEVER applied if there is any suspicion of ML/TF/PF (Reg 2 §19)

INSERT INTO sdd_measures_reference (code, description, regulation_ref) VALUES
('SDD_A', 'Verify customer/BO identity AFTER business relationship established',                                                   'Reg 2 §18(a)'),
('SDD_B', 'Reduce ongoing monitoring degree based on reasonable monetary threshold as prescribed by SBP',                           'Reg 2 §18(b)'),
('SDD_C', 'Infer (do not explicitly collect) purpose/nature of relationship from type of transactions/business relationship',       'Reg 2 §18(c)');

-- ============================================================================
-- 8. PEP WATCHLIST SEED (demo data — Reg 5, Def #52, #28, #12)
-- ============================================================================

INSERT INTO pep_watchlist_seed (full_name, pep_category, relationship_type, related_pep_name, position_title) VALUES
-- Direct PEPs
('Ahmed Raza Khan',     'DOMESTIC',  'DIRECT',           NULL,                'Federal Minister for Finance'),
('Fatima Noor Siddiqui','DOMESTIC',  'DIRECT',           NULL,                'Provincial Chief Minister'),
('Hassan Ali Mirza',    'DOMESTIC',  'DIRECT',           NULL,                'Chairman Senate Standing Committee'),
('Omar Yusuf Sheikh',   'FOREIGN',   'DIRECT',           NULL,                'Foreign Trade Secretary (Country X)'),
('Elena Vasquez Torres','INTL_ORG',  'DIRECT',           NULL,                'Senior Director, International Development Agency'),
('Ibrahim Khalid Dar',  'DOMESTIC',  'DIRECT',           NULL,                'CEO State-Owned Enterprise'),
-- Family members (Def #28)
('Sara Raza Khan',      'DOMESTIC',  'FAMILY_MEMBER',    'Ahmed Raza Khan',   'Spouse of Federal Minister'),
('Bilal Hassan Mirza',  'DOMESTIC',  'FAMILY_MEMBER',    'Hassan Ali Mirza',  'Son of Senate Committee Chairman'),
-- Close associates (Def #12)
('Tariq Mahmood Chaudhry','DOMESTIC','CLOSE_ASSOCIATE',  'Ahmed Raza Khan',   'Business partner of Federal Minister'),
('Naveed Iqbal Bhatti', 'DOMESTIC',  'CLOSE_ASSOCIATE',  'Fatima Noor Siddiqui','Known business associate of Chief Minister');

-- ============================================================================
-- 9. SANCTIONS WATCHLIST SEED (demo data — Reg 4, UNSC Act + ATA)
-- ============================================================================

INSERT INTO sanctions_watchlist_seed (full_name, list_type) VALUES
('Abdul Qadir Mujahid',   'UNSC'),
('Khalid Zaman Wazir',    'UNSC'),
('Mohammad Ismail Afridi', 'UNSC'),
('Saeedullah Akhundzada',  'ATA'),
('Zahid Hussain Bhittani', 'ATA'),
('Noor Muhammad Mengal',   'ATA');
