#!/bin/bash
# Phase 2 Tests: Bootstrap verification
# Verifies that tenants, resource servers, roles, and seed users exist.
set -euo pipefail

BASE_URL="${THUNDERID_URL:-https://localhost:8090}"
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

# ----- Permissions (check via DB) -----

run_test "2.7 Monitoring API has alerts:read permission" \
    bash -c "docker compose exec thunderid sqlite3 database/configdb.db \
    \"SELECT COUNT(*) FROM ACTION A JOIN RESOURCE_SERVER RS ON A.RESOURCE_SERVER_ID = RS.ID WHERE RS.IDENTIFIER='https://monitoring-api.internal' AND A.PERMISSION='alerts:read';\" \
    | grep -q '^1$'"

run_test "2.8 At least 14 actions exist across custom resource servers" \
    bash -c "docker compose exec thunderid sqlite3 database/configdb.db \
    \"SELECT COUNT(*) FROM ACTION A JOIN RESOURCE_SERVER RS ON A.RESOURCE_SERVER_ID = RS.ID WHERE RS.IDENTIFIER != 'https://localhost:8090/mcp';\" \
    | python3 -c 'import sys; assert int(sys.stdin.read().strip()) >= 14'"

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

# ----- Role Permissions (via DB) -----

run_test "2.12 monitoring-admin has 6 permissions" \
    bash -c "docker compose exec thunderid sqlite3 database/configdb.db \
    \"SELECT COUNT(*) FROM ROLE_PERMISSION RP JOIN ROLE R ON RP.ROLE_ID = R.ID WHERE R.NAME='monitoring-admin';\" \
    | grep -q '^6$'"

run_test "2.13 monitoring-viewer has 2 permissions" \
    bash -c "docker compose exec thunderid sqlite3 database/configdb.db \
    \"SELECT COUNT(*) FROM ROLE_PERMISSION RP JOIN ROLE R ON RP.ROLE_ID = R.ID WHERE R.NAME='monitoring-viewer';\" \
    | grep -q '^2$'"

# ----- Seed Users -----

run_test "2.14 Seed user 'alice@company.com' exists" \
    bash -c "docker compose exec thunderid sqlite3 database/entitydb.db \
    \"SELECT COUNT(*) FROM ENTITY_IDENTIFIER WHERE NAME='email' AND VALUE='alice@company.com';\" \
    | grep -q '^1$'"

run_test "2.15 Seed user 'bob@company.com' exists" \
    bash -c "docker compose exec thunderid sqlite3 database/entitydb.db \
    \"SELECT COUNT(*) FROM ENTITY_IDENTIFIER WHERE NAME='email' AND VALUE='bob@company.com';\" \
    | grep -q '^1$'"

run_test "2.16 Seed user 'sysadmin@company.com' exists" \
    bash -c "docker compose exec thunderid sqlite3 database/entitydb.db \
    \"SELECT COUNT(*) FROM ENTITY_IDENTIFIER WHERE NAME='email' AND VALUE='sysadmin@company.com';\" \
    | grep -q '^1$'"

# ----- Idempotency -----

run_test "2.17 Bootstrap is idempotent" \
    bash -c "cd '$PROJECT_DIR/bootstrap' && ADMIN_PASSWORD='${ADMIN_PASSWORD}' python3 bootstrap.py > /dev/null 2>&1"

run_test "2.18 Seed is idempotent" \
    bash -c "cd '$PROJECT_DIR/bootstrap' && ADMIN_PASSWORD='${ADMIN_PASSWORD}' python3 seed_users.py > /dev/null 2>&1"

echo ""
echo "--- Results: $PASS/$TOTAL passed, $FAIL failed ---"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "=== All Phase 2 tests passed! ==="
