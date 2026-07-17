#!/bin/bash

# =============================================================================
# UC5: STR Investigation Pipeline — Automated Test Runner
# GenosAI AML/CFT/CPF Compliance Automation POC v2
# =============================================================================
# Usage: ./test_uc5_str.sh payloads/<file.json>
# =============================================================================

PAYLOAD=$1
JQ="/snap/bin/jq"

if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
  echo "Usage: ./test_uc5_str.sh payloads/<file.json>"
  exit 1
fi

echo "============================================================================="
echo "  STR PIPELINE TEST RUNNER"
echo "  Scenario: $($JQ -r .scenario "$PAYLOAD")"
echo "============================================================================="

# -----------------------------------------------------------------------------
# STEP 0: Verify target customer exists in database
# -----------------------------------------------------------------------------
echo "=== Step 0: Verifying Test Customer in Database ==="
CUSTOMER_ID=$($JQ -r .customer_id "$PAYLOAD")

# Check if customer exists in customers table
CUST_EXISTS=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT 1 FROM customers WHERE id = $CUSTOMER_ID;")

if [ -z "$CUST_EXISTS" ]; then
  echo "⚠️ Customer ID $CUSTOMER_ID not found in database. Inserting mock customer..."
  docker exec -i aml-postgres psql -U aml_user -d aml_local -c \
    "INSERT INTO customers (id, case_id, role, full_name, date_of_birth, nationality_status) \
     VALUES ($CUSTOMER_ID, 1, 'PRIMARY_CUSTOMER', 'Test STR Customer', '1978-11-23', 'RESIDENT') \
     ON CONFLICT (id) DO NOTHING;" > /dev/null
fi

CUSTOMER_NAME=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
  "SELECT full_name FROM customers WHERE id = $CUSTOMER_ID;")
echo "Verified Customer: $CUSTOMER_NAME (ID: $CUSTOMER_ID)"

# -----------------------------------------------------------------------------
# FLOW A: Trigger Case Creation (Flow A)
# -----------------------------------------------------------------------------
HAS_TRIGGER=$($JQ '.trigger' "$PAYLOAD")
if [ -n "$HAS_TRIGGER" ] && [ "$HAS_TRIGGER" != "null" ]; then
  echo ""
  echo "=== Flow A: Triggering Case Creation ==="
  TRIGGER_PATH=$($JQ -r .trigger.path "$PAYLOAD")
  TRIGGER_BODY=$($JQ --argjson cust_id "$CUSTOMER_ID" '.trigger.body + {"customer_id": $cust_id}' "$PAYLOAD")

  echo "POST http://localhost:5678/webhook/$TRIGGER_PATH"
  RESPONSE_A=$(curl -s -X POST "http://localhost:5678/webhook/$TRIGGER_PATH" \
    -H "Content-Type: application/json" \
    -d "$TRIGGER_BODY")

  echo "Response Flow A:"
  echo "$RESPONSE_A" | $JQ .

  STATUS_A=$(echo "$RESPONSE_A" | $JQ -r .status)
  CASE_ID=$(echo "$RESPONSE_A" | $JQ -r .case_id)
  CASE_REF=$(echo "$RESPONSE_A" | $JQ -r .case_ref)

  if [ -z "$CASE_ID" ] || [ "$CASE_ID" = "null" ]; then
    echo "❌ Error: Flow A did not return a valid case_id."
    exit 1
  fi
  echo "STR case created (Case ID: $CASE_ID, Ref: $CASE_REF, Status: $STATUS_A)"
else
  # If no trigger in payload, try to find the latest open case for this customer in DB
  CASE_ID=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
    "SELECT id FROM str_cases WHERE customer_id = $CUSTOMER_ID ORDER BY id DESC LIMIT 1;")
  CASE_REF=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
    "SELECT case_ref FROM str_cases WHERE id = $CASE_ID;")
  echo "Using existing case from DB: $CASE_REF (ID: $CASE_ID)"
fi

# -----------------------------------------------------------------------------
# ACCESS CHECK: Test Access Control (Flow D)
# -----------------------------------------------------------------------------
HAS_ACCESS_CHECK=$($JQ '.access_check' "$PAYLOAD")
if [ -n "$HAS_ACCESS_CHECK" ] && [ "$HAS_ACCESS_CHECK" != "null" ]; then
  echo ""
  echo "=== Flow D: Access Control check ==="
  ACCESS_PAYLOAD=$($JQ --argjson cid "$CASE_ID" '.access_check + {"str_case_id": $cid}' "$PAYLOAD")

  echo "POST http://localhost:5678/webhook/uc5-str-access-check"
  RESPONSE_AC=$(curl -s -X POST http://localhost:5678/webhook/uc5-str-access-check \
    -H "Content-Type: application/json" \
    -d "$ACCESS_PAYLOAD")

  echo "Response Access Check:"
  echo "$RESPONSE_AC" | $JQ .
fi

# -----------------------------------------------------------------------------
# FLOW B: Analyst Investigation (Flow B - investigate)
# -----------------------------------------------------------------------------
HAS_INVESTIGATE=$($JQ '.analyst_investigate' "$PAYLOAD")
if [ -n "$HAS_INVESTIGATE" ] && [ "$HAS_INVESTIGATE" != "null" ]; then
  echo ""
  echo "=== Flow B: Analyst Investigation Logging ==="
  INV_PAYLOAD=$($JQ --argjson cid "$CASE_ID" '.analyst_investigate + {"str_case_id": $cid}' "$PAYLOAD")

  echo "POST http://localhost:5678/webhook/uc5-str-analyst-action (investigate)"
  RESPONSE_INV=$(curl -s -X POST http://localhost:5678/webhook/uc5-str-analyst-action \
    -H "Content-Type: application/json" \
    -d "$INV_PAYLOAD")

  echo "Response Investigation Log:"
  echo "$RESPONSE_INV" | $JQ .
fi

# -----------------------------------------------------------------------------
# FLOW B: Analyst Decision (Flow B - decide)
# -----------------------------------------------------------------------------
HAS_DECIDE=$($JQ '.analyst_decide' "$PAYLOAD")
if [ -n "$HAS_DECIDE" ] && [ "$HAS_DECIDE" != "null" ]; then
  echo ""
  echo "=== Flow B: Analyst Decision Submission ==="
  DEC_PAYLOAD=$($JQ --argjson cid "$CASE_ID" '.analyst_decide + {"str_case_id": $cid}' "$PAYLOAD")

  echo "POST http://localhost:5678/webhook/uc5-str-analyst-action (decide)"
  RESPONSE_DEC=$(curl -s -X POST http://localhost:5678/webhook/uc5-str-analyst-action \
    -H "Content-Type: application/json" \
    -d "$DEC_PAYLOAD")

  echo "Response Analyst Decision:"
  echo "$RESPONSE_DEC" | $JQ .
  
  DEC_STATUS=$(echo "$RESPONSE_DEC" | $JQ -r .status)
fi

# -----------------------------------------------------------------------------
# FLOW C: Officer Sign-Off + Filing (Flow C)
# -----------------------------------------------------------------------------
HAS_SIGNOFF=$($JQ '.officer_signoff' "$PAYLOAD")
if [ -n "$HAS_SIGNOFF" ] && [ "$HAS_SIGNOFF" != "null" ]; then
  echo ""
  echo "=== Flow C: Compliance Officer Sign-Off ==="
  SIGNOFF_PAYLOAD=$($JQ --argjson cid "$CASE_ID" '.officer_signoff + {"str_case_id": $cid}' "$PAYLOAD")

  echo "POST http://localhost:5678/webhook/uc5-str-officer-signoff"
  RESPONSE_SO=$(curl -s -X POST http://localhost:5678/webhook/uc5-str-officer-signoff \
    -H "Content-Type: application/json" \
    -d "$SIGNOFF_PAYLOAD")

  echo "Response Officer Sign-Off:"
  echo "$RESPONSE_SO" | $JQ .
  
  # Verify DB state
  DB_STATUS=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
    "SELECT review_status FROM str_cases WHERE id = $CASE_ID;")
  DB_FILING=$(docker exec -i aml-postgres psql -U aml_user -d aml_local -t -A -c \
    "SELECT filing_reference FROM str_filings WHERE str_case_id = $CASE_ID;")
    
  echo ""
  echo "Database verification:"
  echo "  Case Status in DB: $DB_STATUS"
  if [ -n "$DB_FILING" ]; then
    echo "  Filing Reference in DB: $DB_FILING"
  fi
fi

echo ""
echo "============================================================================="
echo "  Test scenario run complete."
echo "============================================================================="
