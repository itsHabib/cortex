defmodule CortexWeb.GossipComponents do
  @moduledoc """
  Gossip protocol visualization components for the Cortex UI.

  Extracted from GossipLive's render logic. Provides gossip overview,
  knowledge entries display, and round progress bar. Used by RunDetailLive's
  Overview tab for gossip-mode runs.
  """
  use Phoenix.Component

  alias CortexWeb.StatusComponents

  # -- Gossip Overview --

  @doc """
  Renders a gossip protocol overview panel with status, round progress,
  and convergence state.

  ## Examples

      <.gossip_overview
        project="my-project"
        running={true}
        rounds_completed={3}
        rounds_total={5}
        nodes={nodes}
        entries={entries}
      />
  """
  attr(:project, :string, default: nil)
  attr(:running, :boolean, default: false)
  attr(:rounds_completed, :integer, default: 0)
  attr(:rounds_total, :integer, default: 0)
  attr(:nodes, :list, default: [])
  attr(:entries, :list, default: [])
  attr(:class, :string, default: nil)

  def gossip_overview(assigns) do
    ~H"""
    <div class={["space-y-4", @class]}>
      <%!-- Status banner --%>
      <div :if={@running} class="bg-blue-900/30 border border-blue-800 rounded-lg p-3 flex items-center gap-3">
        <StatusComponents.status_dot status={:online} pulse={true} />
        <span class="text-blue-300 text-sm">
          Gossip session active
          <span :if={@project}> &mdash; <span class="text-cortex-400">{@project}</span></span>
          &mdash; round {@rounds_completed}/{@rounds_total}
        </span>
      </div>

      <%!-- Round progress --%>
      <.round_progress
        :if={@rounds_total > 0}
        current={@rounds_completed}
        total={@rounds_total}
      />

      <%!-- Convergence state --%>
      <div :if={@entries != []} class="flex items-center gap-2">
        <span class="text-xs text-gray-500">Knowledge:</span>
        <span class="text-xs text-gray-400">{length(@entries)} entries</span>
        <span class={[
          "text-xs px-2 py-0.5 rounded",
          if(converged?(@entries, @nodes),
            do: "bg-green-900/50 text-green-300",
            else: "bg-yellow-900/50 text-yellow-300"
          )
        ]}>
          {if converged?(@entries, @nodes), do: "Converged", else: "Divergent"}
        </span>
      </div>
    </div>
    """
  end

  # -- Gossip Topology SVG --

  @doc """
  Renders gossip topology SVG with interactive node selection.
  """
  attr(:nodes, :list, required: true)
  attr(:topology, :map, required: true)
  attr(:selected_node, :string, default: nil)
  attr(:click_event, :string, default: "select_node")

  def gossip_topology(assigns) do
    count = length(assigns.nodes)

    {edges, node_circles} =
      if count == 0 do
        {[], []}
      else
        cx = 250
        cy = 250
        r = 180

        positions =
          assigns.nodes
          |> Enum.with_index()
          |> Enum.map(fn {node, idx} ->
            angle = 2 * :math.pi() * idx / count - :math.pi() / 2
            x = cx + r * :math.cos(angle)
            y = cy + r * :math.sin(angle)
            {node.name, {round(x), round(y)}}
          end)
          |> Map.new()

        selected = assigns.selected_node
        selected_peers = if selected, do: Map.get(assigns.topology, selected, []), else: []

        edges = build_svg_edges(assigns.topology, positions, selected, selected_peers)

        node_circles =
          Enum.map(assigns.nodes, fn node ->
            {x, y} = Map.get(positions, node.name, {0, 0})
            is_selected = node.name == selected
            is_peer = node.name in selected_peers

            %{
              name: node.name,
              x: x,
              y: y,
              status: node.status,
              selected: is_selected,
              peer: is_peer
            }
          end)

        {edges, node_circles}
      end

    assigns = assign(assigns, edges: edges, node_circles: node_circles)

    ~H"""
    <svg
      :if={@node_circles != []}
      viewBox="0 0 500 500"
      class="w-full max-w-lg aspect-square"
      role="img"
      aria-label="Gossip topology graph"
    >
      <!-- Edges -->
      <line
        :for={edge <- @edges}
        x1={edge.x1}
        y1={edge.y1}
        x2={edge.x2}
        y2={edge.y2}
        stroke={if edge.highlighted, do: "#38bdf8", else: "#1f2937"}
        stroke-width={if edge.highlighted, do: "2", else: "1"}
        stroke-opacity={if edge.highlighted, do: "0.8", else: "0.5"}
      />
      <!-- Nodes -->
      <g
        :for={node <- @node_circles}
        phx-click={@click_event}
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
        <!-- Peer highlight ring -->
        <circle
          :if={node.peer && !node.selected}
          cx={node.x}
          cy={node.y}
          r="30"
          fill="none"
          stroke="#38bdf8"
          stroke-width="1"
          opacity="0.3"
        />
        <!-- Main circle -->
        <circle
          cx={node.x}
          cy={node.y}
          r="24"
          fill={if node.selected, do: "#0c4a6e", else: StatusComponents.svg_fill(node.status)}
          stroke={if node.selected, do: "#38bdf8", else: if(node.peer, do: "#38bdf8", else: StatusComponents.svg_stroke(node.status))}
          stroke-width={if node.selected, do: "3", else: "2"}
        />
        <!-- Label -->
        <text
          x={node.x}
          y={node.y + 4}
          text-anchor="middle"
          fill={if(node.selected || node.peer, do: "#e0f2fe", else: "white")}
          font-size="11"
          font-weight={if node.selected, do: "bold", else: "normal"}
          font-family="monospace"
        >
          {String.slice(node.name, 0, 5)}
        </text>
        <!-- Status dot -->
        <circle
          cx={node.x + 16}
          cy={node.y - 16}
          r="4"
          fill={StatusComponents.svg_stroke(node.status)}
        />
      </g>
    </svg>
    """
  end

  # -- Knowledge Entries --

  @doc """
  Renders a list of gossip knowledge entries with source attribution
  and confidence scores.

  ## Examples

      <.knowledge_entries entries={entries} selected_node="alpha" click_event="select_node" />
  """
  attr(:entries, :list, required: true)
  attr(:selected_node, :string, default: nil)
  attr(:click_event, :string, default: "select_node")
  attr(:class, :string, default: nil)

  def knowledge_entries(assigns) do
    ~H"""
    <div class={@class}>
      <%= if @entries != [] do %>
        <div class="space-y-2 max-h-[50vh] overflow-y-auto">
          <div
            :for={entry <- Enum.sort_by(@entries, & &1.topic)}
            class={[
              "rounded p-3 transition-colors",
              if(@selected_node && entry.source == @selected_node,
                do: "bg-cortex-900/20 border border-cortex-800/50",
                else: "bg-gray-950"
              )
            ]}
          >
            <div class="flex items-center gap-3 mb-2">
              <span class="bg-cortex-900/50 text-cortex-300 text-xs px-2 py-0.5 rounded">
                {entry.topic}
              </span>
              <button
                phx-click={@click_event}
                phx-value-name={entry.source}
                class="text-gray-500 text-xs hover:text-cortex-400 transition-colors"
              >
                from: {entry.source}
              </button>
              <span class="text-gray-600 text-xs ml-auto font-mono">
                {String.slice(entry.id, 0, 8)}
              </span>
            </div>
            <p class="text-gray-300 text-sm mb-2">{truncate(entry.content, 200)}</p>
            <div class="flex items-center gap-4 text-xs">
              <span class="text-gray-500">
                confidence: <span class={confidence_class(entry.confidence)}>{Float.round(entry.confidence, 2)}</span>
              </span>
              <span class="text-gray-600 font-mono">
                vc: {format_vector_clock(entry.vector_clock)}
              </span>
            </div>
          </div>
        </div>
      <% else %>
        <p class="text-gray-500 text-sm">Waiting for knowledge entries...</p>
      <% end %>
    </div>
    """
  end

  # -- Round Progress --

  @doc """
  Renders a visual progress bar for gossip rounds.

  ## Examples

      <.round_progress current={3} total={5} />
  """
  attr(:current, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:class, :string, default: nil)

  def round_progress(assigns) do
    pct =
      if assigns.total > 0 do
        min(round(assigns.current / assigns.total * 100), 100)
      else
        0
      end

    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div class={["space-y-1", @class]}>
      <div class="flex items-center justify-between text-xs">
        <span class="text-gray-500">Rounds</span>
        <span class="text-gray-400">{@current}/{@total}</span>
      </div>
      <div class="w-full bg-gray-800 rounded-full h-1.5" role="progressbar" aria-valuenow={@current} aria-valuemin="0" aria-valuemax={@total}>
        <div
          class="bg-purple-500 h-1.5 rounded-full transition-all"
          style={"width: #{@pct}%"}
        />
      </div>
    </div>
    """
  end

  # -- Private helpers --

  defp build_svg_edges(topology, positions, selected, selected_peers) do
    topology
    |> unique_edge_pairs()
    |> Enum.map(fn {from, to} ->
      {fx, fy} = Map.get(positions, from, {0, 0})
      {tx, ty} = Map.get(positions, to, {0, 0})

      highlighted =
        selected != nil and
          ((from == selected and to in selected_peers) or
             (to == selected and from in selected_peers))

      %{x1: fx, y1: fy, x2: tx, y2: ty, highlighted: highlighted}
    end)
  end

  defp unique_edge_pairs(topology) do
    topology
    |> Enum.flat_map(&normalize_peer_edges/1)
    |> Enum.uniq()
  end

  defp normalize_peer_edges({from, peers}) do
    Enum.map(peers, fn to -> if from < to, do: {from, to}, else: {to, from} end)
  end

  defp converged?(entries, nodes) do
    node_names = MapSet.new(nodes, & &1.name)
    node_count = MapSet.size(node_names)

    node_count > 0 and
      Enum.all?(entries, fn entry ->
        vc_nodes = MapSet.new(Map.keys(entry.vector_clock))
        MapSet.subset?(node_names, vc_nodes)
      end)
  end

  defp confidence_class(c) when c >= 0.8, do: "text-green-400"
  defp confidence_class(c) when c >= 0.5, do: "text-yellow-400"
  defp confidence_class(_), do: "text-red-400"

  defp format_vector_clock(vc) when map_size(vc) == 0, do: "{}"

  defp format_vector_clock(vc) do
    vc
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join(" ", fn {k, v} -> "#{String.slice(k, 0, 3)}:#{v}" end)
  end

  defp truncate(nil, _max), do: ""
  defp truncate(text, _max) when not is_binary(text), do: inspect(text)

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
