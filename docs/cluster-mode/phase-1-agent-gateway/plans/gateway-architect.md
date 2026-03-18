# Gateway Architect Plan

## You are in PLAN MODE.

### Project
I want to build the **Agent Gateway** for Cortex Cluster Mode.

**Goal:** build a **Phoenix WebSocket gateway** in which **external agents connect, register their capabilities, send heartbeats, report task results, and receive work assignments** -- turning Cortex from a job scheduler into a control plane for an agent mesh.

### Role + Scope
- **Role:** Gateway Architect
- **Scope:** I own the Phoenix Socket and Channel that agents connect to over WebSocket, plus the channel test suite. I do NOT own the Gateway.Registry GenServer (Registry Engineer), the protocol parsing/validation logic (Protocol Engineer), or telemetry/supervision wiring (Integration & Telemetry Engineer). My channel delegates all state management to Gateway.Registry and all message parsing to Gateway.Protocol.
- **File I will write:** `docs/cluster-mode/phase-1-agent-gateway/plans/gateway-architect.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

- **FR1:** A Phoenix Socket (`AgentSocket`) that accepts WebSocket connections at `/agent/websocket`, authenticates via bearer token in connection params, and routes to `AgentChannel`.
- **FR2:** A Phoenix Channel (`AgentChannel`) on topic `"agent:lobby"` that handles:
  - `join/3` -- validates the connecting agent, assigns a socket-scoped agent state.
  - `handle_in("register", payload, socket)` -- delegates to Gateway.Protocol for validation, then to Gateway.Registry for registration; pushes `"registered"` reply.
  - `handle_in("heartbeat", payload, socket)` -- delegates to Gateway.Registry to update health/load; replies with `"heartbeat_ack"`.
  - `handle_in("task_result", payload, socket)` -- delegates to Gateway.Registry / orchestration to route the completed task result.
  - `handle_in("status_update", payload, socket)` -- delegates to Gateway.Registry to update agent status; broadcasts via PubSub for LiveView.
  - `terminate/2` -- notifies Gateway.Registry that the agent disconnected; emits PubSub event.
- **FR3:** Outbound pushes from Cortex to agent:
  - `"registered"` -- confirmation after successful registration.
  - `"task_request"` -- Cortex assigns work (dispatched via the channel pid stored in the registry).
  - `"peer_request"` -- another agent invokes this agent as a tool.
- **FR4:** PubSub event emission on join, leave, status change, and registration so LiveView dashboards update in real time.
- **Tests required:** Unit tests for AgentChannel (join, all handle_in clauses, terminate, outbound pushes, error cases). Use `Phoenix.ChannelTest` helpers.
- **Metrics required:** N/A for channel directly -- the Integration & Telemetry Engineer owns telemetry event emission. The channel will call telemetry helpers but not define them.

## Non-Functional Requirements

- **Language/runtime:** Elixir, Phoenix Channels (WebSocket transport)
- **Local dev:** `mix phx.server` brings up the endpoint; no additional containers needed for the channel itself.
- **Observability:** Channel emits PubSub events (Cortex.Events) and calls telemetry helpers. Logging via `Logger` on connect/disconnect/errors.
- **Safety:** Invalid messages return `{:reply, {:error, reason}, socket}` -- never crash the channel process. Bearer token auth on socket connect rejects unauthenticated connections. Timeout on registration (agent must send `register` within 30s of joining or gets disconnected).
- **Documentation:** Contributions to CLAUDE.md and EXPLAIN.md proposed below.
- **Performance:** Phoenix Channels handle thousands of concurrent WebSocket connections out of the box. No custom pooling needed for MVP.

---

## Assumptions / System Model

- **Deployment environment:** Single BEAM node (local dev via `mix phx.server`; later multi-node with PubSub adapter swap).
- **Failure modes:**
  - WebSocket disconnect (network drop, agent crash) -- `terminate/2` fires, registry marks agent disconnected.
  - Invalid messages -- channel replies with error, does not crash.
  - Registry unavailable (GenServer down) -- channel logs error and replies with `{:error, :service_unavailable}`. The supervisor will restart the registry.
  - Auth failure on connect -- socket `connect/3` returns `:error`, connection refused at transport level.
- **Delivery guarantees:** At-most-once for pushes from Cortex to agent (WebSocket is not durable). Agent should re-register on reconnect.
- **Multi-tenancy:** None for MVP. Single-tenant, single gateway token.

---

## Data Model

The channel itself is stateless beyond socket assigns. All persistent agent state lives in Gateway.Registry (Registry Engineer's scope). The channel stores these assigns in `socket.assigns`:

- **Socket assigns (set in AgentSocket.connect/3):**
  - `connect_time` -- `DateTime.t()`, when the WebSocket was established
  - `remote_ip` -- `String.t()`, peer IP address (from `connect_info`)
  - `authenticated` -- `boolean()`, true if bearer token was valid

- **Channel assigns (set in AgentChannel.join/3 and handle_in("register")):**
  - `agent_id` -- `String.t() | nil`, assigned after successful registration
  - `agent_name` -- `String.t() | nil`, the agent's self-reported name
  - `registered` -- `boolean()`, whether the agent has completed registration
  - `joined_at` -- `DateTime.t()`, when the agent joined the channel

- **Validation rules:**
  - `agent_id` is a UUID v4 string assigned by the registry on registration.
  - `agent_name` must be a non-empty string, max 255 chars, matching `~r/^[a-zA-Z0-9_-]+$/`.
  - `registered` defaults to `false`; set to `true` only after successful `register` handling.
  - Messages received before `registered == true` (other than `"register"`) are rejected.

- **Versioning:** Protocol version is carried in the `register` message and validated by Gateway.Protocol. The channel passes it through; it does not interpret the version itself.

---

## APIs

The channel's "API" is the set of WebSocket message types it handles. These map 1:1 to the registration protocol defined in the kickoff.

### Inbound (Agent -> Cortex via `handle_in`)

| Event | Payload | Reply | Side Effects |
|-------|---------|-------|--------------|
| `"register"` | `%{"protocol_version" => 1, "agent" => %{...}, "auth" => %{...}}` | `{:ok, %{"type" => "registered", ...}}` or `{:error, %{"reason" => ...}}` | Registry.register, PubSub :gateway_agent_registered |
| `"heartbeat"` | `%{"agent_id" => uuid, "status" => str, "load" => %{...}}` | `{:ok, %{"type" => "heartbeat_ack"}}` | Registry.heartbeat |
| `"task_result"` | `%{"task_id" => uuid, "status" => str, "result" => %{...}}` | `{:ok, %{}}` or `{:error, %{"reason" => ...}}` | Route result to orchestration |
| `"status_update"` | `%{"agent_id" => uuid, "status" => str, "detail" => str}` | `{:ok, %{}}` | Registry.update_status, PubSub broadcast |

### Outbound (Cortex -> Agent via `push`)

| Event | Payload | Trigger |
|-------|---------|---------|
| `"registered"` | `%{"agent_id" => uuid, "mesh_info" => %{...}}` | Successful registration |
| `"task_request"` | `%{"task_id" => uuid, "prompt" => str, ...}` | Orchestration dispatches work |
| `"peer_request"` | `%{"request_id" => uuid, "from_agent" => str, ...}` | Another agent invokes this one |

### Error Semantics

All errors are returned as `{:reply, {:error, payload}, socket}` where payload is:

```json
{"reason": "not_registered", "detail": "Must send 'register' message before other operations"}
{"reason": "invalid_payload", "detail": "Missing required field: capabilities"}
{"reason": "already_registered", "detail": "Agent already registered with id abc-123"}
```

### Socket Endpoint

- **Path:** `/agent/websocket`
- **Transport:** WebSocket only (no longpoll)
- **Auth:** Bearer token passed as `params.token` on connect
- **Connect info:** `[:peer_data, :x_headers]` for IP tracking

---

## Architecture / Component Boundaries

### Components I Touch

1. **`CortexWeb.AgentSocket`** -- Phoenix Socket module
   - Authenticates on `connect/3` by extracting `params["token"]` and calling `Gateway.Auth.authenticate/1`
   - On success: assigns `authenticated: true`, `connect_time`, `remote_ip`
   - On failure: returns `:error` (WebSocket connection refused)
   - `id/1` returns `"agent_socket:#{socket.assigns.agent_id}"` (or nil pre-registration)

2. **`CortexWeb.AgentChannel`** -- Phoenix Channel on `"agent:lobby"`
   - Thin routing layer: validates message shape, delegates to Registry/Protocol, formats replies
   - Stores minimal state in socket assigns
   - Pushes outbound messages when called by other Cortex modules via the channel pid

3. **`CortexWeb.Endpoint`** (modification) -- Add `socket "/agent/websocket", CortexWeb.AgentSocket` route

### Components I Call (owned by other teammates)

- `Cortex.Gateway.Protocol` -- parse/validate inbound messages, encode outbound messages
- `Cortex.Gateway.Registry` -- register/unregister agents, update status/heartbeat, lookup by ID
- `Cortex.Gateway.Auth` -- authenticate bearer tokens
- `Cortex.Events` -- broadcast PubSub events for LiveView

### How Outbound Messages Reach the Agent

Other Cortex modules (orchestration, agent tool) need to push messages to a connected agent. The flow:

1. Caller looks up the agent's channel pid via `Gateway.Registry.get_channel(agent_id)`
2. Caller sends a message to the channel process: `send(channel_pid, {:push_to_agent, event, payload})`
3. `AgentChannel.handle_info({:push_to_agent, event, payload}, socket)` calls `push(socket, event, payload)`

This avoids tight coupling -- callers only need the channel pid, not knowledge of Phoenix Channel internals.

### Concurrency Model

- Each WebSocket connection is a separate Channel process (one process per agent) -- Phoenix handles this.
- No worker pools needed. Channel processes are lightweight.
- The channel never blocks on long operations -- all registry calls should be fast GenServer calls.

### Backpressure

- If an agent sends messages faster than we can process, the BEAM mailbox buffers them. For MVP this is acceptable.
- If a registry call is slow, the channel blocks (GenServer.call timeout of 5000ms default). We'll use an explicit timeout of 5000ms and return an error to the agent if exceeded.

---

## Correctness Invariants

1. **Auth gate:** No WebSocket connection is established without a valid bearer token. `connect/3` returns `:error` for invalid/missing tokens.
2. **Registration gate:** No `handle_in` message (except `"register"`) is processed until `socket.assigns.registered == true`. Violations receive `{:error, %{"reason" => "not_registered"}}`.
3. **Single registration:** An agent can only register once per connection. A second `"register"` message returns `{:error, %{"reason" => "already_registered"}}`.
4. **Clean disconnect:** `terminate/2` always calls `Gateway.Registry.unregister(agent_id)` to clean up. This is idempotent.
5. **Agent ID consistency:** The `agent_id` in socket assigns matches the `agent_id` in the registry. Heartbeat and status_update messages must carry an `agent_id` matching the socket's assigned ID.
6. **No crash on bad input:** All `handle_in` clauses pattern-match defensively and return error replies for malformed payloads. The channel process never crashes from invalid input.
7. **PubSub emission:** Every registration, unregistration, and status change emits a PubSub event so LiveView dashboards stay in sync.

---

## Tests

### Unit Tests (`test/cortex_web/channels/agent_channel_test.exs`)

Using `Phoenix.ChannelTest`:

1. **Socket connect tests:**
   - Connect with valid token succeeds, assigns `authenticated: true`
   - Connect with invalid token returns `:error`
   - Connect with missing token returns `:error`

2. **Join tests:**
   - Join `"agent:lobby"` succeeds for authenticated socket
   - Join sets `registered: false` and `joined_at` in assigns

3. **Registration tests:**
   - Push `"register"` with valid payload: gets `"registered"` reply with `agent_id`
   - Push `"register"` with missing fields: gets error reply
   - Push `"register"` twice: second gets `"already_registered"` error
   - Push `"register"` with unsupported protocol version: gets error

4. **Heartbeat tests:**
   - Push `"heartbeat"` after registration: gets `"heartbeat_ack"` reply
   - Push `"heartbeat"` before registration: gets `"not_registered"` error
   - Push `"heartbeat"` with mismatched agent_id: gets error

5. **Task result tests:**
   - Push `"task_result"` with valid payload: gets ok reply
   - Push `"task_result"` before registration: gets error

6. **Status update tests:**
   - Push `"status_update"` with valid payload: gets ok reply, PubSub event emitted
   - Push `"status_update"` before registration: gets error

7. **Outbound push tests:**
   - Send `{:push_to_agent, "task_request", payload}` to channel: agent receives the push
   - Send `{:push_to_agent, "peer_request", payload}` to channel: agent receives the push

8. **Disconnect tests:**
   - Close the channel: `terminate/2` calls Registry.unregister
   - Verify PubSub event emitted on disconnect

### Integration Test (separate file or tagged)

- Full flow: connect -> join -> register -> heartbeat -> status_update -> task_result -> disconnect
- Verify registry state at each step (requires Gateway.Registry running)

### Test Commands

```bash
mix test test/cortex_web/channels/
mix test test/cortex_web/channels/agent_channel_test.exs
mix test test/cortex_web/channels/agent_channel_test.exs --trace
```

---

## Benchmarks + "Success"

N/A for the channel layer directly. Phoenix Channels are battle-tested at scale. The channel is a thin routing layer with no algorithmic complexity worth benchmarking.

**Success criteria for this role** are functional, not performance-based:
- All tests pass.
- An agent can connect, register, exchange heartbeats, receive tasks, and disconnect cleanly.
- LiveView dashboards update in real time when agents connect/disconnect.
- No channel process crashes from malformed input.

---

## Engineering Decisions & Tradeoffs

### Decision 1: Single "agent:lobby" topic vs per-agent topics

- **Decision:** Use a single `"agent:lobby"` topic for all agents.
- **Alternatives considered:** Per-agent topics like `"agent:{agent_id}"` where each agent joins its own channel.
- **Why:** At this stage, agents do not need to subscribe to each other's messages. All communication is agent<->Cortex. A single lobby simplifies the implementation -- one channel module, one join path. Per-agent topics can be added later for peer-to-peer features (Phase 3) without breaking the lobby.
- **Tradeoff acknowledged:** Broadcasting to the lobby hits all connected agents. For outbound messages targeted at a single agent, we use `push/3` (direct to socket), not `broadcast/3`, so this is not a problem in practice. If we later need agent-to-agent pub/sub, we'll add per-agent topics.

### Decision 2: Channel as thin router vs channel with embedded logic

- **Decision:** The channel is a thin routing layer that delegates all validation to `Gateway.Protocol` and all state management to `Gateway.Registry`.
- **Alternatives considered:** Embed validation and state tracking directly in the channel module.
- **Why:** Separation of concerns. The Protocol module can be tested in isolation without WebSocket machinery. The Registry can be shared across channels and called from non-WebSocket code paths (e.g., REST API). The channel stays small and easy to reason about.
- **Tradeoff acknowledged:** More function calls per message (channel -> protocol -> registry). The overhead is negligible for our scale and the testability/maintainability gain is worth it.

### Decision 3: Push via `handle_info` + `send/2` vs Phoenix.Channel.Server.push

- **Decision:** External callers push messages to agents by sending `{:push_to_agent, event, payload}` to the channel process, which calls `push/3` in `handle_info`.
- **Alternatives considered:** (a) Using `CortexWeb.Endpoint.broadcast` to the lobby topic. (b) Exposing a public function on AgentChannel that wraps the push.
- **Why:** `Endpoint.broadcast` would broadcast to ALL connected agents, not just one. A public function on the channel module doesn't have access to the socket. Sending a message to the channel pid and handling it in `handle_info` is the standard Phoenix pattern for server-initiated pushes.
- **Tradeoff acknowledged:** Callers need the channel pid (from the registry). This creates a dependency on the registry for outbound routing, but that's the right place for it.

### Decision 4: Registration timeout

- **Decision:** After joining, agents have 30 seconds to send a `"register"` message. A `Process.send_after` in `join/3` triggers disconnection if registration hasn't completed.
- **Alternatives considered:** No timeout (let unregistered connections sit indefinitely).
- **Why:** Prevents resource leaks from connections that join but never register (broken sidecars, network issues, scanners). 30 seconds is generous for a registration handshake.
- **Tradeoff acknowledged:** Agents with slow startup may be disconnected prematurely. 30 seconds should be ample, and sidecars can be configured to send registration immediately on connect. If needed, the timeout is configurable.

---

## Risks & Mitigations

### Risk 1: Gateway.Registry API not finalized when channel implementation starts

- **Risk:** The channel depends on Registry functions that may not exist yet or may have different signatures.
- **Impact:** Channel code needs rewriting or mocking gets out of sync with actual implementation.
- **Mitigation:** Define the Registry behaviour (callback module) up front in the plan. The channel codes against the behaviour. Use a simple mock/stub in channel tests. Coordinate with Registry Engineer on the exact function signatures before writing code.
- **Validation time:** ~10 minutes to agree on the behaviour/callback spec with the Registry Engineer.

### Risk 2: Gateway.Protocol API not finalized when channel implementation starts

- **Risk:** Similar to above -- the channel depends on Protocol.parse/validate functions.
- **Impact:** Channel error handling may not match actual protocol error shapes.
- **Mitigation:** Same approach -- agree on the Protocol behaviour. Channel tests use a stub that returns the expected shapes. Validation of the actual protocol messages is the Protocol Engineer's test responsibility.
- **Validation time:** ~10 minutes to agree on the protocol function signatures.

### Risk 3: Phoenix.ChannelTest limitations with custom socket auth

- **Risk:** `Phoenix.ChannelTest.connect/3` may not support custom `connect_info` (peer_data, x_headers) needed for IP tracking.
- **Impact:** Tests can't verify IP tracking behavior; may need workarounds.
- **Mitigation:** Use `Phoenix.ChannelTest.connect/3` with params for token auth (this is well-supported). For IP tracking, accept that it's best tested in an integration/E2E test with a real WebSocket client, and keep the channel logic simple enough that unit tests cover the important paths.
- **Validation time:** ~5 minutes to spike a test with `connect/3` and verify connect_info support.

### Risk 4: PubSub not started in test environment

- **Risk:** Channel tests that assert PubSub events will fail if PubSub isn't started.
- **Impact:** Tests fail or need complex setup.
- **Mitigation:** Cortex.PubSub is already started in the application supervision tree. Verify it's available in the test env. If not, start it in `test_helper.exs`. Channel tests subscribe to PubSub before the test action and assert on received messages.
- **Validation time:** ~5 minutes to check test_helper.exs and run a PubSub smoke test.

### Risk 5: Handling reconnection and duplicate registration

- **Risk:** An agent disconnects and reconnects quickly. The old channel's `terminate/2` and the new channel's `join/3` race against the registry.
- **Impact:** Agent could end up registered twice, or the unregister from the old connection could remove the new registration.
- **Mitigation:** The registry uses `Process.monitor` on the channel pid. When the old channel dies, the registry removes the entry keyed by that specific pid. The new channel registers with a new pid. The registry stores `{agent_id, channel_pid}` and unregister is scoped to `{agent_id, channel_pid}` -- not just `agent_id`. This prevents the race.
- **Validation time:** ~10 minutes to write a test that simulates rapid disconnect/reconnect.

---

## Recommended API Surface

### CortexWeb.AgentSocket

```elixir
# connect/3 -- authenticate bearer token
connect(params, socket, connect_info) :: {:ok, socket} | :error

# id/1 -- socket identifier for disconnect tracking
id(socket) :: String.t() | nil
```

### CortexWeb.AgentChannel

```elixir
# Standard Phoenix Channel callbacks
join("agent:lobby", payload, socket) :: {:ok, socket} | {:error, reason}

handle_in("register", payload, socket) :: {:reply, {:ok, map} | {:error, map}, socket}
handle_in("heartbeat", payload, socket) :: {:reply, {:ok, map} | {:error, map}, socket}
handle_in("task_result", payload, socket) :: {:reply, {:ok, map} | {:error, map}, socket}
handle_in("status_update", payload, socket) :: {:reply, {:ok, map} | {:error, map}, socket}

# Server-initiated push (called via send/2 from external code)
handle_info({:push_to_agent, event, payload}, socket) :: {:noreply, socket}

# Registration timeout
handle_info(:registration_timeout, socket) :: {:stop, :normal, socket} | {:noreply, socket}

terminate(reason, socket) :: :ok
```

### Dependencies on Other Teammates' APIs

The channel calls these functions (to be confirmed with respective engineers):

```elixir
# Gateway.Auth (Protocol Engineer)
Gateway.Auth.authenticate(token :: String.t()) :: {:ok, identity} | {:error, :unauthorized}

# Gateway.Protocol (Protocol Engineer)
Gateway.Protocol.validate_register(payload :: map()) :: {:ok, parsed} | {:error, reasons}
Gateway.Protocol.validate_heartbeat(payload :: map()) :: {:ok, parsed} | {:error, reasons}
Gateway.Protocol.validate_task_result(payload :: map()) :: {:ok, parsed} | {:error, reasons}
Gateway.Protocol.validate_status_update(payload :: map()) :: {:ok, parsed} | {:error, reasons}

# Gateway.Registry (Registry Engineer)
Gateway.Registry.register(agent_info :: map(), channel_pid :: pid()) :: {:ok, agent_id} | {:error, reason}
Gateway.Registry.unregister(agent_id :: String.t()) :: :ok
Gateway.Registry.heartbeat(agent_id :: String.t(), status :: String.t(), load :: map()) :: :ok
Gateway.Registry.update_status(agent_id :: String.t(), status :: String.t(), detail :: String.t()) :: :ok
Gateway.Registry.route_task_result(task_id :: String.t(), result :: map()) :: :ok | {:error, reason}
```

---

## Folder Structure

```
lib/
  cortex_web/
    channels/
      agent_socket.ex          # Phoenix Socket -- auth + routing (Gateway Architect)
      agent_channel.ex         # Phoenix Channel -- message handling (Gateway Architect)
    endpoint.ex                # Modified: add socket route (Integration Engineer)

test/
  cortex_web/
    channels/
      agent_channel_test.exs   # Channel unit + integration tests (Gateway Architect)
```

Modules I create: `CortexWeb.AgentSocket`, `CortexWeb.AgentChannel`
Modules I modify: none directly (Integration Engineer adds the socket to endpoint.ex)
Modules I depend on: `Cortex.Gateway.Auth`, `Cortex.Gateway.Protocol`, `Cortex.Gateway.Registry`, `Cortex.Events`

---

## Step-by-Step Task Plan (Tighten the plan into 4-7 small tasks)

### Task 1: AgentSocket with bearer token authentication

- **Outcome:** A Phoenix Socket at `/agent/websocket` that authenticates via bearer token on connect and rejects unauthenticated connections.
- **Files to create:** `lib/cortex_web/channels/agent_socket.ex`
- **Files to modify:** `lib/cortex_web/endpoint.ex` (add socket route)
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  ```
  Manual: `websocat ws://localhost:4000/agent/websocket?token=valid` connects; without token, connection is refused.
- **Suggested commit message:** `feat(gateway): add AgentSocket with bearer token auth`

### Task 2: AgentChannel join and registration handler

- **Outcome:** AgentChannel handles `join("agent:lobby")` and `handle_in("register")`. Delegates to Protocol for validation and Registry for state. Pushes `"registered"` reply. Includes 30s registration timeout.
- **Files to create:** `lib/cortex_web/channels/agent_channel.ex`
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex_web/channels/agent_channel_test.exs --trace
  ```
- **Suggested commit message:** `feat(gateway): add AgentChannel with join and registration`

### Task 3: Heartbeat and status update handlers

- **Outcome:** `handle_in("heartbeat")` and `handle_in("status_update")` are implemented. Both enforce the registration gate. Heartbeat replies with `"heartbeat_ack"`. Status update emits PubSub event.
- **Files to modify:** `lib/cortex_web/channels/agent_channel.ex`
- **Verification:**
  ```bash
  mix test test/cortex_web/channels/agent_channel_test.exs --trace
  ```
- **Suggested commit message:** `feat(gateway): add heartbeat and status update handlers to AgentChannel`

### Task 4: Task result handler and outbound push support

- **Outcome:** `handle_in("task_result")` routes completed task results. `handle_info({:push_to_agent, event, payload})` enables server-initiated pushes (`"task_request"`, `"peer_request"`).
- **Files to modify:** `lib/cortex_web/channels/agent_channel.ex`
- **Verification:**
  ```bash
  mix test test/cortex_web/channels/agent_channel_test.exs --trace
  ```
- **Suggested commit message:** `feat(gateway): add task result handler and outbound push to AgentChannel`

### Task 5: Disconnect cleanup and terminate handler

- **Outcome:** `terminate/2` calls `Gateway.Registry.unregister/1` and emits PubSub disconnect event. Socket `id/1` returns a trackable ID for Phoenix disconnect broadcasting.
- **Files to modify:** `lib/cortex_web/channels/agent_channel.ex`, `lib/cortex_web/channels/agent_socket.ex`
- **Verification:**
  ```bash
  mix test test/cortex_web/channels/agent_channel_test.exs --trace
  ```
- **Suggested commit message:** `feat(gateway): add disconnect cleanup in AgentChannel terminate`

### Task 6: Comprehensive test suite

- **Outcome:** Full test coverage for all channel paths: connect auth (valid/invalid/missing), join, register (success/duplicate/invalid), heartbeat (success/pre-registration/mismatched-id), task_result, status_update, outbound pushes, disconnect cleanup, registration timeout.
- **Files to create:** `test/cortex_web/channels/agent_channel_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex_web/channels/ --trace
  mix format --check-formatted
  mix credo --strict
  ```
- **Suggested commit message:** `test(gateway): add comprehensive AgentChannel test suite`

---

## CLAUDE.md Contributions (do NOT write the file; propose content)

### From Gateway Architect

**Coding style rules:**
- Phoenix Channels use `handle_in/3` for incoming WebSocket messages, `handle_info/2` for server-initiated actions
- All `handle_in` clauses must return `{:reply, {:ok | :error, payload}, socket}` -- never crash on bad input
- Channel assigns are the only state the channel holds; all durable state lives in Gateway.Registry
- Use `Phoenix.ChannelTest` for channel tests, not raw WebSocket clients

**Dev commands:**
```bash
# Run channel tests
mix test test/cortex_web/channels/

# Test WebSocket connection manually (requires websocat)
websocat ws://localhost:4000/agent/websocket?token=YOUR_TOKEN
```

**Before you commit checklist (additions):**
- Ensure all `handle_in` clauses have a matching test
- Ensure `terminate/2` is tested for cleanup
- No `IO.inspect` or `dbg()` in channel code

**Guardrails:**
- Never call `Gateway.Registry` functions directly from LiveView -- use PubSub events
- The channel pid is the authority for "is this agent connected" -- if the process is alive, the agent is connected
- Registration timeout (30s) is hardcoded for now; extract to config if agents need longer

---

## EXPLAIN.md Contributions (do NOT write the file; propose outline bullets)

**Flow / Architecture:**
- External agents connect to Cortex via WebSocket at `/agent/websocket`
- The `AgentSocket` authenticates the connection using a bearer token
- Agents join the `"agent:lobby"` channel and send a `"register"` message with their name, role, and capabilities
- The channel delegates to `Gateway.Protocol` for validation and `Gateway.Registry` for state management
- On successful registration, the agent receives a `"registered"` reply with its assigned UUID
- Heartbeats keep the agent's health status current; the channel forwards them to the registry
- Cortex pushes `"task_request"` and `"peer_request"` messages to agents via the channel pid
- On disconnect, `terminate/2` cleans up the registry entry and emits a PubSub event

**Key Engineering Decisions + Tradeoffs:**
- Single "agent:lobby" topic (simpler) vs per-agent topics (more flexible) -- chose simplicity, per-agent topics can be added in Phase 3
- Channel as thin router, delegating to Protocol and Registry -- better testability, more indirection
- Server-initiated push via `handle_info` + `send/2` -- standard Phoenix pattern for targeted pushes
- 30s registration timeout to prevent resource leaks from zombie connections

**Limits of MVP + Next Steps:**
- Single bearer token for all agents (no per-agent auth or JWT)
- No rate limiting on incoming messages
- No message queuing if agent disconnects during task execution
- No reconnection protocol (agent must re-register from scratch)
- Next: per-agent topics for peer messaging, token-per-agent auth, message delivery guarantees

**How to Run Locally + How to Validate:**
- `mix phx.server` starts the endpoint with the agent gateway
- Connect with any WebSocket client to `ws://localhost:4000/agent/websocket?token=YOUR_TOKEN`
- Send `{"type": "register", "protocol_version": 1, "agent": {"name": "test", "role": "tester", "capabilities": ["test"]}}` to register
- Observe registration in the LiveView dashboard at `http://localhost:4000/mesh`
- `mix test test/cortex_web/channels/` runs the full channel test suite

---

## READY FOR APPROVAL
