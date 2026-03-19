defmodule CortexWeb.Live.Helpers.TopologyLayout do
  @moduledoc """
  Calculates radial layout positions for topology graph nodes.

  Used by TopologyComponents for mesh and gossip circular layouts.
  Extracted from MeshLive and GossipLive topology rendering logic.
  """

  @doc """
  Calculates radial positions for a list of node names around a circle.

  Returns a map of `%{name => {x, y}}`.

  ## Options

    * `:cx` - center x coordinate (default: 250)
    * `:cy` - center y coordinate (default: 250)
    * `:radius` - circle radius in pixels (default: 180)

  ## Examples

      iex> calculate_radial(["a", "b", "c"])
      %{"a" => {430, 250}, "b" => {160, 406}, "c" => {160, 94}}
  """
  @spec calculate_radial([String.t()], keyword()) :: %{String.t() => {integer(), integer()}}
  def calculate_radial(names, opts \\ []) when is_list(names) do
    cx = Keyword.get(opts, :cx, 250)
    cy = Keyword.get(opts, :cy, 250)
    r = Keyword.get(opts, :radius, 180)
    count = length(names)

    if count == 0 do
      %{}
    else
      names
      |> Enum.with_index()
      |> Enum.map(fn {name, idx} ->
        angle = 2 * :math.pi() * idx / count - :math.pi() / 2
        x = cx + r * :math.cos(angle)
        y = cy + r * :math.sin(angle)
        {name, {round(x), round(y)}}
      end)
      |> Map.new()
    end
  end

  @doc """
  Builds full-mesh edge pairs between active node names.

  Returns a list of `{from, to}` tuples where `from < to` to avoid duplicates.
  """
  @spec mesh_edge_pairs([String.t()]) :: [{String.t(), String.t()}]
  def mesh_edge_pairs(active_names) do
    for a <- active_names,
        b <- active_names,
        a < b,
        do: {a, b}
  end

  @doc """
  Builds unique edge pairs from a topology adjacency map.

  The topology map is `%{node_name => [peer_names]}`.
  Returns deduplicated `{from, to}` tuples where `from < to`.
  """
  @spec topology_edge_pairs(%{String.t() => [String.t()]}) :: [{String.t(), String.t()}]
  def topology_edge_pairs(topology) when is_map(topology) do
    topology
    |> Enum.flat_map(fn {from, peers} ->
      Enum.map(peers, &normalize_edge(from, &1))
    end)
    |> Enum.uniq()
  end

  defp normalize_edge(a, b) when a < b, do: {a, b}
  defp normalize_edge(a, b), do: {b, a}
end
