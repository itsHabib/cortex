defmodule CortexWeb.RunDetailLive do
  use CortexWeb, :live_view

  import CortexWeb.DAGComponents

  alias Cortex.Orchestration.DAG

  @max_activities 150

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
           activities: [],
           team_members: %{},
           page_title: "Run Not Found"
         )}

      run ->
        team_runs = safe_get_team_runs(run.id)
        {tiers, edges} = build_dag(run, team_runs)
        team_members = extract_team_members(run)
        team_names = Enum.map(team_runs, & &1.team_name)

        {:ok,
         assign(socket,
           run: run,
           team_runs: team_runs,
           tiers: tiers,
           edges: edges,
           team_members: team_members,
           team_names: team_names,
           activities: [],
           msg_to: "",
           msg_content: "",
           resume_workspace_path: "",
           page_title: "Run: #{run.name}"
         )}
    end
  end

  # -- Event handlers: lifecycle events (re-fetch from DB) --

  @impl true
  def handle_info(%{type: type, payload: _payload}, socket)
      when type in [
             :run_started,
             :team_started,
             :team_completed,
             :tier_started,
             :tier_completed,
             :run_completed
           ] do
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

  # -- Event handlers: live token updates --

  def handle_info(%{type: :team_tokens_updated, payload: payload}, socket) do
    run = socket.assigns.run

    if run && Map.get(payload, :run_id) == run.id do
      team_name = payload.team_name

      team_runs =
        Enum.map(socket.assigns.team_runs, fn tr ->
          if tr.team_name == team_name do
            %{tr | input_tokens: payload.input_tokens, output_tokens: payload.output_tokens}
          else
            tr
          end
        end)

      total_input =
        team_runs |> Enum.map(& &1.input_tokens) |> Enum.reject(&is_nil/1) |> Enum.sum()

      total_output =
        team_runs |> Enum.map(& &1.output_tokens) |> Enum.reject(&is_nil/1) |> Enum.sum()

      updated_run = %{run | total_input_tokens: total_input, total_output_tokens: total_output}

      {:noreply, assign(socket, team_runs: team_runs, run: updated_run)}
    else
      {:noreply, socket}
    end
  end

  # -- Event handlers: activity feed --

  def handle_info(%{type: :team_activity, payload: payload}, socket) do
    run = socket.assigns.run

    if run && Map.get(payload, :run_id) == run.id do
      tools = Map.get(payload, :tools, [])
      tool_str = Enum.join(tools, ", ")

      entry = %{
        team: payload.team_name,
        text: "using #{tool_str}",
        kind: :tool,
        at: format_now()
      }

      activities = prepend_activity(socket.assigns.activities, entry)
      {:noreply, assign(socket, activities: activities)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{type: :team_progress, payload: payload}, socket) do
    run = socket.assigns.run

    if run && Map.get(payload, :run_id) == run.id do
      message = Map.get(payload, :message, %{})
      content = Map.get(message, "content", Map.get(message, :content, ""))

      entry = %{
        team: payload.team_name,
        text: truncate(to_string(content), 200),
        kind: :progress,
        at: format_now()
      }

      activities = prepend_activity(socket.assigns.activities, entry)
      {:noreply, assign(socket, activities: activities)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Event handlers: message sending --

  @impl true
  def handle_event("send_message", %{"to" => to, "content" => content}, socket) do
    run = socket.assigns.run

    if run && to != "" && content != "" do
      workspace_path = run.workspace_path

      if workspace_path do
        Cortex.Orchestration.Runner.send_message(workspace_path, "coordinator", to, content)

        entry = %{
          team: "coordinator",
          text: "sent to #{to}: #{truncate(content, 100)}",
          kind: :message,
          at: format_now()
        }

        activities = prepend_activity(socket.assigns.activities, entry)

        {:noreply,
         socket
         |> assign(activities: activities, msg_content: "")
         |> put_flash(:info, "Message sent to #{to}")}
      else
        {:noreply, put_flash(socket, :error, "No workspace path — cannot send messages")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_workspace_path", %{"workspace_path" => path}, socket) do
    {:noreply, assign(socket, resume_workspace_path: path)}
  end

  def handle_event("resume_dead_teams", _params, socket) do
    run = socket.assigns.run
    workspace_path = run.workspace_path || non_empty(socket.assigns.resume_workspace_path)

    if run && workspace_path do
      # Persist workspace_path to run if it was manually entered
      if run.workspace_path == nil do
        safe_update_workspace(run, workspace_path)
      end

      entry = %{
        team: "system",
        text: "Resuming dead teams at #{workspace_path}...",
        kind: :message,
        at: format_now()
      }

      socket = assign(socket, activities: prepend_activity(socket.assigns.activities, entry))

      # Run resume in a background task so LiveView stays responsive
      Task.start(fn ->
        case Cortex.Orchestration.Runner.resume_run(workspace_path) do
          {:ok, results} ->
            Cortex.Events.broadcast(:run_resumed, %{
              run_id: run.id,
              results: Map.keys(results)
            })

          {:error, reason} ->
            require Logger
            Logger.error("Resume failed: #{inspect(reason)}")
        end
      end)

      {:noreply, put_flash(socket, :info, "Resuming dead teams...")}
    else
      {:noreply, put_flash(socket, :error, "No workspace path — cannot resume")}
    end
  end

  def handle_event("form_update", params, socket) do
    {:noreply,
     assign(socket,
       msg_to: Map.get(params, "to", socket.assigns.msg_to),
       msg_content: Map.get(params, "content", socket.assigns.msg_content)
     )}
  end

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
            <.token_display input={@run.total_input_tokens} output={@run.total_output_tokens} />
          </span>
          <span class="ml-2 text-gray-400">
            <.duration_display ms={@run.total_duration_ms} />
          </span>
        </:subtitle>
        <:actions>
          <a href="/runs" class="text-sm text-gray-400 hover:text-white">Back to Runs</a>
        </:actions>
      </.header>

      <!-- Resume Banner (shown when dead teams detected) -->
      <%= if has_dead_teams?(@team_runs, @run.status) do %>
        <div class="bg-yellow-900/30 border border-yellow-800 rounded-lg p-4 mb-6">
          <div class="flex items-center justify-between mb-2">
            <div>
              <p class="text-yellow-300 font-medium">Stalled teams detected</p>
              <p class="text-yellow-200/70 text-sm">
                {count_by_status(@team_runs, "running")} team(s) show as "running" but their processes have stopped. You can resume their sessions.
              </p>
            </div>
            <button
              phx-click="resume_dead_teams"
              class="rounded bg-yellow-600 px-4 py-2 text-sm font-medium text-white hover:bg-yellow-500 shrink-0"
            >
              Resume Dead Teams
            </button>
          </div>
          <%= unless @run.workspace_path do %>
            <form phx-change="set_workspace_path" class="flex items-center gap-2 mt-2 pt-2 border-t border-yellow-800/50">
              <label class="text-xs text-yellow-200/60 shrink-0">Workspace path:</label>
              <input
                type="text"
                name="workspace_path"
                value={@resume_workspace_path}
                class="flex-1 bg-gray-950 border border-yellow-800/50 rounded px-2 py-1 text-sm text-gray-300"
                placeholder="/path/to/project (containing .cortex/)"
              />
            </form>
          <% end %>
        </div>
      <% end %>

      <!-- Status Summary -->
      <% stalled = has_dead_teams?(@team_runs, @run.status) %>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-6">
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-3 text-center">
          <p class="text-xs text-gray-500 uppercase">Pending</p>
          <p class="text-lg font-bold text-gray-400">{count_by_status(@team_runs, "pending")}</p>
        </div>
        <%= if stalled do %>
          <div class="bg-gray-900 rounded-lg border border-yellow-900 p-3 text-center">
            <p class="text-xs text-yellow-400 uppercase">Stalled</p>
            <p class="text-lg font-bold text-yellow-300">{count_by_status(@team_runs, "running")}</p>
          </div>
        <% else %>
          <div class="bg-gray-900 rounded-lg border border-blue-900 p-3 text-center">
            <p class="text-xs text-blue-400 uppercase">Running</p>
            <p class="text-lg font-bold text-blue-300">{count_by_status(@team_runs, "running")}</p>
          </div>
        <% end %>
        <div class="bg-gray-900 rounded-lg border border-green-900 p-3 text-center">
          <p class="text-xs text-green-400 uppercase">Done</p>
          <p class="text-lg font-bold text-green-300">{count_by_status(@team_runs, ["completed", "done"])}</p>
        </div>
        <div class="bg-gray-900 rounded-lg border border-red-900 p-3 text-center">
          <p class="text-xs text-red-400 uppercase">Failed</p>
          <p class="text-lg font-bold text-red-300">{count_by_status(@team_runs, "failed")}</p>
        </div>
      </div>

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
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 mb-6">
          <a
            :for={team <- @team_runs}
            href={"/runs/#{@run.id}/teams/#{team.team_name}"}
            class="bg-gray-900 rounded-lg border border-gray-800 p-4 hover:border-gray-600 transition-colors block"
          >
            <div class="flex items-center justify-between mb-2">
              <h3 class="font-medium text-white">{team.team_name}</h3>
              <.status_badge status={display_status(team, @team_runs, @run.status)} />
            </div>
            <p :if={team.role} class="text-sm text-gray-400 mb-2">{team.role}</p>
            <%= if members = Map.get(@team_members, team.team_name, []) do %>
              <div :if={members != []} class="mb-2">
                <div class="flex flex-wrap gap-1">
                  <span
                    :for={member <- members}
                    class="inline-flex items-center rounded bg-gray-800 px-1.5 py-0.5 text-xs text-gray-400"
                  >
                    {member}
                  </span>
                </div>
              </div>
            <% end %>
            <div class="flex items-center gap-4 text-sm">
              <span class="text-gray-500">Tier {team.tier || 0}</span>
              <.token_display input={team.input_tokens} output={team.output_tokens} />
              <.duration_display ms={team.duration_ms} />
            </div>
          </a>
        </div>
      <% end %>

      <!-- Activity Feed + Message Panel -->
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <!-- Activity Feed (2/3 width) -->
        <div class="lg:col-span-2 bg-gray-900 rounded-lg border border-gray-800 p-4">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Activity Feed</h2>
          <%= if @activities == [] do %>
            <p class="text-gray-500 text-sm">No activity yet. Events will appear here in real-time.</p>
          <% else %>
            <div class="space-y-1 max-h-80 overflow-y-auto" id="activity-feed">
              <div :for={entry <- Enum.take(@activities, 50)} class="flex items-start gap-2 text-sm py-1">
                <span class="text-gray-600 text-xs shrink-0 mt-0.5">{entry.at}</span>
                <span class={activity_icon_class(entry.kind)}>{activity_icon(entry.kind)}</span>
                <span class="text-cortex-400 font-medium shrink-0">{entry.team}:</span>
                <span class="text-gray-300">{entry.text}</span>
              </div>
            </div>
          <% end %>
        </div>

        <!-- Send Message (1/3 width) -->
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Send Message</h2>
          <%= if @run.status == "running" and @run.workspace_path do %>
            <form phx-submit="send_message" phx-change="form_update" class="space-y-3">
              <div>
                <label class="text-xs text-gray-500 block mb-1">To</label>
                <select
                  name="to"
                  class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                >
                  <option value="">Select team...</option>
                  <option :for={name <- @team_names} value={name}>{name}</option>
                </select>
              </div>
              <div>
                <label class="text-xs text-gray-500 block mb-1">Message</label>
                <textarea
                  name="content"
                  rows="3"
                  class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300 resize-y"
                  placeholder="Type your message..."
                ><%= @msg_content %></textarea>
              </div>
              <button
                type="submit"
                class="w-full rounded bg-cortex-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-cortex-500"
              >
                Send
              </button>
            </form>
          <% else %>
            <p class="text-gray-500 text-sm">
              <%= if @run.status == "running" do %>
                No workspace path available for messaging.
              <% else %>
                Messaging available only during active runs.
              <% end %>
            </p>
          <% end %>
        </div>
      </div>
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
    teams_for_dag = build_teams_for_dag(run, team_runs)

    case DAG.build_tiers(teams_for_dag) do
      {:ok, tiers} ->
        edges = build_edges(teams_for_dag)
        {tiers, edges}

      _ ->
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

  defp extract_team_members(run) do
    if run.config_yaml do
      case YamlElixir.read_from_string(run.config_yaml) do
        {:ok, raw} ->
          raw
          |> Map.get("teams", [])
          |> Enum.map(fn team ->
            name = Map.get(team, "name", "")
            members = Map.get(team, "members", []) || []
            roles = Enum.map(members, fn m -> Map.get(m, "role", "") end)
            {name, roles}
          end)
          |> Map.new()

        _ ->
          %{}
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp run_title(run), do: run.name || "Untitled Run"

  defp has_dead_teams?(team_runs, run_status) do
    # Show resume banner when run status is "running" or "failed"
    # and there are teams stuck in "running" state
    run_status in ["running", "failed"] and
      Enum.any?(team_runs, fn tr -> (tr.status || "pending") == "running" end)
  end

  # Override "running" → "stalled" for display when the banner is showing
  defp display_status(team, team_runs, run_status) do
    raw = team.status || "pending"

    if raw == "running" and has_dead_teams?(team_runs, run_status) do
      "stalled"
    else
      raw
    end
  end

  defp count_by_status(team_runs, statuses) when is_list(statuses) do
    Enum.count(team_runs, fn tr -> (tr.status || "pending") in statuses end)
  end

  defp count_by_status(team_runs, status) do
    Enum.count(team_runs, fn tr -> (tr.status || "pending") == status end)
  end

  defp prepend_activity(activities, entry) do
    [entry | activities] |> Enum.take(@max_activities)
  end

  defp format_now do
    DateTime.utc_now() |> Calendar.strftime("%H:%M:%S")
  end

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp activity_icon(:tool), do: ">"
  defp activity_icon(:progress), do: "*"
  defp activity_icon(:message), do: "@"
  defp activity_icon(_), do: "-"

  defp activity_icon_class(:tool), do: "text-blue-400 font-mono"
  defp activity_icon_class(:progress), do: "text-green-400 font-mono"
  defp activity_icon_class(:message), do: "text-yellow-400 font-mono"
  defp activity_icon_class(_), do: "text-gray-400 font-mono"

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(s) when is_binary(s), do: String.trim(s) |> non_empty_trimmed()
  defp non_empty_trimmed(""), do: nil
  defp non_empty_trimmed(s), do: Path.expand(s)

  defp safe_update_workspace(run, workspace_path) do
    case Cortex.Store.get_run(run.id) do
      nil -> :ok
      fresh -> Cortex.Store.update_run(fresh, %{workspace_path: workspace_path})
    end
  rescue
    _ -> :ok
  end
end
