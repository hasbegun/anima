#!/bin/bash
# Phase 1 Tests: ThunderID Setup
# Verifies that ThunderID and MailSlurper are running and healthy.
set -euo pipefail

BASE_URL="https://localhost:8090"
CURL="curl -sf --insecure --max-time 10"

PASS=0
FAIL=0
TOTAL=0

run_test() {
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" > /dev/null 2>&1; then
        echo "  PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_field() {
    local url="$1"
    local field="$2"
    local body
    body=$($CURL "$url") || return 1
    echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$field' in d, 'missing $field'" 2>/dev/null
}

echo "=== Phase 1: ThunderID Setup Tests ==="
echo ""

# Test 1.1: Server responds (OIDC discovery returns valid JSON)
run_test "1.1 Server responds" \
    bash -c "$CURL '$BASE_URL/.well-known/openid-configuration' | python3 -c 'import sys,json; json.load(sys.stdin)'"

# Test 1.2: OIDC discovery has required fields
run_test "1.2 OIDC discovery available" \
    bash -c "$CURL '$BASE_URL/.well-known/openid-configuration' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
for field in ['issuer', 'token_endpoint', 'jwks_uri']:
    assert field in d, f'missing {field}'
\""

# Test 1.3: JWKS endpoint returns keys array with at least 1 key
run_test "1.3 JWKS endpoint returns keys" \
    bash -c "$CURL '$BASE_URL/oauth2/jwks' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert 'keys' in d, 'missing keys'
assert len(d['keys']) >= 1, 'no keys found'
\""

# Test 1.4: Admin console loads (returns HTTP 200 or redirect)
run_test "1.4 Admin console loads" \
    bash -c "curl -s --insecure --max-time 10 -o /dev/null -w '%{http_code}' '$BASE_URL/console' | grep -qE '^(200|301|302|303|307)$'"

# Test 1.5: Login gate loads (returns HTTP 200 or redirect)
run_test "1.5 Login gate loads" \
    bash -c "curl -s --insecure --max-time 10 -o /dev/null -w '%{http_code}' '$BASE_URL/gate' | grep -qE '^(200|301|302|303|307)$'"

# Test 1.6: MailSlurper Web UI responds
run_test "1.6 MailSlurper Web UI responds" \
    bash -c "curl -sf --max-time 10 'http://localhost:4436' > /dev/null"

# Test 1.7: No database port exposed (no 5432, 3306, 27017 on host)
run_test "1.7 No database port exposed" \
    bash -c "! docker compose ps --format '{{.Ports}}' 2>/dev/null | grep -qE '(5432|3306|27017)'"

echo ""
echo "--- Results: $PASS/$TOTAL passed, $FAIL failed ---"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "=== All Phase 1 tests passed! ==="
