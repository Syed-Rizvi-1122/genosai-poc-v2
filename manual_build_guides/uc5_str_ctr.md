# UC5: Suspicious Transaction Investigation & STR/CTR Pipeline — n8n Step-by-Step Build Guide

> **Written for someone who has never used n8n.** Every click, every node, every setting is documented.
> If you've already built UC1 and UC3, you can skip Part 0 — the canvas and credential patterns are the same.

---

## Part 0: Prerequisites

### 0.1 Make sure UC1 is deployed
UC5 references UC1's `customers` table for customer profile lookups. The UC1 workflow must have been deployed first, and the UC5 migration scripts (`005_uc5_schema.sql` and `006_uc5_seed.sql`) must have been applied.

**Apply the UC5 migrations manually** (if you haven't already):
```bash
docker exec -i aml-postgres psql -U aml_user -d aml_local < db/init/005_uc5_schema.sql
docker exec -i aml-postgres psql -U aml_user -d aml_local < db/init/006_uc5_seed.sql
```

### 0.2 Open n8n
1. Open your browser → go to **http://localhost:5678**
2. You will create **TWO separate workflows** for UC5:
   - `UC5 - CTR Pipeline`
   - `UC5 - STR Investigation Pipeline`

### 0.3 Reuse the AML Postgres Credential
Every Postgres node in both workflows reuses the **same credential** you created in UC1:

| Field | Value |
|---|---|
| **Host** | `postgres` |
| **Database** | `aml_local` |
| **User** | `aml_user` |
| **Password** | `aml_password` |
| **Port** | `5432` |
| **SSL** | `disable` |

If you already have this credential from UC1, just select it from the dropdown. Otherwise, create it in the first Postgres node and reuse it for all subsequent ones.

### 0.4 Reuse the SMTP Credential
For email notifications, reuse the SMTP credential from UC1:

| Field | Value |
|---|---|
| **Host** | `smtp.gmail.com` |
| **Port** | `465` |
| **SSL/TLS** | *Tick to Enable (SSL)* |
| **User** | `shazanali3210@gmail.com` |
| **Password** | `fuut kokl lprz yjix` *(Gmail App Password)* |

---

## Part 1: Workflow Architecture

### Why Two Separate Workflows?
The PRD states: "CTR and STR are two genuinely separate tracks — a mandatory deterministic filing vs. a judgment-based investigation. Do not merge them into one pipeline."

- **CTR** is mechanical: threshold check → flag → verify data → file. No human judges *whether* to file.
- **STR** is investigative: multi-source trigger → case build → 100% human-reviewed → two-tier approval → file.

### Workflow 1: UC5 - CTR Pipeline (18 nodes, 2 flows)

```
Flow A: Transaction Intake + Threshold Check
  Webhook Trigger (uc5-ctr-transaction)
    │
  [Lookup CTR Threshold] from regulatory_thresholds_config
    │
  [IF: Cash Transaction?]
    ├── No  → [Respond: Not Cash — No CTR Required]
    └── Yes → [IF: Amount >= Threshold?]
                 ├── No  → [Respond: Below Threshold]
                 └── Yes → [Insert CTR Candidate (PENDING_CHECK)]
                              │
                           [Send Email: CTR Candidate Flagged]
                              │
                           [Respond: CTR Candidate Created]

Flow B: Data Accuracy Verification + Filing
  Webhook Trigger (uc5-ctr-verify)
    │
  [Update ctr_candidates — data_accuracy_status]
    │
  [IF: VERIFIED?]
    ├── No (CORRECTION_NEEDED) → [Respond: Correction Needed]
    └── Yes → [Get Transaction Details]
                │
              [Insert ctr_filings] (mock filing_reference, compute retention_until)
                │
              [Send Email: CTR Filed]
                │
              [Respond: CTR Filed]
```

### Workflow 2: UC5 - STR Investigation Pipeline (35 nodes, 4 flows)

```
Flow A: Case Creation (4 trigger entry points)
  Webhook: uc5-str-tms-alert       → TMS_ALERT
  Webhook: uc5-str-manual-obs      → MANUAL_STAFF_OBSERVATION
  Webhook: uc5-str-cross-uc        → CROSS_UC_FINDING
  Webhook: uc5-str-cdd-failure     → CDD_FAILURE_OR_TIPOFF_RISK
    │
  [Merge 4 triggers]
    │
  [Insert str_case_triggers] → [Generate Case Ref] → [Insert str_cases]
    │
  [IF: CDD_WOULD_TIPOFF_S7D2?] → Set RECOMMENDED_FOR_FILING directly
    │
  [Aggregate Customer Profile]
    │
  [Compute Triage Score] (Code node — queue ordering only)
    │
  [Update str_cases with triage_score]
    │
  [Send Email: New STR Case]
    │
  [Respond: Case Created]

Flow B: Analyst Investigation + Decision
  Webhook (uc5-str-analyst-action)
    │
  [Validate Role = COMPLIANCE_ANALYST]
    │
  [Log Access → str_access_log]
    │
  [IF: action = 'investigate'?]
    ├── Yes → [Insert str_investigation_log] → [Update status → UNDER_INVESTIGATION] → [Respond]
    └── No  → [Insert str_analyst_decisions]
                │
              [IF: CLOSE_NOT_SUSPICIOUS?]
                ├── Yes → [Update → CLOSED] → [Respond: Case Closed]
              [IF: NEEDS_MORE_INFO?]
                ├── Yes → [Update → NEEDS_MORE_INFO] → [Respond]
              [IF: FILE_STR?]
                └── Yes → [Update → RECOMMENDED_FOR_FILING] → [Respond]

Flow C: Compliance Officer Sign-Off + Filing
  Webhook (uc5-str-officer-signoff)
    │
  [Validate Role = COMPLIANCE_OFFICER]
    │
  [Log Access → str_access_log]
    │
  [Validate case is RECOMMENDED_FOR_FILING]
    │
  [Insert str_compliance_officer_signoff]
    │
  [IF: APPROVED?]
    ├── No (RETURNED) → [Update → UNDER_INVESTIGATION] → [Respond: Returned]
    └── Yes → [Insert str_filings] → [Update → FILED]
                │
              [Send Email: STR Filed]
                │
              [Respond: STR Filed]

Flow D: Access Control Validation
  Webhook (uc5-str-access-check)
    │
  [IF: role is COMPLIANCE_ANALYST or COMPLIANCE_OFFICER?]
    ├── No  → [Respond: 403 ACCESS_DENIED]
    └── Yes → [Log Access] → [Query Filtered Cases] → [Respond: Case Data]
```

---

## Part 2A: Build It — CTR Pipeline (Workflow 1)

**Create a new workflow:** Click **"Create Workflow"** → rename to **`UC5 - CTR Pipeline`**

---

## FLOW A: Transaction Intake + Threshold Check

---

### Node 1: Webhook Trigger — Transaction Intake

This is the entry point for new transactions (simulating a core banking system feed or teller submission).

1. Click the **"+"** button in the center of the canvas
2. Search for **"Webhook"** → click to add it
3. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc5-ctr-transaction`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook Trigger — Transaction Intake`**

**Expected payload:**
```json
{
  "customer_id": 1,
  "transaction_type": "CASH_DEPOSIT",
  "amount": 2500000,
  "currency": "PKR",
  "branch_code": "BR-001",
  "channel": "BRANCH_TELLER",
  "description": "Large cash deposit"
}
```

---

### Node 2: Insert Transaction

Records the transaction in the database first, before any threshold logic runs.

1. Click the **+** on the right side of **Webhook Trigger — Transaction Intake**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres` (select existing)
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO transactions (customer_id, account_id, transaction_type, amount, currency, branch_code, channel, description)
   VALUES (
     {{ $json.body.customer_id }},
     NULL,
     '{{ $json.body.transaction_type }}',
     {{ $json.body.amount }},
     '{{ $json.body.currency || 'PKR' }}',
     '{{ $json.body.branch_code }}',
     '{{ $json.body.channel }}',
     '{{ $json.body.description || '' }}'
   )
   RETURNING id, customer_id, transaction_type, amount, currency, executed_at;
   ```
6. Rename to **`Insert Transaction`**

---

### Node 3: Lookup CTR Threshold

Reads the current CTR threshold from the config table — **never hardcoded**.

1. Click the **+** on the right side of **Insert Transaction**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT config_value, is_confirmed, source_note
   FROM regulatory_thresholds_config
   WHERE config_key = 'CTR_THRESHOLD_PKR';
   ```
6. Rename to **`Lookup CTR Threshold`**

---

### Node 4: IF — Cash Transaction?

CTRs only apply to **cash** transactions (deposits/withdrawals). Wire transfers, digital payments, etc. do not trigger CTR filing.

1. Click the **+** on the right side of **Lookup CTR Threshold**
2. Add an **IF** node
3. Click **Add condition** → select **String**
   - **Value 1:** `{{ $('Insert Transaction').first().json.transaction_type }}` *(Expression mode)*
   - **Operator:** `contains`
   - **Value 2:** `CASH`
4. Rename to **`IF: Cash Transaction?`**

---

### Node 5: Respond — Not Cash

Returns a clear response when the transaction is not a cash type.

1. Drag from the **false** output of **IF: Cash Transaction?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "NO_CTR_REQUIRED", "reason": "Transaction type is not cash (CASH_DEPOSIT or CASH_WITHDRAWAL). CTRs only apply to cash transactions.", "transaction_id": $('Insert Transaction').first().json.id, "transaction_type": $('Insert Transaction').first().json.transaction_type } }}
     ```
4. Rename to **`Respond: Not Cash`**

---

### Node 6: IF — Amount >= Threshold?

Compares the transaction amount against the regulatory threshold read from config.

1. Drag from the **true** output of **IF: Cash Transaction?**
2. Add an **IF** node
3. Click **Add condition** → select **Number**
   - **Value 1:** `{{ $('Insert Transaction').first().json.amount }}` *(Expression mode)*
   - **Operator:** `is greater than or equal`
   - **Value 2:** `{{ $('Lookup CTR Threshold').first().json.config_value }}` *(Expression mode)*
   - **Convert types where required:** Toggle to **ON** (active). *(This is required because Postgres returns numeric/decimal database fields as strings, and n8n expects explicit conversion for number comparisons).*
4. Rename to **`IF: Amount >= Threshold?`**

---

### Node 7: Respond — Below Threshold

1. Drag from the **false** output of **IF: Amount >= Threshold?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "BELOW_THRESHOLD", "transaction_id": $('Insert Transaction').first().json.id, "amount": $('Insert Transaction').first().json.amount, "threshold": $('Lookup CTR Threshold').first().json.config_value, "message": "Transaction amount is below CTR threshold. No CTR filing required." } }}
     ```
4. Rename to **`Respond: Below Threshold`**

---

### Node 8: Insert CTR Candidate

Flags the transaction as a CTR candidate with a snapshot of the threshold used.

1. Drag from the **true** output of **IF: Amount >= Threshold?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO ctr_candidates (transaction_id, threshold_applied, data_accuracy_status)
   VALUES (
     {{ $('Insert Transaction').first().json.id }},
     {{ $('Lookup CTR Threshold').first().json.config_value }},
     'PENDING_CHECK'
   )
   RETURNING id, transaction_id, threshold_applied, data_accuracy_status, flagged_at;
   ```
6. Rename to **`Insert CTR Candidate`**

---

### Node 9: Send Email — CTR Candidate Flagged

Notifies compliance that a transaction requires data accuracy verification before filing.

1. Click the **+** on the right side of **Insert CTR Candidate**
2. Add a **Send Email** node
3. **Credential:** Select existing SMTP credential (or create per Part 0.4)
4. Set:
   - **From Email:** `shazanali3210@gmail.com`
   - **To Email:** `shazanali3210@gmail.com`
   - **Subject:** `[UC5 CTR] New CTR Candidate Flagged — Transaction #{{ $('Insert Transaction').first().json.id }}` *(Expression mode)*
   - Click **Add Option** → **HTML** → Toggle **ON**
   - **HTML Body:** *(Fixed mode, paste directly)*
     ```html
     <html>
     <head>
       <style>
         body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; background: #f4f6f9; margin: 0; padding: 40px; }
         .card { background: #fff; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); max-width: 600px; margin: 0 auto; overflow: hidden; border: 1px solid #e1e4e8; }
         .header { background: linear-gradient(135deg, #1565c0 0%, #0d47a1 100%); color: #fff; padding: 30px; text-align: center; }
         .header h1 { margin: 0; font-size: 22px; font-weight: 600; }
         .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; }
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
           <h1>💰 CTR Candidate Flagged</h1>
           <p>UC5 — Currency Transaction Report Pipeline</p>
         </div>
         <div class="content">
           <span class="badge">ACTION REQUIRED: VERIFY DATA ACCURACY</span>
           <div class="section-title">Transaction Details</div>
           <table>
             <tr><td>Transaction ID</td><td>{{$('Insert Transaction').first().json.id}}</td></tr>
             <tr><td>Customer ID</td><td>{{$('Insert Transaction').first().json.customer_id}}</td></tr>
             <tr><td>Type</td><td>{{$('Insert Transaction').first().json.transaction_type}}</td></tr>
             <tr><td>Amount (PKR)</td><td style="color: #e53935;">{{$('Insert Transaction').first().json.amount}}</td></tr>
             <tr><td>Threshold Applied</td><td>{{$('Lookup CTR Threshold').first().json.config_value}}</td></tr>
           </table>
           <div class="section-title">Next Step</div>
           <p style="font-size:14px;">Please verify the data accuracy of this CTR candidate. Submit verification via <code>POST /webhook/uc5-ctr-verify</code> with the candidate ID.</p>
         </div>
         <div class="footer">
           GenosAI AML Compliance Automation • SBP Regulation 7 — CTR Filing
         </div>
       </div>
     </body>
     </html>
     ```
5. Rename to **`Send Email — CTR Candidate Flagged`**

---

### Node 10: Respond — CTR Candidate Created

Returns the flagged CTR candidate details.

1. Click the **+** on the right side of **Send Email — CTR Candidate Flagged**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "CTR_CANDIDATE_FLAGGED", "ctr_candidate_id": $('Insert CTR Candidate').first().json.id, "transaction_id": $('Insert Transaction').first().json.id, "amount": $('Insert Transaction').first().json.amount, "threshold_applied": $('Insert CTR Candidate').first().json.threshold_applied, "data_accuracy_status": "PENDING_CHECK", "message": "Transaction flagged for CTR filing. Verify data accuracy via POST /webhook/uc5-ctr-verify." } }}
     ```
4. Rename to **`Respond: CTR Candidate Created`**

---

## FLOW B: Data Accuracy Verification + Filing

---

### Node 11: Webhook Trigger — CTR Verify

This is where the compliance officer confirms data accuracy or flags corrections.

1. Click an empty area of the canvas (not connected to Flow A)
2. Add a **Webhook** node (a separate, independent trigger)
3. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc5-ctr-verify`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook Trigger — CTR Verify`**

**Expected payload:**
```json
{
  "ctr_candidate_id": 1,
  "data_accuracy_status": "VERIFIED",
  "verified_by": "Officer Compliance"
}
```

---

### Node 12: Update CTR Candidate Status

Records the verification decision on the CTR candidate.

1. Click the **+** on the right side of **Webhook Trigger — CTR Verify**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE ctr_candidates
   SET data_accuracy_status = '{{ $json.body.data_accuracy_status }}',
       verified_by = '{{ $json.body.verified_by }}',
       verified_at = now()
   WHERE id = {{ $json.body.ctr_candidate_id }}
   RETURNING id, transaction_id, data_accuracy_status, verified_by, verified_at;
   ```
6. Rename to **`Update CTR Candidate Status`**

---

### Node 13: IF — Data Verified?

Branches on the verification outcome.

1. Click the **+** on the right side of **Update CTR Candidate Status**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.data_accuracy_status }}` *(Expression mode)*
   - **Operator:** `equal`
   - **Value 2:** `VERIFIED`
4. Rename to **`IF: Data Verified?`**

---

### Node 14: Respond — Correction Needed

1. Drag from the **false** output of **IF: Data Verified?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "CORRECTION_NEEDED", "ctr_candidate_id": $('Update CTR Candidate Status').first().json.id, "message": "Data accuracy check failed. Please correct the transaction data and resubmit for verification." } }}
     ```
4. Rename to **`Respond: Correction Needed`**

---

### Node 15: Get Transaction Details

Fetches the original transaction data needed to compute the retention date and generate the filing.

1. Drag from the **true** output of **IF: Data Verified?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT
     t.id AS transaction_id,
     t.customer_id,
     t.transaction_type,
     t.amount,
     t.currency,
     t.branch_code,
     t.channel,
     t.executed_at,
     c.full_name AS customer_name
   FROM transactions t
   JOIN customers c ON t.customer_id = c.id
   WHERE t.id = {{ $('Update CTR Candidate Status').first().json.transaction_id }};
   ```
6. Rename to **`Get Transaction Details`**

---

### Node 16: Insert CTR Filing

Creates the CTR filing record with a mock FMU reference and the computed retention date.

1. Click the **+** on the right side of **Get Transaction Details**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO ctr_filings (ctr_candidate_id, filing_reference, retention_until)
   VALUES (
     {{ $('Update CTR Candidate Status').first().json.id }},
     'FMU-CTR-' || to_char(now(), 'YYYYMMDD-HH24MISS') || '-' || {{ $('Update CTR Candidate Status').first().json.id }},
     GREATEST('{{ $json.executed_at }}'::timestamp, now())::date + interval '10 years'
   )
   RETURNING id, ctr_candidate_id, filing_reference, filed_at, retention_until;
   ```

> **Note on retention_until:** We use `GREATEST(executed_at, filed_at)` + 10 years to satisfy both the AML Act §7(4) anchor ("after reporting") and Reg 8 §3 anchor ("completion of transaction"). The later date is used as the conservative approach documented in the PRD.

6. Rename to **`Insert CTR Filing`**

---

### Node 17: Send Email — CTR Filed

Sends a confirmation that the CTR has been filed.

1. Click the **+** on the right side of **Insert CTR Filing**
2. Add a **Send Email** node
3. **Credential:** Select existing SMTP credential
4. Set:
   - **From Email:** `shazanali3210@gmail.com`
   - **To Email:** `shazanali3210@gmail.com`
   - **Subject:** `[UC5 CTR] CTR Filed — Reference {{ $json.filing_reference }}` *(Expression mode)*
   - Click **Add Option** → **HTML** → Toggle **ON**
   - **HTML Body:** *(Fixed mode, paste directly)*
     ```html
     <html>
     <head>
       <style>
         body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; background: #f4f6f9; margin: 0; padding: 40px; }
         .card { background: #fff; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); max-width: 600px; margin: 0 auto; overflow: hidden; border: 1px solid #e1e4e8; }
         .header { background: linear-gradient(135deg, #2e7d32 0%, #1b5e20 100%); color: #fff; padding: 30px; text-align: center; }
         .header h1 { margin: 0; font-size: 22px; font-weight: 600; }
         .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; }
         .content { padding: 30px; }
         .badge { display: inline-block; padding: 6px 12px; font-size: 12px; font-weight: 700; border-radius: 20px; text-transform: uppercase; margin-bottom: 20px; background: #e8f5e9; color: #2e7d32; }
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
           <h1>✅ CTR Filed Successfully</h1>
           <p>UC5 — Currency Transaction Report Pipeline</p>
         </div>
         <div class="content">
           <span class="badge">STATUS: FILED WITH FMU</span>
           <div class="section-title">Filing Details</div>
           <table>
             <tr><td>Filing Reference</td><td>{{$json.filing_reference}}</td></tr>
             <tr><td>Filed At</td><td>{{$json.filed_at}}</td></tr>
             <tr><td>Retention Until</td><td>{{$json.retention_until}}</td></tr>
           </table>
           <div class="section-title">Transaction Details</div>
           <table>
             <tr><td>Customer</td><td>{{$('Get Transaction Details').first().json.customer_name}}</td></tr>
             <tr><td>Amount (PKR)</td><td>{{$('Get Transaction Details').first().json.amount}}</td></tr>
             <tr><td>Type</td><td>{{$('Get Transaction Details').first().json.transaction_type}}</td></tr>
             <tr><td>Branch</td><td>{{$('Get Transaction Details').first().json.branch_code}}</td></tr>
           </table>
           <div class="section-title">Regulatory Basis</div>
           <p style="font-size:14px;">Filed under AML Act 2010 §7 — SBP Regulation 7. Records retained for 10 years per Reg 8 §3.</p>
         </div>
         <div class="footer">
           GenosAI AML Compliance Automation • SBP Regulation 7 — CTR Filing
         </div>
       </div>
     </body>
     </html>
     ```
5. Rename to **`Send Email — CTR Filed`**

---

### Node 18: Respond — CTR Filed

Returns the final filing confirmation.

1. Click the **+** on the right side of **Send Email — CTR Filed**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "CTR_FILED", "filing_id": $('Insert CTR Filing').first().json.id, "filing_reference": $('Insert CTR Filing').first().json.filing_reference, "filed_at": $('Insert CTR Filing').first().json.filed_at, "retention_until": $('Insert CTR Filing').first().json.retention_until, "transaction_id": $('Get Transaction Details').first().json.transaction_id, "customer_name": $('Get Transaction Details').first().json.customer_name, "amount": $('Get Transaction Details').first().json.amount, "message": "CTR filed with FMU (mock). Record retained until " + $('Insert CTR Filing').first().json.retention_until + " per Reg 8 §3." } }}
     ```
4. Rename to **`Respond: CTR Filed`**

---

## Part 2B: Build It — STR Investigation Pipeline (Workflow 2)

**Create a new workflow:** Click **"Create Workflow"** → rename to **`UC5 - STR Investigation Pipeline`**

---

## FLOW A: Multi-Source Case Creation

---

### Node 1: Webhook — TMS Alert

Entry point for Transaction Monitoring System alerts (Reg 12 §6).

1. Click the **"+"** button in the center of the canvas
2. Search for **"Webhook"** → click to add it
3. Set:
   - **HTTP Method:** `POST`
   - **Path:** `uc5-str-tms-alert`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook — TMS Alert`**

---

### Node 2: Set Trigger — TMS Alert

1. Click the **+** on the right side of **Webhook — TMS Alert**
2. Add a **Set** node
3. Click **Add Field** → **String**:
   - **Name:** `trigger_type`
   - **Value:** `TMS_ALERT`
4. Click **Add Field** → **String**:
   - **Name:** `trigger_subtype`
   - **Value:** *(leave empty)*
5. Click **Add Field** → **Number**:
   - **Name:** `customer_id`
   - **Value:** `{{ $json.body.customer_id }}` *(Expression mode)*
6. Click **Add Field** → **String**:
   - **Name:** `source_reference`
   - **Value:** `{{ $json.body.source_reference || '' }}` *(Expression mode)*
7. Click **Add Field** → **String**:
   - **Name:** `description`
   - **Value:** `{{ $json.body.description || '' }}` *(Expression mode)*
8. Rename to **`Set Trigger — TMS Alert`**

---

### Node 3: Webhook — Manual Staff Observation

Entry point for staff-observed suspicious activity (no TMS alert involved).

1. Click an empty area of the canvas
2. Add a **Webhook** node
3. Set:
   - **HTTP Method:** `POST`
   - **Path:** `uc5-str-manual-obs`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook — Manual Observation`**

---

### Node 4: Set Trigger — Manual Observation

1. Click the **+** on the right side of **Webhook — Manual Observation**
2. Add a **Set** node
3. Click **Add Field** → **String**:
   - **Name:** `trigger_type`
   - **Value:** `MANUAL_STAFF_OBSERVATION`
4. Click **Add Field** → **String**:
   - **Name:** `trigger_subtype`
   - **Value:** *(leave empty)*
5. Click **Add Field** → **Number**:
   - **Name:** `customer_id`
   - **Value:** `{{ $json.body.customer_id }}` *(Expression mode)*
6. Click **Add Field** → **String**:
   - **Name:** `source_reference`
   - **Value:** `{{ $json.body.source_reference || '' }}` *(Expression mode)*
7. Click **Add Field** → **String**:
   - **Name:** `description`
   - **Value:** `{{ $json.body.description || '' }}` *(Expression mode)*
8. Rename to **`Set Trigger — Manual Observation`**

---

### Node 5: Webhook — Cross-UC Finding

Entry point for findings from other use cases (e.g., UC3 PEP gap).

1. Click an empty area of the canvas
2. Add a **Webhook** node
3. Set:
   - **HTTP Method:** `POST`
   - **Path:** `uc5-str-cross-uc`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook — Cross-UC Finding`**

---

### Node 6: Set Trigger — Cross-UC Finding

1. Click the **+** on the right side of **Webhook — Cross-UC Finding**
2. Add a **Set** node
3. Click **Add Field** → **String**:
   - **Name:** `trigger_type`
   - **Value:** `CROSS_UC_FINDING`
4. Click **Add Field** → **String**:
   - **Name:** `trigger_subtype`
   - **Value:** *(leave empty)*
5. Click **Add Field** → **Number**:
   - **Name:** `customer_id`
   - **Value:** `{{ $json.body.customer_id }}` *(Expression mode)*
6. Click **Add Field** → **String**:
   - **Name:** `source_reference`
   - **Value:** `{{ $json.body.source_reference || '' }}` *(Expression mode)*
7. Click **Add Field** → **String**:
   - **Name:** `description`
   - **Value:** `{{ $json.body.description || '' }}` *(Expression mode)*
8. Rename to **`Set Trigger — Cross-UC Finding`**

---

### Node 7: Webhook — CDD Failure / Tip-Off Risk

Entry point for AML Act 2010 §7D triggers. This has a **subtype**:
- `CDD_INCOMPLETE_S7D1` — CDD couldn't be completed
- `CDD_WOULD_TIPOFF_S7D2` — pursuing CDD would tip off the customer

1. Click an empty area of the canvas
2. Add a **Webhook** node
3. Set:
   - **HTTP Method:** `POST`
   - **Path:** `uc5-str-cdd-failure`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook — CDD Failure`**

---

### Node 8: Set Trigger — CDD Failure

1. Click the **+** on the right side of **Webhook — CDD Failure**
2. Add a **Set** node
3. Click **Add Field** → **String**:
   - **Name:** `trigger_type`
   - **Value:** `CDD_FAILURE_OR_TIPOFF_RISK`
4. Click **Add Field** → **String**:
   - **Name:** `trigger_subtype`
   - **Value:** `{{ $json.body.trigger_subtype }}` *(Expression mode)*
5. Click **Add Field** → **Number**:
   - **Name:** `customer_id`
   - **Value:** `{{ $json.body.customer_id }}` *(Expression mode)*
6. Click **Add Field** → **String**:
   - **Name:** `source_reference`
   - **Value:** `{{ $json.body.source_reference || '' }}` *(Expression mode)*
7. Click **Add Field** → **String**:
   - **Name:** `description`
   - **Value:** `{{ $json.body.description || '' }}` *(Expression mode)*
8. Rename to **`Set Trigger — CDD Failure`**

---

### Node 9: Merge All Triggers

Merges all four trigger paths into a single downstream flow to keep downstream connections clean.

1. Add a **Merge** node
2. Click **Add Input** in the parameter panel until you have 4 input ports.
3. Connect the outputs of the four Set nodes (Nodes 2, 4, 6, 8) to the four input ports of the Merge node.
4. Set **Mode:** `Append`
5. Rename to **`Merge`**

---

### Node 10: Insert STR Case Trigger

Records the trigger event in the database.

1. Add a **Postgres** node
2. Connect the output of the **Merge** node (Node 9) to this node.
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO str_case_triggers (trigger_type, trigger_subtype, source_reference, customer_id, details)
   VALUES (
     '{{ $json.trigger_type }}',
     {{ $json.trigger_subtype ? "'" + $json.trigger_subtype + "'" : 'NULL' }},
     '{{ $json.source_reference }}',
     {{ $json.customer_id }},
     '{{ JSON.stringify({ description: $json.description }) }}'::jsonb
   )
   RETURNING id, trigger_type, trigger_subtype, customer_id, triggered_at;
   ```
6. Rename to **`Insert STR Case Trigger`**

---

### Node 11: Generate Case Ref + Insert STR Case

Creates the STR case record with a unique reference number, and applies the §7D(2) fast-track rule.

1. Click the **+** on the right side of **Insert STR Case Trigger**
2. Add a **Code** node (JavaScript)
3. Set **Mode:** `Run Once for Each Item`
4. Paste:
   ```javascript
   // Generate a unique case reference: STR-YYYYMMDD-NNNN
   const triggerId = $json.id;
   const now = new Date();
   const datePart = now.toISOString().slice(0,10).replace(/-/g,'');
   const caseRef = `STR-${datePart}-${String(triggerId).padStart(4, '0')}`;

   // Determine initial review_status based on trigger subtype
   // Per PRD: if CDD_WOULD_TIPOFF_S7D2, suspicion is already legally established
   // → skip to RECOMMENDED_FOR_FILING
   const triggerSubtype = $json.trigger_subtype;
   const initialStatus = (triggerSubtype === 'CDD_WOULD_TIPOFF_S7D2')
     ? 'RECOMMENDED_FOR_FILING'
     : 'PENDING_FIRST_REVIEW';

   return {
     json: {
       trigger_id: triggerId,
       case_ref: caseRef,
       customer_id: $json.customer_id,
       trigger_type: $json.trigger_type,
       trigger_subtype: triggerSubtype,
       initial_status: initialStatus
     }
   };
   ```
5. Rename to **`Generate Case Ref`**

---

### Node 12: Insert STR Case

1. Click the **+** on the right side of **Generate Case Ref**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO str_cases (trigger_id, case_ref, customer_id, review_status, is_confidential)
   VALUES (
     {{ $json.trigger_id }},
     '{{ $json.case_ref }}',
     {{ $json.customer_id }},
     '{{ $json.initial_status }}',
     TRUE
   )
   RETURNING id, case_ref, customer_id, review_status, is_confidential, opened_at;
   ```
6. Rename to **`Insert STR Case`**

---

### Node 13: Aggregate Customer Profile

Pulls the customer's profile and recent transactions for the triage score calculation.

1. Click the **+** on the right side of **Insert STR Case**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT
     c.id AS customer_id,
     c.full_name,
     c.date_of_birth,
     c.nationality_status,
     COALESCE(
       (SELECT json_agg(sub) FROM (
         SELECT t.id, t.transaction_type, t.amount, t.currency, t.executed_at
         FROM transactions t
         WHERE t.customer_id = c.id
         ORDER BY t.executed_at DESC
         LIMIT 10
       ) sub),
       '[]'::json
     ) AS recent_transactions,
     (SELECT COUNT(*) FROM transactions t WHERE t.customer_id = c.id) AS total_transactions,
     (SELECT COALESCE(SUM(t.amount), 0) FROM transactions t WHERE t.customer_id = c.id AND t.executed_at > now() - interval '30 days') AS last_30d_volume
   FROM customers c
   WHERE c.id = {{ $('Insert STR Case').first().json.customer_id }};
   ```
6. Rename to **`Aggregate Customer Profile`**

---

### Node 14: Compute Triage Score

A simple rule-based scoring rubric for queue ordering. **This score is for sorting ONLY — no branch reads it to auto-close anything.**

1. Click the **+** on the right side of **Aggregate Customer Profile**
2. Add a **Code** node (JavaScript)
3. Set **Mode:** `Run Once for Each Item`
4. Paste:
   ```javascript
   // Triage severity scoring rubric (POC — simple rule-based)
   // This score is for QUEUE ORDERING ONLY — never for auto-deciding outcomes.
   //
   // Rubric:
   //   +30 if trigger is TMS_ALERT (system-detected pattern)
   //   +40 if trigger is CDD_FAILURE_OR_TIPOFF_RISK (legally significant)
   //   +20 if trigger is CROSS_UC_FINDING (multi-UC correlation)
   //   +10 if trigger is MANUAL_STAFF_OBSERVATION (subjective)
   //   +15 if last 30 days volume > PKR 5M (high activity)
   //   +10 if total transactions > 20 (frequent transactor)

   const triggerType = $('Generate Case Ref').first().json.trigger_type;
   const last30dVolume = parseFloat($json.last_30d_volume || 0);
   const totalTx = parseInt($json.total_transactions || 0);

   let score = 0;

   // Trigger type scoring
   switch (triggerType) {
     case 'CDD_FAILURE_OR_TIPOFF_RISK': score += 40; break;
     case 'TMS_ALERT': score += 30; break;
     case 'CROSS_UC_FINDING': score += 20; break;
     case 'MANUAL_STAFF_OBSERVATION': score += 10; break;
   }

   // Activity-based scoring
   if (last30dVolume > 5000000) score += 15;
   if (totalTx > 20) score += 10;

   return {
     json: {
       triage_severity_score: score,
       customer_id: $json.customer_id,
       full_name: $json.full_name,
       total_transactions: totalTx,
       last_30d_volume: last30dVolume
     }
   };
   ```
5. Rename to **`Compute Triage Score`**

---

### Node 15: Update STR Case with Triage Score

1. Click the **+** on the right side of **Compute Triage Score**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE str_cases
   SET triage_severity_score = {{ $json.triage_severity_score }}
   WHERE id = {{ $('Insert STR Case').first().json.id }}
   RETURNING id, case_ref, triage_severity_score;
   ```
6. Rename to **`Update Triage Score`**

---

### Node 16: Send Email — New STR Case

1. Click the **+** on the right side of **Update Triage Score**
2. Add a **Send Email** node
3. **Credential:** Select existing SMTP credential
4. Set:
   - **From Email:** `shazanali3210@gmail.com`
   - **To Email:** `shazanali3210@gmail.com`
   - **Subject:** `[UC5 STR] ⚠️ New STR Case Opened — {{ $('Insert STR Case').first().json.case_ref }}` *(Expression mode)*
   - Click **Add Option** → **HTML** → Toggle **ON**
   - **HTML Body:** *(Fixed mode, paste directly)*
     ```html
     <html>
     <head>
       <style>
         body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; background: #f4f6f9; margin: 0; padding: 40px; }
         .card { background: #fff; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); max-width: 600px; margin: 0 auto; overflow: hidden; border: 1px solid #e1e4e8; }
         .header { background: linear-gradient(135deg, #d32f2f 0%, #b71c1c 100%); color: #fff; padding: 30px; text-align: center; }
         .header h1 { margin: 0; font-size: 22px; font-weight: 600; }
         .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; }
         .content { padding: 30px; }
         .badge { display: inline-block; padding: 6px 12px; font-size: 12px; font-weight: 700; border-radius: 20px; text-transform: uppercase; margin-bottom: 20px; background: #ffebee; color: #c62828; }
         .section-title { font-size: 14px; text-transform: uppercase; letter-spacing: 1px; color: #718096; border-bottom: 1px solid #edf2f7; padding-bottom: 8px; margin-top: 25px; margin-bottom: 15px; }
         table { width: 100%; border-collapse: collapse; }
         td { padding: 8px 0; font-size: 14px; }
         td:first-child { color: #718096; width: 40%; }
         td:last-child { font-weight: 600; }
         .footer { background: #f8f9fa; padding: 20px 30px; text-align: center; font-size: 12px; color: #718096; }
         .warning { background: #fff3cd; border: 1px solid #ffc107; border-radius: 8px; padding: 12px; margin-top: 15px; font-size: 13px; color: #856404; }
       </style>
     </head>
     <body>
       <div class="card">
         <div class="header">
           <h1>🔍 New STR Case Opened</h1>
           <p>UC5 — Suspicious Transaction Report Pipeline</p>
         </div>
         <div class="content">
           <span class="badge">CONFIDENTIAL — COMPLIANCE USE ONLY</span>
           <div class="section-title">Case Details</div>
           <table>
             <tr><td>Case Ref</td><td>{{$('Insert STR Case').first().json.case_ref}}</td></tr>
             <tr><td>Status</td><td>{{$('Insert STR Case').first().json.review_status}}</td></tr>
             <tr><td>Trigger Type</td><td>{{$('Generate Case Ref').first().json.trigger_type}}</td></tr>
             <tr><td>Triage Score</td><td>{{$json.triage_severity_score}}</td></tr>
           </table>
           <div class="section-title">Customer</div>
           <table>
             <tr><td>Name</td><td>{{$('Compute Triage Score').first().json.full_name}}</td></tr>
             <tr><td>Customer ID</td><td>{{$('Insert STR Case').first().json.customer_id}}</td></tr>
           </table>
           <div class="warning">
             ⚠️ <strong>Reg 13 §4(d) Reminder:</strong> Do NOT disclose to the customer or any front-line staff that this case exists. Tipping-off is a criminal offense.
           </div>
           <div class="section-title">Next Step</div>
           <p style="font-size:14px;">Compliance analyst must review this case via <code>POST /webhook/uc5-str-analyst-action</code>.</p>
         </div>
         <div class="footer">
           GenosAI AML Compliance Automation • SBP Regulation 7 / Reg 13 §4(d)
         </div>
       </div>
     </body>
     </html>
     ```
5. Rename to **`Send Email — New STR Case`**

---

### Node 17: Respond — Case Created

1. Click the **+** on the right side of **Send Email — New STR Case**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "STR_CASE_CREATED", "case_id": $('Insert STR Case').first().json.id, "case_ref": $('Insert STR Case').first().json.case_ref, "review_status": $('Insert STR Case').first().json.review_status, "triage_severity_score": $('Update Triage Score').first().json.triage_severity_score, "trigger_type": $('Generate Case Ref').first().json.trigger_type, "trigger_subtype": $('Generate Case Ref').first().json.trigger_subtype || null, "customer_id": $('Insert STR Case').first().json.customer_id, "is_confidential": true, "message": "STR case opened. Analyst must review via POST /webhook/uc5-str-analyst-action." } }}
     ```
4. Rename to **`Respond: Case Created`**

---

## FLOW B: Analyst Investigation + Decision

---

### Node 18: Webhook — Analyst Action

This is the analyst's interface for investigating cases and submitting decisions.

1. Click an empty area of the canvas (not connected to Flow A)
2. Add a **Webhook** node
3. Set:
   - **HTTP Method:** `POST`
   - **Path:** `uc5-str-analyst-action`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook — Analyst Action`**

**Expected payload for investigation:**
```json
{
  "str_case_id": 1,
  "action": "investigate",
  "analyst_name": "Analyst Ahmed",
  "analyst_role": "COMPLIANCE_ANALYST",
  "transaction_history_reviewed": [{"id": 7, "amount": 1900000}],
  "background_purpose_findings": "Customer has no declared source for repeated near-threshold deposits.",
  "narrative_draft": "The customer exhibits a pattern of structuring...",
  "narrative_edited_by_human": true
}
```

**Expected payload for decision:**
```json
{
  "str_case_id": 1,
  "action": "decide",
  "analyst_name": "Analyst Ahmed",
  "analyst_role": "COMPLIANCE_ANALYST",
  "decision": "FILE_STR",
  "rationale": "Clear structuring pattern detected across 5 transactions over 3 days."
}
```

---

### Node 19: Validate Analyst Role

Validates that the requester has a valid compliance role before any case access.

1. Click the **+** on the right side of **Webhook — Analyst Action**
2. Add a **Code** node (JavaScript)
3. Set **Mode:** `Run Once for Each Item`
4. Paste:
   ```javascript
   const role = $json.body.analyst_role;
   const validRoles = ['COMPLIANCE_ANALYST'];

   if (!validRoles.includes(role)) {
     return {
       json: {
         is_valid_role: false,
         error: 'ACCESS_DENIED',
         message: 'Only COMPLIANCE_ANALYST role can perform analyst actions. Per Reg 13 §4(d), front-line staff must not access STR case data.'
       }
     };
   }

   return {
     json: {
       is_valid_role: true,
       ...($json.body)
     }
   };
   ```
5. Rename to **`Validate Analyst Role`**

---

### Node 20: IF — Valid Role?

1. Click the **+** on the right side of **Validate Analyst Role**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.is_valid_role }}` *(Expression mode)*
   - **Operator:** `Is True`
4. Rename to **`IF: Valid Role?`**

---

### Node 21: Respond — Access Denied

1. Drag from the **false** output of **IF: Valid Role?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Code:** `403`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "ACCESS_DENIED", "message": $json.message, "regulation": "Reg 13 §4(d) — Tipping-off prohibition" } }}
     ```
4. Rename to **`Respond: Access Denied`**

---

### Node 22: Log Access — Analyst

Logs the case access to the audit trail.

1. Drag from the **true** output of **IF: Valid Role?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO str_access_log (str_case_id, accessed_by, accessed_by_role, access_type)
   VALUES (
     {{ $json.str_case_id }},
     '{{ $json.analyst_name }}',
     '{{ $json.analyst_role }}',
     '{{ $json.action === "investigate" ? "INVESTIGATE" : "DECIDE" }}'
   )
   RETURNING id;
   ```
6. Rename to **`Log Access — Analyst`**

---

### Node 23: IF — Action is Investigate?

1. Click the **+** on the right side of **Log Access — Analyst**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $('Validate Analyst Role').first().json.action }}` *(Expression mode)*
   - **Operator:** `equal`
   - **Value 2:** `investigate`
4. Rename to **`IF: Action = Investigate?`**

---

### Node 24: Insert Investigation Log

Records the analyst's investigation findings (Reg 2 §21(e) — "examine as far as possible").

1. Drag from the **true** output of **IF: Action = Investigate?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO str_investigation_log (
     str_case_id,
     analyst_name,
     transaction_history_reviewed,
     background_purpose_findings,
     narrative_draft,
     narrative_edited_by_human
   ) VALUES (
     {{ $('Validate Analyst Role').first().json.str_case_id }},
     '{{ $('Validate Analyst Role').first().json.analyst_name }}',
     '{{ JSON.stringify($('Validate Analyst Role').first().json.transaction_history_reviewed || []) }}'::jsonb,
     '{{ $('Validate Analyst Role').first().json.background_purpose_findings || '' }}',
     '{{ $('Validate Analyst Role').first().json.narrative_draft || '' }}',
     {{ $('Validate Analyst Role').first().json.narrative_edited_by_human || false }}
   )
   RETURNING id, str_case_id, analyst_name, logged_at;
   ```
6. Rename to **`Insert Investigation Log`**

---

### Node 25: Update Case — Under Investigation

1. Click the **+** on the right side of **Insert Investigation Log**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE str_cases
   SET review_status = 'UNDER_INVESTIGATION'
   WHERE id = {{ $('Validate Analyst Role').first().json.str_case_id }}
     AND review_status IN ('PENDING_FIRST_REVIEW', 'NEEDS_MORE_INFO', 'UNDER_INVESTIGATION')
   RETURNING id, case_ref, review_status;
   ```
6. Rename to **`Update Case — Under Investigation`**

---

### Node 26: Respond — Investigation Logged

1. Click the **+** on the right side of **Update Case — Under Investigation**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "INVESTIGATION_LOGGED", "investigation_id": $('Insert Investigation Log').first().json.id, "str_case_id": $('Insert Investigation Log').first().json.str_case_id, "case_ref": $('Update Case — Under Investigation').first().json.case_ref, "review_status": "UNDER_INVESTIGATION", "message": "Investigation findings recorded. Submit decision via action: 'decide'." } }}
     ```
4. Rename to **`Respond: Investigation Logged`**

---

### Node 26A: IF — Rationale Provided?

Validates that the analyst has submitted a non-empty rationale, as required by regulations.

1. Drag from the **false** output of **IF: Action = Investigate?** (the "decide" path)
2. Add an **IF** node
3. Set condition:
   - Click **Add condition** → select **String**
   - **Value 1:** `{{ $('Validate Analyst Role').first().json.rationale }}` *(Expression mode)*
   - **Operator:** `is not empty`
   - **Convert types where required:** Toggle to **ON** (active).
4. Rename to **`IF: Rationale Provided?`**

---

### Node 26B: Respond — Rationale Required

Gracefully returns a 400 Bad Request if the analyst attempts to decide a case without a rationale.

1. Drag from the **false** output of **IF: Rationale Provided?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Code:** `400`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "VALIDATION_FAILED", "error": "RATIONALE_REQUIRED", "message": "Under SBP AML/CFT Regulation 7 & Reg 2 §21(e), a detailed non-empty compliance rationale is mandatory for recording any STR decisions (file or close).", "regulation_reference": "Regulation 7 & Reg 2 §21(e)" } }}
     ```
4. Rename to **`Respond: Rationale Required`**

---

### Node 27: Insert Analyst Decision

Records the analyst's final decision. The database has a check constraint preventing blank values.

1. Drag from the **true** output of **IF: Rationale Provided?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO str_analyst_decisions (str_case_id, decision, rationale, decided_by)
   VALUES (
     {{ $('Validate Analyst Role').first().json.str_case_id }},
     '{{ $('Validate Analyst Role').first().json.decision }}',
     '{{ $('Validate Analyst Role').first().json.rationale }}',
     '{{ $('Validate Analyst Role').first().json.analyst_name }}'
   )
   RETURNING id, str_case_id, decision, rationale, decided_by, decided_at;
   ```
6. Rename to **`Insert Analyst Decision`**

---

### Node 28: IF — Decision = Close?

1. Click the **+** on the right side of **Insert Analyst Decision**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.decision }}` *(Expression mode)*
   - **Operator:** `equal`
   - **Value 2:** `CLOSE_NOT_SUSPICIOUS`
4. Rename to **`IF: Close Not Suspicious?`**

---

### Node 29: Update Case — Closed

1. Drag from the **true** output of **IF: Close Not Suspicious?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE str_cases
   SET review_status = 'CLOSED_NOT_SUSPICIOUS',
       closed_at = now()
   WHERE id = {{ $('Insert Analyst Decision').first().json.str_case_id }}
   RETURNING id, case_ref, review_status, closed_at;
   ```
6. Rename to **`Update Case — Closed`**

---

### Node 30: Respond — Case Closed

1. Click the **+** on the right side of **Update Case — Closed**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "CLOSED_NOT_SUSPICIOUS", "str_case_id": $json.id, "case_ref": $json.case_ref, "closed_at": $json.closed_at, "decision_by": $('Insert Analyst Decision').first().json.decided_by, "rationale": $('Insert Analyst Decision').first().json.rationale, "message": "Case closed by analyst decision. Logged with rationale for audit." } }}
     ```
4. Rename to **`Respond: Case Closed`**

---

### Node 31: IF — Decision = Needs More Info?

1. Drag from the **false** output of **IF: Close Not Suspicious?**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $('Insert Analyst Decision').first().json.decision }}` *(Expression mode)*
   - **Operator:** `equal`
   - **Value 2:** `NEEDS_MORE_INFO`
4. Rename to **`IF: Needs More Info?`**

---

### Node 32: Update Case — Needs More Info

1. Drag from the **true** output of **IF: Needs More Info?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE str_cases
   SET review_status = 'NEEDS_MORE_INFO'
   WHERE id = {{ $('Insert Analyst Decision').first().json.str_case_id }}
   RETURNING id, case_ref, review_status;
   ```
6. Rename to **`Update Case — Needs More Info`**

---

### Node 33: Respond — Needs More Info

1. Click the **+** on the right side of **Update Case — Needs More Info**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "NEEDS_MORE_INFO", "str_case_id": $json.id, "case_ref": $json.case_ref, "message": "Case requires additional information. Analyst can resubmit investigation findings via action: 'investigate'." } }}
     ```
4. Rename to **`Respond: Needs More Info`**

---

### Node 34: Update Case — Recommended for Filing

1. Drag from the **false** output of **IF: Needs More Info?** (this is the FILE_STR path)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE str_cases
   SET review_status = 'RECOMMENDED_FOR_FILING'
   WHERE id = {{ $('Insert Analyst Decision').first().json.str_case_id }}
   RETURNING id, case_ref, review_status;
   ```
6. Rename to **`Update Case — Recommended for Filing`**

---

### Node 35: Respond — Recommended for Filing

1. Click the **+** on the right side of **Update Case — Recommended for Filing**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "RECOMMENDED_FOR_FILING", "str_case_id": $json.id, "case_ref": $json.case_ref, "decision_by": $('Insert Analyst Decision').first().json.decided_by, "rationale": $('Insert Analyst Decision').first().json.rationale, "message": "Case recommended for STR filing. Compliance officer must sign off via POST /webhook/uc5-str-officer-signoff." } }}
     ```
4. Rename to **`Respond: Recommended for Filing`**

---

## FLOW C: Compliance Officer Sign-Off + Filing

---

### Node 36: Webhook — Officer Sign-Off

This is the compliance officer's interface for approving or returning STR cases.

1. Click an empty area of the canvas (not connected to Flows A or B)
2. Add a **Webhook** node
3. Set:
   - **HTTP Method:** `POST`
   - **Path:** `uc5-str-officer-signoff`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook — Officer Sign-Off`**

**Expected payload:**
```json
{
  "str_case_id": 1,
  "officer_name": "Director Compliance",
  "officer_role": "COMPLIANCE_OFFICER",
  "decision": "APPROVED",
  "comments": "Investigation findings support filing. Approve STR submission."
}
```

---

### Node 37: Validate Officer Role

1. Click the **+** on the right side of **Webhook — Officer Sign-Off**
2. Add a **Code** node (JavaScript)
3. Set **Mode:** `Run Once for Each Item`
4. Paste:
   ```javascript
   const role = $json.body.officer_role;
   const validRoles = ['COMPLIANCE_OFFICER'];

   if (!validRoles.includes(role)) {
     return {
       json: {
         is_valid_role: false,
         error: 'ACCESS_DENIED',
         message: 'Only COMPLIANCE_OFFICER role can sign off on STR filings.'
       }
     };
   }

   return {
     json: {
       is_valid_role: true,
       ...($json.body)
     }
   };
   ```
5. Rename to **`Validate Officer Role`**

---

### Node 38: IF — Valid Officer Role?

1. Click the **+** on the right side of **Validate Officer Role**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.is_valid_role }}` *(Expression mode)*
   - **Operator:** `Is True`
4. Rename to **`IF: Valid Officer Role?`**

---

### Node 39: Respond — Officer Access Denied

1. Drag from the **false** output of **IF: Valid Officer Role?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Code:** `403`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "ACCESS_DENIED", "message": $json.message } }}
     ```
4. Rename to **`Respond: Officer Access Denied`**

---

### Node 40: Log Access — Officer

1. Drag from the **true** output of **IF: Valid Officer Role?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO str_access_log (str_case_id, accessed_by, accessed_by_role, access_type)
   VALUES (
     {{ $json.str_case_id }},
     '{{ $json.officer_name }}',
     '{{ $json.officer_role }}',
     'SIGNOFF'
   )
   RETURNING id;
   ```
6. Rename to **`Log Access — Officer`**

---

### Node 41: Validate Case Status

Ensures the case is in the correct state (RECOMMENDED_FOR_FILING) before officer can act.

1. Click the **+** on the right side of **Log Access — Officer**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT id, case_ref, review_status, customer_id
   FROM str_cases
   WHERE id = {{ $('Validate Officer Role').first().json.str_case_id }}
     AND review_status = 'RECOMMENDED_FOR_FILING';
   ```
6. Click the **Settings** tab (gear icon) → toggle **Always Output Data** to **ON**
7. Rename to **`Validate Case Status`**

---

### Node 42: IF — Case Ready for Sign-Off?

1. Click the **+** on the right side of **Validate Case Status**
2. Add an **IF** node
3. Set condition:
   - Click **Add condition** → select **String**
   - **Value 1:** `{{ $json.id }}` *(Expression mode)*
   - **Operator:** `is not empty`
   - **Convert types where required:** Toggle to **ON** (active).
4. Rename to **`IF: Case Ready?`**

---

### Node 43: Respond — Case Not Ready

1. Drag from the **false** output of **IF: Case Ready?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Code:** `422`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "CASE_NOT_READY", "str_case_id": $('Validate Officer Role').first().json.str_case_id, "message": "Case is not in RECOMMENDED_FOR_FILING status. Cannot proceed with sign-off." } }}
     ```
4. Rename to **`Respond: Case Not Ready`**

---

### Node 44: Insert Officer Sign-Off

1. Drag from the **true** output of **IF: Case Ready?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO str_compliance_officer_signoff (str_case_id, decision, officer_name, comments)
   VALUES (
     {{ $('Validate Officer Role').first().json.str_case_id }},
     '{{ $('Validate Officer Role').first().json.decision }}',
     '{{ $('Validate Officer Role').first().json.officer_name }}',
     '{{ $('Validate Officer Role').first().json.comments || '' }}'
   )
   RETURNING id, str_case_id, decision, officer_name, decided_at;
   ```
6. Rename to **`Insert Officer Sign-Off`**

---

### Node 45: IF — Officer Approved?

1. Click the **+** on the right side of **Insert Officer Sign-Off**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.decision }}` *(Expression mode)*
   - **Operator:** `equal`
   - **Value 2:** `APPROVED`
4. Rename to **`IF: Officer Approved?`**

---

### Node 46: Update Case — Returned for Revision

1. Drag from the **false** output of **IF: Officer Approved?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE str_cases
   SET review_status = 'UNDER_INVESTIGATION'
   WHERE id = {{ $('Insert Officer Sign-Off').first().json.str_case_id }}
   RETURNING id, case_ref, review_status;
   ```
6. Rename to **`Update Case — Returned`**

---

### Node 47: Respond — Returned for Revision

1. Click the **+** on the right side of **Update Case — Returned**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "RETURNED_FOR_REVISION", "str_case_id": $json.id, "case_ref": $json.case_ref, "review_status": "UNDER_INVESTIGATION", "officer_comments": $('Insert Officer Sign-Off').first().json.comments || '', "message": "Case returned to analyst for revision. Officer comments attached." } }}
     ```
4. Rename to **`Respond: Returned for Revision`**

---

### Node 48: Get Transaction for Retention Date

Fetches the latest transaction date for the STR retention calculation.

1. Drag from the **true** output of **IF: Officer Approved?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT
     GREATEST(
       COALESCE((SELECT MAX(t.executed_at) FROM transactions t WHERE t.customer_id = sc.customer_id), now()),
       now()
     )::date + interval '10 years' AS retention_until,
     sc.case_ref,
     sc.customer_id
   FROM str_cases sc
   WHERE sc.id = {{ $('Insert Officer Sign-Off').first().json.str_case_id }};
   ```
6. Rename to **`Get Retention Date`**

---

### Node 49: Insert STR Filing

Creates the STR filing record with a mock FMU reference.

1. Click the **+** on the right side of **Get Retention Date**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO str_filings (str_case_id, filing_reference, retention_until)
   VALUES (
     {{ $('Insert Officer Sign-Off').first().json.str_case_id }},
     'FMU-STR-' || to_char(now(), 'YYYYMMDD-HH24MISS') || '-' || {{ $('Insert Officer Sign-Off').first().json.str_case_id }},
     '{{ $json.retention_until }}'::date
   )
   RETURNING id, str_case_id, filing_reference, filed_at, retention_until;
   ```
6. Rename to **`Insert STR Filing`**

---

### Node 50: Update Case — Filed

1. Click the **+** on the right side of **Insert STR Filing**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE str_cases
   SET review_status = 'FILED',
       closed_at = now()
   WHERE id = {{ $('Insert Officer Sign-Off').first().json.str_case_id }}
   RETURNING id, case_ref, review_status, closed_at;
   ```
6. Rename to **`Update Case — Filed`**

---

### Node 51: Send Email — STR Filed

1. Click the **+** on the right side of **Update Case — Filed**
2. Add a **Send Email** node
3. **Credential:** Select existing SMTP credential
4. Set:
   - **From Email:** `shazanali3210@gmail.com`
   - **To Email:** `shazanali3210@gmail.com`
   - **Subject:** `[UC5 STR] ✅ STR Filed — {{ $('Insert STR Filing').first().json.filing_reference }}` *(Expression mode)*
   - Click **Add Option** → **HTML** → Toggle **ON**
   - **HTML Body:** *(Fixed mode, paste directly)*
     ```html
     <html>
     <head>
       <style>
         body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; background: #f4f6f9; margin: 0; padding: 40px; }
         .card { background: #fff; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); max-width: 600px; margin: 0 auto; overflow: hidden; border: 1px solid #e1e4e8; }
         .header { background: linear-gradient(135deg, #2e7d32 0%, #1b5e20 100%); color: #fff; padding: 30px; text-align: center; }
         .header h1 { margin: 0; font-size: 22px; font-weight: 600; }
         .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; }
         .content { padding: 30px; }
         .badge { display: inline-block; padding: 6px 12px; font-size: 12px; font-weight: 700; border-radius: 20px; text-transform: uppercase; margin-bottom: 20px; background: #e8f5e9; color: #2e7d32; }
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
           <h1>✅ STR Filed Successfully</h1>
           <p>UC5 — Suspicious Transaction Report Pipeline</p>
         </div>
         <div class="content">
           <span class="badge">CONFIDENTIAL — FILED WITH FMU</span>
           <div class="section-title">Filing Details</div>
           <table>
             <tr><td>Filing Reference</td><td>{{$('Insert STR Filing').first().json.filing_reference}}</td></tr>
             <tr><td>Case Ref</td><td>{{$('Update Case — Filed').first().json.case_ref}}</td></tr>
             <tr><td>Filed At</td><td>{{$('Insert STR Filing').first().json.filed_at}}</td></tr>
             <tr><td>Retention Until</td><td>{{$('Insert STR Filing').first().json.retention_until}}</td></tr>
           </table>
           <div class="section-title">Approval Chain</div>
           <table>
             <tr><td>Signed Off By</td><td>{{$('Insert Officer Sign-Off').first().json.officer_name}}</td></tr>
             <tr><td>Decision</td><td style="color: #2e7d32;">APPROVED</td></tr>
           </table>
           <div class="section-title">Regulatory Basis</div>
           <p style="font-size:14px;">Filed under AML Act 2010 §7 — SBP Regulation 7. Records retained for 10 years per Reg 8 §3. Confidentiality maintained per Reg 13 §4(d).</p>
         </div>
         <div class="footer">
           GenosAI AML Compliance Automation • SBP Regulation 7 / Reg 13 §4(d)
         </div>
       </div>
     </body>
     </html>
     ```
5. Rename to **`Send Email — STR Filed`**

---

### Node 52: Respond — STR Filed

1. Click the **+** on the right side of **Send Email — STR Filed**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "STR_FILED", "filing_id": $('Insert STR Filing').first().json.id, "filing_reference": $('Insert STR Filing').first().json.filing_reference, "case_ref": $('Update Case — Filed').first().json.case_ref, "filed_at": $('Insert STR Filing').first().json.filed_at, "retention_until": $('Insert STR Filing').first().json.retention_until, "signed_off_by": $('Insert Officer Sign-Off').first().json.officer_name, "message": "STR filed with FMU (mock). Record retained until " + $('Insert STR Filing').first().json.retention_until + " per Reg 8 §3." } }}
     ```
4. Rename to **`Respond: STR Filed`**

---

## FLOW D: Access Control Validation (Tipping-Off Check)

---

### Node 53: Webhook — Access Check

Entry point for testing the access control gate. Front-line staff should be blocked.

1. Click an empty area of the canvas
2. Add a **Webhook** node
3. Set:
   - **HTTP Method:** `POST`
   - **Path:** `uc5-str-access-check`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook — Access Check`**

**Expected payload:**
```json
{
  "requester_name": "Branch Manager Amir",
  "requester_role": "RELATIONSHIP_MANAGER",
  "str_case_id": 1
}
```

---

### Node 54: Check Access Role

1. Click the **+** on the right side of **Webhook — Access Check**
2. Add a **Code** node (JavaScript)
3. Set **Mode:** `Run Once for Each Item`
4. Paste:
   ```javascript
   const role = $json.body.requester_role;
   const allowedRoles = ['COMPLIANCE_ANALYST', 'COMPLIANCE_OFFICER'];

   if (!allowedRoles.includes(role)) {
     return {
       json: {
         is_allowed: false,
         requester_name: $json.body.requester_name,
         requester_role: role,
         str_case_id: $json.body.str_case_id,
         message: 'ACCESS DENIED. Role "' + role + '" is not authorized to view STR case data. Per Reg 13 §4(d), front-line and relationship management staff must not access STR-related information.'
       }
     };
   }

   return {
     json: {
       is_allowed: true,
       requester_name: $json.body.requester_name,
       requester_role: role,
       str_case_id: $json.body.str_case_id
     }
   };
   ```
5. Rename to **`Check Access Role`**

---

### Node 55: IF — Access Allowed?

1. Click the **+** on the right side of **Check Access Role**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.is_allowed }}` *(Expression mode)*
   - **Operator:** `Is True`
4. Rename to **`IF: Access Allowed?`**

---

### Node 56: Respond — Tipping-Off Block

1. Drag from the **false** output of **IF: Access Allowed?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Code:** `403`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "ACCESS_DENIED", "requester_name": $json.requester_name, "requester_role": $json.requester_role, "regulation": "Reg 13 §4(d) — Employees shall be strictly prohibited from disclosing STR information.", "message": $json.message } }}
     ```
4. Rename to **`Respond: Access Denied (Tipping-Off)`**

---

### Node 57: Log Access + Return Case Data

For authorized roles, logs the access and returns the filtered case data.

1. Drag from the **true** output of **IF: Access Allowed?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   -- Log the access
   INSERT INTO str_access_log (str_case_id, accessed_by, accessed_by_role, access_type)
   VALUES ({{ $json.str_case_id }}, '{{ $json.requester_name }}', '{{ $json.requester_role }}', 'VIEW');

   -- Return the case data (only for confidential-authorized roles)
   SELECT
     sc.id, sc.case_ref, sc.review_status, sc.triage_severity_score,
     sc.is_confidential, sc.opened_at, sc.closed_at,
     c.full_name AS customer_name
   FROM str_cases sc
   JOIN customers c ON sc.customer_id = c.id
   WHERE sc.id = {{ $json.str_case_id }};
   ```
6. Rename to **`Log + Return Case Data`**

---

### Node 58: Respond — Case Data

1. Click the **+** on the right side of **Log + Return Case Data**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```
     {{ { "status": "ACCESS_GRANTED", "case_data": $json } }}
     ```
4. Rename to **`Respond: Case Data`**

---

## Part 3: Pre-Flight Checks

Before testing, make sure:

### 3.1 Activate Both Workflows
1. Open the **UC5 - CTR Pipeline** workflow → click **"Publish"** in the top-right corner
2. Open the **UC5 - STR Investigation Pipeline** workflow → click **"Publish"**

### 3.2 Test Webhook URLs

**CTR Pipeline (2 endpoints):**
- `http://localhost:5678/webhook/uc5-ctr-transaction` (Flow A — transaction intake)
- `http://localhost:5678/webhook/uc5-ctr-verify` (Flow B — data verification)

**STR Pipeline (7 endpoints):**
- `http://localhost:5678/webhook/uc5-str-tms-alert` (Flow A — TMS alert trigger)
- `http://localhost:5678/webhook/uc5-str-manual-obs` (Flow A — manual observation trigger)
- `http://localhost:5678/webhook/uc5-str-cross-uc` (Flow A — cross-UC finding trigger)
- `http://localhost:5678/webhook/uc5-str-cdd-failure` (Flow A — CDD failure trigger)
- `http://localhost:5678/webhook/uc5-str-analyst-action` (Flow B — analyst investigation/decision)
- `http://localhost:5678/webhook/uc5-str-officer-signoff` (Flow C — officer sign-off)
- `http://localhost:5678/webhook/uc5-str-access-check` (Flow D — access control test)

---

## Part 4: Complete Node Summary

### Workflow 1: UC5 - CTR Pipeline

| Node # | Name | Type | Flow |
|---|---|---|---|
| 1 | Webhook Trigger — Transaction Intake | Webhook | A |
| 2 | Insert Transaction | Postgres | A |
| 3 | Lookup CTR Threshold | Postgres | A |
| 4 | IF: Cash Transaction? | IF | A |
| 5 | Respond: Not Cash | Respond to Webhook | A |
| 6 | IF: Amount >= Threshold? | IF | A |
| 7 | Respond: Below Threshold | Respond to Webhook | A |
| 8 | Insert CTR Candidate | Postgres | A |
| 9 | Send Email — CTR Candidate Flagged | Send Email | A |
| 10 | Respond: CTR Candidate Created | Respond to Webhook | A |
| 11 | Webhook Trigger — CTR Verify | Webhook | B |
| 12 | Update CTR Candidate Status | Postgres | B |
| 13 | IF: Data Verified? | IF | B |
| 14 | Respond: Correction Needed | Respond to Webhook | B |
| 15 | Get Transaction Details | Postgres | B |
| 16 | Insert CTR Filing | Postgres | B |
| 17 | Send Email — CTR Filed | Send Email | B |
| 18 | Respond: CTR Filed | Respond to Webhook | B |

**Total: 18 nodes across 2 flows**

### Workflow 2: UC5 - STR Investigation Pipeline

| Node # | Name | Type | Flow |
|---|---|---|---|
| 1 | Webhook — TMS Alert | Webhook | A |
| 2 | Set Trigger — TMS Alert | Set | A |
| 3 | Webhook — Manual Observation | Webhook | A |
| 4 | Set Trigger — Manual Observation | Set | A |
| 5 | Webhook — Cross-UC Finding | Webhook | A |
| 6 | Set Trigger — Cross-UC Finding | Set | A |
| 7 | Webhook — CDD Failure | Webhook | A |
| 8 | Set Trigger — CDD Failure | Set | A |
| 9 | *(triggers connect directly to Node 10)* | — | A |
| 10 | Insert STR Case Trigger | Postgres | A |
| 11 | Generate Case Ref | Code | A |
| 12 | Insert STR Case | Postgres | A |
| 13 | Aggregate Customer Profile | Postgres | A |
| 14 | Compute Triage Score | Code | A |
| 15 | Update Triage Score | Postgres | A |
| 16 | Send Email — New STR Case | Send Email | A |
| 17 | Respond: Case Created | Respond to Webhook | A |
| 18 | Webhook — Analyst Action | Webhook | B |
| 19 | Validate Analyst Role | Code | B |
| 20 | IF: Valid Role? | IF | B |
| 21 | Respond: Access Denied | Respond to Webhook | B |
| 22 | Log Access — Analyst | Postgres | B |
| 23 | IF: Action = Investigate? | IF | B |
| 24 | Insert Investigation Log | Postgres | B |
| 25 | Update Case — Under Investigation | Postgres | B |
| 26 | Respond: Investigation Logged | Respond to Webhook | B |
| 27 | Insert Analyst Decision | Postgres | B |
| 28 | IF: Close Not Suspicious? | IF | B |
| 29 | Update Case — Closed | Postgres | B |
| 30 | Respond: Case Closed | Respond to Webhook | B |
| 31 | IF: Needs More Info? | IF | B |
| 32 | Update Case — Needs More Info | Postgres | B |
| 33 | Respond: Needs More Info | Respond to Webhook | B |
| 34 | Update Case — Recommended for Filing | Postgres | B |
| 35 | Respond: Recommended for Filing | Respond to Webhook | B |
| 36 | Webhook — Officer Sign-Off | Webhook | C |
| 37 | Validate Officer Role | Code | C |
| 38 | IF: Valid Officer Role? | IF | C |
| 39 | Respond: Officer Access Denied | Respond to Webhook | C |
| 40 | Log Access — Officer | Postgres | C |
| 41 | Validate Case Status | Postgres | C |
| 42 | IF: Case Ready? | IF | C |
| 43 | Respond: Case Not Ready | Respond to Webhook | C |
| 44 | Insert Officer Sign-Off | Postgres | C |
| 45 | IF: Officer Approved? | IF | C |
| 46 | Update Case — Returned | Postgres | C |
| 47 | Respond: Returned for Revision | Respond to Webhook | C |
| 48 | Get Retention Date | Postgres | C |
| 49 | Insert STR Filing | Postgres | C |
| 50 | Update Case — Filed | Postgres | C |
| 51 | Send Email — STR Filed | Send Email | C |
| 52 | Respond: STR Filed | Respond to Webhook | C |
| 53 | Webhook — Access Check | Webhook | D |
| 54 | Check Access Role | Code | D |
| 55 | IF: Access Allowed? | IF | D |
| 56 | Respond: Access Denied (Tipping-Off) | Respond to Webhook | D |
| 57 | Log + Return Case Data | Postgres | D |
| 58 | Respond: Case Data | Respond to Webhook | D |

**Total: 58 nodes across 4 flows**

**Combined UC5 total: 76 nodes across 2 workflows (6 flows)**
