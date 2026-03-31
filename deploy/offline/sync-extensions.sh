#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# sync-extensions.sh
#
# Downloads extensions from a public Open VSX registry and publishes them to a
# LOCAL Open VSX instance. Designed to run on a machine WITH internet access.
#
# Usage:
#   bash sync-extensions.sh [OPTIONS]
#
# Options:
#   --source URL       Source registry to download FROM (default: https://open-vsx.org)
#   --target URL       LOCAL registry to publish TO (default: http://localhost:8080)
#   --token TOKEN      Access token for the LOCAL target registry (default: super_token)
#                      This is NOT your open-vsx.org token. Use the token seeded by
#                      deploy.sh (super_token) or one you created in your local instance.
#   --count N          Max extensions to sync (default: 0 = all)
#   --offset N         Start offset for pagination (default: 0)
#   --batch N          Page size per API call (default: 50)
#   --downloads DIR    Directory for downloaded .vsix files (default: ./downloads)
#   --max-size MB      Skip extensions larger than N MB (default: 200)
#   --timeout SECS     Download timeout per file in seconds (default: 300)
#   --help             Show this help
#
# The default token "super_token" is created by deploy.sh (via init-admin.sql).
# If you haven't run deploy.sh yet, run it first, or manually seed the token:
#   docker exec -i openvsx-postgres psql -U openvsx -d openvsx < config/init-admin.sql
#
###############################################################################

SOURCE_URL="${SOURCE_URL:-https://open-vsx.org}"
TARGET_URL="${TARGET_URL:-http://localhost:8080}"
ACCESS_TOKEN="${ACCESS_TOKEN:-super_token}"
MAX_COUNT="${MAX_COUNT:-0}"
OFFSET="${OFFSET:-0}"
BATCH_SIZE="${BATCH_SIZE:-50}"
DOWNLOADS_DIR=""
MAX_SIZE_MB="${MAX_SIZE_MB:-200}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-300}"
HELP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)     SOURCE_URL="$2";       shift 2 ;;
    --target)     TARGET_URL="$2";       shift 2 ;;
    --token)      ACCESS_TOKEN="$2";     shift 2 ;;
    --count)      MAX_COUNT="$2";        shift 2 ;;
    --offset)     OFFSET="$2";           shift 2 ;;
    --batch)      BATCH_SIZE="$2";       shift 2 ;;
    --downloads)  DOWNLOADS_DIR="$2";    shift 2 ;;
    --max-size)   MAX_SIZE_MB="$2";      shift 2 ;;
    --timeout)    DOWNLOAD_TIMEOUT="$2"; shift 2 ;;
    --help)       HELP=true;             shift ;;
    *)            echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ "${HELP}" = true ]; then
  head -40 "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-${SCRIPT_DIR}/downloads}"
mkdir -p "${DOWNLOADS_DIR}"

TMPDIR_SYNC=$(mktemp -d)
trap 'rm -rf "${TMPDIR_SYNC}"' EXIT

echo "=========================================="
echo " Open VSX Extension Sync"
echo "=========================================="
echo " Source:       ${SOURCE_URL}"
echo " Target:       ${TARGET_URL}"
echo " Downloads:    ${DOWNLOADS_DIR}"
echo " Max size:     ${MAX_SIZE_MB} MB per extension"
echo " DL timeout:   ${DOWNLOAD_TIMEOUT}s per file"
if [ "${MAX_COUNT}" -gt 0 ]; then
  echo " Max count:    ${MAX_COUNT}"
else
  echo " Max count:    all"
fi
echo "=========================================="
echo ""

# --- Pre-flight checks ---

# 1. Check target is reachable
if ! curl -sf --connect-timeout 5 "${TARGET_URL}/api/-/search" > /dev/null 2>&1; then
  echo "Error: Target registry at ${TARGET_URL} is not reachable."
  echo "Make sure the server is running: docker compose up -d"
  exit 1
fi

# 2. Validate the access token against the LOCAL target registry
echo -n "[check] Validating access token against ${TARGET_URL}... "
TOKEN_CHECK_FILE="${TMPDIR_SYNC}/token_check.json"
TOKEN_HTTP=$(curl -s --connect-timeout 5 --max-time 10 \
  -o "${TOKEN_CHECK_FILE}" -w "%{http_code}" \
  -X POST "${TARGET_URL}/api/-/namespace/create?token=${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name": "__token_validation_test__"}' 2>/dev/null) || TOKEN_HTTP="000"

TOKEN_ERROR=$(python3 -c "import json;print(json.load(open('${TOKEN_CHECK_FILE}')).get('error',''))" 2>/dev/null || echo "")

if echo "${TOKEN_ERROR}" | grep -qi "invalid access token"; then
  echo "FAILED"
  echo ""
  echo "================================================================"
  echo " ERROR: Invalid access token for your LOCAL registry."
  echo "================================================================"
  echo ""
  echo " The --token flag requires a token from YOUR LOCAL Open VSX"
  echo " instance at ${TARGET_URL}, NOT from open-vsx.org."
  echo ""
  echo " Your token '${ACCESS_TOKEN:0:12}...' was rejected by the local server."
  echo ""
  echo " How to fix:"
  echo "   Option 1: Use the default token (recommended)."
  echo "     The deploy.sh script seeds a token called 'super_token'."
  echo "     Just run without --token:"
  echo "       bash sync-extensions.sh --count 5"
  echo ""
  echo "   Option 2: Re-seed the default token if it's missing:"
  echo "     docker exec -i openvsx-postgres psql -U openvsx -d openvsx \\"
  echo "       < config/init-admin.sql"
  echo "     Then run: bash sync-extensions.sh --count 5"
  echo ""
  echo "   Option 3: Create a new token via the API (requires a logged-in user)."
  echo "================================================================"
  exit 1
fi

# If we accidentally created the test namespace, that's fine — it's harmless.
# The important thing is the token was accepted.
echo "OK"
echo ""

# 3. Check source is reachable
echo -n "[check] Verifying source registry ${SOURCE_URL}... "
if ! curl -sf --connect-timeout 5 --max-time 10 "${SOURCE_URL}/api/-/search?size=1" > /dev/null 2>&1; then
  echo "FAILED"
  echo "Error: Source registry at ${SOURCE_URL} is not reachable."
  echo "Check your internet connection."
  exit 1
fi
echo "OK"
echo ""

SYNCED=0
FAILED=0
SKIPPED=0
CURRENT_OFFSET="${OFFSET}"

while true; do
  SEARCH_URL="${SOURCE_URL}/api/-/search?offset=${CURRENT_OFFSET}&size=${BATCH_SIZE}&sortBy=relevance&sortOrder=desc"
  echo "[fetch] page offset=${CURRENT_OFFSET} size=${BATCH_SIZE}"

  RESPONSE_FILE="${TMPDIR_SYNC}/response.json"
  MANIFEST_FILE="${TMPDIR_SYNC}/manifest.tsv"

  if ! curl -sf --connect-timeout 10 --max-time 30 -o "${RESPONSE_FILE}" "${SEARCH_URL}" 2>/dev/null; then
    echo "Error: Failed to fetch from source registry at offset ${CURRENT_OFFSET}."
    echo "       URL: ${SEARCH_URL}"
    break
  fi

  python3 - "${RESPONSE_FILE}" "${MANIFEST_FILE}" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
total = data.get("totalSize", 0)
exts = data.get("extensions", [])
with open(sys.argv[2], "w") as out:
    out.write(f"__TOTAL__\t{total}\t{len(exts)}\n")
    for ext in exts:
        ns = ext.get("namespace", "")
        name = ext.get("name", "")
        ver = ext.get("version", "")
        dl = (ext.get("files") or {}).get("download", "")
        out.write(f"{ns}\t{name}\t{ver}\t{dl}\n")
PYEOF

  TOTAL_SIZE=$(head -1 "${MANIFEST_FILE}" | cut -f2)
  PAGE_COUNT=$(head -1 "${MANIFEST_FILE}" | cut -f3)
  echo "       totalSize=${TOTAL_SIZE}, page has ${PAGE_COUNT} extensions"

  if [ "${PAGE_COUNT}" -eq 0 ]; then
    echo "No more extensions found."
    break
  fi

  while IFS=$'\t' read -r NAMESPACE NAME VERSION DOWNLOAD_URL; do
    if [ -z "${NAMESPACE}" ] || [ -z "${NAME}" ]; then
      continue
    fi

    if [ "${MAX_COUNT}" -gt 0 ] && [ "${SYNCED}" -ge "${MAX_COUNT}" ]; then
      echo ""
      echo "Reached max count (${MAX_COUNT}). Stopping."
      STOP_SYNC=true
      break
    fi

    VSIX_FILE="${DOWNLOADS_DIR}/${NAMESPACE}.${NAME}-${VERSION}.vsix"

    # Download .vsix if not cached
    if [ ! -f "${VSIX_FILE}" ]; then
      if [ -z "${DOWNLOAD_URL}" ]; then
        DOWNLOAD_URL="${SOURCE_URL}/api/${NAMESPACE}/${NAME}/${VERSION}/file/${NAMESPACE}.${NAME}-${VERSION}.vsix"
      fi

      # Check file size via HEAD request before downloading
      CONTENT_LENGTH=$(curl -sI --connect-timeout 5 --max-time 10 -L "${DOWNLOAD_URL}" 2>/dev/null \
        | grep -i '^content-length:' | tail -1 | tr -d '[:space:]' | cut -d: -f2 || echo "0")
      MAX_BYTES=$((MAX_SIZE_MB * 1024 * 1024))

      if [ -n "${CONTENT_LENGTH}" ] && [ "${CONTENT_LENGTH}" -gt "${MAX_BYTES}" ] 2>/dev/null; then
        SIZE_MB=$(( CONTENT_LENGTH / 1024 / 1024 ))
        echo "  [skip] ${NAMESPACE}.${NAME}@${VERSION} (${SIZE_MB} MB > ${MAX_SIZE_MB} MB limit)"
        SKIPPED=$((SKIPPED + 1))
        continue
      fi

      echo -n "  [download] ${NAMESPACE}.${NAME}@${VERSION}... "
      if curl -sfL --connect-timeout 10 --max-time "${DOWNLOAD_TIMEOUT}" \
           -o "${VSIX_FILE}" "${DOWNLOAD_URL}" 2>/dev/null; then
        FILE_SIZE=$(du -sh "${VSIX_FILE}" 2>/dev/null | cut -f1)
        echo "OK (${FILE_SIZE})"
      else
        echo "FAILED (timeout or network error)"
        rm -f "${VSIX_FILE}"
        FAILED=$((FAILED + 1))
        continue
      fi
    else
      echo "  [cached] ${NAMESPACE}.${NAME}@${VERSION}"
    fi

    # Create namespace (ignore if exists)
    curl -s --connect-timeout 5 --max-time 10 \
      -X POST "${TARGET_URL}/api/-/namespace/create?token=${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"${NAMESPACE}\"}" > /dev/null 2>&1 || true

    # Publish extension
    echo -n "  [publish] ${NAMESPACE}.${NAME}@${VERSION}... "
    PUBLISH_FILE="${TMPDIR_SYNC}/publish_result.json"
    HTTP_CODE=$(curl -s --connect-timeout 10 --max-time 120 \
      -o "${PUBLISH_FILE}" -w "%{http_code}" \
      -X POST "${TARGET_URL}/api/-/publish?token=${ACCESS_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@${VSIX_FILE}" 2>/dev/null) || HTTP_CODE="000"

    if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "201" ]; then
      ERROR=$(python3 -c "import json;d=json.load(open('${PUBLISH_FILE}'));print(d.get('error',''))" 2>/dev/null || echo "")
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
    elif [ "${HTTP_CODE}" = "000" ]; then
      echo "FAILED (connection error)"
      FAILED=$((FAILED + 1))
    else
      ERROR=$(python3 -c "import json;d=json.load(open('${PUBLISH_FILE}'));print(d.get('error',''))" 2>/dev/null || echo "HTTP ${HTTP_CODE}")
      if echo "${ERROR}" | grep -q "already published"; then
        echo "SKIP (already published)"
        SKIPPED=$((SKIPPED + 1))
      else
        echo "FAILED: ${ERROR}"
        FAILED=$((FAILED + 1))
      fi
    fi
  done < <(tail -n +2 "${MANIFEST_FILE}")

  if [ "${STOP_SYNC:-false}" = true ]; then
    break
  fi

  CURRENT_OFFSET=$((CURRENT_OFFSET + BATCH_SIZE))
  if [ "${TOTAL_SIZE}" -gt 0 ] 2>/dev/null && [ "${CURRENT_OFFSET}" -ge "${TOTAL_SIZE}" ]; then
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
echo "  bash backup-data.sh"
