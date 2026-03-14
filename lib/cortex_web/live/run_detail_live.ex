defmodule CortexWeb.RunDetailLive do
  use CortexWeb, :live_view

  import CortexWeb.DAGComponents

  alias Cortex.Orchestration.DAG

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: safe_subscribe()

    case safe_get_run(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Run not found")
         |> assign(
           run: nil,
           team_runs: [],
           tiers: [],
           edges: [],
           page_title: "Run Not Found"
         )}

      run ->
        team_runs = safe_get_team_runs(run.id)
        {tiers, edges} = build_dag(run, team_runs)

        {:ok,
         assign(socket,
           run: run,
           team_runs: team_runs,
           tiers: tiers,
           edges: edges,
           page_title: "Run: #{run.name}"
         )}
    end
  end

  @impl true
  def handle_info(%{type: type, payload: _payload}, socket)
      when type in [:team_started, :team_completed, :tier_completed, :run_completed] do
    case socket.assigns.run do
      nil ->
        {:noreply, socket}

      run ->
        updated_run = safe_get_run(run.id)
        team_runs = safe_get_team_runs(run.id)
        {tiers, edges} = build_dag(updated_run || run, team_runs)

        {:noreply,
         assign(socket,
           run: updated_run || run,
           team_runs: team_runs,
           tiers: tiers,
           edges: edges
         )}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @run == nil do %>
      <.header>
        Run Not Found
        <:subtitle>The requested run could not be found</:subtitle>
      </.header>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <p class="text-gray-400">This run does not exist or has been deleted.</p>
        <a href="/runs" class="text-cortex-400 hover:text-cortex-300 mt-2 inline-block">Back to Runs</a>
      </div>
    <% else %>
      <.header>
        {run_title(@run)}
        <:subtitle>
          <.status_badge status={@run.status} />
          <span class="ml-2 text-gray-400">
            <.cost_display amount={@run.total_cost_usd} />
          </span>
          <span class="ml-2 text-gray-400">
            <.duration_display ms={@run.total_duration_ms} />
          </span>
        </:subtitle>
        <:actions>
          <a href="/runs" class="text-sm text-gray-400 hover:text-white">Back to Runs</a>
        </:actions>
      </.header>

      <!-- DAG Visualization -->
      <%= if @tiers != [] do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-6">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Dependency Graph</h2>
          <.dag_graph
            tiers={@tiers}
            teams={@team_runs}
            edges={@edges}
            run_id={@run.id}
          />
        </div>
      <% end %>

      <!-- Team Cards -->
      <h2 class="text-lg font-semibold text-white mb-4">Teams</h2>
      <%= if @team_runs == [] do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <p class="text-gray-400">No teams recorded for this run.</p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <a
            :for={team <- @team_runs}
            href={"/runs/#{@run.id}/teams/#{team.team_name}"}
            class="bg-gray-900 rounded-lg border border-gray-800 p-4 hover:border-gray-600 transition-colors block"
          >
            <div class="flex items-center justify-between mb-2">
              <h3 class="font-medium text-white">{team.team_name}</h3>
              <.status_badge status={team.status || "pending"} />
            </div>
            <p :if={team.role} class="text-sm text-gray-400 mb-2">{team.role}</p>
            <div class="flex items-center gap-4 text-sm">
              <span class="text-gray-500">Tier {team.tier || 0}</span>
              <.cost_display amount={team.cost_usd} />
              <.duration_display ms={team.duration_ms} />
            </div>
          </a>
        </div>
      <% end %>
    <% end %>
    """
  end

  # -- Private helpers --

  defp safe_get_run(id) do
    Cortex.Store.get_run(id)
  rescue
    _ -> nil
  end

  defp safe_get_team_runs(run_id) do
    Cortex.Store.get_team_runs(run_id)
  rescue
    _ -> []
  end

  defp safe_subscribe do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp build_dag(run, team_runs) do
    # Try to build tiers from config_yaml, fall back to team_runs tier data
    teams_for_dag = build_teams_for_dag(run, team_runs)

    case DAG.build_tiers(teams_for_dag) do
      {:ok, tiers} ->
        edges = build_edges(teams_for_dag)
        {tiers, edges}

      _ ->
        # Fallback: group by tier field on team_runs
        tiers = build_tiers_from_team_runs(team_runs)
        {tiers, []}
    end
  end

  defp build_teams_for_dag(run, team_runs) do
    if run.config_yaml do
      case parse_config_teams(run.config_yaml) do
        {:ok, config_teams} -> config_teams
        _ -> team_runs_to_dag_input(team_runs)
      end
    else
      team_runs_to_dag_input(team_runs)
    end
  end

  defp parse_config_teams(yaml_string) do
    case Cortex.Orchestration.Config.Loader.load_string(yaml_string) do
      {:ok, config, _warnings} ->
        teams =
          Enum.map(config.teams, fn t ->
            %{name: t.name, depends_on: t.depends_on || []}
          end)

        {:ok, teams}

      _ ->
        :error
    end
  end

  defp team_runs_to_dag_input(team_runs) do
    Enum.map(team_runs, fn tr ->
      %{name: tr.team_name, depends_on: []}
    end)
  end

  defp build_edges(teams) do
    Enum.flat_map(teams, fn team ->
      Enum.map(team.depends_on, fn dep -> {dep, team.name} end)
    end)
  end

  defp build_tiers_from_team_runs(team_runs) do
    team_runs
    |> Enum.group_by(fn tr -> tr.tier || 0 end)
    |> Enum.sort_by(fn {tier, _} -> tier end)
    |> Enum.map(fn {_tier, runs} ->
      Enum.map(runs, & &1.team_name) |> Enum.sort()
    end)
  end

  defp run_title(run), do: run.name || "Untitled Run"
end
