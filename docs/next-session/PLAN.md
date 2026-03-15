# Next Session Plan: Gossip LiveView + Dynamic Cluster Join

## Context for Claude

Cortex is at `/Users/michaelhabib/dev/teams-sbx/cortex/` — its own git repo. Elixir/OTP multi-agent orchestration system with two coordination modes:

1. **DAG mode** (working, e2e tested) — structured projects with tiers and dependencies
2. **Gossip mode** (working, tested) — peer agents explore topics, exchange findings via gossip protocol with real `claude -p` processes

653 tests, 0 failures. The user has zero Elixir experience — Claude drives all technical decisions.

Read `CLAUDE.md` and `PROJECT.md` in the project root for full context.

### What Was Built Last Session

- **Observability wired up**: Telemetry emissions in runner.ex + coordinator.ex, CortexWeb.Telemetry for LiveDashboard, `/health/live` + `/health/ready` endpoints, Prometheus `/metrics` endpoint, infra/docker-compose.yml with Prometheus + Grafana + pre-built dashboard
- **Fixes**: Flaky spawner timeout test, DB files removed from git, tailwind warning fixed, runner now uses Injection module (agents get `/loop` inbox polling instructions)
- **Gossip cluster_context**: New field in gossip.yaml — every agent gets a "welcome to the cluster" introduction with context + list of all peers
- **Gossip agents get /loop**: Agents now set up `/loop 2m cat <inbox_path>` to poll for knowledge from other agents
- **Makefile**: `make up`, `make test`, `make check`, `make run CONFIG=...`, etc.

---

## Priority 1: Gossip LiveView — Mesh Visualization

### The Problem

The existing LiveView pages show DAG-style tier visualizations (run_detail_live.ex + dag_components.ex). Gossip mode has no visualization. When a gossip session runs, there's no way to see:
- Which agents are active
- Knowledge flowing between them
- How many findings each agent has produced
- Exchange rounds happening in real-time

### What to Build

A new LiveView page at `/gossip/:id` (or extend the existing run detail page with a gossip tab) that shows:

#### Core: Mesh Graph (SVG)
- Agents rendered as **nodes in a mesh** (not tiers — circular or force-directed layout)
- Edges between nodes based on the gossip topology (full_mesh, ring, random)
- Edges animate/pulse when an exchange happens between two agents
- Node color reflects status: researching (blue), exchanging (yellow), done (green), stuck (red)
- Node size or badge shows finding count

#### Side Panel: Knowledge Stream
- Live feed of knowledge entries as they're discovered
- Each entry shows: source agent, topic, content snippet, confidence, timestamp
- Filterable by agent or topic

#### Stats Bar
- Total findings across all agents
- Exchange rounds completed / total
- Per-agent finding counts
- Total cost so far

### How It Should Work

1. **PubSub events** — The coordinator already broadcasts `:gossip_started`, `:gossip_completed`, `:gossip_round_completed`. Add more granular events:
   - `:gossip_exchange` — when two agents exchange (with agent names + entry counts)
   - `:gossip_finding` — when a new finding is ingested from an agent
   - `:gossip_agent_status` — agent started/completed/failed

2. **LiveView subscribes** to these events and updates the mesh in real-time

3. **Layout algorithm** — For the mesh layout, use a simple circular layout (agents evenly spaced on a circle) since gossip clusters are typically small (3-8 agents). No need for force-directed physics.

4. **SVG components** — Similar pattern to `dag_components.ex` but with:
   - `mesh_graph` — circular node layout with edge lines
   - `agent_node` — circle (not rectangle) with name + finding count
   - `exchange_edge` — line between nodes, animatable via CSS

### Suggested File Structure

```
lib/cortex_web/
  live/gossip_live.ex              # LiveView page
  components/mesh_components.ex    # SVG mesh components
  live/helpers/mesh_layout.ex      # Circular layout calculator
```

Add route: `live("/gossip/:id", GossipLive, :show)` in router.ex

### What Exists Already

- `lib/cortex_web/components/dag_components.ex` — SVG component pattern to follow
- `lib/cortex_web/live/helpers/dag_layout.ex` — layout calculator pattern to follow
- `lib/cortex_web/live/run_detail_live.ex` — existing run detail page (subscribe to events, update assigns)
- `lib/cortex/gossip/coordinator.ex` — already has `broadcast/2` calls for gossip events
- `lib/cortex/gossip/topology.ex` — builds topology maps (who's connected to who)

---

## Priority 2: Dynamic Cluster Join

### The Problem

Currently, all gossip agents are defined in the YAML upfront and spawned simultaneously. You can't add a new agent to a running gossip cluster. This limits the usefulness — you might realize mid-session that you need a specialist agent, or want to scale up the cluster.

### What to Build

#### 2a. Coordinator as a Long-Running GenServer

Currently `Cortex.Gossip.SessionRunner` is a module with functions — not a GenServer. The `execute/2` function runs synchronously, blocking until all agents complete. To support dynamic join, the coordinator needs to become a GenServer that:

- Holds cluster state (stores, config, topology, active agents)
- Runs the exchange loop as a recurring `Process.send_after` (not a blocking `Enum.each` with `Process.sleep`)
- Accepts `join/2` calls to add new agents mid-run
- Handles agent completion asynchronously (via Task monitoring)

#### 2b. Join API

```elixir
# Add a new agent to a running cluster
Cortex.Gossip.SessionRunner.join(coordinator_pid, %{
  name: "new-specialist",
  topic: "pricing strategy",
  prompt: "Research pricing models for fitness apps..."
})
```

When an agent joins:
1. Create its KnowledgeStore
2. Seed it with current cluster knowledge (not just seed_knowledge — the FULL merged state)
3. Update the topology to include the new agent
4. Spawn the `claude -p` process with:
   - The `cluster_context` from config
   - A "## Current Cluster Knowledge" section with all findings so far
   - The standard inbox/findings/loop instructions
5. Broadcast `:gossip_agent_joined` event (LiveView updates mesh)

#### 2c. Mix Task / API Endpoint

Provide a way to trigger join:
- `mix cortex.join --cluster <name> --agent-config <path>` — CLI
- `POST /api/gossip/:id/agents` — HTTP API for the web UI
- A "Join Agent" button on the Gossip LiveView page

#### 2d. Knowledge Catch-Up

The critical piece: when a new agent joins round 3 of 5, it needs to know what the cluster has already discovered. The coordinator should:
1. Collect all entries from all stores
2. Deduplicate
3. Inject them into the new agent's KnowledgeStore
4. Write a summary to the new agent's inbox
5. Include a condensed version in the new agent's prompt

### Suggested Approach

1. First: Refactor SessionRunner to be a GenServer (2a) — this is the foundation
2. Then: Add `join/2` with knowledge catch-up (2b + 2d)
3. Then: Mix task + API endpoint (2c)
4. Then: Wire into Gossip LiveView (button + mesh update)

### What Exists Already

- `lib/cortex/gossip/coordinator.ex` — current synchronous coordinator (refactor target)
- `lib/cortex/gossip/knowledge_store.ex` — GenServer, already supports `start_link` + `put` + `all`
- `lib/cortex/gossip/topology.ex` — `build/2` takes agent names + strategy, returns topology map
- `lib/cortex/gossip/protocol.ex` — `exchange/2` works between any two stores
- `lib/cortex/gossip/config.ex` — has `cluster_context` field (added last session)

---

## Suggested Build Order

Do Priority 1 first (Gossip LiveView) since it's self-contained and gives you visibility into gossip runs. Then Priority 2 (Dynamic Join) which is more architectural.

For each priority: build directly, no planning phases needed. Run fully autonomous — no approval gates, handle everything end to end.
