#!/bin/bash

# Usage: ./test_onboarding.sh payloads/<file.json> [APPROVED/REJECTED]
PAYLOAD=$1
DECISION=${2:-"APPROVED"}

if [ -z "$PAYLOAD" ]; then
  echo "Usage: ./test_onboarding.sh payloads/<file.json> [APPROVED/REJECTED]"
  exit 1
fi

# Ensure the workflow is active for production URL calls
echo "=== 1. Triggering Onboarding Intake ==="
RESPONSE=$(curl -s -X POST http://localhost:5678/webhook/uc1-onboarding \
  -H "Content-Type: application/json" \
  -d @"$PAYLOAD")

echo "Intake Response:"
echo "$RESPONSE" | /snap/bin/jq .

STATUS=$(echo "$RESPONSE" | /snap/bin/jq -r .status)
CASE_REF=$(echo "$RESPONSE" | /snap/bin/jq -r .case_ref)

if [ "$STATUS" = "PENDING_APPROVAL" ]; then
  echo ""
  echo "=== 2. Asynchronous Manager Approval Required ==="
  echo "Case Reference: $CASE_REF"
  echo "Sending approval request ($DECISION) to static endpoint..."
  
  APPROVAL_RESPONSE=$(curl -s -X POST http://localhost:5678/webhook/uc1-approve-case \
    -H "Content-Type: application/json" \
    -d "{\"case_ref\": \"$CASE_REF\", \"decision\": \"$DECISION\", \"approver_name\": \"Compliance Officer\", \"approver_role\": \"SENIOR_MANAGEMENT\"}")
    
  echo "Approval Response:"
  echo "$APPROVAL_RESPONSE" | /snap/bin/jq .
else
  echo ""
  echo "=== Onboarding Completed Immediately (No Manager Approval Required) ==="
fi
