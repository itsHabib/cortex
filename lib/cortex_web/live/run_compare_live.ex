defmodule CortexWeb.RunCompareLive do
  @moduledoc """
  LiveView for comparing token usage and cost across completed runs.

  Displays a sortable table of completed runs with per-run token
  breakdowns (input, output, cache read, cache creation) and a
  totals row. Designed for comparing regular vs babel protocol runs.
  """
  use CortexWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: safe_subscribe()

    runs = load_completed_runs()

    {:ok,
     assign(socket,
       runs: runs,
       sort_col: "started_at",
       sort_dir: :desc,
       page_title: "Run Comparison"
     )}
  end

  @impl true
  def handle_info(%{type: type}, socket)
      when type in [:run_completed, :run_started] do
    {:noreply, assign(socket, runs: load_completed_runs())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("sort", %{"col" => col}, socket) do
    {sort_col, sort_dir} =
      if socket.assigns.sort_col == col do
        {col, flip_dir(socket.assigns.sort_dir)}
      else
        {col, :desc}
      end

    runs = sort_runs(socket.assigns.runs, sort_col, sort_dir)
    {:noreply, assign(socket, runs: runs, sort_col: sort_col, sort_dir: sort_dir)}
  end

  def handle_event("refresh", _params, socket) do
    runs =
      load_completed_runs()
      |> sort_runs(socket.assigns.sort_col, socket.assigns.sort_dir)

    {:noreply, assign(socket, runs: runs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Run Comparison
      <:subtitle>Token usage and cost across completed runs</:subtitle>
      <:actions>
        <button
          phx-click="refresh"
          class="text-sm text-gray-400 hover:text-white px-3 py-1 rounded border border-gray-700 hover:border-gray-500"
        >
          Refresh
        </button>
        <a href="/runs" class="text-sm text-gray-400 hover:text-white">Back to Runs</a>
      </:actions>
    </.header>

    <%= if @runs == [] do %>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <p class="text-gray-400">No completed runs yet.</p>
      </div>
    <% else %>
      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-x-auto">
        <table class="w-full">
          <thead>
            <tr class="border-b border-gray-800">
              <th :for={{col, label} <- columns()} class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-3 py-3">
                <button
                  phx-click="sort"
                  phx-value-col={col}
                  class="flex items-center gap-1 hover:text-gray-200 transition-colors"
                >
                  {label}
                  <span :if={@sort_col == col} class="text-cortex-400">
                    {if @sort_dir == :asc, do: " ↑", else: " ↓"}
                  </span>
                </button>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs} class="border-b border-gray-800/50 hover:bg-gray-800/30 transition-colors">
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
              <td class="px-3 py-2.5 text-sm font-mono text-gray-300">{fmt_cost(run.total_cost_usd)}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-gray-300">{fmt_duration(run.total_duration_ms)}</td>
              <td class="px-3 py-2.5 text-sm text-gray-400">{fmt_time(run.started_at || run.inserted_at)}</td>
            </tr>
            <!-- Totals row -->
            <tr class="border-t-2 border-gray-700 bg-gray-800/30 font-semibold">
              <td class="px-3 py-2.5 text-sm text-gray-300">Total ({length(@runs)} runs)</td>
              <td class="px-3 py-2.5"></td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_tokens(sum_field(@runs, :total_input_tokens))}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_tokens(sum_field(@runs, :total_output_tokens))}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_tokens(sum_field(@runs, :total_cache_read_tokens))}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_tokens(sum_field(@runs, :total_cache_creation_tokens))}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_cost(sum_float_field(@runs, :total_cost_usd))}</td>
              <td class="px-3 py-2.5 text-sm font-mono text-white">{fmt_duration(sum_field(@runs, :total_duration_ms))}</td>
              <td class="px-3 py-2.5"></td>
            </tr>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  # -- Private --

  defp columns do
    [
      {"name", "Name"},
      {"status", "Status"},
      {"total_input_tokens", "Input"},
      {"total_output_tokens", "Output"},
      {"total_cache_read_tokens", "Cache Read"},
      {"total_cache_creation_tokens", "Cache Create"},
      {"total_cost_usd", "Cost"},
      {"total_duration_ms", "Duration"},
      {"started_at", "Started"}
    ]
  end

  defp load_completed_runs do
    Cortex.Store.list_runs(limit: 100, status: "completed")
  rescue
    _ -> []
  end

  defp safe_subscribe do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp flip_dir(:asc), do: :desc
  defp flip_dir(:desc), do: :asc

  @spec sort_runs([map()], String.t(), :asc | :desc) :: [map()]
  defp sort_runs(runs, col, dir) do
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

  defp sum_float_field(runs, field) do
    runs |> Enum.map(&(Map.get(&1, field) || 0.0)) |> Enum.sum()
  end

  defp fmt_tokens(nil), do: "0"
  defp fmt_tokens(0), do: "0"
  defp fmt_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt_tokens(n), do: to_string(n)

  defp fmt_cost(nil), do: "--"
  defp fmt_cost(n) when is_number(n), do: "$#{:erlang.float_to_binary(n / 1, decimals: 4)}"
  defp fmt_cost(_), do: "--"

  defp fmt_duration(nil), do: "--"
  defp fmt_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp fmt_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  defp fmt_duration(ms) when ms < 3_600_000 do
    "#{div(ms, 60_000)}m #{div(rem(ms, 60_000), 1_000)}s"
  end

  defp fmt_duration(ms) do
    "#{div(ms, 3_600_000)}h #{div(rem(ms, 3_600_000), 60_000)}m"
  end

  defp fmt_time(nil), do: "--"

  defp fmt_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp fmt_time(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%Y-%m-%d %H:%M")

  defp fmt_time(_), do: "--"
end
