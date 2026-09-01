#!/bin/bash
# Phase 2 Tests: Bootstrap verification
# Verifies that tenants, resource servers, roles, and seed users exist.
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

# Obtain admin access token
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
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

# Helper: run a python assertion against an API endpoint
api_assert() {
    local endpoint="$1"
    local assertion="$2"
    $CURL -H "$AUTH" "$BASE_URL/$endpoint" | python3 -c "
import sys, json
d = json.load(sys.stdin)
$assertion
"
}

echo "=== Phase 2: Bootstrap Tests ==="
echo ""

# ----- Tenants -----

run_test "2.1 Tenant 'monitoring-api' exists" \
    api_assert "organization-units" \
    "assert 'monitoring-api' in [ou['handle'] for ou in d['organizationUnits']]"

run_test "2.2 Tenant 'data-pipeline' exists" \
    api_assert "organization-units" \
    "assert 'data-pipeline' in [ou['handle'] for ou in d['organizationUnits']]"

run_test "2.3 Tenant 'deploy-tool' exists" \
    api_assert "organization-units" \
    "assert 'deploy-tool' in [ou['handle'] for ou in d['organizationUnits']]"

# ----- Resource Servers -----

run_test "2.4 RS 'monitoring-api.internal' exists" \
    api_assert "resource-servers" \
    "assert 'https://monitoring-api.internal' in [rs['identifier'] for rs in d['resourceServers']]"

run_test "2.5 RS 'data-pipeline.internal' exists" \
    api_assert "resource-servers" \
    "assert 'https://data-pipeline.internal' in [rs['identifier'] for rs in d['resourceServers']]"

run_test "2.6 RS 'deploy-tool.internal' exists" \
    api_assert "resource-servers" \
    "assert 'https://deploy-tool.internal' in [rs['identifier'] for rs in d['resourceServers']]"

# ----- Permissions (check via API) -----

run_test "2.7 Monitoring API has alerts:read action" \
    bash -c "
RS_ID=\$($CURL -H '$AUTH' '$BASE_URL/resource-servers' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
rs = next(r for r in d['resourceServers'] if r['identifier'] == 'https://monitoring-api.internal')
print(rs['id'])
\")
RES_ID=\$($CURL -H '$AUTH' '$BASE_URL/resource-servers/'\"\$RS_ID\"'/resources' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
res = next(r for r in d['resources'] if r['handle'] == 'alerts')
print(res['id'])
\")
$CURL -H '$AUTH' '$BASE_URL/resource-servers/'\"\$RS_ID\"'/resources/'\"\$RES_ID\"'/actions' | python3 -c \"
import sys, json
d = json.load(sys.stdin)
handles = [a['handle'] for a in d['actions']]
assert 'read' in handles, f'missing read in {handles}'
\"
"

run_test "2.8 At least 14 actions across resource servers" \
    bash -c "$CURL -H '$AUTH' '$BASE_URL/resource-servers' | python3 -c \"
import sys, json, ssl, urllib.request
d = json.load(sys.stdin)
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
total = 0
for rs in d['resourceServers']:
    if 'mcp' in rs['identifier']:
        continue
    rid = rs['id']
    req = urllib.request.Request('$BASE_URL/resource-servers/' + rid + '/resources',
        headers={'Authorization': 'Bearer $TOKEN'})
    with urllib.request.urlopen(req, context=ctx) as resp:
        resources = json.load(resp)
    for res in resources.get('resources', []):
        req2 = urllib.request.Request(
            '$BASE_URL/resource-servers/' + rid + '/resources/' + res['id'] + '/actions',
            headers={'Authorization': 'Bearer $TOKEN'})
        with urllib.request.urlopen(req2, context=ctx) as resp2:
            actions = json.load(resp2)
        total += len(actions.get('actions', []))
assert total >= 14, f'only {total} actions found'
\""

# ----- Roles -----

run_test "2.9 Role 'monitoring-admin' exists in monitoring-api" \
    api_assert "roles" \
    "assert any(r['name'] == 'monitoring-admin' and r['ouHandle'] == 'monitoring-api' for r in d['roles'])"

run_test "2.10 Role 'pipeline-admin' exists in data-pipeline" \
    api_assert "roles" \
    "assert any(r['name'] == 'pipeline-admin' and r['ouHandle'] == 'data-pipeline' for r in d['roles'])"

run_test "2.11 At least 6 custom roles exist" \
    api_assert "roles" \
    "assert len([r for r in d['roles'] if r['name'] != 'Administrator']) >= 6"

# ----- Seed Users (check via API) -----

check_user_exists() {
    local email="$1"
    $CURL -H "$AUTH" "$BASE_URL/users" | python3 -c "
import sys, json, ssl, urllib.request
d = json.load(sys.stdin)
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
found = False
for u in d['users']:
    req = urllib.request.Request('$BASE_URL/users/' + u['id'],
        headers={'Authorization': 'Bearer $TOKEN'})
    with urllib.request.urlopen(req, context=ctx) as resp:
        detail = json.load(resp)
    if (detail.get('attributes') or {}).get('email') == '$email':
        found = True
        break
assert found, '$email not found'
"
}

run_test "2.12 Seed user 'alice@company.com' exists" \
    check_user_exists "alice@company.com"

run_test "2.13 Seed user 'bob@company.com' exists" \
    check_user_exists "bob@company.com"

run_test "2.14 Seed user 'sysadmin@company.com' exists" \
    check_user_exists "sysadmin@company.com"

# ----- Idempotency -----

run_test "2.15 Bootstrap is idempotent" \
    bash -c "cd '$PROJECT_DIR/bootstrap' && python3 bootstrap.py > /dev/null 2>&1"

run_test "2.16 Seed is idempotent" \
    bash -c "cd '$PROJECT_DIR/bootstrap' && python3 seed_users.py > /dev/null 2>&1"

echo ""
echo "--- Results: $PASS/$TOTAL passed, $FAIL failed ---"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "=== All Phase 2 tests passed! ==="
