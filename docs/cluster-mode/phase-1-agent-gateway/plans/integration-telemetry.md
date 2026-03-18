# Integration & Telemetry Engineer — Phase 1: Agent Gateway

## You are in PLAN MODE.

### Project
I want to build a **Cluster Mode Agent Gateway** for Cortex.

**Goal:** build the **integration and observability layer** in which we wire the gateway into Cortex's existing supervision tree, event system, telemetry pipeline, and LiveView dashboards so that externally registered agents are first-class citizens in the Cortex control plane.

### Role + Scope
- **Role:** Integration & Telemetry Engineer
- **Scope:** I own Gateway.Supervisor, Gateway.Events, telemetry event definitions and emission helpers for gateway operations, modifications to Application supervision tree, Endpoint socket wiring, and initial dashboard integration for connected agent counts. I do NOT own the Channel implementation (Gateway Architect), the Registry GenServer internals (Registry Engineer), or the protocol message validation/parsing (Protocol Engineer).
- **File I will write:** `/docs/cluster-mode/phase-1-agent-gateway/plans/integration-telemetry.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

- **FR1:** `Gateway.Supervisor` starts as part of the main `Cortex.Supervisor` tree and supervises `Gateway.Registry` and `Gateway.Health` with appropriate restart strategies.
- **FR2:** `Gateway.Events` defines PubSub topics and broadcast helpers for gateway-specific events: `agent_registered`, `agent_unregistered`, `agent_heartbeat`, `agent_status_changed`, `task_dispatched`, `task_completed`. Must be compatible with the existing `Cortex.Events` pattern (same `%{type, payload, timestamp}` shape, same PubSub instance).
- **FR3:** `Cortex.Telemetry` is extended with five new gateway telemetry events (`[:cortex, :gateway, :agent, :registered]`, `[:cortex, :gateway, :agent, :unregistered]`, `[:cortex, :gateway, :agent, :heartbeat]`, `[:cortex, :gateway, :task, :dispatched]`, `[:cortex, :gateway, :task, :completed]`) with emission helpers following the existing pattern.
- **FR4:** `Cortex.Application` starts `Gateway.Supervisor` in the supervision tree after PubSub and before the web layer.
- **FR5:** `CortexWeb.Endpoint` gains a new socket declaration at `/agent` for the agent gateway WebSocket channel.
- **FR6:** `CortexWeb.DashboardLive` shows a "Connected Agents" count card that updates in real-time via PubSub.
- **FR7:** `CortexWeb.MeshLive` shows externally registered agents in the member roster alongside Cortex-spawned agents.
- **Tests required:** Unit tests for Gateway.Supervisor startup and child process liveness; unit tests for Gateway.Events broadcast/subscribe; unit tests for new telemetry emission helpers; integration test covering connect -> register -> heartbeat -> disconnect flow with telemetry and event assertions.
- **Metrics required:** Prometheus counters/distributions for all five gateway telemetry events exposed via `TelemetryMetricsPrometheus.Core` and `CortexWeb.Telemetry` (LiveDashboard).

## Non-Functional Requirements

- **Language/runtime:** Elixir/OTP. All new modules follow existing conventions.
- **Local dev:** `mix phx.server` starts the full gateway stack; no additional config needed.
- **Observability:** All gateway operations emit both PubSub events (for LiveView) and `:telemetry` events (for Prometheus and LiveDashboard). Gateway events use a dedicated PubSub topic `"cortex:gateway"` to avoid noise on the main `"cortex:events"` topic, while also forwarding to `"cortex:events"` for dashboard consumers.
- **Safety:** Supervisor uses `:one_for_one` strategy with default restart intensity. `safe_broadcast` pattern (rescue on PubSub errors) used consistently, matching existing codebase.
- **Documentation:** `@moduledoc`, `@doc`, `@spec` on all public functions per project conventions.
- **Performance:** Event emission is fire-and-forget; no synchronous calls in the hot path. PubSub broadcast is O(subscribers), matching existing patterns.

---

## Assumptions / System Model

- **Deployment environment:** Single-node Elixir application. No distributed Erlang / libcluster for now (per PROJECT.md non-goals).
- **Failure modes:** If Gateway.Supervisor crashes, the supervisor tree restarts it and its children. Connected WebSocket channels will be terminated and agents must reconnect. This is acceptable for MVP — agents retry via the sidecar.
- **Delivery guarantees:** PubSub events are best-effort (no persistence, no replay). Telemetry events are fire-and-forget. Both match existing Cortex patterns.
- **Multi-tenancy:** Single-tenant (per PROJECT.md non-goals). No namespace isolation on PubSub topics.
- **Event ordering:** Events are emitted synchronously from the calling process. Subscribers may receive them in any order relative to each other, but a single subscriber sees events in emission order from a given publisher.

---

## Data Model (as relevant to role)

The Integration & Telemetry role does not own the core data structures (that's the Registry Engineer). However, this role defines the event shapes:

### Gateway PubSub Event Shape

Follows the existing `Cortex.Events` pattern:

```elixir
%{
  type: :agent_registered | :agent_unregistered | :agent_heartbeat |
        :agent_status_changed | :task_dispatched | :task_completed,
  payload: map(),
  timestamp: DateTime.t()
}
```

**Payload schemas per event type:**

| Event | Payload Fields |
|-------|---------------|
| `agent_registered` | `agent_id`, `name`, `role`, `capabilities` |
| `agent_unregistered` | `agent_id`, `name`, `reason` |
| `agent_heartbeat` | `agent_id`, `status`, `active_tasks`, `queue_depth` |
| `agent_status_changed` | `agent_id`, `old_status`, `new_status`, `detail` |
| `task_dispatched` | `task_id`, `agent_id`, `prompt_length`, `timeout_ms` |
| `task_completed` | `task_id`, `agent_id`, `status`, `duration_ms`, `input_tokens`, `output_tokens` |

### Telemetry Event Shape

| Event Name | Measurements | Metadata |
|-----------|-------------|----------|
| `[:cortex, :gateway, :agent, :registered]` | `%{system_time: integer}` | `agent_id`, `name`, `role`, `capabilities` |
| `[:cortex, :gateway, :agent, :unregistered]` | `%{system_time: integer}` | `agent_id`, `name`, `reason` |
| `[:cortex, :gateway, :agent, :heartbeat]` | `%{system_time: integer}` | `agent_id`, `status`, `active_tasks` |
| `[:cortex, :gateway, :task, :dispatched]` | `%{system_time: integer}` | `task_id`, `agent_id` |
| `[:cortex, :gateway, :task, :completed]` | `%{duration_ms: integer}` | `task_id`, `agent_id`, `status` |

- **Validation rules:** Emission helpers guard on `is_map(metadata)` matching existing pattern. No further validation at the telemetry layer — the caller (Channel/Registry) is responsible for data correctness.
- **Versioning strategy:** Event names are namespaced under `[:cortex, :gateway, ...]` to avoid collision with existing mesh/agent events. If the protocol version changes, new event names can be added without breaking existing handlers.
- **Minimal persistence:** None for MVP. Events are ephemeral. Persistence (event sourcing) is a future phase concern.

---

## APIs (as relevant to role)

### Gateway.Events API

```elixir
# Subscribe to all gateway events
Gateway.Events.subscribe() :: :ok | {:error, term()}

# Broadcast a gateway event (follows Cortex.Events pattern)
Gateway.Events.broadcast(type :: atom(), payload :: map()) :: :ok | {:error, term()}

# Returns the gateway-specific PubSub topic
Gateway.Events.topic() :: String.t()  # "cortex:gateway"
```

### Cortex.Telemetry — New Emission Helpers

```elixir
Cortex.Telemetry.emit_gateway_agent_registered(metadata :: map()) :: :ok
Cortex.Telemetry.emit_gateway_agent_unregistered(metadata :: map()) :: :ok
Cortex.Telemetry.emit_gateway_agent_heartbeat(metadata :: map()) :: :ok
Cortex.Telemetry.emit_gateway_task_dispatched(metadata :: map()) :: :ok
Cortex.Telemetry.emit_gateway_task_completed(metadata :: map()) :: :ok
```

### Gateway.Supervisor API

```elixir
# Standard Supervisor — no custom public API beyond start_link/1
Gateway.Supervisor.start_link(keyword()) :: Supervisor.on_start()
```

### Endpoint Socket

The socket mount at `/agent` in `CortexWeb.Endpoint` — no custom API, just the Phoenix socket declaration with `websocket: true`.

---

## Architecture / Component Boundaries

### Component Diagram

```
Cortex.Application
  └── Cortex.Supervisor (:one_for_one)
        ├── Phoenix.PubSub (Cortex.PubSub)
        ├── Registry (Cortex.Agent.Registry)
        ├── DynamicSupervisor (Cortex.Agent.Supervisor)
        ├── ... existing children ...
        ├── Gateway.Supervisor (:one_for_one)        # NEW
        │     ├── Gateway.Registry (GenServer)        # Registry Engineer owns internals
        │     └── Gateway.Health (GenServer)           # Future: health checker
        ├── Cortex.Repo
        ├── Cortex.Store.EventSink
        ├── CortexWeb.Telemetry
        ├── TelemetryMetricsPrometheus.Core
        └── CortexWeb.Endpoint
              └── socket "/agent" → AgentSocket       # NEW
                    └── "agent:lobby" → AgentChannel   # Gateway Architect owns
```

### Responsibilities

| Component | Owner | Integration Touch Points |
|-----------|-------|-------------------------|
| `Gateway.Supervisor` | Integration & Telemetry | Starts Registry + Health; inserted into Application children |
| `Gateway.Events` | Integration & Telemetry | PubSub broadcast/subscribe for gateway events |
| `Cortex.Telemetry` (gateway additions) | Integration & Telemetry | `:telemetry.execute` for Prometheus/LiveDashboard |
| `CortexWeb.Endpoint` (socket) | Integration & Telemetry | Socket mount for WebSocket connections |
| `DashboardLive` | Integration & Telemetry | Subscribe to gateway events, show connected agent count |
| `MeshLive` | Integration & Telemetry | Subscribe to gateway events, show external agents in roster |
| `Gateway.Registry` | Registry Engineer | Calls `Gateway.Events.broadcast` and `Cortex.Telemetry.emit_*` on state changes |
| `AgentChannel` | Gateway Architect | Calls Registry on join/leave; calls Gateway.Events on protocol messages |

### Config Propagation

No runtime config changes for MVP. Gateway.Supervisor starts with compile-time defaults. Future: runtime config via Application env.

### Concurrency Model

- Gateway.Supervisor is a static supervisor — children are known at compile time.
- PubSub broadcasts are non-blocking (Phoenix.PubSub is backed by `:pg`).
- Telemetry emission is synchronous in the calling process but handlers should be lightweight.

### Backpressure Strategy

N/A for MVP. PubSub has no backpressure — if a LiveView subscriber is slow, messages queue in its mailbox (standard Phoenix behavior). Telemetry handlers are synchronous and must be fast.

---

## Correctness Invariants

1. **Supervisor child liveness:** After application boot, `Gateway.Supervisor`, `Gateway.Registry`, and `Gateway.Health` are all alive and registered.
2. **Event shape consistency:** Every `Gateway.Events.broadcast/2` call produces a message matching the `%{type: atom(), payload: map(), timestamp: DateTime.t()}` shape — same as `Cortex.Events`.
3. **Telemetry event catalog completeness:** `Cortex.Telemetry.event_names/0` includes all five new gateway events. The count increases from 15 to 20.
4. **Socket reachability:** A WebSocket connection to `ws://localhost:4000/agent/websocket` succeeds (transport layer, before channel join).
5. **Dashboard reactivity:** When a `gateway_agent_registered` PubSub event is broadcast, the DashboardLive connected-agent count increments within the same LiveView render cycle.
6. **Telemetry-Prometheus alignment:** Every gateway telemetry event has a corresponding Prometheus metric definition in `Cortex.Application.prometheus_metrics/0` and a LiveDashboard metric in `CortexWeb.Telemetry.metrics/0`.

---

## Tests

### Unit Tests

**`test/cortex/gateway/supervisor_test.exs`**
- Test that `Gateway.Supervisor` starts successfully and is alive after application boot.
- Test that `Gateway.Registry` child process is alive under the supervisor.
- Test that `Gateway.Health` child process is alive (or placeholder alive if stubbed for MVP).
- Test restart: killing a child causes it to be restarted.

**`test/cortex/gateway/events_test.exs`**
- Test `subscribe/0` and `broadcast/2` round-trip: subscriber receives the event.
- Test event shape: broadcast produces `%{type, payload, timestamp}`.
- Test all six event types can be broadcast without error.
- Test that broadcasting with non-atom type or non-map payload raises/returns error.

**`test/cortex/telemetry_test.exs` (extend existing)**
- Test `event_names/0` count increases to 20.
- Test each of the five new `emit_gateway_*` helpers emits the correct event name with correct measurements/metadata.
- Test `emit_gateway_task_completed/1` extracts `duration_ms` into measurements (matching `emit_tool_executed` pattern).

### Integration Tests

**`test/cortex/gateway/integration_test.exs`**
- Full flow: connect WebSocket -> send `register` message -> assert `agent_registered` PubSub event received -> send `heartbeat` -> assert `agent_heartbeat` PubSub event -> disconnect -> assert `agent_unregistered` PubSub event.
- Assert corresponding telemetry events fire during the flow (attach test handler, collect events, assert all five types seen).
- Verify Gateway.Registry state reflects the agent during connection and clears after disconnect.

### Property/Fuzz Tests

N/A for this role. Protocol validation fuzz tests are the Protocol Engineer's responsibility.

### Failure Injection Tests

- Kill `Gateway.Registry` process, verify supervisor restarts it within 1 second.
- Kill `Gateway.Supervisor`, verify `Cortex.Supervisor` restarts the entire gateway subtree.

### Commands

```bash
mix test test/cortex/gateway/supervisor_test.exs
mix test test/cortex/gateway/events_test.exs
mix test test/cortex/gateway/integration_test.exs
mix test test/cortex/telemetry_test.exs
mix test test/cortex/gateway/
```

---

## Benchmarks + "Success"

N/A — benchmarks are not the primary concern for the integration/telemetry layer. The hot path (PubSub broadcast + telemetry emission) uses the same primitives as existing Cortex code, which is already proven at the required scale (hundreds of agents per PROJECT.md).

**Success criteria:**
- All tests pass with `mix test test/cortex/gateway/` and updated `test/cortex/telemetry_test.exs`.
- `mix compile --warnings-as-errors` passes.
- `mix credo --strict` passes.
- Gateway telemetry events appear in LiveDashboard at `/dev/dashboard`.
- Prometheus metrics endpoint at `/metrics` includes gateway counters.
- DashboardLive shows "Connected Agents: 0" card on initial load.

---

## Engineering Decisions & Tradeoffs

### Decision 1: Dedicated PubSub topic for gateway events

- **Decision:** Use `"cortex:gateway"` as a separate PubSub topic rather than broadcasting gateway events on the existing `"cortex:events"` topic.
- **Alternatives considered:** (a) Reuse `"cortex:events"` for all events. (b) Per-event-type topics like `"cortex:gateway:agent_registered"`.
- **Why:** The existing `"cortex:events"` topic carries run/tier/team/mesh events that all current LiveView subscribers handle. Adding high-frequency heartbeat events from potentially hundreds of external agents would force every existing subscriber to pattern-match and discard gateway events, increasing GC pressure and mailbox sizes. A dedicated topic lets only gateway-interested subscribers (DashboardLive, MeshLive) opt in.
- **Tradeoff acknowledged:** Gateway.Events and Cortex.Events are now two parallel modules with similar APIs. This is a small amount of code duplication, but keeps subscriber sets cleanly separated. If we later want unified event routing, we can introduce a topic-routing layer.

### Decision 2: Gateway.Supervisor as a static Supervisor (not DynamicSupervisor)

- **Decision:** Use a regular `Supervisor` with a fixed child spec list, not a `DynamicSupervisor`.
- **Alternatives considered:** (a) DynamicSupervisor to allow adding/removing gateway services at runtime. (b) No separate supervisor — add Registry and Health directly to `Cortex.Supervisor`.
- **Why:** The gateway has a known, small set of children (Registry + Health). A static supervisor gives us compile-time guarantees about the child list and clearer restart semantics. Adding children directly to the top-level supervisor would flatten the hierarchy and make it harder to reason about gateway-specific restarts.
- **Tradeoff acknowledged:** If we later need dynamic gateway services (e.g., per-tenant registries), we'd need to refactor to DynamicSupervisor. For single-tenant MVP, this is the simpler choice.

### Decision 3: Telemetry events use `system_time` measurements (not duration) for registration/heartbeat

- **Decision:** Registration, unregistration, and heartbeat telemetry events carry `%{system_time: System.system_time()}` as measurements, not durations.
- **Alternatives considered:** Carry `%{}` empty measurements (simpler) or carry request duration.
- **Why:** Matches the existing pattern for `emit_agent_started/1` and `emit_mesh_member_joined/1`. System time allows Prometheus to compute rates. Task completion uses `duration_ms` because it has a meaningful duration to measure.
- **Tradeoff acknowledged:** System time in measurements is somewhat redundant with the Prometheus scrape timestamp, but it maintains consistency with the existing codebase and enables accurate rate calculations independent of scrape interval.

---

## Risks & Mitigations

### Risk 1: Circular dependency between Gateway.Supervisor children and PubSub

- **Risk:** If Gateway.Registry tries to broadcast a PubSub event during `init/1`, PubSub might not be ready if startup ordering is wrong.
- **Impact:** Application crash on boot.
- **Mitigation:** Gateway.Supervisor is placed in the Application children list AFTER `Phoenix.PubSub` (which is the first child). The existing `safe_broadcast` rescue pattern is used in all event emission code.
- **Validation time:** < 5 minutes. Start the application with `mix phx.server` and verify no crash. Check with `mix test test/cortex/gateway/supervisor_test.exs`.

### Risk 2: Existing telemetry test breaks when event count changes

- **Risk:** The existing `telemetry_test.exs` asserts `length(names) == 15`. Adding 5 gateway events changes this to 20, breaking the existing test.
- **Impact:** CI failure until test is updated.
- **Mitigation:** Update the existing test assertion from 15 to 20 AND add assertions for the five new event names in the same commit that adds the events. This is a coordinated change.
- **Validation time:** < 2 minutes. Run `mix test test/cortex/telemetry_test.exs`.

### Risk 3: DashboardLive PubSub handler becomes a catch-all performance problem

- **Risk:** DashboardLive subscribes to gateway events to show connected agent count. If hundreds of agents send heartbeats every 30 seconds, the LiveView process handles thousands of messages per minute.
- **Impact:** Dashboard becomes sluggish or crashes under load.
- **Mitigation:** DashboardLive subscribes to `"cortex:gateway"` but only handles `agent_registered` and `agent_unregistered` events (which are infrequent). Heartbeat events are ignored via the existing catch-all `handle_info(_msg, socket)`. For MVP, this is sufficient. If needed later, we can add a debounce or use a separate GenServer to aggregate counts.
- **Validation time:** < 5 minutes. Open dashboard in browser, verify it renders. In production, heartbeat volume is bounded by agent count (hundreds, not thousands).

### Risk 4: WebSocket socket path conflicts with existing routes

- **Risk:** Adding `socket "/agent"` to the Endpoint could conflict with a future `/agent` HTTP route.
- **Impact:** Routing confusion; HTTP requests to `/agent` get handled as WebSocket upgrade attempts.
- **Mitigation:** Phoenix sockets and HTTP routes are separate dispatch paths — sockets only match on the WebSocket upgrade handshake. The path `/agent/websocket` is the actual transport URL. No conflict with browser routes. Additionally, the existing router has no `/agent` scope.
- **Validation time:** < 3 minutes. Start server, verify both `curl http://localhost:4000/agent` (404) and WebSocket connection to `ws://localhost:4000/agent/websocket` work as expected.

### Risk 5: MeshLive integration causes confusion between mesh-spawned and gateway-registered agents

- **Risk:** Showing both Cortex-spawned mesh agents and externally registered gateway agents in the same MeshLive roster could confuse users about which agents are which.
- **Impact:** User confusion; no functional failure.
- **Mitigation:** Add a `source` indicator to the roster table (e.g., "mesh" vs "gateway" badge) so users can distinguish origin. The `agent_registered` event payload includes enough metadata to determine source.
- **Validation time:** < 5 minutes. Visual inspection of MeshLive page with both agent types present.

---

## Recommended API Surface

1. **`Cortex.Gateway.Supervisor`** — `start_link/1` (standard Supervisor)
2. **`Cortex.Gateway.Events`** — `subscribe/0`, `broadcast/2`, `topic/0`
3. **`Cortex.Telemetry`** (extended) — `emit_gateway_agent_registered/1`, `emit_gateway_agent_unregistered/1`, `emit_gateway_agent_heartbeat/1`, `emit_gateway_task_dispatched/1`, `emit_gateway_task_completed/1`, updated `event_names/0`
4. **`CortexWeb.Endpoint`** (modified) — `socket "/agent"` declaration
5. **`CortexWeb.DashboardLive`** (modified) — `connected_agents` assign, gateway PubSub subscription
6. **`CortexWeb.MeshLive`** (modified) — gateway agent entries in roster

## Folder Structure

```
lib/cortex/gateway/
  supervisor.ex          # NEW — Supervisor for gateway processes
  events.ex              # NEW — PubSub topic + broadcast helpers

lib/cortex/telemetry.ex            # MODIFIED — 5 new gateway events + helpers
lib/cortex/application.ex          # MODIFIED — add Gateway.Supervisor to children
lib/cortex_web/endpoint.ex         # MODIFIED — add socket "/agent"
lib/cortex_web/live/dashboard_live.ex  # MODIFIED — connected agents card
lib/cortex_web/live/mesh_live.ex       # MODIFIED — external agents in roster

test/cortex/gateway/
  supervisor_test.exs    # NEW
  events_test.exs        # NEW
  integration_test.exs   # NEW
test/cortex/telemetry_test.exs     # MODIFIED — assert 20 events
```

## Step-by-Step Task Plan (Small Commits)

See "Tighten the plan" section below.

## Benchmark Plan

N/A — see "Benchmarks + Success" section above.

---

## Tighten the plan into 4-7 small tasks

### Task 1: Add gateway telemetry events to Cortex.Telemetry

- **Outcome:** Five new gateway telemetry event definitions, emission helpers, and updated `event_names/0`.
- **Files to create/modify:**
  - `lib/cortex/telemetry.ex` — add 5 module attributes, 5 emission helpers, update `event_names/0`
  - `test/cortex/telemetry_test.exs` — update count assertion (15 -> 20), add 5 new emission tests
- **Exact verification command(s):**
  - `mix test test/cortex/telemetry_test.exs`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat(cortex): add gateway telemetry events for agent registration, heartbeat, and tasks`

### Task 2: Create Gateway.Events PubSub module

- **Outcome:** `Cortex.Gateway.Events` module with `subscribe/0`, `broadcast/2`, `topic/0` on the `"cortex:gateway"` topic, matching `Cortex.Events` API shape.
- **Files to create/modify:**
  - `lib/cortex/gateway/events.ex` — new module
  - `test/cortex/gateway/events_test.exs` — new test file
- **Exact verification command(s):**
  - `mix test test/cortex/gateway/events_test.exs`
  - `mix credo --strict lib/cortex/gateway/events.ex`
- **Suggested commit message:** `feat(cortex): add Gateway.Events PubSub module for gateway event broadcasting`

### Task 3: Create Gateway.Supervisor and wire into Application

- **Outcome:** `Cortex.Gateway.Supervisor` starts `Gateway.Registry` and `Gateway.Health` (stubs if those modules aren't built yet by teammates). Application.ex includes it in the supervision tree. Endpoint.ex gains `socket "/agent"`.
- **Files to create/modify:**
  - `lib/cortex/gateway/supervisor.ex` — new module
  - `lib/cortex/application.ex` — add `Cortex.Gateway.Supervisor` to children
  - `lib/cortex_web/endpoint.ex` — add `socket "/agent"` declaration
  - `test/cortex/gateway/supervisor_test.exs` — new test file
- **Exact verification command(s):**
  - `mix test test/cortex/gateway/supervisor_test.exs`
  - `mix test test/cortex/application_test.exs`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat(cortex): add Gateway.Supervisor and wire into application supervision tree`

### Task 4: Add Prometheus and LiveDashboard metrics for gateway events

- **Outcome:** `prometheus_metrics/0` in Application.ex and `metrics/0` in CortexWeb.Telemetry include counters/distributions for all five gateway telemetry events.
- **Files to create/modify:**
  - `lib/cortex/application.ex` — add gateway metrics to `prometheus_metrics/0`
  - `lib/cortex_web/telemetry.ex` — add gateway metrics to `metrics/0`
- **Exact verification command(s):**
  - `mix compile --warnings-as-errors`
  - `mix phx.server` then `curl http://localhost:4000/metrics` (verify gateway metric names appear)
- **Suggested commit message:** `feat(cortex): add Prometheus and LiveDashboard metrics for gateway events`

### Task 5: Integrate gateway events into DashboardLive and MeshLive

- **Outcome:** DashboardLive shows a "Connected Agents" card that updates on `agent_registered`/`agent_unregistered` events. MeshLive shows externally registered agents in the roster with a "gateway" source badge.
- **Files to create/modify:**
  - `lib/cortex_web/live/dashboard_live.ex` — subscribe to gateway events, add `connected_agents` assign and card
  - `lib/cortex_web/live/mesh_live.ex` — subscribe to gateway events, add external agents to member list
- **Exact verification command(s):**
  - `mix compile --warnings-as-errors`
  - `mix credo --strict lib/cortex_web/live/dashboard_live.ex lib/cortex_web/live/mesh_live.ex`
  - `mix phx.server` then open `http://localhost:4000/` and `http://localhost:4000/mesh` (visual inspection)
- **Suggested commit message:** `feat(cortex): show connected gateway agents in dashboard and mesh LiveViews`

### Task 6: Integration test — full connect/register/heartbeat/disconnect flow

- **Outcome:** End-to-end test that connects a WebSocket client, sends register + heartbeat messages, asserts PubSub events and telemetry events fire, then disconnects and asserts cleanup.
- **Files to create/modify:**
  - `test/cortex/gateway/integration_test.exs` — new test file
- **Exact verification command(s):**
  - `mix test test/cortex/gateway/integration_test.exs`
  - `mix test test/cortex/gateway/`
- **Suggested commit message:** `test(cortex): add integration test for gateway connect/register/heartbeat/disconnect flow`

---

## CLAUDE.md contributions (do NOT write the file; propose content)

### From Integration & Telemetry Engineer

**Coding style rules:**
- Gateway PubSub events use the `"cortex:gateway"` topic — do not broadcast gateway events on `"cortex:events"`.
- All gateway telemetry events are namespaced `[:cortex, :gateway, ...]` — never `[:cortex, :agent, ...]` (that namespace is for Cortex-spawned agents).
- Emission helpers follow the pattern: `emit_gateway_<category>_<event>(metadata)` where metadata is a plain map.
- Use `safe_broadcast` (rescue wrapper) for all PubSub calls in production code paths.

**Dev commands:**
```bash
mix test test/cortex/gateway/              # gateway unit + integration tests
mix test test/cortex/telemetry_test.exs    # telemetry emission tests
mix phx.server                             # start with gateway socket on /agent
curl http://localhost:4000/metrics         # check Prometheus gateway metrics
```

**Before you commit checklist:**
1. `mix format`
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix test test/cortex/gateway/` (all pass)
5. `mix test test/cortex/telemetry_test.exs` (updated count + new helpers pass)
6. No IO.inspect or dbg() left in code

**Guardrails:**
- Do NOT add `Gateway.Registry` or `Gateway.Health` to `Cortex.Supervisor` directly — they must be children of `Gateway.Supervisor`.
- Do NOT subscribe DashboardLive to heartbeat events at high frequency — only register/unregister for agent counts.
- Gateway telemetry handlers must be fast (< 1ms) — no I/O in handlers.

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture Explanation
- Gateway.Supervisor is a subtree within Cortex.Supervisor, started after PubSub and before the web layer
- Two parallel event systems: `Cortex.Events` (existing runs/mesh) and `Gateway.Events` (gateway agents) — same API shape, different PubSub topics
- WebSocket agents connect via `/agent` socket, which routes to AgentChannel (built by Gateway Architect)
- Channel operations trigger both PubSub broadcasts (for LiveViews) and `:telemetry` events (for Prometheus/LiveDashboard)

### Key Engineering Decisions + Tradeoffs
- Separate PubSub topic (`"cortex:gateway"`) avoids heartbeat noise on the main events topic, at the cost of two event modules
- Static Supervisor (not Dynamic) for gateway — simple and sufficient for single-tenant MVP
- Telemetry events carry `system_time` measurements for rate computation, matching existing patterns

### Limits of MVP + Next Steps
- No event persistence or replay — if a LiveView connects late, it misses prior events
- No backpressure on PubSub — high agent counts could grow LiveView mailboxes
- DashboardLive agent count is eventually consistent (PubSub-driven, not polled)
- Next: event sourcing for gateway events, agent connection rate limiting, per-agent telemetry drilldown

### How to Run Locally + How to Validate
- `mix deps.get && mix ecto.create && mix ecto.migrate`
- `mix phx.server` — starts on port 4000 with gateway socket at `/agent`
- `mix test test/cortex/gateway/` — run all gateway tests
- Open `http://localhost:4000/` — verify "Connected Agents: 0" card
- Open `http://localhost:4000/mesh` — verify external agent roster section
- `curl http://localhost:4000/metrics | grep cortex_gateway` — verify Prometheus metrics exist

---

## READY FOR APPROVAL
