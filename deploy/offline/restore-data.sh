#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# restore-data.sh
#
# Restores a previously backed-up PostgreSQL database and extension file
# storage into the local Open VSX deployment. Use this on the air-gapped
# target machine after importing Docker images and starting the stack.
#
# Usage:
#   bash restore-data.sh <DB_BACKUP.sql.gz> [FILES_BACKUP.tar.gz]
#
###############################################################################

if [ $# -lt 1 ]; then
  echo "Usage: bash restore-data.sh <DB_BACKUP.sql.gz> [FILES_BACKUP.tar.gz]"
  exit 1
fi

DB_BACKUP="$1"
FILES_BACKUP="${2:-}"

if [ ! -f "${DB_BACKUP}" ]; then
  echo "Error: Database backup file not found: ${DB_BACKUP}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=== Open VSX Data Restore ==="
echo ""

# Ensure only postgres is running for restore
echo "[1/4] Starting PostgreSQL (stopping server to avoid conflicts)..."
docker compose stop server webui 2>/dev/null || true
docker compose up -d postgres
sleep 5

# Wait for postgres
echo "[2/4] Waiting for PostgreSQL to be ready..."
TIMEOUT=60
ELAPSED=0
while [ "${ELAPSED}" -lt "${TIMEOUT}" ]; do
  if docker exec openvsx-postgres pg_isready -U openvsx -d openvsx > /dev/null 2>&1; then
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

# Restore database
echo "[3/4] Restoring database from ${DB_BACKUP}..."
gunzip -c "${DB_BACKUP}" | docker exec -i openvsx-postgres psql -U openvsx -d openvsx --quiet
echo "  Database restored."

# Restore extension files
if [ -n "${FILES_BACKUP}" ] && [ -f "${FILES_BACKUP}" ]; then
  echo "[4/4] Restoring extension files from ${FILES_BACKUP}..."
  VOLUME_NAME=$(docker volume ls --format '{{.Name}}' | grep extension-storage || echo "")
  if [ -z "${VOLUME_NAME}" ]; then
    echo "  Creating extension-storage volume..."
    docker compose up -d server
    sleep 2
    docker compose stop server
    VOLUME_NAME=$(docker volume ls --format '{{.Name}}' | grep extension-storage || echo "")
  fi

  if [ -n "${VOLUME_NAME}" ]; then
    docker run --rm \
      -v "${VOLUME_NAME}":/data \
      -v "$(cd "$(dirname "${FILES_BACKUP}")" && pwd)":/backup:ro \
      ubuntu:22.04 \
      bash -c "rm -rf /data/* && tar xzf /backup/$(basename "${FILES_BACKUP}") -C /data"
    echo "  Files restored."
  else
    echo "  Warning: Could not determine extension-storage volume name."
  fi
else
  echo "[4/4] No files backup provided. Skipping."
fi

echo ""
echo "=== Restore complete ==="
echo ""
echo "Start all services: docker compose up -d"
