#!/bin/bash
# Restore ThunderID data from a backup tarball.
#
# Stops ThunderID, replaces databases/certs/secrets, then restarts.
# Usage: bash scripts/restore-db.sh backups/thunderid_YYYYMMDD.tar.gz
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <backup_file.tar.gz>"
    echo ""
    echo "Available backups:"
    ls -lh backups/thunderid_*.tar.gz 2>/dev/null || echo "  No backups found"
    exit 1
fi

BACKUP_FILE="$1"
CONTAINER="aegis-id-thunderid-1"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: $BACKUP_FILE not found"
    exit 1
fi

# Verify backup contents
echo "=== Aegis ID Restore ==="
echo "  Backup: $BACKUP_FILE"
echo "  Contents:"
tar -tzf "$BACKUP_FILE" | head -20
echo ""

# Require explicit confirmation (via CONFIRM=yes env var for non-interactive use)
if [ "${CONFIRM:-}" != "yes" ]; then
    echo "WARNING: This will overwrite all ThunderID data."
    echo "Set CONFIRM=yes to proceed (or run interactively)."
    exit 1
fi

# Extract backup
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
tar -xzf "$BACKUP_FILE" -C "$TMPDIR"

# Stop ThunderID (use docker directly to avoid dependency cascade)
echo "  Stopping ThunderID..."
docker stop aegis-id-thunderid-1 2>/dev/null || true

# Restore files using a temporary helper container that mounts the same
# volumes. This avoids permission issues: we copy files in, fix ownership,
# and clean up WAL files — all before ThunderID starts.
echo "  Restoring databases, certs, and secrets..."
docker run --rm \
    -v aegis-id_thunderid-db:/opt/thunderid/database \
    -v aegis-id_thunderid-certs:/opt/thunderid/config/certs \
    -v aegis-id_thunderid-secrets:/opt/thunderid/config/secrets \
    -v "$TMPDIR:/restore:ro" \
    alpine:3 sh -c '
        # Restore databases
        for db in configdb entitydb runtime_transient runtime_persistent; do
            if [ -f /restore/${db}.db ]; then
                cp /restore/${db}.db /opt/thunderid/database/${db}.db
                rm -f /opt/thunderid/database/${db}.db-wal \
                      /opt/thunderid/database/${db}.db-shm
            fi
        done

        # Restore certs
        if [ -d /restore/certs ]; then
            cp /restore/certs/* /opt/thunderid/config/certs/
        fi

        # Restore secrets
        if [ -d /restore/secrets ]; then
            cp /restore/secrets/* /opt/thunderid/config/secrets/
        fi

        # Fix ownership (ThunderID runs as uid 10001)
        chown -R 10001:10001 /opt/thunderid/database/
        chown -R 10001:10001 /opt/thunderid/config/certs/
        chown -R 10001:10001 /opt/thunderid/config/secrets/
    '

# Start ThunderID
echo "  Starting ThunderID..."
docker start aegis-id-thunderid-1

# Wait for healthy
echo "  Waiting for healthy..."
for i in $(seq 1 20); do
    status=$(docker inspect "$CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null)
    if [ "$status" = "healthy" ]; then
        echo "  ThunderID is healthy"
        break
    fi
    if [ "$i" -eq 20 ]; then
        echo "  WARNING: ThunderID did not become healthy within 100s"
        exit 1
    fi
    sleep 5
done

echo "=== Restore complete ==="
echo "  Verify: curl -k https://localhost:8090/health"
