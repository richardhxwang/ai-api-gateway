#!/bin/bash
# Test script for v2 changes: O-02 fix, Phase 1a (budget), Phase 1b (model allowlist)
BASE="http://localhost:9471"
SECRET="${ADMIN_SECRET:-test-secret}"
CURL="curl -s --max-time 3"
PASS=0
FAIL=0
TOTAL=0

check() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -q "$expected"; then
    PASS=$((PASS + 1))
    echo "  ✅ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ❌ $desc"
    echo "     Expected: $expected"
    echo "     Got: $(echo "$actual" | head -1)"
  fi
}

echo "============================================"
echo "  LumiGate v2 Test Suite"
echo "============================================"

# Health check
R=$($CURL "$BASE/health")
check "Health endpoint" '"status":"ok"' "$R"

# Auth
R=$($CURL -X POST "$BASE/admin/login" \
  -H "Content-Type: application/json" \
  -d "{\"secret\":\"$SECRET\"}")
check "Login" '"success":true' "$R"

echo ""
echo "--- Phase 1b: Model Allowlist ---"

# Clean up any leftover test projects
$CURL -X DELETE "$BASE/admin/projects/test-allowlist" -H "x-admin-token: $SECRET" > /dev/null 2>&1
$CURL -X DELETE "$BASE/admin/projects/test-budget" -H "x-admin-token: $SECRET" > /dev/null 2>&1
$CURL -X DELETE "$BASE/admin/projects/test-path" -H "x-admin-token: $SECRET" > /dev/null 2>&1

# Create project with model allowlist
R=$($CURL -X POST "$BASE/admin/projects" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $SECRET" \
  -d '{"name":"test-allowlist","allowedModels":["gpt-4.1-nano","gpt-4.1-mini"]}')
check "Create project with allowedModels" '"success":true' "$R"
KEY=$(echo "$R" | sed 's/.*"key":"//;s/".*//')

# Verify allowedModels saved
R=$($CURL "$BASE/admin/projects" -H "x-admin-token: $SECRET")
check "Project has allowedModels" 'allowedModels' "$R"

# Test disallowed model — should get 403 immediately (no proxy timeout)
R=$($CURL -X POST "$BASE/v1/openai/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"gpt-5","messages":[{"role":"user","content":"hi"}]}')
check "Disallowed model rejected with 403" "Model not allowed" "$R"

# Test allowed model — should NOT get "Model not allowed" (may timeout at proxy, that's OK)
R=$($CURL -X POST "$BASE/v1/openai/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"gpt-4.1-nano","messages":[{"role":"user","content":"hi"}]}')
if echo "$R" | grep -q "Model not allowed"; then
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  echo "  ❌ Allowed model should pass allowlist"
else
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  echo "  ✅ Allowed model passes allowlist"
fi

# Update: remove allowlist
R=$($CURL -X PUT "$BASE/admin/projects/test-allowlist" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $SECRET" \
  -d '{"allowedModels":[]}')
check "Remove allowedModels" '"success":true' "$R"

# After removal, previously blocked model should pass allowlist
R=$($CURL -X POST "$BASE/v1/openai/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"gpt-5","messages":[{"role":"user","content":"hi"}]}')
if echo "$R" | grep -q "Model not allowed"; then
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  echo "  ❌ After removing allowlist, all models should pass"
else
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  echo "  ✅ After removing allowlist, all models pass"
fi

$CURL -X DELETE "$BASE/admin/projects/test-allowlist" -H "x-admin-token: $SECRET" > /dev/null

echo ""
echo "--- Phase 1a: Budget Enforcement ---"

# Create project with budget
R=$($CURL -X POST "$BASE/admin/projects" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $SECRET" \
  -d '{"name":"test-budget","maxBudgetUsd":10.00,"budgetPeriod":"monthly"}')
check "Create project with budget" '"success":true' "$R"
check "Has maxBudgetUsd" '"maxBudgetUsd":10' "$R"
check "Has budgetUsedUsd" '"budgetUsedUsd":0' "$R"
check "Has budgetPeriod" '"budgetPeriod":"monthly"' "$R"
check "Has budgetResetAt" '"budgetResetAt"' "$R"
BKEY=$(echo "$R" | sed 's/.*"key":"//;s/".*//')

# Set budget to tiny value so it's "exceeded" after any usage
R=$($CURL -X PUT "$BASE/admin/projects/test-budget" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $SECRET" \
  -d '{"maxBudgetUsd":0.0000001}')
check "Update budget to tiny value" '"success":true' "$R"

# Now manually we can't set budgetUsedUsd, but we can test the structure
# Test resetBudget
R=$($CURL -X PUT "$BASE/admin/projects/test-budget" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $SECRET" \
  -d '{"resetBudget":true}')
check "Reset budget" '"success":true' "$R"

# Test update budgetPeriod
R=$($CURL -X PUT "$BASE/admin/projects/test-budget" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $SECRET" \
  -d '{"budgetPeriod":"daily"}')
check "Change to daily period" '"success":true' "$R"
check "Daily period saved" '"budgetPeriod":"daily"' "$R"

# Test remove budget (set null)
R=$($CURL -X PUT "$BASE/admin/projects/test-budget" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $SECRET" \
  -d '{"maxBudgetUsd":null}')
check "Remove budget (null)" '"success":true' "$R"

# Verify budget fields removed
R=$($CURL "$BASE/admin/projects" -H "x-admin-token: $SECRET")
if echo "$R" | python3 -c "import sys,json; ps=json.load(sys.stdin); p=[x for x in ps if x['name']=='test-budget'][0]; sys.exit(0 if 'maxBudgetUsd' not in p else 1)" 2>/dev/null; then
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  echo "  ✅ Budget fields cleaned up after removal"
else
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  echo "  ❌ Budget fields should be removed"
fi

$CURL -X DELETE "$BASE/admin/projects/test-budget" -H "x-admin-token: $SECRET" > /dev/null

echo ""
echo "--- O-02: Path Allowlist Fix ---"

# Create test project
R=$($CURL -X POST "$BASE/admin/projects" \
  -H "Content-Type: application/json" \
  -H "x-admin-token: $SECRET" \
  -d '{"name":"test-path"}')
PKEY=$(echo "$R" | sed 's/.*"key":"//;s/".*//')

# Invalid path — should be rejected immediately (no timeout)
R=$($CURL -X POST "$BASE/v1/openai/admin/evil" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $PKEY" \
  -d '{"model":"test"}')
check "Invalid openai path rejected" "path is not allowed" "$R"

# doubao may not have API key configured, so either "path not allowed" or "no API key" is fine
R=$($CURL -X POST "$BASE/v1/doubao/admin/evil" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $PKEY" \
  -d '{"model":"test"}')
if echo "$R" | grep -qE "path is not allowed|API key"; then
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  echo "  ✅ Invalid doubao path blocked ($(echo "$R" | grep -o '"error":"[^"]*"'))"
else
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  echo "  ❌ Invalid doubao path should be blocked"
fi

# O-02 fix: /v1/doubao/v1/chat/completions should normalize correctly
# Before fix: would be rejected as "/v1/chat/completions" doesn't match "/chat/completions"
# After fix: normalized to "/chat/completions" which matches
R=$($CURL -X POST "$BASE/v1/doubao/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $PKEY" \
  -d '{"model":"doubao-1.5-lite-32k","messages":[{"role":"user","content":"hi"}]}')
if echo "$R" | grep -q "path is not allowed"; then
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  echo "  ❌ O-02: doubao /v1/chat/completions should be accepted after normalization"
else
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  echo "  ✅ O-02: doubao /v1/chat/completions normalized correctly"
fi

# Gemini path normalization: /v1/gemini/v1/chat/completions → /v1beta/openai/chat/completions
R=$($CURL -X POST "$BASE/v1/gemini/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $PKEY" \
  -d '{"model":"gemini-2.5-flash","messages":[{"role":"user","content":"hi"}]}')
if echo "$R" | grep -q "path is not allowed"; then
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  echo "  ❌ Gemini /v1/chat/completions should normalize to /v1beta/openai/"
else
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  echo "  ✅ Gemini /v1/chat/completions normalized correctly"
fi

# Standard path should still work
R=$($CURL -X POST "$BASE/v1/openai/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $PKEY" \
  -d '{"model":"gpt-4.1-nano","messages":[{"role":"user","content":"hi"}]}')
if echo "$R" | grep -q "path is not allowed"; then
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  echo "  ❌ Standard openai path should work"
else
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  echo "  ✅ Standard openai path works"
fi

$CURL -X DELETE "$BASE/admin/projects/test-path" -H "x-admin-token: $SECRET" > /dev/null

echo ""
echo "--- Basic Endpoints ---"

R=$($CURL "$BASE/health")
check "Health endpoint" '"status":"ok"' "$R"

R=$($CURL "$BASE/providers")
check "Providers endpoint has baseUrl" 'baseUrl' "$R"

R=$($CURL "$BASE/models/openai")
check "Models endpoint" 'gpt-4.1' "$R"

echo ""
echo "============================================"
echo "  Results: $PASS/$TOTAL passed, $FAIL failed"
echo "============================================"

[ $FAIL -eq 0 ] && exit 0 || exit 1
