defmodule Cortex.Gossip.Topology do
  @moduledoc """
  Manages gossip topology -- which agents peer with which.

  Provides three topology strategies for structuring the gossip network:

    - `:full_mesh` — every agent peers with every other agent
    - `:ring` — each agent peers with its immediate neighbors (previous and next)
    - `:random` — each agent peers with `k` random others (default k=3)

  The topology is represented as a map of `agent_id => [peer_ids]`.
  """

  @type strategy :: :full_mesh | :ring | :random

  @doc """
  Builds a topology map for the given agent IDs using the specified strategy.

  ## Parameters

    - `agent_ids` — list of agent ID strings
    - `strategy` — one of `:full_mesh`, `:ring`, or `:random`
    - `opts` — keyword options (strategy-specific)
      - `:k` — number of random peers for `:random` strategy (default 3)

  ## Returns

  A map of `agent_id => [peer_ids]`.

  ## Examples

      iex> Cortex.Gossip.Topology.build(["a", "b", "c"], :full_mesh)
      %{"a" => ["b", "c"], "b" => ["a", "c"], "c" => ["a", "b"]}

  """
  @spec build([String.t()], strategy(), keyword()) :: %{String.t() => [String.t()]}
  def build(agent_ids, strategy, opts \\ [])

  def build([], _strategy, _opts), do: %{}
  def build([single], _strategy, _opts), do: %{single => []}

  def build(agent_ids, :full_mesh, _opts) do
    Map.new(agent_ids, fn id ->
      peers = Enum.reject(agent_ids, &(&1 == id))
      {id, peers}
    end)
  end

  def build(agent_ids, :ring, _opts) do
    count = length(agent_ids)
    indexed = Enum.with_index(agent_ids)

    Map.new(indexed, fn {id, idx} ->
      prev = Enum.at(agent_ids, rem(idx - 1 + count, count))
      next = Enum.at(agent_ids, rem(idx + 1, count))

      peers =
        [prev, next]
        |> Enum.uniq()
        |> Enum.reject(&(&1 == id))

      {id, peers}
    end)
  end

  def build(agent_ids, :random, opts) do
    k = Keyword.get(opts, :k, 3)

    Map.new(agent_ids, fn id ->
      others = Enum.reject(agent_ids, &(&1 == id))
      peers = Enum.take_random(others, min(k, length(others)))
      {id, peers}
    end)
  end
end
