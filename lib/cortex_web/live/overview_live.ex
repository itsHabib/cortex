defmodule CortexWeb.OverviewLive do
  @moduledoc """
  System overview page showing at-a-glance health metrics.

  Renamed from DashboardLive. Displays stat cards (total runs, active runs,
  total tokens, connected agents) and a recent runs table.
  """

  use CortexWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      safe_subscribe()
      safe_subscribe_gateway()
    end

    runs = safe_list_runs(limit: 10)

    {total_input, total_output} = compute_total_tokens(runs)

    active_count = Enum.count(runs, fn r -> r.status == "running" end)

    connected_agents = safe_gateway_agent_count()

    {:ok,
     assign(socket,
       runs: runs,
       total_input_tokens: total_input,
       total_output_tokens: total_output,
       active_count: active_count,
       connected_agents: connected_agents,
       page_title: "Overview"
     )}
  end

  @impl true
  def handle_info(%{type: type, payload: _payload}, socket)
      when type in [:run_started, :run_completed, :team_completed, :team_started, :tier_completed] do
    runs = safe_list_runs(limit: 10)

    {total_input, total_output} = compute_total_tokens(runs)

    active_count = Enum.count(runs, fn r -> r.status == "running" end)

    {:noreply,
     assign(socket,
       runs: runs,
       total_input_tokens: total_input,
       total_output_tokens: total_output,
       active_count: active_count
     )}
  end

  def handle_info(%{type: type}, socket)
      when type in [:agent_registered, :agent_unregistered] do
    {:noreply, assign(socket, connected_agents: safe_gateway_agent_count())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Overview
      <:subtitle>Overview of orchestration runs and system status</:subtitle>
      <:actions>
        <a
          href="/runs?view=compare"
          class="inline-flex items-center rounded-md bg-gray-700 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-gray-600"
        >
          Compare Runs
        </a>
        <a
          href="/workflows"
          class="inline-flex items-center rounded-md bg-cortex-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-cortex-500"
        >
          + New Workflow
        </a>
      </:actions>
    </.header>

    <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
        <p class="text-sm text-gray-400">Total Runs</p>
        <p class="text-2xl font-bold text-white mt-1">{length(@runs)}</p>
      </div>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
        <p class="text-sm text-gray-400">Active Runs</p>
        <p class="text-2xl font-bold text-white mt-1">{@active_count}</p>
      </div>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
        <p class="text-sm text-gray-400">Total Tokens</p>
        <p class="text-2xl font-bold text-white mt-1">
          <.token_display input={@total_input_tokens} output={@total_output_tokens} />
        </p>
      </div>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
        <p class="text-sm text-gray-400">Connected Agents</p>
        <p class="text-2xl font-bold text-white mt-1">{@connected_agents}</p>
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
              <th class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3">Participants</th>
              <th class="text-left text-xs font-medium text-gray-400 uppercase tracking-wider px-4 py-3">Tokens</th>
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
              <td class="px-4 py-3">
                <div class="flex items-center gap-2">
                  <.status_badge status={run.status} />
                  <span class={["text-xs px-1.5 py-0.5 rounded", mode_class(run.mode)]}>
                    {run.mode || "workflow"}
                  </span>
                </div>
              </td>
              <td class="px-4 py-3 text-sm text-gray-300">{run.team_count || 0}</td>
              <td class="px-4 py-3"><.token_display input={run.total_input_tokens} output={run.total_output_tokens} /></td>
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

  defp safe_subscribe_gateway do
    Cortex.Gateway.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp safe_gateway_agent_count do
    Cortex.Gateway.Registry.count()
  rescue
    _ -> 0
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

  defp compute_total_tokens(runs) do
    total_input =
      runs
      |> Enum.map(& &1.total_input_tokens)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    total_output =
      runs
      |> Enum.map(& &1.total_output_tokens)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    {total_input, total_output}
  end
end
