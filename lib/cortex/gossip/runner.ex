defmodule Cortex.Gossip.Runner do
  @moduledoc """
  Orchestrates a gossip exploration session.

  The runner manages the full lifecycle of a gossip-based coordination session:

  1. Start KnowledgeStores for each agent
  2. Distribute seed knowledge across agents
  3. Run gossip rounds — in each round, select pairs based on topology and exchange
  4. After all rounds, collect and return the merged knowledge base

  ## Example

      {:ok, results} = Cortex.Gossip.Runner.run(
        agents: ["researcher_a", "researcher_b", "researcher_c"],
        rounds: 10,
        topology: :full_mesh,
        seed_knowledge: [
          %{agent_id: "researcher_a", entries: [entry_1, entry_2]},
          %{agent_id: "researcher_b", entries: [entry_3]}
        ]
      )

  """

  alias Cortex.Gossip.Entry
  alias Cortex.Gossip.KnowledgeStore
  alias Cortex.Gossip.Protocol
  alias Cortex.Gossip.Topology

  @type agent_seed :: %{agent_id: String.t(), entries: [Entry.t()]}

  @type result :: %{
          entries: [Entry.t()],
          rounds_completed: non_neg_integer(),
          agent_count: non_neg_integer(),
          topology_strategy: Topology.strategy()
        }

  @doc """
  Runs a gossip exploration session.

  ## Options

    - `:agents` (required) — list of agent ID strings
    - `:rounds` — number of gossip rounds (default 10)
    - `:topology` — topology strategy (default `:full_mesh`)
    - `:topology_opts` — keyword options for topology (e.g., `[k: 3]`)
    - `:seed_knowledge` — list of `%{agent_id: String.t(), entries: [Entry.t()]}` maps

  ## Returns

    - `{:ok, result}` with merged knowledge and session metadata
    - `{:error, reason}` on failure

  """
  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts) do
    agent_ids = Keyword.fetch!(opts, :agents)
    rounds = Keyword.get(opts, :rounds, 10)
    topology_strategy = Keyword.get(opts, :topology, :full_mesh)
    topology_opts = Keyword.get(opts, :topology_opts, [])
    seed_knowledge = Keyword.get(opts, :seed_knowledge, [])

    if agent_ids == [] do
      {:error, :no_agents}
    else
      run_session(agent_ids, rounds, topology_strategy, topology_opts, seed_knowledge)
    end
  end

  # --- Private Implementation ---

  @spec run_session(
          [String.t()],
          non_neg_integer(),
          Topology.strategy(),
          keyword(),
          [agent_seed()]
        ) :: {:ok, result()}
  defp run_session(agent_ids, rounds, topology_strategy, topology_opts, seed_knowledge) do
    # Step 1: Start KnowledgeStores for each agent
    stores = start_stores(agent_ids)

    try do
      # Step 2: Distribute seed knowledge
      distribute_seeds(stores, seed_knowledge)

      # Step 3: Build topology
      topology = Topology.build(agent_ids, topology_strategy, topology_opts)

      # Step 4: Run gossip rounds
      run_rounds(stores, topology, rounds)

      # Step 5: Collect results
      all_entries = collect_all_entries(stores)

      {:ok,
       %{
         entries: all_entries,
         rounds_completed: rounds,
         agent_count: length(agent_ids),
         topology_strategy: topology_strategy
       }}
    after
      # Clean up stores
      stop_stores(stores)
    end
  end

  @spec start_stores([String.t()]) :: %{String.t() => pid()}
  defp start_stores(agent_ids) do
    Map.new(agent_ids, fn agent_id ->
      {:ok, pid} = KnowledgeStore.start_link(agent_id: agent_id)
      {agent_id, pid}
    end)
  end

  @spec stop_stores(%{String.t() => pid()}) :: :ok
  defp stop_stores(stores) do
    Enum.each(stores, fn {_id, pid} ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)
  end

  @spec distribute_seeds(%{String.t() => pid()}, [agent_seed()]) :: :ok
  defp distribute_seeds(stores, seed_knowledge) do
    Enum.each(seed_knowledge, fn %{agent_id: agent_id, entries: entries} ->
      case Map.get(stores, agent_id) do
        nil -> :ok
        pid -> Enum.each(entries, &KnowledgeStore.put(pid, &1))
      end
    end)
  end

  @spec run_rounds(
          %{String.t() => pid()},
          %{String.t() => [String.t()]},
          non_neg_integer()
        ) :: :ok
  defp run_rounds(stores, topology, rounds) do
    Enum.each(1..max(rounds, 1)//1, fn _round ->
      pairs = select_pairs(topology)

      Enum.each(pairs, fn {agent_a, agent_b} ->
        store_a = Map.fetch!(stores, agent_a)
        store_b = Map.fetch!(stores, agent_b)
        Protocol.exchange(store_a, store_b)
      end)
    end)
  end

  # Selects pairs of agents for gossip exchange based on the topology.
  # Each agent picks one random peer from its peer list.
  # Deduplicates so we don't exchange twice between the same pair in one round.
  @spec select_pairs(%{String.t() => [String.t()]}) :: [{String.t(), String.t()}]
  defp select_pairs(topology) do
    topology
    |> Enum.flat_map(fn {agent_id, peers} ->
      case peers do
        [] -> []
        peers -> [{agent_id, Enum.random(peers)}]
      end
    end)
    |> Enum.map(fn {a, b} -> if a < b, do: {a, b}, else: {b, a} end)
    |> Enum.uniq()
  end

  @spec collect_all_entries(%{String.t() => pid()}) :: [Entry.t()]
  defp collect_all_entries(stores) do
    stores
    |> Enum.flat_map(fn {_id, pid} -> KnowledgeStore.all(pid) end)
    |> Enum.uniq_by(& &1.id)
  end
end
