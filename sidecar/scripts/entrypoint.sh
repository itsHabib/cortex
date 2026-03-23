#!/bin/sh
set -eu

# Start sidecar in background
/cortex-sidecar &
SIDECAR_PID=$!

# Wait for sidecar to become healthy
SIDECAR_PORT="${CORTEX_SIDECAR_PORT:-9090}"
echo "Waiting for sidecar on port ${SIDECAR_PORT}..."

RETRIES=0
MAX_RETRIES=30
while [ "$RETRIES" -lt "$MAX_RETRIES" ]; do
  if curl -sf "http://localhost:${SIDECAR_PORT}/health" > /dev/null 2>&1; then
    echo "Sidecar is healthy"
    break
  fi
  RETRIES=$((RETRIES + 1))
  sleep 1
done

if [ "$RETRIES" -eq "$MAX_RETRIES" ]; then
  echo "ERROR: Sidecar did not become healthy after ${MAX_RETRIES}s"
  kill "$SIDECAR_PID" 2>/dev/null || true
  exit 1
fi

# Trap signals to forward to both processes
cleanup() {
  echo "Shutting down..."
  kill "$WORKER_PID" 2>/dev/null || true
  kill "$SIDECAR_PID" 2>/dev/null || true
  wait "$WORKER_PID" 2>/dev/null || true
  wait "$SIDECAR_PID" 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT

# Start worker in foreground
/agent-worker &
WORKER_PID=$!

echo "Sidecar (PID ${SIDECAR_PID}) and worker (PID ${WORKER_PID}) running"

# Wait for either process to exit
wait -n "$SIDECAR_PID" "$WORKER_PID" 2>/dev/null || true
EXIT_CODE=$?

echo "A process exited with code ${EXIT_CODE}, shutting down..."
cleanup
