#!/bin/bash

# =============================================================================
# UC5: CTR Pipeline — Automated Test Runner
# GenosAI AML/CFT/CPF Compliance Automation POC v2
# =============================================================================
# Usage: ./test_uc5_ctr.sh payloads/<file.json>
# =============================================================================

PAYLOAD=$1
JQ="/snap/bin/jq"

if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
  echo "Usage: ./test_uc5_ctr.sh payloads/<file.json>"
  exit 1
fi

echo "============================================================================="
echo "  CTR PIPELINE TEST RUNNER"
echo "  Scenario: $($JQ -r .scenario "$PAYLOAD")"
echo "============================================================================="

# -----------------------------------------------------------------------------
# STEP 0: Verify target customer exists in database
# -----------------------------------------------------------------------------
echo "=== Step 0: Verifying Test Customer in Database ==="
CUSTOMER_ID=$($JQ -r .transaction.customer_id "$PAYLOAD")

# Check if customer exists in customers table
CUST_EXISTS=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT 1 FROM customers WHERE id = $CUSTOMER_ID;")

if [ -z "$CUST_EXISTS" ]; then
  echo "⚠️ Customer ID $CUSTOMER_ID not found in database. Inserting mock customer..."
  docker exec -i aml-postgres psql -U aml_user -d aml_local -c \
    "INSERT INTO customers (id, case_id, role, full_name, date_of_birth, nationality_status) \
     VALUES ($CUSTOMER_ID, 1, 'PRIMARY_CUSTOMER', 'Test CTR Customer', '1985-05-12', 'RESIDENT') \
     ON CONFLICT (id) DO NOTHING;" > /dev/null
fi

CUSTOMER_NAME=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT full_name FROM customers WHERE id = $CUSTOMER_ID;")
echo "Verified Customer: $CUSTOMER_NAME (ID: $CUSTOMER_ID)"

# -----------------------------------------------------------------------------
# FLOW A: Trigger Transaction Intake (Flow A)
# -----------------------------------------------------------------------------
echo ""
echo "=== Flow A: Triggering Transaction Intake ==="
TX_PAYLOAD=$($JQ '.transaction' "$PAYLOAD")

echo "POST http://localhost:5678/webhook/uc5-ctr-transaction"
RESPONSE_A=$(curl -s -X POST http://localhost:5678/webhook/uc5-ctr-transaction \
  -H "Content-Type: application/json" \
  -d "$TX_PAYLOAD")

echo "Response Flow A:"
echo "$RESPONSE_A" | $JQ .

STATUS_A=$(echo "$RESPONSE_A" | $JQ -r .status)

if [ "$STATUS_A" != "CTR_CANDIDATE_FLAGGED" ]; then
  echo "Flow A completed with status: $STATUS_A. No CTR candidate created."
  echo "Exiting test scenario."
  exit 0
fi

CANDIDATE_ID=$(echo "$RESPONSE_A" | $JQ -r .ctr_candidate_id)
TX_ID=$(echo "$RESPONSE_A" | $JQ -r .transaction_id)
echo "CTR candidate flagged (Candidate ID: $CANDIDATE_ID, Transaction ID: $TX_ID)"

# -----------------------------------------------------------------------------
# FLOW B: Data Accuracy Check + Filing (Flow B)
# -----------------------------------------------------------------------------
echo ""
echo "=== Flow B: Compliance Verification & Filing ==="

HAS_FLOW_B=$($JQ '.verify' "$PAYLOAD")
if [ -z "$HAS_FLOW_B" ] || [ "$HAS_FLOW_B" = "null" ]; then
  echo "No Flow B parameters specified. Exiting test scenario."
  exit 0
fi

VERIFY_PAYLOAD=$($JQ --argjson cid "$CANDIDATE_ID" '.verify + {"ctr_candidate_id": $cid}' "$PAYLOAD")

echo "POST http://localhost:5678/webhook/uc5-ctr-verify"
RESPONSE_B=$(curl -s -X POST http://localhost:5678/webhook/uc5-ctr-verify \
  -H "Content-Type: application/json" \
  -d "$VERIFY_PAYLOAD")

echo "Response Flow B:"
echo "$RESPONSE_B" | $JQ .

STATUS_B=$(echo "$RESPONSE_B" | $JQ -r .status)

if [ "$STATUS_B" = "CTR_FILED" ]; then
  FILING_REF=$(echo "$RESPONSE_B" | $JQ -r .filing_reference)
  RETENTION=$(echo "$RESPONSE_B" | $JQ -r .retention_until)
  echo "✅ CTR Filed Successfully! Reference: $FILING_REF (Retained until: $RETENTION)"
  
  # Verify DB state
  DB_STATUS=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
    "SELECT data_accuracy_status FROM ctr_candidates WHERE id = $CANDIDATE_ID;")
  DB_FILING=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
    "SELECT filing_reference FROM ctr_filings WHERE ctr_candidate_id = $CANDIDATE_ID;")
    
  echo "Database verification:"
  echo "  Candidate Status: $DB_STATUS"
  echo "  Filing Reference: $DB_FILING"
else
  echo "Flow B closed verification with status: $STATUS_B."
fi

echo ""
echo "============================================================================="
echo "  Test scenario run complete."
echo "============================================================================="
