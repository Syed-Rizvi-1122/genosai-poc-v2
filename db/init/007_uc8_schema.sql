-- ============================================================================
-- UC8: WIRE TRANSFER DATA COMPLETENESS SCHEMA
-- ============================================================================

-- Core Wire Transfers Table
CREATE TABLE IF NOT EXISTS wire_transfers (
    id SERIAL PRIMARY KEY,
    transaction_ref VARCHAR(50) UNIQUE NOT NULL,      -- e.g. SWIFT message ID or local transfer ref
    sending_institution VARCHAR(100) NOT NULL,
    receiving_institution VARCHAR(100) NOT NULL,
    is_interbank_exemption BOOLEAN NOT NULL DEFAULT FALSE, -- Reg 11 §1 interbank position check
    transfer_type VARCHAR(20) NOT NULL,                -- 'INDIVIDUAL' or 'BATCH'
    direction VARCHAR(20) NOT NULL,                    -- 'OUTGOING' (Ordering), 'FORWARDING' (Intermediary), 'INCOMING' (Beneficiary)
    originator_customer_id INT REFERENCES customers(id), -- Nullable for foreign originators
    amount NUMERIC(18,2) NOT NULL,
    currency VARCHAR(10) NOT NULL DEFAULT 'PKR',
    value_date DATE NOT NULL,
    purpose_of_transfer TEXT,
    originator_beneficiary_relationship TEXT,          -- SBP reconstruction requirement (§2b)
    
    -- Originator Message Fields (§3)
    originator_name VARCHAR(200),
    originator_account_ref VARCHAR(100),
    originator_id_doc_number VARCHAR(50),              -- CNIC, Passport, etc.
    
    -- Beneficiary Message Fields (§3)
    beneficiary_name VARCHAR(200),
    beneficiary_account_ref VARCHAR(100),
    beneficiary_id_doc_number VARCHAR(50),
    
    transfer_status VARCHAR(30) NOT NULL DEFAULT 'PENDING_CHECK', 
    -- 'PENDING_CHECK', 'SENT', 'EXECUTED', 'HELD_COMPLETENESS', 'REJECTED', 'SUSPENDED'
    
    flagged_for_cdd_failure BOOLEAN NOT NULL DEFAULT FALSE,
    flagged_for_str_review BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    retention_until DATE                               -- transaction completion + 10 years
);

-- Hold Review Queue
CREATE TABLE IF NOT EXISTS wire_transfer_holds (
    id SERIAL PRIMARY KEY,
    wire_transfer_id INT NOT NULL REFERENCES wire_transfers(id),
    role_at_bank VARCHAR(20) NOT NULL,                 -- 'INTERMEDIARY', 'BENEFICIARY'
    hold_reason TEXT,                                  -- description of missing data
    review_status VARCHAR(30) NOT NULL DEFAULT 'PENDING_REVIEW', 
    -- 'PENDING_REVIEW', 'APPROVED_RELEASE', 'APPROVED_REJECT', 'SUSPENDED_STR_ESCALATION'
    reviewed_by VARCHAR(100),
    reviewed_at TIMESTAMP,
    rationale TEXT CHECK (review_status = 'PENDING_REVIEW' OR length(trim(rationale)) > 0),
    logged_at TIMESTAMP NOT NULL DEFAULT now()
);

-- Correspondent Bank Completeness Tracking Log
CREATE TABLE IF NOT EXISTS correspondent_completeness_logs (
    id SERIAL PRIMARY KEY,
    institution_name VARCHAR(100) NOT NULL,
    wire_transfer_id INT NOT NULL REFERENCES wire_transfers(id),
    missing_fields_count INT NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT now()
);
