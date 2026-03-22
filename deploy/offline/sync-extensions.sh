#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# sync-extensions.sh
#
# Downloads extensions from a public Open VSX or VS Code Marketplace compatible
# registry and publishes them to a local Open VSX instance.
#
# This script is designed to be run on a machine WITH internet access.
# After syncing, the local registry data (stored in Docker volumes) contains
# all extensions. The volumes persist across restarts and can be backed up.
#
# Usage:
#   bash sync-extensions.sh [OPTIONS]
#
# Options:
#   --source URL     Source registry URL (default: https://open-vsx.org)
#   --target URL     Target registry URL (default: http://localhost:8080)
#   --token TOKEN    Access token for target (default: super_token)
#   --count N        Number of extensions to sync (default: all)
#   --offset N       Start offset for pagination (default: 0)
#   --batch N        Page size per API call (default: 50)
#   --downloads DIR  Directory for downloaded .vsix files (default: ./downloads)
#   --help           Show this help
#
###############################################################################

SOURCE_URL="${SOURCE_URL:-https://open-vsx.org}"
TARGET_URL="${TARGET_URL:-http://localhost:8080}"
ACCESS_TOKEN="${ACCESS_TOKEN:-super_token}"
MAX_COUNT="${MAX_COUNT:-0}"
OFFSET="${OFFSET:-0}"
BATCH_SIZE="${BATCH_SIZE:-50}"
DOWNLOADS_DIR=""
HELP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)     SOURCE_URL="$2";     shift 2 ;;
    --target)     TARGET_URL="$2";     shift 2 ;;
    --token)      ACCESS_TOKEN="$2";   shift 2 ;;
    --count)      MAX_COUNT="$2";      shift 2 ;;
    --offset)     OFFSET="$2";         shift 2 ;;
    --batch)      BATCH_SIZE="$2";     shift 2 ;;
    --downloads)  DOWNLOADS_DIR="$2";  shift 2 ;;
    --help)       HELP=true;           shift ;;
    *)            echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ "${HELP}" = true ]; then
  head -30 "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-${SCRIPT_DIR}/downloads}"
mkdir -p "${DOWNLOADS_DIR}"

echo "=========================================="
echo " Open VSX Extension Sync"
echo "=========================================="
echo " Source:     ${SOURCE_URL}"
echo " Target:     ${TARGET_URL}"
echo " Downloads:  ${DOWNLOADS_DIR}"
if [ "${MAX_COUNT}" -gt 0 ]; then
  echo " Max count:  ${MAX_COUNT}"
else
  echo " Max count:  all"
fi
echo "=========================================="
echo ""

# Check target is reachable
if ! curl -sf "${TARGET_URL}/api/-/search" > /dev/null 2>&1; then
  echo "Error: Target registry at ${TARGET_URL} is not reachable."
  echo "Make sure the server is running: docker compose up -d"
  exit 1
fi

SYNCED=0
FAILED=0
SKIPPED=0
CURRENT_OFFSET="${OFFSET}"

while true; do
  SEARCH_URL="${SOURCE_URL}/api/-/search?offset=${CURRENT_OFFSET}&size=${BATCH_SIZE}&sortBy=relevance&sortOrder=desc"
  echo "[fetch] ${SEARCH_URL}"

  RESPONSE=$(curl -sf "${SEARCH_URL}" 2>/dev/null) || {
    echo "Error: Failed to fetch from source registry."
    break
  }

  TOTAL_SIZE=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalSize', 0))" 2>/dev/null || echo "0")
  EXTENSIONS=$(echo "${RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ext in data.get('extensions', []):
    ns = ext.get('namespace', '')
    name = ext.get('name', '')
    version = ext.get('version', '')
    dl = ''
    files = ext.get('files', {})
    if files:
        dl = files.get('download', '')
    print(f'{ns}|{name}|{version}|{dl}')
" 2>/dev/null)

  if [ -z "${EXTENSIONS}" ]; then
    echo "No more extensions found."
    break
  fi

  while IFS='|' read -r NAMESPACE NAME VERSION DOWNLOAD_URL; do
    if [ -z "${NAMESPACE}" ] || [ -z "${NAME}" ]; then
      continue
    fi

    if [ "${MAX_COUNT}" -gt 0 ] && [ "${SYNCED}" -ge "${MAX_COUNT}" ]; then
      echo ""
      echo "Reached max count (${MAX_COUNT}). Stopping."
      break 2
    fi

    VSIX_FILE="${DOWNLOADS_DIR}/${NAMESPACE}.${NAME}-${VERSION}.vsix"

    # Download .vsix if not cached
    if [ ! -f "${VSIX_FILE}" ]; then
      if [ -z "${DOWNLOAD_URL}" ]; then
        # Construct download URL from metadata
        DOWNLOAD_URL="${SOURCE_URL}/api/${NAMESPACE}/${NAME}/${VERSION}/file/${NAMESPACE}.${NAME}-${VERSION}.vsix"
      fi

      echo -n "  [download] ${NAMESPACE}.${NAME}@${VERSION}... "
      if curl -sfL -o "${VSIX_FILE}" "${DOWNLOAD_URL}" 2>/dev/null; then
        echo "OK"
      else
        echo "FAILED"
        rm -f "${VSIX_FILE}"
        FAILED=$((FAILED + 1))
        continue
      fi
    else
      echo "  [cached] ${NAMESPACE}.${NAME}@${VERSION}"
    fi

    # Create namespace (ignore if exists)
    curl -sf -X POST "${TARGET_URL}/api/-/namespace/create?token=${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"${NAMESPACE}\"}" > /dev/null 2>&1 || true

    # Publish extension
    echo -n "  [publish] ${NAMESPACE}.${NAME}@${VERSION}... "
    PUBLISH_RESULT=$(curl -s -X POST "${TARGET_URL}/api/-/publish?token=${ACCESS_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@${VSIX_FILE}" 2>/dev/null) || {
      # Check if already published
      if echo "${PUBLISH_RESULT}" 2>/dev/null | grep -q "already published"; then
        echo "SKIP (already published)"
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
      echo "FAILED"
      FAILED=$((FAILED + 1))
      continue
    }

    ERROR=$(echo "${PUBLISH_RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))" 2>/dev/null || echo "")
    if [ -n "${ERROR}" ]; then
      if echo "${ERROR}" | grep -q "already published"; then
        echo "SKIP (already published)"
        SKIPPED=$((SKIPPED + 1))
      else
        echo "FAILED: ${ERROR}"
        FAILED=$((FAILED + 1))
      fi
    else
      echo "OK"
      SYNCED=$((SYNCED + 1))
    fi
  done

  CURRENT_OFFSET=$((CURRENT_OFFSET + BATCH_SIZE))
  if [ "${CURRENT_OFFSET}" -ge "${TOTAL_SIZE}" ]; then
    echo ""
    echo "Reached end of source registry (${TOTAL_SIZE} total extensions)."
    break
  fi
done

echo ""
echo "=========================================="
echo " Sync Summary"
echo "=========================================="
echo "  Published:  ${SYNCED}"
echo "  Skipped:    ${SKIPPED}"
echo "  Failed:     ${FAILED}"
echo "  Downloads:  ${DOWNLOADS_DIR}"
echo "=========================================="
echo ""
echo "The extensions are now stored in the PostgreSQL database and"
echo "on disk in the Docker volume. They will persist across restarts."
echo ""
echo "To back up extension data for offline transfer:"
echo "  docker run --rm -v deploy_offline_extension-storage:/data -v \$(pwd):/backup ubuntu tar czf /backup/extensions-backup.tar.gz -C /data ."
echo "  docker exec openvsx-postgres pg_dump -U openvsx openvsx | gzip > db-backup.sql.gz"
