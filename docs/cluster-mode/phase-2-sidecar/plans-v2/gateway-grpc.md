# Gateway gRPC Engineer — Plan

## You are in PLAN MODE.

### Project
I want to do a **gRPC data-plane server for the Cortex agent gateway**.

**Goal:** build a **gRPC bidirectional streaming endpoint** in which we **accept agent connections via the `AgentGateway.Connect` RPC, writing to the same `Gateway.Registry` and emitting the same PubSub events as the existing Phoenix Channel control plane, so that gRPC-connected agents and WebSocket-connected agents are indistinguishable from the perspective of the registry, health monitor, and dashboard**.

### Role + Scope (fill in)
- **Role:** Gateway gRPC Engineer
- **Scope:** I own the Elixir-side gRPC server implementation (`grpc` hex package), the gRPC endpoint configuration, and the Registry extensions needed to track gRPC stream pids. I do NOT own the protobuf definitions (Proto & Codegen Engineer), the Go sidecar (Sidecar Core / HTTP API Engineers), or the end-to-end integration tests (Integration Test Engineer).
- **File I will write:** `/docs/cluster-mode/phase-2-sidecar/plans-v2/gateway-grpc.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** Implement the `AgentGateway.Connect` bidirectional stream RPC using the `grpc` hex package. Each connected sidecar gets a single long-lived stream.
- **FR2:** On `RegisterRequest`: validate auth token via `Gateway.Auth`, build a `RegisteredAgent`, add to `Gateway.Registry`, and push `RegisterResponse` back on the stream.
- **FR3:** On `Heartbeat`: update `last_heartbeat` and `load` in `Gateway.Registry` via `update_heartbeat/2`.
- **FR4:** On `TaskResult`: emit PubSub event via `Cortex.Events` and `Gateway.Events`, route to the task caller (placeholder for Phase 3).
- **FR5:** On `StatusUpdate`: update status in Registry via `update_status/3`, emit PubSub event.
- **FR6:** On `PeerResponse`: route back to the requesting agent's stream process (via Registry stream pid lookup).
- **FR6a:** On `DirectMessage`: look up `to_agent` in Registry, push the `DirectMessage` to that agent's stream (set `from_agent` to the sender's ID). If target not found, push an `Error` back.
- **FR6b:** On `BroadcastRequest`: iterate all agents in Registry except the sender, push a `DirectMessage` with the broadcast content to each stream.
- **FR7:** Push `TaskRequest`, `PeerRequest`, `DirectMessage`, and `RosterUpdate` messages to the agent's stream proactively from the server side.
- **FR8:** On stream disconnect: unregister agent from Registry (automatic via `Process.monitor` on the stream process).
- **FR9:** Start the gRPC server on port 4001 (configurable via application config) as a child of `Gateway.Supervisor`.
- **FR10:** Extend `RegisteredAgent` to support a `stream_pid` field alongside `channel_pid` for gRPC agents.
- **Tests required:** Unit tests for the gRPC server handler logic and the Registry extensions. Integration-level tests that open a gRPC stream, register, heartbeat, and disconnect are in scope for the Integration Test Engineer but basic server-level tests belong here.
- **Metrics required:** Telemetry events for gRPC stream connect/disconnect/error, matching the existing `[:cortex, :gateway, ...]` namespace.

## Non-Functional Requirements
- **Language/runtime:** Elixir/OTP, using the `grpc` hex package (~> 0.9).
- **Local dev:** Plaintext gRPC on port 4001 by default. TLS optional (not required for dev).
- **Observability:** Emit telemetry events on stream open, register, heartbeat, disconnect, and error. Reuse the existing `Cortex.Events` and `Gateway.Events` PubSub topics — the LiveView dashboard sees gRPC agents with zero changes.
- **Safety:** Auth validation before any state mutation. Reject messages from unregistered streams (heartbeat, task_result, status_update) until RegisterRequest succeeds. Stream processes are supervised and monitored — a crash or disconnect triggers automatic cleanup.
- **Documentation:** `@moduledoc`, `@doc`, `@spec` on all public functions per project conventions.
- **Performance:** Each stream process is lightweight (holds only agent state + stream reference). The Registry GenServer is the serialization point — same as the Phoenix Channel path. No additional bottleneck introduced.

---

## Assumptions / System Model
- **Deployment environment:** Single-node Elixir application for Phase 2. BEAM distribution (multi-node) is out of scope.
- **Failure modes:** Stream process crash -> monitored by Registry, agent auto-unregistered. Registry crash -> Supervisor restarts it, all agents must re-register (same as Phase 1). gRPC endpoint crash -> Supervisor restarts the GRPC.Server.
- **Delivery guarantees:** Best-effort push for server-to-agent messages (TaskRequest, PeerRequest, RosterUpdate). If the stream is dead, the message is lost. The sidecar is responsible for re-registering and catching up.
- **Multi-tenancy:** Not in scope. Single-tenant, single gateway instance.
- **Proto dependency:** This role depends on generated Elixir protobuf modules from the Proto & Codegen Engineer. The plan assumes those modules exist at `lib/cortex/gateway/proto/` (or a similar path configured by `buf.gen.yaml`).

---

## Data Model (as relevant to your role)

### RegisteredAgent Extension

The existing `RegisteredAgent` struct needs to support both Phoenix Channel pids and gRPC stream pids. Changes:

```
# Current @enforce_keys
[:id, :name, :role, :capabilities, :channel_pid, :monitor_ref]

# New: make channel_pid optional, add stream_pid
@enforce_keys [:id, :name, :role, :capabilities, :monitor_ref]
defstruct [
  :id, :name, :role, :capabilities,
  :channel_pid,    # Phoenix Channel pid (nil for gRPC agents)
  :stream_pid,     # gRPC stream process pid (nil for WS agents)
  :monitor_ref,
  :registered_at, :last_heartbeat,
  status: :idle,
  transport: :websocket,  # :websocket | :grpc
  metadata: %{},
  load: %{active_tasks: 0, queue_depth: 0}
]
```

Key design decisions:
- `channel_pid` is no longer `@enforce_keys` — gRPC agents won't have one.
- New `stream_pid` field for gRPC stream process pids.
- New `transport` field (`:websocket` | `:grpc`) to distinguish connection type when needed (e.g., for routing pushes).
- The existing `monitor_ref` is reused — it monitors whichever pid is active (`channel_pid` or `stream_pid`).

### gRPC Stream Process State

Each `Connect` stream handler maintains internal state:

```
%{
  agent_id: String.t() | nil,    # Set after registration
  registered: boolean(),          # Gate for pre-registration messages
  stream: GRPC.Server.Stream.t() # The stream reference for pushing messages
}
```

---

## APIs (as relevant to your role)

### New Registry Functions

```elixir
# Register a gRPC agent (stream_pid instead of channel_pid)
Registry.register_grpc(server, agent_info, stream_pid) :: {:ok, RegisteredAgent.t()} | {:error, term()}

# Get the stream pid for pushing messages to a gRPC agent
Registry.get_stream(server, agent_id) :: {:ok, pid()} | {:error, :not_found}

# Get the appropriate push pid (channel_pid or stream_pid) regardless of transport
Registry.get_push_pid(server, agent_id) :: {:ok, {transport, pid()}} | {:error, :not_found}
```

### gRPC Server Module

```elixir
# Implements the generated AgentGateway.Service behaviour
defmodule Cortex.Gateway.GrpcServer do
  use GRPC.Server, service: Cortex.Gateway.Proto.AgentGateway.Service

  # Bidirectional stream handler
  def connect(stream, _server) :: stream
end
```

### gRPC Endpoint Module

```elixir
defmodule Cortex.Gateway.GrpcEndpoint do
  # Starts the GRPC.Server on the configured port
  def child_spec(opts)
  def start_link(opts)
end
```

---

## Architecture / Component Boundaries (as relevant)

```
                     ┌──────────────────────────────────┐
                     │       Gateway.Supervisor          │
                     │  (one_for_one)                    │
                     │                                   │
                     │  ┌────────────────┐               │
                     │  │ Gateway.Registry│ <── shared ──│── Phoenix Channel
                     │  └────────────────┘               │       writes here too
                     │          ▲                         │
                     │          │                         │
                     │  ┌───────┴────────┐               │
                     │  │ Gateway.Health  │               │
                     │  └────────────────┘               │
                     │                                   │
                     │  ┌────────────────┐               │
                     │  │ GrpcEndpoint   │ ← NEW         │
                     │  │ (GRPC.Server)  │               │
                     │  │  port 4001     │               │
                     │  └───────┬────────┘               │
                     │          │ spawns per connection   │
                     │          ▼                         │
                     │  ┌────────────────┐               │
                     │  │ GrpcServer     │ ← NEW         │
                     │  │ (stream proc)  │               │
                     │  │ one per agent  │               │
                     │  └────────────────┘               │
                     └──────────────────────────────────┘
```

Key boundaries:
- `GrpcEndpoint` is a child of `Gateway.Supervisor`, responsible for starting/stopping the gRPC server.
- `GrpcServer` implements the `AgentGateway.Service` behaviour. Each `Connect` call spawns a stream handler process managed by the `grpc` library.
- Stream handler processes call `Gateway.Registry` for all state mutations — no local state duplication.
- The `grpc` library manages the HTTP/2 transport; we only implement the service handler.

---

## Correctness Invariants (must be explicit)

1. **Single source of truth:** The `Gateway.Registry` is the ONLY place agent state lives. gRPC stream handlers hold only transient state (agent_id, registration flag, stream reference).
2. **Registration gate:** Messages received before a successful `RegisterRequest` are rejected with an error pushed back on the stream. No state mutation occurs for unregistered streams.
3. **Auth before state:** `Gateway.Auth.authenticate/1` is called before `Registry.register_grpc/3`. A failed auth rejects the stream with an Error message and does not touch the Registry.
4. **Monitor invariant:** Every registered agent has exactly one `Process.monitor` reference on its connection pid (channel_pid or stream_pid). When that pid dies, the agent is automatically unregistered.
5. **Transport-agnostic registry:** `Registry.list/0`, `Registry.list_by_capability/1`, `Registry.get/1` return agents regardless of transport type. The dashboard, health monitor, and all consumers see a unified view.
6. **PubSub event parity:** gRPC registration, unregistration, heartbeat, and status changes emit the same event types and payloads as the Phoenix Channel path. No new event types are introduced — only a new source.
7. **No duplicate registration:** A stream process can register at most once. Subsequent RegisterRequest messages on the same stream are rejected.

---

## Tests

### Unit Tests (`test/cortex/gateway/grpc_server_test.exs`)

1. **Registration flow:** Simulate sending a RegisterRequest on a Connect stream. Assert the agent appears in the Registry with correct fields, transport is `:grpc`, and a RegisterResponse is pushed.
2. **Auth rejection:** Send a RegisterRequest with an invalid token. Assert an Error is pushed and the Registry is unchanged.
3. **Duplicate registration:** Send two RegisterRequests on the same stream. Assert the second is rejected.
4. **Heartbeat updates:** Register, then send a Heartbeat. Assert `last_heartbeat` is updated in the Registry.
5. **Heartbeat before registration:** Send a Heartbeat without registering first. Assert an Error is pushed.
6. **Status update:** Register, then send a StatusUpdate. Assert the Registry status changes and a PubSub event is emitted.
7. **Task result:** Register, then send a TaskResult. Assert a PubSub event is emitted.
8. **Stream disconnect cleanup:** Register, then terminate the stream process. Assert the agent is removed from the Registry.
9. **Peer response routing:** Register two agents on separate streams. Send a PeerResponse from agent A referencing a request from agent B. Assert the response reaches agent B's stream.

### Registry Extension Tests (`test/cortex/gateway/registry_test.exs` — additions)

10. **register_grpc:** Register via `register_grpc/3`. Assert `stream_pid` is set, `channel_pid` is nil, `transport` is `:grpc`.
11. **get_stream:** Register a gRPC agent. Assert `get_stream/2` returns the stream pid.
12. **get_push_pid:** Register both a WS and gRPC agent. Assert `get_push_pid/2` returns the correct transport/pid tuple for each.
13. **Monitor cleanup (gRPC):** Register via `register_grpc/3`, kill the stream pid. Assert the agent is removed via the existing `:DOWN` handler.

---

## Benchmarks + "Success"

**Success criteria:**
- A gRPC client (Elixir test client using the generated proto modules) can open a Connect stream, register, send heartbeats, receive task requests, and disconnect cleanly.
- The same agent appears in `Registry.list/0` whether connected via gRPC or Phoenix Channel.
- The LiveView dashboard shows gRPC-connected agents without any dashboard code changes.
- `Gateway.Health` marks stale gRPC agents as disconnected using the same heartbeat timeout logic.
- All unit tests pass with `mix test test/cortex/gateway/grpc_server_test.exs`.

**Benchmark plan:**
- Measure stream connection establishment latency (connect + register round trip).
- Measure heartbeat processing throughput (heartbeats/second on a single Registry).
- Compare registry lookup latency with 10, 100, and 500 concurrent agents (mix of gRPC and WS).
- These benchmarks are informational, not gating. Target: sub-1ms for registration and heartbeat processing at 500 agents.

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### 1. Extend Registry vs. Separate StreamRegistry

**Decision:** Extend the existing `Gateway.Registry` with `stream_pid` and `transport` fields rather than creating a separate `StreamRegistry`.

**Tradeoff:** Adding fields to the existing struct means the Registry handle_call clauses grow, but all consumers (Health, Dashboard, Discovery) work without changes. A separate StreamRegistry would require merging views everywhere agents are listed, adding complexity for every future consumer.

**Why this wins:** The kickoff explicitly says "Do NOT create a separate StreamRegistry — extend what's already there." Beyond the directive, a unified registry is simpler: one process to monitor, one list to query, one set of PubSub events. The cost is a slightly larger struct and a second registration path (`register_grpc/3`), which is minimal.

### 2. Stream Process Design: Stateless Handler vs. GenServer

**Decision:** Use the `grpc` library's built-in stream handler process (which runs a function per-stream) rather than wrapping each stream in a separate GenServer.

**Tradeoff:** The `grpc` library already spawns a process per stream connection. Adding a GenServer wrapper would give us named processes and OTP supervision, but adds indirection. The stream process already IS a process — we monitor its pid in the Registry, and when it dies, the `:DOWN` message triggers cleanup.

**Why this wins:** Simpler. The `grpc` stream handler holds minimal state (agent_id, registered flag, stream ref). All durable state lives in the Registry. A GenServer wrapper would add boilerplate without functional benefit. If we need to push messages to the stream, we send a message to the stream process's pid (looked up via `Registry.get_stream/2`).

### 3. Auth in RegisterRequest vs. gRPC Metadata

**Decision:** Validate the auth token from the `RegisterRequest` protobuf message field, not from gRPC metadata headers.

**Tradeoff:** gRPC metadata is the "standard" place for auth (like HTTP headers), but the kickoff specifies token in the RegisterRequest message for simplicity. This means auth happens after the stream opens, not at connection time. An attacker could open a stream and hold it without registering, consuming a connection slot.

**Why this wins:** Simpler implementation, consistent with the proto contract, and the registration timeout (adopted from the Phoenix Channel pattern) mitigates idle connections. Can migrate to per-RPC credentials later if needed.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: `grpc` hex package maturity
The `grpc` Elixir package is less battle-tested than `google.golang.org/grpc` on the Go side. Bidirectional streaming edge cases (backpressure, partial writes, stream reset) may surface.

**Mitigation:** Write focused integration tests for stream lifecycle (connect, register, disconnect, reconnect). Pin the `grpc` version. If the package proves unreliable, the fallback is `gun` or `mint` with raw HTTP/2 and manual protobuf framing — ugly but possible.

### Risk 2: Registry contention at scale
All gRPC stream processes and all Phoenix Channel processes call the same `Registry` GenServer for mutations. Under high agent counts (hundreds), this could become a bottleneck.

**Mitigation:** The Registry is read-heavy (heartbeats update a single field, registrations are infrequent). GenServer call latency is microseconds for map operations. If contention appears, use ETS for reads and GenServer only for writes — but this is a Phase 3 concern, not Phase 2.

### Risk 3: Proto codegen dependency
The gRPC server implementation depends on generated Elixir modules from the Proto & Codegen Engineer. If the proto schema changes or codegen is delayed, this role is blocked.

**Mitigation:** Define a clear interface contract (the message types and service behaviour). Write the server code against the expected module names. The codegen output is mechanical — field names and module paths are known from the proto definition in the kickoff.

### Risk 4: Stream process message routing
Pushing messages (TaskRequest, PeerRequest, RosterUpdate) to a gRPC agent requires sending a message to the stream process, which then writes to the gRPC stream. The stream process must handle both incoming protobuf messages AND outgoing push messages.

**Mitigation:** The stream process uses `receive` (or the `grpc` library's push API) to handle both directions. The `grpc` library's `GRPC.Server.send_reply/2` API supports pushing messages on bidirectional streams. Test this path explicitly.

### Risk 5: Breaking RegisteredAgent struct changes
Changing `@enforce_keys` and adding fields to `RegisteredAgent` could break existing Phoenix Channel code that creates the struct.

**Mitigation:** Make the change backward-compatible. `channel_pid` stays as a field but is no longer enforced (default nil). Add `stream_pid` and `transport` with defaults. Update the existing `register/3` call in Registry to set `transport: :websocket` explicitly. Run the full test suite after the struct change.

---

# Please produce (no code yet):

## 1) Recommended API Surface

**Registry (extended):**
- `Registry.register_grpc(server, agent_info, stream_pid)` — registers a gRPC agent
- `Registry.get_stream(server, agent_id)` — returns `{:ok, stream_pid}` for gRPC agents
- `Registry.get_push_pid(server, agent_id)` — returns `{:ok, {:grpc | :websocket, pid}}`

**GrpcServer:**
- `GrpcServer.connect(stream, server)` — bidirectional stream handler (called by `grpc` library)
- Internal message handling: `handle_register/2`, `handle_heartbeat/2`, `handle_task_result/2`, `handle_status_update/2`, `handle_peer_response/2`

**GrpcEndpoint:**
- `GrpcEndpoint.child_spec(opts)` — for supervision tree
- `GrpcEndpoint.start_link(opts)` — starts GRPC.Server on configured port

## 2) Folder Structure

```
lib/cortex/gateway/
  grpc_server.ex          # NEW — AgentGateway.Service implementation
  grpc_endpoint.ex        # NEW — GRPC.Server startup/config
  registry.ex             # MODIFIED — add register_grpc, get_stream, get_push_pid
  registered_agent.ex     # MODIFIED — add stream_pid, transport fields
  supervisor.ex           # MODIFIED — add GrpcEndpoint child
  auth.ex                 # UNCHANGED — reused by gRPC path
  health.ex               # UNCHANGED — works with gRPC agents via Registry
  events.ex               # UNCHANGED — reused by gRPC path
  protocol.ex             # UNCHANGED (control plane only)
  proto/                  # Generated protobuf modules (from Proto Engineer)

test/cortex/gateway/
  grpc_server_test.exs    # NEW — gRPC server unit tests
  registry_test.exs       # MODIFIED — add gRPC registration tests
```

## 3) Step-by-step Task Plan

1. **Add `grpc` dependency to `mix.exs`** — `{:grpc, "~> 0.9"}` and `{:protobuf, "~> 0.12"}`.
2. **Extend `RegisteredAgent` struct** — add `stream_pid`, `transport` fields; relax `@enforce_keys`.
3. **Extend `Registry`** — add `register_grpc/3`, `get_stream/2`, `get_push_pid/2`; update existing `register/3` to set `transport: :websocket`.
4. **Implement `GrpcServer`** — bidirectional stream handler with registration gate, auth, and message dispatch.
5. **Implement `GrpcEndpoint`** — start GRPC.Server on port 4001, wire into `Gateway.Supervisor`.
6. **Write tests** — unit tests for GrpcServer message handling, Registry gRPC extensions.
7. **Verify integration** — run full test suite to confirm Phoenix Channel path is unbroken.

## 4) Benchmark Plan

| Metric | Method | Target |
|--------|--------|--------|
| Registration latency | Elixir gRPC test client: time from stream open to RegisterResponse received | < 5ms p99 |
| Heartbeat throughput | Send N heartbeats in a loop, measure total time | > 10,000/sec single Registry |
| Registry lookup at scale | Register 500 agents (mixed WS/gRPC), measure `list/0` and `get/1` latency | < 1ms p99 |
| Stream connect/disconnect | Open and close 100 streams sequentially, measure total time | < 500ms total |

Benchmarks are informational for Phase 2. Gating performance work is deferred to Phase 3.

---

# Tighten the plan into 4-7 small tasks (STRICT)

### Task 1: Extend RegisteredAgent and Registry for gRPC support
- **Outcome:** `RegisteredAgent` supports `stream_pid` and `transport` fields. `Registry` exposes `register_grpc/3`, `get_stream/2`, and `get_push_pid/2`. Existing WS registration path continues to work with `transport: :websocket`.
- **Files to create/modify:**
  - `lib/cortex/gateway/registered_agent.ex` (modify)
  - `lib/cortex/gateway/registry.ex` (modify)
  - `test/cortex/gateway/registry_test.exs` (modify — add gRPC registration tests)
- **Exact verification command(s):**
  - `mix test test/cortex/gateway/registry_test.exs`
  - `mix test test/cortex_web/channels/` (ensure WS tests still pass)
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat(gateway): extend Registry and RegisteredAgent for gRPC transport support`

### Task 2: Add `grpc` and `protobuf` dependencies
- **Outcome:** `grpc` ~> 0.9 and `protobuf` ~> 0.12 are added to `mix.exs` and compile cleanly.
- **Files to create/modify:**
  - `mix.exs` (modify — add deps)
- **Exact verification command(s):**
  - `mix deps.get`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `build(deps): add grpc and protobuf hex packages for Phase 2 data plane`

### Task 3: Implement GrpcServer — Connect stream handler
- **Outcome:** `Cortex.Gateway.GrpcServer` implements the `AgentGateway.Service` behaviour. The `connect/2` handler processes RegisterRequest (with auth), Heartbeat, TaskResult, StatusUpdate, and PeerResponse messages. It pushes Error messages for invalid/gated requests. On disconnect, the agent is unregistered via the Registry monitor.
- **Files to create/modify:**
  - `lib/cortex/gateway/grpc_server.ex` (create)
- **Exact verification command(s):**
  - `mix compile --warnings-as-errors`
  - `mix credo --strict lib/cortex/gateway/grpc_server.ex`
- **Suggested commit message:** `feat(gateway): implement gRPC Connect stream handler for agent registration`

### Task 4: Implement GrpcEndpoint and wire into Supervisor
- **Outcome:** `Cortex.Gateway.GrpcEndpoint` starts a GRPC.Server on port 4001 (configurable). It is added as a child of `Gateway.Supervisor`. The gRPC server accepts connections.
- **Files to create/modify:**
  - `lib/cortex/gateway/grpc_endpoint.ex` (create)
  - `lib/cortex/gateway/supervisor.ex` (modify — add GrpcEndpoint child)
  - `config/config.exs` or `config/dev.exs` (modify — add grpc port config)
- **Exact verification command(s):**
  - `mix compile --warnings-as-errors`
  - `mix test test/cortex/gateway/supervisor_test.exs`
- **Suggested commit message:** `feat(gateway): add gRPC endpoint on port 4001 to Gateway supervisor`

### Task 5: Write GrpcServer unit tests
- **Outcome:** Comprehensive unit tests covering registration, auth rejection, heartbeat, status update, task result, duplicate registration rejection, and stream disconnect cleanup.
- **Files to create/modify:**
  - `test/cortex/gateway/grpc_server_test.exs` (create)
  - `test/support/grpc_helpers.ex` (create — test helpers for gRPC client setup)
- **Exact verification command(s):**
  - `mix test test/cortex/gateway/grpc_server_test.exs`
  - `mix test` (full suite green)
- **Suggested commit message:** `test(gateway): add unit tests for gRPC server stream handler`

### Task 6: Full suite verification and format/lint pass
- **Outcome:** All existing tests pass (Phoenix Channel path unbroken). All new code passes `mix format`, `mix credo --strict`, and `mix compile --warnings-as-errors`.
- **Files to create/modify:** Any files needing format/lint fixes from previous tasks.
- **Exact verification command(s):**
  - `mix format --check-formatted`
  - `mix compile --warnings-as-errors`
  - `mix credo --strict`
  - `mix test`
- **Suggested commit message:** `chore(gateway): format and lint pass for gRPC server implementation`

---

# CLAUDE.md contributions (do NOT write the file; propose content)

## From Gateway gRPC Engineer

```markdown
## gRPC Data Plane (Phase 2)
- gRPC server runs on port 4001 (configurable via `config :cortex, Cortex.Gateway.GrpcEndpoint, port: 4001`)
- `lib/cortex/gateway/grpc_server.ex` — implements AgentGateway.Connect bidirectional stream
- `lib/cortex/gateway/grpc_endpoint.ex` — GRPC.Server startup, child of Gateway.Supervisor
- RegisteredAgent now has `transport` field (`:websocket` | `:grpc`) and `stream_pid` for gRPC agents
- Registry extended with `register_grpc/3`, `get_stream/2`, `get_push_pid/2`
- gRPC agents and WS agents are identical in the registry — same PubSub events, same Health monitoring
- Depends on: `grpc` ~> 0.9, `protobuf` ~> 0.12
- Proto modules generated to `lib/cortex/gateway/proto/` (see Proto & Codegen Engineer)
```

---

# EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

- **Why gRPC for the data plane?** Language-agnostic typed contract via protobuf, bidirectional streaming replaces both request/response and push patterns, industry-standard for service meshes.
- **How the gRPC server integrates with existing infrastructure:** Same Registry, same PubSub events, same Health monitor. The gRPC server is "just another writer" to the Registry — the dashboard and all consumers are transport-agnostic.
- **Stream lifecycle:** Connect -> RegisterRequest (auth) -> RegisterResponse -> Heartbeats -> TaskRequest/PeerRequest pushes -> Disconnect -> auto-unregister.
- **Transport field:** `RegisteredAgent.transport` distinguishes `:websocket` from `:grpc` when routing pushes (Phoenix push vs. gRPC stream write), but is invisible to consumers querying the registry.
- **Why extend Registry instead of creating StreamRegistry:** Single source of truth, all consumers work unchanged, simpler monitoring and cleanup.

---

## READY FOR APPROVAL
