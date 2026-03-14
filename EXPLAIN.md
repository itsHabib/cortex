# Cortex -- Technical Deep Dive

This document explains the engineering behind Cortex for developers who want to understand, extend, or debug the system.

## Supervision Tree

Cortex uses a single top-level `one_for_one` supervisor (`Cortex.Supervisor`). Children are started in dependency order:

1. **Phoenix.PubSub** -- started first because agents broadcast events during init. Named `Cortex.PubSub`.
2. **Registry** -- started before DynamicSupervisor because agents register via `via_tuple` during init. Named `Cortex.Agent.Registry`, uses `:unique` keys.
3. **DynamicSupervisor** -- manages agent GenServer processes. Named `Cortex.Agent.Supervisor`, uses `one_for_one` strategy with `:temporary` restart (agents don't auto-restart).
4. **Task.Supervisor** -- manages sandboxed tool execution tasks. Named `Cortex.Tool.Supervisor`.
5. **Tool.Registry** -- Agent process holding the `tool_name => module` lookup map.
6. **Cortex.Repo** -- Ecto repository for SQLite persistence.
7. **Cortex.Store.EventSink** -- GenServer that subscribes to PubSub and persists all events to the database.
8. **CortexWeb.Endpoint** -- Phoenix endpoint for the LiveView dashboard.

The `one_for_one` strategy means if any child crashes, only that child restarts. This is important: a crashing agent does not take down PubSub or the database. The EventSink subscribes to PubSub in its `init/1`, so if PubSub restarts, EventSink will also need to restart (the supervisor handles this because PubSub is started before EventSink).

### Why `:temporary` restart for agents

Agent GenServers use `restart: :temporary` because agent crashes are expected (LLM timeouts, bad tool executions, etc.) and the orchestration layer handles retries at a higher level. Automatic restarts would create confusing duplicate agents.

## DAG Orchestration Flow

### Config Loading

1. `Config.Loader.load/1` reads a YAML file via `yaml_elixir`
2. Raw YAML maps are converted to typed structs: `Config`, `Team`, `Lead`, `Member`, `Task`, `Defaults`
3. `Config.Validator.validate/1` checks: non-empty name, at least one team, valid team names, valid dependencies (no references to non-existent teams), unique team names

### DAG Construction (Kahn's Algorithm)

`DAG.build_tiers/1` takes a list of team structs and produces execution tiers:

1. **Validate dependencies** -- ensure all `depends_on` references point to teams that exist in the config
2. **Build adjacency list** -- `dependency => [list of dependents]`
3. **Compute in-degree** -- for each team, count its dependencies
4. **Seed queue** -- teams with in-degree 0 (no dependencies) form the first tier
5. **Process tiers** -- for each tier:
   - The current queue becomes the tier (sorted alphabetically for determinism)
   - Decrement in-degree of all dependents
   - Teams whose in-degree reaches 0 join the next tier's queue
6. **Cycle detection** -- if total teams processed < total teams, a cycle exists

Time complexity: O(V + E) where V = teams, E = dependency edges.

### Execution

`Runner.run/2` orchestrates the full flow:

1. Load config and build tiers
2. Initialize workspace (`.cortex/` directory with `state.json`, `registry.json`, `results/`, `logs/`)
3. Broadcast `:run_started`
4. For each tier:
   - Read shared state once (for prompt context injection)
   - Mark all teams as "running"
   - Spawn all teams as parallel `Task.async` calls
   - Each task builds a prompt, calls `Spawner.spawn/1`, returns an outcome tuple
   - `Task.await_many/2` waits for all (60-minute timeout per task)
   - Apply outcomes to workspace sequentially (avoids read-modify-write races on `state.json`)
   - If any team failed and `continue_on_error` is false, halt
5. Broadcast `:run_completed`
6. Build and return summary

### Prompt Injection

Each team's prompt is built from:
- Role and project context
- Team-specific context string
- Numbered task list with details, deliverables, and verify commands
- Upstream results: for each dependency, inject the result summary from shared state
- Team member descriptions (if the team has members)
- Standard instructions footer

### Spawner

The spawner opens an Erlang port to `claude -p` with `--output-format stream-json`. It:
- Collects stdout data, buffering partial lines
- Parses each complete line as NDJSON
- Extracts the `session_id` from `"type": "system"` init messages
- Captures the final `"type": "result"` line
- Optionally streams raw output to a log file
- Enforces a timeout by scheduling `Process.send_after` and killing the port on timeout

## Gossip Protocol and Convergence

### Knowledge Model

Each gossip agent has a `KnowledgeStore` GenServer holding entries in a `%{entry_id => Entry.t()}` map. Each `Entry` has:
- A unique UUID
- A topic and content
- A source agent ID
- A confidence score (0.0 to 1.0)
- A timestamp
- A vector clock for causal ordering

### Vector Clocks

Vector clocks are maps of `node_id => counter`. Each agent increments its own counter when creating/updating entries. Clocks are compared to determine causal relationships:

- **equal** -- identical counters on all nodes
- **before** -- vc_a is dominated by vc_b (all of a's counters <= b's, at least one <)
- **after** -- vc_a dominates vc_b
- **concurrent** -- neither dominates (conflict)

### Push-Pull Exchange

`Protocol.exchange/2` synchronizes two stores in one round-trip:

1. Get digests from both stores: `[{entry_id, vector_clock}]`
2. Diff digests to find what each side needs:
   - If A doesn't have an entry B has: A needs it
   - If B's version dominates A's: A needs B's version
   - If concurrent: both sides need each other's version (merge will resolve via tiebreaker)
3. Fetch needed entries from each side
4. Merge into each store

### Conflict Resolution

When merging a remote entry with a local entry sharing the same ID:

1. Remote dominates local (`:before`) -- accept remote
2. Local dominates remote (`:after`) -- keep local
3. Equal -- keep local (no-op)
4. Concurrent -- tiebreak by higher confidence, then later timestamp, then keep local

This is a last-writer-wins CRDT with confidence-weighted tiebreaking.

### Topology Strategies

The `Topology` module determines which agents peer with which:

- **Full mesh** -- every agent peers with every other. Fastest convergence, O(n^2) exchanges per round.
- **Ring** -- each agent peers with its two neighbors. Slowest convergence, O(n) exchanges per round.
- **Random-k** -- each agent peers with k random others. Good balance. Default k=3.

The `Runner` drives gossip rounds: in each round, each agent picks a random peer from its topology and performs an exchange. Pairs are deduplicated to avoid redundant exchanges.

### Convergence

With n agents and a full-mesh topology, convergence is typically achieved in O(log n) rounds. With ring topology, it takes O(n) rounds. The gossip runner runs a configurable number of rounds, after which it collects all unique entries across all stores.

## LiveView Real-Time Updates

The dashboard uses Phoenix LiveView with PubSub integration:

1. LiveView mounts and subscribes to `"cortex:events"` topic
2. When events arrive (agent started, run completed, etc.), `handle_info/2` updates assigns
3. LiveView re-renders only the changed portions of the DOM

### DAG Visualization

`DagComponents` renders the DAG as an SVG. `DagLayout` computes node positions:
- Each tier gets a vertical layer
- Teams within a tier are spaced horizontally
- Dependency edges are drawn as SVG paths between nodes
- Node colors reflect status (pending, running, done, failed)

## Key Engineering Decisions and Tradeoffs

### File-based workspace vs. database-only state

The workspace uses JSON files (`.cortex/state.json`, etc.) rather than the database for run state. This was chosen because:
- Workspace state changes rapidly during a run (every team update)
- File-based state is inspectable with standard tools (`cat`, `jq`)
- The database stores the durable event log; the workspace is ephemeral per-run

Tradeoff: concurrent writes to `state.json` require sequential application in the runner. This is fine because the runner already sequences tier processing.

### Erlang ports vs. HTTP client for LLM

Cortex uses Erlang ports to spawn `claude -p` processes rather than making HTTP API calls directly. This was chosen because:
- `claude` CLI handles authentication, retries, and stream parsing
- Port-based spawning isolates each team's execution
- The CLI's NDJSON stream provides progress events naturally

Tradeoff: more overhead per spawn (process startup), less control over retry logic, requires `claude` CLI to be installed.

### GenServer per knowledge store vs. ETS

Each gossip agent has its own GenServer process holding entries in a map. An alternative would be a shared ETS table. The GenServer approach was chosen because:
- Process isolation matches the agent mental model
- Serialized access prevents race conditions during merge
- Message passing between stores during gossip exchange is natural

Tradeoff: GenServer mailbox can become a bottleneck with very high exchange rates. For production scale (1000+ agents), ETS-backed stores would be worth benchmarking.

### SQLite vs. PostgreSQL

SQLite was chosen for the persistence layer because:
- Zero-dependency setup (no external database server)
- Single-file database is easy to inspect and distribute
- WAL mode handles concurrent reads well
- Sufficient for the scale Cortex targets (hundreds of runs, not millions)

Tradeoff: no concurrent write scaling, no distributed replication. For multi-node Cortex deployments, PostgreSQL would be needed.

## Performance Characteristics

- **Agent start/stop**: sub-millisecond (GenServer.start_link + Registry.register)
- **DAG tier building (100 teams)**: microseconds (Kahn's algorithm is O(V+E))
- **Config parsing (50 teams)**: ~1ms (YAML parse + struct construction + validation)
- **Gossip exchange (100 entries per store)**: sub-millisecond (digest diff + entry transfer)
- **Knowledge store merge (1000 entries)**: low milliseconds (vector clock comparison per entry)
- **Vector clock compare (100 nodes)**: microseconds (map comparison)

The critical path in a DAG run is the spawner: each team waits for `claude -p` to complete, which typically takes minutes. The overhead of DAG construction, prompt building, and state management is negligible compared to LLM execution time.

Benchmarks are available in `bench/` and can be run with:
```bash
mix run bench/agent_bench.exs
mix run bench/gossip_bench.exs
mix run bench/dag_bench.exs
```
