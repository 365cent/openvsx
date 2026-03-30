#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# restore-data.sh
#
# Restores previously backed-up data into the local Open VSX deployment.
# Accepts backup files in any order — the script auto-detects which is the
# database dump and which is the file storage archive.
#
# Usage:
#   bash restore-data.sh <BACKUP_FILE> [BACKUP_FILE...]
#
# Examples:
#   bash restore-data.sh backups/openvsx-db-backup-*.sql.gz backups/openvsx-files-backup-*.tar.gz
#   bash restore-data.sh backups/openvsx-files-backup-*.tar.gz
#   bash restore-data.sh backups/openvsx-db-backup-*.sql.gz
#
# The script identifies files by name pattern:
#   *db-backup*.sql.gz   → database dump (restored via psql)
#   *files-backup*.tar.gz → extension file storage (restored to Docker volume)
#
###############################################################################

if [ $# -lt 1 ]; then
  echo "Usage: bash restore-data.sh <BACKUP_FILE> [BACKUP_FILE...]"
  echo ""
  echo "Pass one or more backup files. The script auto-detects type by filename:"
  echo "  *db-backup*.sql.gz    → database"
  echo "  *files-backup*.tar.gz → extension files"
  echo ""
  echo "Example:"
  echo "  bash restore-data.sh backups/openvsx-db-backup-*.sql.gz backups/openvsx-files-backup-*.tar.gz"
  exit 1
fi

DB_BACKUP=""
FILES_BACKUP=""

for ARG in "$@"; do
  if [ ! -f "${ARG}" ]; then
    echo "Error: File not found: ${ARG}"
    exit 1
  fi

  BASENAME="$(basename "${ARG}")"

  if echo "${BASENAME}" | grep -qi "db-backup" && echo "${BASENAME}" | grep -q '\.sql\.gz$'; then
    DB_BACKUP="${ARG}"
  elif echo "${BASENAME}" | grep -qi "files-backup" && echo "${BASENAME}" | grep -q '\.tar\.gz$'; then
    FILES_BACKUP="${ARG}"
  elif echo "${BASENAME}" | grep -q '\.sql\.gz$'; then
    DB_BACKUP="${ARG}"
  elif echo "${BASENAME}" | grep -q '\.tar\.gz$'; then
    FILES_BACKUP="${ARG}"
  else
    echo "Error: Cannot identify backup type for: ${ARG}"
    echo "  Expected either *.sql.gz (database) or *.tar.gz (files)"
    exit 1
  fi
done

if [ -z "${DB_BACKUP}" ] && [ -z "${FILES_BACKUP}" ]; then
  echo "Error: No valid backup files identified."
  exit 1
fi

echo "=== Open VSX Data Restore ==="
echo ""
if [ -n "${DB_BACKUP}" ]; then
  echo "  Database backup:  ${DB_BACKUP}"
fi
if [ -n "${FILES_BACKUP}" ]; then
  echo "  Files backup:     ${FILES_BACKUP}"
fi
echo ""

# Validate: make sure a .tar.gz isn't about to be fed into psql
if [ -n "${DB_BACKUP}" ]; then
  # Quick sanity check: a gzipped SQL file starts with the gzip magic bytes
  # and when decompressed should contain text, not binary tar headers
  MAGIC=$(xxd -l 2 -p "${DB_BACKUP}" 2>/dev/null || echo "")
  if [ "${MAGIC}" = "1f8b" ]; then
    # It's gzip — check if the decompressed content looks like SQL (text)
    SAMPLE=$(gunzip -c "${DB_BACKUP}" 2>/dev/null | head -c 512 || echo "")
    if echo "${SAMPLE}" | grep -q "^BZh\|^.\{0,10\}ustar"; then
      echo "================================================================"
      echo " ERROR: '${DB_BACKUP}' appears to be a tar archive, not a SQL dump."
      echo ""
      echo " You may have the arguments swapped. This script auto-detects"
      echo " file types, so just pass all backup files as arguments:"
      echo ""
      echo "   bash restore-data.sh backups/*"
      echo "================================================================"
      exit 1
    fi
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

STEP=1
TOTAL_STEPS=2
[ -n "${DB_BACKUP}" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ -n "${FILES_BACKUP}" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))

# Ensure only postgres is running for restore
echo "[${STEP}/${TOTAL_STEPS}] Starting PostgreSQL (stopping server to avoid conflicts)..."
docker compose stop server webui 2>/dev/null || true
docker compose up -d postgres
STEP=$((STEP + 1))

# Wait for postgres
echo "[${STEP}/${TOTAL_STEPS}] Waiting for PostgreSQL to be ready..."
TIMEOUT=60
ELAPSED=0
while [ "${ELAPSED}" -lt "${TIMEOUT}" ]; do
  if docker exec openvsx-postgres pg_isready -U openvsx -d openvsx > /dev/null 2>&1; then
    echo "  PostgreSQL is ready."
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
  echo "  Error: PostgreSQL did not become ready within ${TIMEOUT}s."
  exit 1
fi
STEP=$((STEP + 1))

# Restore database
if [ -n "${DB_BACKUP}" ]; then
  echo "[${STEP}/${TOTAL_STEPS}] Restoring database from $(basename "${DB_BACKUP}")..."
  gunzip -c "${DB_BACKUP}" | docker exec -i openvsx-postgres psql -U openvsx -d openvsx --quiet 2>&1 | {
    ERRORS=0
    while IFS= read -r LINE; do
      if echo "${LINE}" | grep -qi "error\|invalid"; then
        ERRORS=$((ERRORS + 1))
        if [ "${ERRORS}" -le 3 ]; then
          echo "  psql: ${LINE}"
        elif [ "${ERRORS}" -eq 4 ]; then
          echo "  psql: (suppressing further errors...)"
        fi
      fi
    done
    if [ "${ERRORS}" -gt 0 ]; then
      echo "  Warning: ${ERRORS} error(s) during restore (some may be benign, e.g. 'already exists')."
    fi
  }
  echo "  Database restore complete."
else
  echo "[${STEP}/${TOTAL_STEPS}] No database backup provided. Skipping."
fi
STEP=$((STEP + 1))

# Restore extension files
if [ -n "${FILES_BACKUP}" ]; then
  echo "[${STEP}/${TOTAL_STEPS}] Restoring extension files from $(basename "${FILES_BACKUP}")..."
  VOLUME_NAME=$(docker volume ls --format '{{.Name}}' | grep extension-storage || echo "")
  if [ -z "${VOLUME_NAME}" ]; then
    echo "  Creating extension-storage volume..."
    docker compose up -d server
    sleep 2
    docker compose stop server
    VOLUME_NAME=$(docker volume ls --format '{{.Name}}' | grep extension-storage || echo "")
  fi

  if [ -n "${VOLUME_NAME}" ]; then
    BACKUP_DIR="$(cd "$(dirname "${FILES_BACKUP}")" && pwd)"
    BACKUP_FILE="$(basename "${FILES_BACKUP}")"
    docker run --rm \
      -v "${VOLUME_NAME}":/data \
      -v "${BACKUP_DIR}":/backup:ro \
      postgres:16.2 \
      bash -c "rm -rf /data/* && tar xzf /backup/${BACKUP_FILE} -C /data"
    echo "  Extension files restored."
  else
    echo "  Warning: Could not determine extension-storage volume name."
  fi
else
  echo "[${STEP}/${TOTAL_STEPS}] No files backup provided. Skipping."
fi

echo ""
echo "=== Restore complete ==="
echo ""
echo "Start all services:"
echo "  docker compose up -d"
