# Protocol Engineer Plan — Phase 1: Agent Gateway

## You are in PLAN MODE.

### Project
I want to build the **Cluster Mode Agent Gateway** for Cortex.

**Goal:** build a **registration protocol and authentication layer** in which external agents connect via WebSocket, authenticate with bearer tokens, and exchange structured JSON messages with Cortex for registration, heartbeating, task results, and peer requests.

### Role + Scope
- **Role:** Protocol Engineer
- **Scope:** I own the message protocol definition (structs, parsing, validation, encoding), protocol versioning, and the authentication module. I do NOT own the Phoenix Channel implementation (Gateway Architect), the registry GenServer (Registry Engineer), or telemetry/integration wiring (Integration & Telemetry Engineer).
- **File I will write:** `docs/cluster-mode/phase-1-agent-gateway/plans/protocol-engineer.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

- **FR1:** Define all agent-to-Cortex message types as Elixir structs with `@enforce_keys` for required fields: `RegisterMessage`, `HeartbeatMessage`, `TaskResultMessage`, `StatusUpdateMessage`.
- **FR2:** Define all Cortex-to-agent message types as structs: `RegisteredResponse`, `TaskRequestMessage`, `PeerRequestMessage`.
- **FR3:** Implement `Protocol.parse/1` that takes raw JSON binary, decodes it, validates it against the correct message struct, and returns `{:ok, struct}` or `{:error, reasons}`.
- **FR4:** Implement `Protocol.encode/1` that serializes any outgoing message struct to JSON binary.
- **FR5:** Implement per-message-type validation functions (`validate_register/1`, `validate_heartbeat/1`, `validate_task_result/1`) that enforce required fields, correct types, and reject unknown fields.
- **FR6:** Implement protocol version checking — reject messages with `protocol_version` != 1 with a clear error.
- **FR7:** Implement `Auth.authenticate/1` that validates a bearer token against the `CORTEX_GATEWAY_TOKEN` environment variable. Returns `{:ok, %{identity: "bearer"}}` or `{:error, :unauthorized}`.
- **FR8:** Auth module must be designed as a behaviour so it can be swapped for OAuth/JWT later.
- **Tests required:** Unit tests for every message struct validation (happy path + every error case), round-trip parse/encode tests, protocol version rejection tests, auth tests with valid/invalid/missing tokens.
- **Metrics required:** None directly emitted by protocol code (telemetry integration is owned by Integration & Telemetry Engineer), but structs must carry enough data for telemetry to instrument later.

## Non-Functional Requirements

- **Language/runtime:** Elixir, OTP 26+, compiled with `--warnings-as-errors`.
- **Local dev:** `mix test test/cortex/gateway/` runs protocol + auth tests in < 2 seconds.
- **Observability:** Error tuples include human-readable reasons suitable for logging by the channel layer (e.g., `{:error, "missing required field: capabilities"}`).
- **Safety:** No secrets logged. `Auth` module reads env var at call time, not compile time. Token comparison uses constant-time comparison (`Plug.Crypto.secure_compare/2`) to prevent timing attacks.
- **Documentation:** `@moduledoc` and `@doc` on every public function. Message structs document the wire format so a sidecar implementer in Go/Python/Rust can implement the protocol from the docs alone.
- **Performance:** Parsing and validation must be O(n) in message size. No expensive operations (no DB calls, no network calls) in the protocol layer. Pure functions wherever possible.

---

## Assumptions / System Model

- **Deployment environment:** Single Cortex node (no distributed Erlang for Phase 1). Agents connect from anywhere over the network.
- **Failure modes:** Malformed JSON, missing fields, wrong types, unsupported protocol version, invalid auth token, expired/revoked tokens (future). The protocol layer returns structured errors for all of these; it never crashes.
- **Delivery guarantees:** WebSocket provides ordered, reliable delivery. The protocol layer does not implement its own acknowledgment or retry — that is the channel's responsibility.
- **Multi-tenancy:** Not in scope. Single-tenant with a single shared gateway token.
- **Protocol version:** Starts at 1. The `protocol_version` field is present on all inbound messages. Cortex rejects versions it does not support. This allows future breaking changes without ambiguity.

---

## Data Model

### Message Structs (all under `Cortex.Gateway.Protocol.Messages`)

**RegisterMessage**
```
Required: protocol_version, agent (map with name, role, capabilities), auth (map with token)
Optional: agent.metadata (map, default %{})
Validation: protocol_version == 1, name is non-empty string, role is non-empty string,
            capabilities is non-empty list of strings, token is non-empty string
```

**HeartbeatMessage**
```
Required: protocol_version, agent_id, status
Optional: load (map with active_tasks, queue_depth)
Validation: protocol_version == 1, agent_id is non-empty string,
            status in ["idle", "working", "draining"]
```

**TaskResultMessage**
```
Required: protocol_version, task_id, status, result
Optional: result.tokens (map), result.duration_ms (integer)
Validation: protocol_version == 1, task_id is non-empty string,
            status in ["completed", "failed", "cancelled"],
            result.text is string
```

**StatusUpdateMessage**
```
Required: protocol_version, agent_id, status
Optional: detail (string)
Validation: protocol_version == 1, agent_id is non-empty string,
            status in ["idle", "working", "draining"]
```

**RegisteredResponse** (outbound)
```
Required: type ("registered"), agent_id
Optional: mesh_info (map with peers count, run_id)
```

**TaskRequestMessage** (outbound)
```
Required: type ("task_request"), task_id, prompt, timeout_ms
Optional: tools (list of strings), context (map)
```

**PeerRequestMessage** (outbound)
```
Required: type ("peer_request"), request_id, from_agent, capability, input, timeout_ms
```

### Versioning Strategy
- All inbound messages carry `protocol_version: 1`.
- The protocol module has a `@supported_versions [1]` module attribute.
- `parse/1` checks the version first, before any field validation. Unsupported versions get `{:error, "unsupported protocol version: 2, supported: [1]"}`.
- When v2 is introduced, both can coexist in the supported list if backwards-compatible, or v1 can be removed.

### Persistence
- None. The protocol layer is purely functional — it transforms JSON to structs and back. No database, no ETS, no GenServer state.

---

## APIs

### `Cortex.Gateway.Protocol`

| Function | Spec | Description |
|----------|------|-------------|
| `parse(raw_json)` | `binary() -> {:ok, struct()} \| {:error, String.t() \| [String.t()]}` | Decode JSON, dispatch to the correct validator by `type` field |
| `encode(message)` | `struct() -> {:ok, binary()} \| {:error, term()}` | Serialize any outgoing message struct to JSON |
| `validate_register(map)` | `map() -> {:ok, RegisterMessage.t()} \| {:error, [String.t()]}` | Validate a decoded register payload |
| `validate_heartbeat(map)` | `map() -> {:ok, HeartbeatMessage.t()} \| {:error, [String.t()]}` | Validate a decoded heartbeat payload |
| `validate_task_result(map)` | `map() -> {:ok, TaskResultMessage.t()} \| {:error, [String.t()]}` | Validate a decoded task result payload |
| `validate_status_update(map)` | `map() -> {:ok, StatusUpdateMessage.t()} \| {:error, [String.t()]}` | Validate a decoded status update payload |
| `supported_versions()` | `-> [pos_integer()]` | Returns list of supported protocol versions |

### `Cortex.Gateway.Protocol.Messages`

Each struct module exposes:
| Function | Spec | Description |
|----------|------|-------------|
| `new(map)` | `map() -> {:ok, t()} \| {:error, [String.t()]}` | Build and validate from a decoded map |
| `to_map(struct)` | `t() -> map()` | Convert to a JSON-encodable map |

### `Cortex.Gateway.Auth`

| Function | Spec | Description |
|----------|------|-------------|
| `authenticate(token)` | `String.t() -> {:ok, map()} \| {:error, :unauthorized}` | Validate a bearer token |
| `authenticate(token, opts)` | `String.t(), keyword() -> {:ok, map()} \| {:error, :unauthorized}` | With options (for testing: `token_source` override) |

### `Cortex.Gateway.Auth` (behaviour)

```elixir
@callback authenticate(token :: String.t(), opts :: keyword()) ::
  {:ok, map()} | {:error, :unauthorized}
```

The default implementation (`Cortex.Gateway.Auth.Bearer`) reads from env var. The behaviour allows future implementations (JWT, OAuth) to be swapped via application config.

---

## Architecture / Component Boundaries

### Component Diagram

```
                          raw JSON binary
                               │
                               ▼
                    ┌─────────────────────┐
                    │  Protocol.parse/1    │  ← pure function, no side effects
                    │  1. Jason.decode     │
                    │  2. version check    │
                    │  3. type dispatch    │
                    │  4. validate fields  │
                    └──────────┬──────────┘
                               │
                          {:ok, struct}
                               │
            ┌──────────────────┼──────────────────┐
            ▼                  ▼                   ▼
    RegisterMessage    HeartbeatMessage    TaskResultMessage
            │                  │                   │
            ▼                  ▼                   ▼
    (Channel layer handles routing — not my scope)
```

### Boundaries

- **Protocol module** is a pure functional layer. It receives binary, returns structs or errors. It does NOT call GenServers, PubSub, or any process. The Channel (Gateway Architect) calls `Protocol.parse/1` on incoming messages and `Protocol.encode/1` on outgoing messages.
- **Auth module** has one side effect: reading the `CORTEX_GATEWAY_TOKEN` env var. This is isolated behind the behaviour so tests can inject tokens.
- **Messages module** defines structs only. No behaviour, no processes, no side effects.

### Config Changes
- Auth backend is configured via `config :cortex, Cortex.Gateway.Auth, backend: Cortex.Gateway.Auth.Bearer`. The `Auth` module dispatches to the configured backend. For Phase 1, only `Bearer` exists.

### Concurrency Model
- N/A for protocol layer — all functions are pure and stateless. They can be called from any process (Channel processes, test processes, etc.) without synchronization.

### Backpressure
- N/A at the protocol layer. The Channel layer (Gateway Architect's scope) is responsible for rate limiting and backpressure on the WebSocket connection.

---

## Correctness Invariants

1. **Round-trip fidelity:** For every valid inbound message, `parse(raw_json)` produces a struct that, when converted with `to_map/1` and re-encoded, produces semantically equivalent JSON (field order may differ).
2. **Strict validation:** `parse/1` rejects any message missing a required field. No silent defaults for required fields.
3. **Unknown field rejection:** Messages with fields not in the schema are rejected to prevent silent drift between protocol versions.
4. **Version gating:** `parse/1` rejects any `protocol_version` not in `@supported_versions` before attempting field validation.
5. **Auth constant-time comparison:** Token comparison uses `Plug.Crypto.secure_compare/2`, never `==`.
6. **No partial structs:** Every struct returned by `new/1` has all `@enforce_keys` fields populated. The struct cannot exist in a partially-valid state.
7. **Error accumulation:** Validation collects ALL errors (not just the first), so clients get a complete list of issues in one round-trip.

---

## Tests

### Unit Tests — `test/cortex/gateway/protocol_test.exs`

**Parse dispatch tests:**
- Parse a valid `register` JSON -> returns `{:ok, %RegisterMessage{}}`
- Parse a valid `heartbeat` JSON -> returns `{:ok, %HeartbeatMessage{}}`
- Parse a valid `task_result` JSON -> returns `{:ok, %TaskResultMessage{}}`
- Parse a valid `status_update` JSON -> returns `{:ok, %StatusUpdateMessage{}}`
- Parse invalid JSON -> returns `{:error, "invalid JSON: ..."}`
- Parse JSON without `type` field -> returns `{:error, "missing required field: type"}`
- Parse JSON with unknown `type` -> returns `{:error, "unknown message type: ..."}`

**Protocol version tests:**
- Parse with `protocol_version: 1` -> succeeds
- Parse with `protocol_version: 2` -> returns `{:error, "unsupported protocol version: 2, supported: [1]"}`
- Parse with missing `protocol_version` -> returns error

**Register validation tests:**
- Valid register with all fields -> `{:ok, %RegisterMessage{}}`
- Valid register with optional metadata -> includes metadata
- Missing `agent.name` -> error includes "missing required field: agent.name"
- Missing `agent.capabilities` -> error includes "missing required field: agent.capabilities"
- Empty capabilities list -> error includes "capabilities must be a non-empty list"
- Capabilities with non-string values -> error
- Unknown fields at top level -> error includes "unknown field: ..."
- Missing `auth.token` -> error includes "missing required field: auth.token"

**Heartbeat validation tests:**
- Valid heartbeat -> `{:ok, %HeartbeatMessage{}}`
- Missing `agent_id` -> error
- Invalid `status` value -> error includes "invalid status: ..."
- With optional `load` map -> includes load data

**Task result validation tests:**
- Valid task result -> `{:ok, %TaskResultMessage{}}`
- Missing `task_id` -> error
- Invalid `status` value -> error
- Missing `result.text` -> error
- With optional `tokens` and `duration_ms` -> included in struct

**Encode tests:**
- Encode `RegisteredResponse` -> valid JSON with `type: "registered"`
- Encode `TaskRequestMessage` -> valid JSON with all required fields
- Encode `PeerRequestMessage` -> valid JSON with all required fields

**Round-trip tests:**
- For each inbound message type: encode example -> parse -> verify struct matches

### Unit Tests — `test/cortex/gateway/auth_test.exs`

- Valid token matches env var -> `{:ok, %{identity: "bearer"}}`
- Invalid token -> `{:error, :unauthorized}`
- Empty token -> `{:error, :unauthorized}`
- Nil token -> `{:error, :unauthorized}`
- Missing env var (not set) -> `{:error, :unauthorized}` (fail closed)

### Property/Fuzz Tests
- N/A for Phase 1 MVP. The strict validation + comprehensive unit tests provide sufficient coverage. Property tests could be added in Phase 2 if the protocol grows.

### Failure Injection Tests
- N/A for protocol layer — it is a pure functional layer with no processes to kill or network to partition.

### Run Command
```bash
mix test test/cortex/gateway/protocol_test.exs test/cortex/gateway/auth_test.exs
```

Or the full directory:
```bash
mix test test/cortex/gateway/
```

---

## Benchmarks + "Success"

N/A — The protocol layer is pure JSON parsing and struct construction. It will be fast by construction (Jason decoding + map traversal). If latency becomes a concern, the bottleneck will be in WebSocket framing or channel process overhead, not in protocol parsing.

If benchmarks are desired later, the target would be: parse + validate a register message in < 50 microseconds on a single core.

---

## Engineering Decisions & Tradeoffs

### Decision 1: Structs with `@enforce_keys` vs. plain maps

- **Decision:** Use dedicated Elixir structs with `@enforce_keys` for each message type.
- **Alternatives considered:** Plain maps with schema validation (like Ecto changesets), or a single generic `%Message{type, payload}` struct.
- **Why:** Structs give compile-time guarantees (pattern matching on `%RegisterMessage{}` in function heads), better documentation (fields are self-documenting), and prevent typo bugs. Each message type has different required fields, so distinct structs map naturally to the protocol spec.
- **Tradeoff acknowledged:** More files and more boilerplate compared to plain maps. Adding a new message type requires creating a new struct module and wiring it into the parser dispatch. This is acceptable because message types change infrequently and the explicitness prevents bugs.

### Decision 2: Reject unknown fields (strict parsing) vs. ignore unknown fields (lenient parsing)

- **Decision:** Reject messages containing fields not defined in the schema.
- **Alternatives considered:** Silently ignore unknown fields (common in REST APIs), or collect them in a `_extra` map.
- **Why:** Strict parsing catches mismatches between sidecar and Cortex versions early. If a sidecar sends a field that Cortex doesn't understand, it's better to fail loudly than silently drop data the sidecar expected Cortex to process. This is especially important for a versioned protocol — unknown fields likely indicate a version mismatch.
- **Tradeoff acknowledged:** Strict parsing makes rolling upgrades harder. If a newer sidecar sends a new optional field to an older Cortex, the message is rejected. Mitigation: protocol version bumps are coordinated, and the version check happens first, so the error message is clear about the mismatch.

### Decision 3: Auth as a behaviour with env-var default

- **Decision:** Define `Cortex.Gateway.Auth` as a behaviour with a `Bearer` implementation that reads from `CORTEX_GATEWAY_TOKEN`.
- **Alternatives considered:** Hardcoded token comparison without behaviour abstraction, or full JWT from day one.
- **Why:** The behaviour adds minimal complexity (one `@callback`, one `defmodule`) but makes testing clean (inject a mock backend) and future migration to JWT/OAuth straightforward (implement the behaviour, change config). Full JWT would be over-engineering for Phase 1.
- **Tradeoff acknowledged:** The env-var approach means all agents share one token. No per-agent identity or permissions until JWT is added. Acceptable for single-tenant MVP.

### Decision 4: Error accumulation vs. fail-fast

- **Decision:** Validation collects all errors into a list rather than failing on the first error.
- **Alternatives considered:** Fail-fast on first validation error (simpler implementation).
- **Why:** Agent developers (who may be implementing sidecars in Go/Python/Rust) benefit from seeing all issues at once rather than fixing one error, re-sending, and discovering the next. This is a significant UX improvement for protocol implementers.
- **Tradeoff acknowledged:** Slightly more complex validation code — each validator must traverse all fields even after finding an error. The complexity is modest since message schemas are small (< 10 fields each).

---

## Risks & Mitigations

### Risk 1: Protocol spec drift between plan and implementation
- **Impact:** Sidecar engineer builds against a different message format than what the protocol module enforces.
- **Mitigation:** The message structs and their `@moduledoc` serve as the executable spec. The sidecar engineer references the struct definitions, not this plan doc. Also, round-trip tests catch any encode/parse mismatches.
- **Validation time:** < 5 minutes — run round-trip tests and review struct docs.

### Risk 2: Strict unknown-field rejection blocks integration testing
- **Impact:** Other engineers add fields to messages during development that the protocol rejects, causing false test failures.
- **Mitigation:** Communicate the strict policy in the integration meeting. If needed, add a `strict: false` option to `parse/1` during development that logs warnings instead of rejecting. Remove the option before merge to main.
- **Validation time:** < 5 minutes — run integration tests with both strict and lenient modes.

### Risk 3: Auth module env var not set in test environment
- **Impact:** Auth tests fail or pass vacuously because `CORTEX_GATEWAY_TOKEN` is not set.
- **Mitigation:** Auth module accepts a `token_source` option (keyword arg) that defaults to `System.get_env("CORTEX_GATEWAY_TOKEN")`. Tests pass `token_source: "test-token"` to make tests hermetic and independent of env vars.
- **Validation time:** < 2 minutes — run auth tests with and without the env var set.

### Risk 4: Jason dependency version mismatch
- **Impact:** Protocol relies on Jason for JSON encoding/decoding. If another dependency pulls in an incompatible version, compilation breaks.
- **Mitigation:** Cortex already uses Jason (via Phoenix). Pin to the same version. Verify with `mix deps.tree | grep jason`.
- **Validation time:** < 1 minute — check `mix.lock`.

### Risk 5: Constant-time comparison dependency
- **Impact:** `Plug.Crypto.secure_compare/2` is needed for timing-attack-safe token comparison. If Plug.Crypto is not available, we fall back to `==` (insecure).
- **Mitigation:** Plug.Crypto is already a transitive dependency via Phoenix. Verify with `mix deps.tree | grep plug_crypto`. If somehow missing, add it explicitly.
- **Validation time:** < 1 minute — check deps.

---

# Recommended API Surface

```elixir
# Main entry point — Channel calls these
Cortex.Gateway.Protocol.parse(raw_json)        # -> {:ok, struct} | {:error, reasons}
Cortex.Gateway.Protocol.encode(message_struct)  # -> {:ok, json_binary} | {:error, term}
Cortex.Gateway.Protocol.supported_versions()    # -> [1]

# Per-type validators (called internally by parse, also public for direct use)
Cortex.Gateway.Protocol.validate_register(map)
Cortex.Gateway.Protocol.validate_heartbeat(map)
Cortex.Gateway.Protocol.validate_task_result(map)
Cortex.Gateway.Protocol.validate_status_update(map)

# Message structs
Cortex.Gateway.Protocol.Messages.RegisterMessage.new(map)
Cortex.Gateway.Protocol.Messages.RegisterMessage.to_map(struct)
# ... same pattern for all 7 message types

# Auth
Cortex.Gateway.Auth.authenticate(token)
Cortex.Gateway.Auth.authenticate(token, opts)
```

---

# Folder Structure

```
lib/cortex/gateway/
  protocol.ex                          # Parse, encode, validate dispatch
  protocol/
    messages.ex                        # All message struct definitions
  auth.ex                             # Auth behaviour + Bearer implementation

test/cortex/gateway/
  protocol_test.exs                   # Protocol parse/validate/encode tests
  auth_test.exs                       # Auth tests
```

Note: I chose to put all message structs in a single `messages.ex` file rather than one file per struct. The structs are small (< 20 lines each) and having them in one file makes it easy to see the full protocol at a glance. If the protocol grows significantly, they can be split into individual files.

---

# Step-by-Step Task Plan (Small Commits)

1. Create message struct definitions in `lib/cortex/gateway/protocol/messages.ex` with `@enforce_keys`, types, `new/1`, and `to_map/1`.
2. Create `lib/cortex/gateway/protocol.ex` with `parse/1`, `encode/1`, version checking, and per-type validation dispatch.
3. Create `lib/cortex/gateway/auth.ex` with the `Auth` behaviour and `Bearer` implementation.
4. Create `test/cortex/gateway/protocol_test.exs` with all parse, validate, encode, and round-trip tests.
5. Create `test/cortex/gateway/auth_test.exs` with all auth tests.
6. Run `mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test test/cortex/gateway/`.

---

# Tighten the Plan into 4-7 Small Tasks (STRICT)

### Task 1: Define all message structs

- **Outcome:** All 7 message struct modules exist in `messages.ex` with `@enforce_keys`, `@type t`, `new/1`, and `to_map/1` for each. No validation logic yet — just construction and serialization.
- **Files to create:** `lib/cortex/gateway/protocol/messages.ex`
- **Verification:** `mix compile --warnings-as-errors`
- **Commit message:** `feat(gateway): define protocol message structs for all 7 message types`

### Task 2: Implement protocol parse, validate, and encode

- **Outcome:** `Protocol.parse/1` decodes JSON, checks version, dispatches to the correct validator, returns `{:ok, struct}` or `{:error, reasons}`. `Protocol.encode/1` serializes outgoing structs to JSON. Validators enforce strict field checking with error accumulation.
- **Files to create:** `lib/cortex/gateway/protocol.ex`
- **Verification:** `mix compile --warnings-as-errors && mix credo --strict`
- **Commit message:** `feat(gateway): implement protocol parsing, validation, and encoding`

### Task 3: Implement auth behaviour and bearer backend

- **Outcome:** `Auth` behaviour defined. `Auth.Bearer` reads `CORTEX_GATEWAY_TOKEN` env var, compares with `Plug.Crypto.secure_compare/2`. `Auth.authenticate/1,2` dispatches to configured backend.
- **Files to create:** `lib/cortex/gateway/auth.ex`
- **Verification:** `mix compile --warnings-as-errors && mix credo --strict`
- **Commit message:** `feat(gateway): add auth behaviour with bearer token backend`

### Task 4: Add protocol tests

- **Outcome:** Comprehensive tests for parse dispatch, version gating, all 4 inbound message validators (happy + error paths), encode for all 3 outbound messages, and round-trip tests.
- **Files to create:** `test/cortex/gateway/protocol_test.exs`
- **Verification:** `mix test test/cortex/gateway/protocol_test.exs`
- **Commit message:** `test(gateway): add protocol parse, validate, and encode tests`

### Task 5: Add auth tests

- **Outcome:** Tests for valid token, invalid token, empty token, nil token, missing env var (fail closed).
- **Files to create:** `test/cortex/gateway/auth_test.exs`
- **Verification:** `mix test test/cortex/gateway/auth_test.exs`
- **Commit message:** `test(gateway): add auth module tests`

### Task 6: Final lint and full test pass

- **Outcome:** All code passes format check, credo strict, warnings-as-errors, and full test suite.
- **Files modified:** Any fixups from lint findings.
- **Verification:** `mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix test test/cortex/gateway/`
- **Commit message:** `chore(gateway): fix lint and format issues in protocol layer`

---

# CLAUDE.md Contributions (Proposed — Do NOT Write the File)

## From Protocol Engineer

### Coding Style
- All gateway protocol messages use structs with `@enforce_keys` — never raw maps
- Validation functions accumulate all errors, not fail-fast — return `{:error, [String.t()]}`
- Use `Plug.Crypto.secure_compare/2` for any token/secret comparison, never `==`
- Auth backends implement the `Cortex.Gateway.Auth` behaviour

### Dev Commands
```bash
mix test test/cortex/gateway/                      # protocol + auth tests
mix test test/cortex/gateway/protocol_test.exs     # protocol tests only
mix test test/cortex/gateway/auth_test.exs         # auth tests only
```

### Before You Commit
- Ensure `mix compile --warnings-as-errors` passes — protocol structs must have no unused fields
- Ensure `mix credo --strict` passes
- No `IO.inspect` or `dbg()` in protocol or auth code

### Guardrails
- Protocol version is checked BEFORE field validation — always
- Unknown fields are rejected by default (strict parsing)
- Auth module MUST fail closed: if the token source is missing/nil, return `{:error, :unauthorized}`
- Never log bearer tokens — log `"auth_failed"` or `"auth_succeeded"`, not the token value

---

# EXPLAIN.md Contributions (Proposed Outline Bullets)

### Flow / Architecture
- The protocol layer is a pure functional pipeline: `raw JSON -> Jason.decode -> version check -> type dispatch -> field validation -> struct`
- The Channel layer (Gateway Architect) calls `Protocol.parse/1` on every incoming WebSocket frame and `Protocol.encode/1` on every outgoing frame
- Auth is invoked once during the `register` message handling — the Channel passes the token from the register payload to `Auth.authenticate/1`

### Key Engineering Decisions + Tradeoffs
- **Strict unknown-field rejection** prevents silent protocol drift but requires coordinated version bumps between sidecar and Cortex
- **Error accumulation** in validation gives sidecar implementers all issues in one round-trip, at the cost of slightly more complex validators
- **Auth as a behaviour** keeps Phase 1 simple (env var token) while making JWT/OAuth migration a config change, not a rewrite
- **Single `messages.ex` file** keeps the full protocol visible at a glance; split into per-type files if it grows past ~300 lines

### Limits of MVP + Next Steps
- Single shared bearer token — no per-agent identity or RBAC
- No message compression or binary encoding — JSON only
- No protocol negotiation — client must know the server supports v1
- Next: JWT auth, protocol v2 with backwards compatibility, optional MessagePack encoding

### How to Run Locally + How to Validate
- `mix test test/cortex/gateway/` — all protocol and auth tests
- `mix compile --warnings-as-errors` — verify no unused struct fields
- To manually test protocol parsing: `Cortex.Gateway.Protocol.parse(~s({"type":"register","protocol_version":1,...}))` in `iex -S mix`

---

## READY FOR APPROVAL
