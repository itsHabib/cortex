# E2E Tests

End-to-end tests for Cortex external agent pipeline. Tests the full flow from
Go sidecar through gRPC gateway to ExternalAgent GenServer and back.

## Prerequisites

1. Build the sidecar:
   ```bash
   cd sidecar && make build
   ```

2. Start Cortex with a gateway auth token:
   ```bash
   CORTEX_GATEWAY_TOKEN=e2e-test-token mix phx.server
   ```

3. Run the tests:
   ```bash
   cd e2e && go test -v -timeout 60s
   ```

## What it tests

1. Starts the Go sidecar binary (connects to Cortex via gRPC on port 4001)
2. Waits for sidecar to register in Gateway.Registry
3. `POST /api/runs` with `provider: external` config → triggers async `Runner.run`
4. A goroutine polls the sidecar's HTTP API (`GET /task`) and auto-responds
5. Polls `GET /api/runs/:id` until the run completes
6. Asserts the run finished with status `"completed"`
