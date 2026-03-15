defmodule CortexWeb.GossipLive do
  @moduledoc """
  LiveView page for visualizing gossip protocol state.

  Interactive topology graph with clickable agent nodes.
  Subscribes to PubSub for real-time updates during live gossip sessions.
  """

  use CortexWeb, :live_view

  alias Cortex.Gossip.{Config, Entry, Topology}
  alias Cortex.Gossip.SessionRunner

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: safe_subscribe()

    {:ok,
     assign(socket,
       page_title: "Gossip Protocol",
       nodes: [],
       topology: %{},
       topology_strategy: nil,
       entries: [],
       rounds_completed: 0,
       rounds_total: 0,
       running: false,
       live_project: nil,
       selected_node: nil,
       # Form state
       yaml_content: "",
       file_path: "",
       workspace_path: "",
       gossip_config: nil,
       validation_errors: [],
       validated: false
     )}
  end

  # -- PubSub handlers --

  @impl true
  def handle_info(%{type: :gossip_started, payload: payload}, socket) do
    agents = Map.get(payload, :agents, [])
    project = Map.get(payload, :project, "unknown")

    nodes =
      Enum.map(agents, fn name ->
        %{name: name, status: :online, last_seen: DateTime.utc_now()}
      end)

    topology_strategy = Map.get(payload, :topology, :full_mesh)
    topology = Topology.build(Enum.map(nodes, & &1.name), topology_strategy)

    {:noreply,
     assign(socket,
       live_project: project,
       nodes: nodes,
       topology: topology,
       topology_strategy: topology_strategy,
       running: true,
       rounds_completed: 0,
       entries: [],
       selected_node: nil
     )}
  end

  def handle_info(%{type: :gossip_round_completed, payload: payload}, socket) do
    round = Map.get(payload, :round, 0)
    total = Map.get(payload, :total, 0)

    nodes =
      Enum.map(socket.assigns.nodes, fn node ->
        %{node | last_seen: DateTime.utc_now()}
      end)

    {:noreply,
     assign(socket,
       rounds_completed: round,
       rounds_total: total,
       nodes: nodes
     )}
  end

  def handle_info(%{type: :gossip_completed, payload: payload}, socket) do
    raw_entries = Map.get(payload, :entries, [])

    entries =
      Enum.map(raw_entries, fn
        %Entry{} = e -> e
        map when is_map(map) -> struct(Entry, map)
      end)

    nodes =
      Enum.map(socket.assigns.nodes, fn node ->
        %{node | status: :converged}
      end)

    {:noreply,
     assign(socket,
       entries: entries,
       nodes: nodes,
       running: false
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Event handlers --

  @impl true
  def handle_event("select_node", %{"name" => name}, socket) do
    selected =
      if socket.assigns.selected_node == name do
        nil
      else
        name
      end

    {:noreply, assign(socket, selected_node: selected)}
  end

  def handle_event("form_changed", params, socket) do
    yaml = Map.get(params, "yaml", socket.assigns.yaml_content)
    path = Map.get(params, "path", socket.assigns.file_path)
    workspace = Map.get(params, "workspace_path", socket.assigns.workspace_path)

    {:noreply,
     assign(socket,
       yaml_content: yaml,
       file_path: path,
       workspace_path: workspace,
       gossip_config: nil,
       validated: false,
       validation_errors: []
     )}
  end

  def handle_event("validate_gossip", params, socket) do
    yaml = Map.get(params, "yaml", socket.assigns.yaml_content)
    path = Map.get(params, "path", socket.assigns.file_path)
    workspace = Map.get(params, "workspace_path", socket.assigns.workspace_path)

    socket = assign(socket, yaml_content: yaml, file_path: path, workspace_path: workspace)
    effective = effective_yaml(socket)

    if effective == "" do
      {:noreply,
       assign(socket,
         validation_errors: ["Please provide YAML content or a file path"],
         gossip_config: nil,
         validated: false
       )}
    else
      case Config.Loader.load_string(effective) do
        {:ok, config} ->
          {:noreply,
           assign(socket,
             gossip_config: config,
             validated: true,
             validation_errors: []
           )}

        {:error, errors} ->
          {:noreply,
           assign(socket,
             validation_errors: errors,
             gossip_config: nil,
             validated: false
           )}
      end
    end
  end

  def handle_event("launch_gossip", _params, socket) do
    config = socket.assigns.gossip_config

    if config == nil do
      {:noreply, put_flash(socket, :error, "Validate configuration first")}
    else
      yaml = effective_yaml(socket)
      workspace = String.trim(socket.assigns.workspace_path)

      workspace_path =
        if workspace != "" do
          workspace
        else
          Path.join(System.tmp_dir!(), "cortex_gossip_#{Uniq.UUID.uuid4() |> String.slice(0, 8)}")
        end

      run_attrs = %{
        name: config.name,
        config_yaml: yaml,
        status: "pending",
        mode: "gossip",
        team_count: length(config.agents),
        started_at: DateTime.utc_now(),
        workspace_path: workspace_path
      }

      case safe_create_run(run_attrs) do
        {:ok, run} ->
          spawn_gossip(run, config, workspace_path)

          {:noreply,
           socket
           |> put_flash(:info, "Gossip run started!")
           |> push_navigate(to: "/runs/#{run.id}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to create run")}
      end
    end
  end

  def handle_event("change_topology", %{"strategy" => strategy}, socket) do
    strategy_atom = String.to_existing_atom(strategy)
    agent_names = Enum.map(socket.assigns.nodes, & &1.name)

    topology =
      if agent_names != [] do
        Topology.build(agent_names, strategy_atom)
      else
        %{}
      end

    {:noreply, assign(socket, topology: topology, topology_strategy: strategy_atom)}
  end

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-7xl mx-auto">
      <div class="mb-6">
        <h1 class="text-2xl font-bold text-white">Gossip Protocol</h1>
        <p class="text-sm text-gray-500 mt-1">
          CRDT-based knowledge convergence visualization
          <%= if @live_project do %>
            — <span class="text-cortex-400">{@live_project}</span>
          <% end %>
        </p>
      </div>

      <%= if @running do %>
        <div class="bg-blue-900/30 border border-blue-800 rounded-lg p-3 mb-6 flex items-center gap-3">
          <span class="text-blue-400 animate-pulse">●</span>
          <span class="text-blue-300 text-sm">
            Gossip session active — round {@rounds_completed}/{@rounds_total}
          </span>
        </div>
      <% end %>

      <%= if @nodes != [] do %>
        <!-- Main layout: graph + detail panel -->
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6 mb-6">
          <!-- Topology Graph (2/3) -->
          <div class="lg:col-span-2">
            <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
              <div class="flex items-center justify-between mb-3">
                <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">
                  Topology
                  <%= if @topology_strategy do %>
                    <span class="text-gray-600 normal-case font-normal ml-1">({@topology_strategy})</span>
                  <% end %>
                </h2>
                <div class="flex items-center gap-3">
                  <span class="text-xs text-gray-600">{length(@nodes)} nodes</span>
                  <form phx-change="change_topology">
                    <select
                      name="strategy"
                      class="bg-gray-950 border border-gray-700 rounded px-2 py-1 text-xs text-gray-300"
                    >
                      <option value="full_mesh" selected={@topology_strategy == :full_mesh}>Full Mesh</option>
                      <option value="ring" selected={@topology_strategy == :ring}>Ring</option>
                      <option value="random" selected={@topology_strategy == :random}>Random</option>
                    </select>
                  </form>
                </div>
              </div>
              <%= if @topology != %{} do %>
                <div class="flex justify-center">
                  {topology_svg(assigns)}
                </div>
                <p class="text-xs text-gray-600 text-center mt-2">Click a node to inspect</p>
              <% end %>
            </div>
          </div>

          <!-- Node Detail Panel (1/3) -->
          <div>
            <%= if @selected_node do %>
              <% node = Enum.find(@nodes, &(&1.name == @selected_node)) %>
              <% peers = Map.get(@topology, @selected_node, []) %>
              <% node_entries = Enum.filter(@entries, &(&1.source == @selected_node)) %>
              <% node_vc_entries = Enum.filter(@entries, &(Map.has_key?(&1.vector_clock, @selected_node))) %>
              <div class="bg-gray-900 rounded-lg border border-cortex-800 p-4 space-y-4">
                <!-- Header -->
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <span class={if(node, do: node_dot_class(node.status), else: "text-gray-600")}>●</span>
                    <h2 class="text-lg font-bold text-white">{@selected_node}</h2>
                  </div>
                  <button
                    phx-click="select_node"
                    phx-value-name={@selected_node}
                    class="text-gray-600 hover:text-gray-400 text-sm"
                  >
                    ✕
                  </button>
                </div>

                <!-- Status -->
                <div :if={node} class="grid grid-cols-2 gap-2 text-xs">
                  <div class="bg-gray-950 rounded p-2">
                    <span class="text-gray-500">Status</span>
                    <p class={node_status_text_class(node.status)}>{node_status_label(node.status)}</p>
                  </div>
                  <div class="bg-gray-950 rounded p-2">
                    <span class="text-gray-500">Last seen</span>
                    <p class="text-gray-300">{format_time(node.last_seen)}</p>
                  </div>
                  <div class="bg-gray-950 rounded p-2">
                    <span class="text-gray-500">Peers</span>
                    <p class="text-gray-300">{length(peers)}</p>
                  </div>
                  <div class="bg-gray-950 rounded p-2">
                    <span class="text-gray-500">Entries authored</span>
                    <p class="text-gray-300">{length(node_entries)}</p>
                  </div>
                </div>

                <!-- Peers list -->
                <div>
                  <h3 class="text-xs text-gray-500 uppercase tracking-wider mb-2">Peers</h3>
                  <div class="flex flex-wrap gap-1">
                    <button
                      :for={peer <- peers}
                      phx-click="select_node"
                      phx-value-name={peer}
                      class="bg-gray-950 hover:bg-gray-800 text-cortex-400 text-xs px-2 py-1 rounded transition-colors"
                    >
                      {peer}
                    </button>
                    <span :if={peers == []} class="text-gray-600 text-xs">No peers</span>
                  </div>
                </div>

                <!-- Vector clock presence -->
                <div :if={node_vc_entries != []}>
                  <h3 class="text-xs text-gray-500 uppercase tracking-wider mb-2">
                    Vector Clock ({length(node_vc_entries)} entries)
                  </h3>
                  <div class="space-y-1 max-h-32 overflow-y-auto">
                    <div
                      :for={entry <- Enum.take(Enum.sort_by(node_vc_entries, & &1.topic), 10)}
                      class="flex items-center justify-between text-xs bg-gray-950 rounded px-2 py-1"
                    >
                      <span class="text-gray-400">{entry.topic}</span>
                      <span class="text-cortex-400 font-mono">{Map.get(entry.vector_clock, @selected_node, 0)}</span>
                    </div>
                  </div>
                </div>

                <!-- Authored entries -->
                <div :if={node_entries != []}>
                  <h3 class="text-xs text-gray-500 uppercase tracking-wider mb-2">
                    Authored Entries ({length(node_entries)})
                  </h3>
                  <div class="space-y-2 max-h-48 overflow-y-auto">
                    <div
                      :for={entry <- Enum.sort_by(node_entries, & &1.topic)}
                      class="bg-gray-950 rounded p-2"
                    >
                      <div class="flex items-center gap-2 mb-1">
                        <span class="text-cortex-300 text-xs">{entry.topic}</span>
                        <span class={["text-xs", confidence_class(entry.confidence)]}>
                          {Float.round(entry.confidence, 2)}
                        </span>
                      </div>
                      <p class="text-gray-400 text-xs">{truncate(entry.content, 120)}</p>
                    </div>
                  </div>
                </div>
              </div>
            <% else %>
              <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 text-center h-full flex flex-col justify-center">
                <p class="text-gray-600 text-sm">Select a node in the graph</p>
                <p class="text-gray-700 text-xs mt-1">to see its peers, entries, and vector clocks</p>
              </div>
            <% end %>
          </div>
        </div>

        <!-- All Entries + Vector Clock Table -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- CRDT Entries -->
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">
                Knowledge Entries ({length(@entries)})
              </h2>
              <%= if @entries != [] do %>
                <span class={[
                  "text-xs px-2 py-0.5 rounded",
                  if(converged?(@entries, @nodes),
                    do: "bg-green-900/50 text-green-300",
                    else: "bg-yellow-900/50 text-yellow-300"
                  )
                ]}>
                  {if converged?(@entries, @nodes), do: "Converged", else: "Divergent"}
                </span>
              <% end %>
            </div>
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
                      phx-click="select_node"
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

          <!-- Vector Clocks Table -->
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
            <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">
              Vector Clocks
            </h2>
            <%= if @entries != [] do %>
              <div class="overflow-x-auto max-h-[50vh] overflow-y-auto">
                <table class="w-full text-sm">
                  <thead class="sticky top-0 bg-gray-900">
                    <tr class="border-b border-gray-800">
                      <th class="text-left text-gray-500 text-xs uppercase py-2 pr-4">Entry</th>
                      <th
                        :for={node <- Enum.sort_by(@nodes, & &1.name)}
                        class="text-center text-xs uppercase py-2 px-2"
                      >
                        <button
                          phx-click="select_node"
                          phx-value-name={node.name}
                          class={[
                            "hover:text-cortex-400 transition-colors",
                            if(@selected_node == node.name, do: "text-cortex-400 font-bold", else: "text-gray-500")
                          ]}
                        >
                          {node.name}
                        </button>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={entry <- Enum.take(Enum.sort_by(@entries, & &1.topic), 20)}
                      class={[
                        "border-b border-gray-800/50",
                        if(@selected_node && entry.source == @selected_node, do: "bg-cortex-900/10", else: "")
                      ]}
                    >
                      <td class="py-2 pr-4">
                        <span class="text-cortex-400 text-xs">{entry.topic}</span>
                        <span class="text-gray-600 text-xs ml-1">({String.slice(entry.id, 0, 6)})</span>
                      </td>
                      <td
                        :for={node <- Enum.sort_by(@nodes, & &1.name)}
                        class="text-center py-2 px-2"
                      >
                        <span class={[
                          "font-mono text-xs",
                          cond do
                            @selected_node == node.name && Map.get(entry.vector_clock, node.name, 0) > 0 ->
                              "text-cortex-300 font-bold"
                            Map.get(entry.vector_clock, node.name, 0) > 0 ->
                              "text-cortex-400"
                            true ->
                              "text-gray-700"
                          end
                        ]}>
                          {Map.get(entry.vector_clock, node.name, 0)}
                        </span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% else %>
              <p class="text-gray-500 text-sm">No vector clock data yet.</p>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- New Gossip Run Form -->
      <div class="mt-6">
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <h2 class="text-lg font-semibold text-white mb-4">New Gossip Run</h2>
          <form phx-change="form_changed" phx-submit="validate_gossip">
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-4">
              <div>
                <label class="text-xs text-gray-500 block mb-1">Gossip YAML</label>
                <textarea
                  name="yaml"
                  rows="10"
                  class="w-full bg-gray-950 border border-gray-700 rounded p-3 text-sm font-mono text-gray-300 resize-y"
                  placeholder="Paste gossip.yaml content..."
                ><%= @yaml_content %></textarea>
              </div>
              <div class="space-y-3">
                <div>
                  <label class="text-xs text-gray-500 block mb-1">Or load from file</label>
                  <input
                    type="text"
                    name="path"
                    value={@file_path}
                    class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm font-mono text-gray-300"
                    placeholder="/path/to/gossip.yaml"
                  />
                </div>
                <div>
                  <label class="text-xs text-gray-500 block mb-1">Workspace path</label>
                  <input
                    type="text"
                    name="workspace_path"
                    value={@workspace_path}
                    class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm font-mono text-gray-300"
                    placeholder="/path/to/project (default: /tmp)"
                  />
                </div>
                <!-- Config Preview -->
                <%= if @gossip_config do %>
                  <div class="bg-gray-950 rounded p-3 text-sm space-y-1">
                    <div><span class="text-gray-500">Project:</span> <span class="text-white">{@gossip_config.name}</span></div>
                    <div><span class="text-gray-500">Agents:</span> <span class="text-white">{length(@gossip_config.agents)}</span></div>
                    <div><span class="text-gray-500">Rounds:</span> <span class="text-white">{@gossip_config.gossip.rounds}</span></div>
                    <div><span class="text-gray-500">Topology:</span> <span class="text-white">{@gossip_config.gossip.topology}</span></div>
                    <div class="flex flex-wrap gap-1 pt-1">
                      <span
                        :for={agent <- @gossip_config.agents}
                        class="bg-purple-900/50 text-purple-300 text-xs px-2 py-0.5 rounded"
                      >
                        {agent.name}
                      </span>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
            <!-- Errors -->
            <%= if @validation_errors != [] do %>
              <div class="bg-rose-900/30 border border-rose-800 rounded p-3 mb-4">
                <ul class="list-disc list-inside text-sm text-rose-200 space-y-1">
                  <li :for={error <- @validation_errors}>{error}</li>
                </ul>
              </div>
            <% end %>
            <div class="flex gap-3">
              <button
                type="submit"
                class="rounded bg-gray-700 px-4 py-2 text-sm font-medium text-white hover:bg-gray-600"
              >
                Validate
              </button>
              <button
                :if={@validated}
                type="button"
                phx-click="launch_gossip"
                class="rounded bg-cortex-600 px-4 py-2 text-sm font-medium text-white hover:bg-cortex-500"
              >
                Launch Gossip Run
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # -- Topology SVG --

  defp topology_svg(assigns) do
    nodes = assigns.nodes
    topology = assigns.topology
    selected = assigns.selected_node
    count = length(nodes)

    if count == 0 do
      ~H""
    else
      cx = 250
      cy = 250
      r = 180

      positions =
        nodes
        |> Enum.with_index()
        |> Enum.map(fn {node, idx} ->
          angle = 2 * :math.pi() * idx / count - :math.pi() / 2
          x = cx + r * :math.cos(angle)
          y = cy + r * :math.sin(angle)
          {node.name, {round(x), round(y)}}
        end)
        |> Map.new()

      selected_peers = if selected, do: Map.get(topology, selected, []), else: []

      edges = build_svg_edges(topology, positions, selected, selected_peers)

      node_circles =
        Enum.map(nodes, fn node ->
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

      assigns = assign(assigns, edges: edges, node_circles: node_circles)

      ~H"""
      <svg viewBox="0 0 500 500" class="w-full max-w-lg aspect-square">
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
          phx-click="select_node"
          phx-value-name={node.name}
          class="cursor-pointer"
        >
          <!-- Hover/selection ring -->
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
            fill={if node.selected, do: "#0c4a6e", else: node_fill(node.status)}
            stroke={if node.selected, do: "#38bdf8", else: if(node.peer, do: "#38bdf8", else: node_stroke(node.status))}
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
            fill={node_stroke(node.status)}
          />
        </g>
      </svg>
      """
    end
  end

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

  # -- Helpers --

  defp safe_subscribe do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp effective_yaml(socket) do
    cond do
      socket.assigns.yaml_content != "" ->
        socket.assigns.yaml_content

      socket.assigns.file_path != "" ->
        case File.read(socket.assigns.file_path) do
          {:ok, content} -> content
          _ -> ""
        end

      true ->
        ""
    end
  end

  defp safe_create_run(attrs) do
    Cortex.Store.create_run(attrs)
  rescue
    e -> {:error, e}
  end

  defp spawn_gossip(run, config, workspace_path) do
    run_id = run.id
    yaml = run.config_yaml

    Task.start(fn ->
      tmp_path = Path.join(System.tmp_dir!(), "cortex_gossip_#{run_id}.yaml")
      File.write!(tmp_path, yaml)

      try do
        {:ok, _summary} =
          SessionRunner.run_config(config,
            workspace_path: workspace_path
          )

        safe_update_run_status(run, "completed")
      rescue
        e ->
          safe_update_run_status(run, "failed")
          require Logger
          Logger.error("Gossip run #{run_id} crashed: #{inspect(e)}")
      after
        File.rm(tmp_path)
      end
    end)
  end

  defp safe_update_run_status(run, status) do
    case Cortex.Store.get_run(run.id) do
      nil -> :ok
      fresh -> Cortex.Store.update_run(fresh, %{status: status, completed_at: DateTime.utc_now()})
    end
  rescue
    _ -> :ok
  end

  defp node_dot_class(:online), do: "text-blue-400 animate-pulse"
  defp node_dot_class(:converged), do: "text-green-400"
  defp node_dot_class(_), do: "text-gray-600"

  defp node_status_text_class(:online), do: "text-blue-400"
  defp node_status_text_class(:converged), do: "text-green-400"
  defp node_status_text_class(_), do: "text-gray-500"

  defp node_status_label(:online), do: "Online"
  defp node_status_label(:converged), do: "Converged"
  defp node_status_label(_), do: "Offline"

  defp node_fill(:online), do: "#1e3a5f"
  defp node_fill(:converged), do: "#14532d"
  defp node_fill(_), do: "#1f2937"

  defp node_stroke(:online), do: "#3b82f6"
  defp node_stroke(:converged), do: "#22c55e"
  defp node_stroke(_), do: "#4b5563"

  defp confidence_class(c) when c >= 0.8, do: "text-green-400"
  defp confidence_class(c) when c >= 0.5, do: "text-yellow-400"
  defp confidence_class(_), do: "text-red-400"

  defp format_vector_clock(vc) when map_size(vc) == 0, do: "{}"

  defp format_vector_clock(vc) do
    vc
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join(" ", fn {k, v} -> "#{String.slice(k, 0, 3)}:#{v}" end)
  end

  defp format_time(nil), do: "-"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
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

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
