# Cortex

Multi-agent orchestration system built on Elixir/OTP. Cortex manages teams of AI agents that collaborate on complex, multi-step objectives via `claude -p` processes.

It supports three coordination modes: **DAG orchestration** for structured, dependency-aware execution, **mesh** for autonomous agents with optional peer messaging, and **gossip protocol** for emergent, decentralized knowledge sharing.

Built on Elixir/OTP because the problem is inherently concurrent — dozens of long-lived agent processes, message routing, failure detection, real-time streaming. OTP provides supervision trees, GenServers, Erlang ports, PubSub, and Phoenix LiveView out of the box. Every piece of infrastructure that would need to be hand-rolled in other stacks comes for free.

![Mesh — animated communication graph](priv/static/images/mesh-overview.jpg)

<details>
<summary>More screenshots</summary>

### DAG Workflow
![DAG overview — run in progress](priv/static/images/dag-overview.jpg)

### Gossip Protocol
![Gossip — topology and knowledge exchange](priv/static/images/gossip-overview.jpg)

### Logs
![Logs — structured NDJSON output](priv/static/images/logs-overview.jpg)

</details>

## Table of Contents

- [Modes](#modes)
- [Features](#features)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Workspace Layout](#workspace-layout)
- [Development](#development)
- [Project Structure](#project-structure)

## Modes

Cortex supports three coordination modes. Each mode defines how agents are organized, how they communicate, and how much coordination is imposed.

### Workflow (DAG)

Structured, dependency-aware execution. Define teams with explicit dependencies — Cortex builds a DAG, sorts into parallel tiers via Kahn's algorithm, and executes tier by tier. Upstream results are injected into downstream prompts.

**Use when:** you have a multi-step project with clear dependencies (backend before frontend, research before implementation).

- Teams run in parallel within a tier, sequentially across tiers
- Fault recovery — continue interrupted runs, resume stalled sessions, restart with injected log history
- File-based messaging — coordinator can send mid-run guidance to teams

### Mesh

Autonomous agents with optional peer messaging. Each agent gets a roster of who else is in the cluster and can message them if needed, but there's no forced coordination. Agents work independently on their assignments and reach out only when they need info from another agent's domain.

**Use when:** you have parallel workstreams that are mostly independent but might benefit from occasional cross-talk (multiple researchers, parallel feature builds, distributed analysis).

- SWIM-inspired membership — agents tracked through alive → suspect → dead lifecycle states
- Failure detection — periodic heartbeat checks with configurable suspect/dead timeouts
- Message relay — outbox polling delivers cross-agent messages via file-based inboxes
- Thin orchestrator (~300 LOC) — spawn agents, provide roster, get out of the way

### Gossip

Emergent, decentralized knowledge sharing. Agents explore different angles of a topic independently. A coordinator periodically reads their findings, runs gossip protocol exchanges between knowledge stores, and delivers merged knowledge back to agents.

**Use when:** you want multiple agents exploring a broad topic and cross-pollinating ideas (market research, brainstorming, literature review).

- CRDT-backed knowledge stores with vector clocks for conflict-free convergence
- Push-pull exchange — agents compare digests, fetch missing/newer entries, merge with causal ordering
- Topology strategies — full mesh, ring, and random-k peering
- Optional coordinator agent that can steer exploration and terminate early

## Features

### Observability
- **Live token tracking** — NDJSON usage parsed in real-time, streamed to LiveView via PubSub
- **Activity feed** — tool use events extracted from agent output, displayed as a live timeline
- **Stalled detection** — teams flagged after 5 minutes of silence, with per-team health indicators
- **Diagnostics** — LogParser structures NDJSON into timelines with auto-diagnosis (died during tool use, hit max turns, rate limited, no session, etc.)
- **Telemetry + Prometheus + Grafana** — structured telemetry events, `/metrics` endpoint, pre-configured dashboards

### Dashboard (Phoenix LiveView)
- **Run detail** — 5 tabs: Overview, Activity, Messages, Logs, Diagnostics
- **Overview** — coordinator status, status grid (pending/running/stalled/done/failed), DAG visualization, token counters
- **Messages** — per-team inbox/outbox viewer with send form
- **Diagnostics** — event timeline, diagnosis banners, resume/restart buttons per team
- **Team detail** — individual team page with prompt, logs, and recovery actions
- **Gossip view** — topology visualization with round-by-round knowledge propagation

### Infrastructure
- **Pluggable tool system** — sandboxed execution with timeouts and crash isolation
- **Persistent event log** — all orchestration events stored in SQLite via Ecto
- **Liveness checks** — spawner monitors port processes every 2 minutes, catches silent deaths

## Quick Start

### Prerequisites

- Elixir 1.17+
- Erlang/OTP 27+
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) (`claude -p` must be available)

### Setup

```bash
git clone https://github.com/itsHabib/cortex.git && cd cortex
mix deps.get
mix ecto.create && mix ecto.migrate
mix test
```

### Start the dashboard

```bash
mix phx.server
# http://localhost:4000
```

### Create a config

The easiest way to create a config is with the Claude Code skill:

```
/cortex-config
```

This walks you through choosing a mode, describing your project, and writes the YAML for you.

Or create configs manually — see [Configuration](#configuration) for the schema.

### Run an orchestration

```bash
# Dry run — show execution plan without spawning agents
mix cortex.run examples/mesh-simple.yaml --dry-run

# Run
mix cortex.run examples/mesh-simple.yaml

# Resume stalled teams in an existing workspace
mix cortex.resume /path/to/workspace

# Auto-retry on rate limits
mix cortex.resume /path/to/workspace --auto-retry --retry-delay 120
```

You can also launch runs directly from the dashboard at `http://localhost:4000`.

### Full stack (with Grafana)

```bash
make up    # Phoenix:4000 + Prometheus:9090 + Grafana:3000 (admin/cortex)
```

## Configuration

Projects are defined in YAML. Three modes:

**DAG workflow** — teams with dependencies, executed in parallel tiers:

```yaml
teams:
  - name: backend
    lead: { role: "Backend Engineer" }
    tasks: [{ summary: "Build the API", deliverables: ["api.ex"] }]
  - name: frontend
    lead: { role: "Frontend Engineer" }
    tasks: [{ summary: "Build the UI" }]
    depends_on: [backend]
```

**Mesh** — autonomous agents with optional peer messaging:

```yaml
mode: mesh
mesh: { heartbeat_interval_seconds: 30, suspect_timeout_seconds: 90 }
agents:
  - name: market-sizing
    role: "Market researcher"
    prompt: "Research market size and growth..."
  - name: competitor-analysis
    role: "Competitive analyst"
    prompt: "Map the competitive landscape..."
```

**Gossip** — agents explore independently, knowledge exchanged periodically:

```yaml
mode: gossip
gossip: { rounds: 3, topology: full_mesh, exchange_interval_seconds: 30 }
agents:
  - name: analyst
    topic: "competitors"
    prompt: "Research the top 5 competitors..."
```

See `examples/` for complete configs (`dag-demo.yaml`, `gossip-simple.yaml`, `mesh-simple.yaml`).

### Config Reference

**Shared fields:**

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | Yes | — | Project name |
| `mode` | No | `"workflow"` | `workflow` (DAG), `gossip`, or `mesh` |
| `workspace_path` | No | `"."` | Directory for `.cortex/` workspace |
| `defaults.model` | No | `"sonnet"` | Default LLM model |
| `defaults.max_turns` | No | `200` | Max conversation turns |
| `defaults.permission_mode` | No | `"acceptEdits"` | Permission mode for file edits |
| `defaults.timeout_minutes` | No | `30` | Per-team/agent timeout |

**DAG workflow fields:**

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `teams[].name` | Yes | — | Unique team identifier |
| `teams[].lead.role` | Yes | — | Team lead role description |
| `teams[].lead.model` | No | project default | Model override |
| `teams[].members` | No | `[]` | Additional team members |
| `teams[].tasks` | Yes | — | At least one task |
| `teams[].depends_on` | No | `[]` | Team dependencies (by name) |
| `teams[].context` | No | — | Additional prompt context |

**Mesh fields:**

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `mesh.heartbeat_interval_seconds` | No | `30` | Seconds between heartbeat checks |
| `mesh.suspect_timeout_seconds` | No | `90` | Seconds before suspect → dead |
| `mesh.dead_timeout_seconds` | No | `180` | Seconds before dead member cleanup |
| `cluster_context` | No | — | Shared context for all agents |
| `agents[].name` | Yes | — | Unique agent identifier |
| `agents[].role` | Yes | — | Agent role description |
| `agents[].prompt` | Yes | — | Agent instructions |
| `agents[].model` | No | project default | Model override |
| `agents[].metadata` | No | `{}` | Arbitrary key-value metadata |

**Gossip fields:**

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `gossip.rounds` | No | `5` | Number of knowledge exchange rounds |
| `gossip.topology` | No | `"random"` | `full_mesh`, `ring`, or `random` |
| `gossip.exchange_interval_seconds` | No | `60` | Seconds between exchange rounds |
| `gossip.coordinator` | No | `false` | Spawn a coordinator agent |
| `cluster_context` | No | — | Shared context for all agents |
| `agents[].name` | Yes | — | Unique agent identifier |
| `agents[].topic` | Yes | — | Knowledge topic this agent explores |
| `agents[].prompt` | Yes | — | Agent instructions |
| `seed_knowledge` | No | `[]` | Initial knowledge entries |

## Architecture

### Supervision Tree

```
Cortex.Supervisor (one_for_one)
  |-- Phoenix.PubSub
  |-- Registry (Agent.Registry)
  |-- DynamicSupervisor (Agent.Supervisor)
  |-- Task.Supervisor (Tool.Supervisor)
  |-- Tool.Registry (Agent)
  |-- Registry (RunnerRegistry)
  |-- Registry (MailboxRegistry)
  |-- Messaging.Router
  |-- Messaging.Supervisor
  |-- Repo (Ecto/SQLite)
  |-- Store.EventSink
  |-- CortexWeb.Telemetry
  |-- TelemetryMetricsPrometheus.Core
  |-- CortexWeb.Endpoint (Phoenix)
```

### Orchestration (`lib/cortex/orchestration/`)

Runner, DAG engine, Spawner (port-based process management, NDJSON parsing), Workspace management, prompt Injection, LogParser, Config.Loader.

### Mesh (`lib/cortex/mesh/`)

Member struct with state machine, MemberList GenServer, Detector (heartbeat), Prompt builder, MessageRelay, SessionRunner (~300 LOC), ephemeral Supervisor.

### Gossip (`lib/cortex/gossip/`)

KnowledgeStore GenServers with vector clocks, push-pull Protocol, Topology strategies, SessionRunner (~1,200 LOC coordinator).

### Messaging (`lib/cortex/messaging/`)

File-based messaging (InboxBridge) for team coordination during runs, plus an in-process system (Router, Mailbox, Bus) for agent-to-agent communication.

### Dashboard (`lib/cortex_web/live/`)

Phoenix LiveView with real-time PubSub subscriptions — no polling.

- **DashboardLive** — system overview, recent runs
- **RunListLive** — filterable run history with sort and delete
- **RunDetailLive** — tabbed run view (overview, activity, messages, logs, diagnostics)
- **TeamDetailLive** — individual team inspection with recovery actions
- **NewRunLive** — launch runs from the browser
- **GossipLive** — gossip topology visualization

### Persistence (`lib/cortex/store/`)

Ecto with SQLite. EventSink subscribes to PubSub and persists events automatically. Schemas: `Run`, `TeamRun`, `EventLog`.

## Workspace Layout

Each run creates a `.cortex/` directory:

```
.cortex/
  state.json          # per-team status, result summaries, token counts
  registry.json       # team registry: names, session IDs, timestamps
  results/
    <team>.json       # full result per team
  logs/
    <team>.log        # raw NDJSON from claude -p
  messages/
    <team>/
      inbox.json      # messages received
      outbox.json     # messages sent
```

## Development

```bash
mix test                              # run all tests
mix test --trace                      # verbose output
mix test test/cortex/orchestration/   # specific directory
mix format                            # format code
mix compile --warnings-as-errors      # compile check
mix credo --strict                    # lint
```

### Benchmarks

```bash
mix run bench/agent_bench.exs         # agent lifecycle
mix run bench/gossip_bench.exs        # gossip protocol
mix run bench/dag_bench.exs           # DAG engine
```

## Project Structure

```
cortex/
  bench/                          # Benchee benchmark scripts
  config/                         # Environment configs
  lib/
    cortex/
      agent/                      # Agent GenServer, Config, State, Registry
      coordinator/                # Coordinator prompt building
      gossip/                     # KnowledgeStore, Protocol, VectorClock, Topology
      mesh/                       # Member, MemberList, Detector, Prompt, SessionRunner
      messaging/                  # InboxBridge, OutboxWatcher, Router, Mailbox, Bus
      orchestration/              # Runner, DAG, Spawner, Workspace, Config, LogParser
      perf/                       # Profiler utilities
      store/                      # Ecto schemas, EventSink
      tool/                       # Tool behaviour, executor, registry
    cortex_web/
      components/                 # Phoenix components (core, DAG)
      live/                       # LiveView pages
  priv/
    repo/migrations/              # Ecto migrations
  test/                           # mirrors lib/ structure
```

## License

MIT
