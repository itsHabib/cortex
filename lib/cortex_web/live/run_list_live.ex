defmodule CortexWeb.RunListLive do
  use CortexWeb, :live_view

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: safe_subscribe()

    {:ok,
     assign(socket,
       runs: safe_list_runs(limit: @per_page, offset: 0),
       page: 0,
       per_page: @per_page,
       status_filter: nil,
       sort_field: :inserted_at,
       sort_dir: :desc,
       page_title: "Runs"
     )}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    filter = if status == "all", do: nil, else: status

    runs =
      safe_list_runs(
        limit: @per_page,
        offset: 0,
        status: filter
      )

    {:noreply, assign(socket, runs: runs, status_filter: filter, page: 0)}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)

    new_dir =
      if socket.assigns.sort_field == field_atom and socket.assigns.sort_dir == :asc,
        do: :desc,
        else: :asc

    runs = sort_runs(socket.assigns.runs, field_atom, new_dir)

    {:noreply, assign(socket, runs: runs, sort_field: field_atom, sort_dir: new_dir)}
  end

  def handle_event("next_page", _params, socket) do
    page = socket.assigns.page + 1

    runs =
      safe_list_runs(
        limit: @per_page,
        offset: page * @per_page,
        status: socket.assigns.status_filter
      )

    if runs == [] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, runs: runs, page: page)}
    end
  end

  def handle_event("prev_page", _params, socket) do
    page = max(socket.assigns.page - 1, 0)

    runs =
      safe_list_runs(
        limit: @per_page,
        offset: page * @per_page,
        status: socket.assigns.status_filter
      )

    {:noreply, assign(socket, runs: runs, page: page)}
  end

  @impl true
  def handle_info(%{type: type}, socket)
      when type in [:run_started, :run_completed] do
    runs =
      safe_list_runs(
        limit: @per_page,
        offset: socket.assigns.page * @per_page,
        status: socket.assigns.status_filter
      )

    {:noreply, assign(socket, runs: runs)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Runs
      <:subtitle>All orchestration runs</:subtitle>
    </.header>

    <div class="mb-4 flex items-center gap-4">
      <form phx-change="filter_status">
        <select
          name="status"
          class="bg-gray-800 border border-gray-700 text-gray-300 text-sm rounded-lg px-3 py-2 focus:ring-cortex-500 focus:border-cortex-500"
        >
          <option value="all" selected={@status_filter == nil}>All Statuses</option>
          <option value="pending" selected={@status_filter == "pending"}>Pending</option>
          <option value="running" selected={@status_filter == "running"}>Running</option>
          <option value="completed" selected={@status_filter == "completed"}>Completed</option>
          <option value="failed" selected={@status_filter == "failed"}>Failed</option>
        </select>
      </form>
    </div>

    <%= if @runs == [] do %>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <p class="text-gray-400">No runs found.</p>
      </div>
    <% else %>
      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
        <table class="w-full">
          <thead>
            <tr class="border-b border-gray-800">
              <th
                phx-click="sort"
                phx-value-field="name"
                class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3 cursor-pointer hover:text-gray-200"
              >
                Name {sort_indicator(@sort_field, @sort_dir, :name)}
              </th>
              <th
                phx-click="sort"
                phx-value-field="status"
                class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3 cursor-pointer hover:text-gray-200"
              >
                Status {sort_indicator(@sort_field, @sort_dir, :status)}
              </th>
              <th
                phx-click="sort"
                phx-value-field="team_count"
                class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3 cursor-pointer hover:text-gray-200"
              >
                Teams {sort_indicator(@sort_field, @sort_dir, :team_count)}
              </th>
              <th
                phx-click="sort"
                phx-value-field="total_cost_usd"
                class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3 cursor-pointer hover:text-gray-200"
              >
                Cost {sort_indicator(@sort_field, @sort_dir, :total_cost_usd)}
              </th>
              <th
                phx-click="sort"
                phx-value-field="total_duration_ms"
                class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3 cursor-pointer hover:text-gray-200"
              >
                Duration {sort_indicator(@sort_field, @sort_dir, :total_duration_ms)}
              </th>
              <th
                phx-click="sort"
                phx-value-field="inserted_at"
                class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3 cursor-pointer hover:text-gray-200"
              >
                Started {sort_indicator(@sort_field, @sort_dir, :inserted_at)}
              </th>
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

      <div class="flex justify-between items-center mt-4">
        <button
          :if={@page > 0}
          phx-click="prev_page"
          class="text-sm text-gray-400 hover:text-white px-3 py-1 rounded bg-gray-800 hover:bg-gray-700"
        >
          Previous
        </button>
        <span class="text-sm text-gray-500">Page {@page + 1}</span>
        <button
          :if={length(@runs) == @per_page}
          phx-click="next_page"
          class="text-sm text-gray-400 hover:text-white px-3 py-1 rounded bg-gray-800 hover:bg-gray-700"
        >
          Next
        </button>
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

  defp sort_runs(runs, field, dir) do
    Enum.sort_by(runs, &Map.get(&1, field), fn a, b ->
      case dir do
        :asc -> compare_values(a, b)
        :desc -> compare_values(b, a)
      end
    end)
  end

  defp compare_values(nil, _), do: true
  defp compare_values(_, nil), do: false

  defp compare_values(%DateTime{} = a, %DateTime{} = b),
    do: DateTime.compare(a, b) != :gt

  defp compare_values(a, b) when is_binary(a) and is_binary(b),
    do: a <= b

  defp compare_values(a, b) when is_number(a) and is_number(b),
    do: a <= b

  defp compare_values(a, b), do: to_string(a) <= to_string(b)

  defp sort_indicator(current_field, dir, field) do
    if current_field == field do
      case dir do
        :asc -> "^"
        :desc -> "v"
      end
    else
      ""
    end
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
