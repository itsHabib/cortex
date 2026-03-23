#!/bin/sh
# Docker smoke test for Cortex container infrastructure.
# Builds images, starts services, runs health checks, and tears down.
#
# Usage: ./scripts/docker-smoke-test.sh
# Requires: Docker Engine + Compose plugin

set -eu

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

cleanup() {
  echo ""
  echo "==> Cleaning up..."
  docker compose down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Building all images..."
if docker compose build; then
  pass "docker compose build"
else
  fail "docker compose build"
  echo "Build failed, aborting."
  exit 1
fi

echo ""
echo "==> Starting core services..."
docker compose up -d

echo ""
echo "==> Waiting for Cortex to become healthy (up to 60s)..."
RETRIES=0
MAX_RETRIES=60
while [ "$RETRIES" -lt "$MAX_RETRIES" ]; do
  if curl -sf http://localhost:4000/health/ready > /dev/null 2>&1; then
    break
  fi
  RETRIES=$((RETRIES + 1))
  sleep 1
done

if [ "$RETRIES" -lt "$MAX_RETRIES" ]; then
  pass "Cortex healthy within ${RETRIES}s"
else
  fail "Cortex did not become healthy within ${MAX_RETRIES}s"
fi

echo ""
echo "==> Running health checks..."

if curl -sf http://localhost:4000/health/ready > /dev/null 2>&1; then
  pass "GET /health/ready returns 200"
else
  fail "GET /health/ready"
fi

if curl -sf http://localhost:4000/health/live > /dev/null 2>&1; then
  pass "GET /health/live returns 200"
else
  fail "GET /health/live"
fi

echo ""
echo "==> Checking image sizes..."

CORTEX_SIZE=$(docker images cortex-cortex --format '{{.Size}}' 2>/dev/null | head -1)
if [ -n "$CORTEX_SIZE" ]; then
  echo "  Cortex image size: $CORTEX_SIZE"
  pass "Cortex image built"
else
  fail "Cortex image not found"
fi

echo ""
echo "==> Checking container status..."
docker compose ps

echo ""
echo "==> Stopping core services..."
docker compose down

echo ""
echo "==> Starting with external profile..."
docker compose --profile external up -d

echo ""
echo "==> Waiting for services to become healthy (up to 90s)..."
RETRIES=0
MAX_RETRIES=90
while [ "$RETRIES" -lt "$MAX_RETRIES" ]; do
  CORTEX_OK=$(curl -sf http://localhost:4000/health/ready > /dev/null 2>&1 && echo "1" || echo "0")
  SIDECAR_OK=$(curl -sf http://localhost:9091/health > /dev/null 2>&1 && echo "1" || echo "0")
  if [ "$CORTEX_OK" = "1" ] && [ "$SIDECAR_OK" = "1" ]; then
    break
  fi
  RETRIES=$((RETRIES + 1))
  sleep 1
done

if [ "$RETRIES" -lt "$MAX_RETRIES" ]; then
  pass "All services healthy with external profile within ${RETRIES}s"
else
  fail "External profile services did not become healthy within ${MAX_RETRIES}s"
fi

if curl -sf http://localhost:9091/health > /dev/null 2>&1; then
  pass "Sidecar GET /health returns 200"
else
  fail "Sidecar GET /health"
fi

echo ""
echo "========================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

echo ""
echo "All checks passed."
