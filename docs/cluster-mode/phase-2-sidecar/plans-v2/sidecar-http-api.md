# Sidecar HTTP API Plan

## You are in PLAN MODE.

### Project
I want to build the **Cortex Sidecar HTTP API** — the local HTTP/JSON server inside the Go sidecar that agents call to interact with the mesh.

**Goal:** build a **chi-based HTTP API** in which agents call `localhost:9090` to discover peers, exchange messages, invoke other agents, publish/query knowledge, and report status — all bridged to the Cortex gateway via the sidecar's gRPC bidirectional stream.

### Role + Scope
- **Role:** Sidecar HTTP API Engineer
- **Scope:** I own the chi router setup, all HTTP handler files, JSON request/response formatting, error middleware, request logging middleware, and handler-level unit tests. I do NOT own the gRPC client (`internal/gateway/client.go`), state store (`internal/state/state.go`), sidecar configuration (`internal/config/`), CLI entrypoint (`cmd/`), packaging, or integration tests.
- **File I will write:** `docs/cluster-mode/phase-2-sidecar/plans-v2/sidecar-http-api.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

1. **Health** — `GET /health` returns sidecar connectivity status (gRPC connected, agent registered, uptime).
2. **Roster** — `GET /roster`, `GET /roster/{agent_id}`, `GET /roster/capable/{capability}` return cached mesh agent data from the State store.
3. **Messaging** — `GET /messages` returns pending inbound messages; `POST /messages/{agent_id}` sends a `DirectMessage` via gRPC (`gateway.Client.SendDirectMessage`); `POST /broadcast` sends a `BroadcastRequest` via gRPC (`gateway.Client.Broadcast`).
4. **Invocation** — `POST /ask/{agent_id}` and `POST /ask/capable/{capability}` perform synchronous agent-to-agent calls. These block until a PeerResponse arrives via the gRPC stream or the timeout expires.
5. **Knowledge** — DEFERRED to Phase 3. `GET /knowledge` and `POST /knowledge` return 501 Not Implemented. Knowledge requires proto messages and persistence not yet designed.
6. **Status** — `POST /status` reports progress to Cortex; `GET /task` returns the current task assignment; `POST /task/result` submits a task result.
7. **Error format** — Every error response uses the uniform shape `{"error": "<message>", "code": "<CODE>"}` with an appropriate HTTP status code.

## Non-Functional Requirements

1. **Latency** — All non-blocking endpoints (health, roster, messages, knowledge queries, status, task) must respond in < 10 ms under normal load. The sidecar serves a single co-located agent, so contention is near-zero.
2. **Blocking invocation** — `/ask` endpoints block for up to the caller-specified `timeout_ms` (default 60 s, max 300 s). The HTTP server must not starve other endpoints while an `/ask` call is in flight. Go's goroutine-per-request model handles this naturally.
3. **Localhost only** — The HTTP server binds to `127.0.0.1:CORTEX_SIDECAR_PORT`. No authentication is required on the local API (the sidecar trusts the co-located agent).
4. **JSON only** — All request and response bodies are `application/json`. Non-JSON POST requests return 415 Unsupported Media Type.
5. **Graceful degradation** — If the gRPC connection to Cortex is down, read-only endpoints (health, roster cache, messages, task) still return cached data with a `"connected": false` field. Write endpoints (send message, ask, status, publish knowledge) return 503.
6. **Structured logging** — All requests are logged via `slog` middleware with method, path, status, and duration.

---

## Assumptions / System Model

1. The sidecar runs exactly one HTTP server on `127.0.0.1:CORTEX_SIDECAR_PORT` (default 9090).
2. **State store** (`internal/state/state.go`, built by Sidecar Core Engineer) is a thread-safe struct (sync.RWMutex) that:
   - Caches the mesh roster (list of `AgentInfo` proto structs, received via `RosterUpdate` messages).
   - Stores pending inbound messages (received via gRPC stream).
   - Tracks the current task assignment (received via `TaskRequest`).
   - Tracks connection status (`connected` / `disconnected` / `reconnecting`).
   - Exposes methods: `GetRoster() []*pb.AgentInfo`, `GetAgent(id string) (*pb.AgentInfo, bool)`, `GetCapable(capability string) []*pb.AgentInfo`, `PopMessages() []Message`, `GetTask() *pb.TaskRequest`, `IsConnected() bool`, `GetAgentID() string`, `GetUptime() time.Duration`, `GetStatus() ConnectionStatus`, `GetConnectionInfo() ConnectionInfo`.
3. **Gateway client** (`internal/gateway/client.go`, built by Sidecar Core Engineer) is a struct that:
   - Manages the gRPC bidirectional stream to Cortex.
   - Exposes methods: `SendDirectMessage(ctx context.Context, toAgent, content string) error`, `Broadcast(ctx context.Context, content string) error`, `SendPeerRequest(ctx context.Context, agentID, capability, prompt string, timeoutMs int64) (*pb.PeerResponse, error)`, `SendStatusUpdate(ctx context.Context, update *pb.StatusUpdate) error`, `SendTaskResult(ctx context.Context, result *pb.TaskResult) error`, `SendPeerResponse(ctx context.Context, resp *pb.PeerResponse) error`.
   - Returns `ErrNotConnected` when the gRPC stream is not active.
4. Handlers receive dependencies (State, GatewayClient) via a `Server` struct — no globals.
5. The HTTP server is started by `cmd/cortex-sidecar/main.go` (Sidecar Core Engineer wires this).

---

## Data Model (as relevant to this role)

The HTTP API is stateless — it reads from State and writes via GatewayClient. The JSON shapes it serializes:

### Agent (roster entry)
```json
{
  "id": "uuid",
  "name": "security-reviewer",
  "role": "Reviews code for security vulnerabilities",
  "capabilities": ["security-review", "cve-lookup"],
  "status": "idle",
  "metadata": {"model": "opus"}
}
```

### Message
```json
{
  "id": "msg-uuid",
  "from_agent": "agent-uuid",
  "content": "Found 3 issues in auth module",
  "timestamp": "2026-03-18T12:00:00Z"
}
```

### Knowledge Entry
```json
{
  "id": "entry-uuid",
  "topic": "findings",
  "content": "SQL injection in user_controller.ex line 42",
  "source": "security-reviewer",
  "confidence": 0.9,
  "timestamp": "2026-03-18T12:00:00Z"
}
```

### Invocation Result
```json
{
  "status": "completed",
  "result": "Review complete. Found 3 issues...",
  "duration_ms": 12000
}
```

### Error
```json
{
  "error": "agent not found",
  "code": "NOT_FOUND"
}
```

---

## APIs (as relevant to this role)

### `GET /health`
Returns sidecar health status.

**Response 200:**
```json
{
  "status": "healthy",
  "connected": true,
  "agent_id": "uuid",
  "uptime_ms": 45000
}
```

### `GET /roster`
List all registered agents in the mesh.

**Response 200:**
```json
{
  "agents": [
    {"id": "...", "name": "...", "role": "...", "capabilities": [...], "status": "idle", "metadata": {...}}
  ],
  "count": 5,
  "connected": true
}
```

### `GET /roster/{agent_id}`
Get details for a specific agent.

**Response 200:** Single agent object.
**Response 404:** `{"error": "agent not found", "code": "NOT_FOUND"}`

### `GET /roster/capable/{capability}`
Find agents advertising a capability.

**Response 200:**
```json
{
  "agents": [...],
  "count": 2,
  "capability": "security-review"
}
```

### `GET /messages`
Get pending messages for this agent. Calling this endpoint pops messages from the queue.

**Response 200:**
```json
{
  "messages": [...],
  "count": 3
}
```

### `POST /messages/{agent_id}`
Send a message to another agent.

**Request:**
```json
{
  "content": "Please review the auth module"
}
```

**Response 200:** `{"status": "sent"}`
**Response 400:** `{"error": "missing required field: content", "code": "INVALID_REQUEST"}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

### `POST /broadcast`
Broadcast a message to all agents.

**Request:**
```json
{
  "content": "Standup: I found 3 critical issues"
}
```

**Response 200:** `{"status": "broadcast"}`
**Response 400:** `{"error": "missing required field: content", "code": "INVALID_REQUEST"}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

### `POST /ask/{agent_id}`
Synchronous agent-to-agent invocation by ID. Blocks until response or timeout.

**Request:**
```json
{
  "prompt": "Review this code for SQL injection...",
  "timeout_ms": 60000
}
```

**Response 200:**
```json
{
  "status": "completed",
  "result": "Found 2 SQL injection vulnerabilities...",
  "duration_ms": 8500
}
```

**Response 408:** `{"error": "invocation timed out", "code": "TIMEOUT"}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

### `POST /ask/capable/{capability}`
Synchronous invocation by capability (Cortex picks the best agent). Same request/response shape as `POST /ask/{agent_id}`.

### `GET /knowledge` — DEFERRED (Phase 3)
Returns 501 Not Implemented. Knowledge storage and retrieval requires proto messages and a persistence layer that are out of scope for Phase 2.

**Response 501:** `{"error": "knowledge endpoints not yet implemented", "code": "NOT_IMPLEMENTED"}`

### `POST /knowledge` — DEFERRED (Phase 3)
Returns 501 Not Implemented.

**Response 501:** `{"error": "knowledge endpoints not yet implemented", "code": "NOT_IMPLEMENTED"}`

### `POST /status`
Report agent progress to Cortex.

**Request:**
```json
{
  "status": "working",
  "detail": "Analyzing file 3/7",
  "progress": 0.43
}
```

**Response 200:** `{"status": "accepted"}`
**Response 400:** `{"error": "missing required field: status", "code": "INVALID_REQUEST"}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

### `GET /task`
Get current task assignment.

**Response 200:**
```json
{
  "task": {
    "task_id": "task-uuid",
    "prompt": "Review code for security issues...",
    "timeout_ms": 300000,
    "tools": ["read_file", "grep"],
    "context": {}
  }
}
```

**Response 200 (no task):** `{"task": null}`

### `POST /task/result`
Submit task result.

**Request:**
```json
{
  "task_id": "task-uuid",
  "status": "completed",
  "result_text": "Review complete. Found 3 issues...",
  "duration_ms": 12000,
  "input_tokens": 1500,
  "output_tokens": 800
}
```

**Response 200:** `{"status": "accepted"}`
**Response 400:** `{"error": "missing required field: task_id", "code": "INVALID_REQUEST"}`
**Response 400:** `{"error": "no active task", "code": "NO_TASK"}`
**Response 503:** `{"error": "not connected to Cortex", "code": "DISCONNECTED"}`

---

## Architecture / Component Boundaries

```
sidecar/internal/api/
  server.go              # Server struct (holds deps), JSON helpers, middleware
  router.go              # chi.Router setup — mounts all handlers
  health.go              # GET /health
  roster.go              # GET /roster, /roster/{agentID}, /roster/capable/{capability}
  messages.go            # GET /messages, POST /messages/{agentID}, POST /broadcast
  invoke.go              # POST /ask/{agentID}, POST /ask/capable/{capability}
  knowledge.go           # GET /knowledge, POST /knowledge
  status.go              # POST /status, GET /task, POST /task/result

  health_test.go
  roster_test.go
  messages_test.go
  invoke_test.go
  knowledge_test.go
  status_test.go
```

### Server struct

```go
type Server struct {
    state   *state.State
    gateway *gateway.Client
    logger  *slog.Logger
}
```

All handlers are methods on `Server`. This provides dependency injection without globals.

### Router (`router.go`)

- Creates a `chi.NewRouter()`
- Middleware stack: `slog` request logger, JSON content-type response header, recoverer
- Mounts all handler methods on the router
- `NewRouter(s *Server) chi.Router` returns the configured router
- The caller (`main.go`) wraps this in `http.Server{Addr: "127.0.0.1:PORT"}` and calls `ListenAndServe`

### JSON helpers (`server.go`)

- `writeJSON(w http.ResponseWriter, status int, v any)` — marshal and write JSON response
- `writeError(w http.ResponseWriter, status int, message, code string)` — write error in standard format
- `decodeBody(r *http.Request, v any) error` — decode JSON request body with validation
- `requireConnected(w http.ResponseWriter) bool` — check gRPC connection, write 503 if disconnected, return false

### Handler Pattern

Each handler method:
1. Extracts URL params via `chi.URLParam(r, "agentID")`
2. For write operations, calls `requireConnected()` — returns 503 if disconnected
3. Calls State or GatewayClient methods
4. Returns JSON via `writeJSON()` or `writeError()`

### Dependency Direction
```
Router -> Server methods -> state.State   (reads)
                         -> gateway.Client (writes/invocations)
```

Handlers never access the gRPC stream directly. They go through the State and GatewayClient APIs.

---

## Correctness Invariants

1. **Every HTTP response is valid JSON** — even 404s and 500s. The catch-all route and chi's recoverer middleware (wrapped with a JSON error formatter) ensure this.
2. **Write endpoints gate on connection status** — `POST /messages`, `POST /broadcast`, `POST /ask`, `POST /knowledge`, `POST /status`, `POST /task/result` all check `State.IsConnected()` and return 503 if false.
3. **`/ask` timeout is bounded** — `timeout_ms` in the request body is clamped to `[1_000, 300_000]`. If omitted, defaults to 60_000. The handler creates a `context.WithTimeout` and passes it to the GatewayClient.
4. **No state mutation in handlers** — Handlers are pure request/response translators. All state lives in State and GatewayClient.
5. **Request body validation** — POST endpoints validate required fields and return 400 with specific error messages for missing/invalid fields. No silent defaults for required fields.
6. **Thread safety** — Go's HTTP server runs each request in its own goroutine. State is protected by sync.RWMutex. GatewayClient methods are goroutine-safe (they write to a gRPC stream protected by a mutex or use channels).
7. **Localhost binding** — The server binds to `127.0.0.1` only. It never binds to `0.0.0.0`.

---

## Tests

All tests use `net/http/httptest` and table-driven patterns.

### Test Infrastructure

- A `testServer()` helper creates a `Server` with mock State and GatewayClient, returns an `httptest.Server`
- Mock State: a `state.State` instance pre-populated with test data
- Mock GatewayClient: an interface-based mock (or a struct with function fields) that records calls and returns canned responses
- Each test function sets up its own server instance — no shared state between tests

### `health_test.go`
- Returns healthy status with connection info when connected
- Returns `"connected": false` when disconnected
- Includes agent_id and uptime_ms

### `roster_test.go`
- Lists all agents from state
- Returns single agent by ID
- Returns 404 for unknown agent ID
- Filters agents by capability
- Returns empty list when no agents match capability
- Works when disconnected (returns cached data with `"connected": false`)

### `messages_test.go`
- Returns pending messages
- Sends message to agent (connected)
- Returns 503 when disconnected (POST)
- Validates request body (missing content field)
- Broadcast sends successfully
- Broadcast returns 503 when disconnected

### `invoke_test.go`
- Successful synchronous invocation returns result
- Timeout returns 408
- Disconnected returns 503
- Capability-based invocation routes correctly
- Validates request body (missing prompt)
- Timeout clamping: too large clamps to 300000, too small clamps to 1000, omitted defaults to 60000

### `knowledge_test.go`
- GET /knowledge returns 501 Not Implemented
- POST /knowledge returns 501 Not Implemented

### `status_test.go`
- Reports status successfully
- Returns 503 when disconnected
- Returns current task
- Returns null when no task assigned
- Submits task result
- Returns 400 when no active task for task result
- Validates status request body (missing status field)
- Validates task result body (missing task_id)

---

## Benchmarks + "Success"

### Benchmarks

**Tool:** Go's built-in `testing.B` benchmark framework.

**File:** `sidecar/internal/api/bench_test.go`

**Scenarios:**
1. `BenchmarkHealth` — baseline latency, no state reads
2. `BenchmarkRosterList` — state read (RWMutex RLock)
3. `BenchmarkRosterByID` — state read with lookup
4. `BenchmarkSendMessage` — write path with mock gateway client
5. `BenchmarkAskAgent` — blocking invocation with mock instant response (measures overhead)

### Success Criteria
- `GET /health` p99 < 1 ms
- `GET /roster` p99 < 5 ms
- `POST /messages` p99 < 10 ms
- `POST /ask` overhead (minus mock response delay) p99 < 50 ms
- All handler tests pass: `go test ./internal/api/...`
- No lint warnings: `go vet ./...`
- Formatted: `gofmt -l .` produces no output

---

## Engineering Decisions & Tradeoffs

### 1. chi router vs stdlib `http.ServeMux`

**Decision:** Use `chi` (github.com/go-chi/chi).
**Rationale:** chi provides clean URL parameter extraction (`chi.URLParam`), composable middleware, and route grouping — all while remaining stdlib-compatible (`http.Handler`). The stdlib `ServeMux` (even the improved Go 1.22 version) lacks middleware chaining and has less ergonomic param extraction. Since chi is already specified in the tech stack, this is the natural choice.
**Tradeoff:** Adds one external dependency. However, chi is lightweight (~2k LOC), well-maintained, and the team already agreed on it.

### 2. Handler methods on a Server struct vs standalone functions with closures

**Decision:** All handlers are methods on a `Server` struct that holds `state.State` and `gateway.Client`.
**Rationale:** Methods on a struct provide clean dependency injection, are easy to test (construct a Server with mocks), and avoid either globals or deeply nested closures. This follows Go convention for HTTP handlers that need dependencies.
**Tradeoff:** Every handler signature must include the `Server` receiver. This is standard Go — no real downside.

### 3. Blocking `/ask` via `context.WithTimeout` vs async polling

**Decision:** The `/ask` handler creates a `context.WithTimeout`, passes it to `GatewayClient.SendPeerRequest()`, and blocks the goroutine until the response arrives or the context expires.
**Rationale:** The agent calling `/ask` expects a synchronous response — it's being used as a tool. Polling adds complexity for no benefit since the agent can't do other work while waiting. Go's goroutine-per-request model means the blocked goroutine costs ~4KB stack — trivial for a single-agent sidecar.
**Tradeoff:** A blocked `/ask` ties up a goroutine and a gRPC response channel slot. With a single agent, this is fine. The timeout clamp (max 300s) prevents indefinite hangs.

### 4. Connection status gating on write endpoints

**Decision:** All write endpoints (POST) check connection status and return 503 immediately if disconnected. Read endpoints return cached data with `"connected": false`.
**Rationale:** An agent can still read cached roster/messages/task data while disconnected (useful for graceful degradation). But attempting to send messages or invoke agents while disconnected would fail at the gRPC layer, so we fail fast with a clear error.
**Tradeoff:** Some write operations could theoretically be queued for reconnection, but that adds complexity. Fail-fast is simpler and more predictable for a single-agent sidecar.

---

## Risks & Mitigations

### 1. State / GatewayClient API mismatch with Sidecar Core Engineer

**Risk:** The handler code assumes specific method signatures on State and GatewayClient that the Sidecar Core Engineer may implement differently.
**Mitigation:** Define the expected API contract explicitly in this plan (see Assumptions section). Coordinate with Sidecar Core Engineer before implementation to agree on method names, signatures, and return types. Consider defining Go interfaces (`StateReader`, `GatewayWriter`) that both sides agree on — the handlers depend on the interface, the Core Engineer implements it.

### 2. `/ask` endpoint goroutine leak on GatewayClient crash

**Risk:** If the GatewayClient's internal channel is never written to (e.g., the gRPC stream dies mid-request), the `/ask` handler goroutine could block until the context timeout fires.
**Mitigation:** The `context.WithTimeout` ensures the goroutine always unblocks within the clamped timeout (max 300s). The GatewayClient should also select on the context's Done channel so it returns immediately on cancellation. Add a test case for this scenario.

### 3. JSON decode errors leaking internal details

**Risk:** Raw `json.Unmarshal` errors can include Go type names and struct field details in error messages, which leak implementation details.
**Mitigation:** The `decodeBody()` helper catches JSON decode errors and returns a generic "invalid JSON body" message. For missing required fields, return specific messages ("missing required field: topic") without exposing Go internals.

### 4. chi URL param injection / path traversal

**Risk:** URL params like `{agentID}` or `{capability}` could contain unexpected characters.
**Mitigation:** chi handles URL decoding. The params are passed directly to State/GatewayClient lookups which treat them as opaque string keys — no file system access or SQL queries. The risk is minimal, but we should ensure params are non-empty and reject obviously invalid values (empty string).

### 5. Content-Type enforcement on POST endpoints

**Risk:** Agents could send non-JSON bodies (e.g., form-encoded) and get confusing errors from `json.Decode`.
**Mitigation:** Add a middleware (or check in `decodeBody()`) that validates `Content-Type: application/json` on POST requests and returns 415 Unsupported Media Type otherwise.

---

# Recommended API Surface

See the **APIs** section above for the complete specification of all 14 endpoints across 6 handler files.

Summary of files and their handler functions:

| File | Handlers |
|------|----------|
| `server.go` | `Server` struct, `writeJSON`, `writeError`, `decodeBody`, `requireConnected` |
| `router.go` | `NewRouter(s *Server) chi.Router` |
| `health.go` | `(s *Server) handleHealth(w, r)` |
| `roster.go` | `(s *Server) handleRosterList(w, r)`, `handleRosterGet(w, r)`, `handleRosterCapable(w, r)` |
| `messages.go` | `(s *Server) handleGetMessages(w, r)`, `handleSendMessage(w, r)`, `handleBroadcast(w, r)` |
| `invoke.go` | `(s *Server) handleAskAgent(w, r)`, `handleAskCapable(w, r)` |
| `knowledge.go` | `(s *Server) handleQueryKnowledge(w, r)`, `handlePublishKnowledge(w, r)` — **both return 501 (Phase 3 stubs)** |
| `status.go` | `(s *Server) handleReportStatus(w, r)`, `handleGetTask(w, r)`, `handleSubmitTaskResult(w, r)` |

# Folder Structure

```
sidecar/internal/api/
  server.go              # Server struct, JSON helpers, middleware
  router.go              # chi.NewRouter, route mounting
  health.go              # GET /health
  health_test.go
  roster.go              # roster endpoints
  roster_test.go
  messages.go            # messaging endpoints
  messages_test.go
  invoke.go              # /ask endpoints
  invoke_test.go
  knowledge.go           # knowledge endpoints
  knowledge_test.go
  status.go              # status + task endpoints
  status_test.go
  bench_test.go          # benchmarks
```

Ownership: All files above are owned by the Sidecar HTTP API Engineer.

# Step-by-Step Task Plan

See the "Tighten the plan" section below for the strict 4-7 task breakdown.

# Benchmark Plan

**Tool:** Go's built-in `testing.B` framework.

**File:** `sidecar/internal/api/bench_test.go`

**Scenarios:**
1. `BenchmarkHealth` — baseline, no state access
2. `BenchmarkRosterList` — read from State via RWMutex
3. `BenchmarkSendMessage` — write path through mock GatewayClient
4. `BenchmarkAskAgent` — blocking invocation with instant mock response

**Success:**
- Health: < 1 ms/op
- Roster: < 5 ms/op
- SendMessage: < 10 ms/op
- AskAgent overhead: < 50 ms/op (excluding mock delay)

---

# Tighten the plan into 4–7 small tasks (STRICT)

### Task 1: Server struct, JSON helpers, router scaffold, and health handler

**Outcome:** A running HTTP server with chi router, JSON middleware, catch-all 404, and `GET /health` endpoint.

**Files to create/modify:**
- `sidecar/internal/api/server.go`
- `sidecar/internal/api/router.go`
- `sidecar/internal/api/health.go`
- `sidecar/internal/api/health_test.go`

**Exact verification command(s):**
```bash
cd sidecar && go test ./internal/api/ -run TestHealth -v
```

**Suggested commit message:** `feat(sidecar): add chi router scaffold, JSON helpers, and health endpoint`

---

### Task 2: Roster handler

**Outcome:** `GET /roster`, `GET /roster/{agentID}`, `GET /roster/capable/{capability}` return agent data from State.

**Files to create/modify:**
- `sidecar/internal/api/roster.go`
- `sidecar/internal/api/roster_test.go`

**Exact verification command(s):**
```bash
cd sidecar && go test ./internal/api/ -run TestRoster -v
```

**Suggested commit message:** `feat(sidecar): add roster handler for mesh agent discovery`

---

### Task 3: Messages handler

**Outcome:** `GET /messages`, `POST /messages/{agentID}`, `POST /broadcast` work with connection gating and body validation.

**Files to create/modify:**
- `sidecar/internal/api/messages.go`
- `sidecar/internal/api/messages_test.go`

**Exact verification command(s):**
```bash
cd sidecar && go test ./internal/api/ -run TestMessage -v
```

**Suggested commit message:** `feat(sidecar): add messaging handler for agent-to-agent messages`

---

### Task 4: Invoke handler (blocking /ask)

**Outcome:** `POST /ask/{agentID}` and `POST /ask/capable/{capability}` block until response or timeout, with timeout clamping and connection gating.

**Files to create/modify:**
- `sidecar/internal/api/invoke.go`
- `sidecar/internal/api/invoke_test.go`

**Exact verification command(s):**
```bash
cd sidecar && go test ./internal/api/ -run TestAsk -v
```

**Suggested commit message:** `feat(sidecar): add invoke handler for synchronous agent-to-agent calls`

---

### Task 5: Knowledge and status handlers

**Outcome:** `GET /knowledge`, `POST /knowledge`, `POST /status`, `GET /task`, `POST /task/result` all work with validation and connection gating.

**Files to create/modify:**
- `sidecar/internal/api/knowledge.go`
- `sidecar/internal/api/knowledge_test.go`
- `sidecar/internal/api/status.go`
- `sidecar/internal/api/status_test.go`

**Exact verification command(s):**
```bash
cd sidecar && go test ./internal/api/ -run "TestKnowledge|TestStatus|TestTask" -v
```

**Suggested commit message:** `feat(sidecar): add knowledge and status handlers`

---

### Task 6: Benchmarks + full verification

**Outcome:** All benchmarks pass, all tests pass, code is formatted, vet is clean.

**Files to create/modify:**
- `sidecar/internal/api/bench_test.go`

**Exact verification command(s):**
```bash
cd sidecar && go test ./internal/api/... -v && go vet ./internal/api/... && gofmt -l internal/api/
```

**Suggested commit message:** `test(sidecar): add HTTP API benchmarks and verify full suite`

---

# CLAUDE.md contributions (do NOT write the file; propose content)

## From Sidecar HTTP API Engineer

```
## Sidecar HTTP API
- Router: sidecar/internal/api/router.go — chi router mounting all handlers
- Handlers: sidecar/internal/api/*.go — one file per endpoint group (health, roster, messages, invoke, knowledge, status)
- Server struct (server.go) holds State + GatewayClient deps — no globals
- All endpoints return JSON; errors use {"error": "...", "code": "..."} format
- /ask endpoints block via context.WithTimeout until peer response or timeout (max 300s)
- Write endpoints return 503 when gRPC connection is disconnected
- Tests use net/http/httptest with mock State/GatewayClient (table-driven)
- Benchmarks in bench_test.go using testing.B
```

---

# EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

- **Sidecar HTTP API** — the agent-facing interface
  - How the chi router is structured (middleware stack, route mounting)
  - Request lifecycle: HTTP request -> Server method -> State/GatewayClient -> gRPC stream -> Cortex
  - Blocking invocation model: how `/ask` uses `context.WithTimeout` and channel-based response waiting
  - Error handling: uniform JSON errors, connection gating on writes, Content-Type enforcement
  - Why chi over stdlib ServeMux (URL params, middleware, team convention)
  - Testing strategy: httptest.Server, mock deps via interfaces, table-driven tests

---

## READY FOR APPROVAL
