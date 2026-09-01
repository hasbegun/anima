#!/bin/bash
# Phase 4 Tests: End-to-End Integration
# Verifies token flows, JWKS verification, introspection, revocation, and claim validation.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_FILE="$PROJECT_DIR/bootstrap/config/agent-secrets.json"

if [ ! -f "$SECRETS_FILE" ]; then
    echo "ERROR: $SECRETS_FILE not found. Run bootstrap first."
    exit 1
fi

# Read agent creds
CLEANUP_CLIENT_ID=$(python3 -c "import json; print(json.load(open('$SECRETS_FILE'))['alert-cleanup-agent']['clientId'])")
CLEANUP_CLIENT_SECRET=$(python3 -c "import json; print(json.load(open('$SECRETS_FILE'))['alert-cleanup-agent']['clientSecret'])")
CLEANUP_AGENT_ID=$(python3 -c "import json; print(json.load(open('$SECRETS_FILE'))['alert-cleanup-agent']['agentId'])")
PIPELINE_CLIENT_ID=$(python3 -c "import json; print(json.load(open('$SECRETS_FILE'))['pipeline-scheduler-agent']['clientId'])")
PIPELINE_CLIENT_SECRET=$(python3 -c "import json; print(json.load(open('$SECRETS_FILE'))['pipeline-scheduler-agent']['clientSecret'])")

echo "=== Phase 4: End-to-End Integration Tests ==="
echo ""

# ----- 4.1: Agent token + JWKS offline verification -----

run_test "4.1 Token verified offline via JWKS (PyJWT)" \
    python3 -c "
import httpx, jwt, ssl
from jwt import PyJWKClient

client = httpx.Client(verify=False, timeout=30)
r = client.post('$BASE_URL/oauth2/token',
    auth=('$CLEANUP_CLIENT_ID', '$CLEANUP_CLIENT_SECRET'),
    data={'grant_type': 'client_credentials',
          'resource': 'https://monitoring-api.internal',
          'scope': 'alerts:read alerts:write'},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
access_token = r.json()['access_token']

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
jwks = PyJWKClient('$BASE_URL/oauth2/jwks', ssl_context=ctx)
key = jwks.get_signing_key_from_jwt(access_token)
claims = jwt.decode(access_token, key.key, algorithms=['RS256'],
                    audience='https://monitoring-api.internal')
assert claims['sub'] == '$CLEANUP_AGENT_ID'
assert claims['aud'] == 'https://monitoring-api.internal'
assert claims.get('scope') == 'alerts:read alerts:write'
assert 'jti' in claims
assert 'exp' in claims
assert 'iat' in claims
"

# ----- 4.2: Token has correct audience -----

run_test "4.2 Token audience matches resource server identifier" \
    python3 -c "
import httpx, json, base64
client = httpx.Client(verify=False, timeout=30)
r = client.post('$BASE_URL/oauth2/token',
    auth=('$PIPELINE_CLIENT_ID', '$PIPELINE_CLIENT_SECRET'),
    data={'grant_type': 'client_credentials',
          'resource': 'https://data-pipeline.internal',
          'scope': 'pipelines:read'},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
tok = r.json()['access_token']
payload = tok.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
assert claims['aud'] == 'https://data-pipeline.internal', f'wrong aud: {claims[\"aud\"]}'
"

# ----- 4.3: Wrong audience rejected by JWKS verification -----

run_test "4.3 JWKS verification rejects wrong audience" \
    python3 -c "
import httpx, jwt, ssl
from jwt import PyJWKClient

client = httpx.Client(verify=False, timeout=30)
r = client.post('$BASE_URL/oauth2/token',
    auth=('$CLEANUP_CLIENT_ID', '$CLEANUP_CLIENT_SECRET'),
    data={'grant_type': 'client_credentials',
          'resource': 'https://monitoring-api.internal',
          'scope': 'alerts:read'},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
access_token = r.json()['access_token']

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
jwks = PyJWKClient('$BASE_URL/oauth2/jwks', ssl_context=ctx)
key = jwks.get_signing_key_from_jwt(access_token)

# Verify with correct audience works
jwt.decode(access_token, key.key, algorithms=['RS256'],
           audience='https://monitoring-api.internal')

# Verify with wrong audience fails
try:
    jwt.decode(access_token, key.key, algorithms=['RS256'],
               audience='https://data-pipeline.internal')
    assert False, 'should have raised InvalidAudienceError'
except jwt.InvalidAudienceError:
    pass  # expected
"

# ----- 4.4: Token introspection returns active=true -----

run_test "4.4 Token introspection returns active=true" \
    python3 -c "
import httpx
client = httpx.Client(verify=False, timeout=30)
r = client.post('$BASE_URL/oauth2/token',
    auth=('$CLEANUP_CLIENT_ID', '$CLEANUP_CLIENT_SECRET'),
    data={'grant_type': 'client_credentials',
          'resource': 'https://monitoring-api.internal',
          'scope': 'alerts:read'},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
access_token = r.json()['access_token']

r2 = client.post('$BASE_URL/oauth2/introspect',
    auth=('$CLEANUP_CLIENT_ID', '$CLEANUP_CLIENT_SECRET'),
    data={'token': access_token},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
intro = r2.json()
assert intro.get('active') == True, f'not active: {intro}'
"

# ----- 4.5: Token revocation + introspection shows inactive -----

run_test "4.5 Revoked token introspects as inactive" \
    python3 -c "
import httpx
client = httpx.Client(verify=False, timeout=30)
r = client.post('$BASE_URL/oauth2/token',
    auth=('$CLEANUP_CLIENT_ID', '$CLEANUP_CLIENT_SECRET'),
    data={'grant_type': 'client_credentials',
          'resource': 'https://monitoring-api.internal',
          'scope': 'alerts:read'},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
access_token = r.json()['access_token']

# Revoke
r2 = client.post('$BASE_URL/oauth2/revoke',
    auth=('$CLEANUP_CLIENT_ID', '$CLEANUP_CLIENT_SECRET'),
    data={'token': access_token, 'token_type_hint': 'access_token'},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
assert r2.status_code == 200, f'revoke failed: {r2.status_code}'

# Introspect after revocation
r3 = client.post('$BASE_URL/oauth2/introspect',
    auth=('$CLEANUP_CLIENT_ID', '$CLEANUP_CLIENT_SECRET'),
    data={'token': access_token},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
intro = r3.json()
assert intro.get('active') == False, f'still active after revoke: {intro}'
"

# ----- 4.6: Revoked token still valid offline (known trade-off) -----

run_test "4.6 Revoked token still valid offline (expected trade-off)" \
    python3 -c "
import httpx, jwt, ssl
from jwt import PyJWKClient

client = httpx.Client(verify=False, timeout=30)

# Get JWKS key first
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
jwks = PyJWKClient('$BASE_URL/oauth2/jwks', ssl_context=ctx)

# Get and revoke a token
r = client.post('$BASE_URL/oauth2/token',
    auth=('$CLEANUP_CLIENT_ID', '$CLEANUP_CLIENT_SECRET'),
    data={'grant_type': 'client_credentials',
          'resource': 'https://monitoring-api.internal',
          'scope': 'alerts:read'},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
access_token = r.json()['access_token']

client.post('$BASE_URL/oauth2/revoke',
    auth=('$CLEANUP_CLIENT_ID', '$CLEANUP_CLIENT_SECRET'),
    data={'token': access_token, 'token_type_hint': 'access_token'},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})

# Offline verification still works (JWT is cryptographically valid)
key = jwks.get_signing_key_from_jwt(access_token)
claims = jwt.decode(access_token, key.key, algorithms=['RS256'],
                    audience='https://monitoring-api.internal')
assert claims['sub'] == '$CLEANUP_AGENT_ID'
"

# ----- 4.7: No auth on management endpoint returns 401 -----

run_test "4.7 No auth header on management endpoint returns 401" \
    bash -c "HTTP_CODE=\$(curl -s --insecure --max-time 10 -o /dev/null -w '%{http_code}' '$BASE_URL/roles')
    [ \"\$HTTP_CODE\" = '401' ]"

# ----- 4.8: Malformed token returns 401 -----

run_test "4.8 Malformed Bearer token returns 401" \
    bash -c "HTTP_CODE=\$(curl -s --insecure --max-time 10 -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer not.a.valid.jwt.token' '$BASE_URL/roles')
    [ \"\$HTTP_CODE\" = '401' ]"

# ----- 4.9: OIDC discovery has all required grant types -----

run_test "4.9 OIDC discovery lists all required grant types" \
    bash -c "$CURL '$BASE_URL/.well-known/openid-configuration' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
grants = d.get('grant_types_supported', [])
for g in ['client_credentials', 'authorization_code', 'refresh_token',
           'urn:ietf:params:oauth:grant-type:token-exchange']:
    assert g in grants, f'missing grant type: {g}'
\""

# ----- 4.10: Introspection endpoint requires client auth -----

run_test "4.10 Introspection endpoint rejects unauthenticated request" \
    bash -c "HTTP_CODE=\$(curl -s --insecure --max-time 10 -o /dev/null -w '%{http_code}' \
        -X POST '$BASE_URL/oauth2/introspect' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d 'token=fake-token')
    echo \"\$HTTP_CODE\" | grep -qE '^(400|401)$'"

# ----- 4.11: Revocation endpoint requires client auth -----

run_test "4.11 Revocation endpoint rejects unauthenticated request" \
    bash -c "HTTP_CODE=\$(curl -s --insecure --max-time 10 -o /dev/null -w '%{http_code}' \
        -X POST '$BASE_URL/oauth2/revoke' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d 'token=fake-token')
    echo \"\$HTTP_CODE\" | grep -qE '^(400|401)$'"

# ----- 4.12: Cross-resource-server token isolation -----

run_test "4.12 Token for monitoring-api cannot be verified against pipeline audience" \
    python3 -c "
import httpx, jwt, ssl
from jwt import PyJWKClient

client = httpx.Client(verify=False, timeout=30)

# Get monitoring token
r = client.post('$BASE_URL/oauth2/token',
    auth=('$CLEANUP_CLIENT_ID', '$CLEANUP_CLIENT_SECRET'),
    data={'grant_type': 'client_credentials',
          'resource': 'https://monitoring-api.internal',
          'scope': 'alerts:read'},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
access_token = r.json()['access_token']

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
jwks = PyJWKClient('$BASE_URL/oauth2/jwks', ssl_context=ctx)
key = jwks.get_signing_key_from_jwt(access_token)

# Verify against pipeline audience should fail
try:
    jwt.decode(access_token, key.key, algorithms=['RS256'],
               audience='https://data-pipeline.internal')
    assert False, 'should have rejected wrong audience'
except jwt.InvalidAudienceError:
    pass
"

# ----- 4.13: Token scope enforcement on different agents -----

run_test "4.13 Pipeline agent cannot get monitoring scopes" \
    python3 -c "
import httpx
client = httpx.Client(verify=False, timeout=30)
r = client.post('$BASE_URL/oauth2/token',
    auth=('$PIPELINE_CLIENT_ID', '$PIPELINE_CLIENT_SECRET'),
    data={'grant_type': 'client_credentials',
          'resource': 'https://monitoring-api.internal',
          'scope': 'alerts:read alerts:write'},
    headers={'Content-Type': 'application/x-www-form-urlencoded'})
tok = r.json()
scope = tok.get('scope', '')
assert 'alerts:read' not in scope, f'pipeline agent got monitoring scope: {scope}'
"

echo ""
echo "--- Results: $PASS/$TOTAL passed, $FAIL failed ---"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "=== All Phase 4 tests passed! ==="
