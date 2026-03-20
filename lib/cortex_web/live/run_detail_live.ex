defmodule CortexWeb.RunDetailLive do
  use CortexWeb, :live_view

  import CortexWeb.RunDetail.OverviewTab
  import CortexWeb.RunDetail.ActivityTab
  import CortexWeb.RunDetail.MessagesTab
  import CortexWeb.RunDetail.LogsTab
  import CortexWeb.RunDetail.DiagnosticsTab
  import CortexWeb.RunDetail.SummariesTab
  import CortexWeb.RunDetail.JobsTab
  import CortexWeb.RunDetail.SettingsTab
  import CortexWeb.RunDetail.GraphTab
  import CortexWeb.RunDetail.MembershipTab
  import CortexWeb.RunDetail.KnowledgeTab
  import CortexWeb.RunDetail.TeamSlideOver

  alias Cortex.InternalAgent.Debug
  alias Cortex.InternalAgent.Summary
  alias Cortex.Messaging.InboxBridge
  alias Cortex.Orchestration.Config.Loader, as: ConfigLoader
  alias Cortex.Orchestration.DAG
  alias Cortex.Orchestration.Injection
  alias Cortex.Orchestration.LogParser
  alias Cortex.Orchestration.Runner
  alias Cortex.Orchestration.Spawner
  alias Cortex.Orchestration.Workspace
  alias CortexWeb.RunDetail.Helpers

  require Logger

  @max_activities 150
  @stale_threshold_seconds 300
  @max_log_lines 500
  @pid_check_interval_ms 30_000

  @elapsed_tick_ms 1_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: safe_subscribe()
    if connected?(socket), do: :timer.send_interval(@elapsed_tick_ms, self(), :tick_elapsed)

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
           message_flows: %{flows: [], total: 0, by_agent: %{}},
           membership_view: "list",
           selected_graph_node: nil,
           selected_log_team: nil,
           log_lines: nil,
           log_sort: :desc,
           expanded_logs: MapSet.new(),
           messages_team: nil,
           team_inbox: [],
           diagnostics_team: nil,
           diagnostics_report: nil,
           debug_report: nil,
           debug_loading: false,
           debug_reports: [],
           selected_debug_report: nil,
           coordinator_expanded: false,
           coordinator_log: nil,
           coordinator_inbox: [],
           activity_team: nil,
           coordinator_summaries: [],
           selected_summary: nil,
           run_summary: nil,
           summary_jobs: [],
           summaries_expanded: false,
           run_jobs: [],
           selected_run_job: nil,
           run_job_log: nil,
           gossip_round: nil,
           gossip_knowledge: nil,
           pid_status: %{},
           editing_name: false,
           name_form: %{"name" => ""},
           expanded_activities: MapSet.new(),
           team_panel_open: false,
           panel_team_run: nil,
           panel_log: nil,
           panel_diagnostics: nil
         )}

      run ->
        team_runs = safe_get_team_runs(run.id)
        external_runs = Enum.reject(team_runs, & &1.internal)
        {tiers, edges} = build_dag(run, external_runs)
        team_members = extract_team_members(run)
        team_names = Enum.map(external_runs, & &1.team_name)

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
           message_flows: %{flows: [], total: 0, by_agent: %{}},
           membership_view: "list",
           log_sort: :desc,
           selected_log_team: nil,
           log_lines: nil,
           expanded_logs: MapSet.new(),
           messages_team: nil,
           team_inbox: [],
           diagnostics_team: nil,
           diagnostics_report: nil,
           debug_report: nil,
           debug_loading: false,
           debug_reports: read_debug_reports(run),
           selected_debug_report: nil,
           coordinator_alive: coordinator_alive,
           coordinator_expanded: false,
           coordinator_log: nil,
           coordinator_inbox: [],
           activity_team: nil,
           coordinator_summaries: [],
           selected_summary: nil,
           run_summary: nil,
           summary_jobs: [],
           summaries_expanded: false,
           run_jobs: [],
           selected_run_job: nil,
           run_job_log: nil,
           gossip_round: reconstruct_gossip_round(run),
           gossip_knowledge: nil,
           pid_status: %{},
           editing_name: false,
           name_form: %{"name" => run.name || ""},
           expanded_activities: MapSet.new(),
           team_panel_open: false,
           panel_team_run: nil,
           panel_log: nil,
           panel_diagnostics: nil
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
             :run_completed,
             # Mesh lifecycle
             :mesh_started,
             :mesh_completed,
             :member_joined,
             :member_suspect,
             :member_dead,
             :member_left,
             :member_alive,
             # Gossip lifecycle
             :gossip_started,
             :gossip_completed,
             :gossip_round_completed,
             :gossip_early_termination
           ] do
    case socket.assigns.run do
      nil ->
        {:noreply, socket}

      run ->
        updated_run = safe_get_run(run.id)
        team_runs = safe_get_team_runs(run.id)
        external_runs = Enum.reject(team_runs, & &1.internal)
        {tiers, edges} = build_dag(updated_run || run, external_runs)

        coordinator_alive =
          Runner.coordinator_alive?(run.id)

        # Auto-generate summary on completion events (with full diagnostics)
        completion_events = [
          :tier_completed,
          :run_completed,
          :mesh_completed,
          :gossip_completed,
          :gossip_round_completed
        ]

        run_summary =
          if type in completion_events do
            build_run_summary(updated_run || run, external_runs, socket.assigns.last_seen,
              include_diagnostics: true
            )
          else
            socket.assigns.run_summary
          end

        summaries =
          if type in completion_events do
            read_coordinator_summaries(updated_run || run)
          else
            socket.assigns.coordinator_summaries
          end

        {:noreply,
         assign(socket,
           run: updated_run || run,
           team_runs: team_runs,
           team_names: Enum.map(external_runs, & &1.team_name),
           tiers: tiers,
           edges: edges,
           coordinator_alive: coordinator_alive,
           coordinator_summaries: summaries,
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
        team_runs
        |> Enum.map(fn tr ->
          (tr.input_tokens || 0) + (tr.cache_read_tokens || 0) + (tr.cache_creation_tokens || 0)
        end)
        |> Enum.sum()

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
          inbox = read_team_inbox(run, team_name)

          assign(socket,
            activities: activities,
            last_seen: last_seen,
            team_inbox: inbox
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

  def handle_info(:tick_elapsed, socket) do
    # Just triggers a re-render so elapsed_since/1 shows updated time
    {:noreply, socket}
  end

  def handle_info(%{type: :gossip_round_completed, payload: payload}, socket) do
    round = Map.get(payload, :round, 0)
    total = Map.get(payload, :total, 0)
    total_entries = Map.get(payload, :total_entries, 0)
    by_topic = Map.get(payload, :by_topic, %{})
    top_entries = Map.get(payload, :top_entries, [])

    knowledge =
      if total_entries > 0 do
        %{total_entries: total_entries, by_topic: by_topic, top_entries: top_entries}
      else
        socket.assigns.gossip_knowledge
      end

    entry = %{
      team: "system",
      text: "Gossip round #{round}/#{total} complete — #{total_entries} entries exchanged",
      kind: :message,
      at: format_now()
    }

    {:noreply,
     socket
     |> assign(
       gossip_round: %{current: round, total: total},
       gossip_knowledge: knowledge,
       activities: prepend_activity(socket.assigns.activities, entry)
     )}
  end

  def handle_info(%{type: :gossip_completed, payload: payload}, socket) do
    total_entries = Map.get(payload, :total_entries, 0)
    by_topic = Map.get(payload, :by_topic, %{})
    top_entries = Map.get(payload, :top_entries, [])

    knowledge = %{
      total_entries: total_entries,
      by_topic: by_topic,
      top_entries: top_entries
    }

    entry = %{
      team: "system",
      text:
        "Gossip complete — #{total_entries} knowledge entries across #{map_size(by_topic)} topics",
      kind: :message,
      at: format_now()
    }

    {:noreply,
     socket
     |> assign(
       gossip_knowledge: knowledge,
       activities: prepend_activity(socket.assigns.activities, entry)
     )}
  end

  def handle_info({:ai_summary_result, job_id, {:ok, summary}}, socket) do
    summaries = read_coordinator_summaries(socket.assigns.run)
    tokens = lookup_internal_tokens(socket.assigns.run, "summary-agent")

    entry = %{
      team: "system",
      text: "Agent summary complete",
      kind: :message,
      at: format_now()
    }

    jobs = update_summary_job(socket.assigns.summary_jobs, job_id, :completed, nil, tokens)

    {:noreply,
     socket
     |> assign(
       summary_jobs: jobs,
       coordinator_summaries: summaries,
       selected_summary: %{name: summary.filename || "latest", content: summary.content},
       activities: prepend_activity(socket.assigns.activities, entry)
     )
     |> put_flash(:info, "Agent summary ready")}
  end

  def handle_info({:ai_summary_result, job_id, {:error, reason}}, socket) do
    Logger.warning("Agent summary failed: #{inspect(reason)}")

    entry = %{
      team: "system",
      text: "Agent summary failed",
      kind: :error,
      at: format_now()
    }

    jobs = update_summary_job(socket.assigns.summary_jobs, job_id, :failed)

    {:noreply,
     socket
     |> assign(
       summary_jobs: jobs,
       activities: prepend_activity(socket.assigns.activities, entry)
     )
     |> put_flash(:error, "Agent summary failed — check server logs for details")}
  end

  def handle_info({:debug_report_result, {:ok, report}}, socket) do
    entry = %{
      team: "system",
      text: "Diagnostic report complete for #{report.team}",
      kind: :message,
      at: format_now()
    }

    {:noreply,
     socket
     |> assign(
       debug_loading: false,
       debug_report: report,
       debug_reports: read_debug_reports(socket.assigns.run),
       activities: prepend_activity(socket.assigns.activities, entry)
     )
     |> put_flash(:info, "Diagnostic report ready for #{report.team}")}
  end

  def handle_info({:debug_report_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(debug_loading: false)
     |> put_flash(:error, "Diagnostic report failed: #{inspect(reason)}")}
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
        inbox = read_team_inbox(socket.assigns.run, socket.assigns.messages_team)
        assign(socket, team_inbox: inbox)
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

  def handle_event("switch_tab", %{"tab" => "summaries"}, socket) do
    summaries = read_coordinator_summaries(socket.assigns.run)
    {:noreply, assign(socket, current_tab: "summaries", coordinator_summaries: summaries)}
  end

  def handle_event("switch_tab", %{"tab" => "jobs"}, socket) do
    jobs = get_run_jobs(socket.assigns.run)

    {:noreply,
     assign(socket, current_tab: "jobs", run_jobs: jobs, selected_run_job: nil, run_job_log: nil)}
  end

  def handle_event("select_run_job", %{"id" => job_id}, socket) do
    job = Enum.find(socket.assigns.run_jobs, &(&1.id == job_id))
    log = if job && job.log_path, do: parse_run_job_log(job.log_path), else: nil
    {:noreply, assign(socket, selected_run_job: job, run_job_log: log)}
  end

  def handle_event("close_run_job", _params, socket) do
    {:noreply, assign(socket, selected_run_job: nil, run_job_log: nil)}
  end

  def handle_event("refresh_run_job_log", _params, socket) do
    job = socket.assigns.selected_run_job
    log = if job && job.log_path, do: parse_run_job_log(job.log_path), else: nil
    {:noreply, assign(socket, run_job_log: log)}
  end

  def handle_event("switch_tab", %{"tab" => "membership"}, socket) do
    run = socket.assigns.run
    agent_names = socket.assigns.team_names

    flows =
      Helpers.aggregate_message_flows(run && run.workspace_path, agent_names)

    {:noreply, assign(socket, current_tab: "membership", message_flows: flows)}
  end

  def handle_event("set_membership_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, membership_view: view)}
  end

  def handle_event("select_graph_node", %{"name" => ""}, socket) do
    {:noreply, assign(socket, selected_graph_node: nil)}
  end

  def handle_event("select_graph_node", %{"name" => name}, socket) do
    # Toggle: click again to deselect
    current = socket.assigns[:selected_graph_node]
    {:noreply, assign(socket, selected_graph_node: if(current == name, do: nil, else: name))}
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
    {:noreply, assign(socket, diagnostics_team: nil, diagnostics_report: nil, debug_report: nil)}
  end

  def handle_event("select_diag_team", %{"team" => team_name}, socket) do
    team_status = get_team_status(socket.assigns.team_runs, team_name)
    report = load_diagnostics(socket.assigns.run, team_name, team_status: team_status)

    {:noreply,
     assign(socket, diagnostics_team: team_name, diagnostics_report: report, debug_report: nil)}
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

  def handle_event("request_debug_report", _params, socket) do
    run = socket.assigns.run
    team_name = socket.assigns.diagnostics_team

    cond do
      !(run && run.workspace_path && team_name) ->
        {:noreply, put_flash(socket, :error, "No workspace or team selected")}

      socket.assigns.debug_loading ->
        {:noreply, put_flash(socket, :info, "Debug report already in progress...")}

      true ->
        liveview_pid = self()
        run_id = run.id

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

        log_path = Path.join([run.workspace_path, ".cortex", "logs", "debug-agent.log"])

        # Persist to DB
        safe_store_call(fn ->
          Cortex.Store.upsert_internal_team_run(%{
            run_id: run_id,
            team_name: "debug-agent",
            role: "Debug Report — #{team_name}",
            tier: -2,
            internal: true,
            status: "running",
            log_path: log_path,
            started_at: DateTime.utc_now()
          })
        end)

        Task.start(fn ->
          result =
            try do
              Debug.analyze(run.workspace_path, team_name,
                run_name: run.name || "Untitled",
                on_activity: on_activity
              )
            rescue
              e -> {:error, Exception.message(e)}
            catch
              kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
            end

          persist_agent_job_result(run_id, "debug-agent", result)
          send(liveview_pid, {:debug_report_result, result})
        end)

        entry = %{
          team: "system",
          text: "Diagnostic agent spawned for #{team_name} (haiku)",
          kind: :message,
          at: format_now()
        }

        {:noreply,
         socket
         |> assign(
           debug_loading: true,
           debug_report: nil,
           activities: prepend_activity(socket.assigns.activities, entry)
         )
         |> put_flash(:info, "Generating diagnostic report for #{team_name}...")}
    end
  end

  # -- Event handlers: messages team selection --

  def handle_event("select_messages_team", %{"team" => ""}, socket) do
    {:noreply, assign(socket, messages_team: nil, team_inbox: [])}
  end

  def handle_event("select_messages_team", %{"team" => team_name}, socket) do
    inbox = read_team_inbox(socket.assigns.run, team_name)

    {:noreply,
     assign(socket,
       messages_team: team_name,
       team_inbox: inbox,
       msg_to: team_name
     )}
  end

  def handle_event("refresh_messages", _params, socket) do
    if socket.assigns.messages_team do
      inbox = read_team_inbox(socket.assigns.run, socket.assigns.messages_team)
      {:noreply, assign(socket, team_inbox: inbox)}
    else
      {:noreply, socket}
    end
  end

  # -- Event handlers: message sending --

  def handle_event("send_message", %{"to" => to, "content" => content}, socket) do
    run = socket.assigns.run
    workspace_path = run && run.workspace_path

    cond do
      !(run && to != "" && content != "") ->
        {:noreply, socket}

      not workspace_path ->
        {:noreply, put_flash(socket, :error, "No workspace path -- cannot send messages")}

      true ->
        from = if to == "coordinator", do: "human", else: "coordinator"
        Runner.send_message(workspace_path, from, to, content)

        entry = %{
          team: "system",
          text: "Message sent to #{to}: #{truncate(content, 100)}",
          kind: :message,
          at: format_now()
        }

        activities = prepend_activity(socket.assigns.activities, entry)

        socket =
          if socket.assigns.messages_team == to do
            inbox = read_team_inbox(run, to)

            assign(socket,
              activities: activities,
              msg_content: "",
              team_inbox: inbox
            )
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
      !(run && workspace_path) ->
        {:noreply, put_flash(socket, :error, "No workspace path — cannot restart")}

      team_pid_alive?(workspace_path, team_name) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "#{team_name} process is still alive (PID running). " <>
             "Wait for it to finish or kill it manually before restarting."
         )}

      !(team_run && team_run.prompt) ->
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

  def handle_event("start_rename", _params, socket) do
    {:noreply,
     assign(socket, editing_name: true, name_form: %{"name" => socket.assigns.run.name || ""})}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, editing_name: false)}
  end

  def handle_event("save_rename", %{"name" => new_name}, socket) do
    run = socket.assigns.run
    new_name = String.trim(new_name)

    if run && new_name != "" do
      case Cortex.Store.update_run(run, %{name: new_name}) do
        {:ok, updated_run} ->
          {:noreply,
           assign(socket,
             run: updated_run,
             editing_name: false,
             page_title: "Run: #{updated_run.name}"
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to rename run")}
      end
    else
      {:noreply, assign(socket, editing_name: false)}
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

  def handle_event("stop_run", _params, socket) do
    run = socket.assigns.run

    if run && run.workspace_path do
      killed = kill_all_processes(run.workspace_path)
      coord_killed = stop_coordinator_process(run.id)
      total_killed = killed + coord_killed
      mark_run_stopped(run)

      entry = %{
        team: "system",
        text: "Run stopped — killed #{total_killed} process(es)",
        kind: :error,
        at: format_now()
      }

      # Re-fetch state
      updated_run = safe_get_run(run.id)
      team_runs = safe_get_team_runs(run.id)
      {tiers, edges} = build_dag(updated_run || run, team_runs)

      {:noreply,
       socket
       |> assign(
         run: updated_run || run,
         team_runs: team_runs,
         tiers: tiers,
         edges: edges,
         coordinator_alive: false,
         pid_status: %{},
         activities: prepend_activity(socket.assigns.activities, entry)
       )
       |> put_flash(:info, "Run stopped — #{total_killed} process(es) killed")}
    else
      {:noreply, put_flash(socket, :error, "No workspace path")}
    end
  end

  def handle_event("start_coordinator", _params, socket) do
    run = socket.assigns.run

    cond do
      !(run && run.workspace_path && run.config_yaml) ->
        {:noreply, put_flash(socket, :error, "No workspace path or config available")}

      gossip?(run) ->
        start_gossip_coordinator(socket, run)

      mesh?(run) ->
        start_mesh_coordinator(socket, run)

      true ->
        start_dag_coordinator(socket, run)
    end
  end

  def handle_event("stop_coordinator", _params, socket) do
    run = socket.assigns.run

    if run do
      stopped = stop_coordinator_process(run.id)
      kill_coordinator_os_pid(run.workspace_path)
      mark_coordinator_stopped(run.id)

      entry = %{
        team: "system",
        text: "Coordinator stopped#{if stopped > 0, do: " (process killed)", else: ""}",
        kind: :message,
        at: format_now()
      }

      {:noreply,
       socket
       |> assign(
         coordinator_alive: false,
         activities: prepend_activity(socket.assigns.activities, entry)
       )
       |> put_flash(:info, "Coordinator stopped")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("generate_summary", _params, socket) do
    summary =
      build_run_summary(socket.assigns.run, socket.assigns.team_runs, socket.assigns.last_seen,
        include_diagnostics: true
      )

    {:noreply, assign(socket, run_summary: summary)}
  end

  # -- Event handlers: coordinator detail --

  def handle_event("toggle_coordinator", _params, socket) do
    if socket.assigns.coordinator_expanded do
      {:noreply, assign(socket, coordinator_expanded: false)}
    else
      run = socket.assigns.run
      log = read_coordinator_log(run)
      inbox = read_team_inbox(run, "coordinator")

      {:noreply,
       assign(socket,
         coordinator_expanded: true,
         coordinator_log: log,
         coordinator_inbox: inbox
       )}
    end
  end

  def handle_event("refresh_coordinator", _params, socket) do
    run = socket.assigns.run
    log = read_coordinator_log(run)
    inbox = read_team_inbox(run, "coordinator")

    {:noreply,
     assign(socket,
       coordinator_log: log,
       coordinator_inbox: inbox
     )}
  end

  # -- Event handlers: activity team filter --

  def handle_event("select_activity_team", %{"team" => ""}, socket) do
    {:noreply, assign(socket, activity_team: nil)}
  end

  def handle_event("select_activity_team", %{"team" => team_name}, socket) do
    {:noreply, assign(socket, activity_team: team_name)}
  end

  def handle_event("toggle_activity", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    expanded = socket.assigns.expanded_activities

    expanded =
      if MapSet.member?(expanded, idx),
        do: MapSet.delete(expanded, idx),
        else: MapSet.put(expanded, idx)

    {:noreply, assign(socket, expanded_activities: expanded)}
  end

  # -- Event handlers: coordinator summaries --

  def handle_event("refresh_summaries", _params, socket) do
    summaries = read_coordinator_summaries(socket.assigns.run)
    {:noreply, assign(socket, coordinator_summaries: summaries)}
  end

  def handle_event("toggle_summaries", _params, socket) do
    {:noreply, assign(socket, summaries_expanded: !socket.assigns.summaries_expanded)}
  end

  def handle_event("dismiss_summary_job", %{"id" => job_id}, socket) do
    jobs = Enum.reject(socket.assigns.summary_jobs, &(&1.id == job_id))
    {:noreply, assign(socket, summary_jobs: jobs)}
  end

  def handle_event("request_ai_summary", _params, socket) do
    run = socket.assigns.run
    workspace_path = run && run.workspace_path

    cond do
      !(run && workspace_path) ->
        {:noreply, put_flash(socket, :error, "No workspace path")}

      has_running_summary_job?(socket.assigns.summary_jobs) ->
        {:noreply, put_flash(socket, :info, "Summary already in progress...")}

      true ->
        liveview_pid = self()
        run_id = run.id
        job_id = System.unique_integer([:positive]) |> to_string()

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

        log_path = Path.join([workspace_path, ".cortex", "logs", "summary-agent.log"])

        # Persist to DB
        safe_store_call(fn ->
          Cortex.Store.upsert_internal_team_run(%{
            run_id: run_id,
            team_name: "summary-agent",
            role: "Agent Summary",
            tier: -2,
            internal: true,
            status: "running",
            log_path: log_path,
            started_at: DateTime.utc_now()
          })
        end)

        Task.start(fn ->
          result =
            try do
              Summary.generate(workspace_path,
                run_name: run.name || "Untitled",
                on_activity: on_activity,
                on_token_update: on_token_update
              )
            rescue
              e -> {:error, Exception.message(e)}
            catch
              kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
            end

          persist_agent_job_result(run_id, "summary-agent", result)
          send(liveview_pid, {:ai_summary_result, job_id, result})
        end)

        job = %{
          id: job_id,
          type: :ai_summary,
          status: :running,
          started_at: DateTime.utc_now(),
          error: nil,
          input_tokens: nil,
          output_tokens: nil
        }

        entry = %{
          team: "system",
          text: "Agent summary spawned (haiku)",
          kind: :message,
          at: format_now()
        }

        {:noreply,
         socket
         |> assign(
           summary_jobs: [job | socket.assigns.summary_jobs],
           activities: prepend_activity(socket.assigns.activities, entry)
         )
         |> put_flash(:info, "Generating Agent summary...")}
    end
  end

  def handle_event("select_summary", %{"file" => filename}, socket) do
    selected = read_summary_file(socket.assigns.run, filename, nil)
    {:noreply, assign(socket, selected_summary: selected)}
  end

  def handle_event("select_debug_report", %{"file" => filename}, socket) do
    selected = read_debug_file(socket.assigns.run, filename)
    {:noreply, assign(socket, selected_debug_report: selected)}
  end

  def handle_event("form_update", params, socket) do
    {:noreply,
     assign(socket,
       msg_to: Map.get(params, "to", socket.assigns.msg_to),
       msg_content: Map.get(params, "content", socket.assigns.msg_content)
     )}
  end

  # -- Event handlers: team slide-over panel --

  def handle_event("open_team_panel", %{"team" => team_name}, socket) do
    run = socket.assigns.run

    team_run =
      Enum.find(socket.assigns.team_runs, fn tr -> tr.team_name == team_name end)

    panel_log = read_team_log(run, team_name)
    team_status = get_team_status(socket.assigns.team_runs, team_name)
    panel_diagnostics = load_diagnostics(run, team_name, team_status: team_status)

    {:noreply,
     assign(socket,
       team_panel_open: true,
       panel_team_run: team_run,
       panel_log: panel_log,
       panel_diagnostics: panel_diagnostics
     )}
  end

  def handle_event("close_team_panel", _params, socket) do
    {:noreply,
     assign(socket,
       team_panel_open: false,
       panel_team_run: nil,
       panel_log: nil,
       panel_diagnostics: nil
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
        <%= if @editing_name do %>
          <form phx-submit="save_rename" class="inline-flex items-center gap-2">
            <input
              type="text"
              name="name"
              value={@name_form["name"]}
              autofocus
              class="bg-gray-950 border border-gray-600 rounded px-2 py-1 text-white text-lg font-semibold focus:border-cortex-400 focus:ring-1 focus:ring-cortex-400"
              phx-keydown="cancel_rename"
              phx-key="Escape"
            />
            <button type="submit" class="text-sm text-green-400 hover:text-green-300">Save</button>
            <button type="button" phx-click="cancel_rename" class="text-sm text-gray-400 hover:text-gray-300">Cancel</button>
          </form>
        <% else %>
          <span phx-click="start_rename" class="cursor-pointer hover:text-cortex-300 transition-colors" title="Click to rename">
            {run_title(@run)}
          </span>
        <% end %>
        <:subtitle>
          <.status_badge status={@run.status} />
          <span class="ml-2 text-gray-400">
            <.token_detail
              id="run-tokens"
              input={Helpers.sum_team_field(@team_runs, :input_tokens)}
              output={Helpers.sum_team_field(@team_runs, :output_tokens)}
              cache_read={Helpers.sum_team_field(@team_runs, :cache_read_tokens)}
              cache_creation={Helpers.sum_team_field(@team_runs, :cache_creation_tokens)}
            />
          </span>
          <span class="ml-2 text-gray-400">
            <%= if @run.status in ["running", "pending"] and @run.started_at do %>
              {Helpers.elapsed_since(@run.started_at)}
            <% else %>
              <.duration_display ms={@run.total_duration_ms} />
            <% end %>
          </span>
          <span :if={@run.workspace_path} class="ml-2 text-gray-500 text-xs font-mono">
            {@run.workspace_path}
          </span>
        </:subtitle>
        <:actions>
          <button
            :if={@run.status in ["running", "pending"]}
            phx-click="stop_run"
            data-confirm="Stop this run? All running processes will be killed."
            class="text-sm text-red-400 hover:text-red-300 px-3 py-1 rounded border border-red-800 hover:border-red-600"
          >
            Stop Run
          </button>
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

      <%!-- Resume Banner --%>
      <%= if Helpers.has_stalled_teams?(@team_runs, @run.status, @last_seen, @pid_status) do %>
        <div class="bg-yellow-900/30 border border-yellow-800 rounded-lg p-4 mb-6">
          <div class="flex items-center justify-between mb-2">
            <div>
              <p class="text-yellow-300 font-medium">Stalled {Helpers.participant_label(@run, :lower_plural)} detected</p>
              <p class="text-yellow-200/70 text-sm">
                {Helpers.count_stalled(@team_runs, @last_seen, @pid_status)} {Helpers.participant_label(@run, :singular)}(s) show as "running" but have no live PID and no events in over 5 minutes:
                <span class="font-mono">
                  {Helpers.stalled_team_names(@team_runs, @last_seen, @pid_status) |> Enum.join(", ")}
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

      <%!-- Continue Run Banner --%>
      <% incomplete = incomplete_team_names(@run, @team_runs) %>
      <%= if incomplete != [] and @run.status in ["running", "failed"] and not @coordinator_alive do %>
        <div class="bg-blue-900/30 border border-blue-800 rounded-lg p-4 mb-6">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-blue-300 font-medium">Run interrupted — {length(incomplete)} incomplete {Helpers.participant_label(@run, :singular)}(s)</p>
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

      <%!-- Mode-Conditional Tab Bar --%>
      <div class="flex border-b border-gray-800 mb-6">
        <button
          :for={tab <- visible_tabs(@run)}
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

      <%!-- Tab Content --%>
      <div :if={@current_tab == "overview"}>
        <.overview_tab
          run={@run}
          team_runs={@team_runs}
          tiers={@tiers}
          edges={@edges}
          team_members={@team_members}
          last_seen={@last_seen}
          pid_status={@pid_status}
          coordinator_alive={@coordinator_alive}
          coordinator_expanded={@coordinator_expanded}
          coordinator_log={@coordinator_log}
          coordinator_inbox={@coordinator_inbox}
          activities={@activities}
          expanded_activities={@expanded_activities}
          gossip_round={@gossip_round}
          gossip_knowledge={@gossip_knowledge}
        />
      </div>

      <div :if={@current_tab == "graph"}>
        <.graph_tab run={@run} team_runs={@team_runs} tiers={@tiers} edges={@edges} />
      </div>

      <div :if={@current_tab == "membership"}>
        <.membership_tab run={@run} team_runs={@team_runs} last_seen={@last_seen} pid_status={@pid_status} message_flows={assigns[:message_flows] || %{flows: [], total: 0, by_agent: %{}}} membership_view={assigns[:membership_view] || "list"} selected_graph_node={assigns[:selected_graph_node]} />
      </div>

      <div :if={@current_tab == "knowledge"}>
        <.knowledge_tab run={@run} team_runs={@team_runs} gossip_round={@gossip_round} gossip_knowledge={@gossip_knowledge} />
      </div>

      <div :if={@current_tab == "activity"}>
        <.activity_tab
          run={@run}
          activities={@activities}
          activity_team={@activity_team}
          team_names={@team_names}
          expanded_activities={@expanded_activities}
        />
      </div>

      <div :if={@current_tab == "messages"}>
        <.messages_tab
          run={@run}
          team_names={@team_names}
          messages_team={@messages_team}
          team_inbox={@team_inbox}
          msg_to={@msg_to}
          msg_content={@msg_content}
        />
      </div>

      <div :if={@current_tab == "logs"}>
        <.logs_tab
          run={@run}
          team_names={@team_names}
          selected_log_team={@selected_log_team}
          log_lines={@log_lines}
          log_sort={@log_sort}
          expanded_logs={@expanded_logs}
        />
      </div>

      <div :if={@current_tab == "diagnostics"}>
        <.diagnostics_tab
          run={@run}
          team_runs={@team_runs}
          team_names={@team_names}
          diagnostics_team={@diagnostics_team}
          diagnostics_report={@diagnostics_report}
          debug_report={@debug_report}
          debug_loading={@debug_loading}
          debug_reports={@debug_reports}
          selected_debug_report={@selected_debug_report}
        />
      </div>

      <div :if={@current_tab == "summaries"}>
        <.summaries_tab
          run={@run}
          summary_jobs={@summary_jobs}
          coordinator_summaries={@coordinator_summaries}
          summaries_expanded={@summaries_expanded}
          selected_summary={@selected_summary}
          run_summary={@run_summary}
        />
      </div>

      <div :if={@current_tab == "jobs"}>
        <.jobs_tab
          run={@run}
          run_jobs={@run_jobs}
          selected_run_job={@selected_run_job}
          run_job_log={@run_job_log}
        />
      </div>

      <div :if={@current_tab == "settings"}>
        <.settings_tab run={@run} team_runs={@team_runs} tiers={@tiers} />
      </div>

      <%!-- Team Slide-Over Panel --%>
      <.team_slide_over
        show={@team_panel_open}
        team_run={@panel_team_run}
        panel_log={@panel_log}
        panel_diagnostics={@panel_diagnostics}
        run={@run}
      />
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
        nil ->
          :ok

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

  defp start_gossip_coordinator(socket, run) do
    alias Cortex.Gossip.Config.Loader, as: GossipLoader
    alias Cortex.Gossip.Coordinator.Prompt, as: GossipCoordPrompt

    case GossipLoader.load_string(run.config_yaml) do
      {:ok, gossip_config} ->
        workspace_path = run.workspace_path
        cortex_path = Path.join(workspace_path, ".cortex")
        run_id = run.id

        InboxBridge.setup(workspace_path, ["coordinator"])

        prompt = GossipCoordPrompt.build(gossip_config, workspace_path)
        log_path = Path.join([cortex_path, "logs", "coordinator.log"])

        callbacks = build_coordinator_callbacks(run_id, cortex_path)

        safe_store_call(fn ->
          Cortex.Store.upsert_internal_team_run(%{
            run_id: run_id,
            team_name: "coordinator",
            role: "Gossip Coordinator",
            tier: -1,
            internal: true,
            status: "running",
            prompt: prompt,
            log_path: log_path,
            started_at: DateTime.utc_now()
          })
        end)

        spawn_coordinator_task(run_id, prompt, log_path, workspace_path, callbacks)

        entry = %{
          team: "system",
          text: "Starting gossip coordinator agent...",
          kind: :resume,
          at: format_now()
        }

        {:noreply,
         socket
         |> assign(
           coordinator_alive: true,
           activities: prepend_activity(socket.assigns.activities, entry)
         )
         |> put_flash(:info, "Gossip coordinator agent started")}

      {:error, _errors} ->
        {:noreply, put_flash(socket, :error, "Failed to parse gossip config")}
    end
  end

  defp start_mesh_coordinator(socket, run) do
    alias Cortex.Mesh.Config.Loader, as: MeshLoader
    alias Cortex.Mesh.Coordinator.Prompt, as: MeshCoordPrompt

    case MeshLoader.load_string(run.config_yaml) do
      {:ok, mesh_config} ->
        workspace_path = run.workspace_path
        cortex_path = Path.join(workspace_path, ".cortex")
        run_id = run.id

        InboxBridge.setup(workspace_path, ["coordinator"])

        # Build roster from team_runs
        roster =
          socket.assigns.team_runs
          |> Enum.reject(& &1.internal)
          |> Enum.map(fn tr ->
            %{name: tr.team_name, role: tr.role || tr.team_name, state: tr.status || "running"}
          end)

        prompt = MeshCoordPrompt.build(mesh_config, workspace_path, roster)
        log_path = Path.join([cortex_path, "logs", "coordinator.log"])

        callbacks = build_coordinator_callbacks(run_id, cortex_path)

        safe_store_call(fn ->
          Cortex.Store.upsert_internal_team_run(%{
            run_id: run_id,
            team_name: "coordinator",
            role: "Mesh Coordinator",
            tier: -1,
            internal: true,
            status: "running",
            prompt: prompt,
            log_path: log_path,
            started_at: DateTime.utc_now()
          })
        end)

        spawn_coordinator_task(run_id, prompt, log_path, workspace_path, callbacks)

        entry = %{
          team: "system",
          text: "Starting mesh coordinator agent...",
          kind: :resume,
          at: format_now()
        }

        {:noreply,
         socket
         |> assign(
           coordinator_alive: true,
           activities: prepend_activity(socket.assigns.activities, entry)
         )
         |> put_flash(:info, "Mesh coordinator agent started")}

      {:error, _errors} ->
        {:noreply, put_flash(socket, :error, "Failed to parse mesh config")}
    end
  end

  defp start_dag_coordinator(socket, run) do
    with {:ok, config, _warnings} <- ConfigLoader.load_string(run.config_yaml),
         {:ok, tiers} <- DAG.build_tiers(config.teams) do
      do_start_coordinator(socket, run, config, tiers)
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to parse config or build DAG")}
    end
  end

  defp do_start_coordinator(socket, run, config, tiers) do
    workspace_path = run.workspace_path
    cortex_path = Path.join(workspace_path, ".cortex")
    run_id = run.id

    InboxBridge.setup(workspace_path, ["coordinator"])

    prompt = Injection.build_coordinator_prompt(config, tiers, cortex_path)
    log_path = Path.join([cortex_path, "logs", "coordinator.log"])

    callbacks = build_coordinator_callbacks(run_id, cortex_path)

    safe_store_call(fn ->
      Cortex.Store.upsert_internal_team_run(%{
        run_id: run_id,
        team_name: "coordinator",
        role: "Runtime Coordinator",
        tier: -1,
        internal: true,
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
     |> assign(
       coordinator_alive: true,
       activities: prepend_activity(socket.assigns.activities, entry)
     )
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
      Registry.register(
        Cortex.Orchestration.RunnerRegistry,
        {:coordinator, run_id},
        %{started_at: DateTime.utc_now()}
      )

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

  defp persist_agent_job_result(run_id, team_name, result) do
    status =
      case result do
        {:ok, _} -> "completed"
        {:error, _} -> "failed"
      end

    safe_store_call(fn ->
      # Find the most recent running job of this type for this run
      import Ecto.Query

      case Cortex.Repo.one(
             from(tr in Cortex.Store.Schemas.TeamRun,
               where:
                 tr.run_id == ^run_id and tr.team_name == ^team_name and tr.status == "running",
               order_by: [desc: tr.started_at],
               limit: 1
             )
           ) do
        %{} = tr ->
          Cortex.Store.update_team_run(tr, %{status: status, completed_at: DateTime.utc_now()})

        nil ->
          :ok
      end
    end)
  end

  defp kill_all_processes(workspace_path) do
    case read_registry_teams(workspace_path) do
      {:ok, teams} ->
        teams
        |> Enum.map(&Map.get(&1, "pid"))
        |> Enum.filter(&(is_integer(&1) and &1 > 0))
        |> Enum.count(&kill_pid/1)

      :error ->
        0
    end
  rescue
    _ -> 0
  end

  defp kill_pid(pid) do
    case System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp stop_coordinator_process(run_id) do
    case Registry.lookup(Cortex.Orchestration.RunnerRegistry, {:coordinator, run_id}) do
      [{pid, _}] ->
        Process.exit(pid, :shutdown)
        1

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp kill_coordinator_os_pid(nil), do: :ok

  defp kill_coordinator_os_pid(workspace_path) do
    pids = coordinator_os_pids(workspace_path)
    Enum.each(pids, &kill_pid/1)
  end

  defp coordinator_os_pids(workspace_path) do
    case read_registry_teams(workspace_path) do
      {:ok, teams} ->
        teams
        |> Enum.filter(fn t -> Map.get(t, "name") == "coordinator" end)
        |> Enum.map(fn t -> Map.get(t, "pid") end)
        |> Enum.filter(fn pid -> is_integer(pid) and pid > 0 end)

      _ ->
        []
    end
  end

  defp mark_coordinator_stopped(run_id) do
    safe_store_call(fn ->
      run_id
      |> Cortex.Store.get_team_runs()
      |> Enum.find(&(&1.team_name == "coordinator" and &1.status == "running"))
      |> case do
        %{} = tr ->
          Cortex.Store.update_team_run(tr, %{status: "stopped", completed_at: DateTime.utc_now()})

        _ ->
          :ok
      end
    end)
  end

  defp mark_run_stopped(run) do
    safe_store_call(fn ->
      # Mark all running team_runs as stopped
      team_runs = Cortex.Store.get_team_runs(run.id)

      for tr <- team_runs, tr.status == "running" do
        Cortex.Store.update_team_run(tr, %{status: "stopped", completed_at: DateTime.utc_now()})
      end

      # Mark the run itself as stopped
      Cortex.Store.update_run(run, %{status: "stopped"})
    end)
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

  defp visible_tabs(run) do
    mode_tab =
      cond do
        gossip?(run) -> ["knowledge"]
        mesh?(run) -> ["membership"]
        true -> ["graph"]
      end

    ["overview"] ++
      mode_tab ++ ["activity", "messages", "logs", "summaries", "diagnostics", "jobs", "settings"]
  end

  defp tab_label("overview", _assigns), do: "Overview"

  defp tab_label("activity", assigns) do
    count = length(assigns.activities)
    if count > 0, do: "Activity (#{count})", else: "Activity"
  end

  defp tab_label("messages", _assigns), do: "Messages"
  defp tab_label("logs", _assigns), do: "Logs"
  defp tab_label("diagnostics", _assigns), do: "Diagnostics"

  defp tab_label("jobs", _assigns), do: "Jobs"

  defp tab_label(tab, _assigns), do: String.capitalize(tab)

  # -- Stalled detection (Priority 3) --

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

      completed =
        team_runs
        |> Enum.filter(&(&1.status in ["completed", "done"]))
        |> MapSet.new(& &1.team_name)

      config_names
      |> MapSet.difference(existing_names)
      |> MapSet.difference(completed)
      |> MapSet.to_list()
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

  defp read_coordinator_log(run) do
    read_team_log(run, "coordinator")
  end

  defp read_summary_file(_run, nil, fallback), do: fallback

  defp read_summary_file(run, filename, fallback) do
    path = Path.join([run.workspace_path, ".cortex", "summaries", filename])

    case File.read(path) do
      {:ok, data} -> %{name: filename, content: data}
      _ -> fallback
    end
  end

  defp get_run_jobs(run) do
    if run do
      run.id
      |> safe_get_team_runs()
      |> Enum.filter(& &1.internal)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
    else
      []
    end
  rescue
    _ -> []
  end

  @max_job_log_lines 200

  defp parse_run_job_log(log_path) do
    case File.read(log_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(-@max_job_log_lines)
        |> Enum.map(&classify_log_line/1)

      _ ->
        nil
    end
  end

  defp classify_log_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type}} -> %{type: type, text: line}
      _ -> %{type: nil, text: line}
    end
  end

  defp lookup_internal_tokens(run, team_name) do
    if run do
      case Cortex.Store.get_team_run(run.id, team_name) do
        %{input_tokens: input, output_tokens: output}
        when not is_nil(input) or not is_nil(output) ->
          %{input: input || 0, output: output || 0}

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp has_running_summary_job?(jobs) do
    Enum.any?(jobs, fn j -> j.status == :running end)
  end

  defp update_summary_job(jobs, job_id, status, error \\ nil, tokens \\ nil) do
    Enum.map(jobs, fn j ->
      if j.id == job_id do
        apply_job_update(j, status, error, tokens)
      else
        j
      end
    end)
  end

  defp apply_job_update(job, status, error, nil) do
    %{job | status: status, error: error}
  end

  defp apply_job_update(job, status, error, tokens) do
    %{
      job
      | status: status,
        error: error,
        input_tokens: tokens.input,
        output_tokens: tokens.output
    }
  end

  defp read_coordinator_summaries(run) do
    if run && run.workspace_path do
      dir = Path.join([run.workspace_path, ".cortex", "summaries"])

      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.sort(:desc)

        _ ->
          []
      end
    else
      []
    end
  end

  defp read_debug_reports(run) do
    if run && run.workspace_path do
      dir = Path.join([run.workspace_path, ".cortex", "debug"])

      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.sort(:desc)

        _ ->
          []
      end
    else
      []
    end
  end

  defp read_debug_file(run, filename) do
    if run && run.workspace_path do
      path = Path.join([run.workspace_path, ".cortex", "debug", filename])

      case File.read(path) do
        {:ok, data} -> %{name: filename, content: data}
        _ -> nil
      end
    else
      nil
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

  defp sort_log_lines(nil, _sort), do: nil

  defp sort_log_lines(lines, :desc), do: Enum.sort_by(lines, & &1.num, :desc)
  defp sort_log_lines(lines, :asc), do: Enum.sort_by(lines, & &1.num, :asc)

  defp read_team_inbox(run, team_name) do
    if run && run.workspace_path do
      case InboxBridge.read_inbox(run.workspace_path, team_name) do
        {:ok, messages} -> messages
        _ -> []
      end
    else
      []
    end
  end

  # -- General helpers --

  defp run_title(run), do: run.name || "Untitled Run"

  defp prepend_activity(activities, entry) do
    [entry | activities] |> Enum.take(@max_activities)
  end

  defp format_now do
    DateTime.utc_now() |> Calendar.strftime("%H:%M:%S")
  end

  defp gossip?(run), do: run.mode == "gossip"
  defp mesh?(run), do: run.mode == "mesh"

  defp reconstruct_gossip_round(run) do
    if run.mode == "gossip" and run.gossip_rounds_total > 0 do
      %{current: run.gossip_rounds_completed || 0, total: run.gossip_rounds_total}
    else
      nil
    end
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

    total_input = Enum.map(team_runs, &total_input/1) |> Enum.sum()
    total_output = sum_team_tokens(team_runs, :output_tokens)

    team_lines =
      team_runs
      |> Enum.sort_by(&{&1.tier || 0, &1.team_name})
      |> Enum.map(&format_team_summary_line(&1, run, last_seen, include_diagnostics))

    [
      "=== #{run.name || "Untitled"} ===",
      "Status: #{run.status} | Wall clock: #{wall_clock}",
      "Tokens: #{format_token_count(total_input)} in / #{format_token_count(total_output)} out",
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
    diag = format_team_diag_summary(tr, run, status, include_diagnostics)
    result = format_team_result_snippet(tr)

    "  [T#{tr.tier || 0}] #{tr.team_name}: #{status}#{health}#{tokens}#{diag}#{result}"
  end

  defp format_team_token_summary(tr) do
    if tr.input_tokens || tr.output_tokens do
      " | #{format_token_count(total_input(tr))} in / #{format_token_count(tr.output_tokens || 0)} out"
    else
      ""
    end
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
        %{
          team: change.team,
          text: "#{change.from} -> #{change.to}: #{change.detail}",
          kind: :resume,
          at: format_now()
        }
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
        %{
          tr
          | input_tokens: payload.input_tokens,
            output_tokens: payload.output_tokens,
            cache_read_tokens: Map.get(payload, :cache_read_tokens, tr.cache_read_tokens),
            cache_creation_tokens:
              Map.get(payload, :cache_creation_tokens, tr.cache_creation_tokens)
        }
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

  # Total input tokens including cache (the actual API consumption)
  defp total_input(team_run) do
    (team_run.input_tokens || 0) + (team_run.cache_read_tokens || 0) +
      (team_run.cache_creation_tokens || 0)
  end
end
