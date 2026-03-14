# Cortex

Multi-agent orchestration system built on Elixir/OTP. Cortex manages teams of AI agents that collaborate on complex, multi-step objectives. It supports two coordination modes: **DAG orchestration** for structured, dependency-aware execution, and **gossip protocol** for emergent, decentralized knowledge sharing.

## Features

- **DAG-based orchestration** -- define teams with dependencies in YAML, execute in parallel tiers using Kahn's algorithm
- **Gossip protocol** -- CRDT-backed knowledge stores with vector clocks for conflict-free convergence
- **LiveView dashboard** -- real-time web UI showing run progress, DAG visualization, team results
- **Pluggable tool system** -- sandboxed tool execution with timeout enforcement and crash isolation
- **Persistent event log** -- all orchestration events stored in SQLite via Ecto for replay and debugging
- **Telemetry instrumentation** -- structured telemetry events for all critical operations
- **Health checks** -- programmatic system health inspection

## Quick Start

### Prerequisites

- Elixir 1.17+
- Erlang/OTP 27+

### Setup

```bash
git clone <repo-url> && cd cortex
mix deps.get
mix ecto.create
mix ecto.migrate
mix test
```

### Start the dashboard

```bash
mix phx.server
# Visit http://localhost:4000
```

### Run an orchestration

```bash
# Validate a config file
# (see Configuration section for the orchestra.yaml format)
mix run -e 'Cortex.Orchestration.Config.Loader.load("path/to/orchestra.yaml") |> IO.inspect()'

# Run via the Runner module
mix run -e 'Cortex.Orchestration.Runner.run("path/to/orchestra.yaml") |> IO.inspect()'
```

## Configuration

Cortex projects are defined in `orchestra.yaml` files:

```yaml
name: "my-project"

defaults:
  model: sonnet                  # LLM model (default: sonnet)
  max_turns: 200                 # Max conversation turns per agent
  permission_mode: acceptEdits   # How agents handle file edits
  timeout_minutes: 30            # Per-team timeout

teams:
  - name: backend
    lead:
      role: "Backend Engineer"
      model: opus                # Optional per-team model override
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
      - backend               # Waits for backend to complete
```

### Configuration Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | Yes | -- | Project name |
| `defaults.model` | No | `"sonnet"` | Default LLM model |
| `defaults.max_turns` | No | `200` | Max conversation turns |
| `defaults.permission_mode` | No | `"acceptEdits"` | Permission mode |
| `defaults.timeout_minutes` | No | `30` | Per-team timeout |
| `teams[].name` | Yes | -- | Unique team identifier |
| `teams[].lead.role` | Yes | -- | Team lead role description |
| `teams[].lead.model` | No | project default | Model override |
| `teams[].members` | No | `[]` | Team member list |
| `teams[].tasks` | Yes | -- | At least one task |
| `teams[].depends_on` | No | `[]` | Team name dependencies |
| `teams[].context` | No | `nil` | Additional prompt context |

## Architecture

Cortex is structured around several key subsystems:

### Supervision Tree

```
Cortex.Supervisor (one_for_one)
  |-- Phoenix.PubSub (Cortex.PubSub)
  |-- Registry (Cortex.Agent.Registry)
  |-- DynamicSupervisor (Cortex.Agent.Supervisor)
  |-- Task.Supervisor (Cortex.Tool.Supervisor)
  |-- Cortex.Tool.Registry (Agent)
  |-- Cortex.Repo (Ecto)
  |-- Cortex.Store.EventSink (GenServer)
  |-- CortexWeb.Endpoint (Phoenix)
```

### Agent System (`lib/cortex/agent/`)

Each agent is a GenServer process registered by UUID. Agents have a lifecycle (idle -> running -> done/failed) and broadcast events via PubSub. The DynamicSupervisor manages agent lifecycles with `:one_for_one` restart strategy.

### DAG Orchestration (`lib/cortex/orchestration/`)

The orchestration engine loads YAML configs, builds a dependency DAG using Kahn's algorithm, and executes teams in parallel tiers. Each team spawns an external `claude -p` process via Erlang ports, collects NDJSON output, and records results. A file-based workspace (`.cortex/` directory) tracks state, results, and logs.

### Gossip Protocol (`lib/cortex/gossip/`)

Agents in gossip mode each have a KnowledgeStore (GenServer) holding entries with vector clocks. The gossip protocol performs push-pull exchanges: agents compare digests, identify missing/newer entries, and merge. Three topology strategies are supported: full mesh, ring, and random-k.

### Web Dashboard (`lib/cortex_web/`)

Phoenix LiveView provides a real-time dashboard for monitoring runs, viewing DAG visualizations, and inspecting team results. The dashboard subscribes to PubSub events for live updates.

### Persistence (`lib/cortex/store/`)

Ecto with SQLite stores run history, team results, and event logs. The EventSink GenServer subscribes to PubSub and persists all events automatically.

## Running the Dashboard

```bash
mix phx.server
```

The dashboard is available at `http://localhost:4000` and includes:

- **Dashboard** -- overview of system status and recent runs
- **Run List** -- history of all orchestration runs
- **Run Detail** -- per-run DAG visualization, team statuses, cost breakdown
- **Team Detail** -- individual team results, logs, and metrics
- **New Run** -- launch a new orchestration from the web UI

## Running Tests

```bash
# All tests
mix test

# Verbose output
mix test --trace

# Specific directory
mix test test/cortex/agent/
mix test test/cortex/gossip/
mix test test/cortex/orchestration/

# With coverage
mix test --cover
```

## Benchmarks

```bash
mix run bench/agent_bench.exs    # Agent lifecycle benchmarks
mix run bench/gossip_bench.exs   # Gossip protocol benchmarks
mix run bench/dag_bench.exs      # DAG engine benchmarks
```

## Development

```bash
# Format code
mix format

# Check formatting (CI)
mix format --check-formatted

# Compile with warnings as errors (CI)
mix compile --warnings-as-errors
```

## Project Structure

```
cortex/
  bench/                          # Benchee benchmark scripts
  config/                         # Environment configs
  lib/
    cortex/
      agent/                      # Agent GenServer, Config, State, Registry
      gossip/                     # KnowledgeStore, Protocol, VectorClock, Topology
      orchestration/              # Runner, DAG, Spawner, Workspace, Config
      perf/                       # Profiler utilities
      store/                      # Ecto schemas, EventSink
      tool/                       # Tool behaviour, executor, registry
      application.ex              # OTP application and supervision tree
      events.ex                   # PubSub event broadcasting
      health.ex                   # System health checks
      logger.ex                   # Structured logging wrapper
      telemetry.ex                # Telemetry event definitions
    cortex_web/
      components/                 # Phoenix components (core, DAG)
      controllers/                # Error handlers
      live/                       # LiveView modules (dashboard, runs, teams)
      endpoint.ex                 # Phoenix endpoint
      router.ex                   # Route definitions
  priv/
    repo/migrations/              # Ecto migrations
  test/                           # Test suite (mirrors lib/ structure)
```
