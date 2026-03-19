#!/usr/bin/env bash
# End-to-end test: Go sidecar ↔ gRPC ↔ Elixir gateway
#
# Starts the Cortex gateway, connects a sidecar, hits the HTTP API,
# and asserts expected behavior.
#
# Usage: ./test/e2e/sidecar_e2e_test.sh
# Exit code: 0 = all pass, 1 = failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0
GATEWAY_PID=""
SIDECAR_PID=""

cleanup() {
  [ -n "$SIDECAR_PID" ] && kill "$SIDECAR_PID" 2>/dev/null || true
  [ -n "$GATEWAY_PID" ] && kill "$GATEWAY_PID" 2>/dev/null || true
  wait "$SIDECAR_PID" 2>/dev/null || true
  wait "$GATEWAY_PID" 2>/dev/null || true
}
trap cleanup EXIT

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo -e "  ${GREEN}✓${NC} $label"
    ((PASS++))
  else
    echo -e "  ${RED}✗${NC} $label (expected '$needle' in response)"
    echo "    got: $haystack"
    ((FAIL++))
  fi
}

assert_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo -e "  ${RED}✗${NC} $label (did not expect '$needle' in response)"
    echo "    got: $haystack"
    ((FAIL++))
  else
    echo -e "  ${GREEN}✓${NC} $label"
    ((PASS++))
  fi
}

assert_http_status() {
  local label="$1"
  local url="$2"
  local expected="$3"
  local method="${4:-GET}"
  local body="${5:-}"

  local status
  if [ "$method" = "POST" ] && [ -n "$body" ]; then
    status=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$body" "$url")
  else
    status=$(curl -s -o /dev/null -w "%{http_code}" "$url")
  fi

  if [ "$status" = "$expected" ]; then
    echo -e "  ${GREEN}✓${NC} $label (HTTP $status)"
    ((PASS++))
  else
    echo -e "  ${RED}✗${NC} $label (expected HTTP $expected, got $status)"
    ((FAIL++))
  fi
}

echo "=== Cortex Sidecar E2E Test ==="
echo ""

# --- Step 1: Build the sidecar ---
echo "Building sidecar..."
cd sidecar
go build -o bin/cortex-sidecar ./cmd/cortex-sidecar
cd "$PROJECT_DIR"
echo "  Binary built at sidecar/bin/cortex-sidecar"
echo ""

# --- Step 2: Start the gateway ---
echo "Starting Cortex gateway..."
CORTEX_GATEWAY_TOKEN=e2e-test-token mix phx.server &>/tmp/cortex-e2e-gateway.log &
GATEWAY_PID=$!

# Wait for gateway to be ready
for i in $(seq 1 15); do
  if lsof -ti:4001 >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! lsof -ti:4001 >/dev/null 2>&1; then
  echo -e "${RED}Gateway failed to start on port 4001${NC}"
  cat /tmp/cortex-e2e-gateway.log
  exit 1
fi
echo "  Gateway running (HTTP :4000, gRPC :4001)"
echo ""

# --- Step 3: Connect the sidecar ---
echo "Starting sidecar..."
CORTEX_GATEWAY_URL=localhost:4001 \
CORTEX_AGENT_NAME=e2e-test-agent \
CORTEX_AGENT_ROLE="e2e test runner" \
CORTEX_AGENT_CAPABILITIES=testing,e2e \
CORTEX_AUTH_TOKEN=e2e-test-token \
sidecar/bin/cortex-sidecar &>/tmp/cortex-e2e-sidecar.log &
SIDECAR_PID=$!

# Wait for sidecar to register
sleep 3

echo ""
echo "--- Test: Registration ---"
SIDECAR_LOG=$(cat /tmp/cortex-e2e-sidecar.log)
assert_contains "sidecar starts" "$SIDECAR_LOG" "starting cortex sidecar"
assert_contains "sidecar registers" "$SIDECAR_LOG" "registered with gateway"
assert_contains "gets agent_id" "$SIDECAR_LOG" "agent_id="
assert_not_contains "no auth errors" "$SIDECAR_LOG" "AUTH_FAILED"

echo ""
echo "--- Test: Health endpoint ---"
HEALTH=$(curl -s http://127.0.0.1:9090/health)
assert_contains "returns healthy" "$HEALTH" '"status":"healthy"'
assert_contains "shows connected" "$HEALTH" '"connected":true'
assert_contains "has agent_id" "$HEALTH" '"agent_id":'
assert_contains "has uptime" "$HEALTH" '"uptime_ms":'

echo ""
echo "--- Test: Roster endpoint ---"
ROSTER=$(curl -s http://127.0.0.1:9090/roster)
assert_contains "returns roster" "$ROSTER" '"agents":'
assert_contains "shows connected" "$ROSTER" '"connected":true'

echo ""
echo "--- Test: Task endpoint ---"
TASK=$(curl -s http://127.0.0.1:9090/task)
assert_contains "no task assigned" "$TASK" '"task":null'

echo ""
echo "--- Test: Messages endpoint ---"
MESSAGES=$(curl -s http://127.0.0.1:9090/messages)
assert_contains "returns messages" "$MESSAGES" '"messages":'

echo ""
echo "--- Test: Status endpoint (POST) ---"
assert_http_status "POST /status returns 200" \
  "http://127.0.0.1:9090/status" "200" "POST" \
  '{"status":"working","detail":"running e2e test","progress":0.5}'

echo ""
echo "--- Test: Knowledge endpoints (501 stubs) ---"
assert_http_status "GET /knowledge returns 501" "http://127.0.0.1:9090/knowledge" "501"
assert_http_status "POST /knowledge returns 501" \
  "http://127.0.0.1:9090/knowledge" "501" "POST" \
  '{"topic":"test","content":"test"}'

echo ""
echo "--- Test: Invalid requests ---"
assert_http_status "POST /status without body returns 400" \
  "http://127.0.0.1:9090/status" "400" "POST" '{}'

echo ""
echo "--- Test: Auth rejection ---"
# Start a second sidecar with wrong token
CORTEX_GATEWAY_URL=localhost:4001 \
CORTEX_AGENT_NAME=bad-agent \
CORTEX_AGENT_ROLE="bad agent" \
CORTEX_AUTH_TOKEN=wrong-token \
sidecar/bin/cortex-sidecar &>/tmp/cortex-e2e-bad-sidecar.log &
BAD_PID=$!
sleep 3
kill "$BAD_PID" 2>/dev/null || true
wait "$BAD_PID" 2>/dev/null || true
BAD_LOG=$(cat /tmp/cortex-e2e-bad-sidecar.log)
assert_contains "bad token gets AUTH_FAILED" "$BAD_LOG" "AUTH_FAILED"

echo ""
echo "--- Test: Clean shutdown ---"
kill "$SIDECAR_PID" 2>/dev/null
wait "$SIDECAR_PID" 2>/dev/null || true
SIDECAR_PID=""
FINAL_LOG=$(cat /tmp/cortex-e2e-sidecar.log)
assert_contains "graceful shutdown" "$FINAL_LOG" "shutdown signal received"
assert_contains "sidecar stopped" "$FINAL_LOG" "sidecar stopped"

echo ""
echo "=============================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
