-- Seed customer cases and customer records for UC8 testing
-- We insert cases first, then insert customers pointing to those cases.

-- Case 201: Approved Customer (Compliant)
INSERT INTO cdd_cases (id, case_ref, status, is_occasional_customer, current_phase, opened_at)
VALUES (201, 'CDD-2026-UC8-201', 'APPROVED', FALSE, 'CLOSED', now())
ON CONFLICT (case_ref) DO NOTHING;

INSERT INTO customers (id, case_id, role, full_name, identity_doc_type, identity_doc_number, date_of_birth, nationality_status)
VALUES (201, 201, 'PRIMARY', 'Test Outgoing Compliant Customer', 'CNIC', '42101-1234567-1', '1985-05-15', 'RESIDENT')
ON CONFLICT (id) DO NOTHING;

-- Case 202: In-Progress Customer (Incomplete CDD)
INSERT INTO cdd_cases (id, case_ref, status, is_occasional_customer, current_phase, opened_at)
VALUES (202, 'CDD-2026-UC8-202', 'IN_PROGRESS', FALSE, 'INTAKE', now())
ON CONFLICT (case_ref) DO NOTHING;

INSERT INTO customers (id, case_id, role, full_name, identity_doc_type, identity_doc_number, date_of_birth, nationality_status)
VALUES (202, 202, 'PRIMARY', 'Test Outgoing Incomplete Customer', 'CNIC', '42101-1234567-2', '1990-08-20', 'RESIDENT')
ON CONFLICT (id) DO NOTHING;

-- Case 203: Approved Customer (Beneficiary Compliant)
INSERT INTO cdd_cases (id, case_ref, status, is_occasional_customer, current_phase, opened_at)
VALUES (203, 'CDD-2026-UC8-203', 'APPROVED', FALSE, 'CLOSED', now())
ON CONFLICT (case_ref) DO NOTHING;

INSERT INTO customers (id, case_id, role, full_name, identity_doc_type, identity_doc_number, date_of_birth, nationality_status)
VALUES (203, 203, 'PRIMARY', 'Test Beneficiary Compliant Customer', 'CNIC', '42101-1234567-3', '1978-12-01', 'RESIDENT')
ON CONFLICT (id) DO NOTHING;
