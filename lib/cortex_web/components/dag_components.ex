defmodule CortexWeb.DAGComponents do
  @moduledoc """
  SVG components for rendering the DAG visualization of team dependencies.
  """
  use Phoenix.Component

  alias CortexWeb.Live.Helpers.DAGLayout

  @doc """
  Renders the full DAG as an SVG element with team nodes and dependency edges.

  ## Attributes

    * `tiers` - list of lists of team name strings
    * `teams` - list of team maps/structs with at least `:team_name` and `:status`
    * `edges` - list of `{from_name, to_name}` tuples
    * `run_id` - the run ID for linking to team details
  """
  attr(:tiers, :list, required: true)
  attr(:teams, :list, required: true)
  attr(:edges, :list, default: [])
  attr(:run_id, :string, required: true)

  def dag_graph(assigns) do
    positions = DAGLayout.calculate_positions(assigns.tiers)
    {vw, vh} = DAGLayout.viewport_size(assigns.tiers)

    team_map =
      assigns.teams
      |> Enum.map(fn t -> {t.team_name, t} end)
      |> Map.new()

    assigns =
      assigns
      |> assign(:positions, positions)
      |> assign(:vw, vw)
      |> assign(:vh, vh)
      |> assign(:team_map, team_map)

    ~H"""
    <svg
      viewBox={"0 0 #{@vw} #{@vh}"}
      class="w-full"
      style={"max-height: #{@vh}px;"}
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
          <polygon points="0 0, 10 3.5, 0 7" fill="#6b7280" />
        </marker>
      </defs>
      <%= for {from, to} <- @edges do %>
        <.dependency_edge
          from_pos={Map.get(@positions, from)}
          to_pos={Map.get(@positions, to)}
        />
      <% end %>
      <%= for {name, pos} <- @positions do %>
        <.team_node
          name={name}
          pos={pos}
          team={Map.get(@team_map, name)}
          run_id={@run_id}
        />
      <% end %>
    </svg>
    """
  end

  @doc """
  Renders a single team as an SVG rectangle with name and status.
  """
  attr(:name, :string, required: true)
  attr(:pos, :map, required: true)
  attr(:team, :map, default: nil)
  attr(:run_id, :string, required: true)

  def team_node(assigns) do
    status = if assigns.team, do: assigns.team.status, else: "pending"
    cost = if assigns.team, do: assigns.team.cost_usd, else: nil

    assigns =
      assigns
      |> assign(:status, status || "pending")
      |> assign(:cost, cost)

    ~H"""
    <a href={"/runs/#{@run_id}/teams/#{@name}"}>
      <rect
        x={@pos.x}
        y={@pos.y}
        width={@pos.width}
        height={@pos.height}
        rx="6"
        ry="6"
        fill={node_fill(@status)}
        stroke={node_stroke(@status)}
        stroke-width="1.5"
        class="cursor-pointer hover:opacity-80 transition-opacity"
      />
      <text
        x={@pos.x + div(@pos.width, 2)}
        y={@pos.y + 24}
        text-anchor="middle"
        fill="white"
        font-size="13"
        font-weight="600"
      >
        {@name}
      </text>
      <text
        x={@pos.x + div(@pos.width, 2)}
        y={@pos.y + 42}
        text-anchor="middle"
        fill={status_text_color(@status)}
        font-size="11"
      >
        {status_label(@status)}{cost_label(@cost)}
      </text>
    </a>
    """
  end

  @doc """
  Renders an arrow line between two team nodes.
  """
  attr(:from_pos, :map, default: nil)
  attr(:to_pos, :map, default: nil)

  def dependency_edge(assigns) do
    if assigns.from_pos && assigns.to_pos do
      x1 = assigns.from_pos.x + assigns.from_pos.width
      y1 = assigns.from_pos.y + div(assigns.from_pos.height, 2)
      x2 = assigns.to_pos.x
      y2 = assigns.to_pos.y + div(assigns.to_pos.height, 2)

      assigns =
        assigns
        |> assign(:x1, x1)
        |> assign(:y1, y1)
        |> assign(:x2, x2)
        |> assign(:y2, y2)

      ~H"""
      <line
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        stroke="#6b7280"
        stroke-width="1.5"
        marker-end="url(#arrowhead)"
      />
      """
    else
      ~H""
    end
  end

  # -- Private helpers --

  defp node_fill("pending"), do: "#374151"
  defp node_fill("running"), do: "#1e3a5f"
  defp node_fill("completed"), do: "#064e3b"
  defp node_fill("done"), do: "#064e3b"
  defp node_fill("failed"), do: "#7f1d1d"
  defp node_fill(_), do: "#374151"

  defp node_stroke("pending"), do: "#6b7280"
  defp node_stroke("running"), do: "#3b82f6"
  defp node_stroke("completed"), do: "#10b981"
  defp node_stroke("done"), do: "#10b981"
  defp node_stroke("failed"), do: "#ef4444"
  defp node_stroke(_), do: "#6b7280"

  defp status_text_color("pending"), do: "#9ca3af"
  defp status_text_color("running"), do: "#93c5fd"
  defp status_text_color("completed"), do: "#6ee7b7"
  defp status_text_color("done"), do: "#6ee7b7"
  defp status_text_color("failed"), do: "#fca5a5"
  defp status_text_color(_), do: "#9ca3af"

  defp status_label(status), do: status

  defp cost_label(nil), do: ""

  defp cost_label(cost) when is_number(cost),
    do: " | $#{:erlang.float_to_binary(cost / 1, decimals: 4)}"

  defp cost_label(_), do: ""
end
