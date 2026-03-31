#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/images"
mkdir -p "${OUTPUT_DIR}"

IMAGES=(
  "openvsx-server:local"
  "openvsx-webui:local"
  "postgres:16.2"
)

echo "=== Exporting Docker images as tarballs ==="
echo "Output directory: ${OUTPUT_DIR}"
echo ""

for IMAGE in "${IMAGES[@]}"; do
  SAFE_NAME="${IMAGE//[:\/]/_}"
  TARBALL="${OUTPUT_DIR}/${SAFE_NAME}.tar.gz"

  if [ -f "${TARBALL}" ]; then
    echo "[skip] ${IMAGE} -> ${TARBALL} (already exists)"
    continue
  fi

  echo "[save] ${IMAGE} -> ${TARBALL}"
  docker save "${IMAGE}" | gzip > "${TARBALL}"
  SIZE=$(du -sh "${TARBALL}" | cut -f1)
  echo "       Size: ${SIZE}"
done

echo ""
echo "=== Export complete ==="
echo "Files in ${OUTPUT_DIR}:"
ls -lh "${OUTPUT_DIR}"/*.tar.gz
echo ""
echo "Transfer the entire 'offline/' directory to the target machine."
echo "Then run: bash import-images.sh"
