#!/bin/bash
# Phase 3 Tests: Agent Identity
# Verifies that agents are created, can obtain tokens, and scope enforcement works.
set -euo pipefail

BASE_URL="${THUNDERID_URL:-https://localhost:8090}"
PUBLIC_URL="${THUNDERID_PUBLIC_URL:-https://localhost:8090}"
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

# Locate project root and secrets
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="$PROJECT_DIR/bootstrap/config/agent-secrets.json"

if [ ! -f "$SECRETS_FILE" ]; then
    echo "ERROR: $SECRETS_FILE not found. Run bootstrap first."
    exit 1
fi

# Obtain admin token
TOKEN=$(cd "$PROJECT_DIR/bootstrap" && python3 -c "
import os
from auth import get_admin_token
print(get_admin_token(
    os.getenv('THUNDERID_URL', 'https://localhost:8090'),
    'admin',
    os.getenv('ADMIN_PASSWORD', ''),
    public_url=os.getenv('THUNDERID_PUBLIC_URL', 'https://localhost:8090'),
))
")
AUTH="Authorization: Bearer $TOKEN"

# Helper: extract agent secrets
agent_creds() {
    local agent_name="$1"
    python3 -c "
import json
with open('$SECRETS_FILE') as f:
    s = json.load(f)
a = s['$agent_name']
print(a['clientId'])
print(a['clientSecret'])
print(a['agentId'])
print(a['mode'])
"
}

echo "=== Phase 3: Agent Identity Tests ==="
echo ""

# ----- Agent Creation -----

run_test "3.1 Agent 'alert-cleanup-agent' exists" \
    bash -c "$CURL -H '$AUTH' '$BASE_URL/agents' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert any(a['name'] == 'alert-cleanup-agent' for a in d['agents']), 'not found'
\""

run_test "3.2 Agent 'pipeline-scheduler-agent' exists" \
    bash -c "$CURL -H '$AUTH' '$BASE_URL/agents' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert any(a['name'] == 'pipeline-scheduler-agent' for a in d['agents']), 'not found'
\""

ASSISTANT_AGENT_ID=$(python3 -c "import json; print(json.load(open('$SECRETS_FILE'))['monitoring-assistant']['agentId'])")

run_test "3.3 Agent 'monitoring-assistant' is delegated (auth_code + PKCE)" \
    bash -c "$CURL -H '$AUTH' '$BASE_URL/agents/$ASSISTANT_AGENT_ID' | python3 -c \"
import sys, json
agent = json.load(sys.stdin)
oauth = agent['inboundAuthConfig'][0]['config']
assert 'authorization_code' in oauth['grantTypes'], 'missing auth_code grant'
assert oauth.get('pkceRequired') == True, 'pkce not required'
assert 'http://localhost:3000/callback' in oauth.get('redirectUris', []), 'missing redirect URI'
\""

run_test "3.4 Agent secrets file exists with 3 agents" \
    bash -c "python3 -c \"
import json
with open('$SECRETS_FILE') as f:
    s = json.load(f)
assert len(s) == 3, f'expected 3, got {len(s)}'
for name in ['alert-cleanup-agent', 'pipeline-scheduler-agent', 'monitoring-assistant']:
    assert name in s, f'missing {name}'
    assert s[name].get('clientId'), f'{name} missing clientId'
    assert s[name].get('clientSecret'), f'{name} missing clientSecret'
\""

# ----- Token via client_credentials -----

CREDS=($(agent_creds "alert-cleanup-agent"))
CLEANUP_CLIENT_ID="${CREDS[0]}"
CLEANUP_CLIENT_SECRET="${CREDS[1]}"
CLEANUP_AGENT_ID="${CREDS[2]}"

run_test "3.5 Autonomous agent gets token via client_credentials" \
    bash -c "curl -sf --insecure --max-time 10 -X POST '$BASE_URL/oauth2/token' \
        -u '$CLEANUP_CLIENT_ID:$CLEANUP_CLIENT_SECRET' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read alerts:write' \
        | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert 'access_token' in d, 'no access_token'
assert d.get('scope') == 'alerts:read alerts:write', f'wrong scope: {d.get(\"scope\")}'
\""

run_test "3.6 Agent token has correct JWT claims" \
    bash -c "curl -sf --insecure --max-time 10 -X POST '$BASE_URL/oauth2/token' \
        -u '$CLEANUP_CLIENT_ID:$CLEANUP_CLIENT_SECRET' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read' \
        | python3 -c \"
import sys, json, base64
tok = json.load(sys.stdin)['access_token']
payload = tok.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
assert claims['sub'] == '$CLEANUP_AGENT_ID', f'wrong sub: {claims[\"sub\"]}'
assert claims['aud'] == 'https://monitoring-api.internal', f'wrong aud'
assert claims['grant_type'] == 'client_credentials', f'wrong grant_type'
assert 'jti' in claims, 'missing jti'
assert 'exp' in claims, 'missing exp'
assert claims.get('scope') == 'alerts:read', f'wrong scope: {claims.get(\"scope\")}'
\""

# ----- Wrong secret -----

run_test "3.7 Agent with wrong secret gets 401" \
    bash -c "HTTP_CODE=\$(curl -s --insecure --max-time 10 -o /dev/null -w '%{http_code}' \
        -X POST '$BASE_URL/oauth2/token' \
        -u '$CLEANUP_CLIENT_ID:wrong-secret-here' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read')
    [ \"\$HTTP_CODE\" = '401' ]"

# ----- Scope downscoping -----

run_test "3.8 Agent requesting disallowed scope gets downscoped" \
    bash -c "curl -sf --insecure --max-time 10 -X POST '$BASE_URL/oauth2/token' \
        -u '$CLEANUP_CLIENT_ID:$CLEANUP_CLIENT_SECRET' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read alerts:delete' \
        | python3 -c \"
import sys, json
d = json.load(sys.stdin)
scope = d.get('scope', '')
assert 'alerts:read' in scope, 'missing alerts:read'
assert 'alerts:delete' not in scope, 'alerts:delete should be downscoped'
\""

# ----- Pipeline agent -----

CREDS2=($(agent_creds "pipeline-scheduler-agent"))
PIPELINE_CLIENT_ID="${CREDS2[0]}"
PIPELINE_CLIENT_SECRET="${CREDS2[1]}"

run_test "3.9 Pipeline agent gets token with correct scopes" \
    bash -c "curl -sf --insecure --max-time 10 -X POST '$BASE_URL/oauth2/token' \
        -u '$PIPELINE_CLIENT_ID:$PIPELINE_CLIENT_SECRET' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d 'grant_type=client_credentials&resource=https://data-pipeline.internal&scope=pipelines:read pipelines:run' \
        | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert d.get('scope') == 'pipelines:read pipelines:run', f'wrong scope: {d.get(\"scope\")}'
\""

# ----- Delegated agent has client_credentials too -----

CREDS3=($(agent_creds "monitoring-assistant"))
ASSISTANT_CLIENT_ID="${CREDS3[0]}"
ASSISTANT_CLIENT_SECRET="${CREDS3[1]}"

run_test "3.10 Delegated agent can also use client_credentials" \
    bash -c "curl -sf --insecure --max-time 10 -X POST '$BASE_URL/oauth2/token' \
        -u '$ASSISTANT_CLIENT_ID:$ASSISTANT_CLIENT_SECRET' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read dashboards:read' \
        | python3 -c \"
import sys, json
d = json.load(sys.stdin)
assert 'access_token' in d, 'no access_token'
\""

# ----- Idempotency -----

run_test "3.11 Bootstrap is idempotent with agents" \
    bash -c "cd '$PROJECT_DIR/bootstrap' && python3 bootstrap.py > /dev/null 2>&1"

echo ""
echo "--- Results: $PASS/$TOTAL passed, $FAIL failed ---"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "=== All Phase 3 tests passed! ==="
