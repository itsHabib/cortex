defmodule CortexWeb.AgentsLive do
  @moduledoc """
  Fleet dashboard showing all connected agents via the Gateway Registry.

  Supports grid/list layout toggle, topology visualization mode, capability-based
  search and filtering, agent detail slide-over panel with URL routing (`/agents/:id`),
  and real-time PubSub updates for agent connect/disconnect/status changes.
  """

  use CortexWeb, :live_view

  @refresh_interval :timer.seconds(5)

  # -- Mount --

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      safe_subscribe_events()
      safe_subscribe_gateway()
      Process.send_after(self(), :refresh_heartbeats, @refresh_interval)
    end

    agents = safe_list_agents()

    {:ok,
     assign(socket,
       page_title: "Agents",
       agents: agents,
       now: DateTime.utc_now(),
       view_mode: :grid,
       card_layout: :cards,
       search_query: "",
       status_filter: :all,
       transport_filter: :all,
       capability_filters: MapSet.new(),
       group_by: :none,
       selected_agent: nil
     )}
  end

  # -- URL routing --

  @impl true
  def handle_params(%{"id" => agent_id}, _uri, socket) do
    selected = find_agent(socket.assigns.agents, agent_id)

    {:noreply,
     assign(socket,
       selected_agent: selected,
       page_title: if(selected, do: "Agent: #{selected.name}", else: "Agents")
     )}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, selected_agent: nil, page_title: "Agents")}
  end

  # -- Client event handlers --

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, search_query: query)}
  end

  def handle_event("filter_status", %{"status" => "all"}, socket) do
    {:noreply, assign(socket, status_filter: :all)}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, assign(socket, status_filter: String.to_existing_atom(status))}
  end

  def handle_event("filter_transport", %{"transport" => "all"}, socket) do
    {:noreply, assign(socket, transport_filter: :all)}
  end

  def handle_event("filter_transport", %{"transport" => transport}, socket) do
    {:noreply, assign(socket, transport_filter: String.to_existing_atom(transport))}
  end

  def handle_event("filter_capability", %{"capability" => cap}, socket) do
    caps = socket.assigns.capability_filters

    updated =
      if MapSet.member?(caps, cap),
        do: MapSet.delete(caps, cap),
        else: MapSet.put(caps, cap)

    {:noreply, assign(socket, capability_filters: updated)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     assign(socket,
       search_query: "",
       status_filter: :all,
       transport_filter: :all,
       capability_filters: MapSet.new()
     )}
  end

  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, view_mode: String.to_existing_atom(mode))}
  end

  def handle_event("toggle_layout", %{"layout" => layout}, socket) do
    {:noreply, assign(socket, card_layout: String.to_existing_atom(layout))}
  end

  def handle_event("select_agent", %{"name" => name}, socket) do
    case Enum.find(socket.assigns.agents, &(&1.name == name)) do
      %{id: id} -> {:noreply, push_patch(socket, to: "/agents/#{id}")}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, push_patch(socket, to: "/agents")}
  end

  def handle_event("select_agent_by_name", %{"name" => name}, socket) do
    case Enum.find(socket.assigns.agents, &(&1.name == name)) do
      %{id: id} -> {:noreply, push_patch(socket, to: "/agents/#{id}")}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("group_by", %{"group" => group}, socket) do
    {:noreply, assign(socket, group_by: String.to_existing_atom(group))}
  end

  # -- PubSub handlers --

  @impl true
  def handle_info(%{type: :agent_registered, payload: payload}, socket) do
    agent_id = Map.get(payload, :agent_id)

    agents =
      case safe_get_agent(agent_id) do
        {:ok, agent} ->
          [agent | reject_agent(socket.assigns.agents, agent_id)]

        _ ->
          socket.assigns.agents
      end

    name = Map.get(payload, :name, "unknown")

    {:noreply,
     socket
     |> assign(agents: agents, now: DateTime.utc_now())
     |> put_flash(:info, "Agent connected: #{name}")}
  end

  def handle_info(%{type: :agent_unregistered, payload: payload}, socket) do
    agent_id = Map.get(payload, :agent_id)
    name = Map.get(payload, :name, "unknown")

    agents = reject_agent(socket.assigns.agents, agent_id)

    # If the detail panel shows this agent, keep it visible with disconnected note
    selected =
      case socket.assigns.selected_agent do
        %{id: ^agent_id} = agent -> %{agent | status: :disconnected}
        other -> other
      end

    {:noreply,
     socket
     |> assign(agents: agents, now: DateTime.utc_now(), selected_agent: selected)
     |> put_flash(:info, "Agent disconnected: #{name}")}
  end

  def handle_info(%{type: :agent_status_changed, payload: payload}, socket) do
    agent_id = Map.get(payload, :agent_id)
    new_status = Map.get(payload, :new_status)

    agents =
      Enum.map(socket.assigns.agents, fn agent ->
        if agent.id == agent_id, do: %{agent | status: new_status}, else: agent
      end)

    selected =
      case socket.assigns.selected_agent do
        %{id: ^agent_id} = agent -> %{agent | status: new_status}
        other -> other
      end

    {:noreply, assign(socket, agents: agents, selected_agent: selected)}
  end

  def handle_info(:refresh_heartbeats, socket) do
    Process.send_after(self(), :refresh_heartbeats, @refresh_interval)
    {:noreply, assign(socket, now: DateTime.utc_now())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Render --

  @impl true
  def render(assigns) do
    filtered = filter_agents(assigns.agents, assigns)
    all_capabilities = all_capabilities(assigns.agents)
    grouped = group_agents(filtered, assigns.group_by)

    assigns =
      assigns
      |> assign(:filtered_agents, filtered)
      |> assign(:all_capabilities, all_capabilities)
      |> assign(:grouped_agents, grouped)
      |> assign(:has_active_filters, has_active_filters?(assigns))

    ~H"""
    <div class="p-6 max-w-7xl mx-auto space-y-6">
      <.header>
        Agents
        <:subtitle>
          <span class="inline-flex items-center gap-2">
            Connected agents
            <span class="bg-cortex-900/60 text-cortex-300 text-xs font-medium px-2 py-0.5 rounded-full">
              {length(@agents)}
            </span>
            <%= if @has_active_filters do %>
              <span class="text-gray-500 text-xs">
                (showing {length(@filtered_agents)})
              </span>
            <% end %>
          </span>
        </:subtitle>
      </.header>

      <.filter_toolbar
        search_query={@search_query}
        status_filter={@status_filter}
        transport_filter={@transport_filter}
        capability_filters={@capability_filters}
        all_capabilities={@all_capabilities}
        view_mode={@view_mode}
        card_layout={@card_layout}
        group_by={@group_by}
        has_active_filters={@has_active_filters}
      />

      <%= if @agents == [] do %>
        <.empty_state />
      <% else %>
        <%= if @filtered_agents == [] do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-12 text-center">
            <p class="text-gray-400 text-lg">No agents match your filters.</p>
            <button
              phx-click="clear_filters"
              class="mt-3 text-cortex-400 hover:text-cortex-300 text-sm underline"
            >
              Clear all filters
            </button>
          </div>
        <% else %>
          <%= if @view_mode == :topology do %>
            <.topology_view agents={@filtered_agents} selected={@selected_agent} now={@now} />
          <% else %>
            <.agents_display
              grouped_agents={@grouped_agents}
              group_by={@group_by}
              card_layout={@card_layout}
              selected={@selected_agent}
              now={@now}
            />
          <% end %>
        <% end %>
      <% end %>

      <.slide_over
        show={@selected_agent != nil}
        on_close="close_detail"
        title={if @selected_agent, do: @selected_agent.name, else: ""}
        id="agent-detail"
      >
        <.agent_detail_panel
          :if={@selected_agent}
          agent={@selected_agent}
          now={@now}
        />
      </.slide_over>
    </div>
    """
  end

  # -- Filter toolbar component --

  defp filter_toolbar(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex flex-wrap items-center gap-3">
        <%!-- Search ---%>
        <div class="flex-1 min-w-[200px]">
          <input
            type="text"
            value={@search_query}
            phx-keyup="search"
            phx-debounce="300"
            phx-value-query=""
            name="query"
            placeholder="Search agents by name, role, or capability..."
            class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300 placeholder-gray-600 focus:border-cortex-500 focus:ring-1 focus:ring-cortex-500"
            aria-label="Search agents"
          />
        </div>

        <%!-- Status filter ---%>
        <select
          phx-change="filter_status"
          name="status"
          class="bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
          aria-label="Filter by status"
        >
          <option value="all" selected={@status_filter == :all}>All statuses</option>
          <option value="idle" selected={@status_filter == :idle}>Idle</option>
          <option value="working" selected={@status_filter == :working}>Working</option>
          <option value="draining" selected={@status_filter == :draining}>Draining</option>
          <option value="disconnected" selected={@status_filter == :disconnected}>Disconnected</option>
        </select>

        <%!-- Transport filter ---%>
        <select
          phx-change="filter_transport"
          name="transport"
          class="bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
          aria-label="Filter by transport"
        >
          <option value="all" selected={@transport_filter == :all}>All transports</option>
          <option value="websocket" selected={@transport_filter == :websocket}>WebSocket</option>
          <option value="grpc" selected={@transport_filter == :grpc}>gRPC</option>
        </select>

        <%!-- Group by ---%>
        <select
          phx-change="group_by"
          name="group"
          class="bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
          aria-label="Group agents by"
        >
          <option value="none" selected={@group_by == :none}>No grouping</option>
          <option value="status" selected={@group_by == :status}>Group by status</option>
          <option value="transport" selected={@group_by == :transport}>Group by transport</option>
        </select>

        <%!-- View mode toggle ---%>
        <div class="flex items-center gap-1 bg-gray-900 rounded p-0.5 border border-gray-800">
          <button
            phx-click="toggle_view"
            phx-value-mode="grid"
            class={[
              "px-2.5 py-1.5 text-xs rounded transition-colors",
              if(@view_mode == :grid, do: "bg-gray-700 text-white", else: "text-gray-500 hover:text-gray-300")
            ]}
            aria-label="Grid view"
            aria-pressed={to_string(@view_mode == :grid)}
          >
            Grid
          </button>
          <button
            phx-click="toggle_view"
            phx-value-mode="topology"
            class={[
              "px-2.5 py-1.5 text-xs rounded transition-colors",
              if(@view_mode == :topology, do: "bg-gray-700 text-white", else: "text-gray-500 hover:text-gray-300")
            ]}
            aria-label="Topology view"
            aria-pressed={to_string(@view_mode == :topology)}
          >
            Topology
          </button>
        </div>

        <%!-- Layout toggle (grid mode only) ---%>
        <div
          :if={@view_mode == :grid}
          class="flex items-center gap-1 bg-gray-900 rounded p-0.5 border border-gray-800"
        >
          <button
            phx-click="toggle_layout"
            phx-value-layout="cards"
            class={[
              "px-2.5 py-1.5 text-xs rounded transition-colors",
              if(@card_layout == :cards, do: "bg-gray-700 text-white", else: "text-gray-500 hover:text-gray-300")
            ]}
            aria-label="Card layout"
            aria-pressed={to_string(@card_layout == :cards)}
          >
            Cards
          </button>
          <button
            phx-click="toggle_layout"
            phx-value-layout="rows"
            class={[
              "px-2.5 py-1.5 text-xs rounded transition-colors",
              if(@card_layout == :rows, do: "bg-gray-700 text-white", else: "text-gray-500 hover:text-gray-300")
            ]}
            aria-label="List layout"
            aria-pressed={to_string(@card_layout == :rows)}
          >
            List
          </button>
        </div>

        <%!-- Clear filters ---%>
        <button
          :if={@has_active_filters}
          phx-click="clear_filters"
          class="text-cortex-400 hover:text-cortex-300 text-xs underline"
        >
          Clear filters
        </button>
      </div>

      <%!-- Capability tag chips ---%>
      <div :if={@all_capabilities != []} class="flex flex-wrap gap-1.5">
        <button
          :for={cap <- @all_capabilities}
          phx-click="filter_capability"
          phx-value-capability={cap}
          class={[
            "text-xs px-2 py-1 rounded-full transition-colors border",
            if(MapSet.member?(@capability_filters, cap),
              do: "bg-cortex-900/60 text-cortex-300 border-cortex-700",
              else: "bg-gray-900 text-gray-500 border-gray-800 hover:text-gray-300 hover:border-gray-700"
            )
          ]}
          aria-pressed={to_string(MapSet.member?(@capability_filters, cap))}
        >
          {cap}
        </button>
      </div>
    </div>
    """
  end

  # -- Agents display (grid/list, with optional grouping) --

  defp agents_display(%{group_by: :none} = assigns) do
    ~H"""
    <.render_agent_collection agents={@grouped_agents[:all] || []} card_layout={@card_layout} selected={@selected} now={@now} />
    """
  end

  defp agents_display(assigns) do
    ~H"""
    <div class="space-y-6">
      <div :for={{group_label, group_agents} <- @grouped_agents} class="space-y-3">
        <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider flex items-center gap-2">
          {format_group_label(@group_by, group_label)}
          <span class="bg-gray-800 text-gray-500 text-xs px-1.5 py-0.5 rounded-full">
            {length(group_agents)}
          </span>
        </h3>
        <.render_agent_collection agents={group_agents} card_layout={@card_layout} selected={@selected} now={@now} />
      </div>
    </div>
    """
  end

  defp render_agent_collection(%{card_layout: :rows} = assigns) do
    ~H"""
    <.agent_list
      agents={@agents}
      on_select="select_agent"
      selected={if @selected, do: @selected.name}
    />
    """
  end

  defp render_agent_collection(assigns) do
    ~H"""
    <.agent_grid
      agents={@agents}
      on_select="select_agent"
      selected={if @selected, do: @selected.name}
      now={@now}
    />
    """
  end

  # -- Topology view --

  defp topology_view(assigns) do
    nodes =
      Enum.map(assigns.agents, fn agent ->
        %{name: agent.name, status: agent.status, id: agent.id}
      end)

    assigns = assign(assigns, :nodes, nodes)

    ~H"""
    <div class="space-y-4">
      <%= if length(@nodes) == 0 do %>
        <div class="text-gray-500 text-sm text-center py-8">No agents to display</div>
      <% else %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <div class="text-center mb-3">
            <p class="text-gray-500 text-xs">
              Agents shown as available nodes. Start a mesh run to see live connectivity.
            </p>
          </div>
          <div class="flex justify-center">
            <.topology_graph
              variant={:radial}
              nodes={@nodes}
              edges={[]}
              selected={if @selected, do: @selected.name}
              on_node_click="select_agent_by_name"
            />
          </div>
          <.topology_legend
            items={[
              %{label: "idle", color: "blue"},
              %{label: "working", color: "green"},
              %{label: "draining", color: "yellow"},
              %{label: "disconnected", color: "red"}
            ]}
            class="justify-center mt-3"
          />
        </div>
      <% end %>
    </div>
    """
  end

  # -- Agent detail slide-over panel --

  defp agent_detail_panel(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Status + Transport ---%>
      <div class="flex items-center gap-2">
        <.status_badge status={@agent.status} />
        <.transport_badge transport={@agent.transport} />
      </div>

      <%!-- Role ---%>
      <div>
        <h4 class="text-xs text-gray-500 uppercase tracking-wider mb-1">Role</h4>
        <p class="text-gray-300">{@agent.role || "\u2014"}</p>
      </div>

      <%!-- Capabilities ---%>
      <div>
        <h4 class="text-xs text-gray-500 uppercase tracking-wider mb-1">Capabilities</h4>
        <%= if (@agent.capabilities || []) != [] do %>
          <div class="flex flex-wrap gap-1.5">
            <span
              :for={cap <- @agent.capabilities}
              class="bg-gray-800 text-gray-300 text-xs px-2 py-1 rounded"
            >
              {cap}
            </span>
          </div>
        <% else %>
          <p class="text-gray-600 text-sm">No capabilities advertised</p>
        <% end %>
      </div>

      <%!-- Load ---%>
      <div>
        <h4 class="text-xs text-gray-500 uppercase tracking-wider mb-1">Load</h4>
        <div class="grid grid-cols-2 gap-3">
          <div class="bg-gray-950 rounded p-3">
            <p class="text-gray-500 text-xs">Active tasks</p>
            <p class="text-white text-lg font-medium">
              {get_in(@agent.load || %{}, [:active_tasks]) || Map.get(@agent.load || %{}, "active_tasks", 0)}
            </p>
          </div>
          <div class="bg-gray-950 rounded p-3">
            <p class="text-gray-500 text-xs">Queue depth</p>
            <p class="text-white text-lg font-medium">
              {get_in(@agent.load || %{}, [:queue_depth]) || Map.get(@agent.load || %{}, "queue_depth", 0)}
            </p>
          </div>
        </div>
      </div>

      <%!-- Timestamps ---%>
      <div>
        <h4 class="text-xs text-gray-500 uppercase tracking-wider mb-1">Connection</h4>
        <div class="space-y-2 text-sm">
          <div class="flex justify-between">
            <span class="text-gray-500">Last heartbeat</span>
            <span class="text-gray-300">{relative_time(@agent.last_heartbeat, @now)}</span>
          </div>
          <div class="flex justify-between">
            <span class="text-gray-500">Registered at</span>
            <span class="text-gray-300">{format_time(@agent.registered_at)}</span>
          </div>
          <div class="flex justify-between">
            <span class="text-gray-500">Transport</span>
            <span class="text-gray-300">{@agent.transport}</span>
          </div>
        </div>
      </div>

      <%!-- Metadata ---%>
      <%= if (@agent.metadata || %{}) != %{} do %>
        <div>
          <h4 class="text-xs text-gray-500 uppercase tracking-wider mb-1">Metadata</h4>
          <div class="bg-gray-950 rounded p-3 space-y-1">
            <div :for={{key, val} <- @agent.metadata} class="flex justify-between text-sm">
              <span class="text-gray-500">{key}</span>
              <span class="text-gray-300 font-mono text-xs">{inspect(val)}</span>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Agent ID ---%>
      <div>
        <h4 class="text-xs text-gray-500 uppercase tracking-wider mb-1">Agent ID</h4>
        <p class="text-gray-400 font-mono text-xs break-all">{@agent.id}</p>
      </div>
    </div>
    """
  end

  # -- Empty state --

  defp empty_state(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg border border-gray-800 p-12 text-center">
      <div class="mx-auto w-16 h-16 mb-4 text-gray-700">
        <svg fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1">
          <circle cx="12" cy="5" r="2.5" />
          <circle cx="5" cy="19" r="2.5" />
          <circle cx="19" cy="19" r="2.5" />
          <line x1="12" y1="7.5" x2="5" y2="16.5" />
          <line x1="12" y1="7.5" x2="19" y2="16.5" />
          <line x1="7.5" y1="19" x2="16.5" y2="19" />
        </svg>
      </div>
      <p class="text-gray-400 text-lg">No agents connected</p>
      <p class="text-gray-600 text-sm mt-2">
        Deploy a sidecar or start a local agent to get started.
      </p>
    </div>
    """
  end

  # -- Filtering --

  defp filter_agents(agents, assigns) do
    agents
    |> filter_by_search(assigns.search_query)
    |> filter_by_status(assigns.status_filter)
    |> filter_by_transport(assigns.transport_filter)
    |> filter_by_capabilities(assigns.capability_filters)
    |> Enum.sort_by(& &1.name)
  end

  defp filter_by_search(agents, ""), do: agents

  defp filter_by_search(agents, query) do
    q = String.downcase(query)

    Enum.filter(agents, fn agent ->
      String.contains?(String.downcase(agent.name || ""), q) ||
        String.contains?(String.downcase(agent.role || ""), q) ||
        Enum.any?(agent.capabilities || [], &String.contains?(String.downcase(&1), q))
    end)
  end

  defp filter_by_status(agents, :all), do: agents
  defp filter_by_status(agents, status), do: Enum.filter(agents, &(&1.status == status))

  defp filter_by_transport(agents, :all), do: agents

  defp filter_by_transport(agents, transport),
    do: Enum.filter(agents, &(&1.transport == transport))

  defp filter_by_capabilities(agents, caps) do
    if MapSet.size(caps) == 0 do
      agents
    else
      Enum.filter(agents, fn agent ->
        agent_caps = MapSet.new(agent.capabilities || [])
        MapSet.subset?(caps, agent_caps)
      end)
    end
  end

  defp has_active_filters?(assigns) do
    assigns.search_query != "" ||
      assigns.status_filter != :all ||
      assigns.transport_filter != :all ||
      MapSet.size(assigns.capability_filters) > 0
  end

  # -- Grouping --

  defp group_agents(agents, :none), do: [all: agents]

  defp group_agents(agents, :status) do
    agents
    |> Enum.group_by(& &1.status)
    |> Enum.sort_by(fn {status, _} -> status_sort_order(status) end)
  end

  defp group_agents(agents, :transport) do
    agents
    |> Enum.group_by(& &1.transport)
    |> Enum.sort_by(fn {transport, _} -> to_string(transport) end)
  end

  defp status_sort_order(:working), do: 0
  defp status_sort_order(:idle), do: 1
  defp status_sort_order(:draining), do: 2
  defp status_sort_order(:disconnected), do: 3
  defp status_sort_order(_), do: 4

  defp format_group_label(:status, status), do: to_string(status)
  defp format_group_label(:transport, transport), do: to_string(transport)
  defp format_group_label(_, label), do: to_string(label)

  # -- Capability discovery --

  defp all_capabilities(agents) do
    agents
    |> Enum.flat_map(fn agent -> agent.capabilities || [] end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # -- Private helpers --

  defp safe_subscribe_events do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp safe_subscribe_gateway do
    Cortex.Gateway.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp safe_list_agents do
    Cortex.Gateway.Registry.list()
  rescue
    _ -> []
  end

  defp safe_get_agent(agent_id) do
    Cortex.Gateway.Registry.get(agent_id)
  rescue
    _ -> {:error, :not_found}
  end

  defp reject_agent(agents, agent_id) do
    Enum.reject(agents, fn a -> a.id == agent_id end)
  end

  defp find_agent(agents, agent_id) do
    Enum.find(agents, fn a -> a.id == agent_id end) ||
      case safe_get_agent(agent_id) do
        {:ok, agent} -> agent
        _ -> nil
      end
  end

  defp relative_time(nil, _now), do: "\u2014"

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
