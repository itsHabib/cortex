defmodule Cortex.Gossip.KnowledgeStore do
  @moduledoc """
  GenServer holding the local knowledge base for a single gossip agent.

  Each agent in gossip mode gets its own `KnowledgeStore` process that manages
  knowledge entries. The store supports CRDT-style merge semantics using vector
  clocks for conflict resolution during gossip exchanges.

  ## Merge Logic

  When merging a remote entry with a local entry that has the same ID:

    1. If local doesn't exist -- accept remote entry
    2. If remote dominates local -- accept remote entry
    3. If local dominates remote -- keep local entry
    4. If concurrent -- keep the entry with higher confidence; break ties by later timestamp

  """

  use GenServer

  alias Cortex.Gossip.Entry
  alias Cortex.Gossip.VectorClock

  @type state :: %{
          entries: %{String.t() => Entry.t()},
          agent_id: String.t()
        }

  # --- Client API ---

  @doc """
  Starts a KnowledgeStore GenServer.

  ## Options

    - `:agent_id` (required) — the owning agent's ID
    - `:name` — optional GenServer name for registration

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, agent_id, gen_opts)
  end

  @doc """
  Adds or updates an entry in the knowledge store.

  The entry is stored by its `id`. If an entry with the same `id` already
  exists, the merge logic determines which version to keep.
  """
  @spec put(GenServer.server(), Entry.t()) :: :ok
  def put(server, %Entry{} = entry) do
    GenServer.call(server, {:put, entry})
  end

  @doc """
  Retrieves an entry by its ID.

  Returns `{:ok, entry}` if found, or `:not_found` if no entry with that ID exists.
  """
  @spec get(GenServer.server(), String.t()) :: {:ok, Entry.t()} | :not_found
  def get(server, entry_id) do
    GenServer.call(server, {:get, entry_id})
  end

  @doc """
  Returns all entries in the knowledge store.
  """
  @spec all(GenServer.server()) :: [Entry.t()]
  def all(server) do
    GenServer.call(server, :all)
  end

  @doc """
  Returns all entries matching the given topic.
  """
  @spec by_topic(GenServer.server(), String.t()) :: [Entry.t()]
  def by_topic(server, topic) do
    GenServer.call(server, {:by_topic, topic})
  end

  @doc """
  Returns the digest of the knowledge store: a list of `{entry_id, vector_clock}` pairs.

  Used during gossip exchanges to compare knowledge state without transferring full entries.
  """
  @spec digest(GenServer.server()) :: [{String.t(), VectorClock.t()}]
  def digest(server) do
    GenServer.call(server, :digest)
  end

  @doc """
  Merges a list of remote entries into the local knowledge store.

  Uses vector clock comparison for conflict resolution. See module docs for merge logic.
  """
  @spec merge(GenServer.server(), [Entry.t()]) :: :ok
  def merge(server, entries) when is_list(entries) do
    GenServer.call(server, {:merge, entries})
  end

  @doc """
  Returns entries for a list of IDs. Entries not found are silently skipped.
  """
  @spec entries_for_ids(GenServer.server(), [String.t()]) :: [Entry.t()]
  def entries_for_ids(server, ids) when is_list(ids) do
    GenServer.call(server, {:entries_for_ids, ids})
  end

  @doc """
  Returns the number of entries in the store.
  """
  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server) do
    GenServer.call(server, :size)
  end

  # --- Server Callbacks ---

  @impl true
  def init(agent_id) do
    {:ok, %{entries: %{}, agent_id: agent_id}}
  end

  @impl true
  def handle_call({:put, %Entry{} = entry}, _from, state) do
    new_entries = merge_entry(state.entries, entry)
    {:reply, :ok, %{state | entries: new_entries}}
  end

  @impl true
  def handle_call({:get, entry_id}, _from, state) do
    case Map.get(state.entries, entry_id) do
      nil -> {:reply, :not_found, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, Map.values(state.entries), state}
  end

  @impl true
  def handle_call({:by_topic, topic}, _from, state) do
    entries =
      state.entries
      |> Map.values()
      |> Enum.filter(&(&1.topic == topic))

    {:reply, entries, state}
  end

  @impl true
  def handle_call(:digest, _from, state) do
    digest =
      state.entries
      |> Enum.map(fn {id, entry} -> {id, entry.vector_clock} end)

    {:reply, digest, state}
  end

  @impl true
  def handle_call({:merge, remote_entries}, _from, state) do
    new_entries =
      Enum.reduce(remote_entries, state.entries, fn entry, acc ->
        merge_entry(acc, entry)
      end)

    {:reply, :ok, %{state | entries: new_entries}}
  end

  @impl true
  def handle_call({:entries_for_ids, ids}, _from, state) do
    entries =
      ids
      |> Enum.map(&Map.get(state.entries, &1))
      |> Enum.reject(&is_nil/1)

    {:reply, entries, state}
  end

  @impl true
  def handle_call(:size, _from, state) do
    {:reply, map_size(state.entries), state}
  end

  # --- Private Helpers ---

  # Merges a single entry into the entries map using vector clock comparison.
  @spec merge_entry(%{String.t() => Entry.t()}, Entry.t()) :: %{String.t() => Entry.t()}
  defp merge_entry(entries, %Entry{id: id} = remote) do
    case Map.get(entries, id) do
      nil ->
        # No local entry -- accept remote
        Map.put(entries, id, remote)

      local ->
        winner = resolve_conflict(local, remote)
        Map.put(entries, id, winner)
    end
  end

  # Resolves a conflict between a local and remote entry using vector clocks.
  @spec resolve_conflict(Entry.t(), Entry.t()) :: Entry.t()
  defp resolve_conflict(local, remote) do
    case VectorClock.compare(local.vector_clock, remote.vector_clock) do
      :equal ->
        # Identical causal history -- keep local
        local

      :after ->
        # Local dominates -- keep local
        local

      :before ->
        # Remote dominates -- accept remote
        remote

      :concurrent ->
        # Concurrent -- tiebreak by confidence, then timestamp
        resolve_concurrent(local, remote)
    end
  end

  # Tiebreaker for concurrent entries: higher confidence wins,
  # then later timestamp, then keep local as final fallback.
  @spec resolve_concurrent(Entry.t(), Entry.t()) :: Entry.t()
  defp resolve_concurrent(local, remote) do
    cond do
      remote.confidence > local.confidence -> remote
      local.confidence > remote.confidence -> local
      compare_timestamps(remote.timestamp, local.timestamp) == :gt -> remote
      true -> local
    end
  end

  # Compares two timestamps, handling nil values (nil is treated as earliest).
  @spec compare_timestamps(DateTime.t() | nil, DateTime.t() | nil) :: :gt | :lt | :eq
  defp compare_timestamps(nil, nil), do: :eq
  defp compare_timestamps(nil, _), do: :lt
  defp compare_timestamps(_, nil), do: :gt
  defp compare_timestamps(a, b), do: DateTime.compare(a, b)
end
