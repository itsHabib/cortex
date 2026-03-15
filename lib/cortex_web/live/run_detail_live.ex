defmodule CortexWeb.RunDetailLive do
  use CortexWeb, :live_view

  import CortexWeb.DAGComponents

  alias Cortex.Messaging.InboxBridge
  alias Cortex.Orchestration.Config.Loader, as: ConfigLoader
  alias Cortex.Orchestration.DAG
  alias Cortex.Orchestration.Injection
  alias Cortex.Orchestration.LogParser
  alias Cortex.Orchestration.Runner
  alias Cortex.Orchestration.Spawner
  alias Cortex.Orchestration.Workspace

  @max_activities 150
  @stale_threshold_seconds 300
  @max_log_lines 500
  @pid_check_interval_ms 30_000

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
           page_title: "Run Not Found",
           current_tab: "overview",
           last_seen: %{},
           selected_log_team: nil,
           log_lines: nil,
           log_sort: :desc,
           expanded_logs: MapSet.new(),
           messages_team: nil,
           team_inbox: [],
           team_outbox: [],
           diagnostics_team: nil,
           diagnostics_report: nil,
           run_summary: nil,
           pid_status: %{}
         )}

      run ->
        team_runs = safe_get_team_runs(run.id)
        {tiers, edges} = build_dag(run, team_runs)
        team_members = extract_team_members(run)
        team_names = Enum.map(team_runs, & &1.team_name)

        coordinator_alive =
          Runner.coordinator_alive?(run.id)

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
           page_title: "Run: #{run.name}",
           current_tab: "overview",
           last_seen: %{},
           log_sort: :desc,
           selected_log_team: nil,
           log_lines: nil,
           expanded_logs: MapSet.new(),
           messages_team: nil,
           team_inbox: [],
           team_outbox: [],
           diagnostics_team: nil,
           diagnostics_report: nil,
           coordinator_alive: coordinator_alive,
           run_summary: nil,
           pid_status: %{}
         )}
        |> tap(fn _ -> maybe_start_pid_check(run, socket) end)
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

        coordinator_alive =
          Runner.coordinator_alive?(run.id)

        # Auto-generate summary on tier/run completion (with full diagnostics)
        run_summary =
          if type in [:tier_completed, :run_completed] do
            build_run_summary(updated_run || run, team_runs, socket.assigns.last_seen,
              include_diagnostics: true
            )
          else
            socket.assigns.run_summary
          end

        {:noreply,
         assign(socket,
           run: updated_run || run,
           team_runs: team_runs,
           tiers: tiers,
           edges: edges,
           coordinator_alive: coordinator_alive,
           run_summary: run_summary
         )}
    end
  end

  # -- Event handlers: live token updates (+ last_seen tracking) --

  def handle_info(%{type: :team_tokens_updated, payload: payload}, socket) do
    run = socket.assigns.run

    if run && Map.get(payload, :run_id) == run.id do
      team_name = payload.team_name
      last_seen = Map.put(socket.assigns.last_seen, team_name, DateTime.utc_now())

      team_runs = update_team_tokens(socket.assigns.team_runs, team_name, payload)

      total_input =
        team_runs |> Enum.map(& &1.input_tokens) |> Enum.reject(&is_nil/1) |> Enum.sum()

      total_output =
        team_runs |> Enum.map(& &1.output_tokens) |> Enum.reject(&is_nil/1) |> Enum.sum()

      updated_run = %{run | total_input_tokens: total_input, total_output_tokens: total_output}

      # Auto-refresh summary if one exists (skip expensive diag loading)
      run_summary =
        if socket.assigns.run_summary do
          build_run_summary(updated_run, team_runs, last_seen, include_diagnostics: false)
        end

      {:noreply,
       assign(socket,
         team_runs: team_runs,
         run: updated_run,
         last_seen: last_seen,
         run_summary: run_summary
       )}
    else
      {:noreply, socket}
    end
  end

  # -- Event handlers: activity feed (+ last_seen tracking) --

  def handle_info(%{type: :team_activity, payload: payload}, socket) do
    run = socket.assigns.run

    if run && Map.get(payload, :run_id) == run.id do
      team_name = payload.team_name
      last_seen = Map.put(socket.assigns.last_seen, team_name, DateTime.utc_now())

      tools = Map.get(payload, :tools, [])
      details = Map.get(payload, :details, [])
      text = format_tool_activity(tools, details)

      entry = %{
        team: team_name,
        text: text,
        kind: :tool,
        at: format_now()
      }

      activities = prepend_activity(socket.assigns.activities, entry)
      {:noreply, assign(socket, activities: activities, last_seen: last_seen)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{type: :team_progress, payload: payload}, socket) do
    run = socket.assigns.run

    if run && Map.get(payload, :run_id) == run.id do
      team_name = payload.team_name
      last_seen = Map.put(socket.assigns.last_seen, team_name, DateTime.utc_now())

      message = Map.get(payload, :message, %{})
      content = Map.get(message, "content", Map.get(message, :content, ""))

      entry = %{
        team: team_name,
        text: truncate(to_string(content), 200),
        kind: :progress,
        at: format_now()
      }

      activities = prepend_activity(socket.assigns.activities, entry)

      # Auto-refresh messages if on messages tab viewing this team
      socket =
        if socket.assigns.current_tab == "messages" and
             socket.assigns.messages_team == team_name do
          {inbox, outbox} = read_team_messages(run, team_name)

          assign(socket,
            activities: activities,
            last_seen: last_seen,
            team_inbox: inbox,
            team_outbox: outbox
          )
        else
          assign(socket, activities: activities, last_seen: last_seen)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # -- Event handlers: resume feedback --

  def handle_info(%{type: :team_resume_result, payload: payload}, socket) do
    run = socket.assigns.run

    if run && Map.get(payload, :run_id) == run.id do
      status = payload.status
      reason = Map.get(payload, :reason, "")

      entry = %{
        team: payload.team_name,
        text: "resume #{status}: #{reason}",
        kind: :resume,
        at: format_now()
      }

      activities = prepend_activity(socket.assigns.activities, entry)
      {:noreply, assign(socket, activities: activities)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{type: :run_resumed, payload: payload}, socket) do
    run = socket.assigns.run

    if run && Map.get(payload, :run_id) == run.id do
      # Re-fetch team_runs from DB so statuses update
      team_runs = safe_get_team_runs(run.id)
      {tiers, edges} = build_dag(run, team_runs)

      entry = %{
        team: "system",
        text: "resume complete -- team statuses refreshed",
        kind: :resume,
        at: format_now()
      }

      activities = prepend_activity(socket.assigns.activities, entry)

      {:noreply,
       assign(socket,
         team_runs: team_runs,
         tiers: tiers,
         edges: edges,
         activities: activities
       )}
    else
      {:noreply, socket}
    end
  end

  # -- PID health check (periodic) --

  def handle_info(:check_pids, socket) do
    run = socket.assigns.run

    if run && run.workspace_path && run.status in ["running", "failed"] do
      pid_status = check_all_team_pids(run.workspace_path)

      # Schedule next check
      Process.send_after(self(), :check_pids, @pid_check_interval_ms)

      {:noreply, assign(socket, pid_status: pid_status)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Event handlers: tab switching --

  @impl true
  def handle_event("switch_tab", %{"tab" => "logs"}, socket) do
    socket =
      cond do
        socket.assigns.selected_log_team == "__all__" ->
          log_lines = read_all_team_logs(socket.assigns.run, socket.assigns.team_names)
          sorted = sort_log_lines(log_lines, socket.assigns.log_sort)
          assign(socket, log_lines: sorted)

        socket.assigns.selected_log_team ->
          log_lines = read_team_log(socket.assigns.run, socket.assigns.selected_log_team)
          sorted = sort_log_lines(log_lines, socket.assigns.log_sort)
          assign(socket, log_lines: sorted)

        socket.assigns.team_names != [] ->
          first = hd(socket.assigns.team_names)
          log_lines = read_team_log(socket.assigns.run, first)
          sorted = sort_log_lines(log_lines, socket.assigns.log_sort)
          assign(socket, selected_log_team: first, log_lines: sorted)

        true ->
          socket
      end

    {:noreply, assign(socket, current_tab: "logs")}
  end

  def handle_event("switch_tab", %{"tab" => "messages"}, socket) do
    socket =
      if socket.assigns.messages_team do
        {inbox, outbox} = read_team_messages(socket.assigns.run, socket.assigns.messages_team)
        assign(socket, team_inbox: inbox, team_outbox: outbox)
      else
        socket
      end

    {:noreply, assign(socket, current_tab: "messages")}
  end

  def handle_event("switch_tab", %{"tab" => "diagnostics"}, socket) do
    socket =
      cond do
        socket.assigns.diagnostics_team ->
          team_status = get_team_status(socket.assigns.team_runs, socket.assigns.diagnostics_team)

          report =
            load_diagnostics(socket.assigns.run, socket.assigns.diagnostics_team,
              team_status: team_status
            )

          assign(socket, diagnostics_report: report)

        socket.assigns.team_names != [] ->
          # Auto-select first running/stalled team, or first team
          first =
            Enum.find(socket.assigns.team_runs, fn tr ->
              (tr.status || "pending") == "running"
            end)

          first_name = if first, do: first.team_name, else: hd(socket.assigns.team_names)
          team_status = get_team_status(socket.assigns.team_runs, first_name)
          report = load_diagnostics(socket.assigns.run, first_name, team_status: team_status)
          assign(socket, diagnostics_team: first_name, diagnostics_report: report)

        true ->
          socket
      end

    {:noreply, assign(socket, current_tab: "diagnostics")}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, current_tab: tab)}
  end

  # -- Event handlers: log team selection --

  def handle_event("select_log_team", %{"team" => ""}, socket) do
    {:noreply,
     assign(socket, selected_log_team: nil, log_lines: nil, expanded_logs: MapSet.new())}
  end

  def handle_event("select_log_team", %{"team" => "__all__"}, socket) do
    log_lines = read_all_team_logs(socket.assigns.run, socket.assigns.team_names)
    sorted = sort_log_lines(log_lines, socket.assigns.log_sort)

    {:noreply,
     assign(socket, selected_log_team: "__all__", log_lines: sorted, expanded_logs: MapSet.new())}
  end

  def handle_event("select_log_team", %{"team" => team_name}, socket) do
    log_lines = read_team_log(socket.assigns.run, team_name)
    sorted = sort_log_lines(log_lines, socket.assigns.log_sort)

    {:noreply,
     assign(socket, selected_log_team: team_name, log_lines: sorted, expanded_logs: MapSet.new())}
  end

  def handle_event("refresh_logs", _params, socket) do
    case socket.assigns.selected_log_team do
      nil ->
        {:noreply, socket}

      "__all__" ->
        log_lines = read_all_team_logs(socket.assigns.run, socket.assigns.team_names)
        sorted = sort_log_lines(log_lines, socket.assigns.log_sort)
        {:noreply, assign(socket, log_lines: sorted, expanded_logs: MapSet.new())}

      team_name ->
        log_lines = read_team_log(socket.assigns.run, team_name)
        sorted = sort_log_lines(log_lines, socket.assigns.log_sort)
        {:noreply, assign(socket, log_lines: sorted, expanded_logs: MapSet.new())}
    end
  end

  def handle_event("toggle_log_sort", _params, socket) do
    new_sort = if socket.assigns.log_sort == :asc, do: :desc, else: :asc

    sorted =
      if socket.assigns.log_lines do
        sort_log_lines(socket.assigns.log_lines, new_sort)
      end

    {:noreply, assign(socket, log_sort: new_sort, log_lines: sorted, expanded_logs: MapSet.new())}
  end

  def handle_event("toggle_log_line", %{"line" => line_str}, socket) do
    line_num = String.to_integer(line_str)

    expanded =
      if MapSet.member?(socket.assigns.expanded_logs, line_num) do
        MapSet.delete(socket.assigns.expanded_logs, line_num)
      else
        MapSet.put(socket.assigns.expanded_logs, line_num)
      end

    {:noreply, assign(socket, expanded_logs: expanded)}
  end

  # -- Event handlers: diagnostics team selection --

  def handle_event("select_diag_team", %{"team" => ""}, socket) do
    {:noreply, assign(socket, diagnostics_team: nil, diagnostics_report: nil)}
  end

  def handle_event("select_diag_team", %{"team" => team_name}, socket) do
    team_status = get_team_status(socket.assigns.team_runs, team_name)
    report = load_diagnostics(socket.assigns.run, team_name, team_status: team_status)
    {:noreply, assign(socket, diagnostics_team: team_name, diagnostics_report: report)}
  end

  def handle_event("refresh_diagnostics", _params, socket) do
    if socket.assigns.diagnostics_team do
      team_status = get_team_status(socket.assigns.team_runs, socket.assigns.diagnostics_team)

      report =
        load_diagnostics(socket.assigns.run, socket.assigns.diagnostics_team,
          team_status: team_status
        )

      {:noreply, assign(socket, diagnostics_report: report)}
    else
      {:noreply, socket}
    end
  end

  # -- Event handlers: messages team selection --

  def handle_event("select_messages_team", %{"team" => ""}, socket) do
    {:noreply, assign(socket, messages_team: nil, team_inbox: [], team_outbox: [])}
  end

  def handle_event("select_messages_team", %{"team" => team_name}, socket) do
    {inbox, outbox} = read_team_messages(socket.assigns.run, team_name)

    {:noreply,
     assign(socket,
       messages_team: team_name,
       team_inbox: inbox,
       team_outbox: outbox,
       msg_to: team_name
     )}
  end

  def handle_event("refresh_messages", _params, socket) do
    if socket.assigns.messages_team do
      {inbox, outbox} = read_team_messages(socket.assigns.run, socket.assigns.messages_team)
      {:noreply, assign(socket, team_inbox: inbox, team_outbox: outbox)}
    else
      {:noreply, socket}
    end
  end

  # -- Event handlers: message sending --

  def handle_event("send_message", %{"to" => to, "content" => content}, socket) do
    run = socket.assigns.run
    workspace_path = run && run.workspace_path

    cond do
      not (run && to != "" && content != "") ->
        {:noreply, socket}

      not workspace_path ->
        {:noreply, put_flash(socket, :error, "No workspace path -- cannot send messages")}

      true ->
        Runner.send_message(workspace_path, "coordinator", to, content)

        entry = %{
          team: "coordinator",
          text: "sent to #{to}: #{truncate(content, 100)}",
          kind: :message,
          at: format_now()
        }

        activities = prepend_activity(socket.assigns.activities, entry)

        socket =
          if socket.assigns.messages_team == to do
            {inbox, outbox} = read_team_messages(run, to)
            assign(socket, activities: activities, msg_content: "", team_inbox: inbox, team_outbox: outbox)
          else
            assign(socket, activities: activities, msg_content: "")
          end

        {:noreply, socket |> put_flash(:info, "Message sent to #{to}")}
    end
  end

  def handle_event("set_workspace_path", %{"workspace_path" => path}, socket) do
    {:noreply, assign(socket, resume_workspace_path: path)}
  end

  def handle_event("resume_dead_teams", _params, socket) do
    run = socket.assigns.run
    workspace_path = run.workspace_path || non_empty(socket.assigns.resume_workspace_path)

    if run && workspace_path do
      if run.workspace_path == nil, do: safe_update_workspace(run, workspace_path)

      entry = %{
        team: "system",
        text: "Resuming stalled teams at #{workspace_path}...",
        kind: :resume,
        at: format_now()
      }

      socket = assign(socket, activities: prepend_activity(socket.assigns.activities, entry))
      spawn_resume_all_task(run.id, workspace_path)
      {:noreply, put_flash(socket, :info, "Resuming stalled teams...")}
    else
      {:noreply, put_flash(socket, :error, "No workspace path -- cannot resume")}
    end
  end

  def handle_event("resume_single_team", %{"team" => team_name}, socket) do
    run = socket.assigns.run
    workspace_path = run.workspace_path || non_empty(socket.assigns.resume_workspace_path)

    if run && workspace_path do
      if run.workspace_path == nil, do: safe_update_workspace(run, workspace_path)

      entry = %{
        team: "system",
        text: "Resuming #{team_name} at #{workspace_path}...",
        kind: :resume,
        at: format_now()
      }

      socket = assign(socket, activities: prepend_activity(socket.assigns.activities, entry))
      spawn_resume_single_task(run.id, team_name, workspace_path)
      {:noreply, put_flash(socket, :info, "Resuming #{team_name}...")}
    else
      {:noreply, put_flash(socket, :error, "No workspace path — cannot resume")}
    end
  end

  def handle_event("restart_team", %{"team" => team_name}, socket) do
    run = socket.assigns.run
    workspace_path = run && run.workspace_path
    team_run = Enum.find(socket.assigns.team_runs, &(&1.team_name == team_name))

    cond do
      not (run && workspace_path) ->
        {:noreply, put_flash(socket, :error, "No workspace path — cannot restart")}

      team_pid_alive?(workspace_path, team_name) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "#{team_name} process is still alive (PID running). " <>
             "Wait for it to finish or kill it manually before restarting."
         )}

      not (team_run && team_run.prompt) ->
        {:noreply, put_flash(socket, :error, "No prompt found for #{team_name}")}

      true ->
        do_restart_team(socket, run, team_name, team_run, workspace_path)
    end
  end

  def handle_event("delete_run", _params, socket) do
    run = socket.assigns.run

    if run do
      case Cortex.Store.delete_run(run) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Run deleted")
           |> push_navigate(to: "/runs")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete run")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("reconcile_run", _params, socket) do
    run = socket.assigns.run

    if run do
      entry = %{
        team: "system",
        text: "Reconciling state — scanning logs for completed sessions...",
        kind: :resume,
        at: format_now()
      }

      socket = assign(socket, activities: prepend_activity(socket.assigns.activities, entry))
      handle_reconcile_result(socket, run, Runner.reconcile_run(run.id))
    else
      {:noreply, socket}
    end
  end

  def handle_event("continue_run", _params, socket) do
    run = socket.assigns.run

    if run do
      run_id = run.id

      entry = %{
        team: "system",
        text: "Continuing run — spawning remaining teams...",
        kind: :resume,
        at: format_now()
      }

      socket = assign(socket, activities: prepend_activity(socket.assigns.activities, entry))

      spawn_continue_run_task(run_id)

      {:noreply, put_flash(socket, :info, "Continuing run — remaining teams will be spawned...")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("start_coordinator", _params, socket) do
    run = socket.assigns.run

    if run && run.workspace_path && run.config_yaml do
      with {:ok, config, _warnings} <- ConfigLoader.load_string(run.config_yaml),
           {:ok, tiers} <- DAG.build_tiers(config.teams) do
        do_start_coordinator(socket, run, config, tiers)
      else
        _ -> {:noreply, put_flash(socket, :error, "Failed to parse config or build DAG")}
      end
    else
      {:noreply, put_flash(socket, :error, "No workspace path or config available")}
    end
  end

  def handle_event("generate_summary", _params, socket) do
    summary =
      build_run_summary(socket.assigns.run, socket.assigns.team_runs, socket.assigns.last_seen,
        include_diagnostics: true
      )

    {:noreply, assign(socket, run_summary: summary)}
  end

  def handle_event("form_update", params, socket) do
    {:noreply,
     assign(socket,
       msg_to: Map.get(params, "to", socket.assigns.msg_to),
       msg_content: Map.get(params, "content", socket.assigns.msg_content)
     )}
  end

  # -- Render --

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
            <.token_display input={sum_team_field(@team_runs, :input_tokens)} output={sum_team_field(@team_runs, :output_tokens)} />
          </span>
          <span class="ml-2 text-gray-400">
            <.duration_display ms={@run.total_duration_ms} />
          </span>
          <span :if={@run.workspace_path} class="ml-2 text-gray-500 text-xs font-mono">
            {@run.workspace_path}
          </span>
        </:subtitle>
        <:actions>
          <button
            phx-click="delete_run"
            data-confirm="Are you sure you want to delete this run? This cannot be undone."
            class="text-sm text-red-400 hover:text-red-300"
          >
            Delete
          </button>
          <a href="/runs" class="text-sm text-gray-400 hover:text-white">Back to Runs</a>
        </:actions>
      </.header>

      <!-- Resume Banner (visible across all tabs when stalled teams detected) -->
      <%= if has_stalled_teams?(@team_runs, @run.status, @last_seen, @pid_status) do %>
        <div class="bg-yellow-900/30 border border-yellow-800 rounded-lg p-4 mb-6">
          <div class="flex items-center justify-between mb-2">
            <div>
              <p class="text-yellow-300 font-medium">Stalled teams detected</p>
              <p class="text-yellow-200/70 text-sm">
                {count_stalled(@team_runs, @last_seen, @pid_status)} team(s) show as "running" but have no live PID and no events in over 5 minutes:
                <span class="font-mono">
                  {stalled_team_names(@team_runs, @last_seen, @pid_status) |> Enum.join(", ")}
                </span>
              </p>
            </div>
            <button
              phx-click="resume_dead_teams"
              class="rounded bg-yellow-600 px-4 py-2 text-sm font-medium text-white hover:bg-yellow-500 shrink-0"
            >
              Resume All Stalled
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

      <!-- Continue Run Banner (visible when run is interrupted with incomplete teams) -->
      <% incomplete = incomplete_team_names(@run, @team_runs) %>
      <%= if incomplete != [] and @run.status in ["running", "failed"] and not @coordinator_alive do %>
        <div class="bg-blue-900/30 border border-blue-800 rounded-lg p-4 mb-6">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-blue-300 font-medium">Run interrupted — {length(incomplete)} incomplete team(s)</p>
              <p class="text-blue-200/70 text-sm">
                The coordinator process died before all tiers completed.
                Remaining: <span class="font-mono">{Enum.join(incomplete, ", ")}</span>
              </p>
            </div>
            <div class="flex gap-2 shrink-0">
              <button
                phx-click="reconcile_run"
                class="rounded bg-gray-600 px-4 py-2 text-sm font-medium text-white hover:bg-gray-500"
              >
                Reconcile State
              </button>
              <button
                phx-click="continue_run"
                class="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500"
              >
                Continue Run
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <!-- Tab Bar -->
      <div class="flex border-b border-gray-800 mb-6">
        <button
          :for={tab <- ~w(overview activity messages logs diagnostics)}
          phx-click="switch_tab"
          phx-value-tab={tab}
          class={[
            "px-4 py-2 text-sm font-medium border-b-2 transition-colors",
            if(@current_tab == tab,
              do: "text-cortex-400 border-cortex-400",
              else: "text-gray-400 border-transparent hover:text-gray-200 hover:border-gray-600"
            )
          ]}
        >
          {tab_label(tab, assigns)}
        </button>
      </div>

      <!-- ============ Overview Tab ============ -->
      <div :if={@current_tab == "overview"}>
        <!-- Coordinator + Status Summary -->
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3 mb-6">
          <div class={[
            "bg-gray-900 rounded-lg border p-3 text-center",
            if(@coordinator_alive, do: "border-green-900", else: "border-gray-800")
          ]}>
            <p class="text-xs text-gray-500 uppercase">Coordinator</p>
            <%= if @coordinator_alive do %>
              <p class="text-lg font-bold text-green-300">Alive</p>
            <% else %>
              <p class="text-lg font-bold text-gray-500">Dead</p>
              <button
                :if={@run && @run.workspace_path}
                phx-click="start_coordinator"
                class="mt-1 text-xs text-cortex-400 hover:text-cortex-300 underline"
              >
                Start
              </button>
            <% end %>
          </div>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-3 text-center">
            <p class="text-xs text-gray-500 uppercase">Pending</p>
            <p class="text-lg font-bold text-gray-400">{count_by_status(@team_runs, "pending")}</p>
          </div>
          <div class="bg-gray-900 rounded-lg border border-blue-900 p-3 text-center">
            <p class="text-xs text-blue-400 uppercase">Running</p>
            <p class="text-lg font-bold text-blue-300">{count_active_running(@team_runs, @last_seen, @pid_status)}</p>
          </div>
          <div class="bg-gray-900 rounded-lg border border-yellow-900 p-3 text-center">
            <p class="text-xs text-yellow-400 uppercase">Stalled</p>
            <p class="text-lg font-bold text-yellow-300">{count_stalled(@team_runs, @last_seen, @pid_status)}</p>
          </div>
          <div class="bg-gray-900 rounded-lg border border-green-900 p-3 text-center">
            <p class="text-xs text-green-400 uppercase">Done</p>
            <p class="text-lg font-bold text-green-300">{count_by_status(@team_runs, ["completed", "done"])}</p>
          </div>
          <div class="bg-gray-900 rounded-lg border border-red-900 p-3 text-center">
            <p class="text-xs text-red-400 uppercase">Failed</p>
            <p class="text-lg font-bold text-red-300">{count_by_status(@team_runs, "failed")}</p>
          </div>
        </div>

        <!-- On-demand Run Summary -->
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-6">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Run Summary</h2>
            <button
              phx-click="generate_summary"
              class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
            >
              {if @run_summary, do: "Refresh", else: "Generate"}
            </button>
          </div>
          <%= if @run_summary do %>
            <pre class="text-gray-300 text-sm font-mono whitespace-pre overflow-x-auto bg-gray-950 rounded p-3">{@run_summary}</pre>
          <% else %>
            <p class="text-gray-500 text-sm">Click Generate to build a summary of current run state.</p>
          <% end %>
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
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <a
              :for={team <- @team_runs}
              href={"/runs/#{@run.id}/teams/#{team.team_name}"}
              class="bg-gray-900 rounded-lg border border-gray-800 p-4 hover:border-gray-600 transition-colors block"
            >
              <div class="flex items-center justify-between mb-2">
                <h3 class="font-medium text-white">{team.team_name}</h3>
                <.status_badge status={display_status(team, @last_seen, @pid_status)} />
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
      </div>

      <!-- ============ Activity Tab ============ -->
      <div :if={@current_tab == "activity"}>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Activity Feed</h2>
            <span class="text-xs text-gray-600">{length(@activities)} events</span>
          </div>
          <%= if @activities == [] do %>
            <p class="text-gray-500 text-sm">No activity yet. Events appear here in real-time and clear on page reload.</p>
          <% else %>
            <div class="space-y-1 min-h-[60vh] max-h-[80vh] overflow-y-auto" id="activity-feed">
              <div :for={entry <- @activities} class="flex items-start gap-2 text-sm py-1">
                <span class="text-gray-600 text-xs shrink-0 mt-0.5">{entry.at}</span>
                <span class={activity_icon_class(entry.kind)}>{activity_icon(entry.kind)}</span>
                <span class="text-cortex-400 font-medium shrink-0">{entry.team}:</span>
                <span class="text-gray-300">{entry.text}</span>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <!-- ============ Messages Tab ============ -->
      <div :if={@current_tab == "messages"}>
        <%= if @run.workspace_path do %>
          <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <!-- Message History (2/3 width) -->
            <div class="lg:col-span-2 space-y-4">
              <!-- Team Selector -->
              <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
                <div class="flex items-center gap-3">
                  <label class="text-sm text-gray-400 shrink-0">Team:</label>
                  <form phx-change="select_messages_team" class="flex-1">
                    <select
                      name="team"
                      class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                    >
                      <option value="">Select team...</option>
                      <option :for={name <- @team_names} value={name} selected={name == @messages_team}>
                        {name}
                      </option>
                    </select>
                  </form>
                  <button
                    :if={@messages_team}
                    phx-click="refresh_messages"
                    class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
                  >
                    Refresh
                  </button>
                </div>
              </div>

              <!-- Inbox -->
              <div :if={@messages_team} class="bg-gray-900 rounded-lg border border-gray-800 p-4">
                <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">
                  Inbox ({length(@team_inbox)} messages to {@messages_team})
                </h3>
                <%= if @team_inbox == [] do %>
                  <p class="text-gray-500 text-sm">No messages received.</p>
                <% else %>
                  <div class="space-y-2 max-h-[40vh] overflow-y-auto">
                    <div :for={msg <- @team_inbox} class="bg-gray-950 rounded p-3 text-sm">
                      <div class="flex items-center justify-between mb-1">
                        <span class="text-cortex-400 font-medium">from: {Map.get(msg, "from", "?")}</span>
                        <span class="text-gray-600 text-xs">{Map.get(msg, "timestamp", "")}</span>
                      </div>
                      <p class="text-gray-300">{Map.get(msg, "content", "")}</p>
                    </div>
                  </div>
                <% end %>
              </div>

              <!-- Outbox -->
              <div :if={@messages_team} class="bg-gray-900 rounded-lg border border-gray-800 p-4">
                <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">
                  Outbox ({length(@team_outbox)} messages from {@messages_team})
                </h3>
                <%= if @team_outbox == [] do %>
                  <p class="text-gray-500 text-sm">No messages sent.</p>
                <% else %>
                  <div class="space-y-2 max-h-[40vh] overflow-y-auto">
                    <div :for={msg <- @team_outbox} class="bg-gray-950 rounded p-3 text-sm">
                      <div class="flex items-center justify-between mb-1">
                        <span class="text-green-400 font-medium">to: {Map.get(msg, "to", "?")}</span>
                        <span class="text-gray-600 text-xs">{Map.get(msg, "timestamp", "")}</span>
                      </div>
                      <p class="text-gray-300">{Map.get(msg, "content", "")}</p>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <!-- Send Message (1/3 width) -->
            <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 h-fit">
              <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Send Message</h2>
              <form phx-submit="send_message" phx-change="form_update" class="space-y-3">
                <div>
                  <label class="text-xs text-gray-500 block mb-1">To</label>
                  <select
                    name="to"
                    class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                  >
                    <option value="">Select team...</option>
                    <option :for={name <- @team_names} value={name} selected={name == @msg_to}>
                      {name}
                    </option>
                  </select>
                </div>
                <div>
                  <label class="text-xs text-gray-500 block mb-1">Message</label>
                  <textarea
                    name="content"
                    rows="4"
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
            </div>
          </div>
        <% else %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
            <p class="text-gray-500">No workspace path available. Messages require a workspace with .cortex/ directory.</p>
          </div>
        <% end %>
      </div>

      <!-- ============ Logs Tab ============ -->
      <div :if={@current_tab == "logs"}>
        <%= if @run.workspace_path do %>
          <!-- Team Selector + Refresh -->
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
            <div class="flex items-center gap-3">
              <label class="text-sm text-gray-400 shrink-0">Team:</label>
              <form phx-change="select_log_team" class="flex-1">
                <select
                  name="team"
                  class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                >
                  <option value="">Select team...</option>
                  <option value="__all__" selected={@selected_log_team == "__all__"}>All teams</option>
                  <option :for={name <- @team_names} value={name} selected={name == @selected_log_team}>
                    {name}
                  </option>
                </select>
              </form>
              <button
                :if={@selected_log_team}
                phx-click="toggle_log_sort"
                class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
              >
                {if @log_sort == :desc, do: "Newest first ↓", else: "Oldest first ↑"}
              </button>
              <button
                :if={@selected_log_team}
                phx-click="refresh_logs"
                class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
              >
                Refresh
              </button>
            </div>
          </div>

          <!-- Log Content -->
          <%= if @selected_log_team do %>
            <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
              <div class="flex items-center justify-between mb-3">
                <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">
                  {if @selected_log_team == "__all__", do: "All teams", else: "#{@selected_log_team}.log"}
                </h2>
                <span :if={@log_lines} class="text-xs text-gray-600">
                  {length(@log_lines)} lines (last 500)
                </span>
              </div>
              <%= if @log_lines do %>
                <div class="max-h-[75vh] overflow-y-auto rounded bg-gray-950 divide-y divide-gray-800/50">
                  <%= for line <- @log_lines do %>
                    <% expanded = MapSet.member?(@expanded_logs, line.num) %>
                    <div
                      phx-click="toggle_log_line"
                      phx-value-line={line.num}
                      class={["px-3 py-2 cursor-pointer transition-colors",
                        if(expanded, do: "bg-gray-800/40", else:
                          if(rem(line.num, 2) == 0, do: "bg-gray-950 hover:bg-gray-900/50", else: "bg-gray-900/30 hover:bg-gray-900/60")
                        )
                      ]}
                    >
                      <!-- Collapsed: single line -->
                      <div class="flex items-start gap-3">
                        <span class="text-gray-600 font-mono text-xs select-none shrink-0 w-8 text-right pt-0.5">
                          {line.num}
                        </span>
                        <span class={["shrink-0 pt-0.5", if(expanded, do: "text-cortex-400", else: "text-gray-600")]}>
                          {if expanded, do: "v", else: ">"}
                        </span>
                        <span
                          :if={line[:team]}
                          class="shrink-0 rounded px-1.5 py-0.5 text-xs font-medium bg-cortex-900/40 text-cortex-300"
                        >
                          {line.team}
                        </span>
                        <span
                          :if={line.type}
                          class={["shrink-0 rounded px-1.5 py-0.5 text-xs font-medium", log_type_class(line.type)]}
                        >
                          {line.type}
                        </span>
                        <%= if expanded do %>
                          <code class="text-gray-400 text-xs font-mono flex-1 pt-0.5 truncate">
                            {line.raw}
                          </code>
                        <% else %>
                          <code class="text-gray-400 text-xs font-mono overflow-x-auto whitespace-nowrap block flex-1 pt-0.5">
                            {line.raw}
                          </code>
                        <% end %>
                      </div>
                      <!-- Expanded: parsed JSON fields -->
                      <div :if={expanded && line.parsed} class="mt-2 ml-14 space-y-1 border-l-2 border-gray-700 pl-3">
                        <div :for={{key, val} <- line.parsed} class="flex items-start gap-2 text-xs font-mono">
                          <span class="text-cortex-400 shrink-0">{key}:</span>
                          <span class="text-gray-300 whitespace-pre-wrap break-all">{format_json_value(val)}</span>
                        </div>
                      </div>
                      <div :if={expanded && !line.parsed} class="mt-2 ml-14 border-l-2 border-gray-700 pl-3">
                        <pre class="text-gray-400 text-xs font-mono whitespace-pre-wrap break-all">{line.raw}</pre>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <p class="text-gray-500 text-sm">No log file found for this team.</p>
              <% end %>
            </div>
          <% else %>
            <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
              <p class="text-gray-500 text-sm">Select a team to view its log.</p>
            </div>
          <% end %>
        <% else %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
            <p class="text-gray-500">No workspace path available. Logs require a workspace with .cortex/logs/ directory.</p>
          </div>
        <% end %>
      </div>

      <!-- ============ Diagnostics Tab ============ -->
      <div :if={@current_tab == "diagnostics"}>
        <%= if @run.workspace_path do %>
          <!-- Team Selector + Refresh -->
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
            <div class="flex items-center gap-3">
              <label class="text-sm text-gray-400 shrink-0">Team:</label>
              <form phx-change="select_diag_team" class="flex-1">
                <select
                  name="team"
                  class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                >
                  <option value="">Select team...</option>
                  <option :for={name <- @team_names} value={name} selected={name == @diagnostics_team}>
                    {name}
                  </option>
                </select>
              </form>
              <button
                :if={@diagnostics_team}
                phx-click="refresh_diagnostics"
                class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
              >
                Refresh
              </button>
            </div>
          </div>

          <%= if @diagnostics_team && @diagnostics_report do %>
            <% report = @diagnostics_report %>
            <!-- Diagnosis Banner -->
            <div class={[
              "rounded-lg border p-4 mb-4",
              diag_banner_class(report.diagnosis)
            ]}>
              <div class="flex items-center gap-3">
                <span class="text-lg">{diag_icon(report.diagnosis)}</span>
                <div>
                  <p class="font-medium">{diag_title(report.diagnosis)}</p>
                  <p class="text-sm opacity-80">{report.diagnosis_detail}</p>
                </div>
              </div>
              <div class="flex items-center gap-4 mt-3 text-sm opacity-70 flex-wrap">
                <span :if={report.session_id}>Session: <code class="font-mono">{report.session_id}</code></span>
                <span :if={report.model}>Model: {report.model}</span>
                <span :if={report.cost_usd}>Cost: ${Float.round(report.cost_usd * 1.0, 4)}</span>
                <span :if={report.total_input_tokens > 0 or report.total_output_tokens > 0}>
                  Tokens: {format_token_count(report.total_input_tokens)} in / {format_token_count(report.total_output_tokens)} out
                </span>
                <span>{report.line_count} log lines</span>
              </div>
            </div>

            <!-- Resume / Restart buttons for this specific team -->
            <div
              :if={report.session_id && report.diagnosis not in [:completed]}
              class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4"
            >
              <div class="flex items-center justify-between">
                <div>
                  <p class="text-sm text-gray-300">
                    Session <code class="font-mono text-cortex-400">{report.session_id}</code>
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    :if={not report.has_result}
                    phx-click="resume_single_team"
                    phx-value-team={@diagnostics_team}
                    class="rounded bg-cortex-600 px-4 py-2 text-sm font-medium text-white hover:bg-cortex-500 shrink-0"
                  >
                    Resume
                  </button>
                  <button
                    phx-click="restart_team"
                    phx-value-team={@diagnostics_team}
                    class="rounded bg-yellow-600 px-4 py-2 text-sm font-medium text-white hover:bg-yellow-500 shrink-0"
                    title="Start fresh session with context from previous run"
                  >
                    Restart
                  </button>
                </div>
              </div>
            </div>

            <!-- Result Summary (if exists) -->
            <div :if={report.result_text} class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
              <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-2">Result</h3>
              <pre class="text-gray-300 text-sm whitespace-pre-wrap">{report.result_text}</pre>
            </div>

            <!-- Timeline -->
            <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Event Timeline</h3>
                <span class="text-xs text-gray-600">{length(report.entries)} events</span>
              </div>
              <%= if report.entries == [] do %>
                <p class="text-gray-500 text-sm">No events found in log.</p>
              <% else %>
                <div class="space-y-0.5 max-h-[70vh] overflow-y-auto">
                  <div
                    :for={entry <- report.entries}
                    class="flex items-start gap-2 text-sm py-1.5 px-2 rounded hover:bg-gray-800/50"
                  >
                    <span class={[
                      "shrink-0 rounded px-1.5 py-0.5 text-xs font-medium w-20 text-center",
                      diag_entry_class(entry.type)
                    ]}>
                      {diag_entry_label(entry.type)}
                    </span>
                    <span :if={entry.tools != []} class="text-cortex-400 font-medium shrink-0">
                      {Enum.join(entry.tools, ", ")}
                    </span>
                    <span class="text-gray-300 break-all">{entry.detail}</span>
                    <span :if={entry.timestamp} class="text-gray-600 text-xs shrink-0 ml-auto">
                      {format_iso_time(entry.timestamp)}
                    </span>
                  </div>

                  <!-- End-of-log marker for incomplete sessions -->
                  <%= if not report.has_result do %>
                    <%= if report.diagnosis == :in_progress do %>
                      <div class="flex items-start gap-2 text-sm py-2 px-2 mt-2 rounded bg-blue-950/30 border border-blue-900/50">
                        <span class="shrink-0 rounded px-1.5 py-0.5 text-xs font-medium w-20 text-center bg-blue-900/60 text-blue-300">
                          LIVE
                        </span>
                        <span class="text-blue-300">
                          Process is still running — log continues to grow.
                        </span>
                      </div>
                    <% else %>
                      <div class="flex items-start gap-2 text-sm py-2 px-2 mt-2 rounded bg-red-950/30 border border-red-900/50">
                        <span class="shrink-0 rounded px-1.5 py-0.5 text-xs font-medium w-20 text-center bg-red-900/60 text-red-300">
                          END
                        </span>
                        <span class="text-red-300">
                          Log ends here — no result line received. Process died or was killed.
                        </span>
                      </div>
                    <% end %>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
              <p class="text-gray-500 text-sm">Select a team to view diagnostics.</p>
            </div>
          <% end %>
        <% else %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
            <p class="text-gray-500">No workspace path available. Diagnostics require a workspace with .cortex/logs/ directory.</p>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  # -- Private helpers --

  # Extracted from handle_event("restart_team") to reduce cyclomatic complexity
  defp do_restart_team(socket, run, team_name, team_run, workspace_path) do
    log_path = Path.join([workspace_path, ".cortex", "logs", "#{team_name}.log"])

    restart_context =
      case LogParser.parse(log_path) do
        {:ok, report} -> LogParser.build_restart_context(report)
        _ -> ""
      end

    enriched_prompt = team_run.prompt <> "\n\n" <> restart_context

    # Mark as running in DB (synchronous — before Task.start)
    mark_team_run_running(team_run.id, enriched_prompt)

    team_runs = safe_get_team_runs(run.id)

    entry = %{
      team: "system",
      text: "Restarting #{team_name} with fresh session (previous session expired)...",
      kind: :resume,
      at: format_now()
    }

    socket =
      socket
      |> assign(team_runs: team_runs)
      |> assign(activities: prepend_activity(socket.assigns.activities, entry))

    spawn_restart_task(run.id, team_run.id, team_name, enriched_prompt, log_path, workspace_path)

    {:noreply, put_flash(socket, :info, "Restarting #{team_name} with fresh session...")}
  end

  defp mark_team_run_running(team_run_id, prompt) do
    safe_store_call(fn ->
      case Cortex.Repo.get(Cortex.Store.Schemas.TeamRun, team_run_id) do
        nil -> :ok
        tr ->
          Cortex.Store.update_team_run(tr, %{
            status: "running",
            prompt: prompt,
            started_at: DateTime.utc_now(),
            completed_at: nil,
            result_summary: nil,
            session_id: nil
          })
      end
    end)
  end

  defp spawn_restart_task(run_id, team_run_id, team_name, prompt, log_path, workspace_path) do
    Task.start(fn ->
      result =
        Spawner.spawn(
          team_name: team_name,
          prompt: prompt,
          model: "sonnet",
          max_turns: 200,
          permission_mode: "bypassPermissions",
          timeout_minutes: 45,
          log_path: log_path,
          command: "claude",
          cwd: workspace_path
        )

      persist_spawn_result(team_run_id, result)
      broadcast_spawn_result(run_id, team_name, result)
    end)
  end

  defp persist_spawn_result(team_run_id, result) do
    safe_store_call(fn ->
      case Cortex.Repo.get(Cortex.Store.Schemas.TeamRun, team_run_id) do
        nil -> :ok
        tr -> Cortex.Store.update_team_run(tr, spawn_result_to_attrs(result))
      end
    end)
  end

  defp spawn_result_to_attrs({:ok, %{status: :success} = r}) do
    %{
      status: "completed",
      session_id: r.session_id,
      cost_usd: r.cost_usd,
      input_tokens: r.input_tokens,
      output_tokens: r.output_tokens,
      cache_read_tokens: r.cache_read_tokens,
      cache_creation_tokens: r.cache_creation_tokens,
      duration_ms: r.duration_ms,
      num_turns: r.num_turns,
      result_summary: truncate_for_store(r.result),
      completed_at: DateTime.utc_now()
    }
  end

  defp spawn_result_to_attrs({:ok, r}) do
    %{
      status: "failed",
      session_id: r.session_id,
      cost_usd: r.cost_usd,
      input_tokens: r.input_tokens,
      output_tokens: r.output_tokens,
      duration_ms: r.duration_ms,
      result_summary: truncate_for_store(r.result),
      completed_at: DateTime.utc_now()
    }
  end

  defp spawn_result_to_attrs({:error, reason}) do
    %{
      status: "failed",
      result_summary: "Restart error: #{inspect(reason)}",
      completed_at: DateTime.utc_now()
    }
  end

  defp broadcast_spawn_result(run_id, team_name, result) do
    {status, reason} =
      case result do
        {:ok, %{status: :success}} -> {:success, "restarted and completed successfully"}
        {:ok, %{status: :rate_limited}} -> {:rate_limited, "hit rate limit (429)"}
        {:ok, %{status: s}} -> {:failure, "finished with status: #{s}"}
        {:error, reason} -> {:failure, inspect(reason)}
      end

    Cortex.Events.broadcast(:team_resume_result, %{
      run_id: run_id,
      team_name: team_name,
      status: status,
      reason: reason
    })

    Cortex.Events.broadcast(:run_resumed, %{run_id: run_id})
  end

  defp spawn_continue_run_task(run_id) do
    Task.start(fn ->
      {status, reason} =
        case Runner.continue_run(run_id) do
          {:ok, _summary} -> {:success, "run continued successfully"}
          {:error, reason} -> {:failure, "continue failed: #{inspect(reason)}"}
        end

      Cortex.Events.broadcast(:team_resume_result, %{
        run_id: run_id,
        team_name: "system",
        status: status,
        reason: reason
      })

      Cortex.Events.broadcast(:run_resumed, %{run_id: run_id})
    end)
  end

  defp spawn_resume_all_task(run_id, workspace_path) do
    Task.start(fn -> do_resume_all(run_id, workspace_path) end)
  end

  defp do_resume_all(run_id, workspace_path) do
    case Runner.resume_run(workspace_path) do
      {:ok, results} ->
        Enum.each(results, fn {team_name, result} ->
          {status, reason} = classify_resume_result(result)

          Cortex.Events.broadcast(:team_resume_result, %{
            run_id: run_id,
            team_name: team_name,
            status: status,
            reason: reason
          })
        end)

        Cortex.Events.broadcast(:run_resumed, %{run_id: run_id})

      {:error, reason} ->
        Cortex.Events.broadcast(:team_resume_result, %{
          run_id: run_id,
          team_name: "system",
          status: :failure,
          reason: inspect(reason)
        })
    end
  end

  defp spawn_resume_single_task(run_id, team_name, workspace_path) do
    Task.start(fn ->
      log_path = Path.join([workspace_path, ".cortex", "logs", "#{team_name}.log"])

      {status, reason} = attempt_session_resume(team_name, log_path, workspace_path)

      Cortex.Events.broadcast(:team_resume_result, %{
        run_id: run_id,
        team_name: team_name,
        status: status,
        reason: reason
      })

      Cortex.Events.broadcast(:run_resumed, %{run_id: run_id})
    end)
  end

  defp attempt_session_resume(team_name, log_path, workspace_path) do
    case Spawner.extract_session_id_from_log(log_path) do
      {:ok, session_id} ->
        case Spawner.resume(
               team_name: team_name,
               session_id: session_id,
               timeout_minutes: 30,
               log_path: log_path,
               command: "claude",
               cwd: workspace_path
             ) do
          {:ok, %{status: :success}} -> {:success, "session resumed successfully"}
          {:ok, %{status: :rate_limited}} -> {:rate_limited, "hit rate limit (429)"}
          {:error, reason} -> {:failure, inspect(reason)}
        end

      :error ->
        {:no_session_id, "no session_id found in logs"}
    end
  end

  # Extracted from handle_event("start_coordinator") to reduce cyclomatic complexity
  defp do_start_coordinator(socket, run, config, tiers) do
    workspace_path = run.workspace_path
    cortex_path = Path.join(workspace_path, ".cortex")
    run_id = run.id

    InboxBridge.setup(workspace_path, ["coordinator"])

    prompt = Injection.build_coordinator_prompt(config, tiers, cortex_path)
    log_path = Path.join([cortex_path, "logs", "coordinator.log"])

    callbacks = build_coordinator_callbacks(run_id, cortex_path)

    safe_store_call(fn ->
      Cortex.Store.create_team_run(%{
        run_id: run_id,
        team_name: "coordinator",
        role: "Runtime Coordinator",
        tier: -1,
        status: "running",
        prompt: prompt,
        log_path: log_path,
        started_at: DateTime.utc_now()
      })
    end)

    spawn_coordinator_task(run_id, prompt, log_path, workspace_path, callbacks)

    entry = %{
      team: "system",
      text: "Starting coordinator agent...",
      kind: :resume,
      at: format_now()
    }

    {:noreply,
     socket
     |> assign(activities: prepend_activity(socket.assigns.activities, entry))
     |> put_flash(:info, "Coordinator agent started")}
  end

  defp build_coordinator_callbacks(run_id, cortex_path) do
    on_activity = fn name, activity ->
      Cortex.Events.broadcast(:team_activity, %{
        run_id: run_id,
        team_name: name,
        type: activity.type,
        tools: Map.get(activity, :tools, []),
        details: Map.get(activity, :details, []),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end

    on_token_update = fn name, tokens ->
      Cortex.Events.broadcast(:team_tokens_updated, %{
        run_id: run_id,
        team_name: name,
        input_tokens: tokens.input_tokens,
        output_tokens: tokens.output_tokens,
        cache_read_tokens: tokens.cache_read_tokens,
        cache_creation_tokens: tokens.cache_creation_tokens
      })
    end

    workspace = %Cortex.Orchestration.Workspace{path: cortex_path}

    on_port_opened = fn _name, os_pid ->
      if os_pid do
        Workspace.update_registry_entry(workspace, "coordinator",
          pid: os_pid,
          status: "running",
          started_at: DateTime.utc_now() |> DateTime.to_iso8601()
        )
      end
    end

    %{on_activity: on_activity, on_token_update: on_token_update, on_port_opened: on_port_opened}
  end

  defp spawn_coordinator_task(run_id, prompt, log_path, workspace_path, callbacks) do
    Task.start(fn ->
      result =
        Spawner.spawn(
          team_name: "coordinator",
          prompt: prompt,
          model: "haiku",
          max_turns: 500,
          permission_mode: "bypassPermissions",
          timeout_minutes: 120,
          log_path: log_path,
          command: "claude",
          cwd: workspace_path,
          on_activity: callbacks.on_activity,
          on_token_update: callbacks.on_token_update,
          on_port_opened: callbacks.on_port_opened
        )

      persist_coordinator_result(run_id, result)
    end)
  end

  defp persist_coordinator_result(run_id, result) do
    attrs = coordinator_result_to_attrs(result)

    safe_store_call(fn ->
      with team_runs when is_list(team_runs) <- Cortex.Store.get_team_runs(run_id),
           %{} = tr <- Enum.find(team_runs, &(&1.team_name == "coordinator")) do
        Cortex.Store.update_team_run(tr, attrs)
      end
    end)
  end

  defp coordinator_result_to_attrs({:ok, r}) do
    %{
      status: if(r.status == :success, do: "completed", else: "failed"),
      session_id: r.session_id,
      cost_usd: r.cost_usd,
      input_tokens: r.input_tokens,
      output_tokens: r.output_tokens,
      completed_at: DateTime.utc_now()
    }
  end

  defp coordinator_result_to_attrs({:error, _}) do
    %{status: "failed", completed_at: DateTime.utc_now()}
  end

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
    case ConfigLoader.load_string(yaml_string) do
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
        {:ok, raw} -> parse_team_roles(Map.get(raw, "teams", []))
        _ -> %{}
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp parse_team_roles(teams) do
    Map.new(teams, fn team ->
      name = Map.get(team, "name", "")
      members = Map.get(team, "members", []) || []
      roles = Enum.map(members, fn m -> Map.get(m, "role", "") end)
      {name, roles}
    end)
  end

  # -- Tab helpers --

  defp tab_label("overview", _assigns), do: "Overview"

  defp tab_label("activity", assigns) do
    count = length(assigns.activities)
    if count > 0, do: "Activity (#{count})", else: "Activity"
  end

  defp tab_label("messages", _assigns), do: "Messages"
  defp tab_label("logs", _assigns), do: "Logs"
  defp tab_label("diagnostics", _assigns), do: "Diagnostics"
  defp tab_label(tab, _assigns), do: String.capitalize(tab)

  # -- Stalled detection (Priority 3) --

  defp has_stalled_teams?(team_runs, run_status, last_seen, pid_status) do
    run_status in ["running", "failed"] and
      Enum.any?(team_runs, fn tr -> team_stalled?(tr, last_seen, pid_status) end)
  end

  defp team_stalled?(team_run, last_seen, pid_status) do
    (team_run.status || "pending") == "running" and
      not pid_alive?(team_run.team_name, pid_status) and
      case Map.get(last_seen, team_run.team_name) do
        nil ->
          # No events received this session — fall back to started_at
          case team_run.started_at do
            nil -> true
            ts -> DateTime.diff(DateTime.utc_now(), ts, :second) > @stale_threshold_seconds
          end

        ts ->
          DateTime.diff(DateTime.utc_now(), ts, :second) > @stale_threshold_seconds
      end
  end

  # If we have a PID check result and it says alive, team is not stalled
  defp pid_alive?(team_name, pid_status) do
    Map.get(pid_status, team_name, false)
  end

  defp display_status(team, last_seen, pid_status \\ %{}) do
    raw = team.status || "pending"

    if raw == "running" and team_stalled?(team, last_seen, pid_status) do
      "stalled"
    else
      raw
    end
  end

  defp count_stalled(team_runs, last_seen, pid_status) do
    Enum.count(team_runs, fn tr -> team_stalled?(tr, last_seen, pid_status) end)
  end

  defp count_active_running(team_runs, last_seen, pid_status) do
    Enum.count(team_runs, fn tr ->
      (tr.status || "pending") == "running" and not team_stalled?(tr, last_seen, pid_status)
    end)
  end

  defp stalled_team_names(team_runs, last_seen, pid_status) do
    team_runs
    |> Enum.filter(fn tr -> team_stalled?(tr, last_seen, pid_status) end)
    |> Enum.map(& &1.team_name)
    |> Enum.sort()
  end

  # -- Pending/continue detection --

  defp incomplete_team_names(run, team_runs) do
    # Teams that are pending in DB
    pending =
      team_runs
      |> Enum.filter(fn tr -> (tr.status || "pending") == "pending" end)
      |> Enum.map(& &1.team_name)

    # Teams in config_yaml that have no team_run record at all (runner died before creating them)
    missing = missing_team_names(run, team_runs)

    (pending ++ missing) |> Enum.sort() |> Enum.uniq()
  end

  defp missing_team_names(run, team_runs) do
    with yaml when is_binary(yaml) <- run.config_yaml,
         {:ok, raw} <- YamlElixir.read_from_string(yaml) do
      config_names = raw |> Map.get("teams", []) |> MapSet.new(&Map.get(&1, "name", ""))
      existing_names = MapSet.new(team_runs, & &1.team_name)
      completed = team_runs |> Enum.filter(&(&1.status in ["completed", "done"])) |> MapSet.new(& &1.team_name)

      config_names |> MapSet.difference(existing_names) |> MapSet.difference(completed) |> MapSet.to_list()
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # -- Resume result classification (Priority 2) --

  defp classify_resume_result({:ok, %{status: :success}}),
    do: {:success, "session resumed successfully"}

  defp classify_resume_result({:ok, %{status: :rate_limited}}),
    do: {:rate_limited, "hit rate limit (429)"}

  defp classify_resume_result({:error, :no_session_id}),
    do: {:no_session_id, "no session_id found in registry or logs"}

  defp classify_resume_result({:error, :rate_limited}),
    do: {:rate_limited, "hit rate limit (429)"}

  defp classify_resume_result({:error, reason}),
    do: {:failure, inspect(reason)}

  defp classify_resume_result(_),
    do: {:failure, "unknown result"}

  # -- Log/message reading --

  defp read_team_log(run, team_name) do
    if run && run.workspace_path do
      log_path = Path.join([run.workspace_path, ".cortex", "logs", "#{team_name}.log"])
      parse_log_file(log_path)
    end
  end

  defp parse_log_file(log_path) do
    case File.read(log_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(-@max_log_lines)
        |> Enum.with_index(1)
        |> Enum.map(&build_log_entry/1)

      {:error, _} ->
        nil
    end
  end

  defp build_log_entry({line, idx}) do
    {type, parsed} = parse_log_line(line)
    %{raw: line, type: type, parsed: parsed, num: idx}
  end

  defp read_all_team_logs(run, team_names) do
    if run && run.workspace_path do
      team_names
      |> Enum.flat_map(&read_team_log_with_name(run, &1))
      |> Enum.sort_by(&extract_timestamp/1)
      |> Enum.take(-@max_log_lines)
      |> Enum.with_index(1)
      |> Enum.map(fn {line, idx} -> %{line | num: idx} end)
    end
  end

  defp read_team_log_with_name(run, name) do
    case read_team_log(run, name) do
      nil -> []
      lines -> Enum.map(lines, &Map.put(&1, :team, name))
    end
  end

  defp extract_timestamp(%{parsed: %{"timestamp" => ts}}) when is_binary(ts), do: ts
  defp extract_timestamp(%{parsed: %{"message" => %{"created" => ts}}}), do: ts
  defp extract_timestamp(_), do: ""

  defp parse_log_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = parsed} -> {type, parsed}
      {:ok, parsed} when is_map(parsed) -> {nil, parsed}
      _ -> {nil, nil}
    end
  end

  defp format_json_value(val) when is_binary(val) do
    if String.length(val) > 500 do
      String.slice(val, 0, 500) <> "..."
    else
      val
    end
  end

  defp format_json_value(val) when is_map(val) or is_list(val) do
    Jason.encode!(val, pretty: true)
  end

  defp format_json_value(val), do: inspect(val)

  defp sort_log_lines(nil, _sort), do: nil

  defp sort_log_lines(lines, :desc), do: Enum.sort_by(lines, & &1.num, :desc)
  defp sort_log_lines(lines, :asc), do: Enum.sort_by(lines, & &1.num, :asc)

  defp log_type_class("assistant"), do: "bg-blue-900/50 text-blue-300"
  defp log_type_class("system"), do: "bg-purple-900/50 text-purple-300"
  defp log_type_class("result"), do: "bg-cyan-900/50 text-cyan-300"
  defp log_type_class("error"), do: "bg-red-900/50 text-red-300"
  defp log_type_class("tool_use"), do: "bg-green-900/50 text-green-300"
  defp log_type_class("tool_result"), do: "bg-emerald-900/50 text-emerald-300"
  defp log_type_class(_), do: "bg-gray-800/50 text-gray-400"

  defp read_team_messages(run, team_name) do
    if run && run.workspace_path do
      inbox =
        case InboxBridge.read_inbox(run.workspace_path, team_name) do
          {:ok, messages} -> messages
          _ -> []
        end

      outbox =
        case InboxBridge.read_outbox(run.workspace_path, team_name) do
          {:ok, messages} -> messages
          _ -> []
        end

      {inbox, outbox}
    else
      {[], []}
    end
  end

  # -- General helpers --

  defp run_title(run), do: run.name || "Untitled Run"

  defp count_by_status(team_runs, statuses) when is_list(statuses) do
    Enum.count(team_runs, fn tr -> (tr.status || "pending") in statuses end)
  end

  defp count_by_status(team_runs, status) do
    Enum.count(team_runs, fn tr -> (tr.status || "pending") == status end)
  end

  defp sum_team_field(team_runs, field) do
    team_runs |> Enum.map(&(Map.get(&1, field) || 0)) |> Enum.sum()
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

  # Format tool activity text: "Read config.exs" or "Bash: mix test" instead of "using Read"
  defp format_tool_activity([], _details), do: ""

  defp format_tool_activity(tools, details) do
    tools
    |> Enum.zip(details ++ List.duplicate(nil, max(0, length(tools) - length(details))))
    |> Enum.map_join(", ", fn
      {tool, nil} -> tool
      {tool, detail} -> "#{tool}: #{detail}"
    end)
  end

  defp activity_icon(:tool), do: ">"
  defp activity_icon(:progress), do: "*"
  defp activity_icon(:message), do: "@"
  defp activity_icon(:resume), do: "!"
  defp activity_icon(_), do: "-"

  defp activity_icon_class(:tool), do: "text-blue-400 font-mono"
  defp activity_icon_class(:progress), do: "text-green-400 font-mono"
  defp activity_icon_class(:message), do: "text-yellow-400 font-mono"
  defp activity_icon_class(:resume), do: "text-purple-400 font-mono"
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

  # -- Run summary --

  defp build_run_summary(run, team_runs, last_seen, opts) do
    include_diagnostics = Keyword.get(opts, :include_diagnostics, true)

    wall_clock =
      if run.started_at do
        DateTime.diff(DateTime.utc_now(), run.started_at, :second)
        |> format_duration_seconds()
      else
        "--"
      end

    total_input = sum_team_tokens(team_runs, :input_tokens)
    total_output = sum_team_tokens(team_runs, :output_tokens)
    total_cost = team_runs |> Enum.map(&(&1.cost_usd || 0.0)) |> Enum.sum()

    team_lines =
      team_runs
      |> Enum.sort_by(&{&1.tier || 0, &1.team_name})
      |> Enum.map(&format_team_summary_line(&1, run, last_seen, include_diagnostics))

    [
      "=== #{run.name || "Untitled"} ===",
      "Status: #{run.status} | Wall clock: #{wall_clock}",
      "Tokens: #{format_token_count(total_input)} in / #{format_token_count(total_output)} out | Cost: $#{Float.round(total_cost * 1.0, 4)}",
      "",
      "Teams:" | team_lines
    ]
    |> Enum.join("\n")
  end

  defp sum_team_tokens(team_runs, field) do
    team_runs |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1) |> Enum.sum()
  end

  defp format_team_summary_line(tr, run, last_seen, include_diagnostics) do
    status = display_status(tr, last_seen)
    health = if status == "running", do: " (#{health_indicator_text(tr, last_seen)})", else: ""

    tokens = format_team_token_summary(tr)
    cost = format_team_cost(tr)
    diag = format_team_diag_summary(tr, run, status, include_diagnostics)
    result = format_team_result_snippet(tr)

    "  [T#{tr.tier || 0}] #{tr.team_name}: #{status}#{health}#{tokens}#{cost}#{diag}#{result}"
  end

  defp format_team_token_summary(tr) do
    if tr.input_tokens || tr.output_tokens do
      " | #{format_token_count(tr.input_tokens || 0)} in / #{format_token_count(tr.output_tokens || 0)} out"
    else
      ""
    end
  end

  defp format_team_cost(tr) do
    if tr.cost_usd && tr.cost_usd > 0,
      do: " | $#{Float.round(tr.cost_usd * 1.0, 4)}",
      else: ""
  end

  defp format_team_diag_summary(tr, run, status, include_diagnostics) do
    if include_diagnostics and status in ["running", "stalled"] and run.workspace_path do
      case load_diagnostics(run, tr.team_name, team_status: tr.status || "pending") do
        nil -> ""
        report -> " | #{report.diagnosis_detail}"
      end
    else
      ""
    end
  end

  defp format_team_result_snippet(tr) do
    if tr.result_summary do
      snippet = tr.result_summary |> String.split("\n") |> hd() |> String.slice(0, 80)
      "\n    Result: #{snippet}"
    else
      ""
    end
  end

  defp format_duration_seconds(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
    end
  end

  # -- Diagnostics helpers --

  defp load_diagnostics(run, team_name, opts) do
    if run && run.workspace_path do
      log_path = Path.join([run.workspace_path, ".cortex", "logs", "#{team_name}.log"])

      case LogParser.parse(log_path) do
        {:ok, report} ->
          team_status = Keyword.get(opts, :team_status)
          maybe_override_diagnosis(report, team_status)

        {:error, _} ->
          nil
      end
    end
  end

  # When a team is still running, death-like diagnoses are just log snapshots, not actual failures
  @death_diagnoses [
    :died_after_tool_result,
    :died_during_tool,
    :log_ends_without_result,
    :no_session,
    :empty_log
  ]

  defp maybe_override_diagnosis(report, "running") when report.diagnosis in @death_diagnoses do
    %{
      report
      | diagnosis: :in_progress,
        diagnosis_detail: "Still running — log is a live snapshot"
    }
  end

  defp maybe_override_diagnosis(report, _status), do: report

  defp get_team_status(team_runs, team_name) do
    case Enum.find(team_runs, fn tr -> tr.team_name == team_name end) do
      nil -> "pending"
      tr -> tr.status || "pending"
    end
  end

  # Check all team PIDs from registry.json, returns %{team_name => true/false}
  defp handle_reconcile_result(socket, run, {:ok, changes}) when changes != [] do
    entries =
      Enum.map(changes, fn change ->
        %{team: change.team, text: "#{change.from} -> #{change.to}: #{change.detail}",
          kind: :resume, at: format_now()}
      end)

    activities = Enum.reduce(entries, socket.assigns.activities, &prepend_activity(&2, &1))

    done_entry = %{
      team: "system",
      text: "Reconciled #{length(changes)} team(s)",
      kind: :resume,
      at: format_now()
    }

    team_runs = safe_get_team_runs(run.id)
    fresh_run = safe_get_run(run.id)
    {tiers, edges} = build_dag(fresh_run || run, team_runs)

    {:noreply,
     assign(socket,
       activities: prepend_activity(activities, done_entry),
       team_runs: team_runs,
       run: fresh_run || run,
       tiers: tiers,
       edges: edges
     )}
  end

  defp handle_reconcile_result(socket, _run, {:ok, []}) do
    no_change = %{
      team: "system",
      text: "No changes — no completed sessions found in logs",
      kind: :resume,
      at: format_now()
    }

    {:noreply, assign(socket, activities: prepend_activity(socket.assigns.activities, no_change))}
  end

  defp handle_reconcile_result(socket, _run, {:error, reason}) do
    err_entry = %{
      team: "system",
      text: "Reconcile failed: #{inspect(reason)}",
      kind: :resume,
      at: format_now()
    }

    {:noreply, assign(socket, activities: prepend_activity(socket.assigns.activities, err_entry))}
  end

  defp update_team_tokens(team_runs, team_name, payload) do
    Enum.map(team_runs, fn tr ->
      if tr.team_name == team_name do
        %{tr | input_tokens: payload.input_tokens, output_tokens: payload.output_tokens}
      else
        tr
      end
    end)
  end

  defp maybe_start_pid_check(run, socket) do
    if run.status in ["running", "failed"] and connected?(socket) do
      send(self(), :check_pids)
    end
  end

  defp check_all_team_pids(workspace_path) do
    case read_registry_teams(workspace_path) do
      {:ok, teams} ->
        Map.new(teams, fn team ->
          {Map.get(team, "name", ""), os_pid_alive?(Map.get(team, "pid"))}
        end)

      :error ->
        %{}
    end
  end

  defp team_pid_alive?(workspace_path, team_name) do
    case read_registry_teams(workspace_path) do
      {:ok, teams} ->
        team = Enum.find(teams, fn t -> Map.get(t, "name") == team_name end)
        os_pid_alive?(team && Map.get(team, "pid"))

      :error ->
        false
    end
  end

  defp read_registry_teams(workspace_path) do
    registry_path = Path.join([workspace_path, ".cortex", "registry.json"])

    with {:ok, content} <- File.read(registry_path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, Map.get(data, "teams", [])}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp os_pid_alive?(pid) when is_integer(pid) and pid > 0 do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
  end

  defp os_pid_alive?(_), do: false

  defp diag_banner_class(:in_progress), do: "bg-blue-950/30 border-blue-800 text-blue-300"
  defp diag_banner_class(:completed), do: "bg-green-950/30 border-green-800 text-green-300"
  defp diag_banner_class(:max_turns), do: "bg-yellow-950/30 border-yellow-800 text-yellow-300"
  defp diag_banner_class(:empty_log), do: "bg-red-950/30 border-red-800 text-red-300"
  defp diag_banner_class(:no_session), do: "bg-red-950/30 border-red-800 text-red-300"
  defp diag_banner_class(:died_during_tool), do: "bg-red-950/30 border-red-800 text-red-300"

  defp diag_banner_class(:died_after_tool_result),
    do: "bg-red-950/30 border-red-800 text-red-300"

  defp diag_banner_class(:log_ends_without_result),
    do: "bg-red-950/30 border-red-800 text-red-300"

  defp diag_banner_class(:error_during_execution),
    do: "bg-red-950/30 border-red-800 text-red-300"

  defp diag_banner_class(_), do: "bg-gray-900 border-gray-800 text-gray-300"

  defp diag_icon(:in_progress), do: ">>"
  defp diag_icon(:completed), do: "OK"
  defp diag_icon(:max_turns), do: "!!"
  defp diag_icon(:empty_log), do: "XX"
  defp diag_icon(:no_session), do: "XX"
  defp diag_icon(:error_during_execution), do: "!!"
  defp diag_icon(:died_during_tool), do: "!!"
  defp diag_icon(:died_after_tool_result), do: "!!"
  defp diag_icon(:log_ends_without_result), do: "!!"
  defp diag_icon(_), do: "??"

  defp diag_title(:in_progress), do: "Still Running"
  defp diag_title(:completed), do: "Completed Successfully"
  defp diag_title(:max_turns), do: "Hit Max Turns"
  defp diag_title(:empty_log), do: "Empty Log — Never Started"
  defp diag_title(:no_session), do: "No Session — Crashed on Startup"
  defp diag_title(:error_during_execution), do: "Error During Execution"
  defp diag_title(:died_during_tool), do: "Died During Tool Execution"
  defp diag_title(:died_after_tool_result), do: "Died After Tool Result"
  defp diag_title(:log_ends_without_result), do: "Log Ends Without Result"
  defp diag_title(:exited), do: "Exited with Error"
  defp diag_title(_), do: "Unknown Status"

  defp diag_entry_class(:session_start), do: "bg-purple-900/60 text-purple-300"
  defp diag_entry_class(:thinking), do: "bg-gray-800/60 text-gray-400"
  defp diag_entry_class(:text), do: "bg-blue-900/60 text-blue-300"
  defp diag_entry_class(:tool_use), do: "bg-green-900/60 text-green-300"
  defp diag_entry_class(:tool_start), do: "bg-green-900/60 text-green-300"
  defp diag_entry_class(:tool_result), do: "bg-emerald-900/60 text-emerald-300"
  defp diag_entry_class(:tool_error), do: "bg-red-900/60 text-red-300"
  defp diag_entry_class(:result), do: "bg-cyan-900/60 text-cyan-300"
  defp diag_entry_class(:end_turn), do: "bg-gray-800/60 text-gray-400"
  defp diag_entry_class(:parse_error), do: "bg-red-900/60 text-red-300"
  defp diag_entry_class(_), do: "bg-gray-800/60 text-gray-400"

  defp diag_entry_label(:session_start), do: "session"
  defp diag_entry_label(:thinking), do: "thinking"
  defp diag_entry_label(:text), do: "text"
  defp diag_entry_label(:tool_use), do: "tool"
  defp diag_entry_label(:tool_start), do: "tool"
  defp diag_entry_label(:tool_result), do: "result"
  defp diag_entry_label(:tool_error), do: "error"
  defp diag_entry_label(:result), do: "done"
  defp diag_entry_label(:end_turn), do: "end"
  defp diag_entry_label(:parse_error), do: "parse err"
  defp diag_entry_label(type), do: Atom.to_string(type)

  defp format_iso_time(nil), do: ""

  defp format_iso_time(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso_string
    end
  end

  # -- Per-team health indicators --

  defp health_indicator_text(team, last_seen) do
    case Map.get(last_seen, team.team_name) do
      nil ->
        case team.started_at do
          nil -> "no events"
          ts -> "started #{time_ago(ts)}, no events received"
        end

      ts ->
        "last event #{time_ago(ts)}"
    end
  end

  defp safe_store_call(fun) do
    fun.()
  rescue
    _ -> :ok
  end

  defp truncate_for_store(nil), do: nil

  defp truncate_for_store(text) when is_binary(text) do
    if String.length(text) > 2000, do: String.slice(text, 0, 2000) <> "...", else: text
  end

  defp truncate_for_store(other), do: inspect(other) |> truncate_for_store()

  defp format_token_count(nil), do: "0"
  defp format_token_count(0), do: "0"

  defp format_token_count(n) when n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_token_count(n) when n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end

  defp format_token_count(n), do: to_string(n)

  defp time_ago(datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      true -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m ago"
    end
  end
end
