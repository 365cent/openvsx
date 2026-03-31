#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DIR="${SCRIPT_DIR}/images"

if [ ! -d "${IMAGE_DIR}" ]; then
  echo "Error: images/ directory not found at ${IMAGE_DIR}"
  echo "Make sure the image tarballs are in the 'images/' subdirectory."
  exit 1
fi

echo "=== Importing Docker images from tarballs ==="
echo ""

for TARBALL in "${IMAGE_DIR}"/*.tar.gz; do
  if [ ! -f "${TARBALL}" ]; then
    echo "No .tar.gz files found in ${IMAGE_DIR}"
    exit 1
  fi

  BASENAME="$(basename "${TARBALL}")"
  echo "[load] ${BASENAME}"
  docker load < "${TARBALL}"
done

echo ""
echo "=== Import complete ==="
echo ""
echo "Loaded images:"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | head -20
