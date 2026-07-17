#!/bin/bash

# =============================================================================
# UC8: Wire Transfer Data Completeness — Automated Test Runner
# GenosAI AML/CFT/CPF Compliance Automation POC v2
# =============================================================================
# Usage: ./test_uc8_wire_transfers.sh payloads/<file.json>
# =============================================================================

PAYLOAD=$1
JQ="/snap/bin/jq"

if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
  echo "Usage: ./test_uc8_wire_transfers.sh payloads/<file.json>"
  exit 1
fi

SCENARIO=$(basename "$PAYLOAD" .json)
echo "============================================================================="
echo "  WIRE TRANSFER PIPELINE TEST RUNNER"
echo "  Scenario: $SCENARIO"
echo "============================================================================="

# Parse payload
IS_NESTED=$($JQ 'has("intake")' "$PAYLOAD")

if [ "$IS_NESTED" = "true" ]; then
  INTAKE_BODY=$($JQ '.intake' "$PAYLOAD")
  TXN_REF=$($JQ -r '.intake.transaction_ref' "$PAYLOAD")
else
  INTAKE_BODY=$(cat "$PAYLOAD")
  TXN_REF=$($JQ -r '.transaction_ref' "$PAYLOAD")
fi

# Clean up existing records for this reference to allow clean runs
docker exec -i aml-postgres psql -U aml_user -d aml_local -c \
  "DELETE FROM wire_transfer_holds WHERE wire_transfer_id = (SELECT id FROM wire_transfers WHERE transaction_ref = '$TXN_REF'); \
   DELETE FROM correspondent_completeness_logs WHERE wire_transfer_id = (SELECT id FROM wire_transfers WHERE transaction_ref = '$TXN_REF'); \
   DELETE FROM wire_transfers WHERE transaction_ref = '$TXN_REF';" > /dev/null 2>&1

# -----------------------------------------------------------------------------
# FLOW A: Trigger Intake Webhook
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: Triggering Wire Transfer Intake Webhook ==="
echo "POST http://localhost:5678/webhook/uc8-wire-intake"

RESPONSE_INTAKE=$(curl -s -X POST "http://localhost:5678/webhook/uc8-wire-intake" \
  -H "Content-Type: application/json" \
  -d "$INTAKE_BODY")

echo "Response Intake:"
echo "$RESPONSE_INTAKE" | $JQ .

STATUS_INTAKE=$(echo "$RESPONSE_INTAKE" | $JQ -r .status)
HOLD_ID=$(echo "$RESPONSE_INTAKE" | $JQ -r .hold_id)

# -----------------------------------------------------------------------------
# FLOW B: Trigger Analyst Action Webhook if required
# -----------------------------------------------------------------------------
HAS_ACTION=$($JQ 'has("analyst_action")' "$PAYLOAD")

if [ "$HAS_ACTION" = "true" ] && [ "$STATUS_INTAKE" = "HELD_COMPLETENESS" ]; then
  # If hold_id is missing or null, fetch from DB
  if [ -z "$HOLD_ID" ] || [ "$HOLD_ID" = "null" ]; then
    HOLD_ID=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
      "SELECT id FROM wire_transfer_holds WHERE wire_transfer_id = (SELECT id FROM wire_transfers WHERE transaction_ref = '$TXN_REF') ORDER BY id DESC LIMIT 1;")
  fi

  echo ""
  echo "=== Step 2: Triggering Analyst Action Webhook ==="
  echo "POST http://localhost:5678/webhook/uc8-analyst-action (Hold ID: $HOLD_ID)"
  
  ACTION_BODY=$($JQ --argjson hid "$HOLD_ID" '.analyst_action + {"hold_id": $hid}' "$PAYLOAD")
  
  RESPONSE_ACTION=$(curl -s -X POST "http://localhost:5678/webhook/uc8-analyst-action" \
    -H "Content-Type: application/json" \
    -d "$ACTION_BODY")
    
  echo "Response Analyst Action:"
  echo "$RESPONSE_ACTION" | $JQ .
fi

# -----------------------------------------------------------------------------
# STEP 3: Database Verification Checks
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Database Verification Checks ==="

DB_WT_STATUS=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT transfer_status FROM wire_transfers WHERE transaction_ref = '$TXN_REF';")

DB_EXEMPT=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT is_interbank_exemption FROM wire_transfers WHERE transaction_ref = '$TXN_REF';")

DB_CDD_FAIL=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT flagged_for_cdd_failure FROM wire_transfers WHERE transaction_ref = '$TXN_REF';")

DB_STR_FAIL=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT flagged_for_str_review FROM wire_transfers WHERE transaction_ref = '$TXN_REF';")

DB_RETENTION=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT retention_until FROM wire_transfers WHERE transaction_ref = '$TXN_REF';")

echo "Database verification:"
echo "  Transfer Status in DB:       $DB_WT_STATUS"
echo "  Interbank Exemption Flag:    $DB_EXEMPT"
echo "  CDD Failure Block Flag:      $DB_CDD_FAIL"
echo "  STR Review Escalation Flag:  $DB_STR_FAIL"
echo "  Record Retention Deadline:   $DB_RETENTION"

echo ""
echo "============================================================================="
echo "  Test scenario run complete."
echo "============================================================================="
