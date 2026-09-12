#!/bin/bash
# Upgrade ThunderID to a new version with automated backup, validation,
# and rollback on failure.
#
# Usage:
#   bash scripts/upgrade.sh <new_version>           # Full upgrade
#   bash scripts/upgrade.sh <new_version> --check    # Pre-flight check only
#   bash scripts/upgrade.sh --rollback               # Rollback last upgrade
#
# Examples:
#   bash scripts/upgrade.sh 1.1.0
#   bash scripts/upgrade.sh 1.1.0 --check
#   bash scripts/upgrade.sh --rollback
#
# Environment:
#   ADMIN_PASSWORD   Required for bootstrap/test verification
#   SKIP_TESTS       Set to "true" to skip test suite after upgrade
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

COMPOSE_FILE="docker-compose.yml"
TEST_SCRIPT="scripts/test-phase7.sh"
IMAGE_BASE="ghcr.io/thunder-id/thunderid"
CONTAINER="sigil-thunderid-1"
ROLLBACK_STATE_FILE=".upgrade-rollback-state"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

info()  { echo "  $*"; }
step()  { echo ""; echo "--- $* ---"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "  ✗ $*" >&2; }

get_current_version() {
    grep "image: ${IMAGE_BASE}:" "$COMPOSE_FILE" \
        | head -1 \
        | sed "s|.*${IMAGE_BASE}:||" \
        | tr -d '[:space:]'
}

wait_for_healthy() {
    local timeout="${1:-120}"
    local interval=5
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local status
        status=$(docker inspect "$CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null || echo "not_found")
        if [ "$status" = "healthy" ]; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

# ──────────────────────────────────────────────
# Rollback
# ──────────────────────────────────────────────

do_rollback() {
    step "Rolling back upgrade"

    if [ ! -f "$ROLLBACK_STATE_FILE" ]; then
        fail "No rollback state found ($ROLLBACK_STATE_FILE)"
        echo ""
        echo "If you need to restore from a backup manually:"
        echo "  1. Edit $COMPOSE_FILE to set the old image version"
        echo "  2. make restore FILE=backups/<your_backup>.tar.gz"
        exit 1
    fi

    # Read rollback state
    local old_version old_backup
    old_version=$(grep '^OLD_VERSION=' "$ROLLBACK_STATE_FILE" | cut -d= -f2)
    old_backup=$(grep '^BACKUP_FILE=' "$ROLLBACK_STATE_FILE" | cut -d= -f2)

    info "Reverting to version: $old_version"
    info "Backup file: $old_backup"

    # Revert the image tag
    sed -i "s|${IMAGE_BASE}:[^ ]*|${IMAGE_BASE}:${old_version}|g" "$COMPOSE_FILE"
    ok "Reverted $COMPOSE_FILE to $old_version"

    # Revert the test assertion
    if [ -f "$TEST_SCRIPT" ]; then
        sed -i "s|thunderid:[^ '\"]*|thunderid:${old_version}|g" "$TEST_SCRIPT"
        ok "Reverted $TEST_SCRIPT to $old_version"
    fi

    # Restore from backup if it exists
    if [ -n "$old_backup" ] && [ -f "$old_backup" ]; then
        info "Restoring data from backup..."
        CONFIRM=yes bash scripts/restore-db.sh "$old_backup"
        ok "Data restored from $old_backup"
    else
        # Just restart with the old image
        info "No backup to restore, restarting with old image..."
        docker compose stop thunderid 2>/dev/null || true
        docker compose up -d thunderid
        if wait_for_healthy 120; then
            ok "ThunderID is healthy"
        else
            fail "ThunderID did not become healthy"
            exit 1
        fi
    fi

    # Clean up rollback state
    rm -f "$ROLLBACK_STATE_FILE"
    ok "Rollback complete"
    echo ""
    echo "Rolled back to ThunderID $old_version"
    echo "Verify: make status"
}

# ──────────────────────────────────────────────
# Pre-flight check
# ──────────────────────────────────────────────

do_check() {
    local new_version="$1"
    local current_version
    current_version=$(get_current_version)

    step "Pre-flight check: $current_version → $new_version"

    # Check if already on this version
    if [ "$current_version" = "$new_version" ]; then
        info "Already on version $new_version — nothing to upgrade"
        exit 0
    fi

    # Check the new image exists
    info "Pulling image ${IMAGE_BASE}:${new_version}..."
    if docker pull "${IMAGE_BASE}:${new_version}" > /dev/null 2>&1; then
        ok "Image ${IMAGE_BASE}:${new_version} exists and pulled"
    else
        fail "Image ${IMAGE_BASE}:${new_version} not found"
        echo ""
        echo "Check available versions at:"
        echo "  https://github.com/thunder-id/thunderid/pkgs/container/thunderid"
        exit 1
    fi

    # Check ADMIN_PASSWORD is set
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
        fail "ADMIN_PASSWORD not set (required for bootstrap verification)"
        echo "  Set it: export ADMIN_PASSWORD=<password>"
        exit 1
    fi

    # Check ThunderID is currently running and healthy
    local status
    status=$(docker inspect "$CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null || echo "not_found")
    if [ "$status" = "healthy" ]; then
        ok "ThunderID is currently healthy"
    else
        fail "ThunderID is not healthy (status: $status)"
        echo "  Start it first: make setup"
        exit 1
    fi

    # Check for uncommitted changes to compose/test files
    if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; then
        if git diff --name-only | grep -qE "(docker-compose|test-phase7)"; then
            fail "Uncommitted changes to $COMPOSE_FILE or $TEST_SCRIPT"
            echo "  Commit or stash them first"
            exit 1
        else
            ok "No uncommitted changes to upgrade-affected files"
        fi
    fi

    # Estimate files to change
    local compose_count
    compose_count=$(grep -c "${IMAGE_BASE}:${current_version}" "$COMPOSE_FILE")
    info "Files to update:"
    info "  $COMPOSE_FILE — $compose_count image reference(s)"
    info "  $TEST_SCRIPT — version assertion"

    echo ""
    echo "Pre-flight check passed. Ready to upgrade."
    echo "  Run: ADMIN_PASSWORD=<pw> bash scripts/upgrade.sh $new_version"
}

# ──────────────────────────────────────────────
# Full upgrade
# ──────────────────────────────────────────────

do_upgrade() {
    local new_version="$1"
    local current_version
    current_version=$(get_current_version)

    echo "==========================================="
    echo "  ThunderID Upgrade: $current_version → $new_version"
    echo "==========================================="

    # Validate
    if [ "$current_version" = "$new_version" ]; then
        info "Already on version $new_version — nothing to upgrade"
        exit 0
    fi

    if [ -z "${ADMIN_PASSWORD:-}" ]; then
        fail "ADMIN_PASSWORD not set"
        echo "  Usage: ADMIN_PASSWORD=<pw> bash scripts/upgrade.sh $new_version"
        exit 1
    fi

    # Step 1: Pull the new image first (fail fast if it doesn't exist)
    step "Step 1/8: Pull new image"
    if docker pull "${IMAGE_BASE}:${new_version}" > /dev/null 2>&1; then
        ok "Pulled ${IMAGE_BASE}:${new_version}"
    else
        fail "Image ${IMAGE_BASE}:${new_version} not found"
        exit 1
    fi

    # Step 2: Create backup
    step "Step 2/8: Create backup"
    local backup_file
    backup_file=$(bash scripts/backup-db.sh 2>&1 | grep "Backup created:" | sed 's/.*: //' | awk '{print $1}')
    if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
        ok "Backup created: $backup_file"
    else
        fail "Backup failed"
        exit 1
    fi

    # Save rollback state
    cat > "$ROLLBACK_STATE_FILE" <<ROLLBACK_EOF
OLD_VERSION=$current_version
NEW_VERSION=$new_version
BACKUP_FILE=$backup_file
TIMESTAMP=$(date -Iseconds)
ROLLBACK_EOF
    ok "Rollback state saved to $ROLLBACK_STATE_FILE"

    # Step 3: Update image tag in docker-compose.yml
    step "Step 3/8: Update image tag"
    sed -i "s|${IMAGE_BASE}:${current_version}|${IMAGE_BASE}:${new_version}|g" "$COMPOSE_FILE"
    local replaced
    replaced=$(grep -c "${IMAGE_BASE}:${new_version}" "$COMPOSE_FILE")
    ok "Updated $replaced image reference(s) in $COMPOSE_FILE"

    # Step 4: Update version assertion in test script
    step "Step 4/8: Update test assertion"
    if [ -f "$TEST_SCRIPT" ]; then
        sed -i "s|thunderid:${current_version}|thunderid:${new_version}|g" "$TEST_SCRIPT"
        ok "Updated version in $TEST_SCRIPT"
    fi

    # Step 5: Restart ThunderID
    step "Step 5/8: Restart ThunderID"
    docker compose stop thunderid monitoring-api 2>/dev/null || true
    docker compose up -d thunderid
    info "Waiting for ThunderID to be healthy..."
    if wait_for_healthy 120; then
        ok "ThunderID is healthy on $new_version"
    else
        fail "ThunderID did not become healthy within 120s"
        echo ""
        echo "Check logs:  docker compose logs thunderid"
        echo "Rollback:    bash scripts/upgrade.sh --rollback"
        exit 1
    fi

    # Step 6: Verify basic endpoints
    step "Step 6/8: Verify endpoints"
    if curl -sf --insecure https://localhost:8090/.well-known/openid-configuration > /dev/null 2>&1; then
        ok "OIDC discovery endpoint responds"
    else
        fail "OIDC discovery endpoint not responding"
        echo "Rollback:    bash scripts/upgrade.sh --rollback"
        exit 1
    fi
    if curl -sf --insecure https://localhost:8090/oauth2/jwks > /dev/null 2>&1; then
        ok "JWKS endpoint responds"
    else
        fail "JWKS endpoint not responding"
        echo "Rollback:    bash scripts/upgrade.sh --rollback"
        exit 1
    fi

    # Step 7: Re-run bootstrap (tests management API compatibility)
    step "Step 7/8: Verify bootstrap compatibility"
    if docker compose run --rm toolbox python3 bootstrap/bootstrap.py > /dev/null 2>&1; then
        ok "Bootstrap succeeded (management API compatible)"
    else
        fail "Bootstrap failed — management API may have changed"
        echo ""
        echo "Check:    docker compose run --rm toolbox python3 bootstrap/bootstrap.py"
        echo "Rollback: bash scripts/upgrade.sh --rollback"
        exit 1
    fi
    if docker compose run --rm toolbox python3 bootstrap/seed_users.py > /dev/null 2>&1; then
        ok "Seed succeeded"
    else
        fail "Seed failed"
        echo "Rollback: bash scripts/upgrade.sh --rollback"
        exit 1
    fi

    # Step 8: Run test suite (unless skipped)
    step "Step 8/8: Run test suite"
    if [ "${SKIP_TESTS:-}" = "true" ]; then
        info "Skipping tests (SKIP_TESTS=true)"
    else
        docker compose up -d monitoring-api
        info "Waiting for monitoring-api..."
        sleep 5
        for i in $(seq 1 12); do
            if curl -sf http://localhost:9100/health > /dev/null 2>&1; then
                break
            fi
            sleep 5
        done

        local test_failed=false

        # Phases 1-5 (toolbox)
        info "Running Phases 1-5..."
        if docker compose run --rm toolbox bash scripts/test-all.sh > /dev/null 2>&1; then
            ok "Phases 1-5 passed"
        else
            fail "Phases 1-5 had failures"
            test_failed=true
        fi

        # Phase 6 (host)
        info "Running Phase 6..."
        if ADMIN_PASSWORD="$ADMIN_PASSWORD" bash scripts/test-phase6.sh > /dev/null 2>&1; then
            ok "Phase 6 passed"
        else
            fail "Phase 6 had failures"
            test_failed=true
        fi

        # Phase 7 (host)
        info "Running Phase 7..."
        if bash scripts/test-phase7.sh > /dev/null 2>&1; then
            ok "Phase 7 passed"
        else
            fail "Phase 7 had failures"
            test_failed=true
        fi

        if [ "$test_failed" = "true" ]; then
            echo ""
            fail "Some tests failed after upgrade"
            echo ""
            echo "Options:"
            echo "  1. Investigate: run individual test phases for details"
            echo "  2. Rollback:    bash scripts/upgrade.sh --rollback"
            exit 1
        fi
    fi

    # Success — clean up rollback state
    rm -f "$ROLLBACK_STATE_FILE"

    echo ""
    echo "==========================================="
    echo "  Upgrade complete: $current_version → $new_version"
    echo "==========================================="
    echo ""
    echo "Next steps:"
    echo "  1. Review changes:  git diff"
    echo "  2. Commit:          git add -A && git commit -m 'Upgrade ThunderID to v$new_version'"
    echo ""
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

if [ $# -eq 0 ]; then
    echo "Usage:"
    echo "  $0 <version>           Upgrade ThunderID to <version>"
    echo "  $0 <version> --check   Pre-flight check only (no changes)"
    echo "  $0 --rollback          Rollback the last upgrade"
    echo ""
    echo "Current version: $(get_current_version)"
    echo ""
    echo "Examples:"
    echo "  ADMIN_PASSWORD=<pw> $0 1.1.0"
    echo "  $0 1.1.0 --check"
    echo "  $0 --rollback"
    exit 0
fi

case "${1:-}" in
    --rollback)
        do_rollback
        ;;
    *)
        new_version="$1"
        # Validate version format (semver-like: digits and dots)
        if ! echo "$new_version" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?$'; then
            fail "Invalid version format: $new_version"
            echo "  Expected: X.Y.Z (e.g., 1.1.0, 2.0.0-rc1)"
            exit 1
        fi

        if [ "${2:-}" = "--check" ]; then
            do_check "$new_version"
        else
            do_upgrade "$new_version"
        fi
        ;;
esac
