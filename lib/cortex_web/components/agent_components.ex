defmodule CortexWeb.AgentComponents do
  @moduledoc """
  Agent display components for the Cortex UI.

  Provides agent cards (grid/list/compact modes), agent grid and list
  wrappers, and an agent picker for selecting agents from a pool.
  Used by Agents page, Workflow agent picker, and Run team list.
  """
  use Phoenix.Component

  alias CortexWeb.StatusComponents

  # -- Agent Card --

  @doc """
  Renders a single agent card with name, role, capabilities, status, and transport.

  ## Modes

    * `:grid` - Full card with all details (default)
    * `:list` - Compact row with inline details
    * `:compact` - Minimal card with name and status only

  ## Examples

      <.agent_card agent={agent} />
      <.agent_card agent={agent} mode={:list} on_click="select_agent" />
  """
  attr(:agent, :map, required: true)
  attr(:mode, :atom, default: :grid, values: [:grid, :list, :compact])
  attr(:on_click, :string, default: nil)
  attr(:selected, :boolean, default: false)
  attr(:now, :any, default: nil)
  attr(:class, :string, default: nil)

  def agent_card(%{mode: :grid} = assigns) do
    ~H"""
    <div
      class={[
        "bg-gray-900 rounded-lg border p-4 space-y-3",
        if(@selected, do: "border-cortex-600", else: "border-gray-800"),
        @on_click && "cursor-pointer hover:border-gray-700 transition-colors",
        @class
      ]}
      phx-click={@on_click}
      phx-value-name={@agent.name}
      role={if @on_click, do: "button"}
      aria-selected={if @on_click, do: to_string(@selected)}
    >
      <%!-- Header: name + transport badge --%>
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2 min-w-0">
          <span class="text-white font-medium truncate">{@agent.name}</span>
          <StatusComponents.transport_badge
            :if={Map.get(@agent, :transport)}
            transport={@agent.transport}
          />
        </div>
        <StatusComponents.status_badge status={Map.get(@agent, :status, :idle)} />
      </div>

      <%!-- Role --%>
      <p class="text-sm text-gray-400">{Map.get(@agent, :role) || "\u2014"}</p>

      <%!-- Capabilities --%>
      <%= if capabilities(@agent) != [] do %>
        <div class="flex flex-wrap gap-1">
          <span
            :for={cap <- capabilities(@agent)}
            class="bg-gray-800 text-gray-400 text-xs px-1.5 py-0.5 rounded"
          >
            {cap}
          </span>
        </div>
      <% end %>

      <%!-- Metadata row --%>
      <div class="grid grid-cols-2 gap-2 text-xs">
        <div>
          <span class="text-gray-600">Last heartbeat</span>
          <p class="text-gray-300">{relative_time(Map.get(@agent, :last_heartbeat), @now)}</p>
        </div>
        <div>
          <span class="text-gray-600">Registered</span>
          <p class="text-gray-300">{format_time(Map.get(@agent, :registered_at))}</p>
        </div>
      </div>

      <%!-- Agent ID --%>
      <div :if={Map.get(@agent, :id)} class="text-xs">
        <span class="text-gray-600">ID:</span>
        <span class="text-gray-500 font-mono" title={@agent.id}>
          {String.slice(@agent.id, 0, 8)}&hellip;
        </span>
      </div>
    </div>
    """
  end

  def agent_card(%{mode: :list} = assigns) do
    ~H"""
    <tr
      class={[
        "border-b border-gray-800/50 transition-colors",
        if(@selected, do: "bg-cortex-900/20", else: ""),
        @on_click && "cursor-pointer hover:bg-gray-800/50",
        @class
      ]}
      phx-click={@on_click}
      phx-value-name={@agent.name}
      role={if @on_click, do: "button"}
      aria-selected={if @on_click, do: to_string(@selected)}
    >
      <td class="py-2 pr-3">
        <div class="flex items-center gap-2">
          <span class="text-white">{@agent.name}</span>
          <StatusComponents.transport_badge
            :if={Map.get(@agent, :transport)}
            transport={@agent.transport}
          />
        </div>
      </td>
      <td class="py-2 pr-3">
        <span class="text-gray-400 text-xs">{Map.get(@agent, :role) || "\u2014"}</span>
      </td>
      <td class="py-2 pr-3">
        <div class="flex flex-wrap gap-1">
          <span
            :for={cap <- capabilities(@agent)}
            class="bg-gray-800 text-gray-300 text-xs px-1.5 py-0.5 rounded"
          >
            {cap}
          </span>
        </div>
      </td>
      <td class="py-2 px-2 text-center">
        <StatusComponents.status_badge status={Map.get(@agent, :status, :idle)} />
      </td>
    </tr>
    """
  end

  def agent_card(%{mode: :compact} = assigns) do
    ~H"""
    <div
      class={[
        "bg-gray-900 rounded border p-2 flex items-center gap-2",
        if(@selected, do: "border-cortex-600", else: "border-gray-800"),
        @on_click && "cursor-pointer hover:border-gray-700 transition-colors",
        @class
      ]}
      phx-click={@on_click}
      phx-value-name={@agent.name}
      role={if @on_click, do: "button"}
      aria-selected={if @on_click, do: to_string(@selected)}
    >
      <StatusComponents.status_dot status={Map.get(@agent, :status, :idle)} />
      <span class="text-white text-sm truncate">{@agent.name}</span>
      <span :if={Map.get(@agent, :role)} class="text-gray-500 text-xs ml-auto">{@agent.role}</span>
    </div>
    """
  end

  # -- Agent Grid --

  @doc """
  Wraps agent cards in a responsive CSS grid layout.

  ## Examples

      <.agent_grid agents={agents} on_select="select_agent" />
  """
  attr(:agents, :list, required: true)
  attr(:on_select, :string, default: nil)
  attr(:selected, :string, default: nil)
  attr(:now, :any, default: nil)
  attr(:class, :string, default: nil)

  def agent_grid(assigns) do
    ~H"""
    <%= if @agents == [] do %>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-12 text-center">
        <p class="text-gray-400 text-lg">No agents connected.</p>
        <p class="text-gray-600 text-sm mt-2">Start a sidecar to see agents appear.</p>
      </div>
    <% else %>
      <div class={["grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4", @class]}>
        <.agent_card
          :for={agent <- @agents}
          agent={agent}
          mode={:grid}
          on_click={@on_select}
          selected={@selected == agent.name}
          now={@now}
        />
      </div>
    <% end %>
    """
  end

  # -- Agent List --

  @doc """
  Renders agents as a table with sortable columns.

  ## Examples

      <.agent_list agents={agents} on_select="select_agent" />
  """
  attr(:agents, :list, required: true)
  attr(:on_select, :string, default: nil)
  attr(:selected, :string, default: nil)
  attr(:class, :string, default: nil)

  def agent_list(assigns) do
    ~H"""
    <div class={["overflow-x-auto", @class]}>
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b border-gray-800">
            <th class="text-left text-gray-500 text-xs uppercase py-2 pr-3">Name</th>
            <th class="text-left text-gray-500 text-xs uppercase py-2 pr-3">Role</th>
            <th class="text-left text-gray-500 text-xs uppercase py-2 pr-3">Capabilities</th>
            <th class="text-center text-gray-500 text-xs uppercase py-2 px-2">Status</th>
          </tr>
        </thead>
        <tbody>
          <.agent_card
            :for={agent <- @agents}
            agent={agent}
            mode={:list}
            on_click={@on_select}
            selected={@selected == agent.name}
          />
        </tbody>
      </table>
    </div>
    """
  end

  # -- Agent Picker --

  @doc """
  Renders an agent picker for selecting agents from a pool with capability filtering.

  Shows available agents as selectable cards with a filter input.
  Selected agents are displayed as removable chips.

  ## Examples

      <.agent_picker
        available={agents}
        selected={["agent-1"]}
        filter=""
        on_add="add_agent"
        on_remove="remove_agent"
        on_filter="filter_agents"
      />
  """
  attr(:available, :list, required: true)
  attr(:selected, :list, default: [])
  attr(:filter, :string, default: "")
  attr(:on_add, :string, default: nil)
  attr(:on_remove, :string, default: nil)
  attr(:on_filter, :string, default: nil)
  attr(:class, :string, default: nil)

  def agent_picker(assigns) do
    filtered =
      if assigns.filter == "" do
        assigns.available
      else
        query = String.downcase(assigns.filter)

        Enum.filter(assigns.available, fn agent ->
          String.contains?(String.downcase(agent.name), query) ||
            Enum.any?(capabilities(agent), &String.contains?(String.downcase(&1), query))
        end)
      end

    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <div class={["space-y-3", @class]}>
      <%!-- Selected agents chips --%>
      <div :if={@selected != []} class="flex flex-wrap gap-2">
        <span
          :for={name <- @selected}
          class="bg-cortex-900/50 text-cortex-300 text-xs px-2 py-1 rounded-full flex items-center gap-1"
        >
          {name}
          <button
            :if={@on_remove}
            phx-click={@on_remove}
            phx-value-name={name}
            class="text-cortex-400 hover:text-cortex-200 ml-0.5"
            aria-label={"Remove #{name}"}
          >
            &#x2715;
          </button>
        </span>
      </div>

      <%!-- Filter input --%>
      <input
        :if={@on_filter}
        type="text"
        value={@filter}
        phx-keyup={@on_filter}
        placeholder="Filter by name or capability..."
        class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
        aria-label="Filter agents"
      />

      <%!-- Available agents --%>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 max-h-64 overflow-y-auto">
        <.agent_card
          :for={agent <- @filtered}
          agent={agent}
          mode={:compact}
          on_click={@on_add}
          selected={agent.name in @selected}
        />
      </div>

      <p :if={@filtered == []} class="text-gray-500 text-sm text-center py-4">
        No matching agents
      </p>
    </div>
    """
  end

  # -- Private helpers --

  defp capabilities(agent) do
    Map.get(agent, :capabilities) || []
  end

  defp relative_time(nil, _now), do: "\u2014"

  defp relative_time(%DateTime{} = dt, nil), do: format_time(dt)

  defp relative_time(%DateTime{} = dt, now) do
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 0 -> "just now"
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  defp relative_time(_, _now), do: "\u2014"

  defp format_time(nil), do: "\u2014"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: "\u2014"
end
