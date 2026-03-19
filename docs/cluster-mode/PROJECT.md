# Cluster Mode — Agent Mesh & External Registration

> Turn Cortex into a control plane for an agent mesh where agents register externally, discover each other by capability, and invoke each other as tools — regardless of where they run.

---

## Problem & Motivation

Cortex currently owns the full lifecycle of every agent — it spawns them, watches them, and collects results. Agents can't join from outside, can't discover each other's capabilities, and can't invoke each other. Communication is limited to fire-and-forget file-based messages.

Cluster Mode makes Cortex a **service mesh for AI agents**. Agents register with Cortex (either spawned by Cortex or joining externally), advertise capabilities, discover peers, and call each other as tools. Cortex provides the control plane: registry, routing, health monitoring, and observability. The agents are the data plane.

This unlocks:
- Long-running specialist agents that participate in many runs
- Mixed fleets — some agents spawned by Cortex, some running on developer laptops, some in cloud VMs
- Agent-to-agent tool use — structured, synchronous invocation (not just messages)
- Capability-based routing — "find me an agent that does security review" rather than "send this to agent-7"

---

## Definition of Done

1. A gRPC data-plane gateway where agents connect and register with capabilities (Phoenix WebSocket retained for control plane/UI).
2. A Go sidecar binary that agents run alongside themselves — it connects to Cortex via gRPC, handles heartbeats, and exposes a local HTTP API the agent can call.
3. Agent-to-agent tool use — any registered agent can invoke any other via the `ask_agent` tool.
4. Capability-based discovery — agents query the mesh for peers by capability.
5. Provider.External bridges the gateway into the Provider abstraction from Feature 1.
6. The existing mesh mode and LiveView dashboard work with externally registered agents.
7. Comprehensive tests for the registration protocol, sidecar, and agent-to-agent routing.

---

## Key Components

- **Control Plane** (`lib/cortex_web/`) — Phoenix Channels + LiveView for operator UI and dashboard
- **Data Plane** (`lib/cortex/gateway/grpc_server.ex`) — gRPC server for agent connections
- **Proto Contract** (`proto/cortex/gateway/v1/`) — protobuf service and message definitions
- **Gateway Registry** (`lib/cortex/gateway/`) — tracks connected agents, capabilities, health (shared by control + data plane)
- **Sidecar** (`sidecar/`) — Go binary, gRPC client + local HTTP API for agents
- **Provider.External** (`lib/cortex/provider/external.ex`) — Provider implementation for external agents
- **Agent Tool** (`lib/cortex/tool/agent_tool.ex`) — tool that routes invocations to other agents
- **Capability Discovery** (`lib/cortex/gateway/discovery.ex`) — find agents by capability

---

## Tech Stack

- **Language:** Elixir (gateway, registry, provider), Go (sidecar)
- **Control Plane:** Phoenix Channels + LiveView (operator UI, dashboard)
- **Data Plane:** gRPC bidirectional streaming (agent ↔ Cortex gateway)
- **Protocol:** Protobuf v3 (`cortex.gateway.v1`) — typed, versioned, generates clients in any language
- **Sidecar ↔ Agent:** HTTP/JSON on localhost (agent calls sidecar REST API)
- **Auth:** Bearer tokens for gateway registration (simple, extensible later)
- **Build:** `buf`/`protoc` for proto codegen, `go build` for sidecar binary
- **Testing:** ExUnit (Elixir), `go test` (Go), gRPC test clients

---

## Non-Goals

- **Multi-tenancy / user management** — single-tenant for now
- **Encryption / mTLS between agents** — trust the network for now
- **Agent marketplace / public registry** — agents are registered by operators, not discovered publicly
- **Persistent agent state across restarts** — agents are ephemeral; state lives in Cortex
- **BEAM distribution (libcluster/Horde)** — separate concern from agent mesh

---

## Constraints

- Must integrate with the Provider/SpawnBackend abstractions from the Compute Spawning feature
- Gateway must handle hundreds of concurrent gRPC streams
- Sidecar is a Go binary (natural fit for infrastructure sidecars, first-class gRPC support)
- Registration protocol must be versioned from day one (future-proofing)
- Agent-to-agent calls must have timeout and depth limits (prevent infinite recursion)

---

## Team

| Role | Focus |
|------|-------|
| Gateway Architect | Phoenix WebSocket channel for control plane (Phase 1) |
| Registry Engineer | Agent registry with capabilities, health tracking (Phase 1) |
| Protocol Engineer | Registration, heartbeat, and messaging protocol (Phase 1) |
| Proto & Codegen Engineer | Protobuf service definition + code generation pipeline |
| Gateway gRPC Engineer | gRPC data-plane server in Elixir |
| Sidecar Core Engineer | Go sidecar binary — gRPC client, config, reconnect |
| Sidecar HTTP API Engineer | Go local HTTP endpoints for agents |
| Integration Test Engineer | End-to-end gRPC + sidecar tests |
| External Provider Engineer | Provider.External implementation (Phase 3) |
| Agent Tool Engineer | Agent-to-agent tool use (Phase 3) |
| Discovery Engineer | Capability-based agent discovery and routing (Phase 3) |
| Dashboard Engineer | Mesh visualization and external agent monitoring (Phase 3) |

---

## Phases

| Phase | Config | Goal |
|-------|--------|------|
| Agent Gateway | docs/cluster-mode/phase-1-agent-gateway/kickoff.yaml | Phoenix WebSocket gateway, registry, registration protocol (control plane) |
| Sidecar + gRPC | docs/cluster-mode/phase-2-sidecar/kickoff-v2-grpc.yaml | gRPC data plane, Go sidecar binary, proto contract, local HTTP API |
| Agent Mesh | docs/cluster-mode/phase-3-agent-mesh/kickoff.yaml | Agent-to-agent tool use, capability discovery, Provider.External |

---

## Usage in Phase Planning

This file is the source of truth for all planning phases.
List it as the first dependency in every phase config:

```yaml
dependencies:
  - docs/cluster-mode/PROJECT.md
```
