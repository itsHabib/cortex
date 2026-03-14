defmodule Cortex.Gossip.Protocol do
  @moduledoc """
  Push-pull gossip exchange between two `KnowledgeStore` processes.

  The protocol synchronizes knowledge between two stores in a single exchange:

  1. Get digests (list of `{entry_id, vector_clock}`) from both stores
  2. Diff the digests to determine what each side is missing or has newer
  3. Fetch the needed entries from each side
  4. Merge the received entries into each store

  After an exchange, both stores converge toward the same knowledge state.
  """

  alias Cortex.Gossip.KnowledgeStore
  alias Cortex.Gossip.VectorClock

  @doc """
  Performs a bidirectional gossip exchange between two `KnowledgeStore` processes.

  Both stores exchange digests, compute diffs, fetch missing/newer entries,
  and merge them. After a successful exchange, both stores have converged
  their knowledge.

  ## Parameters

    - `store_a` — the first KnowledgeStore (pid or name)
    - `store_b` — the second KnowledgeStore (pid or name)

  ## Returns

    - `:ok` on successful exchange

  """
  @spec exchange(GenServer.server(), GenServer.server()) :: :ok
  def exchange(store_a, store_b) do
    # Step 1: Get digests from both sides
    digest_a = KnowledgeStore.digest(store_a)
    digest_b = KnowledgeStore.digest(store_b)

    # Step 2: Diff the digests
    {needed_by_a, needed_by_b} = diff_digests(digest_a, digest_b)

    # Step 3: Fetch needed entries from each side
    entries_for_a = KnowledgeStore.entries_for_ids(store_b, needed_by_a)
    entries_for_b = KnowledgeStore.entries_for_ids(store_a, needed_by_b)

    # Step 4: Merge entries into each store
    if entries_for_a != [], do: KnowledgeStore.merge(store_a, entries_for_a)
    if entries_for_b != [], do: KnowledgeStore.merge(store_b, entries_for_b)

    :ok
  end

  # Compares two digests and returns {ids_needed_by_a, ids_needed_by_b}.
  #
  # An entry ID is "needed" by a store if:
  #   - The store doesn't have it at all
  #   - The other store's version dominates (is causally newer)
  #   - The versions are concurrent (merge will resolve via tiebreaker)
  @spec diff_digests(
          [{String.t(), VectorClock.t()}],
          [{String.t(), VectorClock.t()}]
        ) :: {[String.t()], [String.t()]}
  defp diff_digests(digest_a, digest_b) do
    map_a = Map.new(digest_a)
    map_b = Map.new(digest_b)

    all_ids =
      MapSet.union(
        MapSet.new(Map.keys(map_a)),
        MapSet.new(Map.keys(map_b))
      )

    Enum.reduce(all_ids, {[], []}, fn id, {needed_a, needed_b} ->
      vc_a = Map.get(map_a, id)
      vc_b = Map.get(map_b, id)

      case {vc_a, vc_b} do
        {nil, _vc_b} ->
          # A doesn't have it, needs it from B
          {[id | needed_a], needed_b}

        {_vc_a, nil} ->
          # B doesn't have it, needs it from A
          {needed_a, [id | needed_b]}

        {vc_a, vc_b} ->
          case VectorClock.compare(vc_a, vc_b) do
            :equal ->
              # Same version, no transfer needed
              {needed_a, needed_b}

            :before ->
              # A's version is older, A needs B's version
              {[id | needed_a], needed_b}

            :after ->
              # B's version is older, B needs A's version
              {needed_a, [id | needed_b]}

            :concurrent ->
              # Both sides should merge -- send to both for tiebreaker resolution
              {[id | needed_a], [id | needed_b]}
          end
      end
    end)
  end
end
