# Phase 7: Gossip + Advanced — Summary

> 485 tests, 0 failures (+105 new). Cortex now has two coordination modes.

## What Was Built

Phase 7 adds the **gossip protocol** — a second way for agents to coordinate. While DAG orchestration (Phase 3) is for structured projects ("build this app"), gossip is for open-ended exploration ("research this market").

### How Gossip Works (Plain English)

Imagine 5 researchers in a room, each investigating a different angle of the same topic. Periodically, two researchers meet and share notes. After enough rounds of sharing, everyone has everyone else's findings — even if they never met directly. That's gossip.

### The Components

#### Vector Clocks (`vector_clock.ex`)
A way to track "who knew what when" without a central clock. Each agent keeps a counter. When they create or update knowledge, they bump their counter. When comparing two versions of the same knowledge:
- If A's counters are all ≥ B's → A is newer
- If B's ≥ A's → B is newer
- If mixed (A ahead on some, B on others) → they're **concurrent** (conflict)

This is the same technique used by Amazon DynamoDB, Riak, and other distributed databases.

#### Knowledge Entries (`entry.ex`)
A piece of knowledge an agent discovered:
- `topic` — what it's about ("market_research", "competitor_analysis")
- `content` — the actual finding (text)
- `source` — which agent found it
- `confidence` — how sure the agent is (0.0 to 1.0)
- `vector_clock` — version tracking

#### Knowledge Store (`knowledge_store.ex`)
Each agent's local database of everything they know. A GenServer that supports:
- **Put** — add new knowledge (auto-increments vector clock)
- **Get/Query** — look up by ID or filter by topic
- **Digest** — produce a summary of "what I know" for gossip exchange
- **Merge** — accept incoming knowledge from another agent, resolve conflicts

**Conflict resolution:** When two agents have different versions of the same entry:
- If one is clearly newer (vector clock dominates) → take the newer one
- If they're concurrent → keep the one with higher confidence, break ties by timestamp

#### Gossip Protocol (`protocol.ex`)
The push-pull exchange between two agents:
1. Both share their digest ("here's what I know and what version")
2. Compare: find what each side is missing or has an older version of
3. Send the missing/newer entries in both directions
4. Both merge what they received

One exchange takes milliseconds. After enough rounds, all agents converge to the same knowledge.

#### Topology (`topology.ex`)
Who talks to whom. Three strategies:
- **Full mesh** — everyone talks to everyone (fast convergence, lots of messages)
- **Ring** — each agent only talks to neighbors (slow convergence, few messages)
- **Random** — each agent has a few random peers (good balance — used in real systems like Cassandra)

#### Gossip Runner (`runner.ex`)
Orchestrates a complete gossip session:
1. Start knowledge stores for each agent
2. Give each agent some initial knowledge to explore from
3. Run N rounds of gossip exchanges based on the topology
4. Collect all knowledge from all agents
5. Return the merged, deduplicated knowledge base

### Example

```elixir
# 3 agents, each starts with different knowledge
results = Cortex.Gossip.Runner.run(
  agents: [
    %{id: "alice", name: "Alice", role: "researcher"},
    %{id: "bob", name: "Bob", role: "analyst"},
    %{id: "carol", name: "Carol", role: "strategist"}
  ],
  seed_knowledge: %{
    "alice" => [%{topic: "market", content: "Market is $2B"}],
    "bob" => [%{topic: "competitors", content: "3 main players"}],
    "carol" => [%{topic: "strategy", content: "Go after SMB first"}]
  },
  rounds: 5,
  topology: :full_mesh
)
# After 5 rounds, all 3 agents have all 3 pieces of knowledge
```

### What's Next

Phase 9 (Performance) will benchmark the gossip convergence rate and optimize for larger agent counts. The gossip protocol pairs naturally with the DAG engine — you could use DAG for the structured build and gossip for the research/exploration phase that precedes it.
