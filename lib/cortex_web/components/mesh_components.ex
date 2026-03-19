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
