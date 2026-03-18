# Registry Engineer — Phase 1 Plan

## You are in PLAN MODE.

### Project
I want to build a **Gateway Registry** for Cortex's Cluster Mode.

**Goal:** build a **GenServer-backed registry** that tracks all externally connected agents via WebSocket, their capabilities, health state, and channel pids — enabling capability-based discovery, automatic cleanup on disconnect, and health monitoring with configurable timeouts.

### Role + Scope
- **Role:** Registry Engineer
- **Scope:** I own the Gateway Registry GenServer, the RegisteredAgent struct, and the Health monitor GenServer. I do NOT own the Phoenix Channel (Gateway Architect), the wire protocol message parsing (Protocol Engineer), or telemetry event definitions (Integration & Telemetry Engineer). I provide the public API that the Channel calls into.
- **File I will write:** `docs/cluster-mode/phase-1-agent-gateway/plans/registry-engineer.md`
- **No-touch zones:** Do not edit any files outside this plan doc. Do not write code.

---

## Functional Requirements

- **FR1:** `Gateway.Registry` GenServer maintains a map of `agent_id -> RegisteredAgent` for all WebSocket-connected agents.
- **FR2:** `register/2` accepts agent info + channel pid, assigns a UUID, stores the agent, monitors the channel pid via `Process.monitor/1`, and emits an `:agent_registered` event via `Cortex.Events.broadcast/2`.
- **FR3:** `unregister/1` removes an agent by ID, demonitors the channel pid, and emits an `:agent_unregistered` event.
- **FR4:** `get/1` returns `{:ok, RegisteredAgent.t()}` or `{:error, :not_found}` for a given agent ID.
- **FR5:** `list/0` returns all registered agents.
- **FR6:** `list_by_capability/1` returns agents that advertise a given capability string.
- **FR7:** `update_status/2` updates an agent's status (`:idle`, `:working`, `:draining`, `:disconnected`) and its `last_heartbeat` timestamp.
- **FR8:** `get_channel/1` returns `{:ok, pid}` or `{:error, :not_found}` for routing messages to an agent's WebSocket channel.
- **FR9:** `handle_info({:DOWN, ...})` automatically unregisters agents whose channel process crashes or disconnects.
- **FR10:** `Gateway.Health` GenServer runs a periodic tick that checks `last_heartbeat` against a configurable `heartbeat_timeout_ms`. Agents exceeding the threshold are marked `:disconnected`. Agents exceeding a separate `removal_timeout_ms` are removed entirely.
- **FR11:** `RegisteredAgent` struct holds: `id`, `name`, `role`, `capabilities`, `status`, `channel_pid`, `metadata`, `registered_at`, `last_heartbeat`, `load`, `monitor_ref`.
- **Tests required:** Unit tests for Registry (register, unregister, lookup, capability query, monitor-based cleanup) and Health (timeout marking, removal). Integration test for Registry + Health working together.

## Non-Functional Requirements

- **Language/runtime:** Elixir/OTP, consistent with the rest of Cortex.
- **Local dev:** No new dependencies. `mix test test/cortex/gateway/` runs all gateway tests.
- **Observability:** Events broadcast via `Cortex.Events` for `:agent_registered`, `:agent_unregistered`, `:agent_status_changed`. Telemetry hooks will be added by the Integration & Telemetry Engineer — I expose the events, they wire the metrics.
- **Safety:** Monitor-based cleanup guarantees no orphan entries survive a channel crash. Health monitor marks stale agents before removing them (two-phase: disconnect then remove). All public functions return `{:ok, value} | {:error, reason}`.
- **Documentation:** `@moduledoc`, `@doc`, `@spec` on every public function per project conventions.
- **Performance:** ETS-backed lookups are not needed for MVP — a GenServer map handles hundreds of agents. The `list_by_capability/1` scan is O(n) which is acceptable for n < 1000. If we need to scale beyond that, we add an ETS table or a secondary index later.

---

## Assumptions / System Model

- **Deployment environment:** Single Cortex node (no distributed Erlang clustering for MVP). All WebSocket connections terminate on the same BEAM node.
- **Failure modes:** Channel process crash triggers `:DOWN` message -> auto-unregister. Registry GenServer crash loses all state (agents must re-register; the Channel processes are still alive and can re-register on reconnect). Health GenServer crash loses timers but restarts and rescans on next tick.
- **Delivery guarantees:** Events are best-effort via PubSub (same as existing `Cortex.Events` semantics). No persistence — registry is in-memory only.
- **Multi-tenancy:** Not in scope (per PROJECT.md non-goals). Single-tenant.
- **Concurrency model:** Registry is a single GenServer serializing all writes. Reads go through `GenServer.call/2`. This is the simplest correct approach and matches the pattern used by `Mesh.MemberList`.

---

## Data Model

### RegisteredAgent struct (`lib/cortex/gateway/registered_agent.ex`)

```
Fields:
  id            :: String.t()           # UUID v4, assigned at registration
  name          :: String.t()           # Human-readable name from register message
  role          :: String.t()           # Agent's role description
  capabilities  :: [String.t()]         # List of capability tags (e.g. ["security-review", "cve-lookup"])
  status        :: :idle | :working | :draining | :disconnected
  channel_pid   :: pid()                # The Phoenix Channel process pid
  monitor_ref   :: reference()          # Process.monitor ref for the channel pid
  metadata      :: map()                # Arbitrary metadata (model, provider, max_concurrent, etc.)
  registered_at :: DateTime.t()         # UTC timestamp of registration
  last_heartbeat:: DateTime.t()         # UTC timestamp of last heartbeat (or registration time initially)
  load          :: map()                # %{active_tasks: integer, queue_depth: integer}

@enforce_keys: [:id, :name, :role, :capabilities, :channel_pid, :monitor_ref]
```

**Validation rules:**
- `name` must be a non-empty binary.
- `capabilities` must be a list of binaries (may be empty).
- `channel_pid` must be a live pid at registration time.
- `status` defaults to `:idle`.
- `metadata` defaults to `%{}`.
- `load` defaults to `%{active_tasks: 0, queue_depth: 0}`.

**Versioning strategy:** The struct is internal — not serialized to wire format. Protocol versioning is handled by the Protocol Engineer at the message level. Struct changes are purely internal refactors.

**Persistence:** None. In-memory only. Agents re-register on reconnect.

---

## APIs

### Gateway.Registry public API

| Function | Spec | Returns | Side Effects |
|----------|------|---------|-------------|
| `start_link(opts)` | `keyword() -> GenServer.on_start()` | `{:ok, pid}` | Starts GenServer |
| `register(agent_info, channel_pid)` | `map(), pid() -> {:ok, RegisteredAgent.t()} \| {:error, term()}` | Registered agent with assigned UUID | Monitors pid, broadcasts `:agent_registered` |
| `unregister(agent_id)` | `String.t() -> :ok \| {:error, :not_found}` | `:ok` | Demonitors, broadcasts `:agent_unregistered` |
| `get(agent_id)` | `String.t() -> {:ok, RegisteredAgent.t()} \| {:error, :not_found}` | Agent struct | None |
| `list()` | `-> [RegisteredAgent.t()]` | All agents | None |
| `list_by_capability(cap)` | `String.t() -> [RegisteredAgent.t()]` | Matching agents | None |
| `update_status(agent_id, status)` | `String.t(), atom() -> :ok \| {:error, :not_found}` | `:ok` | Broadcasts `:agent_status_changed` |
| `update_heartbeat(agent_id, load)` | `String.t(), map() -> :ok \| {:error, :not_found}` | `:ok` | Updates `last_heartbeat` and `load` |
| `get_channel(agent_id)` | `String.t() -> {:ok, pid()} \| {:error, :not_found}` | Channel pid | None |
| `count()` | `-> non_neg_integer()` | Agent count | None |

**Error semantics:**
- `:not_found` — agent ID does not exist in the registry.
- `:invalid_status` — status atom not in allowed set.
- `:already_registered` — duplicate name (optional; may allow duplicates with different UUIDs).

### Gateway.Health public API

| Function | Spec | Returns |
|----------|------|---------|
| `start_link(opts)` | `keyword() -> GenServer.on_start()` | `{:ok, pid}` |

Health is autonomous — it has no public API beyond `start_link`. It periodically reads from `Gateway.Registry.list/0` and calls `Gateway.Registry.update_status/2` or `Gateway.Registry.unregister/1` as needed. Configuration is passed via `start_link` opts:

- `registry` — the Registry GenServer name/pid (default: `Gateway.Registry`)
- `check_interval_ms` — how often to run the health check (default: `15_000`)
- `heartbeat_timeout_ms` — how long since last heartbeat before marking `:disconnected` (default: `60_000`)
- `removal_timeout_ms` — how long in `:disconnected` state before removal (default: `300_000`)

---

## Architecture / Component Boundaries

### Components I own

1. **Gateway.Registry (GenServer)** — Single process holding the `%{agent_id => RegisteredAgent}` map. Serializes all mutations. Monitors channel pids.
2. **Gateway.RegisteredAgent (struct)** — Pure data struct, no behavior. Created by Registry during registration.
3. **Gateway.Health (GenServer)** — Periodic process that reads from Registry and enforces heartbeat timeouts. Follows the same timer-based pattern as `Mesh.Detector`.

### Integration points (I call into)

- `Cortex.Events.broadcast/2` — for event emission (`:agent_registered`, `:agent_unregistered`, `:agent_status_changed`)
- `UUID.uuid4()` — for agent ID generation (using the `elixir_uuid` or `Ecto.UUID` already in deps)

### Integration points (others call into me)

- **Gateway Channel** (Gateway Architect) calls `Registry.register/2`, `Registry.unregister/1`, `Registry.update_status/2`, `Registry.update_heartbeat/2`
- **Discovery module** (Discovery Engineer, Phase 3) calls `Registry.list_by_capability/1`
- **Dashboard** (Dashboard Engineer) calls `Registry.list/0`, `Registry.count/0`
- **Agent Tool** (Agent Tool Engineer, Phase 3) calls `Registry.get_channel/1`

### How config changes propagate

Health check intervals are set at `start_link` time. No runtime reconfiguration for MVP. If needed later, a `configure/2` call can be added to Health.

### Concurrency model

Single GenServer for Registry. Single GenServer for Health. Health reads from Registry via its public API (GenServer calls). No ETS, no concurrent reads for MVP. This matches the `Mesh.MemberList` pattern exactly.

### Backpressure strategy

Not applicable for MVP. The Registry GenServer processes one call at a time. With hundreds of agents, message queue depth stays trivial. If we hit thousands, we move state to ETS with `:read_concurrency`.

---

## Correctness Invariants

1. **Monitor invariant:** Every entry in the Registry map has a corresponding `Process.monitor` reference. If the monitored process dies, the entry is removed within one message processing cycle.
2. **No orphan entries:** After a channel pid exits, the Registry never returns that agent from `get/1`, `list/0`, or `list_by_capability/1`.
3. **UUID uniqueness:** Every registered agent gets a fresh UUID v4. Collisions are astronomically unlikely but we can add a check-and-retry if desired.
4. **Status validity:** `update_status/2` only accepts atoms in `[:idle, :working, :draining, :disconnected]`. Any other atom returns `{:error, :invalid_status}`.
5. **Event consistency:** Every `register` call that returns `{:ok, _}` has emitted exactly one `:agent_registered` event. Every successful `unregister` has emitted exactly one `:agent_unregistered` event. Monitor-triggered unregistration also emits the event.
6. **Health two-phase removal:** Health marks agents `:disconnected` first, removes only after `removal_timeout_ms`. An agent that resumes heartbeats before removal is restored to its previous status.
7. **Idempotent unregister:** Calling `unregister/1` on an already-removed agent returns `{:error, :not_found}` without side effects.

---

## Tests

### Unit tests — `test/cortex/gateway/registry_test.exs`

1. `register/2` assigns UUID, stores agent, returns `{:ok, agent}`
2. `register/2` with invalid input returns `{:error, reason}`
3. `get/1` returns `{:ok, agent}` for registered agent
4. `get/1` returns `{:error, :not_found}` for unknown ID
5. `list/0` returns all registered agents
6. `list_by_capability/1` returns only agents with matching capability
7. `list_by_capability/1` returns empty list when no match
8. `update_status/2` changes agent status
9. `update_status/2` rejects invalid status atoms
10. `update_heartbeat/2` updates `last_heartbeat` and `load`
11. `get_channel/1` returns channel pid for registered agent
12. `unregister/1` removes agent and demonitors
13. `unregister/1` returns `{:error, :not_found}` for unknown ID
14. Monitor-based cleanup: when channel pid dies, agent is auto-removed
15. Monitor-based cleanup: `:agent_unregistered` event is emitted
16. `count/0` returns correct count after register/unregister
17. Events: `:agent_registered` is broadcast on register
18. Events: `:agent_unregistered` is broadcast on unregister

### Unit tests — `test/cortex/gateway/health_test.exs`

1. Agents with stale `last_heartbeat` are marked `:disconnected` after `heartbeat_timeout_ms`
2. Agents with fresh `last_heartbeat` are not touched
3. Agents in `:disconnected` state exceeding `removal_timeout_ms` are removed via `unregister/1`
4. Agents that resume heartbeats before removal are not removed
5. Health check runs on configured interval (verify with short interval in test)
6. Health tolerates empty registry (no crash on zero agents)

### Integration test — `test/cortex/gateway/registry_integration_test.exs`

1. Full lifecycle: register -> heartbeat -> stop heartbeat -> health marks disconnected -> health removes
2. Register multiple agents, query by capability, kill one channel, verify cleanup

### Commands

```bash
mix test test/cortex/gateway/                    # all gateway tests
mix test test/cortex/gateway/registry_test.exs   # registry unit tests
mix test test/cortex/gateway/health_test.exs     # health unit tests
```

---

## Benchmarks + "Success"

N/A for MVP. The Registry serves hundreds of agents with a simple GenServer map. Benchmarking is not meaningful at this scale — the bottleneck will be WebSocket I/O, not map lookups.

If needed later, benchmark `list_by_capability/1` at 500 and 1000 agents to confirm O(n) scan stays under 1ms. But this is a Phase 3+ concern.

---

## Engineering Decisions & Tradeoffs

### Decision 1: GenServer map vs ETS table for agent storage

- **Decision:** Use a plain `%{}` map inside a GenServer.
- **Alternatives considered:** ETS table with `:read_concurrency` for concurrent reads; ETS + GenServer hybrid (writes through GenServer, reads direct from ETS).
- **Why:** Matches the existing `Mesh.MemberList` pattern exactly. Simpler to reason about, test, and debug. Hundreds of agents means the GenServer mailbox will never be a bottleneck. The existing codebase uses this pattern consistently — diverging adds cognitive load for no gain.
- **Tradeoff acknowledged:** All reads are serialized through the GenServer. Under heavy read load (thousands of concurrent `list_by_capability` calls), this could become a bottleneck. Acceptable because the constraint says "hundreds" of agents, not thousands of concurrent readers.

### Decision 2: Separate Gateway.Registry vs extending Agent.Registry

- **Decision:** Create a new `Cortex.Gateway.Registry` module, completely separate from `Cortex.Agent.Registry`.
- **Alternatives considered:** Extend `Agent.Registry` to handle both internal GenServer agents and external WebSocket agents behind a unified interface.
- **Why:** `Agent.Registry` is a thin wrapper around Elixir's built-in `Registry` module — it maps agent_id -> pid for locally-spawned GenServer processes. The Gateway Registry tracks externally-connected agents with rich metadata (capabilities, health, load). The data models are fundamentally different. Merging them would couple internal agent lifecycle with external WebSocket lifecycle, making both harder to reason about.
- **Tradeoff acknowledged:** Two registries means two places to look up an agent. Future work (Phase 3) may add a unified facade that queries both, but for now the separation keeps each module focused and testable.

### Decision 3: Health as a separate GenServer vs built into Registry

- **Decision:** Health is a separate GenServer (`Gateway.Health`) that reads from Registry via its public API.
- **Alternatives considered:** Build health checking directly into the Registry GenServer using `Process.send_after` (like `Mesh.Detector` is separate from `Mesh.MemberList`).
- **Why:** Follows the existing `Mesh.Detector` / `Mesh.MemberList` separation pattern. Keeps the Registry focused on CRUD operations. Health logic (timeouts, intervals, two-phase removal) is independently testable. If Health crashes, Registry keeps working (agents just won't get auto-removed for stale heartbeats until Health restarts).
- **Tradeoff acknowledged:** Two GenServers means inter-process communication overhead for health checks. Negligible for periodic (every 15s) checks on hundreds of agents.

---

## Risks & Mitigations

### Risk 1: Registry GenServer crash loses all agent state

- **Impact:** All agents appear unregistered. Dashboard goes blank. Routing fails until agents re-register.
- **Mitigation:** Registry is supervised with `:permanent` restart. On restart, existing channel processes are still alive — the Channel (Gateway Architect's scope) should detect the registry restart and re-register. We can also add a `:persistent_term` or ETS backup if needed, but for MVP, re-registration on restart is sufficient.
- **Validation time:** 5 minutes — write a test that kills the Registry, verifies it restarts, and confirm channel processes can re-register.

### Risk 2: Race between monitor-based cleanup and explicit unregister

- **Impact:** Double-unregister could emit duplicate `:agent_unregistered` events or crash on missing monitor ref.
- **Mitigation:** `unregister/1` is idempotent — if the agent is not in the map, return `{:error, :not_found}`. The `handle_info({:DOWN, ...})` handler checks if the agent still exists before removing. Since both run in the same GenServer, there is no true race — messages are serialized.
- **Validation time:** 5 minutes — write a test that unregisters explicitly then sends a synthetic `:DOWN` message and verifies no crash.

### Risk 3: Health check interval too aggressive, flooding Registry with calls

- **Impact:** Registry mailbox grows if Health is checking thousands of agents every second.
- **Mitigation:** Default interval is 15 seconds. Health does a single `list/0` call then iterates locally — so it's 1 call to Registry per tick for the read, plus N calls for any agents that need status updates (only stale ones). For hundreds of agents, this is trivially fast.
- **Validation time:** 5 minutes — test with 100 registered agents and 1-second health interval, verify no mailbox growth.

### Risk 4: UUID generation dependency

- **Impact:** If UUID generation is not available or the dependency is missing, registration fails.
- **Mitigation:** Use `Ecto.UUID.generate/0` which is already a dependency of the project (Ecto is in mix.exs). No new deps needed.
- **Validation time:** 2 minutes — verify `Ecto.UUID` is available in `mix deps`.

### Risk 5: Channel re-registration after Registry restart not handled

- **Impact:** After a Registry crash+restart, agents are connected at the WebSocket level but absent from the Registry. They become invisible.
- **Mitigation:** This is the Gateway Architect's responsibility (channel-side re-register logic). From the Registry side, I ensure `register/2` is idempotent for the same channel pid (if somehow called twice, the second call updates rather than duplicates). I will document this contract clearly for the Gateway Architect.
- **Validation time:** 5 minutes — test that calling `register/2` twice with the same channel pid does not create duplicate entries.

---

## Recommended API Surface

```elixir
# Gateway.Registry
Gateway.Registry.start_link(opts)
Gateway.Registry.register(agent_info, channel_pid)    # -> {:ok, RegisteredAgent.t()} | {:error, term()}
Gateway.Registry.unregister(agent_id)                  # -> :ok | {:error, :not_found}
Gateway.Registry.get(agent_id)                         # -> {:ok, RegisteredAgent.t()} | {:error, :not_found}
Gateway.Registry.list()                                # -> [RegisteredAgent.t()]
Gateway.Registry.list_by_capability(capability)        # -> [RegisteredAgent.t()]
Gateway.Registry.update_status(agent_id, status)       # -> :ok | {:error, :not_found | :invalid_status}
Gateway.Registry.update_heartbeat(agent_id, load)      # -> :ok | {:error, :not_found}
Gateway.Registry.get_channel(agent_id)                 # -> {:ok, pid()} | {:error, :not_found}
Gateway.Registry.count()                               # -> non_neg_integer()

# Gateway.Health
Gateway.Health.start_link(opts)
```

## Folder Structure

```
lib/cortex/gateway/
  registered_agent.ex       # RegisteredAgent struct
  registry.ex               # Gateway Registry GenServer
  health.ex                 # Health monitor GenServer

test/cortex/gateway/
  registry_test.exs         # Registry unit tests
  health_test.exs           # Health unit tests
  registry_integration_test.exs  # Integration tests
```

## Step-by-step task plan (small commits)

See "Tighten the plan" section below.

## Benchmark plan

N/A — see Benchmarks section above. Not meaningful at MVP scale.

---

## Tighten the plan into 4-7 small tasks

### Task 1: RegisteredAgent struct

- **Outcome:** A pure data struct representing a WebSocket-connected agent with all required fields, types, and enforce_keys.
- **Files to create:** `lib/cortex/gateway/registered_agent.ex`
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix format --check-formatted
  ```
- **Suggested commit message:** `feat(gateway): add RegisteredAgent struct for external agent tracking`

### Task 2: Gateway Registry GenServer — core CRUD

- **Outcome:** GenServer with `register/2`, `unregister/1`, `get/1`, `list/0`, `count/0`. Process monitoring on register, auto-cleanup on `:DOWN`. Event broadcasting.
- **Files to create:** `lib/cortex/gateway/registry.ex`
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix format --check-formatted
  ```
- **Suggested commit message:** `feat(gateway): add Gateway Registry GenServer with CRUD and process monitoring`

### Task 3: Gateway Registry — capability query, status, heartbeat

- **Outcome:** `list_by_capability/1`, `update_status/2`, `update_heartbeat/2`, `get_channel/1` functions added to Registry.
- **Files to modify:** `lib/cortex/gateway/registry.ex`
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix format --check-formatted
  ```
- **Suggested commit message:** `feat(gateway): add capability query, status update, and heartbeat tracking to Registry`

### Task 4: Registry unit tests

- **Outcome:** Full test coverage for all Registry public functions: register, unregister, get, list, list_by_capability, update_status, update_heartbeat, get_channel, count, monitor cleanup, event emission.
- **Files to create:** `test/cortex/gateway/registry_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex/gateway/registry_test.exs
  ```
- **Suggested commit message:** `test(gateway): add comprehensive unit tests for Gateway Registry`

### Task 5: Gateway Health GenServer

- **Outcome:** Periodic health check GenServer that marks stale agents as `:disconnected` and removes long-disconnected agents. Configurable intervals.
- **Files to create:** `lib/cortex/gateway/health.ex`
- **Verification:**
  ```bash
  mix compile --warnings-as-errors
  mix format --check-formatted
  ```
- **Suggested commit message:** `feat(gateway): add Health monitor GenServer for heartbeat timeout enforcement`

### Task 6: Health unit tests + integration test

- **Outcome:** Tests for Health timeout logic (mark disconnected, remove after threshold, tolerate fresh agents, tolerate empty registry). Integration test for full register -> heartbeat timeout -> disconnect -> removal lifecycle.
- **Files to create:** `test/cortex/gateway/health_test.exs`, `test/cortex/gateway/registry_integration_test.exs`
- **Verification:**
  ```bash
  mix test test/cortex/gateway/
  mix credo --strict lib/cortex/gateway/
  ```
- **Suggested commit message:** `test(gateway): add Health unit tests and Registry integration tests`

---

## CLAUDE.md contributions

### From Registry Engineer

**Coding style (reinforce existing):**
- `@moduledoc`, `@doc`, `@spec` on all public functions
- `defstruct` with `@enforce_keys` for required fields
- Pattern match in function heads
- Return `{:ok, value} | {:error, reason}` from fallible functions

**Dev commands:**
```bash
mix test test/cortex/gateway/                          # all gateway tests
mix test test/cortex/gateway/registry_test.exs         # registry unit tests
mix test test/cortex/gateway/health_test.exs           # health unit tests
```

**Before you commit checklist:**
1. `mix format`
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix test test/cortex/gateway/`
5. No `IO.inspect` or `dbg()` left in code

**Guardrails:**
- `Gateway.Registry` is distinct from `Agent.Registry` — do not merge them
- `Gateway.Health` reads from Registry via its public API — do not access Registry state directly
- Events use `Cortex.Events.broadcast/2` — do not call `:telemetry.execute` directly from Registry (that's the telemetry engineer's job)
- Use `Ecto.UUID.generate/0` for agent IDs — no new UUID dependencies

---

## EXPLAIN.md contributions

### Flow / architecture explanation
- Gateway Registry is a GenServer that tracks externally-connected agents (via WebSocket), separate from the existing `Agent.Registry` which tracks locally-spawned GenServer agents
- Channel processes call `Registry.register/2` on agent join and `Registry.unregister/1` on leave; `Process.monitor` provides automatic cleanup on crash
- Health GenServer runs periodic checks against `last_heartbeat` timestamps, enforcing a two-phase removal: mark `:disconnected` first, remove after extended timeout
- Events flow through `Cortex.Events` PubSub for dashboard updates and telemetry

### Key engineering decisions + tradeoffs
- GenServer map over ETS: simpler, matches existing MemberList pattern, sufficient for hundreds of agents
- Separate from Agent.Registry: different data models (rich metadata vs pid lookup), keeps concerns isolated
- Health as separate GenServer: follows Detector/MemberList pattern, independently testable, crash-isolated

### Limits of MVP + next steps
- Single-node only — no distributed registry across BEAM nodes
- O(n) capability scan — add secondary index if agent count exceeds ~1000
- No persistence — agents must re-register after Registry restart
- Future: unified facade querying both Agent.Registry and Gateway.Registry

### How to run locally + how to validate
- `mix test test/cortex/gateway/` — runs all gateway tests
- `mix phx.server` then connect a WebSocket client to test registration flow end-to-end (requires Channel from Gateway Architect)
- Check `Cortex.Events` subscribers receive `:agent_registered` / `:agent_unregistered` events

---

## READY FOR APPROVAL
