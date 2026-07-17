# UC8: Wire Transfer Data Completeness & Compliance — n8n Step-by-Step Build Guide

> **Written for someone who has never used n8n.** Every click, every node, every setting is documented.
> If you have already built UC1 and UC5, you can skip Part 0 — the canvas and credential patterns are the same.

---

## Part 0: Prerequisites

### 0.1 Make sure UC1 and UC5 are deployed
UC8 **extends** the database tables of UC1 (`customers`, `cdd_cases`) and invokes the trigger webhooks of UC5 (`uc5-str-cross-uc`). Make sure the UC8 migration scripts (`007_uc8_schema.sql` and `008_uc8_seed.sql`) have been successfully applied to your database.

### 0.2 Open n8n
1. Open your browser → go to **http://localhost:5678**
2. Click **"Create Workflow"** → rename it to `UC8 - Wire Transfer Data Completeness`

### 0.3 Postgres Connection
Every Postgres node in this workflow reuses the **AML Postgres** credential:

| Field | Value |
|---|---|
| **Host** | `aml-postgres` |
| **Database** | `aml_local` |
| **User** | `aml_user` |
| **Password** | `aml_password` |
| **Port** | `5432` |
| **SSL** | `disable` |

---

## Part 1: Workflow Architecture

This solution is built as a single n8n workflow containing **two independent entry points (flows)** on a single canvas:

### Flow A: Intake & Gateway
```
Webhook Trigger (uc8-wire-intake)
           │
  [Insert Raw Transfer]
           │
  [IF: Interbank Exemption?] ── Yes ──► [Set Exempt] ──► [Respond: Exempt]
           │
          No
           │
   [Switch: Role Router]
    ├── OUTGOING   ──► [Lookup Originator CDD] ──► [IF: CDD Approved?] ── Yes ──► [Verify Outgoing Fields] ...
    ├── FORWARDING ──► [Verify Forwarding Fields] ──► [IF: Forwarding Complete?] ── Yes ──► [Forward Complete] ...
    └── INCOMING   ──► [Lookup Beneficiary CDD] ──► [IF: Beneficiary CDD Approved?] ── Yes ──► [Verify Incoming Fields] ...
```

Exposes a public webhook to receive incoming, outgoing, or forwarding transfers. It checks for interbank exemptions first, determines the bank's role, and then routes through three track policies:
1. **Ordering Track:** Blocks outgoing transfers preventively if originator CDD is incomplete or mandatory message fields are missing.
2. **Intermediary Track:** Checks completeness and places incomplete forwarded transfers in a hold queue, notifying compliance and logging correspondent banks.
3. **Beneficiary Track:** Checks local customer CDD status, checks completeness of incoming originator details, and places incomplete transfers on hold.

### Flow B: Analyst Hold Action Gate
```
Webhook Trigger (uc8-analyst-action)
           │
 [Lookup Hold Details]
           │
 [Switch: Analyst Action]
    ├── APPROVED_RELEASE         ──► [Update Hold] ──► [Release Funds] ──► [Respond: Released]
    ├── APPROVED_REJECT          ──► [Update Hold] ──► [Reject Funds] ──► [Respond: Rejected]
    └── SUSPENDED_STR_ESCALATION ──► [Update Hold] ──► [Suspend Funds] ──► [HTTP Request: Trigger UC5 STR] ──► [Respond: Suspended]
```

Allows compliance analysts to review held transfers and release, reject, or suspend them. Suspended transfers automatically generate a case in UC5 via HTTP request.

---

## Part 2: Build It — Node by Node

---

## FLOW A: Wire Transfer Intake & Gateway

---

### Node 1: Webhook Trigger — Wire Transfer Intake

Exposes the endpoint to ingest wire transfer payloads.

1. Add a **Webhook** node to the canvas.
2. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc8-wire-intake`
   - **Response Mode:** `Response to Webhook node`
3. Rename to **`Webhook — Wire Transfer Intake`**

---

### Node 2: Insert Raw Transfer Record

Writes the raw transaction ledger entry into the database in a `PENDING_CHECK` state.

1. Click the **+** on the right side of **Webhook — Wire Transfer Intake**.
2. Add a **Postgres** node.
3. Configure the node:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     INSERT INTO wire_transfers (
       transaction_ref, sending_institution, receiving_institution, 
       transfer_type, direction, originator_customer_id, amount, currency, 
       value_date, purpose_of_transfer, originator_beneficiary_relationship,
       originator_name, originator_account_ref, originator_id_doc_number,
       beneficiary_name, beneficiary_account_ref, beneficiary_id_doc_number,
       transfer_status
     ) VALUES (
       '{{ $json.body.transaction_ref }}',
       '{{ $json.body.sending_institution }}',
       '{{ $json.body.receiving_institution }}',
       '{{ $json.body.transfer_type }}',
       '{{ $json.body.direction }}',
       {{ $json.body.originator_customer_id ? $json.body.originator_customer_id : 'NULL' }},
       {{ $json.body.amount }},
       '{{ $json.body.currency }}',
       '{{ $json.body.value_date }}',
       '{{ $json.body.purpose_of_transfer }}',
       '{{ $json.body.originator_beneficiary_relationship }}',
       '{{ $json.body.originator_name }}',
       '{{ $json.body.originator_account_ref }}',
       '{{ $json.body.originator_id_doc_number }}',
       '{{ $json.body.beneficiary_name }}',
       '{{ $json.body.beneficiary_account_ref }}',
       '{{ $json.body.beneficiary_id_doc_number }}',
       'PENDING_CHECK'
     ) RETURNING *;
     ```
4. Rename to **`Insert Raw Transfer`**

---

### Node 3: IF — Interbank Exemption?

Checks if the transfer is an interbank settlement between SBP member banks acting on their own behalf (exempt under Reg 11 §1).

1. Click the **+** on the right side of **Insert Raw Transfer**.
2. Add an **IF** node.
3. Configure conditions:
   - **Condition 1 (String):**
     - **Value 1:** `{{ $json.body.sending_institution }}` *(Expression)*
     - **Operator:** `equal`
     - **Value 2:** `SBP_MEMBER_BANK_A`
   - **Condition 2 (Boolean):**
     - **Value 1:** `{{ $('Webhook — Wire Transfer Intake').first().json.body.is_own_behalf }}` *(Expression)*
     - **Operator:** `is true`
   - **Convert types where required:** Toggle to **ON** (active).
4. Rename to **`IF: Interbank Exemption?`**

---

### Node 4: Set Exempt Status

Updates the database status of the interbank position to `EXECUTED` and sets the exemption flag.

1. Drag from the **true** output of **IF: Interbank Exemption?**.
2. Add a **Postgres** node.
3. Configure properties:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'EXECUTED',
         is_interbank_exemption = TRUE,
         retention_until = now()::date + interval '10 years'
     WHERE id = {{ $json.id }}
     RETURNING *;
     ```
4. Rename to **`Set Exempt`**

---

### Node 5: Respond — Interbank Exempt

Responds to the caller that the transaction has been exempted and processed.

1. Click the **+** on the right side of **Set Exempt**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Respond With:** `JSON`
   - **Response Code:** `200`
   - **Response Body:** *(Expression mode)*
     ```json
     {{ { "status": "EXEMPT", "transaction_ref": $json.transaction_ref, "message": "Interbank settlement positions are exempt under Reg 11 §1." } }}
     ```
4. Rename to **`Respond: Interbank Exempt`**

---

### Node 6: Switch — Role Router

Routes the transaction to the correct track based on the bank's role (direction of the transfer).

1. Drag from the **false** output of **IF: Interbank Exemption?**.
2. Add a **Switch** node.
3. Configure settings:
   - **Value 1:** `{{ $json.body.direction }}` *(Expression)*
   - **Routing Rules:**
     - Rule 1: String `equal` `OUTGOING` -> Output `0`
     - Rule 2: String `equal` `FORWARDING` -> Output `1`
     - Rule 3: String `equal` `INCOMING` -> Output `2`
4. Rename to **`Switch: Role Router`**

---

### Track 1: Ordering Institution Track (Outgoing)

---

### Node 7: Lookup Originator CDD Status

Queries the database to check if the outgoing customer has completed SBP CDD onboarding.

1. Drag from **Output 0** of **Switch: Role Router**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     SELECT status FROM cdd_cases WHERE id = (SELECT case_id FROM customers WHERE id = {{ $json.originator_customer_id }});
     ```
4. Rename to **`Lookup Originator CDD`**

---

### Node 8: IF — CDD Approved?

Checks if the customer's onboarding CDD is formally approved.

1. Click the **+** on the right side of **Lookup Originator CDD**.
2. Add an **IF** node.
3. Configure condition:
   - **Condition (String):**
     - **Value 1:** `{{ $json.status }}` *(Expression)*
     - **Operator:** `equal`
     - **Value 2:** `APPROVED`
   - **Convert types where required:** Toggle to **ON** (active).
4. Rename to **`IF: CDD Approved?`**

---

### Node 9: Block CDD Failure

Updates the wire transfer record state to `REJECTED` and flags the CDD failure.

1. Drag from the **false** output of **IF: CDD Approved?**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'REJECTED',
         flagged_for_cdd_failure = TRUE
     WHERE id = {{ $('Insert Raw Transfer').first().json.id }}
     RETURNING *;
     ```
4. Rename to **`Block CDD Failure`**

---

### Node 10: Respond — Block CDD Failure

Gracefully returns a 400 Bad Request indicating the customer has not completed CDD checks.

1. Click the **+** on the right side of **Block CDD Failure**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Response Code:** `400`
   - **Response Body:** *(Expression)*
     ```json
     {{ { "status": "REJECTED", "error": "CDD_INCOMPLETE", "message": "Originator CDD is incomplete. Outgoing wire transfer blocked per Reg 11 §2a." } }}
     ```
4. Rename to **`Respond: Block CDD Failure`**

---

### Node 11: Code — Verify Outgoing Fields

Evaluates whether all required fields are present according to the transfer type (Individual vs Batch).

1. Drag from the **true** output of **IF: CDD Approved?**.
2. Add a **Code** node.
3. Configure settings:
   - **Mode:** `Run Once for Each Item`
   - **Code:**
     ```javascript
     const wt = $('Insert Raw Transfer').first().json;
     let isComplete = true;
     let missing = [];
     
     if (wt.transfer_type === 'BATCH') {
       if (!wt.originator_account_ref) { isComplete = false; missing.push('originator_account_ref'); }
       if (!wt.beneficiary_name) { isComplete = false; missing.push('beneficiary_name'); }
       if (!wt.beneficiary_account_ref) { isComplete = false; missing.push('beneficiary_account_ref'); }
     } else {
       if (!wt.originator_name) { isComplete = false; missing.push('originator_name'); }
       if (!wt.originator_account_ref) { isComplete = false; missing.push('originator_account_ref'); }
       if (!wt.originator_id_doc_number) { isComplete = false; missing.push('originator_id_doc_number'); }
       if (!wt.beneficiary_name) { isComplete = false; missing.push('beneficiary_name'); }
       if (!wt.beneficiary_account_ref) { isComplete = false; missing.push('beneficiary_account_ref'); }
     }
     return { is_complete: isComplete, missing_fields: missing };
     ```
4. Rename to **`Verify Outgoing Fields`**

---

### Node 12: IF — Outgoing Fields Complete?

Decides whether the transfer meets regulatory field completeness checks.

1. Click the **+** on the right side of **Verify Outgoing Fields**.
2. Add an **IF** node.
3. Configure condition:
   - **Condition (Boolean):**
     - **Value 1:** `{{ $json.is_complete }}` *(Expression)*
     - **Operator:** `is true`
4. Rename to **`IF: Outgoing Fields Complete?`**

---

### Node 13: Reject Outgoing Transfer

Rejects the transfer in the database due to field incompleteness.

1. Drag from the **false** output of **IF: Outgoing Fields Complete?**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'REJECTED'
     WHERE id = {{ $('Insert Raw Transfer').first().json.id }}
     RETURNING *;
     ```
4. Rename to **`Reject Outgoing`**

---

### Node 14: Respond — Outgoing Rejected

Responds to the core system with a 400 Bad Request listing the missing regulatory fields.

1. Click the **+** on the right side of **Reject Outgoing**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Response Code:** `400`
   - **Response Body:** *(Expression)*
     ```json
     {{ { "status": "REJECTED", "error": "MISSING_REQUIRED_FIELDS", "message": "Outgoing transfer failed completeness checks per SBP Reg 11 §3/§4.", "missing_fields": $('Verify Outgoing Fields').first().json.missing_fields } }}
     ```
4. Rename to **`Respond: Outgoing Rejected`**

---

### Node 15: Send Outgoing

Marks the transaction as sent and establishes the 10-year retention timeline.

1. Drag from the **true** output of **IF: Outgoing Fields Complete?**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'SENT',
         retention_until = now()::date + interval '10 years'
     WHERE id = {{ $('Insert Raw Transfer').first().json.id }}
     RETURNING *;
     ```
4. Rename to **`Send Outgoing`**

---

### Node 16: Respond — Outgoing Sent

Responds to the caller that the compliant outgoing transfer has been processed and sent.

1. Click the **+** on the right side of **Send Outgoing**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Response Code:** `200`
   - **Response Body:** *(Expression)*
     ```json
     {{ { "status": "SENT", "transaction_ref": $json.transaction_ref, "message": "Outgoing wire transfer validated and sent." } }}
     ```
4. Rename to **`Respond: Outgoing Sent`**

---

### Track 2: Intermediary Track (Forwarding)

---

### Node 17: Code — Verify Forwarding Fields

Checks the payload to determine if any of the incoming fields to forward are missing.

1. Drag from **Output 1** of **Switch: Role Router**.
2. Add a **Code** node.
3. Configure settings:
   - **Mode:** `Run Once for Each Item`
   - **Code:**
     ```javascript
     const wt = $('Insert Raw Transfer').first().json;
     let isComplete = true;
     let missing = [];
     
     if (!wt.originator_name) { isComplete = false; missing.push('originator_name'); }
     if (!wt.originator_account_ref) { isComplete = false; missing.push('originator_account_ref'); }
     if (!wt.originator_id_doc_number) { isComplete = false; missing.push('originator_id_doc_number'); }
     if (!wt.beneficiary_name) { isComplete = false; missing.push('beneficiary_name'); }
     if (!wt.beneficiary_account_ref) { isComplete = false; missing.push('beneficiary_account_ref'); }
     return { is_complete: isComplete, missing_fields: missing };
     ```
4. Rename to **`Verify Forwarding Fields`**

---

### Node 18: IF — Forwarding Complete?

Evaluates the forwarding check result.

1. Click the **+** on the right side of **Verify Forwarding Fields**.
2. Add an **IF** node.
3. Configure condition:
   - **Condition (Boolean):**
     - **Value 1:** `{{ $json.is_complete }}` *(Expression)*
     - **Operator:** `is true`
4. Rename to **`IF: Forwarding Complete?`**

---

### Node 19: Forward Complete

Processes the forwarded payment and establishes the retention target.

1. Drag from the **true** output of **IF: Forwarding Complete?**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'EXECUTED',
         retention_until = now()::date + interval '10 years'
     WHERE id = {{ $('Insert Raw Transfer').first().json.id }}
     RETURNING *;
     ```
4. Rename to **`Forward Complete`**

---

### Node 20: Respond — Forward Success

Responds with 200 indicating successful forwarding of the compliant payment.

1. Click the **+** on the right side of **Forward Complete**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Response Code:** `200`
   - **Response Body:** *(Expression)*
     ```json
     {{ { "status": "FORWARDED", "transaction_ref": $json.transaction_ref, "message": "Intermediary transfer forwarded with preserved data." } }}
     ```
4. Rename to **`Respond: Forward Success`**

---

### Node 21: Set Forward Hold

Updates the transfer status to `HELD_COMPLETENESS` in the database.

1. Drag from the **false** output of **IF: Forwarding Complete?**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'HELD_COMPLETENESS'
     WHERE id = {{ $('Insert Raw Transfer').first().json.id }}
     RETURNING *;
     ```
4. Rename to **`Set Forward Hold`**

---

### Node 22: Insert Hold Record

Inserts a hold queue item to await compliance review.

1. Click the **+** on the right side of **Set Forward Hold**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     INSERT INTO wire_transfer_holds (wire_transfer_id, role_at_bank, hold_reason, review_status)
     VALUES (
       {{ $('Insert Raw Transfer').first().json.id }},
       'INTERMEDIARY',
       'Missing fields: {{ $('Verify Forwarding Fields').first().json.missing_fields.join(\", \") }}',
       'PENDING_REVIEW'
     ) RETURNING *;
     ```
4. Rename to **`Insert Hold Record`**

---

### Node 23: Log Correspondent Incompleteness

Logs the correspondent bank failure count in the database logs.

1. Click the **+** on the right side of **Insert Hold Record**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     INSERT INTO correspondent_completeness_logs (institution_name, wire_transfer_id, missing_fields_count)
     VALUES (
       '{{ $('Insert Raw Transfer').first().json.sending_institution }}',
       {{ $('Insert Raw Transfer').first().json.id }},
       {{ $('Verify Forwarding Fields').first().json.missing_fields.length }}
     );
     ```
4. Rename to **`Log Correspondent Incompleteness`**

---

### Node 24: Send Email — Hold Alert

Emails the compliance alerts inbox with details of the held forwarded wire transfer.

1. Click the **+** on the right side of **Log Correspondent Incompleteness**.
2. Add a **Send Email** node.
3. Configure settings:
   - **Credential:** `AML SMTP`
   - **From Email:** `aml.testing.sandbox@gmail.com`
   - **To Email:** `aml.compliance.alerts@genosbank.com`
   - **Subject:** `ALERT: Intermediary Wire Transfer Held for Data Completeness`
   - **Body (HTML):**
     ```html
     <html>
     <head>
       <style>
         body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; background: #f4f6f9; margin: 0; padding: 40px; }
         .card { background: #fff; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); max-width: 600px; margin: 0 auto; overflow: hidden; border: 1px solid #e1e4e8; }
         .header { background: linear-gradient(135deg, #e67e22 0%, #d35400 100%); color: #fff; padding: 30px; text-align: center; }
         .header h1 { margin: 0; font-size: 20px; font-weight: 600; color: #ffffff; }
         .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; color: #ffffff; }
         .content { padding: 30px; }
         .badge { display: inline-block; padding: 6px 12px; font-size: 12px; font-weight: 700; border-radius: 20px; text-transform: uppercase; margin-bottom: 20px; background: #fff3cd; color: #856404; }
         .section-title { font-size: 14px; text-transform: uppercase; letter-spacing: 1px; color: #718096; border-bottom: 1px solid #edf2f7; padding-bottom: 8px; margin-top: 25px; margin-bottom: 15px; }
         table { width: 100%; border-collapse: collapse; }
         td { padding: 8px 0; font-size: 14px; }
         td:first-child { color: #718096; width: 40%; }
         td:last-child { font-weight: 600; }
         .footer { background: #f8f9fa; padding: 20px 30px; text-align: center; font-size: 12px; color: #718096; }
       </style>
     </head>
     <body>
       <div class="card">
         <div class="header">
           <h1>⚠️ Intermediary Transfer Held</h1>
           <p>UC8 — Wire Transfer Data Completeness & Compliance</p>
         </div>
         <div class="content">
           <span class="badge">HOLD REASON: INCOMPLETE DATA</span>
           <div class="section-title">Transfer Details</div>
           <table>
             <tr><td>Transaction Ref</td><td>{{ $('Insert Raw Transfer').first().json.transaction_ref }}</td></tr>
             <tr><td>Direction</td><td>{{ $('Insert Raw Transfer').first().json.direction }}</td></tr>
             <tr><td>Amount</td><td>{{ $('Insert Raw Transfer').first().json.amount }} {{ $('Insert Raw Transfer').first().json.currency }}</td></tr>
             <tr><td>Sending Bank</td><td>{{ $('Insert Raw Transfer').first().json.sending_institution }}</td></tr>
             <tr><td>Receiving Bank</td><td>{{ $('Insert Raw Transfer').first().json.receiving_institution }}</td></tr>
           </table>
           <div class="section-title">Regulatory Hold Status</div>
           <table>
             <tr><td>Hold ID</td><td>{{ $('Insert Hold Record').first().json.id }}</td></tr>
             <tr><td>Hold Reason</td><td style="color: #c0392b;">{{ $('Insert Hold Record').first().json.hold_reason }}</td></tr>
           </table>
           <div class="section-title">Next Step</div>
           <p style="font-size:14px; margin: 0; line-height: 1.5;">This transaction has been placed in the compliance hold queue. The correspondent bank logs have been updated. Action must be taken via the Analyst Hold Action Gate to approve release, reject, or escalate.</p>
         </div>
         <div class="footer">
           Genos Bank Compliance Automation • SBP Regulation 11 Compliance
         </div>
       </div>
     </body>
     </html>
     ```
4. Rename to **`Send Email — Hold Alert`**

---

### Node 25: Respond — Forwarding Hold

Returns a 202 Accepted status with the hold reference ID.

1. Click the **+** on the right side of **Send Email — Hold Alert**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Response Code:** `202`
   - **Response Body:** *(Expression)*
     ```json
     {{ { "status": "HELD_COMPLETENESS", "hold_id": $('Insert Hold Record').first().json.id, "message": "Forwarding transfer placed on hold for data completeness check." } }}
     ```
4. Rename to **`Respond: Forwarding Hold`**

---

### Track 3: Beneficiary Track (Incoming)

---

### Node 26: Lookup Beneficiary CDD Status

Queries the database to verify the receiving local customer's onboarding status.

1. Drag from **Output 2** of **Switch: Role Router**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     SELECT status FROM cdd_cases WHERE id = (SELECT case_id FROM customers WHERE id = {{ $json.originator_customer_id }});
     ```
4. Rename to **`Lookup Beneficiary CDD`**

---

### Node 27: IF — Beneficiary CDD Approved?

Checks if the beneficiary CDD status is active and approved.

1. Click the **+** on the right side of **Lookup Beneficiary CDD**.
2. Add an **IF** node.
3. Configure condition:
   - **Condition (String):**
     - **Value 1:** `{{ $json.status }}` *(Expression)*
     - **Operator:** `equal`
     - **Value 2:** `APPROVED`
   - **Convert types where required:** Toggle to **ON** (active).
4. Rename to **`IF: Beneficiary CDD Approved?`**

---

### Node 28: Code — Verify Incoming Fields

Checks if mandatory originator fields on the incoming transfer are present.

1. Drag from the **true** output of **IF: Beneficiary CDD Approved?**.
2. Add a **Code** node.
3. Configure settings:
   - **Mode:** `Run Once for Each Item`
   - **Code:**
     ```javascript
     const wt = $('Insert Raw Transfer').first().json;
     let isComplete = true;
     let missing = [];
     
     if (!wt.originator_name) { isComplete = false; missing.push('originator_name'); }
     if (!wt.originator_account_ref) { isComplete = false; missing.push('originator_account_ref'); }
     if (!wt.originator_id_doc_number) { isComplete = false; missing.push('originator_id_doc_number'); }
     return { is_complete: isComplete, missing_fields: missing };
     ```
4. Rename to **`Verify Incoming Fields`**

---

### Node 29: IF — Incoming Fields Complete?

Evaluates the incoming completeness check.

1. Click the **+** on the right side of **Verify Incoming Fields**.
2. Add an **IF** node.
3. Configure condition:
   - **Condition (Boolean):**
     - **Value 1:** `{{ $json.is_complete }}` *(Expression)*
     - **Operator:** `is true`
4. Rename to **`IF: Incoming Fields Complete?`**

---

### Node 30: Beneficiary Complete

Marks the transaction as executed and credits the customer's account in the database.

1. Drag from the **true** output of **IF: Incoming Fields Complete?**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'EXECUTED',
         retention_until = now()::date + interval '10 years'
     WHERE id = {{ $('Insert Raw Transfer').first().json.id }}
     RETURNING *;
     ```
4. Rename to **`Beneficiary Complete`**

---

### Node 31: Respond — Beneficiary Complete

Responds to the clearing system that the incoming transfer has been credited.

1. Click the **+** on the right side of **Beneficiary Complete**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Response Code:** `200`
   - **Response Body:** *(Expression)*
     ```json
     {{ { "status": "CREDITED", "transaction_ref": $json.transaction_ref, "message": "Incoming transfer credited to beneficiary account." } }}
     ```
4. Rename to **`Respond: Beneficiary Complete`**

---

### Node 32: Set Beneficiary Hold

Places the incoming transfer in a hold state due to incomplete data or pending CDD.

1. Connect the **false** output of **IF: Beneficiary CDD Approved?** AND the **false** output of **IF: Incoming Fields Complete?** to a new **Postgres** node.
2. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'HELD_COMPLETENESS'
     WHERE id = {{ $('Insert Raw Transfer').first().json.id }}
     RETURNING *;
     ```
3. Rename to **`Set Beneficiary Hold`**

---

### Node 33: Insert Hold Record (Beneficiary)

Logs the detailed hold reason in the review queue.

1. Click the **+** on the right side of **Set Beneficiary Hold**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     INSERT INTO wire_transfer_holds (wire_transfer_id, role_at_bank, hold_reason, review_status)
     VALUES (
       {{ $('Insert Raw Transfer').first().json.id }},
       'BENEFICIARY',
       CASE 
         WHEN '{{ $('Lookup Beneficiary CDD').first().json.status }}' != 'APPROVED' THEN 'Beneficiary CDD incomplete'
         ELSE 'Missing fields: {{ $('Verify Incoming Fields').first().json.missing_fields.join(\", \") }}'
       END,
       'PENDING_REVIEW'
     ) RETURNING *;
     ```
4. Rename to **`Insert Hold Record (Beneficiary)`**

---

### Node 34: Log Correspondent (Beneficiary)

Logs the counterparty institution risk statistics.

1. Click the **+** on the right side of **Insert Hold Record (Beneficiary)**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     INSERT INTO correspondent_completeness_logs (institution_name, wire_transfer_id, missing_fields_count)
     VALUES (
       '{{ $('Insert Raw Transfer').first().json.sending_institution }}',
       {{ $('Insert Raw Transfer').first().json.id }},
       {{ $('Verify Incoming Fields').first().json.is_complete ? 0 : $('Verify Incoming Fields').first().json.missing_fields.length }}
     );
     ```
4. Rename to **`Log Correspondent (Beneficiary)`**

---

### Node 35: Send Email — Hold Alert (Beneficiary)

Sends a notification email for the incoming hold case.

1. Click the **+** on the right side of **Log Correspondent (Beneficiary)**.
2. Add a **Send Email** node.
3. Configure settings:
   - **Credential:** `AML SMTP`
   - **From Email:** `aml.testing.sandbox@gmail.com`
   - **To Email:** `aml.compliance.alerts@genosbank.com`
   - **Subject:** `ALERT: Beneficiary Wire Transfer Held for Data Completeness`
   - **Body (HTML):**
     ```html
     <html>
     <head>
       <style>
         body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; background: #f4f6f9; margin: 0; padding: 40px; }
         .card { background: #fff; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); max-width: 600px; margin: 0 auto; overflow: hidden; border: 1px solid #e1e4e8; }
         .header { background: linear-gradient(135deg, #e67e22 0%, #d35400 100%); color: #fff; padding: 30px; text-align: center; }
         .header h1 { margin: 0; font-size: 20px; font-weight: 600; color: #ffffff; }
         .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; color: #ffffff; }
         .content { padding: 30px; }
         .badge { display: inline-block; padding: 6px 12px; font-size: 12px; font-weight: 700; border-radius: 20px; text-transform: uppercase; margin-bottom: 20px; background: #fff3cd; color: #856404; }
         .section-title { font-size: 14px; text-transform: uppercase; letter-spacing: 1px; color: #718096; border-bottom: 1px solid #edf2f7; padding-bottom: 8px; margin-top: 25px; margin-bottom: 15px; }
         table { width: 100%; border-collapse: collapse; }
         td { padding: 8px 0; font-size: 14px; }
         td:first-child { color: #718096; width: 40%; }
         td:last-child { font-weight: 600; }
         .footer { background: #f8f9fa; padding: 20px 30px; text-align: center; font-size: 12px; color: #718096; }
       </style>
     </head>
     <body>
       <div class="card">
         <div class="header">
           <h1>⚠️ Beneficiary Transfer Held</h1>
           <p>UC8 — Wire Transfer Data Completeness & Compliance</p>
         </div>
         <div class="content">
           <span class="badge">HOLD REASON: KYC OR DATA INCOMPLETE</span>
           <div class="section-title">Transfer Details</div>
           <table>
             <tr><td>Transaction Ref</td><td>{{ $('Insert Raw Transfer').first().json.transaction_ref }}</td></tr>
             <tr><td>Direction</td><td>{{ $('Insert Raw Transfer').first().json.direction }}</td></tr>
             <tr><td>Amount</td><td>{{ $('Insert Raw Transfer').first().json.amount }} {{ $('Insert Raw Transfer').first().json.currency }}</td></tr>
             <tr><td>Sending Bank</td><td>{{ $('Insert Raw Transfer').first().json.sending_institution }}</td></tr>
             <tr><td>Receiving Bank</td><td>{{ $('Insert Raw Transfer').first().json.receiving_institution }}</td></tr>
           </table>
           <div class="section-title">Regulatory Hold Status</div>
           <table>
             <tr><td>Hold ID</td><td>{{ $('Insert Hold Record (Beneficiary)').first().json.id }}</td></tr>
             <tr><td>Hold Reason</td><td style="color: #c0392b;">{{ $('Insert Hold Record (Beneficiary)').first().json.hold_reason }}</td></tr>
           </table>
           <div class="section-title">Next Step</div>
           <p style="font-size:14px; margin: 0; line-height: 1.5;">This transaction has been placed in the compliance hold queue. The beneficiary's KYC status or incoming transaction details failed compliance checks. Action must be taken via the Analyst Hold Action Gate.</p>
         </div>
         <div class="footer">
           Genos Bank Compliance Automation • SBP Regulation 11 Compliance
         </div>
       </div>
     </body>
     </html>
     ```
4. Rename to **`Send Email — Hold Alert (Beneficiary)`**

---

### Node 36: Respond — Beneficiary Hold

Responds with 202 indicating the incoming transfer is locked pending review.

1. Click the **+** on the right side of **Send Email — Hold Alert (Beneficiary)**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Response Code:** `202`
   - **Response Body:** *(Expression)*
     ```json
     {{ { "status": "HELD_COMPLETENESS", "hold_id": $('Insert Hold Record (Beneficiary)').first().json.id, "message": "Incoming beneficiary transfer placed on hold." } }}
     ```
4. Rename to **`Respond: Beneficiary Hold`**

---

## FLOW B: Analyst Hold Action Gate

---

### Node 37: Webhook — Analyst Hold Action

Exposes the endpoint for compliance analysts to submit release, reject, or escalate decisions.

1. On the same canvas (separated from Flow A), add a **Webhook** node.
2. Configure settings:
   - **HTTP Method:** `POST`
   - **Path:** `uc8-analyst-action`
   - **Response Mode:** `Response to Webhook node`
3. Rename to **`Webhook — Analyst Hold Action`**

---

### Node 38: Lookup Hold Details

Pulls the details of the hold and associated transfer from the database.

1. Click the **+** on the right side of **Webhook — Analyst Hold Action**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Credential:** `AML Postgres`
   - **Operation:** `Execute Query`
   - **Query:**
     ```sql
     SELECT h.*, w.transaction_ref, w.direction, w.originator_customer_id 
     FROM wire_transfer_holds h 
     JOIN wire_transfers w ON h.wire_transfer_id = w.id 
     WHERE h.id = {{ $json.body.hold_id }};
     ```
4. Rename to **`Lookup Hold Details`**

---

### Node 39: Switch — Analyst Action Router

Branches the workflow based on the analyst's decision choice.

1. Click the **+** on the right side of **Lookup Hold Details**.
2. Add a **Switch** node.
3. Configure settings:
   - **Value 1:** `{{ $('Webhook — Analyst Hold Action').first().json.body.action }}` *(Expression)*
   - **Routing Rules:**
     - Rule 1: String `equal` `APPROVED_RELEASE` -> Output `0`
     - Rule 2: String `equal` `APPROVED_REJECT` -> Output `1`
     - Rule 3: String `equal` `SUSPENDED_STR_ESCALATION` -> Output `2`
4. Rename to **`Switch: Analyst Action`**

---

### Node 40: Update Hold Release

Updates the hold review record to approved release state.

1. Drag from **Output 0** of **Switch: Analyst Action Router**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfer_holds
     SET review_status = 'APPROVED_RELEASE',
         reviewed_by = '{{ $('Webhook — Analyst Hold Action').first().json.body.reviewer_name }}',
         reviewed_at = now(),
         rationale = '{{ $('Webhook — Analyst Hold Action').first().json.body.rationale }}'
     WHERE id = {{ $json.id }}
     RETURNING *;
     ```
4. Rename to **`Update Hold Release`**

---

### Node 41: Release Funds

Updates the transfer status to executed and sets the retention.

1. Click the **+** on the right side of **Update Hold Release**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'EXECUTED',
         retention_until = now()::date + interval '10 years'
     WHERE id = {{ $json.wire_transfer_id }}
     RETURNING *;
     ```
4. Rename to **`Release Funds`**

---

### Node 42: Respond — Released

Responds to the caller that the funds have been released and executed.

1. Click the **+** on the right side of **Release Funds**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Response Code:** `200`
   - **Response Body:** *(Expression)*
     ```json
     {{ { "status": "APPROVED_RELEASE", "transaction_ref": $('Lookup Hold Details').first().json.transaction_ref, "message": "Wire transfer released and executed." } }}
     ```
4. Rename to **`Respond: Released`**

---

### Node 43: Update Hold Reject

Updates the hold review record to approved reject state.

1. Drag from **Output 1** of **Switch: Analyst Action Router**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfer_holds
     SET review_status = 'APPROVED_REJECT',
         reviewed_by = '{{ $('Webhook — Analyst Hold Action').first().json.body.reviewer_name }}',
         reviewed_at = now(),
         rationale = '{{ $('Webhook — Analyst Hold Action').first().json.body.rationale }}'
     WHERE id = {{ $json.id }}
     RETURNING *;
     ```
4. Rename to **`Update Hold Reject`**

---

### Node 44: Reject Funds

Updates the wire transfer record to rejected status.

1. Click the **+** on the right side of **Update Hold Reject**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'REJECTED',
         retention_until = now()::date + interval '10 years'
     WHERE id = {{ $json.wire_transfer_id }}
     RETURNING *;
     ```
4. Rename to **`Reject Funds`**

---

### Node 45: Respond — Rejected

Responds to the caller that the transfer has been rejected.

1. Click the **+** on the right side of **Reject Funds**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Response Code:** `200`
   - **Response Body:** *(Expression)*
     ```json
     {{ { "status": "APPROVED_REJECT", "transaction_ref": $('Lookup Hold Details').first().json.transaction_ref, "message": "Wire transfer rejected and funds terminated." } }}
     ```
4. Rename to **`Respond: Rejected`**

---

### Node 46: Update Hold Suspend

Updates the hold review record to suspended state.

1. Drag from **Output 2** of **Switch: Analyst Action Router**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfer_holds
     SET review_status = 'SUSPENDED_STR_ESCALATION',
         reviewed_by = '{{ $('Webhook — Analyst Hold Action').first().json.body.reviewer_name }}',
         reviewed_at = now(),
         rationale = '{{ $('Webhook — Analyst Hold Action').first().json.body.rationale }}'
     WHERE id = {{ $json.id }}
     RETURNING *;
     ```
4. Rename to **`Update Hold Suspend`**

---

### Node 47: Suspend Funds

Updates the wire transfer record to suspended status and sets the STR review flags.

1. Click the **+** on the right side of **Update Hold Suspend**.
2. Add a **Postgres** node.
3. Configure settings:
   - **Query:**
     ```sql
     UPDATE wire_transfers
     SET transfer_status = 'SUSPENDED',
         flagged_for_str_review = TRUE,
         retention_until = now()::date + interval '10 years'
     WHERE id = {{ $json.wire_transfer_id }}
     RETURNING *;
     ```
4. Rename to **`Suspend Funds`**

---

### Node 48: HTTP Request — Trigger UC5 STR

Invokes the UC5 STR intake webhook to create a suspicious transaction case using a cross-UC finding trigger.

1. Click the **+** on the right side of **Suspend Funds**.
2. Add an **HTTP Request** node.
3. Configure settings:
   - **Method:** `POST`
   - **URL:** `http://localhost:5678/webhook/uc5-str-cross-uc`
   - **Authentication:** `None`
   - **Send Body:** Toggle to **ON**
   - **Body Content Type:** `JSON`
   - **Specify Body:** `Using JSON below`
   - **JSON:**
     ```json
     {
       "trigger_type": "CROSS_UC_FINDING",
       "source_reference": "UC8-HOLD-{{ $('Lookup Hold Details').first().json.id }}",
       "customer_id": {{ $('Lookup Hold Details').first().json.originator_customer_id ? $('Lookup Hold Details').first().json.originator_customer_id : 103 }},
       "details": {
         "wire_transfer_id": {{ $('Lookup Hold Details').first().json.wire_transfer_id }},
         "transaction_ref": "{{ $('Lookup Hold Details').first().json.transaction_ref }}",
         "reason": "Wire transfer held for data completeness escalated to STR due to suspicious non-compliant counterparty behavior.",
         "hold_rationale": "{{ $('Webhook — Analyst Hold Action').first().json.body.rationale }}"
       }
     }
     ```
4. Rename to **`HTTP Request — Trigger UC5 STR`**

---

### Node 49: Respond — Suspended

Responds with 200 indicating the transfer has been suspended and escalated.

1. Click the **+** on the right side of **HTTP Request — Trigger UC5 STR**.
2. Add a **Respond to Webhook** node.
3. Configure settings:
   - **Response Code:** `200`
   - **Response Body:** *(Expression)*
     ```json
     {{ { "status": "SUSPENDED_STR_ESCALATION", "transaction_ref": $('Lookup Hold Details').first().json.transaction_ref, "message": "Wire transfer suspended. Incident details forwarded to UC5 STR Queue for mandatory investigation." } }}
     ```
4. Rename to **`Respond: Suspended`**

---

## Part 3: Pre-Flight Checks

Before testing, make sure:

### 3.1 Publish the Workflow
1. Open the **UC8 - Wire Transfer Data Completeness** workflow → click **"Publish"** in the top-right corner.

### 3.2 Test Webhook Endpoints
* **Intake Endpoint (Flow A):**
  - `POST http://localhost:5678/webhook/uc8-wire-intake`
* **Analyst Action Endpoint (Flow B):**
  - `POST http://localhost:5678/webhook/uc8-analyst-action`

---

## Part 4: Complete Node Summary

### Workflow: UC8 - Wire Transfer Data Completeness

| Node # | Name | Type | Flow |
|---|---|---|---|
| 1 | Webhook — Wire Transfer Intake | Webhook | A |
| 2 | Insert Raw Transfer | Postgres | A |
| 3 | IF: Interbank Exemption? | IF | A |
| 4 | Set Exempt | Postgres | A |
| 5 | Respond: Interbank Exempt | Respond to Webhook | A |
| 6 | Switch: Role Router | Switch | A |
| 7 | Lookup Originator CDD | Postgres | A |
| 8 | IF: CDD Approved? | IF | A |
| 9 | Block CDD Failure | Postgres | A |
| 10 | Respond: Block CDD Failure | Respond to Webhook | A |
| 11 | Verify Outgoing Fields | Code | A |
| 12 | IF: Outgoing Fields Complete? | IF | A |
| 13 | Reject Outgoing | Postgres | A |
| 14 | Respond: Outgoing Rejected | Respond to Webhook | A |
| 15 | Send Outgoing | Postgres | A |
| 16 | Respond: Outgoing Sent | Respond to Webhook | A |
| 17 | Verify Forwarding Fields | Code | A |
| 18 | IF: Forwarding Complete? | IF | A |
| 19 | Forward Complete | Postgres | A |
| 20 | Respond: Forward Success | Respond to Webhook | A |
| 21 | Set Forward Hold | Postgres | A |
| 22 | Insert Hold Record | Postgres | A |
| 23 | Log Correspondent Incompleteness | Postgres | A |
| 24 | Send Email — Hold Alert | Send Email | A |
| 25 | Respond: Forwarding Hold | Respond to Webhook | A |
| 26 | Lookup Beneficiary CDD | Postgres | A |
| 27 | IF: Beneficiary CDD Approved? | IF | A |
| 28 | Verify Incoming Fields | Code | A |
| 29 | IF: Incoming Fields Complete? | IF | A |
| 30 | Beneficiary Complete | Postgres | A |
| 31 | Respond: Beneficiary Complete | Respond to Webhook | A |
| 32 | Set Beneficiary Hold | Postgres | A |
| 33 | Insert Hold Record (Beneficiary) | Postgres | A |
| 34 | Log Correspondent (Beneficiary) | Postgres | A |
| 35 | Send Email — Hold Alert (Beneficiary) | Send Email | A |
| 36 | Respond: Beneficiary Hold | Respond to Webhook | A |
| 37 | Webhook — Analyst Hold Action | Webhook | B |
| 38 | Lookup Hold Details | Postgres | B |
| 39 | Switch: Analyst Action | Switch | B |
| 40 | Update Hold Release | Postgres | B |
| 41 | Release Funds | Postgres | B |
| 42 | Respond: Released | Respond to Webhook | B |
| 43 | Update Hold Reject | Postgres | B |
| 44 | Reject Funds | Postgres | B |
| 45 | Respond: Rejected | Respond to Webhook | B |
| 46 | Update Hold Suspend | Postgres | B |
| 47 | Suspend Funds | Postgres | B |
| 48 | HTTP Request — Trigger UC5 STR | HTTP Request | B |
| 49 | Respond: Suspended | Respond to Webhook | B |

**Total: 49 nodes across 2 flows (1 unified canvas)**
