defmodule CortexWeb.RunsLive do
  @moduledoc """
  View, filter, sort, compare, and manage all runs.

  Renamed from RunListLive. Absorbs RunCompareLive as a toggle view mode
  (list vs compare), switched via `?view=compare` query param.
  """

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
       view_mode: "list",
       compare_runs: [],
       compare_sort_col: "started_at",
       compare_sort_dir: :desc,
       page_title: "Runs"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = Map.get(params, "view", "list")

    socket =
      if view == "compare" do
        runs = load_completed_runs()

        assign(socket,
          view_mode: "compare",
          compare_runs: runs,
          page_title: "Runs — Compare"
        )
      else
        assign(socket, view_mode: "list", page_title: "Runs")
      end

    {:noreply, socket}
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

  def handle_event("delete_run", %{"id" => id}, socket) do
    case Cortex.Store.get_run(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Run not found")}

      run ->
        case Cortex.Store.delete_run(run) do
          {:ok, _} ->
            runs =
              safe_list_runs(
                limit: @per_page,
                offset: socket.assigns.page * @per_page,
                status: socket.assigns.status_filter
              )

            {:noreply,
             socket
             |> assign(runs: runs)
             |> put_flash(:info, "Run deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete run")}
        end
    end
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

  # Compare view events
  def handle_event("compare_sort", %{"col" => col}, socket) do
    {sort_col, sort_dir} =
      if socket.assigns.compare_sort_col == col do
        {col, flip_dir(socket.assigns.compare_sort_dir)}
      else
        {col, :desc}
      end

    runs = compare_sort_runs(socket.assigns.compare_runs, sort_col, sort_dir)

    {:noreply,
     assign(socket, compare_runs: runs, compare_sort_col: sort_col, compare_sort_dir: sort_dir)}
  end

  def handle_event("refresh_compare", _params, socket) do
    runs =
      load_completed_runs()
      |> compare_sort_runs(socket.assigns.compare_sort_col, socket.assigns.compare_sort_dir)

    {:noreply, assign(socket, compare_runs: runs)}
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

    socket =
      if socket.assigns.view_mode == "compare" do
        assign(socket, compare_runs: load_completed_runs())
      else
        socket
      end

    {:noreply, assign(socket, runs: runs)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Runs
      <:subtitle>All runs</:subtitle>
      <:actions>
        <%= if @view_mode == "list" do %>
          <a
            href="/runs?view=compare"
            class="inline-flex items-center rounded-md bg-gray-700 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-gray-600"
          >
            Compare Runs
          </a>
        <% else %>
          <button
            phx-click="refresh_compare"
            class="text-sm text-gray-400 hover:text-white px-3 py-1 rounded border border-gray-700 hover:border-gray-500"
          >
            Refresh
          </button>
          <a href="/runs" class="text-sm text-gray-400 hover:text-white">Back to List</a>
        <% end %>
      </:actions>
    </.header>

    <%= if @view_mode == "compare" do %>
      {render_compare_view(assigns)}
    <% else %>
      {render_list_view(assigns)}
    <% end %>
    """
  end

  # -- List View --

  defp render_list_view(assigns) do
    ~H"""
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
                phx-value-field="total_input_tokens"
                class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3 cursor-pointer hover:text-gray-200"
              >
                Tokens {sort_indicator(@sort_field, @sort_dir, :total_input_tokens)}
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
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs} class="border-b border-gray-800/50 hover:bg-gray-800/30 transition-colors">
              <td class="px-4 py-3">
                <a href={"/runs/#{run.id}"} class="text-cortex-400 hover:text-cortex-300 font-medium">
                  {run.name}
                </a>
              </td>
              <td class="px-4 py-3">
                <div class="flex items-center gap-2">
                  <.status_badge status={run.status} />
                  <span class={["text-xs px-1.5 py-0.5 rounded", mode_class(run.mode)]}>
                    {run.mode || "workflow"}
                  </span>
                </div>
              </td>
              <td class="px-4 py-3 text-sm text-gray-300">{run.team_count || 0}</td>
              <td class="px-4 py-3"><.token_detail
                id={"run-#{run.id}-tokens"}
                input={run.total_input_tokens}
                output={run.total_output_tokens}
                cache_read={run.total_cache_read_tokens}
                cache_creation={run.total_cache_creation_tokens}
              /></td>
              <td class="px-4 py-3"><.duration_display ms={run.total_duration_ms} /></td>
              <td class="px-4 py-3 text-sm text-gray-400">{format_time(run.started_at || run.inserted_at)}</td>
              <td class="px-4 py-3 text-right">
                <button
                  phx-click="delete_run"
                  phx-value-id={run.id}
                  data-confirm="Are you sure you want to delete this run?"
                  class="text-xs text-red-400/60 hover:text-red-300"
                >
                  Delete
                </button>
              </td>
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

  # -- Compare View --

  defp render_compare_view(assigns) do
    ~H"""
    <%= if @compare_runs == [] do %>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <p class="text-gray-400">No completed runs yet.</p>
      </div>
    <% else %>
      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-x-auto">
        <table class="w-full">
          <thead>
            <tr class="border-b border-gray-800">
              <th :for={{col, label} <- compare_columns()} class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-3 py-3">
                <button
                  phx-click="compare_sort"
                  phx-value-col={col}
                  class="flex items-center gap-1 hover:text-gray-200 transition-colors"
                >
                  {label}
                  <span :if={@compare_sort_col == col} class="text-cortex-400">
                    {if @compare_sort_dir == :asc, do: " \u2191", else: " \u2193"}
                  </span>
                </button>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @compare_runs} class="border-b border-gray-800/50 hover:bg-gray-800/30 transition-colors">
              <td class="px-3 py-2.5">
                <a href={"/runs/#{run.id}"} class="text-cortex-400 hover:text-cortex-300 font-medium text-sm">
                  {run.name}
                </a>
              </td>
              <td class="px-3 py-2.5">
                <.status_badge status={run.status} />
              </td>
              <td class="px-3 py-2.5 text-sm font-mono text-gray-300">{fmt_tokens(run.total_input_tokens)}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-gray-300">{fmt_tokens(run.total_output_tokens)}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-gray-300">{fmt_tokens(run.total_cache_read_tokens)}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-gray-300">{fmt_tokens(run.total_cache_creation_tokens)}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-gray-300">{fmt_duration(run.total_duration_ms)}</td>
              <td class="px-3 py-2.5 text-sm text-gray-400">{format_time(run.started_at || run.inserted_at)}</td>
            </tr>
            <!-- Totals row -->
            <tr class="border-t-2 border-gray-700 bg-gray-800/30 font-semibold">
              <td class="px-3 py-2.5 text-sm text-gray-300">Total ({length(@compare_runs)} runs)</td>
              <td class="px-3 py-2.5"></td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_tokens(sum_field(@compare_runs, :total_input_tokens))}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_tokens(sum_field(@compare_runs, :total_output_tokens))}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_tokens(sum_field(@compare_runs, :total_cache_read_tokens))}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_tokens(sum_field(@compare_runs, :total_cache_creation_tokens))}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_duration(sum_field(@compare_runs, :total_duration_ms))}</td>
              <td class="px-3 py-2.5"></td>
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

  defp load_completed_runs do
    Cortex.Store.list_runs(limit: 100, status: "completed")
  rescue
    _ -> []
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
        :asc -> raw("&uarr;")
        :desc -> raw("&darr;")
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

  defp mode_class("gossip"), do: "bg-purple-900/50 text-purple-300"
  defp mode_class("mesh"), do: "bg-emerald-900/50 text-emerald-300"
  defp mode_class(_), do: "bg-gray-800/50 text-gray-400"

  # -- Compare view helpers --

  defp compare_columns do
    [
      {"name", "Name"},
      {"status", "Status"},
      {"total_input_tokens", "Input"},
      {"total_output_tokens", "Output"},
      {"total_cache_read_tokens", "Cache Read"},
      {"total_cache_creation_tokens", "Cache Create"},
      {"total_duration_ms", "Duration"},
      {"started_at", "Started"}
    ]
  end

  defp flip_dir(:asc), do: :desc
  defp flip_dir(:desc), do: :asc

  defp compare_sort_runs(runs, col, dir) do
    field = String.to_existing_atom(col)

    Enum.sort_by(
      runs,
      fn run ->
        val = Map.get(run, field)

        case val do
          nil -> 0
          %DateTime{} -> DateTime.to_unix(val, :microsecond)
          %NaiveDateTime{} -> NaiveDateTime.to_gregorian_seconds(val) |> elem(0)
          n when is_number(n) -> n
          s when is_binary(s) -> String.downcase(s)
          _ -> 0
        end
      end,
      dir
    )
  end

  defp sum_field(runs, field) do
    runs |> Enum.map(&(Map.get(&1, field) || 0)) |> Enum.sum()
  end

  defp fmt_tokens(nil), do: "0"
  defp fmt_tokens(0), do: "0"
  defp fmt_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt_tokens(n), do: to_string(n)

  defp fmt_duration(nil), do: "--"
  defp fmt_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp fmt_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  defp fmt_duration(ms) when ms < 3_600_000 do
    "#{div(ms, 60_000)}m #{div(rem(ms, 60_000), 1_000)}s"
  end

  defp fmt_duration(ms) do
    "#{div(ms, 3_600_000)}h #{div(rem(ms, 3_600_000), 60_000)}m"
  end
end
