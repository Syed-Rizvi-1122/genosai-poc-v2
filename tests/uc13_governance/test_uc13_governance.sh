#!/bin/bash

# =============================================================================
# UC13: IRAR & BoD Governance — Automated Test Runner
# GenosAI AML/CFT/CPF Compliance Automation POC v2
# =============================================================================
# Usage: ./test_uc13_governance.sh payloads/<file.json>
# =============================================================================

PAYLOAD=$1
JQ="/snap/bin/jq"

if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
  echo "Usage: ./test_uc13_governance.sh payloads/<file.json>"
  exit 1
fi

SCENARIO=$(basename "$PAYLOAD" .json)
echo "============================================================================="
echo "  IRAR & BOD GOVERNANCE PIPELINE TEST RUNNER"
echo "  Scenario: $SCENARIO"
echo "============================================================================="

# -----------------------------------------------------------------------------
# Clean up existing test cycle (except ID 1 which is the historical seed)
# -----------------------------------------------------------------------------
docker exec -i aml-postgres psql -U aml_user -d aml_local -c \
  "DELETE FROM irar_senior_mgmt_prereview WHERE cycle_id > 1; \
   DELETE FROM irar_bod_approval WHERE cycle_id > 1; \
   DELETE FROM irar_sop_approval WHERE action_plan_item_id IN (SELECT id FROM irar_action_plan_items WHERE cycle_id > 1); \
   DELETE FROM irar_action_plan_items WHERE cycle_id > 1; \
   DELETE FROM irar_gap_analysis WHERE cycle_id > 1; \
   DELETE FROM irar_risk_narrative WHERE cycle_id > 1; \
   DELETE FROM irar_employee_risk_snapshot WHERE cycle_id > 1; \
   DELETE FROM irar_rejected_case_inputs WHERE cycle_id > 1; \
   DELETE FROM irar_external_inputs WHERE cycle_id > 1; \
   DELETE FROM irar_internal_metrics_snapshot WHERE cycle_id > 1; \
   DELETE FROM irar_archive WHERE cycle_id > 1; \
   DELETE FROM irar_cycles WHERE id > 1;" > /dev/null 2>&1

# -----------------------------------------------------------------------------
# STEP 1: Trigger Intake (Cron / Event)
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: Triggering IRAR Cycle Trigger Webhook ==="
TRIGGER_TYPE=$($JQ -r '.trigger.trigger_type' "$PAYLOAD")
TRIGGER_NOTE=$($JQ -r '.trigger.trigger_note' "$PAYLOAD")

RESPONSE_CYCLE=$(curl -s -X POST "http://localhost:5678/webhook/uc13-event-trigger" \
  -H "Content-Type: application/json" \
  -d "{\"trigger_type\": \"$TRIGGER_TYPE\", \"trigger_note\": \"$TRIGGER_NOTE\"}")

echo "Response Cycle:"
echo "$RESPONSE_CYCLE" | $JQ .

# Extract cycle ID from the database if not returned directly
CYCLE_ID=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT id FROM irar_cycles WHERE trigger_type = '$TRIGGER_TYPE' ORDER BY id DESC LIMIT 1;")

if [ -z "$CYCLE_ID" ] || [ "$CYCLE_ID" = "null" ]; then
  echo "Error: Failed to fetch cycle ID from database."
  exit 1
fi
echo "Active Cycle ID: $CYCLE_ID"

# -----------------------------------------------------------------------------
# STEP 2: Input External Parameters & Staff Risk (Asynchronous entry points)
# -----------------------------------------------------------------------------
HAS_EXTERNAL=$($JQ 'has("external_input")' "$PAYLOAD")
if [ "$HAS_EXTERNAL" = "true" ]; then
  echo ""
  echo "=== Step 2a: Entering External Regulatory Inputs ==="
  EXT_BODY=$($JQ --argjson cid "$CYCLE_ID" '.external_input + {"cycle_id": $cid}' "$PAYLOAD")
  
  # Check if source_attribution is blank to test DB validation constraints
  ATTR=$(echo "$EXT_BODY" | $JQ -r .source_attribution)
  if [ -z "$ATTR" ] || [ "$ATTR" = "null" ]; then
    echo "Sending payload with empty source_attribution to test DB constraint..."
  fi

  RESPONSE_EXT=$(curl -s -X POST "http://localhost:5678/webhook/uc13-external-inputs" \
    -H "Content-Type: application/json" \
    -d "$EXT_BODY")
  echo "Response External Input:"
  echo "$RESPONSE_EXT" | $JQ .
fi

HAS_STAFF=$($JQ 'has("staff_risk")' "$PAYLOAD")
if [ "$HAS_STAFF" = "true" ]; then
  echo ""
  echo "=== Step 2b: Entering Staff Risk Snapshot ==="
  STAFF_BODY=$($JQ --argjson cid "$CYCLE_ID" '.staff_risk + {"cycle_id": $cid}' "$PAYLOAD")
  RESPONSE_STAFF=$(curl -s -X POST "http://localhost:5678/webhook/uc13-staff-risk" \
    -H "Content-Type: application/json" \
    -d "$STAFF_BODY")
  echo "Response Staff Input:"
  echo "$RESPONSE_STAFF" | $JQ .
fi

# -----------------------------------------------------------------------------
# STEP 3: LLM Drafting & Analyst Narrative Edits
# -----------------------------------------------------------------------------
HAS_NARRATIVE=$($JQ 'has("narrative")' "$PAYLOAD")
if [ "$HAS_NARRATIVE" = "true" ]; then
  echo ""
  echo "=== Step 3: Triggering Narrative Drafting & Analyst Review ==="
  # Trigger draft start
  curl -s -X POST "http://localhost:5678/webhook/uc13-draft-start" \
    -H "Content-Type: application/json" \
    -d "{\"cycle_id\": $CYCLE_ID}" > /dev/null
  
  # Submit analyst edits
  EDIT_BODY=$($JQ --argjson cid "$CYCLE_ID" '.narrative + {"cycle_id": $cid}' "$PAYLOAD")
  RESPONSE_EDIT=$(curl -s -X POST "http://localhost:5678/webhook/uc13-analyst-edit" \
    -H "Content-Type: application/json" \
    -d "$EDIT_BODY")
  echo "Response Analyst Narrative Edit:"
  echo "$RESPONSE_EDIT" | $JQ .
fi

# -----------------------------------------------------------------------------
# STEP 4: Gap Analysis & Action Recommendations
# -----------------------------------------------------------------------------
HAS_GAP=$($JQ 'has("gap_analysis")' "$PAYLOAD")
if [ "$HAS_GAP" = "true" ]; then
  echo ""
  echo "=== Step 4a: Entering Gap Analysis ==="
  GAP_BODY=$($JQ --argjson cid "$CYCLE_ID" '.gap_analysis + {"cycle_id": $cid}' "$PAYLOAD")
  RESPONSE_GAP=$(curl -s -X POST "http://localhost:5678/webhook/uc13-gap-analysis" \
    -H "Content-Type: application/json" \
    -d "$GAP_BODY")
  echo "Response Gap Analysis:"
  echo "$RESPONSE_GAP" | $JQ .
fi

# Enforce category recommendations
HAS_ACTIONS=$($JQ 'has("action_items")' "$PAYLOAD")
if [ "$HAS_ACTIONS" = "true" ]; then
  echo ""
  echo "=== Step 4b: Entering Action Plan Recommendations ==="
  # Iterate over recommendations in payload array
  len=$($JQ '.action_items | length' "$PAYLOAD")
  for ((i=0; i<len; i++)); do
    REC_BODY=$($JQ --argjson cid "$CYCLE_ID" --argjson idx "$i" '.action_items[$idx] + {"cycle_id": $cid}' "$PAYLOAD")
    CAT=$(echo "$REC_BODY" | $JQ -r .category)
    echo "Adding recommendation for category: $CAT"
    
    RESPONSE_REC=$(curl -s -X POST "http://localhost:5678/webhook/uc13-action-item" \
      -H "Content-Type: application/json" \
      -d "$REC_BODY")
  done
  
  # Perform validation check
  echo ""
  echo "=== Step 4c: Executing Category Validation Check ==="
  # Execute checking query
  VAL_RESULT=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
    "SELECT COUNT(DISTINCT category) FROM irar_action_plan_items WHERE cycle_id = $CYCLE_ID;")
  echo "Unique action plan categories logged in DB: $VAL_RESULT / 5"
fi

# -----------------------------------------------------------------------------
# STEP 5: Governance Approval Tier 1 & Tier 2
# -----------------------------------------------------------------------------
HAS_PREREVIEW=$($JQ 'has("pre_review")' "$PAYLOAD")
if [ "$HAS_PREREVIEW" = "true" ] && [ "$VAL_RESULT" = "5" ]; then
  echo ""
  echo "=== Step 5a: Submitting Senior Management Pre-Review ==="
  # Trigger pre-review workflow
  curl -s -X POST "http://localhost:5678/webhook/uc13-pre-review" \
    -H "Content-Type: application/json" \
    -d "{\"cycle_id\": $CYCLE_ID}" > /dev/null

  PR_BODY=$($JQ --argjson cid "$CYCLE_ID" '.pre_review + {"cycle_id": $cid}' "$PAYLOAD")
  DEC=$(echo "$PR_BODY" | $JQ -r .decision)
  echo "Submitting pre-review decision: $DEC"
  RESPONSE_PR=$(curl -s -X POST "http://localhost:5678/webhook/uc13-prereview-decision" \
    -H "Content-Type: application/json" \
    -d "$PR_BODY")
  echo "Response Pre-Review Decision:"
  echo "$RESPONSE_PR" | $JQ .
fi

HAS_BOD=$($JQ 'has("bod_approval")' "$PAYLOAD")
if [ "$HAS_BOD" = "true" ] && [ "$DEC" = "APPROVED_FOR_BOD" ]; then
  echo ""
  echo "=== Step 5b: Submitting Board of Directors Approval ==="
  BOD_BODY=$($JQ --argjson cid "$CYCLE_ID" '.bod_approval + {"cycle_id": $cid}' "$PAYLOAD")
  BOD_DEC=$(echo "$BOD_BODY" | $JQ -r .decision)
  echo "Submitting Board Approval decision: $BOD_DEC"
  RESPONSE_BOD=$(curl -s -X POST "http://localhost:5678/webhook/uc13-bod-decision" \
    -H "Content-Type: application/json" \
    -d "$BOD_BODY")
  echo "Response Board Approval Decision:"
  echo "$RESPONSE_BOD" | $JQ .
fi

HAS_SOP=$($JQ 'has("sop_approval")' "$PAYLOAD")
if [ "$HAS_SOP" = "true" ] && [ "$BOD_DEC" = "APPROVED" ]; then
  echo ""
  echo "=== Step 5c: Submitting SOP/Procedure Approval (Tier 2) ==="
  # Lookup the action plan item ID for SOP category
  SOP_ITEM_ID=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
    "SELECT id FROM irar_action_plan_items WHERE cycle_id = $CYCLE_ID AND category = 'SOP_PROCEDURE_MANUAL' LIMIT 1;")
  
  if [ -n "$SOP_ITEM_ID" ] && [ "$SOP_ITEM_ID" != "null" ]; then
    SOP_BODY=$($JQ --argjson aid "$SOP_ITEM_ID" '.sop_approval + {"action_plan_item_id": $aid}' "$PAYLOAD")
    RESPONSE_SOP=$(curl -s -X POST "http://localhost:5678/webhook/uc13-sop-decision" \
      -H "Content-Type: application/json" \
      -d "$SOP_BODY")
    echo "Response SOP Approval Decision:"
    echo "$RESPONSE_SOP" | $JQ .
  else
    echo "Warning: No SOP action item found to perform Tier 2 approval."
  fi
fi

# -----------------------------------------------------------------------------
# STEP 6: Database Verification Checks
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 6: Final Database Verification Checks ==="
DB_STATUS=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT status FROM irar_cycles WHERE id = $CYCLE_ID;")
echo "Cycle Status in DB: $DB_STATUS"

if [ "$DB_STATUS" = "ARCHIVED" ]; then
  DB_RETENTION=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
    "SELECT retention_until FROM irar_archive WHERE cycle_id = $CYCLE_ID;")
  echo "Archive Record Retention Expiry: $DB_RETENTION"
fi

echo "============================================================================="
echo "  Test scenario run complete."
echo "============================================================================="
