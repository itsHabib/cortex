defmodule Cortex.Gossip.VectorClock do
  @moduledoc """
  Vector clock implementation for causal ordering in gossip-based coordination.

  A vector clock is a map of `node_id => counter` that tracks causality across
  distributed agents. Each agent increments its own counter on local updates,
  and clocks are merged (element-wise max) during gossip exchanges.

  Vector clocks enable three-way comparison between knowledge entries:
  - **before/after** — one entry causally precedes the other
  - **concurrent** — entries were produced independently (conflict)
  - **equal** — entries have identical causal history
  """

  @type t :: %{String.t() => non_neg_integer()}

  @doc """
  Creates a new empty vector clock.

  ## Examples

      iex> Cortex.Gossip.VectorClock.new()
      %{}

  """
  @spec new() :: t()
  def new, do: %{}

  @doc """
  Increments the counter for `node_id` in the vector clock.

  If the node has no entry yet, it starts at 1.

  ## Parameters

    - `vc` — the current vector clock
    - `node_id` — the node whose counter to increment

  ## Examples

      iex> Cortex.Gossip.VectorClock.increment(%{}, "agent_a")
      %{"agent_a" => 1}

      iex> Cortex.Gossip.VectorClock.increment(%{"agent_a" => 2}, "agent_a")
      %{"agent_a" => 3}

  """
  @spec increment(t(), String.t()) :: t()
  def increment(vc, node_id) when is_map(vc) and is_binary(node_id) do
    Map.update(vc, node_id, 1, &(&1 + 1))
  end

  @doc """
  Merges two vector clocks by taking the element-wise maximum.

  For each node present in either clock, the result contains the higher counter.

  ## Parameters

    - `vc_a` — first vector clock
    - `vc_b` — second vector clock

  ## Examples

      iex> Cortex.Gossip.VectorClock.merge(%{"a" => 2, "b" => 1}, %{"a" => 1, "b" => 3})
      %{"a" => 2, "b" => 3}

  """
  @spec merge(t(), t()) :: t()
  def merge(vc_a, vc_b) when is_map(vc_a) and is_map(vc_b) do
    Map.merge(vc_a, vc_b, fn _key, v1, v2 -> max(v1, v2) end)
  end

  @doc """
  Compares two vector clocks for causal ordering.

  Returns:
    - `:equal` — both clocks are identical
    - `:before` — `vc_a` happened before `vc_b` (vc_b dominates vc_a)
    - `:after` — `vc_a` happened after `vc_b` (vc_a dominates vc_b)
    - `:concurrent` — neither dominates the other (conflict)

  ## Parameters

    - `vc_a` — first vector clock
    - `vc_b` — second vector clock

  """
  @spec compare(t(), t()) :: :equal | :before | :after | :concurrent
  def compare(vc_a, vc_b) when is_map(vc_a) and is_map(vc_b) do
    cond do
      vc_a == vc_b -> :equal
      dominates?(vc_b, vc_a) -> :before
      dominates?(vc_a, vc_b) -> :after
      true -> :concurrent
    end
  end

  @doc """
  Returns `true` if `vc_a` dominates `vc_b`.

  A vector clock dominates another when every entry in `vc_b` has a
  corresponding entry in `vc_a` that is greater than or equal, and
  the clocks are not equal.

  ## Parameters

    - `vc_a` — the potentially dominating vector clock
    - `vc_b` — the potentially dominated vector clock

  """
  @spec dominates?(t(), t()) :: boolean()
  def dominates?(vc_a, vc_b) when is_map(vc_a) and is_map(vc_b) do
    vc_a != vc_b &&
      all_keys(vc_a, vc_b)
      |> Enum.all?(fn key ->
        Map.get(vc_a, key, 0) >= Map.get(vc_b, key, 0)
      end)
  end

  # Returns all unique keys from both clocks.
  defp all_keys(vc_a, vc_b) do
    MapSet.union(
      MapSet.new(Map.keys(vc_a)),
      MapSet.new(Map.keys(vc_b))
    )
  end
end
