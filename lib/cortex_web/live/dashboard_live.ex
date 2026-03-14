defmodule CortexWeb.DashboardLive do
  use CortexWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: safe_subscribe()

    runs = safe_list_runs(limit: 10)

    total_cost =
      runs
      |> Enum.map(& &1.total_cost_usd)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    active_count = Enum.count(runs, fn r -> r.status == "running" end)

    {:ok,
     assign(socket,
       runs: runs,
       total_cost: total_cost,
       active_count: active_count,
       page_title: "Dashboard"
     )}
  end

  @impl true
  def handle_info(%{type: type, payload: _payload}, socket)
      when type in [:run_started, :run_completed, :team_completed] do
    runs = safe_list_runs(limit: 10)

    total_cost =
      runs
      |> Enum.map(& &1.total_cost_usd)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    active_count = Enum.count(runs, fn r -> r.status == "running" end)

    {:noreply,
     assign(socket,
       runs: runs,
       total_cost: total_cost,
       active_count: active_count
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Dashboard
      <:subtitle>Overview of orchestration runs and system status</:subtitle>
      <:actions>
        <a
          href="/new"
          class="inline-flex items-center rounded-md bg-cortex-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-cortex-500"
        >
          + New Run
        </a>
      </:actions>
    </.header>

    <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
        <p class="text-sm text-gray-400">Total Runs</p>
        <p class="text-2xl font-bold text-white mt-1">{length(@runs)}</p>
      </div>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
        <p class="text-sm text-gray-400">Active Runs</p>
        <p class="text-2xl font-bold text-white mt-1">{@active_count}</p>
      </div>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
        <p class="text-sm text-gray-400">Total Cost</p>
        <p class="text-2xl font-bold text-white mt-1">
          <.cost_display amount={@total_cost} />
        </p>
      </div>
    </div>

    <h2 class="text-lg font-semibold text-white mb-4">Recent Runs</h2>

    <%= if @runs == [] do %>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <p class="text-gray-400">No runs yet. Start a new run to see it here.</p>
      </div>
    <% else %>
      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
        <table class="w-full">
          <thead>
            <tr class="border-b border-gray-800">
              <th class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3">Name</th>
              <th class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3">Status</th>
              <th class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3">Teams</th>
              <th class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3">Cost</th>
              <th class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3">Duration</th>
              <th class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3">Started</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs} class="border-b border-gray-800/50 hover:bg-gray-800/30 transition-colors">
              <td class="px-4 py-3">
                <a href={"/runs/#{run.id}"} class="text-cortex-400 hover:text-cortex-300 font-medium">
                  {run.name}
                </a>
              </td>
              <td class="px-4 py-3"><.status_badge status={run.status} /></td>
              <td class="px-4 py-3 text-sm text-gray-300">{run.team_count || 0}</td>
              <td class="px-4 py-3"><.cost_display amount={run.total_cost_usd} /></td>
              <td class="px-4 py-3"><.duration_display ms={run.total_duration_ms} /></td>
              <td class="px-4 py-3 text-sm text-gray-400">{format_time(run.started_at || run.inserted_at)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  # -- Private helpers --

  defp safe_list_runs(opts) do
    Cortex.Store.list_runs(opts)
  rescue
    _ -> []
  end

  defp safe_subscribe do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp format_time(nil), do: "--"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_time(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M")
  end

  defp format_time(_), do: "--"
end
