# n8n AML CDD Workflow — Complete Step-by-Step Implementation Guide

> **Written for someone who has never used n8n.** Every click, every node, every setting is documented.

---

## Part 0: Getting Started with n8n (2 minutes)

### 0.1 Open n8n
1. Open your browser → go to **http://localhost:5678**
2. First time only: n8n asks you to create an owner account (email + password). This is local, only for your machine.
3. You'll land on the **n8n dashboard** (a list of your workflows)

### 0.2 Create a New Workflow
1. Click **"Create Workflow"** (or "Start from Scratch")
2. You'll see the **canvas** — a blank workspace with a **"+"** button in the center
3. Click the workflow name at the top (says "My workflow") → rename it to `Customer Onboarding & CDD`

### 0.3 How n8n Works (30-second crash course)
- **Nodes** = individual steps (SQL query, code logic, etc.)
- **Connections** = wires between nodes. Data flows left → right.
- **To add a node:** Click the **+** button on the canvas, or drag from a node's right-side connector.
- **To configure a node:** Click on it → the settings panel opens.
- **To test:** Click **"Test workflow"** (top right) — runs it once immediately.
- **Credentials** are created **inside each node** when you first configure it (there's a credential dropdown → "Create New").

### 0.4 n8n Expression Syntax (Important!)
Throughout this guide you'll see `{{ }}` — these are **n8n expressions** (dynamic values). Key patterns:

| Syntax | What it does |
|---|---|
| `{{ $json.fieldName }}` | Access a field from the current node's input item |
| `{{ $("Node Name").first().json.fieldName }}` | Access data from a specific earlier node in the same active branch |
| `{{ $now }}` | Current timestamp |
| `{{ $workflow.id }}` | Current workflow ID |

---

## Part 1: Workflow Overview (Asynchronous Design)

Rather than keeping the client HTTP request waiting on a manual pause, the workflow is split into two asynchronous entry points:

### Flow A: Intake & Screening
```
Webhook Trigger (uc1-onboarding)
    │
[RE Gate & Checks... Phases 1 - 7]
    │
IF: Sr Mgmt Approval Needed?
       /               \
 [TRUE]/               \[FALSE]
      /                 \
Respond:                Auto-Approve (CDD/SDD) (Outputs case_id)
Pending Approval        [Downstream Account Creation... Phases 9 - 10]
(Returns HTTP 202)
```

### Flow B: Asynchronous Manager Approval
```
Manager Approval Webhook (POST uc1-approve-case)
    │
Get Case Details by Ref (Outputs case_id)
    │
Process Approval Decision (Outputs case_id)
    │
IF: Approved? ───[FALSE]───► Case -> REJECTED ───► Respond: Approval Rejected (HTTP 403)
    │
  [TRUE] (Outputs case_id)
    │
[Downstream Account Creation... Phases 9 - 10]
```

---

## Part 2: Build It — Node by Node

### Node 1: Webhook Trigger

This is the intake endpoint where customer onboarding requests are submitted.

1. Click the **"+"** button in the center of the canvas
2. In the search panel, type **"Webhook"** → click to add it
3. Set the following parameters:
   - **HTTP Method:** `POST`
   - **Path:** `uc1-onboarding`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook Trigger`**

---

### Node 2: RE Type Gate Lookup

Checks if the customer type category is permitted under the SBP rules for this RE type (Bank).

1. Click the **+** on the right side of **Webhook Trigger**
2. Search for **"Postgres"** → click to add it
3. Create the Database Credential:
   - Click the **Credential** dropdown at the top → select **"Create New Credential"**
   - Fill in:

   | Field | Value |
   |---|---|
   | **Host** | `postgres` |
   | **Database** | `aml_local` |
   | **User** | `aml_user` |
   | **Password** | `aml_password` |
   | **Port** | `5432` |
   | **SSL** | `disable` |

   - Click **Save**

4. Back in the node config:
   - **Operation:** `Execute Query`
   - **Query:** Paste this SQL:
     ```sql
     SELECT 
       rca.is_applicable, 
       rt.code as re_code, 
       rt.name as re_name, 
       rt.allows_legal_persons, 
       ct.code as ct_code, 
       ct.name as ct_name, 
       ct.legal_category, 
       ct.requires_beneficial_owner_check, 
       ct.requires_governing_body_cdd, 
       ct.mandatory_edd, 
       ct.id as customer_type_id, 
       rt.id as re_type_id 
     FROM re_customer_type_applicability rca 
     JOIN re_types rt ON rca.re_type_id = rt.id 
     JOIN customer_types ct ON rca.customer_type_id = ct.id 
     WHERE rt.code = 'BANK' AND ct.code = '{{ $json.body.customer_type_code }}' 
     LIMIT 1;
     ```
5. Rename to **`RE Type Gate Lookup`**

---

### Node 3: IF: Applicable?

Gates onboarding requests if the customer type is not allowed for Banks.

1. Click the **+** on the right side of **RE Type Gate Lookup**
2. Add an **IF** node
3. Set the following condition:
   - Click **Add Condition** → Select **Boolean**
   - **Value 1:** `{{ $json.is_applicable }}`
   - **Operator:** `equal` (or `Is True`)
   - **Value 2:** `true`
4. Rename to **`IF: Applicable?`**

---

### Node 4: Respond: Not Applicable

Rejects ineligible requests with HTTP 400.

1. Drag from the `IF: Applicable?` **false** output (bottom)
2. Add a **Respond to Webhook** node
3. Set parameters:
   - **Respond With:** Select **`JSON`** from the dropdown
   - **Response Body:** Switch to **Expression** mode and paste:
     ```json
     {
       "status": "REJECTED",
       "reason": "Customer type not applicable for this RE type (Bank)",
       "customer_type_code": "{{ $('Webhook Trigger').first().json.body.customer_type_code }}"
     }
     ```
   - Click the **Add option** dropdown under **Options** → Select **`Response Code`**
   - **Response Code:** Set this to `400`
4. Rename to **`Respond: Not Applicable`**

---

### Node 5: Insert CDD Case

Initializes a new CDD case record in `cdd_cases` and generates a sequential Case Ref.

1. Drag from the `IF: Applicable?` **true** output (top)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
  ```sql
  INSERT INTO cdd_cases (
    case_ref, 
    re_type_id, 
    customer_type_id, 
    is_occasional_customer, 
    suspicion_flag, 
    current_phase, 
    status
  ) VALUES ( 
    'CDD-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('cdd_cases_id_seq')::text, 6, '0'), 
    {{ $('RE Type Gate Lookup').first().json.re_type_id }}, 
    {{ $('RE Type Gate Lookup').first().json.customer_type_id }}, 
    {{ $('Webhook Trigger').first().json.body.is_occasional_customer || false }}, 
    {{ $('Webhook Trigger').first().json.body.suspicion_flag || false }}, 
    'DOC_COLLECTION', 
    'IN_PROGRESS' 
  ) RETURNING id, case_ref, suspicion_flag;
  ```
6. Rename to **`Insert CDD Case`**

---

### Node 6: Insert Primary Customer

Writes the primary applicant's details.

1. Click **+** on **Insert CDD Case** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  INSERT INTO customers (
    case_id, 
    role, 
    full_name, 
    mother_maiden_name, 
    father_spouse_name, 
    date_of_birth, 
    place_of_birth, 
    permanent_address, 
    current_mailing_address, 
    identity_doc_type, 
    identity_doc_number, 
    identity_doc_issue_date, 
    identity_doc_expiry_date, 
    contact_mobile, 
    contact_landline, 
    email, 
    nationality_status, 
    profession_source_of_income, 
    purpose_of_relationship, 
    next_of_kin, 
    fatca_crs_declared
  ) VALUES ( 
    {{ $('Insert CDD Case').first().json.id }}, 
    'PRIMARY', 
    '{{ $('Webhook Trigger').first().json.body.applicant.full_name }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.mother_maiden_name || '' }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.father_spouse_name || '' }}', 
    {{ $('Webhook Trigger').first().json.body.applicant.date_of_birth ? "'" + $('Webhook Trigger').first().json.body.applicant.date_of_birth + "'" : 'NULL' }}, 
    '{{ $('Webhook Trigger').first().json.body.applicant.place_of_birth || '' }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.permanent_address || '' }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.current_mailing_address || '' }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.identity_doc_type }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.identity_doc_number }}', 
    {{ $('Webhook Trigger').first().json.body.applicant.identity_doc_issue_date ? "'" + $('Webhook Trigger').first().json.body.applicant.identity_doc_issue_date + "'" : 'NULL' }}, 
    {{ $('Webhook Trigger').first().json.body.applicant.identity_doc_expiry_date ? "'" + $('Webhook Trigger').first().json.body.applicant.identity_doc_expiry_date + "'" : 'NULL' }}, 
    '{{ $('Webhook Trigger').first().json.body.applicant.contact_mobile || '' }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.contact_landline || '' }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.email || '' }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.nationality_status || 'RESIDENT' }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.profession_source_of_income || '' }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.purpose_of_relationship || '' }}', 
    '{{ $('Webhook Trigger').first().json.body.applicant.next_of_kin || '' }}', 
    {{ $('Webhook Trigger').first().json.body.applicant.fatca_crs_declared || false }} 
  ) RETURNING id, full_name;
  ```
5. Rename to **`Insert Primary Customer`**

---

### Node 7: Lookup Doc Checklist

Fetches required documents configured for this category.

1. Click **+** on **Insert Primary Customer** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  SELECT 
    dc.document_type, 
    dc.is_mandatory, 
    dc.applies_to_role, 
    dc.is_conditional, 
    dc.condition_description, 
    dc.regulation_ref 
  FROM document_checklist_config dc 
  WHERE dc.customer_type_id = {{ $('RE Type Gate Lookup').first().json.customer_type_id }};
  ```
5. Rename to **`Lookup Doc Checklist`**

---

### Node 8: Check Documents & Attestation

Verifies file presence and attestation constraints.

1. Click **+** on **Lookup Doc Checklist** → Add **Code** node
2. Set **Language:** `JavaScript`
3. Paste:
   ```javascript
   const requiredDocs = $('Lookup Doc Checklist').all().map(item => item.json);
   const submittedDocs = $('Webhook Trigger').first().json.body.documents || [];
   const customerTypeCode = $('RE Type Gate Lookup').first().json.ct_code;
   const hasCourtGuardian = $('Webhook Trigger').first().json.body.guardian_type === 'COURT_APPOINTED';
   const hasProtector = $('Webhook Trigger').first().json.body.trust_details?.protector_name ? true : false;

   const missing = [];
   const attestationErrors = [];
   const validDocs = [];

   for (const req of requiredDocs) {
     if (req.is_conditional) {
       if (req.document_type === 'COURT_GUARDIAN_ORDER' && !hasCourtGuardian) continue;
       if (req.applies_to_role === 'PROTECTOR' && !hasProtector) continue;
     }
     
     const submitted = submittedDocs.find(d => d.document_type === req.document_type && 
       (!req.applies_to_role || d.applies_to_role === req.applies_to_role));
     
     if (!submitted && req.is_mandatory) {
       missing.push({ document_type: req.document_type, applies_to_role: req.applies_to_role, regulation_ref: req.regulation_ref });
     } else if (submitted) {
       const hasAttestation = submitted.is_attested && submitted.attested_by;
       const hasVerification = ['NADRA_VERISYS', 'BIOMETRIC'].includes(submitted.verification_source);
       
       if (!hasAttestation && !hasVerification) {
         attestationErrors.push({ document_type: req.document_type, error: 'Document must be either attested (by Gazetted officer/RE officer) OR verified via NADRA Verisys/Biometric' });
       } else {
         validDocs.push(submitted);
       }
     }
   }

   const isComplete = missing.length === 0 && attestationErrors.length === 0;

   return [{
     json: {
       is_complete: isComplete,
       missing_documents: missing,
       attestation_errors: attestationErrors,
       valid_documents: validDocs,
       case_id: $('Insert CDD Case').first().json.id,
       case_ref: $('Insert CDD Case').first().json.case_ref,
       suspicion_flag: $('Insert CDD Case').first().json.suspicion_flag,
       customer_id: $('Insert Primary Customer').first().json.id,
       customer_type_code: customerTypeCode,
       re_type_id: $('RE Type Gate Lookup').first().json.re_type_id,
       customer_type_id: $('RE Type Gate Lookup').first().json.customer_type_id,
       mandatory_edd: $('RE Type Gate Lookup').first().json.mandatory_edd,
       requires_bo_check: $('RE Type Gate Lookup').first().json.requires_beneficial_owner_check,
       nationality_status: $('Webhook Trigger').first().json.body.applicant.nationality_status || 'RESIDENT'
     }
   }];
   ```
4. Rename to **`Check Documents & Attestation`**

---

### Node 9: IF: Docs Complete?

1. Click **+** on **Check Documents & Attestation** → Add **IF** node
2. Set condition:
   - **Value 1:** `{{ $json.is_complete }}`
   - **Operator:** `equal` (or `Is True`)
   - **Value 2:** `true`
3. Rename to **`IF: Docs Complete?`**

---

### Node 10: Case → ON_HOLD (Incomplete)

1. Drag from `IF: Docs Complete?` **false** output (bottom)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
  ```sql
  UPDATE cdd_cases 
  SET status = 'ON_HOLD', current_phase = 'DOC_COLLECTION' 
  WHERE id = {{ $json.case_id }}; 
  
  INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
  VALUES (
    {{ $json.case_id }}, 
    'cdd_cases', 
    {{ $json.case_id }}, 
    'DOCUMENTS_INCOMPLETE', 
    'SYSTEM', 
    '{{ JSON.stringify({ missing: $json.missing_documents, attestation_errors: $json.attestation_errors }) }}'::jsonb
  );
  ```
6. Rename to **`Case → ON_HOLD (Incomplete)`**

---

### Node 11: Respond: Incomplete Docs

Responds back with HTTP 422.

1. Click **+** from **Case → ON_HOLD (Incomplete)**
2. Add a **Respond to Webhook** node
3. Set parameters:
   - **Respond With:** Select **`JSON`** from the dropdown
   - **Response Body:** Switch to **Expression** mode and paste:
     ```json
     {
       "status": "ON_HOLD",
       "case_ref": "{{ $('Check Documents & Attestation').first().json.case_ref }}",
       "reason": "Incomplete submission",
       "missing_documents": {{ JSON.stringify($('Check Documents & Attestation').first().json.missing_documents) }},
       "attestation_errors": {{ JSON.stringify($('Check Documents & Attestation').first().json.attestation_errors) }}
     }
     ```
   - Click the **Add option** dropdown under **Options** → Select **`Response Code`**
   - **Response Code:** Set this to `422`
4. Rename to **`Respond: Incomplete Docs`**

---

### Node 12: Insert Documents

1. Drag from `IF: Docs Complete?` **true** output (top)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
  ```sql
  INSERT INTO documents (case_id, customer_id, document_type, file_ref, is_attested, attested_by, verification_source) 
  SELECT 
    {{ $json.case_id }}, 
    {{ $json.customer_id }}, 
    d->>'document_type', 
    d->>'file_ref', 
    (d->>'is_attested')::boolean, 
    d->>'attested_by', 
    d->>'verification_source' 
  FROM jsonb_array_elements('{{ JSON.stringify($json.valid_documents) }}'::jsonb) AS d; 
  
  UPDATE cdd_cases SET current_phase = 'IDENTITY_VERIFICATION' WHERE id = {{ $json.case_id }}; 
  
  INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
  VALUES (
    {{ $json.case_id }}, 
    'documents', 
    NULL, 
    'DOCUMENTS_COLLECTED', 
    'SYSTEM', 
    '{"count": {{ $json.valid_documents.length }}}'::jsonb
  );
  ```
6. Rename to **`Insert Documents`**

---

## Phase 2: Identity Verification

### 13. Node: `Identity Verification (Mock)`

Simulates identity checks. Qualifies resident individuals for deferred verification.

1. Click **+** on **Insert Documents** → Add **Code** node
2. Set **Language:** `JavaScript`
3. Paste:
   ```javascript
   const data = $('Check Documents & Attestation').first().json;
   const ct = data.customer_type_code;
   const mandatoryEdd = data.mandatory_edd;
   const nationality = data.nationality_status;

   const isProvisionallyLow = 
     ['INDIVIDUAL'].includes(ct) && 
     !mandatoryEdd && 
     nationality === 'RESIDENT';

   const applicant = $('Webhook Trigger').first().json.body.applicant;
   const mockVerified = applicant.identity_doc_number && applicant.identity_doc_number.length >= 10;

   const isEntityType = ['COMPANY', 'TRUST_CLUB_SOCIETY', 'NGO_NPO'].includes(ct);
   const regDocsPresent = !isEntityType || data.valid_documents?.some(d => 
     ['MEMORANDUM_ARTICLES_OF_ASSOCIATION', 'CERTIFICATE_OF_REGISTRATION_OR_INSTRUMENT_OF_TRUST', 'REGISTRATION_DOCUMENTS_OR_SECP_LICENSE'].includes(d.document_type)
   );

   const verificationPassed = mockVerified && regDocsPresent;
   const deferVerification = isProvisionallyLow && verificationPassed;

   return [{
     json: {
       ...data,
       verification_passed: verificationPassed,
       verification_deferred: deferVerification,
       sdd_eligibility_basis: deferVerification ? 'IRAR_CONFIG_V1' : null,
       mock_verisys_result: { verified: mockVerified, doc_number: applicant.identity_doc_number }
     }
   }];
   ```
4. Rename to **`Identity Verification (Mock)`**

---

### 14. Node: `IF: Verification Passed?`

1. Click **+** on **Identity Verification (Mock)** → Add **IF** node
2. Set condition:
   - **Value 1:** `{{ $json.verification_passed }}`
   - **Operator:** `equal` (or `Is True`)
   - **Value 2:** `true`
3. Rename to **`IF: Verification Passed?`**

---

### 15. Node: `Case → REJECTED (Verification)`

1. Drag from `IF: Verification Passed?` **false** output (bottom)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
  ```sql
  UPDATE cdd_cases 
  SET status = 'REJECTED', current_phase = 'REJECTED', closed_at = now() 
  WHERE id = {{ $json.case_id }}; 
  
  INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
  VALUES (
    {{ $json.case_id }}, 
    'cdd_cases', 
    {{ $json.case_id }}, 
    'IDENTITY_VERIFICATION_FAILED', 
    'SYSTEM', 
    '{"reason": "Verification failed"}'::jsonb
  );
  ```
6. Rename to **`Case → REJECTED (Verification)`**

---

### 16. Node: `Respond: Verification Failed`

1. Click **+** from **Case → REJECTED (Verification)**
2. Add a **Respond to Webhook** node
3. Set parameters:
   - **Respond With:** Select **`JSON`** from the dropdown
   - **Response Body:** Switch to **Expression** mode and paste:
     ```json
     {
       "status": "REJECTED",
       "case_ref": "{{ $('Check Documents & Attestation').first().json.case_ref }}",
       "reason": "Identity verification failed"
     }
     ```
   - Click the **Add option** dropdown under **Options** → Select **`Response Code`**
   - **Response Code:** Set this to `422`
4. Rename to **`Respond: Verification Failed`**

---

### 17. Node: `Update Verification Status`

1. Drag from `IF: Verification Passed?` **true** output (top)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
  ```sql
  UPDATE cdd_cases 
  SET 
    current_phase = 'BENEFICIAL_OWNERSHIP', 
    verification_deferred = {{ $json.verification_deferred }}, 
    sdd_eligibility_basis = {{ $json.sdd_eligibility_basis ? "'" + $json.sdd_eligibility_basis + "'" : 'NULL' }} 
  WHERE id = {{ $json.case_id }}; 
  
  UPDATE documents 
  SET verified_at = now(), verification_source = 'NADRA_VERISYS' 
  WHERE case_id = {{ $json.case_id }} AND verification_source IS NULL; 
  
  INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
  VALUES (
    {{ $json.case_id }}, 
    'cdd_cases', 
    {{ $json.case_id }}, 
    'IDENTITY_VERIFIED', 
    'SYSTEM', 
    '{{ JSON.stringify({ deferred: $json.verification_deferred, sdd_basis: $json.sdd_eligibility_basis }) }}'::jsonb
  );
  ```
6. Rename to **`Update Verification Status`**

---

## Phase 3: Beneficial Ownership Check

### 18. Node: `Beneficial Ownership Check`

Implements SBP BO verification rules.

1. Click **+** on **Update Verification Status** → Add **Code** node
2. Set **Language:** `JavaScript`
3. Paste:
   ```javascript
   const data = $('Identity Verification (Mock)').first().json;
   const ct = data.customer_type_code;
   const requiresBO = data.requires_bo_check;
   const payload = $('Webhook Trigger').first().json.body;

   const boRecords = [];

   if (!requiresBO) {
     return [{ json: { ...data, bo_records: [], bo_skipped: true } }];
   }

   if (ct === 'COMPANY') {
     const owners = payload.beneficial_owners || [];
     const majorityOwners = owners.filter(o => o.ownership_percentage > 25);
     
     if (majorityOwners.length > 0) {
       for (const o of majorityOwners) {
         boRecords.push({ ...o, identification_tier: 'OWNERSHIP' });
       }
     } else {
       const controllers = owners.filter(o => o.has_control);
       if (controllers.length > 0) {
         for (const c of controllers) {
           boRecords.push({ ...c, identification_tier: 'CONTROL' });
         }
       } else {
         const seniorOfficial = payload.senior_managing_official || { full_name: 'Not Provided', ownership_percentage: 0 };
         boRecords.push({ ...seniorOfficial, identification_tier: 'SENIOR_OFFICIAL' });
       }
     }
   } else if (['TRUST_CLUB_SOCIETY', 'NGO_NPO'].includes(ct)) {
     const trustDetails = payload.trust_details || {};
     
     if (trustDetails.settlor_name) {
       boRecords.push({ full_name: trustDetails.settlor_name, identification_tier: 'OWNERSHIP', role: 'SETTLOR' });
     }
     if (trustDetails.trustees) {
       for (const t of trustDetails.trustees) {
         boRecords.push({ full_name: t.full_name, identification_tier: 'CONTROL', role: 'TRUSTEE' });
       }
     }
     if (trustDetails.protector_name) {
       boRecords.push({ full_name: trustDetails.protector_name, identification_tier: 'CONTROL', role: 'PROTECTOR' });
     }
     if (trustDetails.beneficiaries) {
       for (const b of trustDetails.beneficiaries) {
         boRecords.push({ full_name: b.full_name, identification_tier: 'OWNERSHIP', role: 'BENEFICIARY' });
       }
     }
   }

   return [{ json: { ...data, bo_records: boRecords, bo_skipped: false } }];
   ```
4. Rename to **`Beneficial Ownership Check`**

---

### 19. Node: `Insert BO Records`

1. Click **+** on **Beneficial Ownership Check** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  DO $$ 
  DECLARE 
    bo_data jsonb := '{{ JSON.stringify($json.bo_records) }}'::jsonb; 
    bo record; 
    cust_id int; 
  BEGIN 
    IF jsonb_array_length(bo_data) > 0 THEN 
      FOR bo IN SELECT * FROM jsonb_array_elements(bo_data) LOOP 
        INSERT INTO customers (case_id, role, full_name) 
        VALUES ({{ $json.case_id }}, COALESCE(bo.value->>'role', 'BENEFICIAL_OWNER'), bo.value->>'full_name') 
        RETURNING id INTO cust_id; 
        
        INSERT INTO beneficial_owners (case_id, customer_id, identification_tier, ownership_percentage, verified) 
        VALUES ({{ $json.case_id }}, cust_id, bo.value->>'identification_tier', COALESCE((bo.value->>'ownership_percentage')::numeric, 0), FALSE); 
      END LOOP; 
    END IF; 
    
    UPDATE cdd_cases SET current_phase = 'PEP_SCREENING' WHERE id = {{ $json.case_id }}; 
    
    INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
    VALUES (
      {{ $json.case_id }}, 
      'beneficial_owners', 
      NULL, 
      CASE WHEN {{ $json.bo_skipped }} THEN 'BO_CHECK_SKIPPED' ELSE 'BO_CHECK_COMPLETED' END, 
      'SYSTEM', 
      ('{{ JSON.stringify({ count: $json.bo_records.length, skipped: $json.bo_skipped }) }}')::jsonb
    ); 
  END $$;
  ```
5. Rename to **`Insert BO Records`**

---

## Phase 4: PEP Screening

### 20. Node: `PEP Screening`

1. Click **+** on **Insert BO Records** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  SELECT 
    c.id as customer_id, 
    c.full_name, 
    c.role, 
    CASE WHEN pw.id IS NOT NULL THEN TRUE ELSE FALSE END as is_pep, 
    pw.pep_category, 
    pw.relationship_type, 
    pw.related_pep_name, 
    pw.position_title 
  FROM customers c 
  LEFT JOIN pep_watchlist_seed pw ON LOWER(c.full_name) = LOWER(pw.full_name) 
  WHERE c.case_id = {{ $('Check Documents & Attestation').first().json.case_id }};
  ```
5. Rename to **`PEP Screening`**

---

### 21. Node: `Process PEP Results`

1. Click **+** on **PEP Screening** → Add **Code** node
2. Set **Language:** `JavaScript`
3. Paste:
   ```javascript
   const data = $('Beneficial Ownership Check').first().json;
   const pepResults = $('PEP Screening').all().map(item => item.json);

   const pepMatches = pepResults.filter(r => r.is_pep);
   const hasPepMatch = pepMatches.length > 0;

   return [{
     json: {
       ...data,
       pep_matches: pepMatches,
       has_pep_match: hasPepMatch,
       all_screened_persons: pepResults,
       edd_from_pep: hasPepMatch
     }
   }];
   ```
4. Rename to **`Process PEP Results`**

---

### 22. Node: `Insert PEP Results`

1. Click **+** on **Process PEP Results** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  DO $$ 
  DECLARE 
    pep_data jsonb := '{{ JSON.stringify($json.all_screened_persons) }}'::jsonb; 
    p record; 
  BEGIN 
    FOR p IN SELECT * FROM jsonb_array_elements(pep_data) LOOP 
      INSERT INTO pep_screening_results (case_id, customer_id, is_pep, pep_category, relationship_to_pep, match_confidence) 
      VALUES ( 
        {{ $json.case_id }}, 
        (p.value->>'customer_id')::int, 
        (p.value->>'is_pep')::boolean, 
        p.value->>'pep_category', 
        p.value->>'relationship_type', 
        CASE WHEN (p.value->>'is_pep')::boolean THEN 100.00 ELSE 0.00 END 
      ); 
    END LOOP; 
    
    INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
    VALUES (
      {{ $json.case_id }}, 
      'pep_screening_results', 
      NULL, 
      'PEP_SCREENING_COMPLETED', 
      'SYSTEM', 
      ('{{ JSON.stringify({ matches: $json.pep_matches.length, total_screened: $json.all_screened_persons.length }) }}')::jsonb
    ); 
  END $$;
  ```
5. Rename to **`Insert PEP Results`**

---

## Phase 5: Targeted Financial Sanctions (TFS) Screening

### 23. Node: `TFS Screening`

1. Click **+** on **Insert PEP Results** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  SELECT 
    c.id as customer_id, 
    c.full_name, 
    c.role, 
    CASE WHEN sw.id IS NOT NULL THEN TRUE ELSE FALSE END as is_sanctioned, 
    sw.list_type 
  FROM customers c 
  LEFT JOIN sanctions_watchlist_seed sw ON LOWER(c.full_name) = LOWER(sw.full_name) 
  WHERE c.case_id = {{ $('Check Documents & Attestation').first().json.case_id }};
  ```
5. Rename to **`TFS Screening`**

---

### 24. Node: `Process TFS Results`

1. Click **+** on **TFS Screening** → Add **Code** node
2. Set **Language:** `JavaScript`
3. Paste:
   ```javascript
   const data = $('Process PEP Results').first().json;
   const tfsResults = $('TFS Screening').all().map(item => item.json);

   const sanctionMatches = tfsResults.filter(r => r.is_sanctioned);
   const hasSanctionMatch = sanctionMatches.length > 0;

   return [{
     json: {
       ...data,
       tfs_matches: sanctionMatches,
       has_sanction_match: hasSanctionMatch,
       all_tfs_screened: tfsResults
     }
   }];
   ```
4. Rename to **`Process TFS Results`**

---

### 25. Node: `IF: No Sanctions Match?`

1. Click **+** on **Process TFS Results** → Add **IF** node
2. Set condition:
   - **Value 1:** `{{ $json.has_sanction_match }}`
   - **Operator:** `equal` (or `Is True`)
   - **Value 2:** `true`
3. Rename to **`IF: No Sanctions Match?`**

---

### 26. Node: `FREEZE & Reject (TFS Match)`

Implements asset freeze per SBP rules.

1. Drag from `IF: No Sanctions Match?` **false** output (bottom)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
  ```sql
  DO $$ 
  DECLARE 
    tfs_data jsonb := '{{ JSON.stringify($json.tfs_matches) }}'::jsonb; 
    t record; 
  BEGIN 
    FOR t IN SELECT * FROM jsonb_array_elements(tfs_data) LOOP 
      INSERT INTO tfs_screening_results (case_id, customer_id, match_found, list_type, action_taken, frozen_at, reported_within_48h) 
      VALUES ( 
        {{ $json.case_id }}, 
        (t.value->>'customer_id')::int, 
        TRUE, 
        t.value->>'list_type', 
        'FROZEN', 
        now(), 
        TRUE 
      ); 
    END LOOP; 
    
    UPDATE cdd_cases 
    SET status = 'REJECTED', current_phase = 'REJECTED', suspicion_flag = TRUE, closed_at = now() 
    WHERE id = {{ $json.case_id }}; 
    
    INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
    VALUES (
      {{ $json.case_id }}, 
      'tfs_screening_results', 
      NULL, 
      'TFS_MATCH_FROZEN', 
      'SYSTEM', 
      ('{{ JSON.stringify({ matches: $json.tfs_matches, deadline_48h: new Date(Date.now() + 48*60*60*1000).toISOString() }) }}')::jsonb
    ); 
  END $$;
  ```
6. Rename to **`FREEZE & Reject (TFS Match)`**

---

### 27. Node: `Respond: Frozen`

1. Click **+** from **FREEZE & Reject (TFS Match)**
2. Add a **Respond to Webhook** node
3. Set parameters:
   - **Respond With:** Select **`JSON`** from the dropdown
   - **Response Body:** Switch to **Expression** mode and paste:
     ```json
     {
       "status": "FROZEN",
       "case_ref": "{{ $('Check Documents & Attestation').first().json.case_ref }}",
       "reason": "TFS/Sanctions match found — assets frozen per Reg 4 §7",
       "matches": {{ JSON.stringify($('Process TFS Results').first().json.tfs_matches) }},
       "sbp_report_deadline": "Within 48 hours of freezing (Reg 4 §7(c))"
     }
     ```
   - Click the **Add option** dropdown under **Options** → Select **`Response Code`**
   - **Response Code:** Set this to `403`
4. Rename to **`Respond: Frozen`**

---

### 28. Node: `Insert TFS Clear Results`

1. Drag from `IF: No Sanctions Match?` **true** output (top)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
  ```sql
  DO $$ 
  DECLARE 
    tfs_data jsonb := '{{ JSON.stringify($json.all_tfs_screened) }}'::jsonb; 
    t record; 
  BEGIN 
    FOR t IN SELECT * FROM jsonb_array_elements(tfs_data) LOOP 
      INSERT INTO tfs_screening_results (case_id, customer_id, match_found, list_type, action_taken) 
      VALUES ( 
        {{ $json.case_id }}, 
        (t.value->>'customer_id')::int, 
        FALSE, 
        NULL, 
        'NONE' 
      ); 
    END LOOP; 
    
    UPDATE cdd_cases SET current_phase = 'RISK_PROFILING' WHERE id = {{ $json.case_id }}; 
    
    INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
    VALUES (
      {{ $json.case_id }}, 
      'tfs_screening_results', 
      NULL, 
      'TFS_SCREENING_CLEAR', 
      'SYSTEM', 
      '{"matches": 0}'::jsonb
    ); 
  END $$;
  ```
6. Rename to **`Insert TFS Clear Results`**

---

## Phase 6 & 7: Risk Profiling & DD Determination (IRAR-driven)

### 29. Node: `Load IRAR Config (Reg 1)`

1. Click **+** on **Insert TFS Clear Results** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  SELECT * FROM irar_config WHERE is_active = TRUE LIMIT 1;
  ```
5. Rename to **`Load IRAR Config (Reg 1)`**

---

### 30. Node: `Risk Profiling & DD Determination`

Calculates risk score and applies the **Reg 2 §19 suspicion guard** (suspicion revokes SDD).

1. Click **+** on **Load IRAR Config (Reg 1)** → Add **Code** node
2. Set **Language:** `JavaScript`
3. Paste:
   ```javascript
   const data = $('Process TFS Results').first().json;
   const irar = $('Load IRAR Config (Reg 1)').first().json;

   let score = 0;
   const factors = {};

   if (['TRUST_CLUB_SOCIETY', 'NGO_NPO'].includes(data.customer_type_code)) {
     score += parseFloat(irar.weight_customer_type_high);
     factors.customer_type = parseFloat(irar.weight_customer_type_high);
   } else if (['COMPANY', 'FOREIGN_BRANCH', 'LLP', 'PARTNERSHIP'].includes(data.customer_type_code)) {
     score += parseFloat(irar.weight_customer_type_medium);
     factors.customer_type = parseFloat(irar.weight_customer_type_medium);
   } else {
     factors.customer_type = 0;
   }

   if (data.has_pep_match) {
     const hasDirectPep = data.pep_matches.some(m => m.relationship_type === 'DIRECT');
     if (hasDirectPep) {
       score += parseFloat(irar.weight_pep_match);
       factors.pep = parseFloat(irar.weight_pep_match);
     } else {
       score += parseFloat(irar.weight_pep_family);
       factors.pep_family = parseFloat(irar.weight_pep_family);
     }
   } else {
     factors.pep = 0;
   }

   if (data.nationality_status === 'NON_RESIDENT') {
     score += parseFloat(irar.weight_foreign_nationality);
     factors.foreign_nationality = parseFloat(irar.weight_foreign_nationality);
   } else {
     factors.foreign_nationality = 0;
   }

   let riskTier;
   if (score <= parseFloat(irar.threshold_low_max)) {
     riskTier = 'LOW';
   } else if (score <= parseFloat(irar.threshold_medium_max)) {
     riskTier = 'MEDIUM';
   } else {
     riskTier = 'HIGH';
   }

   const suspicionFlag = data.suspicion_flag || data.has_sanction_match;
   const mandatoryEdd = data.mandatory_edd;
   const eddFromPep = data.edd_from_pep;

   let ddType;
   let triggerReason;
   let seniorMgRequired = false;

   if (suspicionFlag) {
     ddType = 'EDD';
     triggerReason = 'SUSPICION_FLAG';
     seniorMgRequired = true;
   } else if (riskTier === 'HIGH' && irar.edd_required_for_high) {
     ddType = 'EDD';
     triggerReason = 'HIGH_RISK_TIER';
     seniorMgRequired = true;
   } else if (mandatoryEdd && irar.edd_required_for_high) {
     ddType = 'EDD';
     triggerReason = 'NGO_TRUST_MANDATORY';
     seniorMgRequired = true;
   } else if (eddFromPep && irar.edd_mandatory_for_pep) {
     ddType = 'EDD';
     triggerReason = 'PEP_MATCH';
     seniorMgRequired = true;
   } else if (riskTier === 'LOW' && irar.sdd_allowed_for_low && !suspicionFlag) {
     ddType = 'SDD';
     triggerReason = 'LOW_RISK_TIER';
   } else {
     ddType = 'CDD';
     triggerReason = 'STANDARD_RISK';
   }

   const measures = [];
   if (ddType === 'EDD') {
     measures.push({ code: 'EDD_A', is_completed: false });
     measures.push({ code: 'EDD_B', is_completed: false });
     measures.push({ code: 'EDD_C', is_completed: false });
     measures.push({ code: 'EDD_E', is_completed: false });
     measures.push({ code: 'EDD_F', is_completed: false });
     measures.push({ code: 'EDD_G', is_completed: false });
   } else if (ddType === 'SDD') {
     measures.push({ code: 'SDD_A', is_completed: data.verification_deferred });
     measures.push({ code: 'SDD_B', is_completed: false });
     measures.push({ code: 'SDD_C', is_completed: true });
   }

   return [{
     json: {
       ...data,
       risk_score: score,
       risk_tier: riskTier,
       scoring_factors: factors,
       irar_config_id: irar.id,
       irar_config_version: irar.config_version,
       dd_type: ddType,
       dd_trigger_reason: triggerReason,
       senior_mgmt_approval_required: seniorMgRequired,
       dd_measures: measures
     }
   }];
   ```
4. Rename to **`Risk Profiling & DD Determination`**

---

### Node 31: Insert Risk & DD

1. Click **+** on **Risk Profiling & DD Determination** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  INSERT INTO risk_profile (case_id, irar_config_id, risk_tier, score, scoring_factors, assigned_by) 
  VALUES ({{ $json.case_id }}, {{ $json.irar_config_id }}, '{{ $json.risk_tier }}', {{ $json.risk_score }}, '{{ JSON.stringify($json.scoring_factors) }}'::jsonb, 'SYSTEM'); 
  
  INSERT INTO dd_determination (case_id, dd_type, trigger_reason, senior_mgmt_approval_required) 
  VALUES ({{ $json.case_id }}, '{{ $json.dd_type }}', '{{ $json.dd_trigger_reason }}', {{ $json.senior_mgmt_approval_required }}) 
  RETURNING id;
  ```
5. Rename to **`Insert Risk & DD`**

---

### Node 32: Insert DD Measures

1. Click **+** on **Insert Risk & DD** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  DO $$ 
  DECLARE 
    dd_id int; 
    measures jsonb := '{{ JSON.stringify($('Risk Profiling & DD Determination').first().json.dd_measures) }}'::jsonb; 
    m record; 
  BEGIN 
    SELECT id INTO dd_id FROM dd_determination WHERE case_id = {{ $('Risk Profiling & DD Determination').first().json.case_id }} ORDER BY id DESC LIMIT 1; 
    
    IF jsonb_array_length(measures) > 0 THEN 
      FOR m IN SELECT * FROM jsonb_array_elements(measures) LOOP 
        INSERT INTO dd_determination_measures (dd_determination_id, measure_code, is_completed) 
        VALUES (dd_id, m.value->>'code', (m.value->>'is_completed')::boolean); 
      END LOOP; 
    END IF; 
    
    UPDATE cdd_cases SET current_phase = 'APPROVAL' WHERE id = {{ $('Risk Profiling & DD Determination').first().json.case_id }} ; 
    
    INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
    VALUES (
      {{ $('Risk Profiling & DD Determination').first().json.case_id }}, 
      'dd_determination', 
      dd_id, 
      'DD_DETERMINED', 
      'SYSTEM', 
      ('{{ JSON.stringify({ dd_type: $('Risk Profiling & DD Determination').first().json.dd_type, risk_tier: $('Risk Profiling & DD Determination').first().json.risk_tier, measures_count: $('Risk Profiling & DD Determination').first().json.dd_measures.length }) }}')::jsonb
    ); 
  END $$;
  ```
5. Rename to **`Insert DD Measures`**

---

## Phase 8: Senior Management Approval (Asynchronous Design)

### Node 33: IF: Sr Mgmt Approval Needed?

1. Click **+** on **Insert DD Measures** → Add **IF** node
2. Set condition:
   - **Value 1:** `{{ $('Risk Profiling & DD Determination').first().json.senior_mgmt_approval_required }}`
   - **Operator:** `equal` (or `Is True`)
   - **Value 2:** `true`
3. Rename to **`IF: Sr Mgmt Approval Needed?`**

---

### Node 34 (True Path): Respond: Pending Approval

1. Drag from `IF: Sr Mgmt Approval Needed?` **true** output (top)
2. Add a **Respond to Webhook** node
3. Set parameters:
   - **Respond With:** Select **`JSON`** from the dropdown
   - **Response Body:** Switch to **Expression** mode and paste:
     ```json
     {
       "status": "PENDING_APPROVAL",
       "case_ref": "{{ $('Check Documents & Attestation').first().json.case_ref }}",
       "reason": "Case requires senior management approval (EDD/PEP/Trust/NGO/High Risk)"
     }
     ```
   - Click the **Add option** dropdown under **Options** → Select **`Response Code`**
   - **Response Code:** Set this to `202`
4. Rename to **`Respond: Pending Approval`**

---

### Node 39 (False Path): Auto-Approve (CDD/SDD)

If the case doesn't need approval, we insert the mock approval record and return the `case_id` so downstream nodes can consume it locally.

1. Drag from `IF: Sr Mgmt Approval Needed?` **false** output (bottom)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
  ```sql
  INSERT INTO approvals (case_id, approver_name, approver_role, decision, decision_at, comments) 
  VALUES (
    {{ $('Risk Profiling & DD Determination').first().json.case_id }}, 
    'Auto-Approved', 
    'COMPLIANCE_OFFICER', 
    'APPROVED', 
    now(), 
    'CDD/SDD case — no senior management approval required'
  ); 
  
  INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
  VALUES (
    {{ $('Risk Profiling & DD Determination').first().json.case_id }}, 
    'approvals', 
    NULL, 
    'AUTO_APPROVED', 
    'SYSTEM', 
    '{"reason": "No senior management approval required for CDD/SDD"}'::jsonb
  );

  SELECT {{ $('Risk Profiling & DD Determination').first().json.case_id }}::int as case_id;
  ```
6. Rename to **`Auto-Approve (CDD/SDD)`**

---

## Flow B: Senior Management Approval Callback

### Node 34-B: Manager Approval Webhook (Trigger)

1. Click the **"+"** button on the canvas (unconnected to any node) to create a new entry point.
2. Search for **"Webhook"** node → click to add it
3. Set parameters:
   - **HTTP Method:** `POST`
   - **Path:** `uc1-approve-case`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Manager Approval Webhook`**

---

### Node 34-C: Get Case Details by Ref

1. Click **+** on **Manager Approval Webhook** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  SELECT 
    c.id as case_id, 
    c.status, 
    c.current_phase, 
    rp.risk_tier, 
    dd.dd_type, 
    dd.id as dd_determination_id
  FROM cdd_cases c
  LEFT JOIN risk_profile rp ON c.id = rp.case_id
  LEFT JOIN dd_determination dd ON c.id = dd.case_id
  WHERE c.case_ref = '{{ $('Manager Approval Webhook').first().json.body.case_ref }}'
  ORDER BY dd.id DESC LIMIT 1;
  ```
5. Rename to **`Get Case Details by Ref`**

---

### Node 35: Process Approval Decision

Inserts the decision and outputs the `case_id`.

1. Click **+** on **Get Case Details by Ref** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  INSERT INTO approvals (case_id, approver_name, approver_role, decision, decision_at, comments) 
  VALUES (
    {{ $('Get Case Details by Ref').first().json.case_id }}, 
    '{{ $('Manager Approval Webhook').first().json.body.approver_name || 'Senior Manager' }}', 
    '{{ $('Manager Approval Webhook').first().json.body.approver_role || 'SENIOR_MANAGEMENT' }}', 
    '{{ $('Manager Approval Webhook').first().json.body.decision }}', 
    now(), 
    '{{ $('Manager Approval Webhook').first().json.body.comments || '' }}'
  ); 
  
  UPDATE dd_determination 
  SET 
    senior_mgmt_approved_by = '{{ $('Manager Approval Webhook').first().json.body.approver_name || 'Senior Manager' }}', 
    senior_mgmt_approved_at = now() 
  WHERE case_id = {{ $('Get Case Details by Ref').first().json.case_id }}; 
  
  UPDATE dd_determination_measures 
  SET is_completed = TRUE, completed_at = now() 
  WHERE dd_determination_id = {{ $('Get Case Details by Ref').first().json.dd_determination_id }} 
    AND measure_code = 'EDD_F'; 
  
  INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
  VALUES (
    {{ $('Get Case Details by Ref').first().json.case_id }}, 
    'approvals', 
    NULL, 
    'SENIOR_MGMT_DECISION', 
    '{{ $('Manager Approval Webhook').first().json.body.approver_name || 'Senior Manager' }}', 
    ('{{ JSON.stringify({ decision: $('Manager Approval Webhook').first().json.body.decision }) }}')::jsonb
  );

  SELECT {{ $('Get Case Details by Ref').first().json.case_id }}::int as case_id;
  ```
6. Rename to **`Process Approval Decision`**

---

### Node 36: IF: Approved?

1. Click **+** on **Process Approval Decision** → Add **IF** node
2. Set condition:
   - **Value 1:** `{{ $('Manager Approval Webhook').first().json.body.decision }}`
   - **Operator:** `equal`
   - **Value 2:** `APPROVED`
3. Rename to **`IF: Approved?`**

---

### Node 37: Case → REJECTED (Approval)

1. Drag from `IF: Approved?` **false** output (bottom)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
  ```sql
  UPDATE cdd_cases 
  SET status = 'REJECTED', current_phase = 'REJECTED', closed_at = now() 
  WHERE id = {{ $json.case_id }}; 
  
  INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
  VALUES (
    {{ $json.case_id }}, 
    'cdd_cases', 
    {{ $json.case_id }}, 
    'APPROVAL_REJECTED', 
    'SYSTEM', 
    '{}'::jsonb
  );
  ```
6. Rename to **`Case → REJECTED (Approval)`**

---

### Node 38: Respond: Approval Rejected

1. Click **+** on **Case → REJECTED (Approval)**
2. Add a **Respond to Webhook** node
3. Set parameters:
   - **Respond With:** Select **`JSON`** from the dropdown
   - **Response Body:** Switch to **Expression** mode and paste:
     ```json
     {
       "status": "REJECTED",
       "case_ref": "{{ $('Manager Approval Webhook').first().json.body.case_ref }}",
       "reason": "Senior management rejected the case"
     }
     ```
   - Click the **Add option** dropdown under **Options** → Select **`Response Code`**
   - **Response Code:** Set this to `403`
4. Rename to **`Respond: Approval Rejected`**

---

## Phase 9 & 10: Merged Account Creation Gate & Response

### Node 40: Check All Measures Complete

This node is shared by both flows. It receives `case_id` directly in its input `$json` from the preceding nodes, fetches the entire case details context, and outputs the aggregated risk and measure details. 

*(Under SBP rules, SDD/CDD cases bypass the EDD measures block, and EDD cases are gated strictly on senior management approval `EDD_F`).*

1. Connect the **inputs** of this Postgres node to:
   - `IF: Approved?` **true** output (top)
   - `Auto-Approve (CDD/SDD)` output (bottom)
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  SELECT 
    c.id as case_id, 
    c.case_ref, 
    rp.risk_tier, 
    rp.score as risk_score, 
    dd.dd_type, 
    dd.trigger_reason as dd_trigger_reason, 
    c.verification_deferred,
    (SELECT config_version FROM irar_config WHERE id = rp.irar_config_id) as irar_version,
    CASE 
      WHEN dd.dd_type != 'EDD' THEN TRUE
      WHEN (SELECT is_completed FROM dd_determination_measures WHERE dd_determination_id = dd.id AND measure_code = 'EDD_F') THEN TRUE
      ELSE FALSE 
    END as all_measures_complete, 
    COUNT(m.id) as total_measures, 
    SUM(CASE WHEN m.is_completed THEN 1 ELSE 0 END) as completed_measures 
  FROM cdd_cases c 
  LEFT JOIN risk_profile rp ON c.id = rp.case_id 
  LEFT JOIN dd_determination dd ON c.id = dd.case_id 
  LEFT JOIN dd_determination_measures m ON dd.id = m.dd_determination_id 
  WHERE c.id = {{ $json.case_id }} 
  GROUP BY c.id, c.case_ref, rp.risk_tier, rp.score, dd.dd_type, dd.trigger_reason, rp.irar_config_id, dd.id;
  ```
5. Rename to **`Check All Measures Complete`**

---

### Node 41: IF: Measures Complete?

1. Click **+** on **Check All Measures Complete** → Add **IF** node
2. Set condition:
   - **Value 1:** `{{ $json.all_measures_complete }}`
   - **Operator:** `equal` (or `Is True`)
   - **Value 2:** `true`
3. Rename to **`IF: Measures Complete?`**

---

### Node 42: Block: Measures Incomplete

1. Drag from `IF: Measures Complete?` **false** output (bottom)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
  ```sql
  UPDATE cdd_cases 
  SET status = 'ON_HOLD', current_phase = 'APPROVAL' 
  WHERE id = {{ $json.case_id }}; 
  
  INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
  VALUES (
    {{ $json.case_id }}, 
    'dd_determination_measures', 
    NULL, 
    'MEASURES_INCOMPLETE_BLOCKED', 
    'SYSTEM', 
    ('{{ JSON.stringify({ total: $json.total_measures, completed: $json.completed_measures }) }}')::jsonb
  );
  ```
6. Rename to **`Block: Measures Incomplete`**

---

### Node 43: Respond: Measures Incomplete

1. Click **+** on **Block: Measures Incomplete**
2. Add a **Respond to Webhook** node
3. Set parameters:
   - **Respond With:** Select **`JSON`** from the dropdown
   - **Response Body:** Click the **Expression** tab and paste:
     ```javascript
     ={{
       status: "ON_HOLD",
       case_ref: $json.case_ref,
       reason: "EDD measures incomplete — account creation blocked",
       total_measures: $json.total_measures,
       completed_measures: $json.completed_measures
     }}
     ```
4. Rename to **`Respond: Measures Incomplete`**

---

### Node 44: Generate Account Number

Generates a randomized non-sequential IBAN placeholder.

1. Drag from `IF: Measures Complete?` **true** output (top)
2. Add a **Code** node
3. Set **Language:** `JavaScript`
4. Paste:
   ```javascript
   const caseData = $json;
   const ddType = caseData.dd_type;

   const timestamp = Date.now().toString(36).toUpperCase();
   const random = Math.random().toString(36).substring(2, 8).toUpperCase();
   const accountNumber = `PK-${timestamp}-${random}`;

   const monitoringTier = ddType === 'EDD' ? 'ENHANCED' : 'STANDARD';

   return [{ json: { ...caseData, account_number: accountNumber, monitoring_tier: monitoringTier } }];
   ```
4. Rename to **`Generate Account Number`**

---

### Node 45: Create Account

1. Click **+** on **Generate Account Number** → Add **Postgres** node
2. **Credential:** `AML Postgres`
3. **Operation:** `Execute Query`
4. **Query:**
  ```sql
  INSERT INTO accounts (case_id, account_number, monitoring_tier, opened_at, status) 
  VALUES ({{ $json.case_id }}, '{{ $json.account_number }}', '{{ $json.monitoring_tier }}', now(), 'ACTIVE'); 
  
  UPDATE cdd_cases 
  SET status = 'APPROVED', current_phase = 'COMPLETE', closed_at = now() 
  WHERE id = {{ $json.case_id }}; 
  
  INSERT INTO audit_log (case_id, entity_type, entity_id, action, actor, details) 
  VALUES (
    {{ $json.case_id }}, 
    'accounts', 
    NULL, 
    'ACCOUNT_CREATED', 
    'SYSTEM', 
    ('{{ JSON.stringify({ account_number: $json.account_number, monitoring_tier: $json.monitoring_tier, dd_type: $json.dd_type }) }}')::jsonb
  );
  ```
6. Rename to **`Create Account`**

---

### Node 46: Respond: Success

Returns all final CDD/EDD state variables from the incoming `$json` payload.

1. Click **+** on **Create Account**
2. Add a **Respond to Webhook** node
3. Set parameters:
   - **Respond With:** Select **`JSON`** from the dropdown
   - **Response Body:** Click the **Expression** tab and paste:
     ```javascript
     ={{
       status: "APPROVED",
       case_ref: $json.case_ref,
       risk_tier: $json.risk_tier,
       risk_score: $json.risk_score,
       dd_type: $json.dd_type,
       dd_trigger: $json.dd_trigger_reason,
       account_number: $json.account_number,
       monitoring_tier: $json.monitoring_tier,
       irar_version: $json.irar_version,
       verification_deferred: $json.verification_deferred
     }}
     ```
4. Rename to **`Respond: Success`**

---

### Node 47: Send Compliance Email

Sends a beautifully styled HTML report of the customer onboarding details to the compliance mailbox using Gmail.

1. Drag from the right output of **Respond: Success** (Node 46)
2. Add a **Send Email** node
3. Create the SMTP credential:
   - Click **Credential** → select **Create New Credential**
   - Fill in:

   | Field | Value |
   |---|---|
   | **Host** | `smtp.gmail.com` |
   | **Port** | `465` |
   | **SSL/TLS** | *Tick to Enable (SSL)* |
   | **User** | `shazanali3210@gmail.com` |
   | **Password** | `fuut kokl lprz yjix` *(Gmail App Password)* |

   - Click **Save**

4. Back in the node config:
   - **From Email:** `shazanali3210@gmail.com` *(Must match SMTP user for Gmail)*
   - **To Email:** `shazanali3210@gmail.com` *(Or your destination alert email)*
   - **Subject:** `[AML Compliance Report] {{ $json.status }} - Case: {{ $json.case_ref }}`
   - Click the **Add Option** dropdown → select **HTML** (toggle it to **ON**)
   - Click the **Expression** tab on the **HTML** text input, and paste the following HTML template:
     ```html
     ={{ `
     <!DOCTYPE html>
     <html>
     <head>
       <style>
         body {
           font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif;
           color: #333333;
           background-color: #f4f6f9;
           margin: 0;
           padding: 40px;
         }
         .card {
           background-color: #ffffff;
           border-radius: 12px;
           box-shadow: 0 4px 12px rgba(0,0,0,0.05);
           max-width: 600px;
           margin: 0 auto;
           overflow: hidden;
           border: 1px solid #e1e4e8;
         }
         .header {
           background: linear-gradient(135deg, #1e3c72 0%, #2a5298 100%);
           color: #ffffff;
           padding: 30px;
           text-align: center;
         }
         .header h1 {
           margin: 0;
           font-size: 24px;
           font-weight: 600;
         }
         .header p {
           margin: 5px 0 0 0;
           opacity: 0.8;
           font-size: 14px;
         }
         .content {
           padding: 30px;
         }
         .badge {
           display: inline-block;
           padding: 6px 12px;
           font-size: 12px;
           font-weight: 700;
           border-radius: 20px;
           text-transform: uppercase;
           margin-bottom: 20px;
         }
         .badge-approved { background-color: #e2f9e1; color: #1e7e34; }
         .badge-pending { background-color: #fff3cd; color: #856404; }
         .badge-rejected { background-color: #f8d7da; color: #721c24; }
         .section-title {
           font-size: 14px;
           text-transform: uppercase;
           letter-spacing: 1px;
           color: #718096;
           border-bottom: 1px solid #edf2f7;
           padding-bottom: 8px;
           margin-top: 25px;
           margin-bottom: 15px;
         }
         .grid {
           display: grid;
           grid-template-columns: 1fr 1fr;
           gap: 15px;
         }
         .grid-item {
           font-size: 14px;
           margin-bottom: 10px;
         }
         .label {
           color: #718096;
           font-size: 12px;
           margin-bottom: 3px;
         }
         .value {
           font-weight: 600;
           color: #2d3748;
         }
         .footer {
           background-color: #f8f9fa;
           padding: 20px;
           text-align: center;
           font-size: 11px;
           color: #718096;
           border-top: 1px solid #edf2f7;
         }
       </style>
     </head>
     <body>
       <div class="card">
         <div class="header">
           <h1>AML CDD Onboarding Report</h1>
           <p>Case Reference: ${$json.case_ref}</p>
         </div>
         <div class="content">
           <div class="badge badge-approved" style="background-color: #e2f9e1; color: #1e7e34; padding: 6px 12px; border-radius: 20px; font-weight: bold; display: inline-block;">
             Status: ${$json.status}
           </div>
           
           <div class="section-title" style="font-size: 13px; text-transform: uppercase; color: #718096; border-bottom: 1px solid #edf2f7; padding-bottom: 5px; margin-top: 20px; margin-bottom: 10px; font-weight: bold;">
             Case Risk Profile
           </div>
           <table style="width: 100%; font-size: 14px; border-collapse: collapse;">
             <tr>
               <td style="padding: 6px 0; color: #718096; width: 40%;">Assigned Risk Tier:</td>
               <td style="padding: 6px 0; font-weight: 600; color: #2d3748;">${$json.risk_tier}</td>
             </tr>
             <tr>
               <td style="padding: 6px 0; color: #718096;">Aggregated Score:</td>
               <td style="padding: 6px 0; font-weight: 600; color: #2d3748;">${$json.risk_score} / 100</td>
             </tr>
             <tr>
               <td style="padding: 6px 0; color: #718096;">Due Diligence:</td>
               <td style="padding: 6px 0; font-weight: 600; color: #2d3748;">${$json.dd_type}</td>
             </tr>
             <tr>
               <td style="padding: 6px 0; color: #718096;">Trigger Basis:</td>
               <td style="padding: 6px 0; font-weight: 600; color: #2d3748;">${$json.dd_trigger}</td>
             </tr>
           </table>

           <div class="section-title" style="font-size: 13px; text-transform: uppercase; color: #718096; border-bottom: 1px solid #edf2f7; padding-bottom: 5px; margin-top: 20px; margin-bottom: 10px; font-weight: bold;">
             Account Credentials
           </div>
           <table style="width: 100%; font-size: 14px; border-collapse: collapse;">
             <tr>
               <td style="padding: 6px 0; color: #718096; width: 40%;">Generated IBAN:</td>
               <td style="padding: 6px 0; font-family: monospace; font-weight: 600; color: #1e3c72; font-size: 13px;">${$json.account_number}</td>
             </tr>
             <tr>
               <td style="padding: 6px 0; color: #718096;">Monitoring Tier:</td>
               <td style="padding: 6px 0; font-weight: 600; color: #2d3748;">${$json.monitoring_tier}</td>
             </tr>
             <tr>
               <td style="padding: 6px 0; color: #718096;">IRAR Config:</td>
               <td style="padding: 6px 0; font-weight: 600; color: #2d3748;">Version ${$json.irar_version}</td>
             </tr>
             <tr>
               <td style="padding: 6px 0; color: #718096;">Identity Verification:</td>
               <td style="padding: 6px 0; font-weight: 600; color: #2d3748;">${$json.verification_deferred ? 'Deferred (Post-Onboarding)' : 'Completed and Attested'}</td>
             </tr>
           </table>
         </div>
         <div class="footer" style="background-color: #f8f9fa; padding: 15px; text-align: center; font-size: 11px; color: #718096; border-top: 1px solid #edf2f7;">
           State Bank of Pakistan (SBP) Compliance Sandbox — Automated Report
         </div>
       </div>
     </body>
     </html>
     \`` }}
     ```
5. Rename to **`Send Compliance Email`**

---

## Part 3: Activate and Test

### 3.1 Toggle Workflow Live
Once you have created and connected all 46 nodes, click the **"Active"** toggle switch in the top-right corner to **ON**. This registers the webhooks in n8n's routing table.

### 3.2 Execute Test Scenarios

Run these terminal commands to send requests to your local n8n instance and verify compliance logic:

```bash
# Test 1: Individual Low Risk (Should qualify for SDD / account created immediately)
curl -X POST http://localhost:5678/webhook/uc1-onboarding \
  -H "Content-Type: application/json" \
  -d @n8n/test_payloads/01_individual_low_risk.json

# Test 2: Sanctions Match (Abdul Qadir Mujahid - Should return 403 FROZEN immediately)
curl -X POST http://localhost:5678/webhook/uc1-onboarding \
  -H "Content-Type: application/json" \
  -d @n8n/test_payloads/07_sanctions_match.json

# Test 3: Attestation Check Fail (Should fail at Document Check and return 422 details)
curl -X POST http://localhost:5678/webhook/uc1-onboarding \
  -H "Content-Type: application/json" \
  -d @n8n/test_payloads/08_missing_documents.json
```

### 3.3 Test Asynchronous Manager Approval (Option 2)
When onboarding an EDD/PEP case (e.g. a PEP customer or a Trust), the intake webhook immediately returns `PENDING_APPROVAL` with your Case Ref.

1. **Trigger the intake flow (PEP applicant):**
   ```bash
   curl -X POST http://localhost:5678/webhook/uc1-onboarding \
     -H "Content-Type: application/json" \
     -d @n8n/test_payloads/03_individual_pep.json
   ```
   *Expected Output:*
   ```json
   {
     "status": "PENDING_APPROVAL",
     "case_ref": "CDD-2026-00000X",
     "reason": "Case requires senior management approval (EDD/PEP/Trust/NGO/High Risk)"
     }
   ```
2. **Submit the approval decision asynchronously:**
   Use the **static** `uc1-approve-case` webhook endpoint to submit the decision (replace `case_ref` with the reference code returned in the previous step):
   ```bash
   curl -X POST http://localhost:5678/webhook/uc1-approve-case \
     -H "Content-Type: application/json" \
     -d '{"case_ref": "CDD-2026-00000X", "decision": "APPROVED", "approver_name": "Nawaz Sharif", "approver_role": "CEO", "comments": "PEP review complete and approved."}'
   ```
   *Expected Output (Account created immediately!):*
   ```json
   {
     "status": "APPROVED",
     "case_ref": "CDD-2026-00000X",
     "risk_tier": "HIGH",
     "dd_type": "EDD",
     "account_number": "PK-...",
     "monitoring_tier": "ENHANCED",
     "irar_version": "V1",
     "verification_deferred": false
   }
   ```

### 3.4 Verify Database Status
Query your Postgres container directly to check the database state:

```bash
# Check cases status, phases, and suspicion flags
docker exec -it aml-postgres psql -U aml_user -d aml_local -c \
  "SELECT case_ref, current_phase, status, suspicion_flag, sdd_eligibility_basis FROM cdd_cases;"

# Check generated accounts and assigned monitoring tiers
docker exec -it aml-postgres psql -U aml_user -d aml_local -c \
  "SELECT case_id, account_number, monitoring_tier, status FROM accounts;"

# View system audit log records
docker exec -it aml-postgres psql -U aml_user -d aml_local -c \
  "SELECT action, actor, details FROM audit_log ORDER BY id DESC LIMIT 10;"
```

---

## Part 4: Troubleshooting

| Error / Behavior | Cause | Fix |
|---|---|---|
| **Postgres: "Connection refused"** | Host is set to `localhost` inside credentials. | Set **Host** to `postgres` in n8n's PostgreSQL credentials form. |
| **"Cannot read property 'json' of undefined"** | An expression references a node name incorrectly. | Ensure that all node names in expressions (e.g. `$('Insert CDD Case')`) match the actual node titles case-sensitively. |
| **Response code 404 on Webhook trigger** | Workflow is not activated. | Turn the **Active** toggle switch in the top-right corner to **ON**. |
| **Loop / connections missing** | Branch outputs are not connected properly. | Double check the connection map below to ensure TRUE/FALSE outputs connect to the correct destination nodes. |

---

## Part 5: Quick Reference: Node Connection Map

```
FLOW A: Intake & Screening
Webhook Trigger (Node 1)
   │
RE Type Gate Lookup (Node 2)
   │
IF: Applicable? (Node 3)
   ├── True  ──► Insert CDD Case (Node 5) ──► Insert Primary Customer (Node 6) ──► Lookup Doc Checklist (Node 7) ──► Check Documents & Attestation (Node 8)
   └── False ──► Respond: Not Applicable (Node 4)                                                                             │
                                                                                                                      IF: Docs Complete? (Node 9)
                                                                                                                         ├── True  ──► Insert Documents (Node 12) ──► Identity Verification (Mock) (Node 13)
                                                                                                                         └── False ──► Case → ON_HOLD (Incomplete) (Node 10) ──► Respond: Incomplete Docs (Node 11)
                                                                                                                                                                                   │
                                                                                                                                                                        IF: Verification Passed? (Node 14)
                                                                                                                                                                           ├── True  ──► Update Verification Status (Node 17)
                                                                                                                                                                           └── False ──► Case → REJECTED (Verification) (Node 15) ──► Respond: Verification Failed (Node 16)
                                                                                                                                                                                                         │
                                                                                                                                                                                              Beneficial Ownership Check (Node 18)
                                                                                                                                                                                                         │
                                                                                                                                                                                              Insert BO Records (Node 19)
                                                                                                                                                                                                         │
                                                                                                                                                                                              PEP Screening (Node 20)
                                                                                                                                                                                                         │
                                                                                                                                                                                              Process PEP Results (Node 21)
                                                                                                                                                                                                         │
                                                                                                                                                                                              Insert PEP Results (Node 22)
                                                                                                                                                                                                         │
                                                                                                                                                                                              TFS Screening (Node 23)
                                                                                                                                                                                                         │
                                                                                                                                                                                              Process TFS Results (Node 24)
                                                                                                                                                                                                         │
                                                                                                                                                                                              IF: No Sanctions Match? (Node 25)
                                                                                                                                                                                                 ├── True  ──► Insert TFS Clear Results (Node 28)
                                                                                                                                                                                                 └── False ──► FREEZE & Reject (TFS Match) (Node 26) ──► Respond: Frozen (Node 27)
                                                                                                                                                                                                                   │
                                                                                                                                                                                                      Load IRAR Config (Reg 1) (Node 29)
                                                                                                                                                                                                                   │
                                                                                                                                                                                                      Risk Profiling & DD Determination (Node 30)
                                                                                                                                                                                                                   │
                                                                                                                                                                                                      Insert Risk & DD (Node 31)
                                                                                                                                                                                                                   │
                                                                                                                                                                                                      Insert DD Measures (Node 32)
                                                                                                                                                                                                                   │
                                                                                                                                                                                                      IF: Sr Mgmt Approval Needed? (Node 33)
                                                                                                                                                                                                         ├── True  ──► Respond: Pending Approval (Node 34)
                                                                                                                                                                                                         └── False ──► Auto-Approve (CDD/SDD) (Node 39) ──► Check All Measures Complete (Node 40)

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

FLOW B: Manager Approval Callback
Manager Approval Webhook (Node 34-B) ──► Get Case Details by Ref (Node 34-C) ──► Process Approval Decision (Node 35) ──► IF: Approved? (Node 36)
                                                                                                                             ├── True  ──► Check All Measures Complete (Node 40)
                                                                                                                             └── False ──► Case → REJECTED (Approval) (Node 37) ──► Respond: Approval Rejected (Node 38)

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

MERGED Downstream Account Creation (Node 40 onwards)
Check All Measures Complete (Node 40) ──► IF: Measures Complete? (Node 41)
                                             ├── True  ──► Generate Account Number (Node 44) ──► Create Account (Node 45) ──► Respond: Success (Node 46) ──► Send Compliance Email (Node 47)
                                             └── False ──► Block: Measures Incomplete (Node 42) ──► Respond: Measures Incomplete (Node 43)
```
