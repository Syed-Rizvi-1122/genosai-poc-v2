# UC3: PEP Lifecycle Monitoring — n8n Step-by-Step Build Guide

> **Written for someone who has never used n8n.** Every click, every node, every setting is documented.
> If you've already built UC1, you can skip Part 0 — the canvas and credential patterns are the same.

---

## Part 0: Prerequisites

### 0.1 Make sure UC1 is deployed
UC3 **extends** UC1's database tables (`customers`, `beneficial_owners`, `cdd_cases`). The UC1 workflow must have been deployed first, and the UC3 migration scripts (`003_uc3_schema.sql` and `004_uc3_seed.sql`) must have been applied.

### 0.2 Open n8n
1. Open your browser → go to **http://localhost:5678**
2. Click **"Create Workflow"** → rename it to `UC3 - PEP Lifecycle Monitoring`

### 0.3 Reuse the AML Postgres Credential
Every Postgres node in this workflow reuses the **same credential** you created in UC1:

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

## Part 1: Workflow Architecture (4 Flows)

This workflow has **4 independent entry points** (webhook/schedule triggers). Each flow handles a different stage of the PEP lifecycle. They communicate through the database — one flow writes records, the next flow reads and acts on them.

### Flow A: Batch Re-screening (Scheduled / Event-Triggered)
```
Schedule Trigger (monthly) OR Webhook Trigger (uc3-rescreen-event)
    │
[Phase 0] Create Rescreening Cycle → rescreening_cycles
    │
[Phase 1] Compile candidates from UC1's customers table
    │
[Phase 2] Fuzzy name match against pep_watchlist_source
    │
[Phase 2b] Insert matches → pep_match_candidates (PENDING_REVIEW)
    │
Respond: Screening Complete (returns cycle_id + match count)
```

### Flow B: Analyst Review + Classification + Seniority Gate
```
Webhook Trigger (uc3-analyst-review)
    │
[Phase 3] Record analyst decision (CONFIRMED / REJECTED / INCONCLUSIVE)
    │
IF: Confirmed?
  ├── REJECTED → Audit log → Respond: Match Rejected
  ├── INCONCLUSIVE → Respond: Needs More Info
  └── CONFIRMED → Continue...
    │
[Phase 4] Record relationship classification (Def #12 / Def #28)
    │
IF: Valid relationship?
  ├── FALSE → Respond: Not Qualifying Relationship
  └── TRUE → Continue...
    │
[Phase 5] Record seniority check (Def #52(d))
    │
IF: Senior enough?
  ├── FALSE → Respond: Excluded (Junior/Middle Ranking)
  └── TRUE → Continue...
    │
[Phase 6] Insert pep_designations (formal PEP designation)
    │
Send Email: PEP Designated
    │
Respond: PEP Designated — Awaiting SOW Evidence
```

### Flow C: Source of Wealth + Senior Management Approval
```
Webhook Trigger (uc3-sow-approval)
    │
IF: action = 'submit_evidence'?
  ├── TRUE → [Phase 7] Insert source_of_wealth_evidence → Respond
  └── FALSE (action = 'approve')
        │
      Check: All evidence reconciled?
        ├── FALSE → Respond: ON_HOLD (evidence incomplete)
        └── TRUE → Continue...
          │
        [Phase 8] Record senior management decision
          │
        IF: Continue relationship?
          ├── EXIT → Send Email: Relationship Exit → Respond: Exit
          └── CONTINUE
                │
              [Phase 9] Insert enhanced_monitoring_flags (ENHANCED)
                │
              [Phase 10] Insert recertification_schedule
                │
              Send Email: PEP Lifecycle Complete
                │
              Respond: PEP Lifecycle Complete
```

### Flow D: Monitoring Intensity Step-Down
```
Webhook Trigger (uc3-stepdown)
    │
Validate: pep_designation exists + is_active = TRUE
    │
Insert monitoring_intensity_log
    │
Update enhanced_monitoring_flags → STANDARD
    │
Respond: Step-Down Recorded (designation preserved)
```

---

## Part 2: Build It — Node by Node

---

## FLOW A: Batch Re-screening

---

### Node 1: Schedule Trigger

This fires the batch re-screening on a monthly cadence.

1. Click the **"+"** button in the center of the canvas
2. Search for **"Schedule Trigger"** → click to add it
3. Set the following:
   - **Trigger Interval:** `Months`
   - **Months Between Triggers:** `1`
   - **Trigger at Day of Month:** `1`
   - **Trigger at Hour:** `2` (2 AM — off-peak)
   - **Trigger at Minute:** `0`
4. Rename to **`Schedule Trigger (Monthly)`**

---

### Node 2: Set Cycle Type — Scheduled

Sets the cycle type context for the scheduled trigger.

1. Click the **+** on the right side of **Schedule Trigger (Monthly)**
2. Add a **Set** node
3. Click **Add Field** → **String**:
   - **Name:** `cycle_type`
   - **Value:** `SCHEDULED`
4. Click **Add Field** → **String**:
   - **Name:** `trigger_reason`
   - **Value:** `MONTHLY_BATCH`
5. Rename to **`Set Cycle Type — Scheduled`**

---

### Node 3: Webhook Trigger — Event Rescreen

This is the event-triggered entry point (fires on profile update, BO change, etc.).

1. Click an empty area of the canvas (not connected to Node 1-2)
2. Add a **Webhook** node (a separate, independent trigger)
3. Set the following:
   - **HTTP Method:** `POST`
   - **Path:** `uc3-rescreen-event`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook Trigger — Event Rescreen`**

---

### Node 4: Set Cycle Type — Event

Sets the cycle type context for the event trigger.

1. Click the **+** on the right side of **Webhook Trigger — Event Rescreen**
2. Add a **Set** node
3. Click **Add Field** → **String**:
   - **Name:** `cycle_type`
   - **Value:** `EVENT_TRIGGERED`
4. Click **Add Field** → **String**:
   - **Name:** `trigger_reason`
   - **Value:** `{{ $json.body.trigger_reason }}`  *(Expression mode)*
5. Click **Add Field** → **Number**:
   - **Name:** `customer_id`
   - **Value:** `{{ $json.body.customer_id }}`  *(Expression mode)*
6. Rename to **`Set Cycle Type — Event`**

---

### Node 5: Merge Triggers

Merges both trigger paths into a single downstream flow.

1. Add a **Merge** node
2. Connect the output of **Set Cycle Type — Scheduled** (Node 2) to Input 1
3. Connect the output of **Set Cycle Type — Event** (Node 4) to Input 2
4. Set **Mode:** `Append`
5. Rename to **`Merge Triggers`**

---

### Node 6: Create Rescreening Cycle

Inserts a new row into `rescreening_cycles` to track this run.

1. Click the **+** on the right side of **Merge Triggers**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres` (select existing)
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO rescreening_cycles (cycle_type, trigger_reason, status)
   VALUES ('{{ $json.cycle_type }}', '{{ $json.trigger_reason }}', 'RUNNING')
   RETURNING id, cycle_type, trigger_reason, triggered_at;
   ```
6. Rename to **`Create Rescreening Cycle`**

---

### Node 7: Compile Candidates

Pulls all active customers + beneficial owners from UC1's tables for screening.
For event-triggered cycles, filters to only the specific customer.

1. Click the **+** on the right side of **Create Rescreening Cycle**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT
     c.id AS customer_id,
     c.full_name,
     c.date_of_birth,
     c.role AS person_role,
     cc.case_ref,
     cc.status AS case_status
   FROM customers c
   JOIN cdd_cases cc ON c.case_id = cc.id
   WHERE cc.status = 'APPROVED'
     AND (
       '{{ $json.cycle_type }}' = 'SCHEDULED'
       OR c.id = {{ $('Merge Triggers').first().json.customer_id || 0 }}
     )
   ORDER BY c.id;
   ```
6. Rename to **`Compile Candidates`**

---

### Node 8: Insert Rescreening Candidates

Inserts each candidate into `rescreening_candidates` and then performs fuzzy screening.

1. Click the **+** on the right side of **Compile Candidates**
2. Add a **Code** node (JavaScript)
3. Set **Mode:** `Run Once for All Items`
4. Paste this code:
   ```javascript
   // This Code node processes each candidate:
   // 1. Inserts into rescreening_candidates
   // 2. Fuzzy-matches against pep_watchlist_source
   // 3. Inserts any matches above 60% threshold into pep_match_candidates

   const cycle_id = $('Create Rescreening Cycle').first().json.id;
   const candidates = $input.all();
   const results = [];
   let totalMatches = 0;

   for (const candidate of candidates) {
     const c = candidate.json;

     // Step 1: Insert into rescreening_candidates
     const rcInsert = await this.helpers.httpRequest({
       method: 'POST',
       url: 'http://postgres:5432', // We'll use $helpers instead
     });

     // Actually, n8n Code nodes can't directly query Postgres.
     // We'll use a simpler approach: collect all candidates and
     // pass them downstream to Postgres nodes for batch processing.
     results.push({
       json: {
         cycle_id: cycle_id,
         customer_id: c.customer_id,
         full_name: c.full_name,
         date_of_birth: c.date_of_birth,
         person_role: c.person_role,
         case_ref: c.case_ref
       }
     });
   }

   return results;
   ```
5. Rename to **`Prepare Candidates`**

> **Important:** Actually, n8n Code nodes cannot directly access the database. We need a better pattern. Let me restructure this. Delete Node 8 if you already added it.

---

### Node 8 (Revised): Loop Over Candidates

We need to process each candidate individually — insert it, then screen it.

1. Click the **+** on the right side of **Compile Candidates**
2. Add a **Loop Over Items** node
3. Set **Batch Size:** `1`
4. Rename to **`Loop Over Candidates`**

---

### Node 9: Insert Rescreening Candidate

Inserts the current candidate into `rescreening_candidates`.

1. Click the **+** on the **"loop"** (main) output of **Loop Over Candidates**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO rescreening_candidates (cycle_id, customer_id, person_role)
   VALUES (
     {{ $('Create Rescreening Cycle').first().json.id }},
     {{ $json.customer_id }},
     '{{ $json.person_role }}'
   )
   RETURNING id, customer_id;
   ```
6. Rename to **`Insert Rescreening Candidate`**

---

### Node 10: Fuzzy Name Screen

Fuzzy-matches the candidate's name against `pep_watchlist_source` using PostgreSQL's `similarity()` function.

1. Click the **+** on the right side of **Insert Rescreening Candidate**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT
     pw.id AS pep_watchlist_source_id,
     pw.full_name AS watchlist_name,
     pw.pep_category,
     pw.seniority_level,
     pw.position_title,
     ROUND((similarity(
       LOWER('{{ $('Loop Over Candidates').first().json.full_name }}'),
       LOWER(pw.full_name)
     ) * 100)::numeric, 2) AS match_confidence
   FROM pep_watchlist_source pw
   WHERE similarity(
     LOWER('{{ $('Loop Over Candidates').first().json.full_name }}'),
     LOWER(pw.full_name)
   ) >= 0.6
   ORDER BY match_confidence DESC;
   ```

   > **IMPORTANT:** This query uses PostgreSQL's `pg_trgm` extension for the `similarity()` function. You need to enable it first. Run this once in your Postgres container:
   > ```bash
   > docker exec -i aml-postgres psql -U aml_user -d aml_local -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
   > ```

6. Rename to **`Fuzzy Name Screen`**

---

### Node 11: IF: Any Matches?

Checks if the fuzzy screen returned any results.

1. Click the **+** on the right side of **Fuzzy Name Screen**
2. Add an **IF** node
3. Set condition:
   - Click **Add condition** → select **String** (do not select Boolean, since `pep_watchlist_source_id` is a numeric/string identifier rather than a true/false flag)
   - **Value 1:** `{{ $json.pep_watchlist_source_id }}`  *(Expression mode)*
   - **Operator:** `is not empty`
4. Rename to **`IF: Any Matches?`**

---

### Node 12: Insert PEP Match Candidates

Inserts each match into `pep_match_candidates` with status `PENDING_REVIEW`.

1. Drag from the **true** output of **IF: Any Matches?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO pep_match_candidates (
     rescreening_candidate_id,
     pep_watchlist_source_id,
     match_confidence,
     review_status
   ) VALUES (
     {{ $('Insert Rescreening Candidate').first().json.id }},
     {{ $json.pep_watchlist_source_id }},
     {{ $json.match_confidence }},
     'PENDING_REVIEW'
   )
   RETURNING id, match_confidence, review_status;
   ```
6. Rename to **`Insert PEP Match Candidates`**

---

### Node 13: Connect Back to Loop

Both the **false** output of **IF: Any Matches?** and the output of **Insert PEP Match Candidates** need to loop back.

1. Connect the **false** output of **IF: Any Matches?** → back to the **Loop Over Candidates** node (the "done" input will auto-route)
2. Connect the output of **Insert PEP Match Candidates** → also back to **Loop Over Candidates**

> The **Loop Over Items** node will automatically detect when all items have been processed and proceed from its **"done"** output.

---

### Node 13b: Collapse to Single Item

Collapses the loop's output array of multiple candidate items into exactly one item, ensuring the downstream completion steps (DB update, summary email, webhook response) execute only once.

1. Drag from the **"done"** output of **Loop Over Candidates**
2. Add a **Code** node
3. Set **Mode:** `Run Once for All Items`
4. Paste the following JavaScript code:
   ```javascript
   return [ $input.first() ];
   ```
5. Rename to **`Collapse to Single Item`**

---

### Node 14: Complete Cycle

Marks the re-screening cycle as COMPLETE.

1. Click the **+** on the right side of **Collapse to Single Item**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE rescreening_cycles
   SET status = 'COMPLETE', completed_at = now()
   WHERE id = {{ $('Create Rescreening Cycle').first().json.id }}
   RETURNING id, status, completed_at;
   ```
6. Rename to **`Complete Cycle`**

---

### Node 15: Get Match Count

Gets a summary of matches found in this cycle.

1. Click the **+** on the right side of **Complete Cycle**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT
     rc.id AS cycle_id,
     rc.cycle_type,
     rc.trigger_reason,
     COUNT(pmc.id) AS total_matches,
     COUNT(DISTINCT rsc.customer_id) AS customers_screened
   FROM rescreening_cycles rc
   LEFT JOIN rescreening_candidates rsc ON rsc.cycle_id = rc.id
   LEFT JOIN pep_match_candidates pmc ON pmc.rescreening_candidate_id = rsc.id
   WHERE rc.id = {{ $('Create Rescreening Cycle').first().json.id }}
   GROUP BY rc.id, rc.cycle_type, rc.trigger_reason;
   ```
6. Rename to **`Get Match Count`**

---

---

### Node 15b: Send Email — Re-screening Summary

Sends a summary of the completed screening cycle to the compliance mailbox.

1. Click the **+** on the right side of **Get Match Count**
2. Add a **Send Email** node
3. **Credential:** Select existing SMTP credential (or create per Part 0.4)
4. Set:
   - **From Email:** `shazanali3210@gmail.com`
   - **To Email:** `shazanali3210@gmail.com`
   - **Subject:** `[UC3 Batch Summary] PEP Re-screening Cycle Completed — ID: {{ $json.cycle_id }}` *(Expression mode)*
   - Click **Add Option** → **HTML** → Toggle **ON**
   - **HTML Body:** *(Fixed mode, paste directly)*
     ```html
     <html>
     <head>
       <style>
         body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; background: #f4f6f9; margin: 0; padding: 40px; }
         .card { background: #fff; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); max-width: 600px; margin: 0 auto; overflow: hidden; border: 1px solid #e1e4e8; }
         .header { background: linear-gradient(135deg, #2c3e50 0%, #3498db 100%); color: #fff; padding: 30px; text-align: center; }
         .header h1 { margin: 0; font-size: 22px; font-weight: 600; }
         .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; }
         .content { padding: 30px; }
         .badge { display: inline-block; padding: 6px 12px; font-size: 12px; font-weight: 700; border-radius: 20px; text-transform: uppercase; margin-bottom: 20px; background: #e8f4fd; color: #1d8cf8; }
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
           <h1>📊 Re-screening Cycle Completed</h1>
           <p>UC3 — PEP Lifecycle Monitoring</p>
         </div>
         <div class="content">
           <span class="badge">BATCH RUN STATUS: COMPLETE</span>
           <div class="section-title">Execution Details</div>
           <table>
             <tr><td>Cycle ID</td><td>{{$json.cycle_id}}</td></tr>
             <tr><td>Cycle Type</td><td>{{$json.cycle_type}}</td></tr>
             <tr><td>Trigger Reason</td><td>{{$json.trigger_reason}}</td></tr>
           </table>
           <div class="section-title">Screening Metrics</div>
           <table>
             <tr><td>Customers Screened</td><td>{{$json.customers_screened}}</td></tr>
             <tr><td>Fuzzy Match Candidates Found</td><td style="color: #e53935;">{{$json.total_matches}}</td></tr>
           </table>
           <div class="section-title">Next Step</div>
           <p style="font-size:14px;">Please review the match candidates queued in the compliance dashboard to confirm or reject PEP designations.</p>
         </div>
         <div class="footer">
           GenosAI AML Compliance Automation • SBP Regulation 5 Compliance
         </div>
       </div>
     </body>
     </html>
     ```
5. Rename to **`Send Email — Re-screening Summary`**

---

### Node 16: Respond: Screening Complete

Returns the screening results for event-triggered requests. For scheduled triggers, this just logs the result.

1. Click the **+** on the right side of **Send Email — Re-screening Summary**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```javascript
     {{
       {
         "status": "SCREENING_COMPLETE",
         "cycle_id": $('Get Match Count').first().json.cycle_id,
         "cycle_type": $('Get Match Count').first().json.cycle_type,
         "trigger_reason": $('Get Match Count').first().json.trigger_reason,
         "customers_screened": parseInt($('Get Match Count').first().json.customers_screened || 0),
         "total_matches_pending_review": parseInt($('Get Match Count').first().json.total_matches || 0)
       }
     }}
     ```
4. Rename to **`Respond: Screening Complete`**

> **Note:** The Schedule Trigger does not have a webhook to respond to, so this Respond node will only fire for the event-triggered path (via Node 3). For the schedule path, the workflow completes silently. This is fine — the Respond node gracefully does nothing when there's no webhook to respond to.

---

## FLOW B: Analyst Review + Classification + Seniority Gate

---

### Node 17: Webhook Trigger — Analyst Review

This is where the compliance analyst submits their match review decision, relationship classification, and seniority check — all in one request.

1. Click an empty area of the canvas (not connected to Flow A)
2. Add a **Webhook** node
3. Set:
   - **HTTP Method:** `POST`
   - **Path:** `uc3-analyst-review`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook Trigger — Analyst Review`**

**Expected payload:**
```json
{
  "match_id": 1,
  "review_decision": "CONFIRMED_MATCH",
  "reviewer_name": "Analyst Ahmed",
  "reviewer_notes": "Name and DOB match confirmed via independent source",

  "classification_type": "DIRECT_PEP",
  "test_joint_beneficial_ownership": false,
  "test_entity_set_up_for_pep_benefit": false,
  "test_reasonably_known_close_connection": false,
  "test_is_spouse": false,
  "test_is_lineal_descendant_ascendant": false,
  "test_is_sibling": false,

  "role_verified": "Federal Minister for Finance",
  "is_senior_enough": true
}
```

---

### Node 18: Update Match Review Status

Records the analyst's decision on the match.

1. Click the **+** on the right side of **Webhook Trigger — Analyst Review**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE pep_match_candidates
   SET review_status = '{{ $json.body.review_decision }}',
       reviewed_by = '{{ $json.body.reviewer_name }}',
       reviewed_at = now(),
       reviewer_notes = '{{ $json.body.reviewer_notes }}'
   WHERE id = {{ $json.body.match_id }}
   RETURNING id, rescreening_candidate_id, pep_watchlist_source_id,
             match_confidence, review_status;
   ```
6. Rename to **`Update Match Review Status`**

---

### Node 19: IF: Match Confirmed?

Branches on the analyst's decision.

1. Click the **+** on the right side of **Update Match Review Status**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.review_status }}`  *(Expression mode)*
   - **Operator:** `equal`
   - **Value 2:** `CONFIRMED_MATCH`
4. Rename to **`IF: Match Confirmed?`**

---

### Node 20: Audit Log — Match Rejected/Inconclusive

Logs the rejection or inconclusive result.

1. Drag from the **false** output of **IF: Match Confirmed?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO audit_log_uc3 (entity_type, entity_id, action, actor, details)
   VALUES (
     'pep_match_candidates',
     {{ $('Update Match Review Status').first().json.id }},
     '{{ $('Update Match Review Status').first().json.review_status }}',
     '{{ $('Webhook Trigger — Analyst Review').first().json.body.reviewer_name }}',
     '{"notes": "{{ $('Webhook Trigger — Analyst Review').first().json.body.reviewer_notes }}"}'::jsonb
   )
   RETURNING id;
   ```
6. Rename to **`Audit Log — Match Rejected`**

---

### Node 21: Respond: Match Not Confirmed

Returns the rejection/inconclusive result.

1. Click the **+** on the right side of **Audit Log — Match Rejected**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```json
     {
       "status": "{{ $('Update Match Review Status').first().json.review_status }}",
       "match_id": {{ $('Update Match Review Status').first().json.id }},
       "message": "Match review recorded. No PEP designation created."
     }
     ```
4. Rename to **`Respond: Match Not Confirmed`**

---

### Node 22: Insert Relationship Classification

Records the analyst's Def #12 / Def #28 sub-test results.

1. Drag from the **true** output of **IF: Match Confirmed?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO relationship_classification (
     pep_match_candidate_id,
     classification_type,
     test_joint_beneficial_ownership,
     test_entity_set_up_for_pep_benefit,
     test_reasonably_known_close_connection,
     test_is_spouse,
     test_is_lineal_descendant_ascendant,
     test_is_sibling,
     classified_by,
     classified_at
   ) VALUES (
     {{ $('Update Match Review Status').first().json.id }},
     '{{ $('Webhook Trigger — Analyst Review').first().json.body.classification_type }}',
     {{ $('Webhook Trigger — Analyst Review').first().json.body.test_joint_beneficial_ownership || false }},
     {{ $('Webhook Trigger — Analyst Review').first().json.body.test_entity_set_up_for_pep_benefit || false }},
     {{ $('Webhook Trigger — Analyst Review').first().json.body.test_reasonably_known_close_connection || false }},
     {{ $('Webhook Trigger — Analyst Review').first().json.body.test_is_spouse || false }},
     {{ $('Webhook Trigger — Analyst Review').first().json.body.test_is_lineal_descendant_ascendant || false }},
     {{ $('Webhook Trigger — Analyst Review').first().json.body.test_is_sibling || false }},
     '{{ $('Webhook Trigger — Analyst Review').first().json.body.reviewer_name }}',
     now()
   )
   RETURNING id, classification_type;
   ```
6. Rename to **`Insert Relationship Classification`**

---

### Node 23: Get Customer Role

Fetches the person_role of the candidate to determine if the relationship test applies.

1. Click the **+** on the right side of **Insert Relationship Classification**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT
     rc.person_role,
     rc.customer_id,
     c.full_name
   FROM rescreening_candidates rc
   JOIN customers c ON rc.customer_id = c.id
   WHERE rc.id = {{ $('Update Match Review Status').first().json.rescreening_candidate_id }};
   ```
6. Rename to **`Get Customer Role`**

---

### Node 24: IF: Valid Relationship?

For non-primary persons (BOs, directors, etc.), at least one Def #12 or Def #28 sub-test must be TRUE to proceed. For DIRECT_PEP classification, this gate always passes.

1. Click the **+** on the right side of **Get Customer Role**
2. Add a **Code** node (JavaScript)
3. Paste:
   ```javascript
   const webhook = $('Webhook Trigger — Analyst Review').first().json.body;
   const classification = webhook.classification_type;
   const personRole = $('Get Customer Role').first().json.person_role;

   let isValid = false;

   if (classification === 'DIRECT_PEP') {
     // Direct PEP always qualifies
     isValid = true;
   } else if (classification === 'CLOSE_ASSOCIATE') {
     // At least one Def #12 sub-test must be true
     isValid = webhook.test_joint_beneficial_ownership ||
               webhook.test_entity_set_up_for_pep_benefit ||
               webhook.test_reasonably_known_close_connection;
   } else if (classification === 'FAMILY_MEMBER') {
     // At least one Def #28 sub-test must be true
     isValid = webhook.test_is_spouse ||
               webhook.test_is_lineal_descendant_ascendant ||
               webhook.test_is_sibling;
   }

   return [{
     json: {
       is_valid_relationship: isValid,
       classification_type: classification,
       person_role: personRole,
       customer_id: $('Get Customer Role').first().json.customer_id,
       full_name: $('Get Customer Role').first().json.full_name
     }
   }];
   ```
4. Rename to **`Check Relationship Validity`**

---

### Node 25: IF: Relationship Valid?

1. Click the **+** on the right side of **Check Relationship Validity**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.is_valid_relationship }}`  *(Expression mode)*
   - **Operator:** `Is True`
4. Rename to **`IF: Relationship Valid?`**

---

### Node 26: Respond: Not Qualifying Relationship

1. Drag from the **false** output of **IF: Relationship Valid?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```json
     {
       "status": "CLOSED_NOT_QUALIFYING",
       "match_id": {{ $('Update Match Review Status').first().json.id }},
       "classification_type": "{{ $json.classification_type }}",
       "message": "Relationship does not meet Def #12 or Def #28 qualifying criteria. No PEP designation created."
     }
     ```
   - **Response Code:** `200`
4. Rename to **`Respond: Not Qualifying Relationship`**

---

### Node 27: Insert Seniority Check

Records the seniority/exclusion gate result (Def #52(d)).

1. Drag from the **true** output of **IF: Relationship Valid?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO seniority_exclusion_check (
     pep_match_candidate_id,
     role_verified,
     is_senior_enough,
     checked_by,
     checked_at
   ) VALUES (
     {{ $('Update Match Review Status').first().json.id }},
     '{{ $('Webhook Trigger — Analyst Review').first().json.body.role_verified }}',
     {{ $('Webhook Trigger — Analyst Review').first().json.body.is_senior_enough }},
     '{{ $('Webhook Trigger — Analyst Review').first().json.body.reviewer_name }}',
     now()
   )
   RETURNING id, is_senior_enough;
   ```
6. Rename to **`Insert Seniority Check`**

---

### Node 28: IF: Senior Enough?

1. Click the **+** on the right side of **Insert Seniority Check**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.is_senior_enough }}`  *(Expression mode)*
   - **Operator:** `Is True`
4. Rename to **`IF: Senior Enough?`**

---

### Node 29: Audit Log — Excluded Junior/Middle

1. Drag from the **false** output of **IF: Senior Enough?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO audit_log_uc3 (entity_type, entity_id, action, actor, details)
   VALUES (
     'pep_match_candidates',
     {{ $('Update Match Review Status').first().json.id }},
     'EXCLUDED_JUNIOR_MIDDLE_DEF52D',
     '{{ $('Webhook Trigger — Analyst Review').first().json.body.reviewer_name }}',
     '{"role_verified": "{{ $('Webhook Trigger — Analyst Review').first().json.body.role_verified }}"}'::jsonb
   )
   RETURNING id;
   ```
6. Rename to **`Audit Log — Excluded Junior/Middle`**

---

### Node 30: Respond: Excluded Junior/Middle

1. Click the **+** on the right side of **Audit Log — Excluded Junior/Middle**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```json
     {
       "status": "EXCLUDED_DEF52D",
       "match_id": {{ $('Update Match Review Status').first().json.id }},
       "role_verified": "{{ $('Webhook Trigger — Analyst Review').first().json.body.role_verified }}",
       "message": "Person excluded from PEP classification per Definition 52(d) — junior/middle ranking."
     }
     ```
4. Rename to **`Respond: Excluded Junior/Middle`**

---

### Node 31: Get Watchlist Details

Fetches the PEP watchlist entry details for the formal designation.

1. Drag from the **true** output of **IF: Senior Enough?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT
     pw.pep_category,
     pw.position_title,
     pw.full_name AS watchlist_name
   FROM pep_watchlist_source pw
   WHERE pw.id = {{ $('Update Match Review Status').first().json.pep_watchlist_source_id }};
   ```
6. Rename to **`Get Watchlist Details`**

---

### Node 32: Insert PEP Designation

Creates the formal PEP designation record (Phase 6).

1. Click the **+** on the right side of **Get Watchlist Details**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO pep_designations (
     customer_id,
     pep_match_candidate_id,
     designation_type,
     pep_category,
     is_active
   ) VALUES (
     {{ $('Check Relationship Validity').first().json.customer_id }},
     {{ $('Update Match Review Status').first().json.id }},
     '{{ $('Webhook Trigger — Analyst Review').first().json.body.classification_type }}',
     '{{ $json.pep_category }}',
     TRUE
   )
   RETURNING id, customer_id, designation_type, pep_category, designated_at;
   ```
6. Rename to **`Insert PEP Designation`**

---

### Node 33: Send Email — PEP Designated

Sends a compliance alert email when a PEP designation is formally created.

1. Click the **+** on the right side of **Insert PEP Designation**
2. Add a **Send Email** node
3. **Credential:** Select existing SMTP credential (or create per Part 0.4)
4. Set:
   - **From Email:** `shazanali3210@gmail.com`
   - **To Email:** `shazanali3210@gmail.com`
   - **Subject:** *(Expression mode)*
     ```
     [UC3 PEP Alert] NEW PEP Designation — {{ $('Check Relationship Validity').first().json.full_name }}
     ```
   - Click **Add Option** → **HTML** → Toggle **ON**
   - **HTML Body:** *(Expression mode — use the Expression tab)*

     Switch to **Fixed** mode first, then paste this HTML directly:

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
           <h1>⚠️ PEP Designation Alert</h1>
           <p>UC3 — PEP Lifecycle Monitoring</p>
         </div>
         <div class="content">
           <span class="badge">ACTION REQUIRED: SOURCE OF WEALTH</span>
           <div class="section-title">Person Details</div>
           <table>
             <tr><td>Customer Name</td><td>{{$('Check Relationship Validity').first().json.full_name}}</td></tr>
             <tr><td>Customer ID</td><td>{{$('Check Relationship Validity').first().json.customer_id}}</td></tr>
             <tr><td>Person Role</td><td>{{$('Check Relationship Validity').first().json.person_role}}</td></tr>
           </table>
           <div class="section-title">PEP Designation</div>
           <table>
             <tr><td>Designation ID</td><td>{{$json.id}}</td></tr>
             <tr><td>Designation Type</td><td>{{$json.designation_type}}</td></tr>
             <tr><td>PEP Category</td><td>{{$json.pep_category}}</td></tr>
             <tr><td>Designated At</td><td>{{$json.designated_at}}</td></tr>
           </table>
           <div class="section-title">Next Step</div>
           <p style="font-size:14px;">Source-of-wealth / source-of-funds evidence must be collected and reconciled (Reg 5 §1(c)) before senior management approval can be requested.</p>
         </div>
         <div class="footer">
           GenosAI AML Compliance Automation • Regulation 5 — Politically Exposed Persons
         </div>
       </div>
     </body>
     </html>
     ```

5. Rename to **`Send Email — PEP Designated`**

---

### Node 34: Respond: PEP Designated

1. Click the **+** on the right side of **Send Email — PEP Designated**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```json
     {
       "status": "PEP_DESIGNATED",
       "designation_id": {{ $('Insert PEP Designation').first().json.id }},
       "customer_id": {{ $('Insert PEP Designation').first().json.customer_id }},
       "designation_type": "{{ $('Insert PEP Designation').first().json.designation_type }}",
       "pep_category": "{{ $('Insert PEP Designation').first().json.pep_category }}",
       "message": "Formal PEP designation created. Next: Submit source-of-wealth evidence via POST /webhook/uc3-sow-approval."
     }
     ```
4. Rename to **`Respond: PEP Designated`**

---

## FLOW C: Source of Wealth + Senior Management Approval

---

### Node 35: Webhook Trigger — SOW & Approval

This endpoint handles both evidence submission and senior management approval.

1. Click an empty area of the canvas (not connected to Flow A or B)
2. Add a **Webhook** node
3. Set:
   - **HTTP Method:** `POST`
   - **Path:** `uc3-sow-approval`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook Trigger — SOW & Approval`**

**Expected payload for evidence submission:**
```json
{
  "action": "submit_evidence",
  "designation_id": 1,
  "evidence_type": "BANK_STATEMENT",
  "file_ref": "/uploads/bank_statement_2026.pdf",
  "declared_source": "Salary from Ministry of Finance",
  "reconciled": true,
  "reconciliation_notes": "Salary matches declared income bracket",
  "reviewer_name": "Analyst Ahmed"
}
```

**Expected payload for senior management approval:**
```json
{
  "action": "approve",
  "designation_id": 1,
  "decision": "CONTINUE_RELATIONSHIP",
  "approver_name": "Director Compliance",
  "approver_role": "Chief Compliance Officer",
  "comments": "Relationship acceptable given verified source of wealth"
}
```

---

### Node 36: IF: Submit Evidence or Approve?

1. Click the **+** on the right side of **Webhook Trigger — SOW & Approval**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.body.action }}`  *(Expression mode)*
   - **Operator:** `equal`
   - **Value 2:** `submit_evidence`
4. Rename to **`IF: Submit Evidence or Approve?`**

---

### Node 37: Insert SOW Evidence

Inserts source-of-wealth evidence (Phase 7).

1. Drag from the **true** output of **IF: Submit Evidence or Approve?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO source_of_wealth_evidence (
     pep_designation_id,
     evidence_type,
     file_ref,
     declared_source,
     reconciled,
     reconciliation_notes,
     reviewed_by,
     reviewed_at
   ) VALUES (
     {{ $('Webhook Trigger — SOW & Approval').first().json.body.designation_id }},
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.evidence_type }}',
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.file_ref }}',
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.declared_source }}',
     {{ $('Webhook Trigger — SOW & Approval').first().json.body.reconciled }},
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.reconciliation_notes }}',
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.reviewer_name }}',
     now()
   )
   RETURNING id, evidence_type, reconciled;
   ```
6. Rename to **`Insert SOW Evidence`**

---

### Node 38: Respond: Evidence Submitted

1. Click the **+** on the right side of **Insert SOW Evidence**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```json
     {
       "status": "EVIDENCE_SUBMITTED",
       "evidence_id": {{ $json.id }},
       "evidence_type": "{{ $json.evidence_type }}",
       "reconciled": {{ $json.reconciled }},
       "message": "Source-of-wealth evidence recorded. When all evidence is reconciled, submit approval request with action: 'approve'."
     }
     ```
4. Rename to **`Respond: Evidence Submitted`**

---

### Node 39: Check All Evidence Reconciled

Checks if ALL evidence for this designation has been reconciled (Phase 7 gate).

1. Drag from the **false** output of **IF: Submit Evidence or Approve?** (this is the "approve" path)
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT
     COUNT(*) AS total_evidence,
     COUNT(*) FILTER (WHERE reconciled = TRUE) AS reconciled_count,
     COUNT(*) FILTER (WHERE reconciled = FALSE) AS unreconciled_count,
     CASE
       WHEN COUNT(*) = 0 THEN FALSE
       WHEN COUNT(*) FILTER (WHERE reconciled = FALSE) = 0 THEN TRUE
       ELSE FALSE
     END AS all_reconciled
   FROM source_of_wealth_evidence
   WHERE pep_designation_id = {{ $('Webhook Trigger — SOW & Approval').first().json.body.designation_id }};
   ```
6. Rename to **`Check All Evidence Reconciled`**

---

### Node 40: IF: All Reconciled?

1. Click the **+** on the right side of **Check All Evidence Reconciled**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.all_reconciled }}`  *(Expression mode)*
   - **Operator:** `Is True`
4. Rename to **`IF: All Reconciled?`**

---

### Node 41: Respond: ON HOLD

Evidence is incomplete — case cannot proceed to senior management approval.

1. Drag from the **false** output of **IF: All Reconciled?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```json
     {
       "status": "ON_HOLD",
       "designation_id": {{ $('Webhook Trigger — SOW & Approval').first().json.body.designation_id }},
       "total_evidence": {{ $('Check All Evidence Reconciled').first().json.total_evidence }},
       "unreconciled_count": {{ $('Check All Evidence Reconciled').first().json.unreconciled_count }},
       "message": "Source-of-wealth evidence is not fully reconciled. Case cannot proceed to senior management approval until all evidence is reconciled."
     }
     ```
   - **Response Code:** `422`
4. Rename to **`Respond: ON HOLD`**

---

### Node 42: Insert Senior Mgmt Approval

Records the senior management decision (Phase 8).

1. Drag from the **true** output of **IF: All Reconciled?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO pep_senior_mgmt_approvals (
     pep_designation_id,
     decision,
     approver_name,
     approver_role,
     decision_at,
     comments
   ) VALUES (
     {{ $('Webhook Trigger — SOW & Approval').first().json.body.designation_id }},
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.decision }}',
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.approver_name }}',
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.approver_role }}',
     now(),
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.comments }}'
   )
   RETURNING id, pep_designation_id, decision;
   ```
6. Rename to **`Insert Senior Mgmt Approval`**

---

### Node 43: IF: Continue Relationship?

1. Click the **+** on the right side of **Insert Senior Mgmt Approval**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.decision }}`  *(Expression mode)*
   - **Operator:** `equal`
   - **Value 2:** `CONTINUE_RELATIONSHIP`
4. Rename to **`IF: Continue Relationship?`**

---

### Node 44: Send Email — Relationship Exit

Sends notification that senior management has decided to exit the relationship.

1. Drag from the **false** output of **IF: Continue Relationship?**
2. Add a **Send Email** node
3. **Credential:** Select existing SMTP credential
4. Set:
   - **From Email:** `shazanali3210@gmail.com`
   - **To Email:** `shazanali3210@gmail.com`
   - **Subject:** *(Expression mode)*
     ```
     [UC3 PEP Alert] RELATIONSHIP EXIT — Designation {{ $('Insert Senior Mgmt Approval').first().json.pep_designation_id }}
     ```
   - Click **Add Option** → **HTML** → Toggle **ON**
   - **HTML Body:** *(Fixed mode, paste directly)*

     ```html
     <html>
     <head>
       <style>
         body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; background: #f4f6f9; margin: 0; padding: 40px; }
         .card { background: #fff; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); max-width: 600px; margin: 0 auto; overflow: hidden; border: 1px solid #e1e4e8; }
         .header { background: linear-gradient(135deg, #c62828 0%, #b71c1c 100%); color: #fff; padding: 30px; text-align: center; }
         .header h1 { margin: 0; font-size: 22px; }
         .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; }
         .content { padding: 30px; }
         .badge { display: inline-block; padding: 6px 12px; font-size: 12px; font-weight: 700; border-radius: 20px; text-transform: uppercase; margin-bottom: 20px; background: #f8d7da; color: #721c24; }
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
           <h1>🚫 Relationship Exit Decision</h1>
           <p>UC3 — PEP Lifecycle Monitoring</p>
         </div>
         <div class="content">
           <span class="badge">EXIT RELATIONSHIP</span>
           <div class="section-title">Approval Details</div>
           <table>
             <tr><td>Designation ID</td><td>{{$('Insert Senior Mgmt Approval').first().json.pep_designation_id}}</td></tr>
             <tr><td>Decision</td><td>{{$('Insert Senior Mgmt Approval').first().json.decision}}</td></tr>
             <tr><td>Approver</td><td>{{$('Webhook Trigger — SOW & Approval').first().json.body.approver_name}}</td></tr>
             <tr><td>Role</td><td>{{$('Webhook Trigger — SOW & Approval').first().json.body.approver_role}}</td></tr>
           </table>
           <div class="section-title">Next Step</div>
           <p style="font-size:14px;">Initiate account closure / off-boarding process per exit policy.</p>
         </div>
         <div class="footer">
           GenosAI AML Compliance Automation • Regulation 5 §1(b) — Senior Management Approval
         </div>
       </div>
     </body>
     </html>
     ```

5. Rename to **`Send Email — Relationship Exit`**

---

### Node 45: Respond: Relationship Exit

1. Click the **+** on the right side of **Send Email — Relationship Exit**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```json
     {
       "status": "EXIT_RELATIONSHIP",
       "designation_id": {{ $('Insert Senior Mgmt Approval').first().json.pep_designation_id }},
       "message": "Senior management has decided to exit the relationship. Initiate off-boarding process."
     }
     ```
4. Rename to **`Respond: Relationship Exit`**

---

### Node 46: Get Designation Details

Fetches full designation details for downstream processing.

1. Drag from the **true** output of **IF: Continue Relationship?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   SELECT
     pd.id AS designation_id,
     pd.customer_id,
     pd.designation_type,
     pd.pep_category,
     pd.designated_at,
     c.full_name
   FROM pep_designations pd
   JOIN customers c ON pd.customer_id = c.id
   WHERE pd.id = {{ $('Insert Senior Mgmt Approval').first().json.pep_designation_id }};
   ```
6. Rename to **`Get Designation Details`**

---

### Node 47: Insert Enhanced Monitoring Flag

Creates the enhanced monitoring flag (Phase 9 — Reg 5 §1(d)).

1. Click the **+** on the right side of **Get Designation Details**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO enhanced_monitoring_flags (
     customer_id,
     pep_designation_id,
     monitoring_tier,
     set_at,
     set_by
   ) VALUES (
     {{ $json.customer_id }},
     {{ $json.designation_id }},
     'ENHANCED',
     now(),
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.approver_name }}'
   )
   RETURNING id, customer_id, monitoring_tier;
   ```
6. Rename to **`Insert Enhanced Monitoring Flag`**

---

### Node 48: Insert Recertification Schedule

Computes and inserts the next recertification date (Phase 10).

1. Click the **+** on the right side of **Insert Enhanced Monitoring Flag**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO recertification_schedule (
     pep_designation_id,
     risk_tier,
     next_recertification_date,
     last_recertified_at,
     last_recertified_by
   ) VALUES (
     {{ $('Get Designation Details').first().json.designation_id }},
     '{{ $('Get Designation Details').first().json.pep_category }}',
     CASE
       WHEN '{{ $('Get Designation Details').first().json.pep_category }}' = 'FOREIGN'
         THEN (now() + INTERVAL '6 months')::date
       ELSE (now() + INTERVAL '12 months')::date
     END,
     now(),
     '{{ $('Webhook Trigger — SOW & Approval').first().json.body.approver_name }}'
   )
   RETURNING id, risk_tier, next_recertification_date;
   ```
6. Rename to **`Insert Recertification Schedule`**

---

### Node 49: Send Email — Lifecycle Complete

Sends a success email when the full PEP lifecycle is completed.

1. Click the **+** on the right side of **Insert Recertification Schedule**
2. Add a **Send Email** node
3. **Credential:** Select existing SMTP credential
4. Set:
   - **From Email:** `shazanali3210@gmail.com`
   - **To Email:** `shazanali3210@gmail.com`
   - **Subject:** *(Expression mode)*
     ```
     [UC3 Complete] PEP Lifecycle Finalized — {{ $('Get Designation Details').first().json.full_name }}
     ```
   - Click **Add Option** → **HTML** → Toggle **ON**
   - **HTML Body:** *(Fixed mode, paste directly)*

     ```html
     <html>
     <head>
       <style>
         body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; background: #f4f6f9; margin: 0; padding: 40px; }
         .card { background: #fff; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); max-width: 600px; margin: 0 auto; overflow: hidden; border: 1px solid #e1e4e8; }
         .header { background: linear-gradient(135deg, #1e7e34 0%, #28a745 100%); color: #fff; padding: 30px; text-align: center; }
         .header h1 { margin: 0; font-size: 22px; font-weight: 600; }
         .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; }
         .content { padding: 30px; }
         .badge { display: inline-block; padding: 6px 12px; font-size: 12px; font-weight: 700; border-radius: 20px; text-transform: uppercase; margin-bottom: 20px; background: #e2f9e1; color: #1e7e34; }
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
           <h1>✅ PEP Lifecycle Complete</h1>
           <p>UC3 — PEP Lifecycle Monitoring</p>
         </div>
         <div class="content">
           <span class="badge">LIFECYCLE COMPLETE</span>
           <div class="section-title">PEP Designation</div>
           <table>
             <tr><td>Customer Name</td><td>{{$('Get Designation Details').first().json.full_name}}</td></tr>
             <tr><td>Designation ID</td><td>{{$('Get Designation Details').first().json.designation_id}}</td></tr>
             <tr><td>Designation Type</td><td>{{$('Get Designation Details').first().json.designation_type}}</td></tr>
             <tr><td>PEP Category</td><td>{{$('Get Designation Details').first().json.pep_category}}</td></tr>
           </table>
           <div class="section-title">Monitoring & Recertification</div>
           <table>
             <tr><td>Monitoring Tier</td><td>{{$('Insert Enhanced Monitoring Flag').first().json.monitoring_tier}}</td></tr>
             <tr><td>Recertification Tier</td><td>{{$json.risk_tier}}</td></tr>
             <tr><td>Next Recertification</td><td>{{$json.next_recertification_date}}</td></tr>
           </table>
           <div class="section-title">Senior Management Decision</div>
           <table>
             <tr><td>Decision</td><td>CONTINUE RELATIONSHIP</td></tr>
             <tr><td>Approver</td><td>{{$('Webhook Trigger — SOW & Approval').first().json.body.approver_name}}</td></tr>
             <tr><td>Role</td><td>{{$('Webhook Trigger — SOW & Approval').first().json.body.approver_role}}</td></tr>
           </table>
         </div>
         <div class="footer">
           GenosAI AML Compliance Automation • Regulation 5 — PEP Lifecycle Complete
         </div>
       </div>
     </body>
     </html>
     ```

5. Rename to **`Send Email — Lifecycle Complete`**

---

### Node 50: Respond: Lifecycle Complete

1. Click the **+** on the right side of **Send Email — Lifecycle Complete**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```json
     {
       "status": "PEP_LIFECYCLE_COMPLETE",
       "designation_id": {{ $('Get Designation Details').first().json.designation_id }},
       "customer_name": "{{ $('Get Designation Details').first().json.full_name }}",
       "designation_type": "{{ $('Get Designation Details').first().json.designation_type }}",
       "pep_category": "{{ $('Get Designation Details').first().json.pep_category }}",
       "monitoring_tier": "{{ $('Insert Enhanced Monitoring Flag').first().json.monitoring_tier }}",
       "next_recertification": "{{ $('Insert Recertification Schedule').first().json.next_recertification_date }}",
       "message": "PEP lifecycle complete. Enhanced monitoring active. Recertification scheduled."
     }
     ```
4. Rename to **`Respond: Lifecycle Complete`**

---

## FLOW D: Monitoring Intensity Step-Down

---

### Node 51: Webhook Trigger — Step-Down

This is a separate sub-flow for explicitly reducing monitoring intensity on a PEP, without removing the designation.

1. Click an empty area of the canvas
2. Add a **Webhook** node
3. Set:
   - **HTTP Method:** `POST`
   - **Path:** `uc3-stepdown`
   - **Response Mode:** `Response to Webhook node`
4. Rename to **`Webhook Trigger — Step-Down`**

**Expected payload:**
```json
{
  "designation_id": 1,
  "reason": "Left public office, 18-month internal observation period completed",
  "approved_by": "Director Compliance"
}
```

---

### Node 52: Validate Designation Active

Verifies the PEP designation exists and is currently active.

1. Click the **+** on the right side of **Webhook Trigger — Step-Down**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
    SELECT
      pd.id,
      pd.is_active,
      pd.designation_type,
      pd.pep_category,
      c.full_name AS customer_name,
      emf.monitoring_tier AS current_tier
    FROM pep_designations pd
    JOIN customers c ON pd.customer_id = c.id
    LEFT JOIN enhanced_monitoring_flags emf ON emf.pep_designation_id = pd.id
    WHERE pd.id = {{ $json.body.designation_id }};
   ```
6. Rename to **`Validate Designation Active`**

---

### Node 53: IF: Designation Active?

1. Click the **+** on the right side of **Validate Designation Active**
2. Add an **IF** node
3. Set condition:
   - **Value 1:** `{{ $json.is_active }}`  *(Expression mode)*
   - **Operator:** `Is True`
4. Rename to **`IF: Designation Active?`**

---

### Node 54: Respond: Designation Not Active

1. Drag from the **false** output of **IF: Designation Active?**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```json
     {
       "status": "ERROR",
       "message": "PEP designation is not active or does not exist. Step-down cannot be applied."
     }
     ```
   - **Response Code:** `400`
4. Rename to **`Respond: Designation Not Active`**

---

### Node 55: Insert Monitoring Intensity Log

Logs the step-down event with full audit trail.

1. Drag from the **true** output of **IF: Designation Active?**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   INSERT INTO monitoring_intensity_log (
     pep_designation_id,
     previous_tier,
     new_tier,
     reason,
     approved_by,
     approved_at
   ) VALUES (
     {{ $('Webhook Trigger — Step-Down').first().json.body.designation_id }},
     '{{ $('Validate Designation Active').first().json.current_tier }}',
     'STANDARD',
     '{{ $('Webhook Trigger — Step-Down').first().json.body.reason }}',
     '{{ $('Webhook Trigger — Step-Down').first().json.body.approved_by }}',
     now()
   )
   RETURNING id, previous_tier, new_tier;
   ```
6. Rename to **`Insert Monitoring Intensity Log`**

---

### Node 56: Update Monitoring Tier

Updates the enhanced monitoring flag to STANDARD — **without touching the PEP designation**.

1. Click the **+** on the right side of **Insert Monitoring Intensity Log**
2. Add a **Postgres** node
3. **Credential:** `AML Postgres`
4. **Operation:** `Execute Query`
5. **Query:**
   ```sql
   UPDATE enhanced_monitoring_flags
   SET monitoring_tier = 'STANDARD',
       set_at = now(),
       set_by = '{{ $('Webhook Trigger — Step-Down').first().json.body.approved_by }}'
   WHERE pep_designation_id = {{ $('Webhook Trigger — Step-Down').first().json.body.designation_id }}
   RETURNING id, customer_id, monitoring_tier;
   ```
6. Rename to **`Update Monitoring Tier`**

---

---

### Node 56b: Send Email — Monitoring Step-Down

Sends a compliance notification email when a PEP is stepped down to Standard monitoring.

1. Click the **+** on the right side of **Update Monitoring Tier**
2. Add a **Send Email** node
3. **Credential:** Select existing SMTP credential
4. Set:
   - **From Email:** `shazanali3210@gmail.com`
   - **To Email:** `shazanali3210@gmail.com`
   - **Subject:** `[UC3 Step-Down] PEP Monitoring Intensity Reduced — {{ $('Validate Designation Active').first().json.customer_name }}` *(Expression mode)*
   - Click **Add Option** → **HTML** → Toggle **ON**
   - **HTML Body:** *(Fixed mode, paste directly)*
     ```html
     <html>
     <head>
       <style>
         body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; background: #f4f6f9; margin: 0; padding: 40px; }
         .card { background: #fff; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); max-width: 600px; margin: 0 auto; overflow: hidden; border: 1px solid #e1e4e8; }
         .header { background: linear-gradient(135deg, #f39c12 0%, #d35400 100%); color: #fff; padding: 30px; text-align: center; }
         .header h1 { margin: 0; font-size: 22px; font-weight: 600; }
         .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; }
         .content { padding: 30px; }
         .badge { display: inline-block; padding: 6px 12px; font-size: 12px; font-weight: 700; border-radius: 20px; text-transform: uppercase; margin-bottom: 20px; background: #fef5e7; color: #e67e22; }
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
           <h1>📉 Monitoring Intensity Step-Down</h1>
           <p>UC3 — PEP Lifecycle Monitoring</p>
         </div>
         <div class="content">
           <span class="badge">STATUS: STEP-DOWN COMPLETED</span>
           <div class="section-title">Customer Details</div>
           <table>
             <tr><td>Customer Name</td><td>{{$('Validate Designation Active').first().json.customer_name}}</td></tr>
             <tr><td>Designation ID</td><td>{{$('Webhook Trigger — Step-Down').first().json.body.designation_id}}</td></tr>
             <tr><td>PEP Category</td><td>{{$('Validate Designation Active').first().json.pep_category}}</td></tr>
           </table>
           <div class="section-title">Monitoring Transition</div>
           <table>
             <tr><td>Previous Tier</td><td>{{$('Insert Monitoring Intensity Log').first().json.previous_tier}}</td></tr>
             <tr><td>New Tier</td><td style="color: #27ae60;">STANDARD</td></tr>
             <tr><td>Approved By</td><td>{{$('Webhook Trigger — Step-Down').first().json.body.approved_by}}</td></tr>
           </table>
           <div class="section-title">Step-Down Basis</div>
           <p style="font-size:14px;">{{$('Webhook Trigger — Step-Down').first().json.body.reason}}</p>
           <p style="font-size:13px; color: #e74c3c;"><strong>Note:</strong> Per Definition 52 ("is or has been"), the PEP designation remains active on file for audit integrity.</p>
         </div>
         <div class="footer">
           GenosAI AML Compliance Automation • SBP Regulation 5 Compliance
         </div>
       </div>
     </body>
     </html>
     ```
5. Rename to **`Send Email — Monitoring Step-Down`**

---

### Node 57: Respond: Step-Down Complete

1. Click the **+** on the right side of **Send Email — Monitoring Step-Down**
2. Add a **Respond to Webhook** node
3. Set:
   - **Respond With:** `JSON`
   - **Response Body:** *(Expression mode)*
     ```json
     {
       "status": "STEP_DOWN_COMPLETE",
       "designation_id": {{ $('Webhook Trigger — Step-Down').first().json.body.designation_id }},
       "previous_tier": "{{ $('Insert Monitoring Intensity Log').first().json.previous_tier }}",
       "new_tier": "{{ $('Insert Monitoring Intensity Log').first().json.new_tier }}",
       "designation_still_active": true,
       "message": "Monitoring intensity reduced to STANDARD. PEP designation remains active and on file (Def #52 'is or has been')."
     }
     ```
4. Rename to **`Respond: Step-Down Complete`**

---

## Part 3: Pre-Flight Checks

Before testing, make sure:

### 3.1 Enable pg_trgm Extension
Run this command once to enable fuzzy text matching:
```bash
docker exec -i aml-postgres psql -U aml_user -d aml_local -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
```

### 3.2 Activate the Workflow
1. In the n8n canvas, click the **"Publish"** button in the top-right corner. This deploys the workflow and activates your webhook endpoints.
2. Once published, you should see the status change (and the button will let you "Unpublish" to edit).

### 3.3 Test Webhook URLs
Your 4 endpoints will be:
- `http://localhost:5678/webhook/uc3-rescreen-event` (Flow A — event trigger)
- `http://localhost:5678/webhook/uc3-analyst-review` (Flow B — analyst review)
- `http://localhost:5678/webhook/uc3-sow-approval` (Flow C — SOW + approval)
- `http://localhost:5678/webhook/uc3-stepdown` (Flow D — step-down)

> **Note:** The Schedule Trigger (Node 1) fires automatically on the 1st of each month. For testing, you can click **"Test workflow"** in n8n to trigger it manually.

---

## Part 4: Complete Node Summary

| Node # | Name | Type | Flow |
|---|---|---|---|
| 1 | Schedule Trigger (Monthly) | Schedule Trigger | A |
| 2 | Set Cycle Type — Scheduled | Set | A |
| 3 | Webhook Trigger — Event Rescreen | Webhook | A |
| 4 | Set Cycle Type — Event | Set | A |
| 5 | Merge Triggers | Merge | A |
| 6 | Create Rescreening Cycle | Postgres | A |
| 7 | Compile Candidates | Postgres | A |
| 8 | Loop Over Candidates | Loop Over Items | A |
| 9 | Insert Rescreening Candidate | Postgres | A |
| 10 | Fuzzy Name Screen | Postgres | A |
| 11 | IF: Any Matches? | IF | A |
| 12 | Insert PEP Match Candidates | Postgres | A |
| 13 | *(wire back to Loop)* | — | A |
| 14 | Complete Cycle | Postgres | A |
| 15 | Get Match Count | Postgres | A |
| 16 | Respond: Screening Complete | Respond to Webhook | A |
| 17 | Webhook Trigger — Analyst Review | Webhook | B |
| 18 | Update Match Review Status | Postgres | B |
| 19 | IF: Match Confirmed? | IF | B |
| 20 | Audit Log — Match Rejected | Postgres | B |
| 21 | Respond: Match Not Confirmed | Respond to Webhook | B |
| 22 | Insert Relationship Classification | Postgres | B |
| 23 | Get Customer Role | Postgres | B |
| 24 | Check Relationship Validity | Code | B |
| 25 | IF: Relationship Valid? | IF | B |
| 26 | Respond: Not Qualifying Relationship | Respond to Webhook | B |
| 27 | Insert Seniority Check | Postgres | B |
| 28 | IF: Senior Enough? | IF | B |
| 29 | Audit Log — Excluded Junior/Middle | Postgres | B |
| 30 | Respond: Excluded Junior/Middle | Respond to Webhook | B |
| 31 | Get Watchlist Details | Postgres | B |
| 32 | Insert PEP Designation | Postgres | B |
| 33 | Send Email — PEP Designated | Send Email | B |
| 34 | Respond: PEP Designated | Respond to Webhook | B |
| 35 | Webhook Trigger — SOW & Approval | Webhook | C |
| 36 | IF: Submit Evidence or Approve? | IF | C |
| 37 | Insert SOW Evidence | Postgres | C |
| 38 | Respond: Evidence Submitted | Respond to Webhook | C |
| 39 | Check All Evidence Reconciled | Postgres | C |
| 40 | IF: All Reconciled? | IF | C |
| 41 | Respond: ON HOLD | Respond to Webhook | C |
| 42 | Insert Senior Mgmt Approval | Postgres | C |
| 43 | IF: Continue Relationship? | IF | C |
| 44 | Send Email — Relationship Exit | Send Email | C |
| 45 | Respond: Relationship Exit | Respond to Webhook | C |
| 46 | Get Designation Details | Postgres | C |
| 47 | Insert Enhanced Monitoring Flag | Postgres | C |
| 48 | Insert Recertification Schedule | Postgres | C |
| 49 | Send Email — Lifecycle Complete | Send Email | C |
| 50 | Respond: Lifecycle Complete | Respond to Webhook | C |
| 51 | Webhook Trigger — Step-Down | Webhook | D |
| 52 | Validate Designation Active | Postgres | D |
| 53 | IF: Designation Active? | IF | D |
| 54 | Respond: Designation Not Active | Respond to Webhook | D |
| 55 | Insert Monitoring Intensity Log | Postgres | D |
| 56 | Update Monitoring Tier | Postgres | D |
| 57 | Respond: Step-Down Complete | Respond to Webhook | D |

**Total: 57 nodes across 4 flows**
