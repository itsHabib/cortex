# Proto & Codegen Engineer — Plan

## You are in PLAN MODE.

### Project
I want to do a **gRPC data-plane for Cortex agent mesh (Phase 2)**.

**Goal:** build a **protobuf service contract and code generation pipeline** in which we **define the typed interface between the Go sidecar and the Elixir gateway, and generate client/server stubs for both languages from a single `.proto` source of truth**.

### Role + Scope
- **Role:** Proto & Codegen Engineer
- **Scope:** Own the `.proto` file, `buf` configuration, code generation pipeline, and Makefile target. Explicitly do NOT own the gRPC server implementation (Gateway gRPC Engineer), the sidecar Go client (Sidecar Core Engineer), or the HTTP API (Sidecar HTTP API Engineer). This role produces the contract and generated stubs that those roles consume.
- **File you will write:** `docs/cluster-mode/phase-2-sidecar/plans-v2/proto-codegen.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** Define a protobuf v3 service `AgentGateway` in package `cortex.gateway.v1` with a single bidirectional streaming RPC `Connect(stream AgentMessage) returns (stream GatewayMessage)`.
- **FR2:** Define all message types using `oneof` for polymorphic dispatch: `AgentMessage` (Register, Heartbeat, TaskResult, StatusUpdate, PeerResponse) and `GatewayMessage` (Registered, TaskRequest, PeerRequest, RosterUpdate, Error).
- **FR3:** Use proper proto3 enums (not stringly-typed strings) for `AgentStatus` (IDLE, WORKING, DRAINING, DISCONNECTED) and `TaskStatus` (COMPLETED, FAILED, CANCELLED).
- **FR4:** Generate Go stubs to `sidecar/internal/proto/gatewayv1/` using `protoc-gen-go` and `protoc-gen-go-grpc`.
- **FR5:** Generate Elixir stubs to `lib/cortex/gateway/proto/` using `protoc-gen-elixir` (from the `grpc` hex package ecosystem).
- **FR6:** Provide a `make proto` target that regenerates all stubs from the `.proto` file and is idempotent.
- **FR7:** Include `buf lint` and `buf breaking` configuration for CI-level schema governance.
- **Tests required:** `buf lint` passes, `buf breaking` passes against the initial commit (baseline), generated Go code compiles (`go build ./...`), generated Elixir code compiles (`mix compile`).
- **Metrics required:** N/A — proto definitions are build-time artifacts, not runtime.

## Non-Functional Requirements
- Language/runtime: Protobuf v3 (schema), Go 1.22+ (generated stubs), Elixir 1.17+ (generated stubs)
- Local dev: `buf` CLI must be installable via `brew install bufbuild/buf/buf`; no Docker required for codegen
- Observability: N/A for proto definitions
- Safety: `buf breaking` prevents accidental wire-incompatible changes; `reserved` blocks prevent field ID reuse
- Documentation: doc comments in the `.proto` file itself; CLAUDE.md contributions for dev commands
- Performance: N/A for build-time code generation

---

## Assumptions / System Model
- **Deployment environment:** `buf` runs on developer machines (macOS/Linux) and CI. Generated code is checked into the repo so downstream engineers do not need `buf` installed.
- **Failure modes:** Proto compilation failure (syntax error), lint violation, breaking change detected, missing `buf` or `protoc-gen-*` plugin.
- **Delivery guarantees:** N/A — this is build tooling, not runtime.
- **Multi-tenancy:** N/A.

---

## Data Model

The proto file IS the data model. Key entities and their fields:

- **RegisterRequest**
  - `name` (string, required) — human-readable agent name
  - `role` (string) — agent role description
  - `capabilities` (repeated string) — advertised capabilities
  - `auth_token` (string) — bearer token for authentication
  - `metadata` (map<string, string>) — extensible key-value pairs
  - Validation: `name` must be non-empty; `auth_token` must be non-empty

- **RegisterResponse**
  - `agent_id` (string) — assigned UUID
  - `peer_count` (int32) — current mesh size
  - `run_id` (string) — active run ID, if any

- **Heartbeat**
  - `agent_id` (string) — sender identity
  - `status` (AgentStatus enum) — IDLE, WORKING, DRAINING
  - `active_tasks` (int32)
  - `queue_depth` (int32)

- **TaskRequest**
  - `task_id` (string)
  - `prompt` (string)
  - `tools` (repeated string)
  - `timeout_ms` (int64)
  - `context` (map<string, string>)

- **TaskResult**
  - `task_id` (string)
  - `status` (TaskStatus enum) — COMPLETED, FAILED, CANCELLED
  - `result_text` (string)
  - `duration_ms` (int64)
  - `input_tokens` (int32)
  - `output_tokens` (int32)

- **StatusUpdate**
  - `agent_id` (string)
  - `status` (AgentStatus enum)
  - `detail` (string) — human-readable progress text
  - `progress` (float) — 0.0 to 1.0

- **PeerRequest**
  - `request_id` (string)
  - `from_agent` (string)
  - `capability` (string)
  - `prompt` (string)
  - `timeout_ms` (int64)

- **PeerResponse**
  - `request_id` (string)
  - `status` (TaskStatus enum)
  - `result` (string)
  - `duration_ms` (int64)

- **RosterUpdate**
  - `agents` (repeated AgentInfo)

- **AgentInfo**
  - `id`, `name`, `role` (string)
  - `capabilities` (repeated string)
  - `status` (AgentStatus enum)
  - `metadata` (map<string, string>)

- **DirectMessage** (agent-to-agent messaging)
  - `message_id` (string) — unique message ID
  - `to_agent` (string) — target agent ID (empty for broadcast delivery)
  - `from_agent` (string) — sender agent ID (set by gateway on delivery)
  - `content` (string) — message body
  - `timestamp` (int64) — Unix millis
  - Appears in both `AgentMessage` (agent sends to gateway for routing) and `GatewayMessage` (gateway delivers to target agent's stream)

- **BroadcastRequest** (agent-to-all messaging)
  - `content` (string) — message body
  - Agent sends this; gateway delivers as `DirectMessage` to all other connected agents

- **Error**
  - `code` (string) — machine-readable error code
  - `message` (string) — human-readable description

**Knowledge endpoints:** Deferred to Phase 3. The HTTP API will return 501 for `GET/POST /knowledge`. No proto messages needed yet — knowledge storage and retrieval requires a separate design for persistence and querying that is out of scope for the gRPC transport layer.

**Versioning strategy:** Package path `cortex.gateway.v1` allows a future `v2` without breaking existing consumers. Field numbers are stable; `reserved` blocks prevent reuse of removed fields.

---

## APIs

The proto defines one RPC:

```
service AgentGateway {
  rpc Connect(stream AgentMessage) returns (stream GatewayMessage);
}
```

This is the only API surface this role defines. The RPC semantics:

| Direction | Message | Semantics |
|-----------|---------|-----------|
| Agent -> Gateway | `RegisterRequest` | First message on stream; must precede all others |
| Gateway -> Agent | `RegisterResponse` | Sent after successful registration |
| Agent -> Gateway | `Heartbeat` | Periodic (default 15s); keeps agent alive |
| Agent -> Gateway | `TaskResult` | Agent completed/failed a task |
| Agent -> Gateway | `StatusUpdate` | Progress update |
| Agent -> Gateway | `PeerResponse` | Response to a peer invocation |
| Agent -> Gateway | `DirectMessage` | Send a message to a specific agent (gateway routes by `to_agent`) |
| Agent -> Gateway | `BroadcastRequest` | Send a message to all agents (gateway fans out as DirectMessages) |
| Gateway -> Agent | `TaskRequest` | Cortex assigns work |
| Gateway -> Agent | `PeerRequest` | Another agent invoking this one |
| Gateway -> Agent | `DirectMessage` | Delivered message from another agent |
| Gateway -> Agent | `RosterUpdate` | Mesh membership changed |
| Gateway -> Agent | `Error` | Protocol-level error (bad message, auth failure) |

**Error semantics:** The `Error` message uses string codes (e.g., `"AUTH_FAILED"`, `"INVALID_MESSAGE"`, `"AGENT_NOT_FOUND"`). The gateway may send an `Error` and then close the stream for fatal errors, or send an `Error` and keep the stream open for non-fatal warnings.

---

## Architecture / Component Boundaries

This role owns:

```
proto/
  buf.yaml                          # buf module config (linting, breaking)
  buf.gen.yaml                      # codegen plugins and output paths
  cortex/gateway/v1/
    gateway.proto                   # THE contract

sidecar/internal/proto/gatewayv1/   # generated Go stubs (checked in)
  gateway.pb.go                     # message types
  gateway_grpc.pb.go                # gRPC client/server interfaces

lib/cortex/gateway/proto/           # generated Elixir stubs (checked in)
  gateway.pb.ex                     # message structs + encoding
```

**How changes propagate:**
1. Engineer edits `gateway.proto`
2. Runs `make proto`
3. `buf lint` validates style
4. `buf generate` produces Go + Elixir stubs
5. Engineer commits proto + generated files together
6. CI runs `buf breaking --against .git#branch=main` to catch wire-incompatible changes

**Concurrency model:** N/A — build-time only.

**Backpressure strategy:** N/A.

---

## Correctness Invariants

1. **Wire compatibility:** Once a field number is assigned and shipped, it must never be reassigned to a different type or semantic. Enforced by `buf breaking`.
2. **Enum zero values:** Every enum has an `_UNSPECIFIED = 0` sentinel so that unset fields are distinguishable from valid values. Enforced by `buf lint` (`ENUM_ZERO_VALUE_SUFFIX`).
3. **Oneof completeness:** `AgentMessage.msg` and `GatewayMessage.msg` must cover all message types for their respective direction. Enforced by code review; tested by ensuring the generated Go `isAgentMessage_Msg` interface has exactly the expected implementors.
4. **Package versioning:** Package path is `cortex.gateway.v1`; Go package is `gatewayv1`. These must stay in sync.
5. **Generated code freshness:** Generated code checked into the repo must match what `buf generate` produces. CI should verify `make proto && git diff --exit-code`.
6. **Reserved blocks:** Any removed field must have its number added to a `reserved` block to prevent accidental reuse.

---

## Tests

- **buf lint:** `cd proto && buf lint` — validates naming conventions, enum zero values, package structure.
  - Command: `cd proto && buf lint`
- **buf breaking:** `cd proto && buf breaking --against .git#branch=main` — detects wire-incompatible changes.
  - Command: `cd proto && buf breaking --against '.git#branch=main'`
- **Go compilation:** Generated Go code compiles with no errors.
  - Command: `cd sidecar && go build ./...`
- **Elixir compilation:** Generated Elixir code compiles with no warnings.
  - Command: `mix compile --warnings-as-errors`
- **Generated code freshness (CI):** Regenerate and diff.
  - Command: `make proto && git diff --exit-code sidecar/internal/proto/ lib/cortex/gateway/proto/`
- **Enum round-trip:** Go and Elixir generated code encode/decode the same enum values to the same wire bytes. Verified manually during initial integration (full automated test is Integration Test Engineer's scope).

Property/fuzz tests: N/A for proto definitions.
Failure injection tests: N/A.

---

## Benchmarks + "Success"

N/A — protobuf code generation is a build-time operation, not a runtime hot path. Proto encoding/decoding performance is a property of the generated libraries (google protobuf for Go, protobuf-elixir for Elixir) and does not need custom benchmarking at this stage.

**Success criteria for this role:**
1. `buf lint` passes with zero violations
2. `buf generate` produces compilable Go and Elixir stubs
3. `make proto` is idempotent (running it twice produces no diff)
4. All message types from the kickoff spec are represented with proper types (enums, not strings)
5. Other engineers (Gateway gRPC, Sidecar Core) can import and use the generated code immediately

---

## Engineering Decisions & Tradeoffs

### Decision 1: Use `buf` instead of raw `protoc`
- **Alternatives considered:** Raw `protoc` with shell scripts; `prototools`; `prototool` (deprecated)
- **Why:** `buf` provides integrated linting (`buf lint`), breaking change detection (`buf breaking`), dependency management (for `google/protobuf` imports), and a declarative `buf.gen.yaml` for codegen. Raw `protoc` requires manual plugin management, no lint/breaking, and fragile shell scripts.
- **Tradeoff acknowledged:** `buf` is an additional developer dependency (must be installed). Mitigated by the fact that generated code is checked in — only proto editors need `buf`.

### Decision 2: Use enums for status fields instead of strings
- **Alternatives considered:** String fields as shown in the kickoff YAML draft (e.g., `string status = 2; // idle, working, draining`)
- **Why:** Enums provide compile-time type safety, exhaustive switch/case checking in Go, clear documentation of valid values, and smaller wire size. Strings are error-prone (typos, case mismatches) and require runtime validation.
- **Tradeoff acknowledged:** Adding a new enum value requires a proto change + regeneration, whereas strings are "open." Mitigated by the fact that status values change rarely and should be deliberate.

### Decision 3: Check generated code into the repo
- **Alternatives considered:** Generate at build time only (add `buf generate` to `mix compile` and `go generate`)
- **Why:** Checking in generated code means downstream engineers (Gateway gRPC, Sidecar Core) can start immediately without installing `buf` or proto plugins. It also makes code review easier — reviewers can see exactly what changed in the generated stubs.
- **Tradeoff acknowledged:** Risk of generated code drifting from the proto source. Mitigated by the CI freshness check (`make proto && git diff --exit-code`).

### Decision 4: Single bidirectional stream instead of multiple unary RPCs
- **Alternatives considered:** Separate RPCs for Register, Heartbeat, SendTaskResult, etc.
- **Why:** A single `Connect` stream matches the always-on nature of the sidecar connection. The sidecar opens one stream on startup and keeps it open for the lifetime of the process. Using `oneof` for message dispatch is idiomatic protobuf and avoids the overhead of opening/closing streams per message type.
- **Tradeoff acknowledged:** Debugging is harder — all message types flow over one stream, so logging/tracing must include message type discrimination. Mitigated by including a message type tag in structured logs.

### Decision 5: Auth token in RegisterRequest, not gRPC metadata
- **Alternatives considered:** Per-RPC credentials via gRPC metadata (standard gRPC auth pattern)
- **Why:** Simpler for MVP — the token is part of the first message on the stream. No need for custom `credentials.PerRPCCredentials` implementation in Go or metadata interceptors in Elixir. Can migrate to per-RPC credentials later if needed.
- **Tradeoff acknowledged:** Non-standard — most gRPC services use metadata for auth. Acceptable for an internal service where the sidecar is the only client.

---

## Risks & Mitigations

### Risk 1: Elixir `grpc` hex package proto codegen compatibility
- **Risk:** The `grpc` hex package may not support `buf`-based code generation, or its `protoc-gen-elixir` plugin may have version incompatibilities with our proto3 features (oneof, maps, enums).
- **Impact:** Elixir stubs won't compile or won't have correct gRPC service modules, blocking the Gateway gRPC Engineer.
- **Mitigation:** Spike: install `protoc-gen-elixir`, generate from a minimal proto with oneof + map + enum, verify it compiles and the service module is usable. Check the `grpc` hex package docs for supported protoc plugin versions.
- **Validation time:** ~10 minutes

### Risk 2: `buf` plugin ecosystem for Elixir
- **Risk:** `buf` may not have a first-class Elixir plugin in its registry. May need to use `protoc` directly for Elixir codegen while using `buf` for Go + linting.
- **Impact:** `buf.gen.yaml` can't be a single source of truth for all codegen; may need a hybrid approach.
- **Mitigation:** Check `buf.build` plugin registry for Elixir support. If missing, use `buf generate` for Go and a separate `protoc --elixir_out` invocation for Elixir, both wrapped in `make proto`.
- **Validation time:** ~5 minutes

### Risk 3: Generated Elixir module naming conflicts
- **Risk:** Generated Elixir modules may conflict with existing `Cortex.Gateway.*` modules (e.g., `Cortex.Gateway.Protocol` already exists from Phase 1).
- **Impact:** Compilation errors or confusing namespace collisions.
- **Mitigation:** Generate into `lib/cortex/gateway/proto/` so modules are namespaced under `Cortex.Gateway.Proto.*` (e.g., `Cortex.Gateway.Proto.RegisterRequest`). Verify no conflicts with existing modules before committing.
- **Validation time:** ~5 minutes

### Risk 4: Go module initialization in `sidecar/`
- **Risk:** The `sidecar/` directory is a new Go module. The generated Go code depends on `google.golang.org/protobuf` and `google.golang.org/grpc`, which must be in `go.mod` before the generated code compiles.
- **Impact:** `go build ./...` fails until `go.mod` has the right dependencies.
- **Mitigation:** Initialize `go.mod` with `go mod init` and `go mod tidy` after generating stubs, as part of the `make proto` target. Include this in the task plan.
- **Validation time:** ~5 minutes

### Risk 5: Proto field numbering diverges from kickoff spec
- **Risk:** The kickoff YAML shows specific field numbers. If we renumber fields (e.g., to add enum types), we must ensure all teammates reference the same contract.
- **Impact:** Gateway gRPC Engineer and Sidecar Core Engineer may hardcode field assumptions that break.
- **Mitigation:** The generated code is the contract, not the kickoff YAML. Once `make proto` produces stubs, all downstream engineers import from the generated packages. Announce field number changes in the plan doc.
- **Validation time:** ~2 minutes (review field numbers in generated code)

---

## Recommended API Surface

One service, one RPC:

```protobuf
service AgentGateway {
  // Connect opens a bidirectional stream between a sidecar and the gateway.
  // The first AgentMessage MUST be a RegisterRequest.
  // The gateway responds with RegisterResponse, then both sides exchange
  // messages asynchronously for the lifetime of the connection.
  rpc Connect(stream AgentMessage) returns (stream GatewayMessage);
}
```

All message types documented in the Data Model section above.

---

## Folder Structure

```
cortex/
├── proto/                                    # Proto source + buf config (this role)
│   ├── buf.yaml                              #   buf module config
│   ├── buf.gen.yaml                          #   codegen plugin config
│   └── cortex/gateway/v1/
│       └── gateway.proto                     #   THE service + message definitions
│
├── sidecar/                                  # Go module (Sidecar Core Engineer owns)
│   ├── go.mod                                #   initialized by this role (proto deps)
│   ├── go.sum
│   └── internal/proto/gatewayv1/             #   generated Go stubs (this role)
│       ├── gateway.pb.go
│       └── gateway_grpc.pb.go
│
├── lib/cortex/gateway/proto/                 # Generated Elixir stubs (this role)
│   └── gateway.pb.ex
│
└── Makefile                                  # Extended with `make proto` target (this role)
```

**Ownership:**
- `proto/` — this role (Proto & Codegen Engineer)
- `sidecar/internal/proto/gatewayv1/` — generated by this role, consumed by Sidecar Core Engineer
- `lib/cortex/gateway/proto/` — generated by this role, consumed by Gateway gRPC Engineer
- `Makefile` (proto target only) — this role

---

## Step-by-Step Task Plan

See "Tighten the plan" section below.

---

## Tighten the plan into 4-7 small tasks

### Task 1: Create the protobuf service definition
- **Outcome:** `proto/cortex/gateway/v1/gateway.proto` exists with the full service contract — `AgentGateway` service, all message types, proper enums (`AgentStatus`, `TaskStatus`), `oneof` wrappers, `reserved` blocks, and doc comments.
- **Files to create:**
  - `proto/cortex/gateway/v1/gateway.proto`
- **Verification:**
  - `protoc --proto_path=proto --descriptor_set_out=/dev/null proto/cortex/gateway/v1/gateway.proto` (syntax-valid)
  - Manual review: all message types from kickoff spec present, enums used for status fields, `oneof` used for polymorphic messages
- **Commit message:** `feat(proto): add AgentGateway service definition with all message types`

### Task 2: Set up buf configuration (lint + breaking)
- **Outcome:** `buf.yaml` and `buf.gen.yaml` exist with lint rules, breaking change detection config, and codegen plugin declarations for Go and Elixir.
- **Files to create:**
  - `proto/buf.yaml`
  - `proto/buf.gen.yaml`
- **Verification:**
  - `cd proto && buf lint` passes
  - `cd proto && buf build` succeeds
- **Commit message:** `feat(proto): add buf configuration for linting and code generation`

### Task 3: Generate Go stubs and initialize Go module
- **Outcome:** Go protobuf and gRPC stubs are generated in `sidecar/internal/proto/gatewayv1/`. The `sidecar/` Go module is initialized with required proto/gRPC dependencies so the generated code compiles.
- **Files to create:**
  - `sidecar/go.mod` (initialized)
  - `sidecar/go.sum`
  - `sidecar/internal/proto/gatewayv1/gateway.pb.go` (generated)
  - `sidecar/internal/proto/gatewayv1/gateway_grpc.pb.go` (generated)
- **Verification:**
  - `cd sidecar && go build ./...` (compiles)
  - `cd sidecar && go vet ./...` (no issues)
- **Commit message:** `feat(proto): generate Go gRPC stubs and initialize sidecar Go module`

### Task 4: Generate Elixir stubs (includes grpc hex package validation spike)
- **Outcome:** Elixir protobuf stubs are generated in `lib/cortex/gateway/proto/`. The `protobuf` and `grpc` hex deps are added to `mix.exs`. Generated modules compile without warnings. **Before generating:** validate that `protoc-gen-elixir` handles our proto3 features (oneof, maps, enums) and that the `grpc` hex package client can open a bidirectional stream. This is a ~10 minute spike that de-risks the entire Elixir gRPC stack for Gateway gRPC Engineer and Integration Test Engineer.
- **Files to create:**
  - `lib/cortex/gateway/proto/gateway.pb.ex` (generated)
- **Files to modify:**
  - `mix.exs` — add `{:protobuf, "~> 0.12"}` and `{:grpc, "~> 0.9"}` deps
- **Verification:**
  - `mix deps.get && mix compile --warnings-as-errors` (compiles)
  - `mix test` (existing tests still pass)
  - Validate: generated Elixir modules include oneof helpers, enum modules, and map field accessors
- **Commit message:** `feat(proto): generate Elixir protobuf stubs and add grpc deps`

### Task 5: Add `make proto` Makefile target
- **Outcome:** `make proto` regenerates all stubs from the `.proto` source. Running it twice produces no diff (idempotent). Includes `buf lint` as a pre-step.
- **Files to modify:**
  - `Makefile` — add `proto` target (and `proto-lint`, `proto-breaking` convenience targets)
- **Verification:**
  - `make proto` succeeds
  - `make proto && git diff --exit-code` (idempotent)
  - `make proto-lint` passes
- **Commit message:** `feat(proto): add make proto target for reproducible code generation`

### Task 6: Add CI freshness check and final validation
- **Outcome:** A verification script or Makefile target that CI can run to ensure generated code is in sync with the proto source. All existing tests still pass. Proto contract is documented.
- **Files to modify:**
  - `Makefile` — add `proto-check` target (`make proto && git diff --exit-code`)
- **Verification:**
  - `make proto-check` passes (returns 0)
  - `make check` still passes (existing CI)
  - `mix test` all pass
  - `cd sidecar && go build ./...` passes
- **Commit message:** `feat(proto): add CI freshness check for generated proto stubs`

---

## CLAUDE.md contributions (do NOT write the file; propose content)

## From Proto & Codegen Engineer

### Proto / Code Generation
- Proto source of truth: `proto/cortex/gateway/v1/gateway.proto`
- Generated Go stubs: `sidecar/internal/proto/gatewayv1/`
- Generated Elixir stubs: `lib/cortex/gateway/proto/`
- **Never hand-edit generated files** — modify the `.proto` and run `make proto`

### Coding Style (proto)
- All messages and fields have doc comments
- Enums use `_UNSPECIFIED = 0` as the zero value
- Use `oneof` for polymorphic message wrappers
- Field numbers are stable — add `reserved` blocks for removed fields
- Package path: `cortex.gateway.v1`

### Dev Commands
```bash
make proto              # regenerate all stubs (Go + Elixir)
make proto-lint         # run buf lint on proto files
make proto-breaking     # check for wire-breaking changes vs main
make proto-check        # CI: regenerate + verify no diff (freshness)
```

### Before You Commit (proto changes)
1. `make proto` — regenerate stubs
2. `make proto-lint` — lint passes
3. `cd sidecar && go build ./...` — Go stubs compile
4. `mix compile --warnings-as-errors` — Elixir stubs compile
5. Commit the `.proto` AND generated files together (never one without the other)

### Guardrails
- `buf breaking` runs in CI — wire-incompatible changes will fail the build
- `make proto-check` in CI ensures generated code matches proto source
- Do NOT rename or renumber existing proto fields without updating `reserved`

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture
- The `.proto` file in `proto/cortex/gateway/v1/gateway.proto` is the single source of truth for the agent-gateway contract
- `buf generate` produces typed stubs for Go (sidecar client) and Elixir (gateway server) from this one file
- Both languages see the same message types, field names, and enum values — no manual JSON schema synchronization

### Key Engineering Decisions + Tradeoffs
- **buf over protoc:** Integrated linting and breaking change detection; tradeoff is an extra dev dependency
- **Enums over strings:** Compile-time safety for status fields; tradeoff is that adding values requires a proto change
- **Checked-in generated code:** Downstream engineers don't need buf installed; tradeoff is freshness drift (mitigated by CI check)
- **Single bidi stream:** Matches the always-on sidecar model; tradeoff is more complex message dispatch vs simple unary RPCs
- **Auth in message, not metadata:** Simpler MVP; can migrate to per-RPC credentials later

### Limits of MVP + Next Steps
- No proto-level authentication (no `google.api.http` annotations, no gRPC interceptors for auth)
- No streaming flow control beyond what gRPC provides natively
- Future: `cortex.gateway.v2` package path for breaking changes; `buf` remote registry for cross-repo proto sharing

### How to Run Locally + How to Validate
- Install buf: `brew install bufbuild/buf/buf`
- Generate stubs: `make proto`
- Verify Go: `cd sidecar && go build ./...`
- Verify Elixir: `mix compile --warnings-as-errors`
- Check freshness: `make proto-check`

---

## READY FOR APPROVAL
