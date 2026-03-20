defmodule CortexWeb.MeshComponents do
  @moduledoc """
  Mesh protocol visualization components for the Cortex UI.

  Extracted from MeshLive's render logic. Provides mesh overview,
  membership table, member card, and topology SVG. Used by RunDetailLive's
  Overview tab for mesh-mode runs.
  """
  use Phoenix.Component

  alias CortexWeb.StatusComponents

  # -- Mesh Overview --

  @doc """
  Renders a mesh protocol overview panel with session status and member counts.

  ## Examples

      <.mesh_overview
        project="my-mesh"
        running={true}
        members={members}
      />
  """
  attr(:project, :string, default: nil)
  attr(:running, :boolean, default: false)
  attr(:members, :list, default: [])
  attr(:class, :string, default: nil)

  def mesh_overview(assigns) do
    alive = Enum.count(assigns.members, &(&1.state == :alive))
    assigns = assign(assigns, :alive_count, alive)

    ~H"""
    <div class={["space-y-4", @class]}>
      <div :if={@running} class="bg-blue-900/30 border border-blue-800 rounded-lg p-3 flex items-center gap-3">
        <StatusComponents.status_dot status={:alive} pulse={true} />
        <span class="text-blue-300 text-sm">
          Mesh session active
          <span :if={@project}> &mdash; <span class="text-cortex-400">{@project}</span></span>
          &mdash; {@alive_count} of {length(@members)} agents alive
        </span>
      </div>
    </div>
    """
  end

  # -- Mesh Topology SVG --

  @doc """
  Renders mesh topology SVG with interactive node selection.
  """
  attr(:members, :list, required: true)
  attr(:selected_member, :string, default: nil)
  attr(:click_event, :string, default: "select_member")

  def mesh_topology(assigns) do
    count = length(assigns.members)

    if count == 0 do
      ~H""
    else
      cx = 250
      cy = 250
      r = 180

      positions =
        assigns.members
        |> Enum.with_index()
        |> Enum.map(fn {member, idx} ->
          angle = 2 * :math.pi() * idx / count - :math.pi() / 2
          x = cx + r * :math.cos(angle)
          y = cy + r * :math.sin(angle)
          {member.name, {round(x), round(y)}}
        end)
        |> Map.new()

      selected = assigns.selected_member

      active_names =
        assigns.members
        |> Enum.filter(fn m -> m.state in [:alive, :suspect] end)
        |> Enum.map(& &1.name)

      edges = build_mesh_edges(active_names, positions, selected)

      node_circles =
        Enum.map(assigns.members, fn member ->
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
      <svg viewBox="0 0 500 500" class="w-full max-w-lg aspect-square" role="img" aria-label="Mesh topology graph">
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

  # -- Membership Table --

  @doc """
  Renders mesh membership roster table with status badges and incarnation numbers.

  ## Examples

      <.membership_table members={members} selected_member="alpha" token_stats={stats} />
  """
  attr(:members, :list, required: true)
  attr(:selected_member, :string, default: nil)
  attr(:token_stats, :map, default: %{})
  attr(:click_event, :string, default: "select_member")
  attr(:class, :string, default: nil)

  def membership_table(assigns) do
    ~H"""
    <div class={["overflow-x-auto", @class]}>
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
            phx-click={@click_event}
            phx-value-name={member.name}
            class={[
              "border-b border-gray-800/50 cursor-pointer hover:bg-gray-800/50 transition-colors",
              if(@selected_member == member.name, do: "bg-cortex-900/20", else: "")
            ]}
            role="button"
            aria-selected={to_string(@selected_member == member.name)}
          >
            <td class="py-2 pr-3">
              <span class="text-white">{member.name}</span>
            </td>
            <td class="py-2 pr-3">
              <span class="text-gray-400 text-xs">{member.role || "\u2014"}</span>
            </td>
            <td class="py-2 px-2 text-center">
              <StatusComponents.status_badge status={member.state} />
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
    """
  end

  # -- Member Card --

  @doc """
  Renders a detailed member card showing state, heartbeat, and load.

  ## Examples

      <.member_card member={member} selected={true} token_stats={stats} />
  """
  attr(:member, :map, required: true)
  attr(:selected, :boolean, default: false)
  attr(:token_stats, :map, default: %{input: 0, output: 0})
  attr(:messages, :list, default: [])
  attr(:on_close, :string, default: nil)
  attr(:class, :string, default: nil)

  def member_card(assigns) do
    ~H"""
    <div class={["bg-gray-900 rounded-lg border border-cortex-800 p-4 space-y-4", @class]}>
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <StatusComponents.status_dot status={@member.state} pulse={@member.state == :alive} />
          <h2 class="text-lg font-bold text-white">{@member.name}</h2>
        </div>
        <button
          :if={@on_close}
          phx-click={@on_close}
          phx-value-name={@member.name}
          class="text-gray-600 hover:text-gray-400 text-sm"
          aria-label={"Close #{@member.name} detail"}
        >
          &#x2715;
        </button>
      </div>

      <%!-- Status grid --%>
      <div class="grid grid-cols-2 gap-2 text-xs">
        <div class="bg-gray-950 rounded p-2">
          <span class="text-gray-500">State</span>
          <p>
            <StatusComponents.status_badge status={@member.state} />
          </p>
        </div>
        <div class="bg-gray-950 rounded p-2">
          <span class="text-gray-500">Incarnation</span>
          <p class="text-gray-300">{@member.incarnation}</p>
        </div>
        <div class="bg-gray-950 rounded p-2">
          <span class="text-gray-500">Role</span>
          <p class="text-gray-300">{@member.role || "\u2014"}</p>
        </div>
        <div class="bg-gray-950 rounded p-2">
          <span class="text-gray-500">Last Seen</span>
          <p class="text-gray-300">{format_time(@member.last_seen)}</p>
        </div>
        <div class="bg-gray-950 rounded p-2">
          <span class="text-gray-500">Tokens In</span>
          <p class="text-cortex-400 font-mono">{format_number(@token_stats.input)}</p>
        </div>
        <div class="bg-gray-950 rounded p-2">
          <span class="text-gray-500">Tokens Out</span>
          <p class="text-cortex-400 font-mono">{format_number(@token_stats.output)}</p>
        </div>
      </div>

      <%!-- Messages --%>
      <div :if={@messages != []}>
        <h3 class="text-xs text-gray-500 uppercase tracking-wider mb-2">
          Messages ({length(@messages)})
        </h3>
        <div class="space-y-1 max-h-48 overflow-y-auto">
          <div
            :for={msg <- Enum.take(@messages, 10)}
            class="bg-gray-950 rounded p-2 text-xs"
          >
            <div class="flex items-center gap-2 mb-1">
              <span class="text-cortex-300">{msg.from}</span>
              <span class="text-gray-600">&rarr;</span>
              <span class="text-cortex-300">{msg.to || "broadcast"}</span>
              <span class="text-gray-700 ml-auto">{format_time(msg.timestamp)}</span>
            </div>
            <p class="text-gray-400 truncate">{truncate(msg.content, 120)}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Mesh Legend --

  @doc """
  Renders the topology legend for mesh states.
  """
  attr(:class, :string, default: nil)

  def mesh_legend(assigns) do
    ~H"""
    <div class={["flex items-center gap-4 text-xs", @class]} role="legend" aria-label="Mesh state legend">
      <span class="flex items-center gap-1">
        <span class="text-blue-400">&#9679;</span> alive
      </span>
      <span class="flex items-center gap-1">
        <span class="text-yellow-400">&#9679;</span> suspect
      </span>
      <span class="flex items-center gap-1">
        <span class="text-red-400">&#9679;</span> dead
      </span>
      <span class="flex items-center gap-1">
        <span class="text-gray-500">&#9679;</span> left
      </span>
    </div>
    """
  end

  # -- Communication Graph (animated) --

  @doc """
  Renders an animated mesh communication graph.

  Nodes are placed radially. Edges animate with flowing dashes in the
  direction of message traffic, plus small traveling particles. Edge
  thickness scales with message volume. Bidirectional flows get two
  offset lines flowing in opposite directions.

  ## Attributes

    * `agents` — list of maps with `:name` and `:status` (string)
    * `message_flows` — the aggregated flows map from Helpers
  """
  attr(:agents, :list, required: true)
  attr(:message_flows, :map, required: true)
  attr(:selected_node, :string, default: nil)
  attr(:run_status, :string, default: "running")

  def communication_graph(assigns) do
    count = length(assigns.agents)

    if count == 0 do
      ~H""
    else
      cx = 250
      cy = 250
      r = if(count <= 4, do: 140, else: 180)

      positions =
        assigns.agents
        |> Enum.with_index()
        |> Enum.map(fn {agent, idx} ->
          angle = 2 * :math.pi() * idx / count - :math.pi() / 2
          x = cx + r * :math.cos(angle)
          y = cy + r * :math.sin(angle)
          {agent.name, {round(x), round(y)}}
        end)
        |> Map.new()

      # Build flow lookup: {from, to} => count
      flow_map =
        assigns.message_flows.flows
        |> Enum.map(fn f -> {{f.from, f.to}, f.count} end)
        |> Map.new()

      max_count =
        case assigns.message_flows.flows do
          [top | _] -> max(top.count, 1)
          [] -> 1
        end

      # Build directed edges with animation data
      agent_names = Enum.map(assigns.agents, & &1.name)

      pairs =
        for a <- agent_names, b <- agent_names, a < b, do: {a, b}

      edges =
        Enum.flat_map(pairs, fn {a, b} ->
          ab = Map.get(flow_map, {a, b}, 0)
          ba = Map.get(flow_map, {b, a}, 0)
          {ax, ay} = Map.get(positions, a, {0, 0})
          {bx, by} = Map.get(positions, b, {0, 0})

          cond do
            ab > 0 and ba > 0 ->
              # Bidirectional: offset two lines perpendicular to the edge
              {ox, oy} = perp_offset(ax, ay, bx, by, 4)

              [
                %{
                  x1: ax + ox, y1: ay + oy, x2: bx + ox, y2: by + oy,
                  count: ab, max: max_count, direction: :forward,
                  id: "#{a}-#{b}", from: a, to: b
                },
                %{
                  x1: bx - ox, y1: by - oy, x2: ax - ox, y2: ay - oy,
                  count: ba, max: max_count, direction: :forward,
                  id: "#{b}-#{a}", from: b, to: a
                }
              ]

            ab > 0 ->
              [%{
                x1: ax, y1: ay, x2: bx, y2: by,
                count: ab, max: max_count, direction: :forward,
                id: "#{a}-#{b}", from: a, to: b
              }]

            ba > 0 ->
              [%{
                x1: bx, y1: by, x2: ax, y2: ay,
                count: ba, max: max_count, direction: :forward,
                id: "#{b}-#{a}", from: b, to: a
              }]

            true ->
              # No messages — background edge
              [%{
                x1: ax, y1: ay, x2: bx, y2: by,
                count: 0, max: max_count, direction: :none,
                id: "bg-#{a}-#{b}", from: a, to: b
              }]
          end
        end)

      selected = assigns.selected_node

      nodes =
        Enum.map(assigns.agents, fn agent ->
          {x, y} = Map.get(positions, agent.name, {0, 0})
          agent_stats = Map.get(assigns.message_flows.by_agent, agent.name, %{sent: 0, received: 0})
          total = agent_stats.sent + agent_stats.received

          %{
            name: agent.name, x: x, y: y, status: agent.status,
            total: total, selected: agent.name == selected,
            role: Map.get(agent, :role)
          }
        end)

      # Flows involving selected node
      selected_flows =
        if selected do
          assigns.message_flows.flows
          |> Enum.filter(fn f -> f.from == selected or f.to == selected end)
        else
          []
        end

      selected_agent =
        if selected, do: Enum.find(assigns.agents, &(&1.name == selected))

      selected_stats =
        if selected, do: Map.get(assigns.message_flows.by_agent, selected, %{sent: 0, received: 0})

      has_traffic = assigns.message_flows.total > 0
      run_active = assigns.run_status in ["running", "pending"]

      assigns =
        assigns
        |> assign(:edges, edges)
        |> assign(:nodes, nodes)
        |> assign(:has_traffic, has_traffic)
        |> assign(:animate, has_traffic and run_active)
        |> assign(:selected_flows, selected_flows)
        |> assign(:selected_agent, selected_agent)
        |> assign(:selected_stats, selected_stats)

      ~H"""
      <div class="flex gap-3 items-start">
      <svg viewBox="0 0 500 500" class={["aspect-square", if(@selected_agent, do: "w-2/3", else: "w-full max-w-xl mx-auto")]} role="img" aria-label="Agent communication graph">
        <defs>
          <marker id="flow-arrow" markerWidth="6" markerHeight="4" refX="6" refY="2" orient="auto">
            <polygon points="0 0, 6 2, 0 4" fill="#22d3ee" opacity="0.6" />
          </marker>
        </defs>
        <style>
          @keyframes dash-flow {
            to { stroke-dashoffset: -14; }
          }
          .flow-edge {
            stroke-dasharray: 8 6;
            animation: dash-flow 1.5s linear infinite;
          }
          .flow-edge-slow {
            stroke-dasharray: 8 6;
            animation: dash-flow 2.5s linear infinite;
          }
          .flow-static {
            stroke-dasharray: none;
          }
        </style>

        <%!-- Background edges (no traffic) --%>
        <line
          :for={edge <- Enum.filter(@edges, & &1.count == 0)}
          x1={edge.x1} y1={edge.y1} x2={edge.x2} y2={edge.y2}
          stroke="#1f2937" stroke-width="1" stroke-opacity="0.5"
        />

        <%!-- Active flow edges --%>
        <%= for edge <- Enum.filter(@edges, & &1.count > 0) do %>
          <% width = 1 + 2 * (edge.count / edge.max) %>
          <% opacity = 0.3 + 0.5 * (edge.count / edge.max) %>
          <g>
            <title>{edge.from} -> {edge.to}: {edge.count} messages</title>
            <%= if @animate do %>
              <% speed_class = if edge.count > edge.max * 0.5, do: "flow-edge", else: "flow-edge-slow" %>
              <line
                x1={edge.x1} y1={edge.y1} x2={edge.x2} y2={edge.y2}
                stroke="#22d3ee" stroke-width={width} stroke-opacity={opacity}
                class={speed_class}
                marker-end="url(#flow-arrow)"
              />
            <% else %>
              <line
                x1={edge.x1} y1={edge.y1} x2={edge.x2} y2={edge.y2}
                stroke="#22d3ee" stroke-width={width} stroke-opacity={opacity}
                marker-end="url(#flow-arrow)"
              />
            <% end %>
          </g>
          <%!-- Traveling particles (only when running) --%>
          <%= if @animate do %>
            <% dur = particle_dur(edge.count, edge.max) %>
            <circle r="3" fill="#22d3ee">
              <animateMotion
                dur={dur}
                repeatCount="indefinite"
                path={"M#{edge.x1},#{edge.y1} L#{edge.x2},#{edge.y2}"}
              />
              <animate
                attributeName="opacity"
                dur={dur}
                repeatCount="indefinite"
                values="0;0.9;0.9;0.9;0"
                keyTimes="0;0.08;0.5;0.92;1"
              />
            </circle>
            <%= if edge.count > edge.max * 0.4 do %>
              <% delay = particle_delay(edge.count, edge.max) %>
              <circle r="2" fill="#67e8f9">
                <animateMotion
                  dur={dur}
                  begin={delay}
                  repeatCount="indefinite"
                  path={"M#{edge.x1},#{edge.y1} L#{edge.x2},#{edge.y2}"}
                />
                <animate
                  attributeName="opacity"
                  dur={dur}
                  begin={delay}
                  repeatCount="indefinite"
                  values="0;0.7;0.7;0.7;0"
                  keyTimes="0;0.08;0.5;0.92;1"
                />
              </circle>
            <% end %>
          <% end %>
        <% end %>

        <%!-- Agent nodes --%>
        <%= for node <- @nodes do %>
          <g
            phx-click="select_graph_node"
            phx-value-name={node.name}
            class="cursor-pointer"
          >
            <%!-- Selection ring --%>
            <circle
              :if={node.selected}
              cx={node.x} cy={node.y} r="32"
              fill="none" stroke="#22d3ee" stroke-width="2"
              stroke-dasharray="4 2" opacity="0.7"
            />
            <%!-- Glow for active agents --%>
            <circle
              :if={node.total > 0 and not node.selected}
              cx={node.x} cy={node.y} r="30"
              fill="none" stroke="#22d3ee" stroke-width="1"
              opacity="0.2"
            />
            <%!-- Main circle --%>
            <circle
              cx={node.x} cy={node.y} r="24"
              fill={if(node.selected, do: "#0c4a6e", else: StatusComponents.svg_fill(node.status))}
              stroke={if(node.selected, do: "#22d3ee", else: if(node.total > 0, do: "#22d3ee", else: StatusComponents.svg_stroke(node.status)))}
              stroke-width={if(node.selected, do: "2.5", else: if(node.total > 0, do: "2", else: "1.5"))}
            />
            <%!-- Label --%>
            <text
              x={node.x} y={node.y + 4}
              text-anchor="middle" fill="white"
              font-size={node_font_size(node.name)}
              font-weight="600" font-family="monospace"
            >
              {abbrev(node.name)}
            </text>
            <%!-- Message count badge --%>
            <g :if={node.total > 0}>
              <circle cx={node.x + 18} cy={node.y - 18} r="8" fill="#0e7490" stroke="#22d3ee" stroke-width="1" />
              <text x={node.x + 18} y={node.y - 15} text-anchor="middle" fill="white" font-size="8" font-weight="bold">
                {node.total}
              </text>
            </g>
          </g>
        <% end %>

        <%!-- Legend --%>
        <g :if={@has_traffic} transform="translate(10, 470)">
          <line x1="0" y1="0" x2="20" y2="0" stroke="#22d3ee" stroke-width="2" class="flow-edge" marker-end="url(#flow-arrow)" />
          <text x="28" y="4" fill="#9ca3af" font-size="10">message flow</text>
        </g>
      </svg>

      <%!-- Detail sidebar for selected node --%>
      <%= if @selected_agent do %>
        <div class="w-1/3 bg-gray-950 rounded-lg border border-cortex-800 px-3 py-3 text-xs shrink-0">
          <div class="flex items-center justify-between mb-2">
            <div class="flex items-center gap-1.5">
              <StatusComponents.status_dot status={@selected_agent.status} pulse={@selected_agent.status in ["running", "alive"]} />
              <span class="text-white font-semibold">{@selected_agent.name}</span>
            </div>
            <button phx-click="select_graph_node" phx-value-name="" class="text-gray-500 hover:text-gray-300">&#x2715;</button>
          </div>
          <StatusComponents.status_badge status={@selected_agent.status} />
          <div :if={Map.get(@selected_agent, :role)} class="text-gray-400 mt-2 leading-snug">{@selected_agent.role}</div>
          <%= if @selected_stats do %>
            <div class="flex gap-3 mt-2 text-gray-500">
              <span><span class="text-cortex-400 font-mono">{@selected_stats.sent}</span> sent</span>
              <span><span class="text-cortex-400 font-mono">{@selected_stats.received}</span> recv</span>
            </div>
          <% end %>
          <%= if @selected_flows != [] do %>
            <div class="mt-2 pt-2 border-t border-gray-800 space-y-1">
              <div :for={flow <- @selected_flows} class="flex items-center gap-1">
                <span class={["font-mono", if(flow.from == @selected_node, do: "text-cortex-400", else: "text-white")]}>{flow.from}</span>
                <span class="text-gray-600">-></span>
                <span class={["font-mono", if(flow.to == @selected_node, do: "text-cortex-400", else: "text-white")]}>{flow.to}</span>
                <span class="text-gray-500 font-mono ml-auto">{flow.count}</span>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
      </div>
      """
    end
  end

  defp perp_offset(x1, y1, x2, y2, dist) do
    dx = x2 - x1
    dy = y2 - y1
    len = :math.sqrt(dx * dx + dy * dy)

    if len == 0 do
      {0, 0}
    else
      {round(-dy / len * dist), round(dx / len * dist)}
    end
  end

  defp particle_dur(count, max) do
    # Faster particles for higher traffic: 4.5s down to 2s
    speed = 4.5 - 2.5 * (count / max)
    "#{Float.round(speed, 1)}s"
  end

  defp particle_delay(count, max) do
    dur = 4.5 - 2.5 * (count / max)
    "#{Float.round(dur / 2, 1)}s"
  end

  defp node_font_size(name) do
    len = String.length(name)
    cond do
      len <= 6 -> "11"
      len <= 10 -> "9"
      true -> "8"
    end
  end

  defp abbrev(name) do
    len = String.length(name)
    cond do
      len <= 10 -> name
      # Try to keep first word + abbreviate rest: "app-logs-analyst" -> "app-logs-a.."
      true -> String.slice(name, 0, 9) <> ".."
    end
  end

  # -- Private helpers --

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

  defp format_time(nil), do: "\u2014"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: "\u2014"

  defp format_number(n) when is_number(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_number(n) when is_number(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_number(n) when is_number(n), do: "#{n}"
  defp format_number(_), do: "0"

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
