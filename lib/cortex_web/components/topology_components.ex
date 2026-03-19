defmodule CortexWeb.TopologyComponents do
  @moduledoc """
  Unified SVG topology renderer supporting DAG (tiered left-to-right) and
  radial (mesh/gossip circular) layouts with interactive node selection.

  Absorbs the functionality of DAGComponents and the inline topology SVGs
  from MeshLive and GossipLive into a single component with a `variant`
  attribute.
  """
  use Phoenix.Component

  alias CortexWeb.Live.Helpers.{DAGLayout, TopologyLayout}
  alias CortexWeb.StatusComponents

  @max_full_mesh_edges 200

  # -- Topology Graph --

  @doc """
  Renders a topology graph as an SVG element.

  ## Variants

    * `:dag` - Tiered left-to-right DAG layout. Requires `tiers` and `teams` attrs.
    * `:radial` - Circular radial layout. Uses `nodes` and `edges` attrs.

  ## Examples

      <.topology_graph variant={:dag} tiers={tiers} teams={teams} edges={edges} run_id={id} />
      <.topology_graph variant={:radial} nodes={nodes} edges={edges} selected={name} on_node_click="select_node" />
  """
  attr(:variant, :atom, required: true, values: [:dag, :radial])
  attr(:nodes, :list, default: [])
  attr(:edges, :list, default: [])
  attr(:tiers, :list, default: [])
  attr(:teams, :list, default: [])
  attr(:run_id, :string, default: nil)
  attr(:selected, :string, default: nil)
  attr(:on_node_click, :string, default: nil)
  attr(:max_edges, :integer, default: @max_full_mesh_edges)
  attr(:class, :string, default: nil)

  def topology_graph(%{variant: :dag} = assigns) do
    render_dag_graph(assigns)
  end

  def topology_graph(%{variant: :radial} = assigns) do
    render_radial_graph(assigns)
  end

  # -- Topology Legend --

  @doc """
  Renders a status color legend strip.

  ## Examples

      <.topology_legend items={[%{label: "alive", color: "blue"}, %{label: "dead", color: "red"}]} />
  """
  attr(:items, :list, required: true)
  attr(:class, :string, default: nil)

  def topology_legend(assigns) do
    ~H"""
    <div class={["flex items-center gap-4 text-xs", @class]} role="legend" aria-label="Topology legend">
      <span :for={item <- @items} class="flex items-center gap-1">
        <span class={legend_dot_class(item.color)}>&#9679;</span>
        {item.label}
      </span>
    </div>
    """
  end

  # -- DAG variant --

  defp render_dag_graph(assigns) do
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
      class={["w-full", @class]}
      style={"max-height: #{@vh}px;"}
      xmlns="http://www.w3.org/2000/svg"
      role="img"
      aria-label="DAG topology graph"
    >
      <defs>
        <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
          <polygon points="0 0, 10 3.5, 0 7" fill="#6b7280" />
        </marker>
      </defs>
      <%= for {from, to} <- @edges do %>
        <.dag_edge
          from_pos={Map.get(@positions, from)}
          to_pos={Map.get(@positions, to)}
        />
      <% end %>
      <%= for {name, pos} <- @positions do %>
        <.dag_node
          name={name}
          pos={pos}
          team={Map.get(@team_map, name)}
          run_id={@run_id}
        />
      <% end %>
    </svg>
    """
  end

  # -- DAG sub-components --

  attr(:name, :string, required: true)
  attr(:pos, :map, required: true)
  attr(:team, :map, default: nil)
  attr(:run_id, :string, default: nil)

  defp dag_node(assigns) do
    status = if assigns.team, do: assigns.team.status, else: "pending"
    input_tokens = if assigns.team, do: Map.get(assigns.team, :input_tokens), else: nil
    output_tokens = if assigns.team, do: Map.get(assigns.team, :output_tokens), else: nil
    status = status || "pending"

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:token_label, dag_token_label(input_tokens, output_tokens))

    ~H"""
    <a href={if @run_id, do: "/runs/#{@run_id}/teams/#{@name}", else: "#"}>
      <rect
        x={@pos.x}
        y={@pos.y}
        width={@pos.width}
        height={@pos.height}
        rx="6"
        ry="6"
        fill={StatusComponents.svg_fill(@status)}
        stroke={StatusComponents.svg_stroke(@status)}
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
        fill={StatusComponents.svg_text_color(@status)}
        font-size="11"
      >
        {@status}{@token_label}
      </text>
    </a>
    """
  end

  attr(:from_pos, :map, default: nil)
  attr(:to_pos, :map, default: nil)

  defp dag_edge(assigns) do
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

  # -- Radial variant --

  defp render_radial_graph(assigns) do
    nodes = assigns.nodes
    count = length(nodes)

    if count == 0 do
      assigns = assign(assigns, :empty, true)

      ~H"""
      <div :if={@empty} class="text-gray-600 text-sm text-center py-8">No nodes to display</div>
      """
    else
      node_names = Enum.map(nodes, & &1.name)
      positions = TopologyLayout.calculate_radial(node_names)

      # Build edge data with position lookups
      edge_data =
        build_radial_edges(assigns.edges, positions, assigns.selected, assigns.max_edges)

      # Build node circle data
      node_circles =
        Enum.map(nodes, fn node ->
          {x, y} = Map.get(positions, node.name, {0, 0})

          %{
            name: node.name,
            x: x,
            y: y,
            state: node_state(node),
            selected: node.name == assigns.selected
          }
        end)

      assigns =
        assigns
        |> assign(:edge_data, edge_data)
        |> assign(:node_circles, node_circles)

      ~H"""
      <svg
        viewBox="0 0 500 500"
        class={["w-full max-w-lg aspect-square", @class]}
        role="img"
        aria-label="Radial topology graph"
      >
        <!-- Edges -->
        <line
          :for={edge <- @edge_data}
          x1={edge.x1}
          y1={edge.y1}
          x2={edge.x2}
          y2={edge.y2}
          stroke={if edge.highlighted, do: "#38bdf8", else: "#1f2937"}
          stroke-width={if edge.highlighted, do: "2", else: "1"}
          stroke-opacity={if edge.highlighted, do: "0.8", else: "0.4"}
        />
        <!-- Nodes -->
        <g
          :for={node <- @node_circles}
          phx-click={@on_node_click}
          phx-value-name={node.name}
          class="cursor-pointer"
          role="button"
          tabindex="0"
          aria-label={"Node: #{node.name}"}
          aria-selected={to_string(node.selected)}
        >
          <!-- Selection ring -->
          <circle
            :if={node.selected}
            cx={node.x}
            cy={node.y}
            r="32"
            fill="none"
            stroke="#38bdf8"
            stroke-width="2"
            stroke-dasharray="4 2"
            opacity="0.6"
          />
          <!-- Main circle -->
          <circle
            cx={node.x}
            cy={node.y}
            r="24"
            fill={if node.selected, do: "#0c4a6e", else: StatusComponents.svg_fill(node.state)}
            stroke={if node.selected, do: "#38bdf8", else: StatusComponents.svg_stroke(node.state)}
            stroke-width={if node.selected, do: "3", else: "2"}
          />
          <!-- Label -->
          <text
            x={node.x}
            y={node.y + 4}
            text-anchor="middle"
            fill={if(node.selected, do: "#e0f2fe", else: "white")}
            font-size="11"
            font-weight={if node.selected, do: "bold", else: "normal"}
            font-family="monospace"
          >
            {String.slice(node.name, 0, 5)}
          </text>
          <!-- State dot -->
          <circle
            cx={node.x + 16}
            cy={node.y - 16}
            r="4"
            fill={StatusComponents.svg_stroke(node.state)}
          />
        </g>
      </svg>
      """
    end
  end

  # -- Private helpers --

  defp build_radial_edges(edges, positions, selected, max_edges) do
    edge_pairs =
      case edges do
        pairs when is_list(pairs) ->
          pairs
          |> Enum.take(max_edges)
          |> Enum.map(fn
            {from, to} ->
              {fx, fy} = Map.get(positions, from, {0, 0})
              {tx, ty} = Map.get(positions, to, {0, 0})
              highlighted = selected != nil and (from == selected or to == selected)
              %{x1: fx, y1: fy, x2: tx, y2: ty, highlighted: highlighted}

            %{from: from, to: to} ->
              {fx, fy} = Map.get(positions, from, {0, 0})
              {tx, ty} = Map.get(positions, to, {0, 0})
              highlighted = selected != nil and (from == selected or to == selected)
              %{x1: fx, y1: fy, x2: tx, y2: ty, highlighted: highlighted}
          end)
      end

    edge_pairs
  end

  defp node_state(%{state: state}), do: state
  defp node_state(%{status: status}), do: status
  defp node_state(_), do: :unknown

  defp dag_token_label(nil, nil), do: ""

  defp dag_token_label(input, output) when is_integer(input) and is_integer(output) do
    " | #{format_k(input + output)} tok"
  end

  defp dag_token_label(_, _), do: ""

  defp format_k(n) when n < 1_000, do: Integer.to_string(n)
  defp format_k(n), do: "#{Float.round(n / 1_000, 1)}K"

  defp legend_dot_class("blue"), do: "text-blue-400"
  defp legend_dot_class("green"), do: "text-green-400"
  defp legend_dot_class("emerald"), do: "text-emerald-400"
  defp legend_dot_class("yellow"), do: "text-yellow-400"
  defp legend_dot_class("red"), do: "text-red-400"
  defp legend_dot_class("orange"), do: "text-orange-400"
  defp legend_dot_class("gray"), do: "text-gray-500"
  defp legend_dot_class("purple"), do: "text-purple-400"
  defp legend_dot_class(_), do: "text-gray-500"
end
