defmodule CortexWeb.MeshLive do
  @moduledoc """
  LiveView page for visualizing mesh protocol state.

  Shows SWIM-inspired membership with real-time failure detection,
  member state transitions, and inter-agent message relay.
  Subscribes to PubSub for live updates during active mesh sessions.
  """

  use CortexWeb, :live_view

  alias Cortex.Mesh.Config.Loader
  alias Cortex.Mesh.SessionRunner

  @max_activities 100
  @max_messages 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: safe_subscribe()

    {:ok,
     assign(socket,
       page_title: "Mesh Protocol",
       # Session state
       running: false,
       live_project: nil,
       run_id: nil,
       # Members from PubSub events
       members: [],
       # Activity feed
       activities: [],
       # Token tracking
       token_stats: %{},
       # Inter-agent messages
       messages: [],
       # UI state
       selected_member: nil,
       # Form state
       yaml_content: "",
       file_path: "",
       workspace_path: "",
       mesh_config: nil,
       validation_errors: [],
       validated: false
     )}
  end

  # -- PubSub handlers --

  @impl true
  def handle_info(%{type: :mesh_started, payload: payload}, socket) do
    agents = Map.get(payload, :agents, [])
    project = Map.get(payload, :project, "unknown")

    members =
      Enum.map(agents, fn name ->
        %{
          name: name,
          role: nil,
          state: :alive,
          incarnation: 0,
          last_seen: DateTime.utc_now(),
          started_at: DateTime.utc_now(),
          died_at: nil,
          os_pid: nil
        }
      end)

    {:noreply,
     assign(socket,
       live_project: project,
       members: members,
       running: true,
       activities: [activity(:mesh_started, project, nil)],
       messages: [],
       token_stats: %{},
       selected_member: nil
     )}
  end

  def handle_info(%{type: :member_joined, payload: payload}, socket) do
    name = Map.get(payload, :name)
    role = Map.get(payload, :role)

    members =
      update_or_add_member(socket.assigns.members, name, fn m ->
        %{m | role: role, state: :alive}
      end)

    {:noreply,
     assign(socket,
       members: members,
       activities: push_activity(socket.assigns.activities, :member_joined, name, role)
     )}
  end

  def handle_info(%{type: :member_suspect, payload: payload}, socket) do
    name = Map.get(payload, :name)

    members =
      update_member_in_list(socket.assigns.members, name, fn m ->
        %{m | state: :suspect}
      end)

    {:noreply,
     assign(socket,
       members: members,
       activities: push_activity(socket.assigns.activities, :member_suspect, name, nil)
     )}
  end

  def handle_info(%{type: :member_alive, payload: payload}, socket) do
    name = Map.get(payload, :name)

    members =
      update_member_in_list(socket.assigns.members, name, fn m ->
        %{m | state: :alive, incarnation: m.incarnation + 1, last_seen: DateTime.utc_now()}
      end)

    {:noreply,
     assign(socket,
       members: members,
       activities: push_activity(socket.assigns.activities, :member_alive, name, nil)
     )}
  end

  def handle_info(%{type: :member_dead, payload: payload}, socket) do
    name = Map.get(payload, :name)

    members =
      update_member_in_list(socket.assigns.members, name, fn m ->
        %{m | state: :dead, died_at: DateTime.utc_now()}
      end)

    {:noreply,
     assign(socket,
       members: members,
       activities: push_activity(socket.assigns.activities, :member_dead, name, nil)
     )}
  end

  def handle_info(%{type: :member_left, payload: payload}, socket) do
    name = Map.get(payload, :name)

    members =
      update_member_in_list(socket.assigns.members, name, fn m ->
        %{m | state: :left, died_at: DateTime.utc_now()}
      end)

    {:noreply,
     assign(socket,
       members: members,
       activities: push_activity(socket.assigns.activities, :member_left, name, nil)
     )}
  end

  def handle_info(%{type: :mesh_completed, payload: payload}, socket) do
    duration = Map.get(payload, :duration_ms, 0)

    {:noreply,
     assign(socket,
       running: false,
       activities:
         push_activity(
           socket.assigns.activities,
           :mesh_completed,
           "session",
           "#{div(duration, 1000)}s"
         )
     )}
  end

  def handle_info(%{type: :team_tokens_updated, payload: payload}, socket) do
    name = Map.get(payload, :team_name)

    stats =
      Map.put(socket.assigns.token_stats, name, %{
        input: Map.get(payload, :input_tokens, 0),
        output: Map.get(payload, :output_tokens, 0)
      })

    {:noreply, assign(socket, token_stats: stats)}
  end

  def handle_info(%{type: :team_activity, payload: payload}, socket) do
    name = Map.get(payload, :team_name)
    detail = Map.get(payload, :type, :unknown) |> to_string()

    {:noreply,
     assign(socket,
       activities: push_activity(socket.assigns.activities, :team_activity, name, detail)
     )}
  end

  def handle_info(%{type: :team_progress, payload: payload}, socket) do
    name = Map.get(payload, :team_name)
    message = Map.get(payload, :message, %{})

    msg_entry = %{
      from: name,
      to: Map.get(message, "to"),
      content: Map.get(message, "content", ""),
      timestamp: DateTime.utc_now()
    }

    messages = [msg_entry | socket.assigns.messages] |> Enum.take(@max_messages)

    {:noreply,
     assign(socket,
       messages: messages,
       activities: push_activity(socket.assigns.activities, :team_progress, name, nil)
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Event handlers --

  @impl true
  def handle_event("select_member", %{"name" => name}, socket) do
    selected =
      if socket.assigns.selected_member == name do
        nil
      else
        name
      end

    {:noreply, assign(socket, selected_member: selected)}
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
       mesh_config: nil,
       validated: false,
       validation_errors: []
     )}
  end

  def handle_event("validate_mesh", params, socket) do
    yaml = Map.get(params, "yaml", socket.assigns.yaml_content)
    path = Map.get(params, "path", socket.assigns.file_path)
    workspace = Map.get(params, "workspace_path", socket.assigns.workspace_path)

    socket = assign(socket, yaml_content: yaml, file_path: path, workspace_path: workspace)
    effective = effective_yaml(socket)

    if effective == "" do
      {:noreply,
       assign(socket,
         validation_errors: ["Please provide YAML content or a file path"],
         mesh_config: nil,
         validated: false
       )}
    else
      case Loader.load_string(effective) do
        {:ok, config} ->
          {:noreply,
           assign(socket,
             mesh_config: config,
             validated: true,
             validation_errors: []
           )}

        {:error, errors} ->
          {:noreply,
           assign(socket,
             validation_errors: errors,
             mesh_config: nil,
             validated: false
           )}
      end
    end
  end

  def handle_event("launch_mesh", _params, socket) do
    config = socket.assigns.mesh_config

    if config == nil do
      {:noreply, put_flash(socket, :error, "Validate configuration first")}
    else
      yaml = effective_yaml(socket)
      workspace = String.trim(socket.assigns.workspace_path)

      workspace_path =
        if workspace != "" do
          workspace
        else
          Path.join(System.tmp_dir!(), "cortex_mesh_#{Uniq.UUID.uuid4() |> String.slice(0, 8)}")
        end

      run_attrs = %{
        name: config.name,
        config_yaml: yaml,
        status: "pending",
        mode: "mesh",
        team_count: length(config.agents),
        started_at: DateTime.utc_now(),
        workspace_path: workspace_path
      }

      case safe_create_run(run_attrs) do
        {:ok, run} ->
          spawn_mesh(run, config, workspace_path)

          {:noreply,
           socket
           |> put_flash(:info, "Mesh run started!")
           |> push_navigate(to: "/runs/#{run.id}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to create run")}
      end
    end
  end

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-7xl mx-auto">
      <div class="mb-6">
        <h1 class="text-2xl font-bold text-white">Mesh Protocol</h1>
        <p class="text-sm text-gray-500 mt-1">
          SWIM-inspired autonomous agent membership
          <%= if @live_project do %>
            — <span class="text-cortex-400">{@live_project}</span>
          <% end %>
        </p>
      </div>

      <%= if @running do %>
        <div class="bg-blue-900/30 border border-blue-800 rounded-lg p-3 mb-6 flex items-center gap-3">
          <span class="text-blue-400 animate-pulse">●</span>
          <span class="text-blue-300 text-sm">
            Mesh session active — {alive_count(@members)} of {length(@members)} agents alive
          </span>
        </div>
      <% end %>

      <%= if @members != [] do %>
        <!-- Main layout: topology + detail panel -->
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6 mb-6">
          <!-- Topology Graph (2/3) -->
          <div class="lg:col-span-2">
            <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
              <div class="flex items-center justify-between mb-3">
                <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">
                  Member Topology
                  <span class="text-gray-600 normal-case font-normal ml-1">(full mesh)</span>
                </h2>
                <div class="flex items-center gap-4 text-xs">
                  <span class="flex items-center gap-1">
                    <span class="text-blue-400">●</span> alive
                  </span>
                  <span class="flex items-center gap-1">
                    <span class="text-yellow-400">●</span> suspect
                  </span>
                  <span class="flex items-center gap-1">
                    <span class="text-red-400">●</span> dead
                  </span>
                  <span class="flex items-center gap-1">
                    <span class="text-gray-500">●</span> left
                  </span>
                  <span class="text-gray-600">{length(@members)} nodes</span>
                </div>
              </div>
              <div class="flex justify-center">
                {topology_svg(assigns)}
              </div>
              <p class="text-xs text-gray-600 text-center mt-2">Click a node to inspect</p>
            </div>
          </div>

          <!-- Member Detail Panel (1/3) -->
          <div>
            <%= if @selected_member do %>
              <% member = Enum.find(@members, &(&1.name == @selected_member)) %>
              <% tokens = Map.get(@token_stats, @selected_member, %{input: 0, output: 0}) %>
              <% member_msgs = Enum.filter(@messages, fn m -> m.from == @selected_member || m.to == @selected_member end) %>
              <div class="bg-gray-900 rounded-lg border border-cortex-800 p-4 space-y-4">
                <!-- Header -->
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <span class={if(member, do: member_dot_class(member.state), else: "text-gray-600")}>●</span>
                    <h2 class="text-lg font-bold text-white">{@selected_member}</h2>
                  </div>
                  <button
                    phx-click="select_member"
                    phx-value-name={@selected_member}
                    class="text-gray-600 hover:text-gray-400 text-sm"
                  >
                    ✕
                  </button>
                </div>

                <!-- Status grid -->
                <div :if={member} class="grid grid-cols-2 gap-2 text-xs">
                  <div class="bg-gray-950 rounded p-2">
                    <span class="text-gray-500">State</span>
                    <p class={member_state_text_class(member.state)}>{member.state}</p>
                  </div>
                  <div class="bg-gray-950 rounded p-2">
                    <span class="text-gray-500">Incarnation</span>
                    <p class="text-gray-300">{member.incarnation}</p>
                  </div>
                  <div class="bg-gray-950 rounded p-2">
                    <span class="text-gray-500">Role</span>
                    <p class="text-gray-300">{member.role || "—"}</p>
                  </div>
                  <div class="bg-gray-950 rounded p-2">
                    <span class="text-gray-500">Last Seen</span>
                    <p class="text-gray-300">{format_time(member.last_seen)}</p>
                  </div>
                  <div class="bg-gray-950 rounded p-2">
                    <span class="text-gray-500">Tokens In</span>
                    <p class="text-cortex-400 font-mono">{format_number(tokens.input)}</p>
                  </div>
                  <div class="bg-gray-950 rounded p-2">
                    <span class="text-gray-500">Tokens Out</span>
                    <p class="text-cortex-400 font-mono">{format_number(tokens.output)}</p>
                  </div>
                </div>

                <!-- Messages involving this member -->
                <div :if={member_msgs != []}>
                  <h3 class="text-xs text-gray-500 uppercase tracking-wider mb-2">
                    Messages ({length(member_msgs)})
                  </h3>
                  <div class="space-y-1 max-h-48 overflow-y-auto">
                    <div
                      :for={msg <- Enum.take(member_msgs, 10)}
                      class="bg-gray-950 rounded p-2 text-xs"
                    >
                      <div class="flex items-center gap-2 mb-1">
                        <span class="text-cortex-300">{msg.from}</span>
                        <span class="text-gray-600">→</span>
                        <span class="text-cortex-300">{msg.to || "broadcast"}</span>
                        <span class="text-gray-700 ml-auto">{format_time(msg.timestamp)}</span>
                      </div>
                      <p class="text-gray-400 truncate">{truncate(msg.content, 120)}</p>
                    </div>
                  </div>
                </div>
              </div>
            <% else %>
              <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 text-center h-full flex flex-col justify-center">
                <p class="text-gray-600 text-sm">Select a node in the graph</p>
                <p class="text-gray-700 text-xs mt-1">to see its state, tokens, and messages</p>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Activity Feed + Roster Table -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Activity Feed -->
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
            <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">
              Activity Feed ({length(@activities)})
            </h2>
            <%= if @activities != [] do %>
              <div class="space-y-1 max-h-[50vh] overflow-y-auto">
                <div
                  :for={act <- Enum.take(@activities, 50)}
                  class="flex items-center gap-2 text-xs py-1 border-b border-gray-800/50"
                >
                  <span class="text-gray-700 font-mono w-16 shrink-0">{format_time(act.timestamp)}</span>
                  <span class={activity_icon_class(act.type)}>{activity_icon(act.type)}</span>
                  <span class="text-gray-300">{act.name}</span>
                  <span :if={act.detail} class="text-gray-600">{act.detail}</span>
                </div>
              </div>
            <% else %>
              <p class="text-gray-500 text-sm">Waiting for events...</p>
            <% end %>
          </div>

          <!-- Roster Table -->
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
            <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">
              Member Roster
            </h2>
            <div class="overflow-x-auto">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b border-gray-800">
                    <th class="text-left text-gray-500 text-xs uppercase py-2 pr-3">Name</th>
                    <th class="text-left text-gray-500 text-xs uppercase py-2 pr-3">Role</th>
                    <th class="text-center text-gray-500 text-xs uppercase py-2 px-2">State</th>
                    <th class="text-center text-gray-500 text-xs uppercase py-2 px-2">Inc</th>
                    <th class="text-right text-gray-500 text-xs uppercase py-2 px-2">Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={member <- Enum.sort_by(@members, & &1.name)}
                    phx-click="select_member"
                    phx-value-name={member.name}
                    class={[
                      "border-b border-gray-800/50 cursor-pointer hover:bg-gray-800/50 transition-colors",
                      if(@selected_member == member.name, do: "bg-cortex-900/20", else: "")
                    ]}
                  >
                    <td class="py-2 pr-3">
                      <span class="text-white">{member.name}</span>
                    </td>
                    <td class="py-2 pr-3">
                      <span class="text-gray-400 text-xs">{member.role || "—"}</span>
                    </td>
                    <td class="py-2 px-2 text-center">
                      <span class={state_badge_class(member.state)}>
                        {member.state}
                      </span>
                    </td>
                    <td class="py-2 px-2 text-center">
                      <span class="text-gray-400 font-mono text-xs">{member.incarnation}</span>
                    </td>
                    <td class="py-2 px-2 text-right">
                      <% t = Map.get(@token_stats, member.name, %{input: 0, output: 0}) %>
                      <span class="text-cortex-400 font-mono text-xs">
                        {format_number(t.input + t.output)}
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      <% end %>

      <!-- New Mesh Run Form -->
      <div class="mt-6">
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <h2 class="text-lg font-semibold text-white mb-4">New Mesh Run</h2>
          <form phx-change="form_changed" phx-submit="validate_mesh">
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-4">
              <div>
                <label class="text-xs text-gray-500 block mb-1">Mesh YAML</label>
                <textarea
                  name="yaml"
                  rows="10"
                  class="w-full bg-gray-950 border border-gray-700 rounded p-3 text-sm font-mono text-gray-300 resize-y"
                  placeholder="Paste mesh.yaml content..."
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
                    placeholder="/path/to/mesh.yaml"
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
                <%= if @mesh_config do %>
                  <div class="bg-gray-950 rounded p-3 text-sm space-y-1">
                    <div><span class="text-gray-500">Project:</span> <span class="text-white">{@mesh_config.name}</span></div>
                    <div><span class="text-gray-500">Agents:</span> <span class="text-white">{length(@mesh_config.agents)}</span></div>
                    <div><span class="text-gray-500">Heartbeat:</span> <span class="text-white">{@mesh_config.mesh.heartbeat_interval_seconds}s</span></div>
                    <div><span class="text-gray-500">Suspect timeout:</span> <span class="text-white">{@mesh_config.mesh.suspect_timeout_seconds}s</span></div>
                    <div><span class="text-gray-500">Dead timeout:</span> <span class="text-white">{@mesh_config.mesh.dead_timeout_seconds}s</span></div>
                    <div class="flex flex-wrap gap-1 pt-1">
                      <span
                        :for={agent <- @mesh_config.agents}
                        class="bg-emerald-900/50 text-emerald-300 text-xs px-2 py-0.5 rounded"
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
                phx-click="launch_mesh"
                class="rounded bg-cortex-600 px-4 py-2 text-sm font-medium text-white hover:bg-cortex-500"
              >
                Launch Mesh Run
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
    members = assigns.members
    selected = assigns.selected_member
    count = length(members)

    if count == 0 do
      ~H""
    else
      cx = 250
      cy = 250
      r = 180

      positions =
        members
        |> Enum.with_index()
        |> Enum.map(fn {member, idx} ->
          angle = 2 * :math.pi() * idx / count - :math.pi() / 2
          x = cx + r * :math.cos(angle)
          y = cy + r * :math.sin(angle)
          {member.name, {round(x), round(y)}}
        end)
        |> Map.new()

      # Full mesh edges between all active members
      active_names =
        members
        |> Enum.filter(fn m -> m.state in [:alive, :suspect] end)
        |> Enum.map(& &1.name)

      edges = build_mesh_edges(active_names, positions, selected)

      node_circles =
        Enum.map(members, fn member ->
          {x, y} = Map.get(positions, member.name, {0, 0})

          %{
            name: member.name,
            x: x,
            y: y,
            state: member.state,
            selected: member.name == selected
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
          stroke-opacity={if edge.highlighted, do: "0.8", else: "0.4"}
        />
        <!-- Nodes -->
        <g
          :for={node <- @node_circles}
          phx-click="select_member"
          phx-value-name={node.name}
          class="cursor-pointer"
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
            fill={if node.selected, do: "#0c4a6e", else: member_fill(node.state)}
            stroke={if node.selected, do: "#38bdf8", else: member_stroke(node.state)}
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
            fill={member_stroke(node.state)}
          />
        </g>
      </svg>
      """
    end
  end

  defp build_mesh_edges(active_names, positions, selected) do
    pairs =
      for a <- active_names,
          b <- active_names,
          a < b,
          do: {a, b}

    Enum.map(pairs, fn {from, to} ->
      {fx, fy} = Map.get(positions, from, {0, 0})
      {tx, ty} = Map.get(positions, to, {0, 0})

      highlighted = selected != nil and (from == selected or to == selected)

      %{x1: fx, y1: fy, x2: tx, y2: ty, highlighted: highlighted}
    end)
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

  defp spawn_mesh(run, config, workspace_path) do
    run_id = run.id
    yaml = run.config_yaml

    Task.start(fn ->
      tmp_path = Path.join(System.tmp_dir!(), "cortex_mesh_#{run_id}.yaml")
      File.write!(tmp_path, yaml)

      safe_update_run_status(run, "running")

      try do
        {:ok, summary} =
          SessionRunner.run_config(config,
            workspace_path: workspace_path,
            run_id: run_id
          )

        safe_update_run_complete(run, summary)
      rescue
        e ->
          trace = Exception.format(:error, e, __STACKTRACE__)
          safe_update_run_failed(run, "#{inspect(e)}")
          require Logger
          Logger.error("Mesh run #{run_id} crashed:\n#{trace}")
      after
        File.rm(tmp_path)
      end
    end)
  end

  defp safe_update_run_complete(run, summary) do
    case Cortex.Store.get_run(run.id) do
      nil ->
        :ok

      fresh ->
        Cortex.Store.update_run(fresh, %{
          status: "completed",
          completed_at: DateTime.utc_now(),
          total_cost_usd: Map.get(summary, :total_cost, 0.0),
          total_input_tokens: Map.get(summary, :total_input_tokens, 0),
          total_output_tokens: Map.get(summary, :total_output_tokens, 0),
          total_duration_ms: Map.get(summary, :total_duration_ms, 0)
        })
    end
  rescue
    _ -> :ok
  end

  defp safe_update_run_status(run, status) do
    case Cortex.Store.get_run(run.id) do
      nil -> :ok
      fresh -> Cortex.Store.update_run(fresh, %{status: status})
    end
  rescue
    _ -> :ok
  end

  defp safe_update_run_failed(run, error_msg) do
    case Cortex.Store.get_run(run.id) do
      nil ->
        :ok

      fresh ->
        truncated = if String.length(error_msg) > 500, do: String.slice(error_msg, 0, 500), else: error_msg

        Cortex.Store.update_run(fresh, %{
          status: "failed",
          completed_at: DateTime.utc_now(),
          name: "#{fresh.name} [ERROR: #{truncated}]"
        })
    end
  rescue
    _ -> :ok
  end

  # -- Member list helpers --

  defp update_member_in_list(members, name, fun) do
    Enum.map(members, fn m ->
      if m.name == name, do: fun.(m), else: m
    end)
  end

  defp update_or_add_member(members, name, fun) do
    if Enum.any?(members, &(&1.name == name)) do
      update_member_in_list(members, name, fun)
    else
      new = %{
        name: name,
        role: nil,
        state: :alive,
        incarnation: 0,
        last_seen: DateTime.utc_now(),
        started_at: DateTime.utc_now(),
        died_at: nil,
        os_pid: nil
      }

      members ++ [fun.(new)]
    end
  end

  defp alive_count(members) do
    Enum.count(members, &(&1.state == :alive))
  end

  # -- Activity helpers --

  defp activity(type, name, detail) do
    %{type: type, name: name, detail: detail, timestamp: DateTime.utc_now()}
  end

  defp push_activity(activities, type, name, detail) do
    [activity(type, name, detail) | activities] |> Enum.take(@max_activities)
  end

  defp activity_icon(:mesh_started), do: "▶"
  defp activity_icon(:mesh_completed), do: "■"
  defp activity_icon(:member_joined), do: "+"
  defp activity_icon(:member_alive), do: "♥"
  defp activity_icon(:member_suspect), do: "?"
  defp activity_icon(:member_dead), do: "✕"
  defp activity_icon(:member_left), do: "←"
  defp activity_icon(:team_activity), do: "⚡"
  defp activity_icon(:team_progress), do: "✉"
  defp activity_icon(_), do: "·"

  defp activity_icon_class(:member_joined), do: "text-green-400"
  defp activity_icon_class(:member_alive), do: "text-blue-400"
  defp activity_icon_class(:member_suspect), do: "text-yellow-400"
  defp activity_icon_class(:member_dead), do: "text-red-400"
  defp activity_icon_class(:member_left), do: "text-gray-400"
  defp activity_icon_class(:mesh_started), do: "text-cortex-400"
  defp activity_icon_class(:mesh_completed), do: "text-cortex-400"
  defp activity_icon_class(:team_progress), do: "text-purple-400"
  defp activity_icon_class(_), do: "text-gray-500"

  # -- Visual helpers --

  defp member_dot_class(:alive), do: "text-blue-400 animate-pulse"
  defp member_dot_class(:suspect), do: "text-yellow-400 animate-pulse"
  defp member_dot_class(:dead), do: "text-red-400"
  defp member_dot_class(:left), do: "text-gray-500"
  defp member_dot_class(_), do: "text-gray-600"

  defp member_state_text_class(:alive), do: "text-blue-400"
  defp member_state_text_class(:suspect), do: "text-yellow-400"
  defp member_state_text_class(:dead), do: "text-red-400"
  defp member_state_text_class(:left), do: "text-gray-400"
  defp member_state_text_class(_), do: "text-gray-500"

  defp member_fill(:alive), do: "#1e3a5f"
  defp member_fill(:suspect), do: "#713f12"
  defp member_fill(:dead), do: "#7f1d1d"
  defp member_fill(:left), do: "#1f2937"
  defp member_fill(_), do: "#1f2937"

  defp member_stroke(:alive), do: "#3b82f6"
  defp member_stroke(:suspect), do: "#eab308"
  defp member_stroke(:dead), do: "#ef4444"
  defp member_stroke(:left), do: "#4b5563"
  defp member_stroke(_), do: "#4b5563"

  defp state_badge_class(:alive) do
    "bg-blue-900/50 text-blue-300 text-xs px-2 py-0.5 rounded"
  end

  defp state_badge_class(:suspect) do
    "bg-yellow-900/50 text-yellow-300 text-xs px-2 py-0.5 rounded"
  end

  defp state_badge_class(:dead) do
    "bg-red-900/50 text-red-300 text-xs px-2 py-0.5 rounded"
  end

  defp state_badge_class(:left) do
    "bg-gray-800 text-gray-400 text-xs px-2 py-0.5 rounded"
  end

  defp state_badge_class(_) do
    "bg-gray-800 text-gray-500 text-xs px-2 py-0.5 rounded"
  end

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: "#{n}"

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
