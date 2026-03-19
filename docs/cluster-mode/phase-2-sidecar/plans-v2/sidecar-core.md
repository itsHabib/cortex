# Sidecar Core Engineer Plan

## You are in PLAN MODE.

### Project
I want to build the **Sidecar Core** for Cortex Cluster Mode Phase 2 (gRPC + Go).

**Goal:** build the **Go sidecar binary's core infrastructure** — CLI entrypoint, configuration from environment variables, gRPC client connection to the Cortex gateway via bidirectional streaming, thread-safe state management, and stream-level auto-reconnect — so that a sidecar process can start alongside an agent, connect to Cortex over gRPC, register itself, send heartbeats, receive tasks and peer requests, and maintain resilient connectivity.

### Role + Scope
- **Role:** Sidecar Core Engineer
- **Scope:** I own the Go sidecar's CLI entrypoint (`cmd/cortex-sidecar/main.go`), configuration (`internal/config/`), gRPC gateway client (`internal/gateway/`), state store (`internal/state/`), Dockerfile, and Makefile. I do NOT own the local HTTP API (Sidecar HTTP API Engineer), the protobuf definitions (Proto & Codegen Engineer), the Elixir gRPC server (Gateway gRPC Engineer), or integration tests across sidecar + gateway (Integration Test Engineer).
- **File I will write:** `docs/cluster-mode/phase-2-sidecar/plans-v2/sidecar-core.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

- **FR1: Configuration** — A `config.Config` struct with `envconfig` tags reads environment variables (`CORTEX_GATEWAY_URL`, `CORTEX_AGENT_NAME`, `CORTEX_AGENT_ROLE`, `CORTEX_AGENT_CAPABILITIES`, `CORTEX_AUTH_TOKEN`, `CORTEX_SIDECAR_PORT`, `CORTEX_HEARTBEAT_INTERVAL`), applies defaults, and validates required fields via a `Validate()` method. Returns a typed, validated config or descriptive errors.

- **FR2: CLI Entrypoint** — A `cobra` root command in `cmd/cortex-sidecar/main.go` that:
  - Reads config via `envconfig`
  - Establishes a gRPC connection to the gateway
  - Starts the gateway client (bidirectional stream)
  - Starts the HTTP server (placeholder, owned by HTTP API Engineer)
  - Uses `signal.NotifyContext` for graceful shutdown on SIGINT/SIGTERM
  - Supports `--version` flag

- **FR3: gRPC Gateway Client** — A `gateway.Client` struct that:
  - Establishes a gRPC connection using `grpc.WithConnectParams` for built-in connection-level reconnection (do NOT reimplement backoff for the TCP/HTTP2 layer)
  - Opens a bidirectional `Connect` stream
  - Sends a `RegisterRequest` on stream open (name, role, capabilities, auth token)
  - Sends periodic `Heartbeat` messages via `time.Ticker` at the configured interval
  - Receives and dispatches `GatewayMessage` variants (`TaskRequest`, `PeerRequest`, `RosterUpdate`, `Error`) to the state store
  - Handles stream-level errors: re-opens the stream and re-sends `RegisterRequest` (the gRPC connection itself reconnects automatically)
  - Exposes methods for sending `TaskResult`, `StatusUpdate`, `PeerResponse` on the stream
  - All operations respect context cancellation for graceful shutdown

- **FR4: State Store** — A `state.Store` struct with `sync.RWMutex` that provides thread-safe access to:
  - Agent ID (assigned by gateway on registration)
  - Connection status (`connecting`, `connected`, `disconnected`, `reconnecting`)
  - Cached roster (list of `AgentInfo` from `RosterUpdate`)
  - Pending inbound messages (task requests, peer requests) as a queue
  - Current task assignment
  - Methods: `GetAgentID`, `SetAgentID`, `GetStatus`, `SetStatus`, `GetRoster`, `SetRoster`, `PushMessage`, `PopMessages`, `GetTask`, `SetTask`, `GetConnectionInfo`

- **FR5: Dockerfile** — Multi-stage build: Go build stage compiles the binary, final stage uses `gcr.io/distroless/static-debian12` for a minimal runtime image.

- **FR6: Makefile** — Targets for `build`, `test`, `lint`, `docker-build`, `clean`.

## Non-Functional Requirements

- **Language/runtime:** Go 1.22+. The sidecar is a standalone binary.
- **Dependencies:** `google.golang.org/grpc`, `github.com/spf13/cobra`, `github.com/kelseyhightower/envconfig`. No other third-party deps in the core (HTTP router is the HTTP API Engineer's concern).
- **Logging:** All logging via `slog` (stdlib). Structured JSON output in production, text in development. Log connection events (connect, disconnect, reconnect, registration success/failure), heartbeat sends, and message dispatch.
- **Safety:** The sidecar must never crash due to gateway unavailability. Stream errors are logged and trigger re-establishment. Invalid messages from the gateway are logged and discarded. Context cancellation propagates cleanly.
- **Testing:** Table-driven unit tests. No global state — all structs accept dependencies via constructor injection.
- **Build:** Single static binary via `CGO_ENABLED=0 go build`. Docker image under 20MB.
- **Performance:** Lightweight — one gRPC connection, one bidirectional stream, one goroutine for receiving. No performance concerns at this scale.

---

## Assumptions / System Model

- **Deployment:** The sidecar runs as a separate process alongside an agent in the same container or machine. In dev, run directly via `go run` or the compiled binary. In production, via Docker or direct binary deployment.
- **Proto contract:** Generated Go code will exist at `sidecar/internal/proto/gatewayv1/` (owned by Proto & Codegen Engineer). The client imports this package for message types and the gRPC service stub. Plan assumes the proto definitions from `kickoff-v2-grpc.yaml` are implemented as-is.
- **Failure modes:**
  - **Gateway unreachable on startup:** gRPC connection enters TRANSIENT_FAILURE state; built-in reconnect with backoff handles this. The client logs and waits. The sidecar starts, HTTP API returns degraded status.
  - **Gateway disconnects mid-session:** The bidirectional stream returns an error. The client re-opens the stream and re-sends `RegisterRequest`. The underlying gRPC connection reconnects automatically.
  - **Invalid gateway messages:** `oneof` field is unset or unknown — logged and skipped. Stream stays open.
  - **State store access during reconnect:** Reads return stale data (cached roster, old agent ID). Writes from the new stream replace stale data atomically.
- **Delivery guarantees:** At-most-once for stream messages. No persistence or retry for outbound messages. If a heartbeat or task result is lost due to stream break, it is re-sent after stream re-establishment only if still relevant.
- **Agent ID changes on reconnect:** On stream re-establishment, a new `RegisterRequest` is sent and a new `agent_id` is received. The old ID is overwritten in the state store.

---

## Data Model (as relevant to this role)

### config.Config

```go
type Config struct {
    GatewayURL        string        `envconfig:"CORTEX_GATEWAY_URL" required:"true"`
    AgentName         string        `envconfig:"CORTEX_AGENT_NAME" required:"true"`
    AgentRole         string        `envconfig:"CORTEX_AGENT_ROLE" default:"agent"`
    AgentCapabilities []string      `envconfig:"CORTEX_AGENT_CAPABILITIES"`
    AuthToken         string        `envconfig:"CORTEX_AUTH_TOKEN"`
    SidecarPort       int           `envconfig:"CORTEX_SIDECAR_PORT" default:"9090"`
    HeartbeatInterval time.Duration `envconfig:"CORTEX_HEARTBEAT_INTERVAL" default:"15s"`
}
```

**Validation rules (in `Validate()`):**
- `GatewayURL` must be non-empty (format validated by gRPC dial)
- `AgentName` must be non-empty, match `^[a-zA-Z0-9_-]+$`
- `AgentCapabilities` parsed from comma-separated env var by `envconfig`
- `SidecarPort` must be between 1024 and 65535
- `HeartbeatInterval` must be >= 1s

### state.Store

```go
type Store struct {
    mu              sync.RWMutex
    agentID         string
    status          ConnectionStatus  // connecting | connected | disconnected | reconnecting
    roster          []*pb.AgentInfo
    pendingMessages []Message         // wrapper for TaskRequest | PeerRequest | DirectMessage
    currentTask     *pb.TaskRequest
    startedAt       time.Time         // set on creation, used for GetUptime()
}

type ConnectionStatus string

const (
    StatusConnecting   ConnectionStatus = "connecting"
    StatusConnected    ConnectionStatus = "connected"
    StatusDisconnected ConnectionStatus = "disconnected"
    StatusReconnecting ConnectionStatus = "reconnecting"
)

type Message struct {
    Type      string          // "task_request" | "peer_request" | "direct_message"
    TaskReq   *pb.TaskRequest
    PeerReq   *pb.PeerRequest
    DirectMsg *pb.DirectMessage
    Received  time.Time
}
```

### gateway.Client

```go
type Client struct {
    cfg     *config.Config
    conn    *grpc.ClientConn
    state   *state.Store
    logger  *slog.Logger
    stream  pb.AgentGateway_ConnectClient  // bidirectional stream
    sendMu  sync.Mutex                     // serialize writes to stream
}
```

**Stream lifecycle:**
1. `grpc.NewClient` with `grpc.WithConnectParams` (sets initial backoff, multiplier, max backoff)
2. `pb.NewAgentGatewayClient(conn).Connect(ctx)` to open the bidirectional stream
3. Send `RegisterRequest` on the stream
4. Start receive goroutine: loops on `stream.Recv()`, dispatches to state store
5. Start heartbeat ticker: sends `Heartbeat` at configured interval
6. On `stream.Recv()` error (EOF, Unavailable, etc.): cancel receive goroutine, wait, re-open stream from step 2
7. On context cancellation (shutdown): close stream, close connection

---

## APIs (as relevant to this role)

### config.Config — Public API

| Function | Signature | Description |
|----------|-----------|-------------|
| `Load` | `func Load() (*Config, error)` | Read env vars via envconfig, validate, return config |
| `Validate` | `func (c *Config) Validate() error` | Validate all fields, return descriptive error |

### gateway.Client — Public API

| Function | Signature | Description |
|----------|-----------|-------------|
| `New` | `func New(cfg *config.Config, store *state.Store, logger *slog.Logger) *Client` | Create a new client (does not connect) |
| `Run` | `func (c *Client) Run(ctx context.Context) error` | Connect, register, start heartbeat + receive loop. Blocks until ctx cancelled. Handles stream reconnect internally. |
| `SendTaskResult` | `func (c *Client) SendTaskResult(ctx context.Context, result *pb.TaskResult) error` | Send task result on the stream |
| `SendStatusUpdate` | `func (c *Client) SendStatusUpdate(ctx context.Context, update *pb.StatusUpdate) error` | Send status update on the stream |
| `SendPeerResponse` | `func (c *Client) SendPeerResponse(ctx context.Context, resp *pb.PeerResponse) error` | Send peer response on the stream |
| `SendPeerRequest` | `func (c *Client) SendPeerRequest(ctx context.Context, agentID, capability, prompt string, timeoutMs int64) (*pb.PeerResponse, error)` | Send peer request, block until response or timeout. Registers a pending request channel, sends on stream, waits. |
| `SendDirectMessage` | `func (c *Client) SendDirectMessage(ctx context.Context, toAgent, content string) error` | Send a direct message to another agent via the stream |
| `Broadcast` | `func (c *Client) Broadcast(ctx context.Context, content string) error` | Broadcast a message to all agents via the stream |

### state.Store — Public API

| Function | Signature | Description |
|----------|-----------|-------------|
| `New` | `func New() *Store` | Create new store with defaults |
| `GetAgentID` | `func (s *Store) GetAgentID() string` | Return assigned agent ID |
| `SetAgentID` | `func (s *Store) SetAgentID(id string)` | Store agent ID |
| `GetStatus` | `func (s *Store) GetStatus() ConnectionStatus` | Return connection status |
| `SetStatus` | `func (s *Store) SetStatus(status ConnectionStatus)` | Update connection status |
| `GetRoster` | `func (s *Store) GetRoster() []*pb.AgentInfo` | Return copy of cached roster |
| `SetRoster` | `func (s *Store) SetRoster(agents []*pb.AgentInfo)` | Replace cached roster |
| `PushMessage` | `func (s *Store) PushMessage(msg Message)` | Enqueue inbound message |
| `PopMessages` | `func (s *Store) PopMessages() []Message` | Dequeue all pending messages |
| `GetTask` | `func (s *Store) GetTask() *pb.TaskRequest` | Return current task |
| `SetTask` | `func (s *Store) SetTask(task *pb.TaskRequest)` | Set or clear current task |
| `GetConnectionInfo` | `func (s *Store) GetConnectionInfo() ConnectionInfo` | Return snapshot: agent ID, status, peer count |
| `GetAgent` | `func (s *Store) GetAgent(id string) (*pb.AgentInfo, bool)` | Look up a specific agent by ID from cached roster |
| `GetCapable` | `func (s *Store) GetCapable(capability string) []*pb.AgentInfo` | Filter cached roster by capability |
| `IsConnected` | `func (s *Store) IsConnected() bool` | Shorthand for `GetStatus() == StatusConnected` |
| `GetUptime` | `func (s *Store) GetUptime() time.Duration` | Return `time.Since(startedAt)` |

### Error Semantics

- `config.Load()` returns a single error wrapping all validation failures (using `errors.Join` or `fmt.Errorf` with context).
- `gateway.Client.SendTaskResult/SendStatusUpdate/SendPeerResponse/SendDirectMessage/Broadcast` return `ErrNotConnected` if the stream is not active.
- `gateway.Client.SendPeerRequest` returns `ErrNotConnected` if disconnected, or `context.DeadlineExceeded` if the peer doesn't respond in time. Internally it registers a response channel keyed by `request_id`, sends the request on the stream, and blocks on the channel.
- `state.Store` methods never return errors — they operate on in-memory state with mutex protection.

---

## Architecture / Component Boundaries

### Components I Own

1. **`cmd/cortex-sidecar/main.go`** — CLI Entrypoint
   - Cobra root command with `--version` flag
   - Loads config via `config.Load()`; exits with descriptive error if invalid
   - Creates `state.Store`
   - Creates `gateway.Client` with config, store, logger
   - Starts `Client.Run()` in a goroutine
   - Starts HTTP server (placeholder — HTTP API Engineer fills in)
   - `signal.NotifyContext` for SIGINT/SIGTERM → cancels context → clean shutdown
   - Blocks on context Done, then waits for goroutines to finish

2. **`internal/config/config.go`** — Configuration
   - Pure data + validation, no goroutines
   - Uses `envconfig.Process("cortex", &cfg)` for declarative parsing
   - `CORTEX_AGENT_CAPABILITIES` is comma-separated; `envconfig` handles `[]string` natively
   - `Validate()` checks semantic rules beyond what envconfig tags express

3. **`internal/gateway/client.go`** — gRPC Gateway Client
   - `Run(ctx)` is the main loop:
     ```
     dial gRPC connection (with ConnectParams for auto-reconnect)
     loop:
       open Connect stream
       send RegisterRequest
       start heartbeat ticker
       start receive loop (goroutine)
       wait for stream error or ctx cancel
       if ctx cancel: return
       log error, update state to "reconnecting"
       wait brief pause (1-2s, just to avoid tight loop on instant failures)
       continue loop (re-open stream on same connection)
     ```
   - The gRPC connection itself handles TCP/HTTP2 reconnect. We only handle stream re-establishment.
   - `sendMu` mutex serializes all `stream.Send()` calls (gRPC streams are not safe for concurrent sends)
   - Heartbeat ticker runs in the receive goroutine; on tick, sends `Heartbeat` with current status from state store

4. **`internal/state/state.go`** — State Store
   - Thread-safe via `sync.RWMutex`
   - Read methods use `RLock`, write methods use `Lock`
   - `PopMessages` atomically drains and returns the queue
   - `GetRoster` returns a shallow copy of the slice (prevents data races on the slice header)
   - No business logic — pure data store for client and HTTP API to coordinate through

5. **`sidecar/Dockerfile`** — Multi-stage build
   - Stage 1: `golang:1.22-alpine`, copy source, `go build -o /cortex-sidecar ./cmd/cortex-sidecar`
   - Stage 2: `gcr.io/distroless/static-debian12`, copy binary, set entrypoint

6. **`sidecar/Makefile`** — Build automation
   - `build`: `CGO_ENABLED=0 go build -o bin/cortex-sidecar ./cmd/cortex-sidecar`
   - `test`: `go test ./...`
   - `lint`: `go vet ./...` (+ `golangci-lint run` if available)
   - `docker-build`: `docker build -t cortex-sidecar .`
   - `clean`: `rm -rf bin/`

### Components I Import (owned by other teammates)

- `sidecar/internal/proto/gatewayv1/` — Generated protobuf Go code (Proto & Codegen Engineer). Provides `AgentGatewayClient`, `AgentMessage`, `GatewayMessage`, and all message types.

### Components That Import Me (owned by other teammates)

- HTTP API handlers (Sidecar HTTP API Engineer) — import `state.Store` for reading roster/messages/task, import `gateway.Client` for sending task results and status updates.

### Concurrency Model

- **Main goroutine:** runs cobra command, sets up components, blocks on signal
- **Client.Run goroutine:** manages the stream lifecycle loop
- **Receive goroutine (inside Run):** loops on `stream.Recv()`, dispatches to state store, also handles heartbeat ticker via `select`
- **HTTP server goroutines (not mine):** call state.Store read methods and gateway.Client send methods
- **Synchronization:** `state.Store` uses `sync.RWMutex`; `gateway.Client` uses `sendMu` for stream writes; all cross-goroutine communication is through the state store or context cancellation

### Stream Reconnect Strategy

The gRPC library handles connection-level reconnect (TCP/HTTP2). We only handle stream re-establishment:

1. `stream.Recv()` returns an error (EOF, Unavailable, etc.)
2. Log the error, set state to `reconnecting`
3. Cancel the heartbeat ticker
4. Wait 2 seconds (avoid tight loop on immediate stream failures)
5. Re-open `Connect` stream on the same `grpc.ClientConn`
6. Re-send `RegisterRequest` (new agent ID will be assigned)
7. Restart heartbeat ticker and receive loop
8. On success, set state to `connected`

This is intentionally simple — no exponential backoff for stream re-establishment because the gRPC connection layer already handles backoff for the underlying transport.

---

## Correctness Invariants

1. **Config validation is strict and fail-fast:** The sidecar binary exits immediately with a descriptive error if any required config field is missing or invalid. No partial startup.
2. **Connection status is always accurate:** `state.Status` always reflects the true state of the gRPC stream. The client updates state on every transition (connecting -> connected, connected -> reconnecting, etc.).
3. **Registration happens exactly once per stream:** On each new `Connect` stream, the client sends exactly one `RegisterRequest`. On stream re-establishment, it re-registers (getting a new `agent_id`).
4. **Heartbeats only when connected:** The heartbeat ticker fires periodically, but heartbeat messages are only sent if the stream is active. Ticker is cancelled on stream error and restarted on stream re-establishment.
5. **Stream sends are serialized:** All `stream.Send()` calls go through `sendMu` to prevent concurrent writes (which gRPC streams do not support).
6. **No crash on gateway failure:** Network errors, stream breaks, and unexpected messages are all handled gracefully. The sidecar logs and continues.
7. **Context cancellation propagates cleanly:** When the root context is cancelled (SIGINT/SIGTERM), the stream receive loop exits, the heartbeat ticker stops, `stream.CloseSend()` is called, and the gRPC connection closes.
8. **State store is thread-safe:** All reads use `RLock`, all writes use `Lock`. `PopMessages` atomically drains the queue. `GetRoster` returns a copy.

---

## Tests

### `internal/config/config_test.go` — Table-driven

1. **Valid config:** All required env vars set -> no error, correct field values
2. **Default values:** `CORTEX_SIDECAR_PORT` and `CORTEX_HEARTBEAT_INTERVAL` unset -> defaults to 9090 and 15s
3. **Missing required fields:** GatewayURL missing -> descriptive error; AgentName missing -> descriptive error
4. **Invalid agent name:** Name with spaces or special chars -> validation error
5. **Invalid port:** Port = 80 (below 1024) or 99999 (above 65535) -> validation error
6. **Capabilities parsing:** `"a,b,c"` -> `["a", "b", "c"]`; `"single"` -> `["single"]`
7. **HeartbeatInterval too low:** `500ms` -> validation error (must be >= 1s)

### `internal/state/state_test.go` — Table-driven

1. **Initial state:** New store has empty agent ID, status `connecting`, empty roster, no messages, nil task
2. **Agent ID:** SetAgentID then GetAgentID returns the ID
3. **Connection status:** SetStatus then GetStatus returns the status
4. **Roster:** SetRoster then GetRoster returns the roster; GetRoster returns a copy (modifying returned slice doesn't affect store)
5. **Messages:** PushMessage three times, PopMessages returns all three in order and clears the queue; subsequent PopMessages returns empty
6. **Current task:** SetTask then GetTask; SetTask(nil) clears it
7. **ConnectionInfo snapshot:** GetConnectionInfo returns correct agent ID, status, and peer count
8. **Concurrent access:** Multiple goroutines reading and writing simultaneously without data races (run with `-race` flag)

### `internal/gateway/client_test.go`

Testing the gRPC client requires a mock gRPC server. Strategy: use `google.golang.org/grpc/test/bufconn` to create an in-memory gRPC server that implements the `AgentGateway` service.

1. **Registration on connect:** Client connects, server receives `RegisterRequest` with correct fields (name, role, capabilities, auth token)
2. **Registration response:** Server sends `RegisterResponse`, client stores agent ID in state, status becomes `connected`
3. **Heartbeat sending:** Client sends `Heartbeat` messages at the configured interval (use short interval like 100ms in tests)
4. **TaskRequest dispatch:** Server sends `TaskRequest`, client pushes it to state store pending messages
5. **PeerRequest dispatch:** Server sends `PeerRequest`, client pushes it to state store pending messages
6. **RosterUpdate dispatch:** Server sends `RosterUpdate`, client updates state store roster
7. **Error message handling:** Server sends `Error`, client logs it (does not crash or disconnect)
8. **SendTaskResult:** Call `SendTaskResult`, server receives the `TaskResult` message
9. **SendStatusUpdate:** Call `SendStatusUpdate`, server receives the `StatusUpdate` message
10. **SendPeerResponse:** Call `SendPeerResponse`, server receives the `PeerResponse` message
11. **Stream reconnect:** Server closes the stream, client re-opens a new stream and re-sends `RegisterRequest`
12. **Graceful shutdown:** Cancel context, client stops cleanly without hanging or panicking
13. **Send when disconnected:** `SendTaskResult` returns `ErrNotConnected` when stream is not active

### Test Commands

```bash
cd sidecar && go test ./internal/config/ -v
cd sidecar && go test ./internal/state/ -v -race
cd sidecar && go test ./internal/gateway/ -v -race
cd sidecar && go test ./... -v -race
```

---

## Benchmarks + "Success"

N/A for explicit benchmarks. The sidecar core is a lightweight process with one gRPC connection, one bidirectional stream, and a mutex-protected state store. There is no algorithmic complexity or throughput concern worth benchmarking at this stage.

**Success criteria for this role:**
- All tests pass (`go test ./... -race` with zero failures)
- The sidecar binary starts, reads config from env, dials the gRPC gateway, registers, and exchanges heartbeats
- When the gRPC stream breaks, the sidecar re-opens the stream and re-registers
- The state store correctly stores and serves agent ID, roster, pending messages, connection status, and current task
- The gateway client never panics from network errors or unexpected messages
- `go vet ./...` reports no issues
- Docker image builds successfully and is under 20MB
- The binary compiles as a static binary (`CGO_ENABLED=0`)

---

## Engineering Decisions & Tradeoffs

### Decision 1: gRPC built-in reconnect + manual stream re-establishment vs full manual reconnect

- **Decision:** Use `grpc.WithConnectParams` for connection-level reconnect (TCP/HTTP2 backoff handled by the gRPC library). Only manually re-establish the bidirectional `Connect` stream when it breaks.
- **Alternatives considered:**
  - Full manual reconnect: close `grpc.ClientConn`, re-dial with custom exponential backoff. This duplicates logic the gRPC library already provides.
  - No stream re-establishment: rely on gRPC to reconnect everything. gRPC reconnects the transport but does NOT re-open application-level streams — streams are bound to a specific transport session.
- **Why:** The gRPC library's built-in backoff (`grpc.ConnectParams` with `backoff.Config`) is battle-tested and handles jitter, max delay, and multiplier correctly. Reimplementing this is error-prone. However, bidirectional streams are tied to a transport session — when the transport reconnects, existing streams are dead. We must re-open the stream and re-send `RegisterRequest`.
- **Tradeoff:** We have two layers of reconnection (transport + stream), which could confuse maintainers. Mitigated by clear comments and logging that distinguish "connection lost → gRPC reconnecting transport" from "stream broken → re-opening stream."

### Decision 2: `sync.RWMutex` state store vs channels

- **Decision:** Use `sync.RWMutex` for the state store instead of a channel-based actor pattern.
- **Alternatives considered:**
  - Channel-based state manager (goroutine + channel, similar to a GenServer): more "Go idiomatic" for some definitions, but adds complexity for what is essentially a shared map.
  - `sync.Map`: not suitable because we need consistent multi-field reads (e.g., agent ID + status together).
- **Why:** The state store is a simple key-value store with low contention. `RWMutex` allows concurrent reads (from multiple HTTP handlers) while serializing writes (from the single gRPC receive goroutine). A channel-based approach would force all reads through a single goroutine bottleneck, adding latency for HTTP handlers that just need to read the roster.
- **Tradeoff:** Mutex-based code is harder to reason about for correctness than message-passing. Mitigated by keeping the critical sections very small (get/set single fields) and running all tests with `-race`.

### Decision 3: Simple 2-second pause on stream re-establishment vs exponential backoff

- **Decision:** Use a fixed 2-second pause between stream re-establishment attempts rather than exponential backoff.
- **Alternatives considered:** Exponential backoff with jitter for stream re-establishment.
- **Why:** The gRPC connection layer already handles exponential backoff for the transport. If the transport is down, `Connect()` will block until the connection is ready (gRPC's `WaitForReady` behavior). The 2-second pause only protects against the edge case where the transport is up but the server immediately closes the stream (e.g., auth failure, server bug). Full exponential backoff at the stream level would be redundant with the transport-level backoff and add complexity.
- **Tradeoff:** If the server has a persistent stream-level bug (accepts connection, immediately closes stream), we'll retry every 2 seconds indefinitely. Acceptable for MVP — server bugs are fixed on the server side. Could add a max retry count or backoff later if needed.

### Decision 4: `sendMu` mutex for stream writes vs channel-based send queue

- **Decision:** Use a `sync.Mutex` (`sendMu`) to serialize `stream.Send()` calls from multiple goroutines (heartbeat goroutine, HTTP handler goroutines calling `SendTaskResult`, etc.).
- **Alternatives considered:** A channel-based send queue where a dedicated goroutine reads from a channel and calls `stream.Send()`.
- **Why:** `stream.Send()` is not safe for concurrent use. A mutex is the simplest solution — wrap each `Send` call in `sendMu.Lock()/Unlock()`. A channel-based queue adds a goroutine, a channel, and buffer-size decisions. The write rate is very low (heartbeats every 15s, occasional task results), so contention is negligible.
- **Tradeoff:** If `stream.Send()` blocks (backpressure from the server), it holds the mutex and blocks other senders. At the low write rates of a sidecar, this is not a practical concern.

---

## Risks & Mitigations

### Risk 1: Generated proto code not available when starting implementation

- **Risk:** The Proto & Codegen Engineer may not have generated Go code in `sidecar/internal/proto/gatewayv1/` yet. The gateway client imports these types.
- **Impact:** `client.go` will not compile without the generated types.
- **Mitigation:** Coordinate with Proto & Codegen Engineer — either wait for their proto generation to land first, or define a minimal interface (`StreamClient`) that wraps the generated gRPC client. The interface can be satisfied by the real generated client or a test mock. In practice, the generated code is straightforward from the proto in the kickoff — worst case, generate it manually with `protoc`.
- **Validation:** `go build ./...` succeeds after proto code is in place.

### Risk 2: `bufconn` test complexity for bidirectional streaming

- **Risk:** Testing bidirectional streaming with `bufconn` requires implementing a mock gRPC server that correctly handles concurrent `Send` and `Recv` on the server-side stream. This is more complex than testing unary RPCs.
- **Impact:** Tests may be flaky if the mock server has concurrency bugs, or test implementation may take longer than expected.
- **Mitigation:** Keep the mock server simple — one goroutine for receiving, one for sending. Use channels for test coordination (e.g., "server received RegisterRequest, now send RegisterResponse"). Reference the `grpc-go` library's own bidirectional streaming tests as implementation examples.
- **Validation:** `go test ./internal/gateway/ -race -count=10` passes without flakes.

### Risk 3: Stream re-establishment tight loop on persistent server-side errors

- **Risk:** If the gRPC server persistently rejects streams (e.g., invalid auth, server bug), the client enters a tight re-establishment loop (open stream -> immediately rejected -> 2s pause -> repeat).
- **Impact:** Log spam, unnecessary load on the server, and the sidecar never becomes functional.
- **Mitigation:** Log each re-establishment attempt with a counter. After N consecutive failures (e.g., 10), increase the pause to 30s and log a warning recommending config/server check. This provides backoff without reimplementing exponential backoff (which the transport layer already handles).
- **Validation:** Test with a mock server that immediately closes streams and verify the log output and retry cadence.

### Risk 4: `envconfig` capabilities parsing edge cases

- **Risk:** `envconfig` handles `[]string` by splitting on commas, but edge cases like spaces around commas (`"a, b, c"`), trailing commas (`"a,b,"`), or empty string (`""`) may produce unexpected results.
- **Impact:** Agent registers with incorrect or empty capabilities.
- **Mitigation:** Post-process capabilities in `Validate()`: trim whitespace from each element, filter empty strings. Add explicit test cases for these edge cases.
- **Validation:** `go test ./internal/config/ -v` with edge case table entries.

### Risk 5: Graceful shutdown ordering

- **Risk:** On SIGINT, the context is cancelled. If the HTTP server shuts down before the gRPC client sends a final `StatusUpdate("draining")`, the agent's last status is not reflected in the gateway.
- **Impact:** The gateway shows the agent as still "connected" until the heartbeat timeout expires.
- **Mitigation:** Shutdown order in `main.go`: (1) stop accepting new HTTP requests, (2) send a final `StatusUpdate` with status "draining" via the gRPC client, (3) close the gRPC stream with `CloseSend()`, (4) close the gRPC connection. Use a short timeout (5s) for the entire shutdown sequence.
- **Validation:** Test graceful shutdown by cancelling context and verifying the mock server receives the draining status update.

---

## Recommended API Surface

### config package

```go
func Load() (*Config, error)
func (c *Config) Validate() error
```

### gateway package

```go
func New(cfg *config.Config, store *state.Store, logger *slog.Logger) *Client
func (c *Client) Run(ctx context.Context) error
func (c *Client) SendTaskResult(ctx context.Context, result *pb.TaskResult) error
func (c *Client) SendStatusUpdate(ctx context.Context, update *pb.StatusUpdate) error
func (c *Client) SendPeerResponse(ctx context.Context, resp *pb.PeerResponse) error
func (c *Client) SendPeerRequest(ctx context.Context, agentID, capability, prompt string, timeoutMs int64) (*pb.PeerResponse, error)
func (c *Client) SendDirectMessage(ctx context.Context, toAgent, content string) error
func (c *Client) Broadcast(ctx context.Context, content string) error

var ErrNotConnected = errors.New("gateway: stream not connected")
```

### state package

```go
func New() *Store
func (s *Store) GetAgentID() string
func (s *Store) SetAgentID(id string)
func (s *Store) GetStatus() ConnectionStatus
func (s *Store) SetStatus(status ConnectionStatus)
func (s *Store) GetRoster() []*pb.AgentInfo
func (s *Store) SetRoster(agents []*pb.AgentInfo)
func (s *Store) GetAgent(id string) (*pb.AgentInfo, bool)
func (s *Store) GetCapable(capability string) []*pb.AgentInfo
func (s *Store) IsConnected() bool
func (s *Store) GetUptime() time.Duration
func (s *Store) PushMessage(msg Message)
func (s *Store) PopMessages() []Message
func (s *Store) GetTask() *pb.TaskRequest
func (s *Store) SetTask(task *pb.TaskRequest)
func (s *Store) GetConnectionInfo() ConnectionInfo

type ConnectionStatus string
type ConnectionInfo struct { ... }
type Message struct { ... }
```

---

## Folder Structure

```
sidecar/
  go.mod
  go.sum
  Dockerfile
  Makefile
  cmd/
    cortex-sidecar/
      main.go                          # Cobra CLI entrypoint (Sidecar Core Engineer)
  internal/
    config/
      config.go                        # Config struct + Load + Validate (Sidecar Core Engineer)
      config_test.go                   # Config tests (Sidecar Core Engineer)
    gateway/
      client.go                        # gRPC client + stream lifecycle (Sidecar Core Engineer)
      client_test.go                   # Client tests with bufconn (Sidecar Core Engineer)
    state/
      state.go                         # Thread-safe state store (Sidecar Core Engineer)
      state_test.go                    # State tests (Sidecar Core Engineer)
    proto/
      gatewayv1/                       # Generated proto code (Proto & Codegen Engineer — NOT mine)
        gateway.pb.go
        gateway_grpc.pb.go
    api/                               # HTTP API handlers (Sidecar HTTP API Engineer — NOT mine)
      router.go
      ...
```

---

## Tighten the plan into 4-7 small tasks

### Task 1: Go module, config, and Makefile

- **Outcome:** `sidecar/` Go module initialized with `go.mod`. `config.Config` struct reads env vars via `envconfig`, validates with `Validate()`, returns typed config or descriptive errors. `Makefile` with build/test/lint/clean targets.
- **Files to create:** `sidecar/go.mod`, `sidecar/internal/config/config.go`, `sidecar/internal/config/config_test.go`, `sidecar/Makefile`
- **Verification:**
  ```bash
  cd sidecar && go test ./internal/config/ -v
  cd sidecar && go vet ./internal/config/
  ```
- **Suggested commit message:** `feat(sidecar): add Go module, config package with envconfig parsing, and Makefile`

### Task 2: Thread-safe state store

- **Outcome:** `state.Store` with `sync.RWMutex` providing thread-safe access to agent ID, connection status, roster, pending messages, and current task. All methods tested, including concurrent access with `-race`.
- **Files to create:** `sidecar/internal/state/state.go`, `sidecar/internal/state/state_test.go`
- **Verification:**
  ```bash
  cd sidecar && go test ./internal/state/ -v -race
  ```
- **Suggested commit message:** `feat(sidecar): add thread-safe state store with mutex-protected accessors`

### Task 3: gRPC gateway client with stream lifecycle

- **Outcome:** `gateway.Client` dials gRPC with `ConnectParams`, opens bidirectional `Connect` stream, sends `RegisterRequest`, dispatches inbound `GatewayMessage` variants to state store, sends periodic heartbeats, and re-establishes the stream on errors. Exposes `SendTaskResult`, `SendStatusUpdate`, `SendPeerResponse`. Tested with `bufconn` mock server.
- **Files to create:** `sidecar/internal/gateway/client.go`, `sidecar/internal/gateway/client_test.go`
- **Verification:**
  ```bash
  cd sidecar && go test ./internal/gateway/ -v -race
  ```
- **Suggested commit message:** `feat(sidecar): add gRPC gateway client with bidirectional streaming and auto-reconnect`

### Task 4: Cobra CLI entrypoint with graceful shutdown

- **Outcome:** `cmd/cortex-sidecar/main.go` with cobra root command, `--version` flag, config loading, component wiring (state store + gateway client), `signal.NotifyContext` for SIGINT/SIGTERM, and ordered shutdown (drain status -> close stream -> close connection).
- **Files to create:** `sidecar/cmd/cortex-sidecar/main.go`
- **Verification:**
  ```bash
  cd sidecar && go build -o bin/cortex-sidecar ./cmd/cortex-sidecar
  cd sidecar && ./bin/cortex-sidecar --version
  cd sidecar && go vet ./cmd/...
  ```
- **Suggested commit message:** `feat(sidecar): add cobra CLI entrypoint with graceful shutdown`

### Task 5: Dockerfile and full build verification

- **Outcome:** Multi-stage Dockerfile (Go build -> distroless). All tests pass with `-race`. `go vet` clean. Static binary compiles. Docker image builds and is under 20MB.
- **Files to create:** `sidecar/Dockerfile`
- **Verification:**
  ```bash
  cd sidecar && CGO_ENABLED=0 go build -o bin/cortex-sidecar ./cmd/cortex-sidecar
  cd sidecar && go test ./... -v -race
  cd sidecar && go vet ./...
  cd sidecar && docker build -t cortex-sidecar .
  docker images cortex-sidecar --format '{{.Size}}'
  ```
- **Suggested commit message:** `feat(sidecar): add Dockerfile with multi-stage distroless build`

---

## CLAUDE.md contributions (do NOT write the file; propose content)

### From Sidecar Core Engineer

**Architecture:**
- Sidecar is a standalone Go binary at `sidecar/`. It is NOT part of the Elixir project.
- Uses gRPC bidirectional streaming to connect to the Cortex gateway on port 4001.
- gRPC handles connection-level reconnect automatically. The sidecar only re-establishes streams.
- State is shared between the gRPC client and HTTP API via a `sync.RWMutex`-protected store.

**Coding style rules:**
- Use `slog` for all logging (never `log` or `fmt.Println`)
- Use `envconfig` struct tags for config, not manual `os.Getenv` calls
- Error wrapping with `fmt.Errorf("context: %w", err)`
- Table-driven tests; run with `-race` flag
- No global state — dependency injection via struct constructors
- All `stream.Send()` calls must go through `sendMu` (gRPC streams are not safe for concurrent sends)

**Dev commands:**
```bash
# Build sidecar binary
cd sidecar && make build

# Run all sidecar tests
cd sidecar && make test

# Run with race detector
cd sidecar && go test ./... -race

# Build Docker image
cd sidecar && make docker-build

# Run the sidecar locally
CORTEX_GATEWAY_URL=cortex:4001 \
CORTEX_AGENT_NAME=my-agent \
CORTEX_AGENT_ROLE="My agent role" \
CORTEX_AGENT_CAPABILITIES=review,analyze \
CORTEX_AUTH_TOKEN=my-token \
./bin/cortex-sidecar
```

**Guardrails:**
- Do NOT reimplement connection-level backoff — gRPC handles this via `grpc.WithConnectParams`
- Do NOT call `stream.Send()` without holding `sendMu` — concurrent sends cause data corruption
- The sidecar depends on generated proto code at `sidecar/internal/proto/gatewayv1/` — if the proto changes, regenerate

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

**Flow / Architecture:**
- The sidecar is a standalone Go binary that runs alongside an agent process (in the same container or machine)
- On startup, it reads configuration from environment variables via `envconfig` (gateway URL, agent identity, auth token)
- It establishes a gRPC connection to the Cortex gateway using `google.golang.org/grpc` with built-in connection-level reconnection
- Over this connection, it opens a bidirectional `Connect` stream (protobuf-defined in `cortex.gateway.v1.AgentGateway`)
- On stream open, it sends a `RegisterRequest` with the agent's name, role, capabilities, and auth token
- The gateway responds with a `RegisterResponse` containing the assigned `agent_id`, which the sidecar stores
- Periodic heartbeats (default: every 15s) keep the agent's health status current in the gateway registry
- Inbound messages (`TaskRequest`, `PeerRequest`, `RosterUpdate`) are dispatched to the state store for the HTTP API to serve
- If the stream breaks, the sidecar re-opens it on the same gRPC connection and re-registers (new agent ID each time)
- The gRPC connection layer handles transport-level reconnect (TCP/HTTP2) with exponential backoff automatically

**Key Engineering Decisions + Tradeoffs:**
- gRPC built-in reconnect for transport, manual stream re-establishment — two layers, but each is simple and well-tested
- `sync.RWMutex` state store over channel-based actor — simpler, allows concurrent reads from HTTP handlers, low contention
- Fixed 2s pause on stream re-establishment — avoids complexity of redundant backoff layer; transport backoff handles the hard case
- `sendMu` mutex for stream writes — simplest serialization for low write rates; channel-based queue is over-engineered here

**Limits of MVP + Next Steps:**
- No outbound message queuing during disconnect — sends return `ErrNotConnected`, caller handles retry
- Agent ID changes on every reconnect — no session resumption protocol yet
- Pending message queue is unbounded — could grow if agent never reads; add size limits later
- No config hot-reload — restart sidecar to change config
- Next: session resumption, outbound buffering, config reload via SIGHUP, queue size limits, metrics endpoint

**How to Run Locally + How to Validate:**
- Build: `cd sidecar && make build`
- Set env vars and run: `CORTEX_GATEWAY_URL=cortex:4001 CORTEX_AGENT_NAME=test-agent ... ./bin/cortex-sidecar`
- Observe the agent appearing in the Cortex gateway registry (via LiveView dashboard or Elixir console)
- Kill the gateway, watch sidecar logs for stream re-establishment
- Restart the gateway, watch sidecar reconnect and re-register
- Run tests: `cd sidecar && go test ./... -race -v`

---

## READY FOR APPROVAL
