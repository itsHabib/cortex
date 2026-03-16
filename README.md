# Cortex

Multi-agent orchestration system built on Elixir/OTP. Cortex manages teams of AI agents that collaborate on complex, multi-step objectives via `claude -p` processes.

It supports two coordination modes: **DAG orchestration** for structured, dependency-aware execution, and **gossip protocol** for emergent, decentralized knowledge sharing.

![DAG overview — run in progress](priv/static/images/dag-overview.jpg)

## Why Elixir?

Running dozens of long-lived AI agent processes, routing messages between them, detecting failures, and streaming real-time updates to a dashboard — this is exactly what OTP was built for. Cortex uses supervision trees for fault tolerance, GenServers for per-agent state, Erlang ports for process management, PubSub for event streaming, and Phoenix LiveView for a real-time dashboard with zero polling. Every piece of infrastructure that would need to be hand-rolled in other stacks comes out of the box.

## Features

### Orchestration
- **DAG-based execution** — define teams with dependencies in YAML, execute in parallel tiers via Kahn's algorithm
- **Fault recovery** — continue interrupted runs (skips completed teams), resume stalled sessions via `claude --resume`, or restart with injected log history
- **File-based messaging** — inbox/outbox per team, outbox watcher polls for progress, coordinator can message teams mid-run

### Observability
- **Live token tracking** — NDJSON usage parsed in real-time, streamed to LiveView via PubSub
- **Activity feed** — tool use events extracted from agent output, displayed as a live timeline
- **Stalled detection** — teams flagged after 5 minutes of silence, with per-team health indicators
- **Diagnostics** — LogParser structures NDJSON into timelines with auto-diagnosis (died during tool use, hit max turns, rate limited, no session, etc.)
- **Telemetry + Prometheus + Grafana** — structured telemetry events, `/metrics` endpoint, pre-configured dashboards

### Gossip Protocol
- **CRDT-backed knowledge stores** — per-agent GenServers with vector clocks for conflict-free convergence
- **Push-pull exchange** — agents compare digests, fetch missing/newer entries, merge with causal ordering
- **Topology strategies** — full mesh, ring, and random-k peering

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

### Run an orchestration

```bash
# Dry run — show execution plan without spawning agents
mix run -e 'Cortex.Orchestration.Runner.run("orchestra.yaml", dry_run: true) |> IO.inspect()'

# Full run
mix run -e 'Cortex.Orchestration.Runner.run("orchestra.yaml") |> IO.inspect()'

# Gossip run
mix run -e 'Cortex.Gossip.SessionRunner.run("gossip.yaml") |> IO.inspect()'

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

### DAG Workflow (`examples/dag-demo.yaml`)

Teams execute in dependency order — tier 0 runs in parallel, tier 1 waits for its dependencies, etc.

```yaml
name: "dag-demo"

defaults:
  model: haiku
  max_turns: 50
  permission_mode: bypassPermissions
  timeout_minutes: 10

teams:
  # Tier 0 — three parallel research teams
  - name: requirements
    lead:
      role: "Requirements Analyst"
    tasks:
      - summary: "Gather requirements for a CLI calculator app"
        details: "Supported ops, input format, error handling, edge cases."
        deliverables: ["requirements.md"]

  - name: tech-research
    lead:
      role: "Tech Researcher"
    tasks:
      - summary: "Research Go CLI patterns for a calculator"
        deliverables: ["tech-research.md"]

  - name: test-strategy
    lead:
      role: "QA Strategist"
    tasks:
      - summary: "Define test strategy"
        deliverables: ["test-strategy.md"]

  # Tier 1 — depends on tier 0
  - name: architecture
    lead:
      role: "Software Architect"
    tasks:
      - summary: "Design the calculator architecture"
        deliverables: ["architecture.md"]
    depends_on: [requirements, tech-research]

  - name: test-plan
    lead:
      role: "QA Lead"
    tasks:
      - summary: "Write detailed test cases"
        deliverables: ["test-plan.md"]
    depends_on: [requirements, test-strategy]

  # Tier 2 — final synthesis
  - name: integration
    lead:
      role: "Integration Lead"
    tasks:
      - summary: "Produce the final implementation plan"
        deliverables: ["implementation-plan.md"]
    depends_on: [architecture, test-plan]
```

### Gossip Session (`examples/gossip-simple.yaml`)

Agents explore independently while a background coordinator periodically exchanges knowledge between them.

```yaml
name: "gossip-simple"
mode: gossip

cluster_context: |
  You're part of a small team brainstorming names for a new coffee shop
  that roasts its own beans and has a cozy library vibe. Share your best
  ideas — build on what others suggest.

defaults:
  model: haiku
  max_turns: 50
  permission_mode: bypassPermissions
  timeout_minutes: 5

gossip:
  rounds: 3                        # knowledge exchange rounds
  topology: full_mesh              # full_mesh | ring | random
  exchange_interval_seconds: 30    # seconds between rounds

agents:
  - name: branding
    topic: "shop names"
    prompt: |
      Brainstorm 5 creative names for a coffee shop that roasts its own beans
      and has a cozy library atmosphere. Build on any peer ideas you receive.

  - name: vibes
    topic: "shop names"
    prompt: |
      Brainstorm 5 creative names for a coffee-and-books shop. Focus on names
      that evoke warmth, curiosity, and the smell of fresh roast.

seed_knowledge:
  - topic: "context"
    content: "College town. Target: students, professors, remote workers."
```

### Config Reference

**Shared fields:**

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | Yes | — | Project name |
| `mode` | No | `"workflow"` | `workflow` (DAG) or `gossip` |
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

### DAG Orchestration (`lib/cortex/orchestration/`)

The engine loads YAML configs, builds a dependency DAG via Kahn's algorithm, and executes teams in parallel tiers. Each team spawns a `claude -p` process through Erlang ports, streams NDJSON for real-time tracking, and records results to both the workspace and DB.

Key modules:
- **Runner** — orchestrator: `run/2`, `continue_run/2`, `resume_run/2`
- **DAG** — topological sort into execution tiers
- **Spawner** — port-based process management, NDJSON parsing, session ID extraction, rate limit detection
- **Workspace** — `.cortex/` directory management (state, registry, logs, results, messages)
- **Injection** — prompt construction with role, tasks, upstream results, inbox instructions
- **LogParser** — NDJSON log parsing with auto-diagnosis
- **Config.Loader** — YAML validation into typed structs

### Gossip Protocol (`lib/cortex/gossip/`)

Each agent has a KnowledgeStore GenServer holding entries with vector clocks. Push-pull exchanges compare digests, transfer missing/newer entries, and merge with causal ordering. Concurrent conflicts resolve by confidence score, then timestamp.

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
mix test                              # 692 tests
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
