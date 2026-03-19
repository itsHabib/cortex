# Cortex Sidecar

Go binary that runs alongside agents, connecting them to the Cortex mesh via gRPC. Agents interact with the mesh through a local HTTP API on `localhost:9090`.

```
┌──────────────┐      ┌───────────────┐        ┌─────────────┐
│  Agent       │──────│   Sidecar     │──gRPC──│   Cortex    │
│  (any lang)  │ HTTP │   (Go binary) │        │   Gateway   │
│              │:9090 │               │        │   :4001     │
└──────────────┘      └───────────────┘        └─────────────┘
```

## Quick Start

```bash
# Build
make build

# Run
CORTEX_GATEWAY_URL=localhost:4001 \
CORTEX_AGENT_NAME=my-agent \
CORTEX_AGENT_ROLE="code reviewer" \
CORTEX_AGENT_CAPABILITIES=review,security \
CORTEX_AUTH_TOKEN=your-token \
./bin/cortex-sidecar
```

## Configuration

All via environment variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CORTEX_GATEWAY_URL` | yes | — | gRPC gateway address (e.g., `localhost:4001`) |
| `CORTEX_AGENT_NAME` | yes | — | Agent name for registration |
| `CORTEX_AGENT_ROLE` | no | `agent` | Agent role description |
| `CORTEX_AGENT_CAPABILITIES` | no | — | Comma-separated capabilities |
| `CORTEX_AUTH_TOKEN` | no | — | Bearer token for gateway auth |
| `CORTEX_SIDECAR_PORT` | no | `9090` | Local HTTP API port |
| `CORTEX_HEARTBEAT_INTERVAL` | no | `15s` | Heartbeat interval |

## HTTP API

The sidecar exposes a local HTTP/JSON API for the co-located agent:

### Mesh Queries
- `GET /health` — sidecar health + connection status
- `GET /roster` — list all agents in the mesh
- `GET /roster/{agent_id}` — agent details
- `GET /roster/capable/{capability}` — find agents by capability

### Messaging
- `GET /messages` — get pending inbound messages
- `POST /messages/{agent_id}` — send a message to another agent
- `POST /broadcast` — broadcast to all agents

### Agent-to-Agent Invocation
- `POST /ask/{agent_id}` — invoke another agent (blocks until response)
- `POST /ask/capable/{capability}` — invoke by capability

### Status & Tasks
- `POST /status` — report progress to Cortex
- `GET /task` — get current task assignment
- `POST /task/result` — submit task result

### Knowledge (Phase 3)
- `GET /knowledge` — 501 Not Implemented
- `POST /knowledge` — 501 Not Implemented

## Project Structure

```
sidecar/
├── cmd/cortex-sidecar/main.go    # CLI entrypoint (cobra)
├── internal/
│   ├── api/                      # HTTP API (chi router, 14 endpoints)
│   ├── config/                   # Environment config (envconfig)
│   ├── gateway/                  # gRPC client (bidirectional streaming)
│   ├── state/                    # Thread-safe state store (sync.RWMutex)
│   ├── proto/gatewayv1/          # Generated protobuf + gRPC stubs
│   └── testutil/                 # Mock gRPC server for tests
├── Dockerfile                    # Multi-stage distroless build
└── Makefile                      # build, test, lint, docker-build
```

## Development

```bash
make build          # Build binary to bin/cortex-sidecar
make test           # Run all tests
make lint           # go vet
make docker-build   # Build Docker image
make clean          # Remove build artifacts
```

## How It Works

1. Sidecar starts and dials the Cortex gateway via gRPC
2. Opens a bidirectional `Connect` stream (protobuf)
3. Sends `RegisterRequest` with agent identity + auth token
4. Gateway responds with `RegisterResponse` (assigned agent ID)
5. Sidecar sends periodic heartbeats to stay registered
6. Inbound messages (tasks, peer requests, roster updates) are cached in the state store
7. The HTTP API reads from the state store and writes via the gRPC stream
8. On stream break, the sidecar re-opens the stream and re-registers (gRPC handles transport reconnection automatically)

## Docker

```bash
make docker-build
docker run -e CORTEX_GATEWAY_URL=host.docker.internal:4001 \
           -e CORTEX_AGENT_NAME=my-agent \
           -e CORTEX_AUTH_TOKEN=token \
           cortex-sidecar
```
