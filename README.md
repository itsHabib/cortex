# Cortex

Multi-agent orchestration system built on Elixir/OTP. Cortex manages teams of AI agents that collaborate on complex, multi-step objectives via `claude -p` processes.

It supports two coordination modes: **DAG orchestration** for structured, dependency-aware execution, and **gossip protocol** for emergent, decentralized knowledge sharing.

<!-- TODO: Add demo video / screenshots here -->

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

- Elixir 1.19+
- Erlang/OTP 28+
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) (`claude -p` must be available)

### Setup

```bash
git clone <repo-url> && cd cortex
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

# Resume stalled teams in an existing workspace
mix cortex.resume /path/to/workspace

# Auto-retry on rate limits
mix cortex.resume /path/to/workspace --auto-retry --retry-delay 120
```

### Full stack (with Grafana)

```bash
make up    # Phoenix:4000 + Prometheus:9090 + Grafana:3000 (admin/cortex)
```

## Configuration

Projects are defined in YAML:

```yaml
name: "my-project"
workspace_path: /tmp/my-project

defaults:
  model: sonnet
  max_turns: 200
  permission_mode: acceptEdits
  timeout_minutes: 30

teams:
  - name: backend
    lead:
      role: "Backend Engineer"
      model: opus                # per-team model override
    members:
      - role: "Database Expert"
        focus: "Schema design and migrations"
    tasks:
      - summary: "Build the REST API"
        details: "Implement CRUD endpoints for all resources"
        deliverables:
          - "lib/api/router.ex"
        verify: "mix test test/api/"
    context: |
      Use Phoenix framework with Ecto for persistence.

  - name: frontend
    lead:
      role: "Frontend Engineer"
    tasks:
      - summary: "Build the web UI"
    depends_on:
      - backend               # waits for backend to complete
```

### Config Reference

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | Yes | — | Project name |
| `workspace_path` | No | `"."` | Directory for `.cortex/` workspace |
| `defaults.model` | No | `"sonnet"` | Default LLM model |
| `defaults.max_turns` | No | `200` | Max conversation turns |
| `defaults.permission_mode` | No | `"acceptEdits"` | Permission mode for file edits |
| `defaults.timeout_minutes` | No | `30` | Per-team timeout |
| `teams[].name` | Yes | — | Unique team identifier |
| `teams[].lead.role` | Yes | — | Team lead role description |
| `teams[].lead.model` | No | project default | Model override |
| `teams[].members` | No | `[]` | Additional team members |
| `teams[].tasks` | Yes | — | At least one task |
| `teams[].depends_on` | No | `[]` | Team dependencies (by name) |
| `teams[].context` | No | — | Additional prompt context |

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
