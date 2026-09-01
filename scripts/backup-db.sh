#!/bin/bash
# Backup ThunderID SQLite databases, certs, and secrets.
#
# Uses sqlite3 .backup for WAL-safe hot backup (no downtime needed).
# Produces a timestamped tarball in ./backups/.
# Keeps only the last 30 backups.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/thunderid_${TIMESTAMP}.tar.gz"
CONTAINER="auth-thunderid-1"

mkdir -p "$BACKUP_DIR"

echo "=== ThunderID Backup ==="

# Verify ThunderID is running
if ! docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
    echo "ERROR: $CONTAINER is not running"
    exit 1
fi

# Create a temp directory for consistent snapshot
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Backup SQLite databases using .backup for WAL consistency
echo "  Backing up databases..."
for db in configdb entitydb runtime_transient runtime_persistent; do
    docker compose exec -T thunderid sqlite3 \
        "database/${db}.db" ".backup '/tmp/${db}_backup.db'" 2>/dev/null
    docker compose cp "thunderid:/tmp/${db}_backup.db" "$TMPDIR/${db}.db" 2>/dev/null
    docker compose exec -T thunderid rm -f "/tmp/${db}_backup.db" 2>/dev/null
done

# Backup certs (JWT signing keys, TLS certs, crypto key)
echo "  Backing up certificates..."
docker compose cp "thunderid:/opt/thunderid/config/certs" "$TMPDIR/certs" 2>/dev/null

# Backup secrets (Direct Auth Secret)
echo "  Backing up secrets..."
docker compose cp "thunderid:/opt/thunderid/config/secrets" "$TMPDIR/secrets" 2>/dev/null

# Create tarball
tar -czf "$BACKUP_FILE" -C "$TMPDIR" .

SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "  Backup created: $BACKUP_FILE ($SIZE)"

# Verify backup contents
FILE_COUNT=$(tar -tzf "$BACKUP_FILE" | wc -l)
echo "  Files in backup: $FILE_COUNT"

# Keep only last 30 backups
DELETED=$(ls -t "$BACKUP_DIR"/thunderid_*.tar.gz 2>/dev/null | tail -n +31 | wc -l)
ls -t "$BACKUP_DIR"/thunderid_*.tar.gz 2>/dev/null | tail -n +31 | xargs -r rm
if [ "$DELETED" -gt 0 ]; then
    echo "  Cleaned $DELETED old backup(s)"
fi

echo "=== Backup complete ==="
