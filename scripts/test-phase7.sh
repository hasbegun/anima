#!/bin/bash
# Phase 7 Tests: Quality Audit & Bug Fixes
#
# Validates fixes for CallerIdentity.is_agent/is_human, subject_type
# consistency across all endpoints, and security checklist items.
set -euo pipefail

# Phase 7 runs on the HOST (needs access to project files for static checks)
THUNDERID_URL="${THUNDERID_URL:-https://localhost:8090}"
API_URL="${MONITORING_API_URL:-http://localhost:9100}"
CURL_TID="curl -sf --insecure --max-time 10"
CURL_API="curl -s --max-time 10"

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="$PROJECT_DIR/bootstrap/config/agent-secrets.json"

if [ ! -f "$SECRETS_FILE" ]; then
    echo "ERROR: $SECRETS_FILE not found. Run bootstrap first."
    exit 1
fi

CLEANUP_CLIENT_ID=$(python3 -c "import json; print(json.load(open('$SECRETS_FILE'))['alert-cleanup-agent']['clientId'])")
CLEANUP_CLIENT_SECRET=$(python3 -c "import json; print(json.load(open('$SECRETS_FILE'))['alert-cleanup-agent']['clientSecret'])")
CLEANUP_AGENT_ID=$(python3 -c "import json; print(json.load(open('$SECRETS_FILE'))['alert-cleanup-agent']['agentId'])")

get_token() {
    local client_id="$1"
    local client_secret="$2"
    local resource="$3"
    local scope="$4"
    $CURL_TID -X POST "$THUNDERID_URL/oauth2/token" \
        -u "$client_id:$client_secret" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "grant_type=client_credentials&resource=$resource&scope=$scope" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

echo "=== Phase 7: Quality Audit & Bug Fix Tests ==="
echo ""

# Wait for monitoring-api
echo "  Waiting for monitoring-api..."
for i in $(seq 1 15); do
    if $CURL_API "$API_URL/health" > /dev/null 2>&1; then
        echo "  monitoring-api is ready"
        break
    fi
    if [ "$i" -eq 15 ]; then echo "  ERROR: monitoring-api not reachable"; exit 1; fi
    sleep 2
done
echo ""

# Get agent tokens
AGENT_TOKEN=$(get_token "$CLEANUP_CLIENT_ID" "$CLEANUP_CLIENT_SECRET" \
    "https://monitoring-api.internal" "alerts:read alerts:write")

# ────────────────────────────────────────────
# CallerIdentity.subject_type inference tests
# ────────────────────────────────────────────

# 7.1: Agent token subject_type is "agent" (inferred from grant_type)
run_test "7.1  Agent token → subject_type is 'agent' (inferred)" \
    bash -c "
        $CURL_API -H 'Authorization: Bearer $AGENT_TOKEN' '$API_URL/whoami' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert d['subject_type'] == 'agent', f'expected agent, got {d[\"subject_type\"]}'
\"
    "

# 7.2: Verify the JWT itself has no sub_type claim (confirming we infer correctly)
run_test "7.2  JWT has no sub_type claim (ThunderID omits it)" \
    python3 -c "
import base64, json
token = '$AGENT_TOKEN'
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
assert 'sub_type' not in claims, f'sub_type unexpectedly present: {claims.get(\"sub_type\")}'
assert claims.get('grant_type') == 'client_credentials', 'expected client_credentials'
"

# 7.3: Agent token subject matches agentId from secrets
run_test "7.3  Agent token sub matches registered agentId" \
    bash -c "
        $CURL_API -H 'Authorization: Bearer $AGENT_TOKEN' '$API_URL/whoami' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert d['subject'] == '$CLEANUP_AGENT_ID', f'expected $CLEANUP_AGENT_ID, got {d[\"subject\"]}'
\"
    "

# ────────────────────────────────────────────
# subject_type consistency across all endpoints
# ────────────────────────────────────────────

# 7.4: GET /alerts returns subject_type == "agent" for agent token
run_test "7.4  GET /alerts caller.subject_type == 'agent'" \
    bash -c "
        $CURL_API -H 'Authorization: Bearer $AGENT_TOKEN' '$API_URL/alerts' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert d['caller']['subject_type'] == 'agent', f'got {d[\"caller\"][\"subject_type\"]}'
\"
    "

# 7.5: POST /alerts returns subject_type == "agent" for agent token
run_test "7.5  POST /alerts caller.subject_type == 'agent'" \
    bash -c "
        $CURL_API -X POST -H 'Authorization: Bearer $AGENT_TOKEN' '$API_URL/alerts' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert d['caller']['subject_type'] == 'agent', f'got {d[\"caller\"][\"subject_type\"]}'
\"
    "

# 7.6: GET /whoami grant_type is preserved alongside correct subject_type
run_test "7.6  /whoami returns both grant_type and correct subject_type" \
    bash -c "
        $CURL_API -H 'Authorization: Bearer $AGENT_TOKEN' '$API_URL/whoami' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert d['subject_type'] == 'agent', f'type: {d[\"subject_type\"]}'
assert d['grant_type'] == 'client_credentials', f'grant: {d[\"grant_type\"]}'
assert d['client_id'] == '$CLEANUP_CLIENT_ID', f'client: {d[\"client_id\"]}'
\"
    "

# ────────────────────────────────────────────
# CallerIdentity.is_agent / is_human property tests
# (tested via subject_type since properties drive the value)
# ────────────────────────────────────────────

# 7.7: Explicit sub_type claim (if present) takes precedence over grant_type
run_test "7.7  Explicit sub_type claim would take precedence" \
    python3 -c "
# Unit test CallerIdentity directly
import sys
sys.path.insert(0, '$PROJECT_DIR/tenant-server')
from auth import CallerIdentity

# Agent: no sub_type, grant_type=client_credentials → agent
agent_claims = {'sub': 'a1', 'grant_type': 'client_credentials', 'scope': 'x'}
ci = CallerIdentity(agent_claims)
assert ci.subject_type == 'agent', f'no sub_type + cc should be agent, got {ci.subject_type}'
assert ci.is_agent == True
assert ci.is_human == False

# User: no sub_type, grant_type=authorization_code → user
user_claims = {'sub': 'u1', 'grant_type': 'authorization_code', 'scope': 'x'}
ci2 = CallerIdentity(user_claims)
assert ci2.subject_type == 'user', f'no sub_type + ac should be user, got {ci2.subject_type}'
assert ci2.is_agent == False
assert ci2.is_human == True

# Explicit sub_type overrides grant_type
override_claims = {'sub': 's1', 'sub_type': 'service', 'grant_type': 'client_credentials', 'scope': 'x'}
ci3 = CallerIdentity(override_claims)
assert ci3.subject_type == 'service', f'explicit sub_type should win, got {ci3.subject_type}'
assert ci3.is_agent == False  # 'service' is not 'agent'
assert ci3.is_human == False  # 'service' is not 'user'

# Explicit sub_type=agent with non-cc grant_type (delegated agent)
deleg_claims = {'sub': 'd1', 'sub_type': 'agent', 'grant_type': 'authorization_code', 'scope': 'x'}
ci4 = CallerIdentity(deleg_claims)
assert ci4.subject_type == 'agent', f'explicit agent should win, got {ci4.subject_type}'
assert ci4.is_agent == True
assert ci4.is_human == False
"

# ────────────────────────────────────────────
# Security checklist verification
# ────────────────────────────────────────────

# 7.8: .env is in .gitignore
run_test "7.8  .env is in .gitignore" \
    bash -c "grep -q '^\.env$' '$PROJECT_DIR/.gitignore'"

# 7.9: setup-output.txt is in .gitignore
run_test "7.9  setup-output.txt is in .gitignore" \
    bash -c "grep -q 'setup-output.txt' '$PROJECT_DIR/.gitignore'"

# 7.10: agent-secrets.json is in .gitignore
run_test "7.10 agent-secrets.json is in .gitignore" \
    bash -c "grep -q 'agent-secrets.json' '$PROJECT_DIR/.gitignore'"

# 7.11: ThunderID image pinned to v1.0.1 (not latest)
run_test "7.11 ThunderID image pinned to v1.0.1" \
    bash -c "
        grep -q 'thunderid:1.0.1' '$PROJECT_DIR/docker-compose.yml'
        ! grep -q 'thunderid:latest' '$PROJECT_DIR/docker-compose.yml'
    "

# 7.12: JWKS cache is configured with reasonable TTL
run_test "7.12 JWKS cache TTL configured (lifespan=3600)" \
    bash -c "
        grep -q 'cache_jwk_set=True' '$PROJECT_DIR/tenant-server/auth.py'
        grep -q 'lifespan=3600' '$PROJECT_DIR/tenant-server/auth.py'
    "

# 7.13: CORS not using wildcard
run_test "7.13 CORS uses explicit origins, not wildcard" \
    bash -c "
        grep -q 'CORS_ORIGINS' '$PROJECT_DIR/tenant-server/main.py'
        ! grep -q 'allow_origins=\[\"\\*\"\]' '$PROJECT_DIR/tenant-server/main.py'
    "

# 7.14: Docker services have restart policies
run_test "7.14 Docker restart policies set" \
    bash -c "
        grep -c 'restart:' '$PROJECT_DIR/docker-compose.yml' | python3 -c \"
import sys
count = int(sys.stdin.read().strip())
assert count >= 3, f'only {count} restart policies found'
\"
    "

# 7.15: .env.example exists
run_test "7.15 .env.example exists" \
    bash -c "[ -f '$PROJECT_DIR/.env.example' ]"

echo ""
echo "--- Results: $PASS/$TOTAL passed, $FAIL failed ---"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "=== All Phase 7 tests passed! ==="
