#!/bin/bash
# Identity Service - Full Test Suite
# Runs all phase test scripts in order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

echo "========================================="
echo "  Identity Service — Full Test Suite"
echo "========================================="

run_phase() {
    local phase="$1"
    local script="$SCRIPT_DIR/test-phase${phase}.sh"

    echo ""
    echo "--- Phase $phase ---"

    if [ ! -f "$script" ]; then
        echo "  SKIP  test-phase${phase}.sh not found"
        return 0
    fi

    if bash "$script"; then
        return 0
    else
        FAILURES=$((FAILURES + 1))
        return 1
    fi
}

run_phase 1
run_phase 2
run_phase 3
run_phase 4
run_phase 5

# Phase 6 needs docker compose (host-side), skip if not available
if command -v docker > /dev/null 2>&1; then
    run_phase 6
else
    echo ""
    echo "--- Phase 6 ---"
    echo "  SKIP  (docker not available in this context)"
fi

echo ""
echo "========================================="
if [ "$FAILURES" -gt 0 ]; then
    echo "  $FAILURES phase(s) had failures"
    echo "========================================="
    exit 1
fi
echo "  All tests passed!"
echo "========================================="
