-- ============================================================================
-- UC3: PEP Lifecycle Monitoring — Seed Data
-- GenosAI AML/CFT/CPF Compliance Automation POC v2
--
-- Seeds the pep_watchlist_source table with 10 demo entries:
--   - Mix of FOREIGN, DOMESTIC, INTL_ORG categories (Def #52(a)-(c))
--   - Mix of SENIOR and JUNIOR_MIDDLE seniority (for Def #52(d) exclusion tests)
--   - Names deliberately overlap with UC1's pep_watchlist_seed to enable
--     cross-screening test scenarios
-- ============================================================================

INSERT INTO pep_watchlist_source (full_name, date_of_birth, nationality, position_title, pep_category, seniority_level, source_note) VALUES

-- 1. Domestic PEP — SENIOR — Federal Minister (overlaps with UC1 seed)
('Ahmed Raza Khan',       '1965-03-15', 'Pakistani',   'Federal Minister for Finance',
 'DOMESTIC', 'SENIOR', 'Active senior domestic PEP. Overlaps with UC1 seed data for cross-screening test.'),

-- 2. Domestic PEP — SENIOR — Provincial Chief Minister (overlaps with UC1 seed)
('Fatima Noor Siddiqui',  '1970-08-22', 'Pakistani',   'Provincial Chief Minister',
 'DOMESTIC', 'SENIOR', 'Active senior domestic PEP. Overlaps with UC1 seed data.'),

-- 3. Domestic PEP — SENIOR — Senate Committee Chairman (overlaps with UC1 seed)
('Hassan Ali Mirza',      '1958-11-10', 'Pakistani',   'Chairman Senate Standing Committee on Defence',
 'DOMESTIC', 'SENIOR', 'Active senior domestic PEP. Overlaps with UC1 seed data.'),

-- 4. Foreign PEP — SENIOR — Foreign Trade Secretary
('Omar Yusuf Sheikh',     '1972-06-05', 'Country X',   'Foreign Trade Secretary (Country X)',
 'FOREIGN', 'SENIOR', 'Foreign PEP for cross-border category testing. Reg 5 + Def #52(a).'),

-- 5. International Org PEP — SENIOR — Senior Director
('Elena Vasquez Torres',  '1968-01-30', 'Colombian',   'Senior Director, International Development Agency',
 'INTL_ORG', 'SENIOR', 'International organization PEP. Def #52(c).'),

-- 6. Domestic PEP — SENIOR — CEO State-Owned Enterprise
('Ibrahim Khalid Dar',    '1975-09-18', 'Pakistani',   'CEO Pakistan State Oil',
 'DOMESTIC', 'SENIOR', 'Senior executive of state-owned corporation. Def #52(b).'),

-- 7. Domestic — JUNIOR_MIDDLE — Tests Def #52(d) exclusion
('Rashid Mehmood Langrial','1985-04-12', 'Pakistani',  'Assistant Director, Provincial Revenue Department',
 'DOMESTIC', 'JUNIOR_MIDDLE', 'Junior government official. Must be EXCLUDED per Def #52(d) even if name matches.'),

-- 8. Domestic — JUNIOR_MIDDLE — Tests Def #52(d) exclusion
('Aisha Bibi Qureshi',   '1990-07-25', 'Pakistani',   'Section Officer, Ministry of Interior',
 'DOMESTIC', 'JUNIOR_MIDDLE', 'Mid-ranking official. Must be EXCLUDED per Def #52(d).'),

-- 9. Foreign PEP — SENIOR — Another foreign PEP for variety
('Viktor Petrov Kozlov',  '1960-12-03', 'Russian',     'Deputy Minister of Energy (Country Y)',
 'FOREIGN', 'SENIOR', 'Senior foreign PEP. Tests multiple foreign PEP matches in same cycle.'),

-- 10. International Org — JUNIOR_MIDDLE — Tests Def #52(d) for intl org
('Maria Santos Delgado',  '1988-05-14', 'Brazilian',   'Program Coordinator, WHO Regional Office',
 'INTL_ORG', 'JUNIOR_MIDDLE', 'Junior intl org official. Must be EXCLUDED per Def #52(d).');

-- ============================================================================
-- Also seed a few "existing customers" in UC1's customers table that will
-- produce matches against the watchlist above during re-screening demos.
-- These simulate customers who were onboarded clean but later match a PEP.
--
-- NOTE: These INSERT statements check for existing records first to avoid
-- duplicates if UC1 test runs have already populated the table.
-- ============================================================================

-- We'll create a dedicated CDD case for these demo customers
INSERT INTO cdd_cases (case_ref, re_type_id, customer_type_id, current_phase, status)
SELECT 'UC3-DEMO-001',
       (SELECT id FROM re_types WHERE code = 'BANK'),
       (SELECT id FROM customer_types WHERE code = 'COMPANY'),
       'COMPLETE', 'APPROVED'
WHERE NOT EXISTS (SELECT 1 FROM cdd_cases WHERE case_ref = 'UC3-DEMO-001');

INSERT INTO cdd_cases (case_ref, re_type_id, customer_type_id, current_phase, status)
SELECT 'UC3-DEMO-002',
       (SELECT id FROM re_types WHERE code = 'BANK'),
       (SELECT id FROM customer_types WHERE code = 'INDIVIDUAL'),
       'COMPLETE', 'APPROVED'
WHERE NOT EXISTS (SELECT 1 FROM cdd_cases WHERE case_ref = 'UC3-DEMO-002');

INSERT INTO cdd_cases (case_ref, re_type_id, customer_type_id, current_phase, status)
SELECT 'UC3-DEMO-003',
       (SELECT id FROM re_types WHERE code = 'BANK'),
       (SELECT id FROM customer_types WHERE code = 'INDIVIDUAL'),
       'COMPLETE', 'APPROVED'
WHERE NOT EXISTS (SELECT 1 FROM cdd_cases WHERE case_ref = 'UC3-DEMO-003');

-- Customer 1: A company whose director's name matches "Ahmed Raza Khan"
INSERT INTO customers (case_id, role, full_name, date_of_birth, nationality_status)
SELECT (SELECT id FROM cdd_cases WHERE case_ref = 'UC3-DEMO-001'),
       'DIRECTOR', 'Ahmed Raza Khan', '1965-03-15', 'RESIDENT'
WHERE NOT EXISTS (
    SELECT 1 FROM customers
    WHERE case_id = (SELECT id FROM cdd_cases WHERE case_ref = 'UC3-DEMO-001')
      AND full_name = 'Ahmed Raza Khan'
);

-- Customer 2: An individual whose name matches "Rashid Mehmood Langrial" (junior — should be excluded)
INSERT INTO customers (case_id, role, full_name, date_of_birth, nationality_status)
SELECT (SELECT id FROM cdd_cases WHERE case_ref = 'UC3-DEMO-002'),
       'PRIMARY', 'Rashid Mehmood Langrial', '1985-04-12', 'RESIDENT'
WHERE NOT EXISTS (
    SELECT 1 FROM customers
    WHERE case_id = (SELECT id FROM cdd_cases WHERE case_ref = 'UC3-DEMO-002')
      AND full_name = 'Rashid Mehmood Langrial'
);

-- Customer 3: An individual whose sibling is connected to PEP "Hassan Ali Mirza"
INSERT INTO customers (case_id, role, full_name, date_of_birth, nationality_status)
SELECT (SELECT id FROM cdd_cases WHERE case_ref = 'UC3-DEMO-003'),
       'PRIMARY', 'Bilal Hassan Mirza', '1988-02-20', 'RESIDENT'
WHERE NOT EXISTS (
    SELECT 1 FROM customers
    WHERE case_id = (SELECT id FROM cdd_cases WHERE case_ref = 'UC3-DEMO-003')
      AND full_name = 'Bilal Hassan Mirza'
);
