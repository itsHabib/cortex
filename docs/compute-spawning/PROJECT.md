# External Compute Spawning

> Enable Cortex to spawn agents on remote compute (Docker, Kubernetes) and support multiple LLM providers (CLI, HTTP API) through unified abstractions.

---

## Problem & Motivation

Cortex currently spawns all agents as local `claude -p` Erlang port processes on the same machine running the orchestrator. This limits scale (10 agents = 10 heavyweight processes on your laptop), locks you into a single LLM provider, and means the orchestrator and agents share failure domains. We want Cortex to spawn agents anywhere — local containers, k8s Jobs, cloud VMs — while also supporting direct HTTP API calls to Claude (and eventually other providers) instead of always shelling out to the CLI.

---

## Definition of Done

1. A `Provider` behaviour abstracts how Cortex communicates with LLMs. Existing CLI spawning works through `Provider.CLI`. A new `Provider.HTTP` calls the Claude Messages API directly with full agentic loop (send → stream → tool_use → execute → repeat).
2. A `SpawnBackend` behaviour abstracts where agents run. Existing local spawning works through `SpawnBackend.Local`. New backends `SpawnBackend.Docker` and `SpawnBackend.K8s` spawn agents in containers / k8s Jobs.
3. YAML configs support `provider` and `backend` fields per team.
4. The orchestration layer (DAG, mesh, gossip) works with any provider/backend combination.
5. The LiveView dashboard shows remote agent status.
6. All existing tests continue to pass; new code has comprehensive tests.

---

## Key Components

- **Provider behaviour** (`lib/cortex/provider.ex`) — unified interface for LLM communication
- **Provider.CLI** (`lib/cortex/provider/cli.ex`) — wraps existing Spawner for `claude -p`
- **Provider.HTTP** (`lib/cortex/provider/http/`) — Claude Messages API with SSE streaming, agentic loop, tool bridge
- **SpawnBackend behaviour** (`lib/cortex/spawn_backend.ex`) — unified interface for agent compute
- **SpawnBackend.Local** (`lib/cortex/spawn_backend/local.ex`) — wraps existing local port spawning
- **SpawnBackend.Docker** (`lib/cortex/spawn_backend/docker.ex`) — spawn agents in Docker containers
- **SpawnBackend.K8s** (`lib/cortex/spawn_backend/k8s.ex`) — spawn agents as Kubernetes Jobs
- **Config updates** — provider/backend fields in YAML config schema
- **Dashboard updates** — remote agent status in LiveView

---

## Tech Stack

- **Language:** Elixir 1.16+, Erlang/OTP 26+
- **Framework:** Phoenix 1.7, LiveView
- **HTTP client:** Req + Finch (SSE streaming to Claude API)
- **K8s client:** `k8s` Elixir library (k8s API communication)
- **Docker:** Docker Engine API via HTTP (unix socket)
- **Database:** SQLite via Ecto (existing)
- **Testing:** ExUnit, Mox for provider/backend mocking

---

## Non-Goals

- **Sidecar binary** — covered in the Cluster Mode feature, not here
- **External agent registration** — agents joining from outside; separate feature
- **Agent-to-agent tool use** — separate feature
- **Multi-provider beyond Claude** — HTTP provider targets Claude API first; OpenAI/Ollama adapters are future work
- **Auto-scaling** — k8s HPA or Fly autoscale; we do manual spawning for now
- **GPU/hardware-specific scheduling** — out of scope

---

## Constraints

- Must not break existing CLI-based orchestration — all current tests pass
- Must work with existing YAML config format (additive fields only)
- HTTP provider needs a valid `ANTHROPIC_API_KEY` environment variable
- Docker backend requires Docker Engine running locally
- K8s backend requires a valid kubeconfig and cluster access
- Existing Spawner module is the primary integration point — refactor, don't rewrite

---

## Team

| Role | Focus |
|------|-------|
| Behaviour Architect | Provider and SpawnBackend behaviour definitions |
| CLI Refactor Engineer | Wrap existing Spawner into Provider.CLI + SpawnBackend.Local |
| Config Engineer | YAML config updates for provider/backend fields |
| Integration Engineer | Wire orchestration layer to use Provider abstraction |
| API Client Engineer | Claude Messages API HTTP client with SSE streaming |
| Agentic Loop Engineer | Conversation loop GenServer with tool dispatch |
| Tool Schema Engineer | Bridge Cortex Tool behaviours to Claude API tool format |
| Observability Engineer | Token tracking, telemetry, tests for HTTP provider |
| Docker Backend Engineer | SpawnBackend.Docker implementation |
| K8s Backend Engineer | SpawnBackend.K8s implementation via k8s Jobs API |
| Container Spec Engineer | Dockerfile, agent image, startup scripts |
| Streaming & Dashboard Engineer | Output streaming from remote backends, LiveView updates |

---

## Phases

| Phase | Config | Goal |
|-------|--------|------|
| Foundation | docs/compute-spawning/phase-1-foundation/kickoff.yaml | Provider & SpawnBackend abstractions, refactor existing code |
| HTTP Provider | docs/compute-spawning/phase-2-http-provider/kickoff.yaml | Claude API direct integration with agentic loop |
| Remote Backends | docs/compute-spawning/phase-3-remote-backends/kickoff.yaml | Docker and Kubernetes spawn backends |

---

## Usage in Phase Planning

This file is the source of truth for all planning phases.
List it as the first dependency in every phase config:

```yaml
dependencies:
  - docs/compute-spawning/PROJECT.md
```
