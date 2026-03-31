#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# backup-data.sh
#
# Backs up the PostgreSQL database and extension file storage from the running
# Open VSX deployment. Use this to create a portable backup that can be
# restored on an air-gapped target machine.
#
# Usage:
#   bash backup-data.sh [OUTPUT_DIR]
#
# Output:
#   OUTPUT_DIR/openvsx-db-backup.sql.gz        - Database dump
#   OUTPUT_DIR/openvsx-files-backup.tar.gz     - Extension file storage
#
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-${SCRIPT_DIR}/backups}"
mkdir -p "${OUTPUT_DIR}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== Open VSX Data Backup ==="
echo "Output: ${OUTPUT_DIR}"
echo ""

# Backup database
DB_BACKUP="${OUTPUT_DIR}/openvsx-db-backup-${TIMESTAMP}.sql.gz"
echo "[1/2] Backing up PostgreSQL database..."
docker exec openvsx-postgres pg_dump -U openvsx openvsx | gzip > "${DB_BACKUP}"
echo "  Database backup: ${DB_BACKUP} ($(du -sh "${DB_BACKUP}" | cut -f1))"

# Backup extension file storage
FILES_BACKUP="${OUTPUT_DIR}/openvsx-files-backup-${TIMESTAMP}.tar.gz"
echo "[2/2] Backing up extension file storage..."
VOLUME_NAME=$(docker volume ls --format '{{.Name}}' | grep extension-storage || echo "")
if [ -n "${VOLUME_NAME}" ]; then
  docker run --rm \
    -v "${VOLUME_NAME}":/data:ro \
    -v "${OUTPUT_DIR}":/backup \
    ubuntu:22.04 \
    tar czf "/backup/$(basename "${FILES_BACKUP}")" -C /data .
  echo "  Files backup: ${FILES_BACKUP} ($(du -sh "${FILES_BACKUP}" | cut -f1))"
else
  echo "  Warning: extension-storage volume not found. Skipping file backup."
fi

echo ""
echo "=== Backup complete ==="
echo ""
echo "Transfer these files to the target machine along with the"
echo "deploy/offline/ directory, then run: bash restore-data.sh"
