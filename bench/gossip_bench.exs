# Gossip protocol benchmark suite
#
# Measures gossip exchange performance, convergence time, and
# knowledge store merge throughput.
#
# Run: mix run bench/gossip_bench.exs

alias Cortex.Gossip.Entry
alias Cortex.Gossip.KnowledgeStore
alias Cortex.Gossip.Protocol
alias Cortex.Gossip.VectorClock

defmodule GossipBenchHelper do
  @moduledoc false

  def make_entry(i, source) do
    Entry.new(
      topic: "bench-topic-#{rem(i, 10)}",
      content: "Knowledge entry #{i} from #{source}",
      source: source,
      confidence: :rand.uniform()
    )
  end

  def make_entries(count, source) do
    Enum.map(1..count, &make_entry(&1, source))
  end

  def start_store_with_entries(agent_id, entries) do
    {:ok, pid} = KnowledgeStore.start_link(agent_id: agent_id)
    Enum.each(entries, &KnowledgeStore.put(pid, &1))
    pid
  end

  def start_agents_with_unique_knowledge(count) do
    Enum.map(1..count, fn i ->
      agent_id = "gossip-bench-agent-#{i}"
      entries = make_entries(5, agent_id)
      pid = start_store_with_entries(agent_id, entries)
      {agent_id, pid}
    end)
  end

  def run_gossip_rounds(stores, rounds) do
    store_list = Map.to_list(stores)

    Enum.each(1..rounds, fn _round ->
      pairs = for {id_a, pid_a} <- store_list,
                  {id_b, pid_b} <- store_list,
                  id_a < id_b,
                  do: {pid_a, pid_b}

      # Pick random subset of pairs
      selected = Enum.take_random(pairs, max(div(length(pairs), 2), 1))
      Enum.each(selected, fn {a, b} -> Protocol.exchange(a, b) end)
    end)
  end
end

Benchee.run(
  %{
    "gossip exchange between 2 stores (empty)" => fn ->
      {:ok, a} = KnowledgeStore.start_link(agent_id: "bench-a")
      {:ok, b} = KnowledgeStore.start_link(agent_id: "bench-b")
      Protocol.exchange(a, b)
      GenServer.stop(a)
      GenServer.stop(b)
    end,
    "gossip exchange between 2 stores (100 entries each)" => {
      fn {a, b} ->
        Protocol.exchange(a, b)
      end,
      before_scenario: fn _ ->
        entries_a = GossipBenchHelper.make_entries(100, "agent-a")
        entries_b = GossipBenchHelper.make_entries(100, "agent-b")
        a = GossipBenchHelper.start_store_with_entries("agent-a", entries_a)
        b = GossipBenchHelper.start_store_with_entries("agent-b", entries_b)
        {a, b}
      end,
      after_scenario: fn {a, b} ->
        GenServer.stop(a)
        GenServer.stop(b)
      end
    },
    "knowledge store merge (100 entries)" => {
      fn {store, entries} ->
        KnowledgeStore.merge(store, entries)
      end,
      before_scenario: fn _ ->
        {:ok, store} = KnowledgeStore.start_link(agent_id: "merge-bench")
        entries = GossipBenchHelper.make_entries(100, "remote-agent")
        {store, entries}
      end,
      after_scenario: fn {store, _} -> GenServer.stop(store) end
    },
    "knowledge store merge (1000 entries)" => {
      fn {store, entries} ->
        KnowledgeStore.merge(store, entries)
      end,
      before_scenario: fn _ ->
        {:ok, store} = KnowledgeStore.start_link(agent_id: "merge-bench-1k")
        entries = GossipBenchHelper.make_entries(1000, "remote-agent")
        {store, entries}
      end,
      after_scenario: fn {store, _} -> GenServer.stop(store) end
    },
    "vector clock compare (10 nodes)" => fn ->
      vc_a = Enum.reduce(1..10, VectorClock.new(), fn i, vc ->
        VectorClock.increment(vc, "node-#{i}")
      end)
      vc_b = Enum.reduce(1..10, VectorClock.new(), fn i, vc ->
        VectorClock.increment(vc, "node-#{i}")
      end)
      VectorClock.compare(vc_a, vc_b)
    end,
    "vector clock compare (100 nodes)" => fn ->
      vc_a = Enum.reduce(1..100, VectorClock.new(), fn i, vc ->
        VectorClock.increment(vc, "node-#{i}")
      end)
      vc_b = Enum.reduce(1..100, VectorClock.new(), fn i, vc ->
        VectorClock.increment(vc, "node-#{i}")
      end)
      VectorClock.compare(vc_a, vc_b)
    end,
    "vector clock merge (100 nodes)" => fn ->
      vc_a = Enum.reduce(1..100, VectorClock.new(), fn i, vc ->
        VectorClock.increment(vc, "node-#{i}")
      end)
      vc_b = Enum.reduce(1..100, VectorClock.new(), fn i, vc ->
        VectorClock.increment(vc, "node-#{rem(i + 50, 100)}")
      end)
      VectorClock.merge(vc_a, vc_b)
    end,
    "digest building (1000 entries)" => {
      fn store ->
        KnowledgeStore.digest(store)
      end,
      before_scenario: fn _ ->
        entries = GossipBenchHelper.make_entries(1000, "digest-agent")
        GossipBenchHelper.start_store_with_entries("digest-agent", entries)
      end,
      after_scenario: fn store -> GenServer.stop(store) end
    }
  },
  warmup: 1,
  time: 5,
  memory_time: 2,
  print: [benchmarking: true, configuration: true]
)
