# Master Plan: Integration Test Engineer

## You are in PLAN MODE.

### Project
I want to build an **integration test suite** for the Cortex Phase 2 gRPC Sidecar.

**Goal:** build **end-to-end integration tests** that verify the full Go sidecar <-> gRPC <-> Elixir gateway flow, ensuring the gRPC data plane writes to the same Gateway.Registry and emits the same PubSub events as the Phase 1 Phoenix Channel control plane.

### Role + Scope
- **Role:** Integration Test Engineer
- **Scope:** I own all integration tests for the gRPC gateway server (Elixir side), the Go sidecar client + HTTP API (Go side), shared test helpers, and a Go mock gRPC server for sidecar unit testing. I do NOT own the sidecar implementation code, the gateway gRPC server implementation, the proto definitions, or the HTTP handler unit tests.
- **File I will write:** `docs/cluster-mode/phase-2-sidecar/plans-v2/integration-test.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

1. **Elixir-Side gRPC Integration Tests** (`test/cortex/gateway/grpc_integration_test.exs`)
   - gRPC Connect stream opens, RegisterRequest received, RegisterResponse sent back with agent_id.
   - Heartbeat received via stream, Gateway.Registry `last_heartbeat` and `load` updated.
   - Stream disconnects (client closes or process dies), agent removed from Registry via Process.monitor cleanup.
   - TaskRequest pushed to agent via gRPC stream (gateway sends GatewayMessage with task_request).
   - TaskResult received via stream, PubSub event emitted.
   - StatusUpdate received via stream, Registry status updated, PubSub event emitted.
   - PeerRequest routed between two gRPC streams: agent A sends PeerRequest targeting agent B's capability, gateway routes to B's stream, B responds via PeerResponse, response routed back to A.
   - gRPC-connected agents produce identical PubSub events as Phoenix Channel agents (`:agent_registered`, `:agent_unregistered`, `:agent_status_changed`), so LiveView dashboard works without changes.

2. **Go-Side Integration Tests** (`sidecar/internal/integration_test.go`)
   - Sidecar connects to a test gRPC server, sends RegisterRequest, receives RegisterResponse with agent_id.
   - Sidecar sends Heartbeat messages at the configured interval (`time.Ticker`).
   - Sidecar reconnects after stream drop: re-opens the bidirectional stream and re-sends RegisterRequest (gets a new agent_id).
   - HTTP API `GET /roster` returns agents from the sidecar's cached RosterUpdate state.
   - HTTP API `POST /ask/:agent_id` sends PeerRequest via gRPC and receives PeerResponse.
   - HTTP API `POST /status` sends StatusUpdate via gRPC stream.

3. **Elixir Test Helpers** (`test/support/grpc_helpers.ex`)
   - Helper to start a gRPC test client that opens a Connect stream to the gateway.
   - Helper to send AgentMessage variants (register, heartbeat, task_result, status_update, peer_response) over the test stream.
   - Helper to receive and assert GatewayMessage variants from the stream.
   - Helper to assert gateway PubSub events with timeout.

4. **Go Mock gRPC Server** (`sidecar/internal/testutil/mock_server.go`)
   - Implements the `AgentGateway.Connect` bidirectional stream RPC.
   - On RegisterRequest: responds with RegisterResponse (generated agent_id).
   - On Heartbeat: no response needed (logs).
   - On StatusUpdate: no response needed (logs).
   - On PeerResponse: logs.
   - Can push TaskRequest and PeerRequest to the stream on demand (for testing sidecar's receive path).
   - Can be configured to close the stream after N messages (for testing reconnect).
   - Records all received messages for assertion in tests.

## Non-Functional Requirements

1. **Determinism** -- Tests must not depend on wall-clock timing. Use `assert_receive` with timeouts (Elixir) and channel-based synchronization (Go) rather than `Process.sleep` / `time.Sleep`.
2. **Isolation** -- Each Elixir test cleans the Gateway.Registry in `setup`. Each Go test starts its own mock server on port 0 (OS-assigned).
3. **Speed** -- Target < 30 seconds for each test suite (Elixir gRPC integration, Go integration).
4. **Observability** -- Tests verify PubSub events and telemetry emissions, not just Registry state.
5. **Async safety** -- Elixir integration tests use `async: false` (shared Gateway.Registry state). Go tests are independent and safe for `go test -parallel`.

---

## Assumptions / System Model

1. The gRPC gateway server (`Cortex.Gateway.GrpcServer`) starts on port 4001 (configurable) as part of the supervision tree. In tests, it starts on a dynamic port to avoid conflicts.
2. The gRPC server uses the `grpc` hex package and implements the `AgentGateway.Connect` bidirectional streaming RPC per the proto contract in `proto/cortex/gateway/v1/gateway.proto`.
3. The gRPC server writes to the same `Cortex.Gateway.Registry` as the Phoenix Channel. Agents connected via gRPC and via Phoenix appear identically in the registry (the `channel_pid` field or a new `stream_pid` field tracks the gRPC stream process).
4. PubSub events from gRPC connections use the same event types and payloads as Phoenix Channel connections. The existing `Cortex.Events.broadcast/2` function is used.
5. The `grpc` hex package provides an Elixir gRPC client that can be used in tests to simulate the sidecar side (opening a Connect stream, sending AgentMessages, receiving GatewayMessages).
6. The Go sidecar uses `google.golang.org/grpc` for the client connection. Stream-level reconnection (re-open stream, re-register) is handled by the sidecar; connection-level reconnection is handled by gRPC's built-in keepalive.
7. Auth: the gRPC server validates the `auth_token` field in `RegisterRequest` against `Cortex.Gateway.Auth` (same module used by Phoenix Channel auth).
8. Generated protobuf code exists at `lib/cortex/gateway/proto/` (Elixir) and `sidecar/internal/proto/gatewayv1/` (Go), produced by the Proto & Codegen Engineer.

---

## Data Model (as relevant to your role)

The integration tests work with existing and new data structures:

| Struct / Message | Location | Role in Tests |
|------------------|----------|---------------|
| `RegisteredAgent` | `Cortex.Gateway.RegisteredAgent` | Verify registration populates all fields; confirm gRPC agents look identical to Phoenix agents |
| `RegisterRequest` | `cortex.gateway.v1` (protobuf) | Build registration messages for gRPC test client |
| `RegisterResponse` | `cortex.gateway.v1` (protobuf) | Assert agent_id returned, peer_count correct |
| `Heartbeat` | `cortex.gateway.v1` (protobuf) | Send heartbeat, verify registry update |
| `TaskRequest` | `cortex.gateway.v1` (protobuf) | Push to agent via stream, verify receipt |
| `TaskResult` | `cortex.gateway.v1` (protobuf) | Send from test client, verify PubSub event |
| `StatusUpdate` | `cortex.gateway.v1` (protobuf) | Send from test client, verify registry + PubSub |
| `PeerRequest` | `cortex.gateway.v1` (protobuf) | Route between two streams |
| `PeerResponse` | `cortex.gateway.v1` (protobuf) | Route response back to requester's stream |
| `AgentMessage` | `cortex.gateway.v1` (protobuf) | Wrapper `oneof` for all agent-to-gateway messages |
| `GatewayMessage` | `cortex.gateway.v1` (protobuf) | Wrapper `oneof` for all gateway-to-agent messages |

No new data models are introduced by the test suite.

---

## APIs (as relevant to your role)

The tests exercise two API surfaces:

### 1. gRPC AgentGateway Service (Elixir tests act as gRPC client)

| RPC | Stream Direction | Test Coverage |
|-----|-----------------|---------------|
| `Connect` | Bidirectional | Open stream, send Register/Heartbeat/TaskResult/StatusUpdate/PeerResponse, receive Registered/TaskRequest/PeerRequest/RosterUpdate/Error |

### 2. Sidecar Local HTTP API (Go tests hit the sidecar's HTTP endpoints)

| Method | Path | Test Coverage |
|--------|------|---------------|
| `GET` | `/health` | Sidecar reports connected/disconnected |
| `GET` | `/roster` | Returns agents from cached RosterUpdate |
| `POST` | `/status` | Sends StatusUpdate via gRPC stream |
| `POST` | `/ask/:agent_id` | Sends PeerRequest, waits for PeerResponse |
| `POST` | `/ask/capable/:capability` | Routes by capability |

### 3. Full end-to-end (`make integration-test`)

Starts the real Elixir gateway + real Go sidecar binary, runs a smoke test that verifies registration, heartbeat, and roster sync over the actual network.

---

## Architecture / Component Boundaries

### Elixir-side test architecture

```
ExUnit Test Process
  |
  |-- GrpcHelpers.connect_grpc_client(port)
  |     |-- Opens gRPC Connect stream (Elixir gRPC client)
  |     |-- Returns stream handle for send/receive
  |
  |-- Gateway (started by test app supervision tree)
  |     |-- GrpcServer (gRPC data plane, dynamic port in tests)
  |     |-- Gateway.Registry (shared GenServer)
  |     |-- Gateway.Health (periodic health checks)
  |
  |-- Cortex.Events / Gateway.Events (PubSub verification)
  |-- Registry.get/list/count (state verification)
```

### Go-side test architecture

```
Go Test Process
  |
  |-- testutil.StartMockServer()
  |     |-- Starts mock AgentGateway gRPC server on port 0
  |     |-- Records received messages for assertion
  |     |-- Can push TaskRequest/PeerRequest on demand
  |
  |-- gateway.NewClient(mockAddr)
  |     |-- Connects to mock server via gRPC
  |     |-- Opens Connect stream, registers
  |
  |-- api.NewRouter(state, client)
  |     |-- Starts HTTP server on port 0
  |     |-- Tests hit HTTP endpoints as an agent would
  |
  |-- Assertions: check mock server received messages,
  |               check HTTP responses, check state cache
```

---

## Correctness Invariants (must be explicit)

1. **Registration parity:** A gRPC-registered agent and a Phoenix-Channel-registered agent with the same name/capabilities must produce identical `RegisteredAgent` structs in the Registry (same fields populated, same status lifecycle).
2. **PubSub parity:** gRPC agent registration must emit `:agent_registered` with the same payload structure as Phoenix Channel registration. Same for `:agent_unregistered` and `:agent_status_changed`.
3. **Heartbeat updates:** After a Heartbeat message on a gRPC stream, `Registry.get(agent_id).last_heartbeat` must be more recent than `registered_at`.
4. **Stream disconnect cleanup:** When a gRPC stream process dies, the Registry must remove the agent (via Process.monitor on the stream process, same as Phase 1 monitors Channel pids).
5. **TaskRequest delivery:** A TaskRequest pushed into the gateway for a gRPC-connected agent must arrive on that agent's Connect stream as a GatewayMessage.
6. **PeerRequest routing:** A PeerRequest targeting an agent by capability must be delivered to the correct agent's stream. The PeerResponse from that agent must be routed back to the requester.
7. **Sidecar re-registration:** After stream drop, the sidecar must re-open the Connect stream and send a new RegisterRequest. The gateway assigns a new agent_id. The old agent_id must not exist in the Registry.
8. **RosterUpdate propagation:** When an agent registers or unregisters, all connected gRPC streams should receive a RosterUpdate. The sidecar caches this, and `GET /roster` returns the cached list.
9. **Auth enforcement:** A RegisterRequest with an invalid `auth_token` must be rejected (gateway sends Error message and closes the stream).

---

## Tests

### `test/cortex/gateway/grpc_integration_test.exs` (Elixir-side, 8 tests)

| Test | Description | Verification |
|------|-------------|--------------|
| `connect_and_register_via_grpc` | Open Connect stream, send RegisterRequest | RegisterResponse received with agent_id; Registry.get(agent_id) returns correct agent |
| `heartbeat_updates_registry` | Send Heartbeat with load data | Registry agent's last_heartbeat updated, load map matches |
| `stream_disconnect_removes_agent` | Close gRPC stream or kill stream process | Agent removed from Registry; `:agent_unregistered` PubSub event with reason `:channel_down` (or `:stream_down`) |
| `task_request_pushed_to_stream` | Push TaskRequest to gRPC agent via registry | Agent's stream receives GatewayMessage with task_request; task_id and prompt match |
| `task_result_emits_pubsub` | Send TaskResult via stream | PubSub event emitted (or task routing called); task_id and status propagated |
| `status_update_changes_registry` | Send StatusUpdate via stream | Registry status updated to new value; `:agent_status_changed` PubSub event emitted |
| `peer_request_routed_between_streams` | Agent A sends PeerRequest targeting B, B sends PeerResponse | A receives PeerResponse on its stream; round-trip completes |
| `grpc_agents_emit_same_pubsub_as_phoenix` | Register agent via gRPC, compare PubSub events | Same event types and payload keys as Phase 1 integration test |

### `sidecar/internal/integration_test.go` (Go-side, 6 tests)

| Test | Description | Verification |
|------|-------------|--------------|
| `TestClient_RegisterAndReceiveID` | Client connects to mock server, sends RegisterRequest | Mock receives RegisterRequest; client receives RegisterResponse with agent_id |
| `TestClient_HeartbeatInterval` | Client sends periodic heartbeats | Mock records >= 2 Heartbeat messages within 2x configured interval |
| `TestClient_ReconnectAfterStreamDrop` | Mock server closes stream | Client re-opens stream, sends new RegisterRequest; mock records 2 RegisterRequests total |
| `TestHTTP_RosterFromCachedState` | Mock pushes RosterUpdate, test hits GET /roster | HTTP response contains agents from the pushed RosterUpdate |
| `TestHTTP_AskSendsPeerRequest` | Test hits POST /ask/:id, mock responds with PeerResponse | HTTP response contains mock's PeerResponse data; mock records PeerRequest |
| `TestHTTP_StatusSendsUpdate` | Test hits POST /status | Mock records StatusUpdate with correct fields |

### `test/support/grpc_helpers.ex` (Elixir helpers)

| Function | Purpose |
|----------|---------|
| `connect_grpc(port, opts \\ [])` | Opens a gRPC Connect stream to localhost:port. Returns `{:ok, stream}` |
| `send_register(stream, name, role, capabilities, token)` | Sends RegisterRequest, waits for RegisterResponse. Returns `{:ok, agent_id}` |
| `send_heartbeat(stream, agent_id, status, load)` | Sends Heartbeat via stream |
| `send_task_result(stream, task_id, status, result_text)` | Sends TaskResult via stream |
| `send_status_update(stream, agent_id, status, detail)` | Sends StatusUpdate via stream |
| `send_peer_response(stream, request_id, status, result)` | Sends PeerResponse via stream |
| `receive_gateway_message(stream, timeout \\ 5000)` | Receives next GatewayMessage from stream |
| `assert_gateway_event(event_type, opts \\ [])` | Asserts a PubSub event was received (wraps assert_receive) |

### `sidecar/internal/testutil/mock_server.go` (Go mock server)

| Function / Method | Purpose |
|-------------------|---------|
| `NewMockServer()` | Creates mock server instance |
| `Start() (addr string, cleanup func())` | Starts gRPC server on port 0, returns address and cleanup |
| `PushTaskRequest(task_id, prompt string)` | Pushes TaskRequest to all connected streams |
| `PushPeerRequest(request_id, from, capability, prompt string)` | Pushes PeerRequest to all connected streams |
| `CloseStreamAfter(n int)` | Configures mock to close stream after N received messages |
| `ReceivedMessages() []proto.AgentMessage` | Returns all received AgentMessage values for assertion |
| `WaitForMessage(type string, timeout time.Duration) (proto.AgentMessage, error)` | Blocks until a message of the given type is received |

---

## Benchmarks + "Success"

Benchmarks are N/A for integration tests. Success criteria:

| Metric | Target |
|--------|--------|
| Elixir gRPC integration tests pass | 8 tests, 0 failures |
| Go integration tests pass | 6 tests, 0 failures |
| Elixir suite runtime | < 30 seconds |
| Go suite runtime | < 30 seconds |
| No flaky tests | 10 consecutive runs with 0 failures |
| PubSub parity verified | gRPC agents produce identical events to Phoenix agents |
| End-to-end smoke test | `make integration-test` passes (Go sidecar -> real Elixir gateway) |

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### 1. Elixir gRPC test client vs. raw TCP

**Decision:** Use the `grpc` hex package's client to open a real gRPC Connect stream from the test process, rather than using raw TCP or mocking the transport.

**Why:** The integration tests must verify the proto contract end-to-end. Using the same gRPC library as a real client would means we test serialization, stream lifecycle, and error codes exactly as they would occur in production. The Phase 1 tests used `Phoenix.ChannelTest` helpers (in-process), but gRPC tests should exercise the actual network stack to catch transport-level issues.

**Tradeoff:** Tests are slightly slower (real TCP connections vs in-process). Mitigated by starting the gRPC server on localhost with minimal startup overhead.

### 2. Go mock server vs. real Elixir gateway for Go tests

**Decision:** Go-side tests use a Go mock gRPC server (`testutil/mock_server.go`) rather than starting the real Elixir gateway.

**Why:** Go unit/integration tests should be self-contained and runnable with `go test` alone, without requiring an Elixir runtime. The mock server implements the proto contract, allowing us to test the sidecar's gRPC client logic, reconnection, and HTTP API in isolation. Full cross-language end-to-end testing is covered separately by `make integration-test`.

**Tradeoff:** The mock server may diverge from the real gateway's behavior. Mitigated by (a) both sides testing against the same proto contract, and (b) the `make integration-test` smoke test catching mismatches.

### 3. Separate test files for Elixir and Go vs. a single cross-language test harness

**Decision:** Keep Elixir and Go integration tests as separate test suites, each runnable independently via `mix test` and `go test`. Add a `make integration-test` target for cross-language smoke testing.

**Why:** Each ecosystem has mature testing infrastructure. Mixing them in a single harness adds complexity (process orchestration, output parsing, startup sequencing) for marginal benefit. The proto contract is the shared interface -- as long as both sides test against it, compatibility is assured.

**Tradeoff:** We need a separate `make` target for the true end-to-end test. This is a small addition to the Makefile.

---

## Risks & Mitigations (REQUIRED)

### 1. `grpc` hex package may not support test client usage easily

**Risk:** The `grpc` Elixir package is primarily designed for building gRPC servers. Its client capabilities may be limited or undocumented, making it harder to write a test client that opens a bidirectional stream.

**Mitigation:** If the `grpc` hex package's client is insufficient, use `gun` (HTTP/2 client) or `mint` to open a raw HTTP/2 connection and frame gRPC messages manually. Alternatively, use a Go test client called via `System.cmd` as a last resort. Evaluate the `grpc` client capabilities early in implementation.

### 2. Proto codegen not ready when tests are written

**Risk:** The integration tests depend on generated protobuf modules (`Cortex.Gateway.Proto.*` in Elixir, `gatewayv1` package in Go). If the Proto & Codegen Engineer hasn't completed codegen, the tests won't compile.

**Mitigation:** Write tests against the expected module/function names from the proto contract in the kickoff doc. Tests can be written, reviewed, and even partially run (compile-check) before codegen lands. Use `@tag :pending` on tests that require proto modules not yet generated.

### 3. gRPC server not ready when tests are written

**Risk:** The `GrpcServer` module (Gateway gRPC Engineer's scope) may not be implemented when integration tests are started.

**Mitigation:** The Elixir test helpers (`grpc_helpers.ex`) abstract the client setup. Tests can be written against the expected behavior. When `GrpcServer` lands, the tests should pass immediately if the implementation matches the proto contract. This is the same approach Phase 1 used -- tests were written alongside the channel implementation.

### 4. PeerRequest routing may not be implemented in Phase 2

**Risk:** The `peer_request_routed_between_streams` test requires the gateway to route PeerRequests between gRPC streams. This routing logic may be deferred to Phase 3.

**Mitigation:** Tag the PeerRequest routing test with `@tag :phase3` so it can be skipped until routing is implemented. Document the expected behavior in the test so it serves as a specification. The test is ready to enable as soon as routing lands.

### 5. Port conflicts in CI for gRPC server

**Risk:** If the gRPC test server starts on a hardcoded port (4001), it will conflict with other test runs or the dev server.

**Mitigation:** Configure the gRPC server to start on port 0 (OS-assigned) in the test environment. The test helpers read the actual port from the server after startup. This is the same pattern used for the Go mock server and is standard practice for test servers.

---

# Recommended API Surface

## Elixir Test Helper Module: `Cortex.GrpcHelpers`

```
connect_grpc(port, opts \\ []) :: {:ok, stream} | {:error, reason}
send_register(stream, name, role, capabilities, token) :: {:ok, agent_id} | {:error, reason}
send_heartbeat(stream, agent_id, status, load) :: :ok
send_task_result(stream, task_id, status, result_text) :: :ok
send_status_update(stream, agent_id, status, detail) :: :ok
send_peer_response(stream, request_id, status, result) :: :ok
receive_gateway_message(stream, timeout \\ 5000) :: {:ok, GatewayMessage.t()} | {:error, :timeout}
assert_gateway_event(event_type, opts \\ []) :: map()
```

## Go Mock Server: `testutil.MockServer`

```go
func NewMockServer() *MockServer
func (s *MockServer) Start() (addr string, cleanup func())
func (s *MockServer) PushTaskRequest(taskID, prompt string)
func (s *MockServer) PushPeerRequest(requestID, from, capability, prompt string)
func (s *MockServer) CloseStreamAfter(n int)
func (s *MockServer) ReceivedMessages() []*pb.AgentMessage
func (s *MockServer) WaitForMessage(msgType string, timeout time.Duration) (*pb.AgentMessage, error)
```

---

# Folder Structure

```
test/
  cortex/
    gateway/
      grpc_integration_test.exs    # Elixir-side gRPC integration tests (8 tests)
  support/
    grpc_helpers.ex                # Elixir gRPC test client helpers

sidecar/
  internal/
    integration_test.go            # Go-side integration tests (6 tests)
    testutil/
      mock_server.go               # Go mock gRPC server for sidecar tests
```

Ownership:
- `test/cortex/gateway/grpc_integration_test.exs` -- Integration Test Engineer
- `test/support/grpc_helpers.ex` -- Integration Test Engineer
- `sidecar/internal/integration_test.go` -- Integration Test Engineer
- `sidecar/internal/testutil/mock_server.go` -- Integration Test Engineer
- All gateway/sidecar implementation code -- other engineers

---

# Step-by-Step Task Plan

## Task 1: Elixir gRPC test helpers
- Create `test/support/grpc_helpers.ex` with connect/send/receive/assert functions
- Verify: `mix compile --warnings-as-errors`
- Commit: `test(gateway): add gRPC test client helpers`

## Task 2: Go mock gRPC server
- Create `sidecar/internal/testutil/mock_server.go` implementing AgentGateway.Connect
- Verify: `cd sidecar && go build ./internal/testutil/...`
- Commit: `test(sidecar): add mock gRPC server for integration tests`

## Task 3: Elixir gRPC integration tests -- core lifecycle
- Create `test/cortex/gateway/grpc_integration_test.exs`
- Tests: connect_and_register, heartbeat_updates_registry, stream_disconnect_removes_agent, task_request_pushed_to_stream
- Verify: `mix test test/cortex/gateway/grpc_integration_test.exs --trace`
- Commit: `test(gateway): add core gRPC integration tests for registration and lifecycle`

## Task 4: Elixir gRPC integration tests -- events and routing
- Add to `grpc_integration_test.exs`: task_result_emits_pubsub, status_update_changes_registry, grpc_agents_emit_same_pubsub_as_phoenix, peer_request_routed_between_streams
- Verify: `mix test test/cortex/gateway/grpc_integration_test.exs --trace`
- Commit: `test(gateway): add gRPC event emission and peer routing integration tests`

## Task 5: Go sidecar integration tests
- Create `sidecar/internal/integration_test.go`
- Tests: register_and_receive_id, heartbeat_interval, reconnect_after_stream_drop, roster_from_cached_state, ask_sends_peer_request, status_sends_update
- Verify: `cd sidecar && go test -v ./internal/...`
- Commit: `test(sidecar): add Go-side integration tests for client, HTTP API, and reconnect`

## Task 6: End-to-end Makefile target
- Add `integration-test` target to root Makefile that starts gateway, builds sidecar, runs sidecar against real gateway, verifies registration
- Verify: `make integration-test`
- Commit: `test(e2e): add make integration-test for cross-language smoke test`

---

# Tighten the plan into 4-7 small tasks (STRICT)

### Task 1: Create Elixir gRPC test helpers and Go mock server
- **Outcome:** `Cortex.GrpcHelpers` module with connect/send/receive/assert functions. `testutil.MockServer` Go struct implementing the AgentGateway Connect stream with message recording.
- **Files to create:** `test/support/grpc_helpers.ex`, `sidecar/internal/testutil/mock_server.go`
- **Exact verification:** `mix compile --warnings-as-errors` and `cd sidecar && go build ./internal/testutil/...`
- **Suggested commit message:** `test(gateway): add gRPC test helpers and Go mock server`

### Task 2: Elixir gRPC integration tests -- core lifecycle (4 tests)
- **Outcome:** 4 passing tests: connect_and_register_via_grpc, heartbeat_updates_registry, stream_disconnect_removes_agent, task_request_pushed_to_stream.
- **Files to create:** `test/cortex/gateway/grpc_integration_test.exs`
- **Exact verification:** `mix test test/cortex/gateway/grpc_integration_test.exs --trace`
- **Suggested commit message:** `test(gateway): add core gRPC lifecycle integration tests`

### Task 3: Elixir gRPC integration tests -- events and routing (4 tests)
- **Outcome:** 4 passing tests: task_result_emits_pubsub, status_update_changes_registry, grpc_agents_emit_same_pubsub_as_phoenix, peer_request_routed_between_streams (last one may be tagged `:phase3`).
- **Files to modify:** `test/cortex/gateway/grpc_integration_test.exs`
- **Exact verification:** `mix test test/cortex/gateway/grpc_integration_test.exs --trace`
- **Suggested commit message:** `test(gateway): add gRPC event parity and peer routing tests`

### Task 4: Go sidecar integration tests (6 tests)
- **Outcome:** 6 passing Go tests covering: client registration, heartbeat interval, stream reconnect, roster caching via HTTP, ask sends PeerRequest, status sends update.
- **Files to create:** `sidecar/internal/integration_test.go`
- **Exact verification:** `cd sidecar && go test -v -run Integration ./internal/...`
- **Suggested commit message:** `test(sidecar): add Go integration tests for client and HTTP API`

### Task 5: End-to-end smoke test via Makefile
- **Outcome:** `make integration-test` starts the Elixir gateway, builds the Go sidecar, runs the sidecar against the real gateway, and verifies registration + heartbeat.
- **Files to create/modify:** `Makefile` (add `integration-test` target)
- **Exact verification:** `make integration-test`
- **Suggested commit message:** `test(e2e): add cross-language integration smoke test`

---

# CLAUDE.md contributions (do NOT write the file; propose content)

## From Integration Test Engineer

```
## gRPC Integration Tests
- `mix test test/cortex/gateway/grpc_integration_test.exs` -- Elixir-side gRPC gateway tests
- `cd sidecar && go test -v ./internal/...` -- Go-side sidecar integration tests
- `make integration-test` -- full end-to-end smoke test (Go sidecar -> Elixir gateway)
- gRPC integration tests use `async: false` (shared Gateway.Registry state)
- `test/support/grpc_helpers.ex` provides `connect_grpc/2`, `send_register/5`, etc.
- `sidecar/internal/testutil/mock_server.go` provides a mock gRPC server for Go tests
- Set `CORTEX_GATEWAY_TOKEN` in test setup for auth (same pattern as Phase 1 gateway tests)
- Tests tagged `@tag :phase3` require peer routing infrastructure (Phase 3)
```

---

# EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

- **gRPC Integration Testing Strategy**: How Elixir tests use a real gRPC client to open Connect streams against the test-mode gateway server, while Go tests use a mock gRPC server for isolation.
- **Proto Contract as the Interface**: Both Elixir and Go tests verify behavior against the same `.proto` contract, ensuring compatibility without requiring cross-language test infrastructure.
- **PubSub Parity Testing**: How `grpc_agents_emit_same_pubsub_as_phoenix` verifies that the gRPC data plane produces identical events to the Phoenix Channel control plane, ensuring the LiveView dashboard works with both transports.
- **Go Mock Server Design**: How `testutil.MockServer` records messages for assertion, supports on-demand push of TaskRequest/PeerRequest, and can simulate stream failures for reconnect testing.
- **Reconnect Testing Without Flakiness**: How the Go tests configure short reconnect intervals and use `WaitForMessage` with timeouts rather than `time.Sleep` to test stream re-establishment deterministically.
- **End-to-End Smoke Test Architecture**: How `make integration-test` orchestrates the Elixir gateway and Go sidecar binary for a real cross-language verification.

---

## READY FOR APPROVAL
