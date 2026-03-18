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

1. A Phoenix WebSocket gateway where agents connect and register with capabilities.
2. A sidecar binary that agents run alongside themselves — it connects to Cortex, handles heartbeats, and exposes a local HTTP API the agent can call.
3. Agent-to-agent tool use — any registered agent can invoke any other via the `ask_agent` tool.
4. Capability-based discovery — agents query the mesh for peers by capability.
5. Provider.External bridges the gateway into the Provider abstraction from Feature 1.
6. The existing mesh mode and LiveView dashboard work with externally registered agents.
7. Comprehensive tests for the registration protocol, sidecar, and agent-to-agent routing.

---

## Key Components

- **Agent Gateway** (`lib/cortex_web/channels/`) — Phoenix WebSocket channel for agent connections
- **Gateway Registry** (`lib/cortex/gateway/`) — tracks connected agents, capabilities, health
- **Registration Protocol** — message format for join, heartbeat, capability advertisement
- **Sidecar** (`sidecar/`) — lightweight binary agents run locally, exposes HTTP API + Cortex WebSocket
- **Provider.External** (`lib/cortex/provider/external.ex`) — Provider implementation for external agents
- **Agent Tool** (`lib/cortex/tool/agent_tool.ex`) — tool that routes invocations to other agents
- **Capability Discovery** (`lib/cortex/gateway/discovery.ex`) — find agents by capability

---

## Tech Stack

- **Language:** Elixir (gateway, registry, provider), Go or Elixir escript (sidecar)
- **Framework:** Phoenix Channels (WebSocket gateway)
- **Protocol:** JSON over WebSocket (agent ↔ Cortex), HTTP (agent ↔ sidecar)
- **Auth:** Bearer tokens for gateway registration (simple, extensible later)
- **Testing:** ExUnit, WebSocket test clients

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
- Gateway must handle hundreds of concurrent WebSocket connections
- Sidecar must be a single binary with zero dependencies (easy to deploy in any container)
- Registration protocol must be versioned from day one (future-proofing)
- Agent-to-agent calls must have timeout and depth limits (prevent infinite recursion)

---

## Team

| Role | Focus |
|------|-------|
| Gateway Architect | Phoenix WebSocket channel for agent connections |
| Registry Engineer | Agent registry with capabilities, health tracking |
| Protocol Engineer | Registration, heartbeat, and messaging protocol |
| Sidecar Engineer | Sidecar binary — Cortex connection + local HTTP API |
| Sidecar API Engineer | Local HTTP endpoints the agent calls (messages, roster, knowledge) |
| External Provider Engineer | Provider.External implementation |
| Agent Tool Engineer | Agent-to-agent tool use (ask_agent tool) |
| Discovery Engineer | Capability-based agent discovery and routing |
| Dashboard Engineer | Mesh visualization and external agent monitoring |

---

## Phases

| Phase | Config | Goal |
|-------|--------|------|
| Agent Gateway | docs/cluster-mode/phase-1-agent-gateway/kickoff.yaml | WebSocket gateway, registry, registration protocol |
| Sidecar | docs/cluster-mode/phase-2-sidecar/kickoff.yaml | Sidecar binary with local HTTP API and Cortex connection |
| Agent Mesh | docs/cluster-mode/phase-3-agent-mesh/kickoff.yaml | Agent-to-agent tool use, capability discovery, Provider.External |

---

## Usage in Phase Planning

This file is the source of truth for all planning phases.
List it as the first dependency in every phase config:

```yaml
dependencies:
  - docs/cluster-mode/PROJECT.md
```
