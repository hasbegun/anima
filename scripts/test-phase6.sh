#!/bin/bash
# Phase 6 Tests: Operations — Logging, CORS, Backup/Restore
#
# These tests run on the HOST (not inside toolbox) because they need
# docker compose access for log inspection and backup/restore.
set -euo pipefail

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

# ── Helper: get a token ──
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

echo "=== Phase 6: Operations Tests ==="
echo ""

# ── Wait for monitoring-api ──
echo "  Waiting for monitoring-api..."
for i in $(seq 1 15); do
    if $CURL_API "$API_URL/health" > /dev/null 2>&1; then
        echo "  monitoring-api is ready"
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "  ERROR: monitoring-api not reachable at $API_URL"
        exit 1
    fi
    sleep 2
done
echo ""

# ────────────────────────────────────────────
# Audit Logging Tests
# ────────────────────────────────────────────

# Clear old logs by truncating
docker compose logs monitoring-api --since 1s > /dev/null 2>&1

# Trigger auth_denied
$CURL_API "$API_URL/alerts" > /dev/null 2>&1 || true
sleep 1

# 6.1: auth_denied log is valid structured JSON
run_test "6.1  Audit log: auth_denied is structured JSON" \
    bash -c "
        cd '$PROJECT_DIR'
        docker compose logs monitoring-api --tail 20 2>&1 | grep 'auth_denied' | head -1 | \
            python3 -c \"
import sys, json, re
line = sys.stdin.read().strip()
idx = line.find('{')
entry = json.loads(line[idx:])
assert entry.get('event') == 'auth_denied'
assert 'timestamp' in entry
assert entry.get('service') == 'monitoring-api'
assert entry.get('decision') == 'denied'
assert 'request_id' in entry
assert 'endpoint' in entry
assert 'method' in entry
\"
    "

# Trigger auth_allowed
AGENT_TOKEN=$(get_token "$CLEANUP_CLIENT_ID" "$CLEANUP_CLIENT_SECRET" \
    "https://monitoring-api.internal" "alerts:read")
$CURL_API -H "Authorization: Bearer $AGENT_TOKEN" "$API_URL/alerts" > /dev/null 2>&1
sleep 1

# 6.2: auth_allowed log has subject, scopes, and timing
run_test "6.2  Audit log: auth_allowed has identity + timing" \
    bash -c "
        cd '$PROJECT_DIR'
        docker compose logs monitoring-api --tail 20 2>&1 | grep 'auth_allowed' | tail -1 | \
            python3 -c \"
import sys, json
line = sys.stdin.read().strip()
idx = line.find('{')
entry = json.loads(line[idx:])
assert entry.get('event') == 'auth_allowed'
assert 'subject' in entry
assert entry.get('subject_type') == 'agent'
assert 'scopes' in entry
assert isinstance(entry['scopes'], list)
assert 'verify_ms' in entry
assert isinstance(entry['verify_ms'], (int, float))
assert 'client_id' in entry
\"
    "

# Trigger scope_denied
$CURL_API -X DELETE -H "Authorization: Bearer $AGENT_TOKEN" "$API_URL/alerts/x" > /dev/null 2>&1
sleep 1

# 6.3: scope_denied log shows required vs actual scopes
run_test "6.3  Audit log: scope_denied shows required vs actual" \
    bash -c "
        cd '$PROJECT_DIR'
        docker compose logs monitoring-api --tail 20 2>&1 | grep 'scope_denied' | tail -1 | \
            python3 -c \"
import sys, json
line = sys.stdin.read().strip()
idx = line.find('{')
entry = json.loads(line[idx:])
assert entry.get('event') == 'scope_denied'
assert entry.get('reason') == 'insufficient_scope'
assert 'required_scopes' in entry
assert 'actual_scopes' in entry
assert 'alerts:delete' in entry['required_scopes']
\"
    "

# ────────────────────────────────────────────
# CORS Tests
# ────────────────────────────────────────────

# 6.4: CORS preflight from allowed origin returns 200
run_test "6.4  CORS preflight from allowed origin → 200" \
    bash -c "
        CODE=\$($CURL_API -o /dev/null -w '%{http_code}' -X OPTIONS \
            -H 'Origin: https://localhost:3000' \
            -H 'Access-Control-Request-Method: GET' \
            -H 'Access-Control-Request-Headers: Authorization' \
            '$API_URL/alerts')
        [ \"\$CODE\" = '200' ]
    "

# 6.5: CORS response includes correct headers for allowed origin
run_test "6.5  CORS headers present for allowed origin" \
    bash -c "
        HEADERS=\$($CURL_API -I -H 'Origin: https://localhost:3000' '$API_URL/health')
        echo \"\$HEADERS\" | grep -qi 'access-control-allow-origin: https://localhost:3000'
        echo \"\$HEADERS\" | grep -qi 'access-control-allow-credentials: true'
    "

# 6.6: CORS does not return allow-origin for disallowed origin
run_test "6.6  CORS no allow-origin for disallowed origin" \
    bash -c "
        HEADERS=\$($CURL_API -I -H 'Origin: https://evil.com' '$API_URL/health')
        ! echo \"\$HEADERS\" | grep -qi 'access-control-allow-origin: https://evil.com'
    "

# ────────────────────────────────────────────
# Backup Tests
# ────────────────────────────────────────────

# 6.7: Backup script produces a valid tarball
run_test "6.7  Backup script creates valid tarball" \
    bash -c "
        cd '$PROJECT_DIR'
        bash scripts/backup-db.sh > /dev/null 2>&1
        LATEST=\$(ls -t backups/thunderid_*.tar.gz 2>/dev/null | head -1)
        [ -n \"\$LATEST\" ] && tar -tzf \"\$LATEST\" > /dev/null 2>&1
    "

# 6.8: Backup contains all required files
run_test "6.8  Backup contains databases, certs, and secrets" \
    bash -c "
        cd '$PROJECT_DIR'
        LATEST=\$(ls -t backups/thunderid_*.tar.gz 2>/dev/null | head -1)
        FILES=\$(tar -tzf \"\$LATEST\")
        echo \"\$FILES\" | grep -q 'configdb.db'
        echo \"\$FILES\" | grep -q 'entitydb.db'
        echo \"\$FILES\" | grep -q 'runtime_persistent.db'
        echo \"\$FILES\" | grep -q 'runtime_transient.db'
        echo \"\$FILES\" | grep -q 'certs/signing.key'
        echo \"\$FILES\" | grep -q 'secrets/direct_auth_secret'
    "

# 6.9: Backup/restore round-trip preserves data
run_test "6.9  Backup/restore round-trip preserves data" \
    bash -c "
        cd '$PROJECT_DIR'

        # Create a fresh backup
        bash scripts/backup-db.sh > /dev/null 2>&1
        BACKUP=\$(ls -t backups/thunderid_*.tar.gz 2>/dev/null | head -1)

        # Restore from that backup
        CONFIRM=yes bash scripts/restore-db.sh \"\$BACKUP\" > /dev/null 2>&1

        # Verify ThunderID is healthy
        for i in \$(seq 1 20); do
            status=\$(docker inspect sigil-thunderid-1 --format '{{.State.Health.Status}}' 2>/dev/null)
            [ \"\$status\" = 'healthy' ] && break
            sleep 5
        done
        [ \"\$status\" = 'healthy' ]

        # Verify OIDC discovery works
        curl -sf --insecure --max-time 10 '$THUNDERID_URL/.well-known/openid-configuration' > /dev/null

        # Verify agents still exist (data survived restore)
        curl -sf --insecure --max-time 10 -X POST '$THUNDERID_URL/oauth2/token' \
            -u '$CLEANUP_CLIENT_ID:$CLEANUP_CLIENT_SECRET' \
            -H 'Content-Type: application/x-www-form-urlencoded' \
            -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read' \
            | python3 -c 'import sys,json; assert \"access_token\" in json.load(sys.stdin)'
    "

echo ""
echo "--- Results: $PASS/$TOTAL passed, $FAIL failed ---"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "=== All Phase 6 tests passed! ==="
