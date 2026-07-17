#!/bin/bash

# =============================================================================
# UC3: PEP Lifecycle Monitoring — Automated Test Runner
# GenosAI AML/CFT/CPF Compliance Automation POC v2
# =============================================================================
# Usage: ./test_pep_lifecycle.sh payloads/01_foreign_pep_full_path.json
# =============================================================================

PAYLOAD=$1
JQ="/snap/bin/jq"

if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
  echo "Usage: ./test_pep_lifecycle.sh payloads/<file.json>"
  exit 1
fi

echo "============================================================================="
echo "  PEP LIFECYCLE TEST RUNNER"
echo "  Scenario: $($JQ -r .scenario "$PAYLOAD")"
echo "============================================================================="

# -----------------------------------------------------------------------------
# STEP 0: Set up test customer in Postgres database
# -----------------------------------------------------------------------------
echo "=== Step 0: Preparing Test Customer in Database ==="
CASE_REF=$($JQ -r .customer.case_ref "$PAYLOAD")
CUSTOMER_TYPE=$($JQ -r .customer.customer_type_code "$PAYLOAD")
FULL_NAME=$($JQ -r .customer.full_name "$PAYLOAD")
DOB=$($JQ -r .customer.date_of_birth "$PAYLOAD")
ROLE=$($JQ -r .customer.role "$PAYLOAD")

# Check if case exists
CASE_EXISTS=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT 1 FROM cdd_cases WHERE case_ref = '$CASE_REF';")

if [ -z "$CASE_EXISTS" ]; then
  echo "Inserting test CDD case: $CASE_REF..."
  docker exec -i aml-postgres psql -U aml_user -d aml_local -c \
    "INSERT INTO cdd_cases (case_ref, re_type_id, customer_type_id, current_phase, status) \
     VALUES ('$CASE_REF', (SELECT id FROM re_types WHERE code = 'BANK'), (SELECT id FROM customer_types WHERE code = '$CUSTOMER_TYPE'), 'COMPLETE', 'APPROVED');" > /dev/null
fi

# Check if customer exists
CUSTOMER_ID=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT id FROM customers WHERE full_name = '$FULL_NAME' AND case_id = (SELECT id FROM cdd_cases WHERE case_ref = '$CASE_REF') LIMIT 1;")

if [ -z "$CUSTOMER_ID" ]; then
  echo "Inserting test customer: $FULL_NAME..."
  docker exec -i aml-postgres psql -U aml_user -d aml_local -c \
    "INSERT INTO customers (case_id, role, full_name, date_of_birth, nationality_status) \
     VALUES ((SELECT id FROM cdd_cases WHERE case_ref = '$CASE_REF'), '$ROLE', '$FULL_NAME', '$DOB', 'RESIDENT');" > /dev/null
     
  CUSTOMER_ID=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
    "SELECT id FROM customers WHERE full_name = '$FULL_NAME' AND case_id = (SELECT id FROM cdd_cases WHERE case_ref = '$CASE_REF') LIMIT 1;")
fi

echo "Verified Customer in Database: $FULL_NAME (ID: $CUSTOMER_ID)"

# -----------------------------------------------------------------------------
# FLOW A: Trigger Rescreening Event
# -----------------------------------------------------------------------------
echo ""
echo "=== Flow A: Triggering Event-Based Rescreening ==="
TRIGGER_REASON=$($JQ -r .flow_a.trigger_reason "$PAYLOAD")

SCREEN_PAYLOAD=$($JQ -n \
  --arg reason "$TRIGGER_REASON" \
  --argjson cust_id "$CUSTOMER_ID" \
  '{"trigger_reason": $reason, "customer_id": $cust_id}')

echo "POST http://localhost:5678/webhook/uc3-rescreen-event"
RESPONSE_A=$(curl -s -X POST http://localhost:5678/webhook/uc3-rescreen-event \
  -H "Content-Type: application/json" \
  -d "$SCREEN_PAYLOAD")

echo "Response Flow A:"
echo "$RESPONSE_A" | $JQ .

CYCLE_ID=$(echo "$RESPONSE_A" | $JQ -r .cycle_id)
if [ -z "$CYCLE_ID" ] || [ "$CYCLE_ID" = "null" ]; then
  echo "❌ Error: Flow A did not return a valid cycle_id. Check if n8n is running and the workflow is active."
  exit 1
fi

# Let's find the match candidate ID created for this customer
MATCH_ID=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT pmc.id FROM pep_match_candidates pmc \
   JOIN rescreening_candidates rc ON pmc.rescreening_candidate_id = rc.id \
   WHERE rc.customer_id = $CUSTOMER_ID AND pmc.review_status = 'PENDING_REVIEW' \
   ORDER BY pmc.id DESC LIMIT 1;")

if [ -z "$MATCH_ID" ]; then
  echo "⚠️ No match candidates pending review for customer (possibly excluded or clean)."
  echo "Exiting test scenario."
  exit 0
fi

echo "Fuzzy match candidate found in DB (Match ID: $MATCH_ID)"

# -----------------------------------------------------------------------------
# FLOW B: Analyst Review + Classification + Seniority Check
# -----------------------------------------------------------------------------
echo ""
echo "=== Flow B: Compliance Analyst Review & Classification ==="
DECISION=$($JQ -r .flow_b.review_decision "$PAYLOAD")

if [ -z "$DECISION" ] || [ "$DECISION" = "null" ]; then
  echo "No Flow B parameters specified. Exiting test scenario."
  exit 0
fi

# Build Flow B Payload
FLOW_B_PAYLOAD=$($JQ --argjson mid "$MATCH_ID" '.flow_b + {"match_id": $mid}' "$PAYLOAD")

echo "POST http://localhost:5678/webhook/uc3-analyst-review"
RESPONSE_B=$(curl -s -X POST http://localhost:5678/webhook/uc3-analyst-review \
  -H "Content-Type: application/json" \
  -d "$FLOW_B_PAYLOAD")

echo "Response Flow B:"
echo "$RESPONSE_B" | $JQ .

STATUS_B=$(echo "$RESPONSE_B" | $JQ -r .status)

if [ "$STATUS_B" != "PEP_DESIGNATED" ]; then
  echo "Flow B closed the case with status: $STATUS_B. No PEP designation created."
  echo "Exiting test scenario."
  exit 0
fi

DESIGNATION_ID=$(echo "$RESPONSE_B" | $JQ -r .designation_id)
echo "PEP designation created (Designation ID: $DESIGNATION_ID)"

# -----------------------------------------------------------------------------
# FLOW C: Source of Wealth & Senior Management Approval
# -----------------------------------------------------------------------------
echo ""
echo "=== Flow C: Source of Wealth & Senior Mgmt Approval ==="

HAS_FLOW_C=$($JQ '.flow_c' "$PAYLOAD")
if [ -z "$HAS_FLOW_C" ] || [ "$HAS_FLOW_C" = "null" ]; then
  echo "No Flow C parameters specified. Exiting test scenario."
  exit 0
fi

# Sub-step 1: Submit SOW Evidence
echo "--- Submitting Source-of-Wealth Evidence ---"
EVIDENCE_PAYLOAD=$($JQ --argjson did "$DESIGNATION_ID" '.flow_c.evidence + {"action": "submit_evidence", "designation_id": $did}' "$PAYLOAD")

echo "POST http://localhost:5678/webhook/uc3-sow-approval (submit_evidence)"
RESPONSE_C1=$(curl -s -X POST http://localhost:5678/webhook/uc3-sow-approval \
  -H "Content-Type: application/json" \
  -d "$EVIDENCE_PAYLOAD")

echo "Response SOW Evidence:"
echo "$RESPONSE_C1" | $JQ .

# Sub-step 2: Senior Management Decision
echo ""
echo "--- Submitting Senior Management Decision ---"
APPROVAL_PAYLOAD=$($JQ --argjson did "$DESIGNATION_ID" '.flow_c.approval + {"action": "approve", "designation_id": $did}' "$PAYLOAD")

echo "POST http://localhost:5678/webhook/uc3-sow-approval (approve)"
RESPONSE_C2=$(curl -s -X POST http://localhost:5678/webhook/uc3-sow-approval \
  -H "Content-Type: application/json" \
  -d "$APPROVAL_PAYLOAD")

echo "Response Senior Management Approval:"
echo "$RESPONSE_C2" | $JQ .

# -----------------------------------------------------------------------------
# FLOW D: Monitoring Step-Down (Conditional)
# -----------------------------------------------------------------------------
echo ""
APPLY_STEPDOWN=$($JQ -r '.flow_d.apply_stepdown' "$PAYLOAD")

if [ "$APPLY_STEPDOWN" = "true" ]; then
  echo "=== Flow D: Monitoring Intensity Step-Down ==="
  STEPDOWN_PAYLOAD=$($JQ --argjson did "$DESIGNATION_ID" '.flow_d.stepdown_payload + {"designation_id": $did}' "$PAYLOAD")
  
  echo "POST http://localhost:5678/webhook/uc3-stepdown"
  RESPONSE_D=$(curl -s -X POST http://localhost:5678/webhook/uc3-stepdown \
    -H "Content-Type: application/json" \
    -d "$STEPDOWN_PAYLOAD")
    
  echo "Response Flow D:"
  echo "$RESPONSE_D" | $JQ .
fi

echo ""
echo "============================================================================="
echo "  Test scenario run complete."
echo "============================================================================="
