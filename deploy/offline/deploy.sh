#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=========================================="
echo " Open VSX Offline Deployment"
echo "=========================================="
echo ""

# Check Docker
if ! command -v docker &> /dev/null; then
  echo "Error: Docker is not installed."
  echo "Install Docker CE: https://docs.docker.com/engine/install/ubuntu/"
  exit 1
fi

if ! docker compose version &> /dev/null; then
  echo "Error: Docker Compose plugin is not installed."
  echo "Install it: sudo apt-get install docker-compose-plugin"
  exit 1
fi

SERVER_IMAGE="${SERVER_IMAGE:-openvsx-server:local}"
WEBUI_IMAGE="${WEBUI_IMAGE:-openvsx-webui:local}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16.2}"
export SERVER_IMAGE WEBUI_IMAGE POSTGRES_IMAGE

echo "[1/4] Checking Docker images..."
MISSING=0
for IMG in "${SERVER_IMAGE}" "${WEBUI_IMAGE}" "${POSTGRES_IMAGE}"; do
  if ! docker image inspect "${IMG}" &>/dev/null; then
    echo "  Missing: ${IMG}"
    MISSING=1
  else
    echo "  Found: ${IMG}"
  fi
done

if [ "${MISSING}" -eq 1 ]; then
  echo ""
  echo "Some images are missing. Importing from tarballs..."
  bash import-images.sh
fi

echo ""
echo "[2/4] Starting services..."
docker compose up -d

echo ""
echo "[3/4] Waiting for services to become healthy..."
TIMEOUT=120
ELAPSED=0
while [ "${ELAPSED}" -lt "${TIMEOUT}" ]; do
  SERVER_HEALTHY=$(docker inspect --format='{{.State.Health.Status}}' openvsx-server 2>/dev/null || echo "starting")
  if [ "${SERVER_HEALTHY}" = "healthy" ]; then
    echo "  Server is healthy."
    break
  fi
  echo "  Waiting for server... (${ELAPSED}s/${TIMEOUT}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
  echo "Warning: Server did not become healthy within ${TIMEOUT}s."
  echo "Check logs: docker compose logs server"
fi

echo ""
echo "[4/5] Seeding admin user and access token..."
sleep 2
docker exec -i openvsx-postgres psql -U openvsx -d openvsx < config/init-admin.sql 2>/dev/null || echo "  (admin user may already exist)"

echo ""
echo "[5/5] Verifying endpoints..."
echo ""

if curl -sf http://localhost:8080/api/-/search > /dev/null 2>&1; then
  echo "  API (port 8080):  OK"
else
  echo "  API (port 8080):  FAILED - check: docker compose logs server"
fi

if curl -sf http://localhost:3000/ > /dev/null 2>&1; then
  echo "  Web UI (port 3000): OK"
else
  echo "  Web UI (port 3000): FAILED - check: docker compose logs webui"
fi

echo ""
echo "=========================================="
echo " Deployment complete!"
echo ""
echo " Web UI:    http://localhost:3000"
echo " API:       http://localhost:8080"
echo " Swagger:   http://localhost:8080/swagger-ui/index.html"
echo " Health:    http://localhost:8080/actuator/health"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  - To load extensions, see: bash sync-extensions.sh --help"
echo "  - To stop: docker compose down"
echo "  - To view logs: docker compose logs -f"
