defmodule CortexWeb.Live.Helpers.DAGLayout do
  @moduledoc """
  Calculates x,y positions for DAG team nodes based on tier structure.

  Takes tiers (list of lists of team names) and produces a map of
  team_name -> %{x, y, tier} for SVG rendering.
  """

  @node_width 180
  @node_height 60
  @x_spacing 240
  @y_spacing 90
  @x_offset 40
  @y_offset 40

  @doc """
  Calculate positions for each team based on their tier placement.

  Returns a map of `%{team_name => %{x: int, y: int, tier: int, width: int, height: int}}`.
  """
  def calculate_positions(tiers) when is_list(tiers) do
    tiers
    |> Enum.with_index()
    |> Enum.flat_map(fn {team_names, tier_index} ->
      team_names
      |> Enum.with_index()
      |> Enum.map(fn {name, y_index} ->
        {name,
         %{
           x: @x_offset + tier_index * @x_spacing,
           y: @y_offset + y_index * @y_spacing,
           tier: tier_index,
           width: @node_width,
           height: @node_height
         }}
      end)
    end)
    |> Map.new()
  end

  @doc """
  Calculate the total SVG viewport dimensions needed for the given tiers.
  Returns `{width, height}`.
  """
  def viewport_size(tiers) when is_list(tiers) do
    num_tiers = length(tiers)
    max_teams_in_tier = tiers |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)

    width = @x_offset * 2 + max(num_tiers * @x_spacing, @node_width + @x_offset)
    height = @y_offset * 2 + max(max_teams_in_tier * @y_spacing, @node_height + @y_offset)

    {width, height}
  end
end
