defmodule CortexWeb.TeamDetailLive do
  use CortexWeb, :live_view

  alias Cortex.Orchestration.LogParser
  alias Cortex.Orchestration.Spawner

  @max_log_lines 500

  @impl true
  def mount(%{"id" => run_id, "name" => team_name}, _session, socket) do
    if connected?(socket), do: safe_subscribe()

    run = safe_get_run(run_id)
    team_run = safe_get_team_run(run_id, team_name)

    team_config = extract_team_config(run, team_name)
    team_members = extract_members(run, team_name)
    log_lines = parse_log(team_run)

    diagnostics = load_diagnostics(run, team_run)

    {:ok,
     assign(socket,
       run: run,
       run_id: run_id,
       team_name: team_name,
       team_run: team_run,
       team_config: team_config,
       team_members: team_members,
       log_lines: log_lines,
       log_sort: :desc,
       expanded_logs: MapSet.new(),
       active_tab: "result",
       page_title: "Team: #{team_name}",
       diagnostics: diagnostics
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
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

  def handle_event("toggle_log_sort", _params, socket) do
    new_sort = if socket.assigns.log_sort == :asc, do: :desc, else: :asc

    sorted =
      if socket.assigns.log_lines do
        sort_log_lines(socket.assigns.log_lines, new_sort)
      end

    {:noreply, assign(socket, log_sort: new_sort, log_lines: sorted, expanded_logs: MapSet.new())}
  end

  def handle_event("refresh_logs", _params, socket) do
    team_run = safe_get_team_run(socket.assigns.run_id, socket.assigns.team_name)
    log_lines = parse_log(team_run)
    sorted = sort_log_lines(log_lines, socket.assigns.log_sort)
    {:noreply, assign(socket, log_lines: sorted, expanded_logs: MapSet.new())}
  end

  def handle_event("resume_team", _params, socket) do
    run = socket.assigns.run
    team_name = socket.assigns.team_name
    workspace_path = run && run.workspace_path

    if workspace_path do
      spawn_resume_task(run.id, team_name, workspace_path)
      {:noreply, put_flash(socket, :info, "Resuming #{team_name}...")}
    else
      {:noreply, put_flash(socket, :error, "No workspace path — cannot resume")}
    end
  end

  def handle_event("mark_failed", _params, socket) do
    team_run = socket.assigns.team_run

    if team_run do
      case Cortex.Store.update_team_run(team_run, %{
             status: "failed",
             result_summary: "Manually marked as failed — session died without completing",
             completed_at: DateTime.utc_now()
           }) do
        {:ok, updated} ->
          diagnostics = load_diagnostics(socket.assigns.run, updated)

          {:noreply,
           socket
           |> assign(team_run: updated, diagnostics: diagnostics)
           |> put_flash(:info, "Team marked as failed")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update team status")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("restart_team", _params, socket) do
    run = socket.assigns.run
    team_name = socket.assigns.team_name
    team_run = socket.assigns.team_run
    workspace_path = run && run.workspace_path

    if workspace_path && team_run && team_run.prompt do
      {socket, enriched_prompt, log_path} = prepare_restart(socket, team_run, team_name, workspace_path)
      spawn_restart_task(run.id, team_run.id, team_name, enriched_prompt, log_path, workspace_path)
      {:noreply, put_flash(socket, :info, "Restarting #{team_name} with fresh session...")}
    else
      {:noreply, put_flash(socket, :error, "No prompt or workspace path — cannot restart")}
    end
  end

  @impl true
  def handle_info(%{type: type, payload: _payload}, socket)
      when type in [:team_completed, :tier_completed, :run_completed, :run_resumed] do
    team_run = safe_get_team_run(socket.assigns.run_id, socket.assigns.team_name)
    log_lines = parse_log(team_run)
    sorted = sort_log_lines(log_lines, socket.assigns.log_sort)
    run = safe_get_run(socket.assigns.run_id)
    diagnostics = load_diagnostics(run, team_run)

    {:noreply,
     assign(socket, team_run: team_run, log_lines: sorted, run: run, diagnostics: diagnostics)}
  end

  def handle_info(%{type: :team_resume_result, payload: payload}, socket) do
    if payload.team_name == socket.assigns.team_name do
      {:noreply,
       put_flash(socket, :info, "Resume #{payload.status}: #{Map.get(payload, :reason, "")}")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@team_name}
      <:subtitle>
        <%= if @team_run do %>
          <.status_badge status={@team_run.status || "pending"} />
          <span :if={@team_run.role} class="ml-2 text-gray-400">{@team_run.role}</span>
          <span class="ml-2 text-gray-400"><.token_display input={team_input_tokens(@team_run)} output={team_output_tokens(@team_run)} /></span>
          <span class="ml-2 text-gray-400"><.duration_display ms={team_duration(@team_run)} /></span>
        <% else %>
          <span class="text-gray-400">Team not found in this run</span>
        <% end %>
      </:subtitle>
      <:actions>
        <a href={"/runs/#{@run_id}"} class="text-sm text-gray-400 hover:text-white">Back to Run</a>
      </:actions>
    </.header>

    <!-- Mark Failed button (only for actively running teams — separate from diagnostics) -->
    <%= if @team_run && (@team_run.status || "pending") == "running" do %>
      <div class="flex items-center justify-end mb-4">
        <button
          phx-click="mark_failed"
          data-confirm="Mark this team as failed?"
          class="rounded bg-red-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-600"
          title="Update DB status to failed"
        >
          Mark Failed
        </button>
      </div>
    <% end %>

    <!-- Diagnostics Banner (only for failed/completed teams — not while actively running) -->
    <%= if @team_run && (@team_run.status || "pending") == "failed" && @diagnostics && @diagnostics.session_id do %>
      <div class={[
        "rounded-lg border p-4 mb-6",
        if(@diagnostics.has_result, do: "bg-gray-900 border-gray-800", else: "bg-yellow-900/30 border-yellow-800")
      ]}>
        <div class="flex items-center justify-between">
          <div>
            <p class={if(@diagnostics.has_result, do: "text-gray-300 font-medium", else: "text-yellow-300 font-medium")}>
              {@diagnostics.diagnosis_detail}
            </p>
            <p :if={@diagnostics.session_id} class="text-sm text-gray-400 mt-1">
              Session: <code class="font-mono text-cortex-400">{@diagnostics.session_id}</code>
              <%= if @diagnostics.total_input_tokens > 0 do %>
                | Tokens: {format_token_count(@diagnostics.total_input_tokens)} in / {format_token_count(@diagnostics.total_output_tokens)} out
              <% end %>
            </p>
            <p :if={@diagnostics.diagnosis not in [:completed]} class="text-xs text-gray-500 mt-1">
              <%= if not @diagnostics.has_result do %>
                <strong>Resume</strong> continues the existing session.
                <strong>Restart</strong> starts fresh with context from previous progress.
                If the session expired, Resume will fail — use Restart instead.
              <% else %>
                Session ended with an error. <strong>Restart</strong> starts fresh with context from previous progress.
              <% end %>
            </p>
          </div>
          <div :if={@diagnostics.diagnosis not in [:completed]} class="flex items-center gap-2">
            <button
              :if={not @diagnostics.has_result}
              phx-click="resume_team"
              class="rounded bg-cortex-600 px-4 py-2 text-sm font-medium text-white hover:bg-cortex-500 shrink-0"
            >
              Resume
            </button>
            <button
              phx-click="restart_team"
              class="rounded bg-yellow-600 px-4 py-2 text-sm font-medium text-white hover:bg-yellow-500 shrink-0"
              title="Start fresh session with context from previous run"
            >
              Restart
            </button>
          </div>
        </div>
      </div>
    <% end %>

    <!-- Team Members -->
    <div :if={@team_members != []} class="mb-6 bg-gray-900 rounded-lg border border-gray-800 p-4">
      <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Team Members</h3>
      <div class="space-y-2">
        <div :for={member <- @team_members} class="flex items-start gap-3">
          <span class="inline-flex items-center rounded bg-cortex-900 px-2 py-0.5 text-xs font-medium text-cortex-300 shrink-0">
            {member.role}
          </span>
          <span :if={member.focus} class="text-sm text-gray-400">{member.focus}</span>
        </div>
      </div>
    </div>

    <!-- Tabs -->
    <div class="flex border-b border-gray-800 mb-6">
      <button
        :for={tab <- ~w(result log config prompt)}
        phx-click="switch_tab"
        phx-value-tab={tab}
        class={[
          "px-4 py-2 text-sm font-medium border-b-2 transition-colors",
          if(@active_tab == tab,
            do: "text-cortex-400 border-cortex-400",
            else: "text-gray-400 border-transparent hover:text-gray-200 hover:border-gray-600"
          )
        ]}
      >
        {tab_label(tab, assigns)}
      </button>
    </div>

    <!-- Tab Content -->
    <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
      <%= case @active_tab do %>
        <% "result" -> %>
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Result Summary</h3>
          <%= if @team_run && @team_run.result_summary do %>
            <div class="prose prose-invert max-w-none">
              <pre class="whitespace-pre-wrap text-sm text-gray-300 font-sans">{@team_run.result_summary}</pre>
            </div>
          <% else %>
            <p class="text-gray-500">No result summary available.</p>
          <% end %>

        <% "log" -> %>
          <div class="flex items-center justify-between mb-3">
            <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Log Output</h3>
            <div class="flex items-center gap-2">
              <span :if={@log_lines} class="text-xs text-gray-600">
                {length(@log_lines)} lines
              </span>
              <button
                phx-click="toggle_log_sort"
                class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
              >
                {if @log_sort == :desc, do: "Newest first ↓", else: "Oldest first ↑"}
              </button>
              <button
                phx-click="refresh_logs"
                class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
              >
                Refresh
              </button>
            </div>
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
            <p class="text-gray-500">No log file available.</p>
          <% end %>

        <% "config" -> %>
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Team Configuration</h3>
          <%= if @team_config do %>
            <pre class="bg-gray-950 rounded p-4 text-xs text-gray-300 font-mono overflow-auto max-h-96">{@team_config}</pre>
          <% else %>
            <p class="text-gray-500">No configuration available.</p>
          <% end %>

        <% "prompt" -> %>
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Prompt</h3>
          <%= if @team_run && @team_run.prompt do %>
            <pre class="bg-gray-950 rounded p-4 text-xs text-gray-300 font-mono overflow-auto max-h-96 whitespace-pre-wrap">{@team_run.prompt}</pre>
          <% else %>
            <p class="text-gray-500">No prompt available.</p>
          <% end %>

        <% _ -> %>
          <p class="text-gray-500">Unknown tab.</p>
      <% end %>
    </div>
    """
  end

  # -- Private helpers --

  defp safe_get_run(id) do
    Cortex.Store.get_run(id)
  rescue
    _ -> nil
  end

  defp safe_get_team_run(run_id, team_name) do
    Cortex.Store.get_team_run(run_id, team_name)
  rescue
    _ -> nil
  end

  defp safe_subscribe do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp team_input_tokens(nil), do: nil
  defp team_input_tokens(team_run), do: team_run.input_tokens

  defp team_output_tokens(nil), do: nil
  defp team_output_tokens(team_run), do: team_run.output_tokens

  defp team_duration(nil), do: nil
  defp team_duration(team_run), do: team_run.duration_ms

  defp tab_label("log", assigns) do
    if assigns.log_lines, do: "Log (#{length(assigns.log_lines)})", else: "Log"
  end

  defp tab_label(tab, _assigns), do: String.capitalize(tab)

  defp spawn_resume_task(run_id, team_name, workspace_path) do
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

  defp prepare_restart(socket, team_run, team_name, workspace_path) do
    log_path = Path.join([workspace_path, ".cortex", "logs", "#{team_name}.log"])

    restart_context =
      case LogParser.parse(log_path) do
        {:ok, report} -> LogParser.build_restart_context(report)
        _ -> ""
      end

    enriched_prompt = team_run.prompt <> "\n\n" <> restart_context
    updated_team_run = mark_team_run_restarting(team_run.id, enriched_prompt, team_run)
    {assign(socket, team_run: updated_team_run), enriched_prompt, log_path}
  end

  defp mark_team_run_restarting(team_run_id, prompt, fallback) do
    case Cortex.Repo.get(Cortex.Store.Schemas.TeamRun, team_run_id) do
      nil ->
        fallback

      fresh ->
        case Cortex.Store.update_team_run(fresh, %{
               status: "running",
               prompt: prompt,
               started_at: DateTime.utc_now(),
               completed_at: nil,
               result_summary: nil,
               session_id: nil
             }) do
          {:ok, updated} -> updated
          _ -> fresh
        end
    end
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

      persist_restart_result(team_run_id, result)
      broadcast_restart_result(run_id, team_name, result)
    end)
  end

  defp broadcast_restart_result(run_id, team_name, result) do
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

  defp extract_team_config(nil, _team_name), do: nil

  defp extract_team_config(run, team_name) do
    with yaml when is_binary(yaml) <- run.config_yaml,
         {:ok, raw} <- YamlElixir.read_from_string(yaml),
         %{} = team_map <- find_team(raw, team_name) do
      Jason.encode!(team_map, pretty: true)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_members(nil, _team_name), do: []

  defp extract_members(run, team_name) do
    with yaml when is_binary(yaml) <- run.config_yaml,
         {:ok, raw} <- YamlElixir.read_from_string(yaml),
         %{} = team_map <- find_team(raw, team_name) do
      (Map.get(team_map, "members") || [])
      |> Enum.map(fn m -> %{role: Map.get(m, "role", ""), focus: Map.get(m, "focus")} end)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp find_team(raw, team_name) do
    raw
    |> Map.get("teams", [])
    |> Enum.find(fn t -> Map.get(t, "name") == team_name end)
  end

  # -- Log parsing (same as run_detail_live) --

  defp parse_log(nil), do: nil

  defp parse_log(team_run) do
    if team_run.log_path && File.exists?(team_run.log_path) do
      parse_log_file(team_run.log_path)
    end
  rescue
    _ -> nil
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
        |> sort_log_lines(:desc)

      {:error, _} ->
        nil
    end
  end

  defp build_log_entry({line, idx}) do
    {type, parsed} = parse_log_line(line)
    %{raw: line, type: type, parsed: parsed, num: idx}
  end

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

  defp log_type_class("assistant"), do: "bg-blue-900/50 text-blue-300"
  defp log_type_class("system"), do: "bg-purple-900/50 text-purple-300"
  defp log_type_class("result"), do: "bg-cyan-900/50 text-cyan-300"
  defp log_type_class("error"), do: "bg-red-900/50 text-red-300"
  defp log_type_class("tool_use"), do: "bg-green-900/50 text-green-300"
  defp log_type_class("tool_result"), do: "bg-emerald-900/50 text-emerald-300"
  defp log_type_class(_), do: "bg-gray-800/50 text-gray-400"

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

  # -- Diagnostics --

  defp load_diagnostics(run, team_run) do
    if run && run.workspace_path && team_run && team_run.log_path do
      case LogParser.parse(team_run.log_path) do
        {:ok, report} -> report
        {:error, _} -> nil
      end
    end
  end

  defp persist_restart_result(team_run_id, result) do
    case Cortex.Repo.get(Cortex.Store.Schemas.TeamRun, team_run_id) do
      nil ->
        :ok

      team_run ->
        attrs =
          case result do
            {:ok, %{status: :success} = tr} ->
              %{
                status: "completed",
                session_id: tr.session_id,
                cost_usd: tr.cost_usd,
                input_tokens: tr.input_tokens,
                output_tokens: tr.output_tokens,
                cache_read_tokens: tr.cache_read_tokens,
                cache_creation_tokens: tr.cache_creation_tokens,
                duration_ms: tr.duration_ms,
                num_turns: tr.num_turns,
                result_summary: truncate_summary(tr.result),
                completed_at: DateTime.utc_now()
              }

            {:ok, tr} ->
              %{
                status: "failed",
                session_id: tr.session_id,
                cost_usd: tr.cost_usd,
                input_tokens: tr.input_tokens,
                output_tokens: tr.output_tokens,
                duration_ms: tr.duration_ms,
                result_summary: truncate_summary(tr.result),
                completed_at: DateTime.utc_now()
              }

            {:error, reason} ->
              %{
                status: "failed",
                result_summary: "Restart error: #{inspect(reason)}",
                completed_at: DateTime.utc_now()
              }
          end

        Cortex.Store.update_team_run(team_run, attrs)
    end
  rescue
    _ -> :ok
  end

  defp truncate_summary(nil), do: nil

  defp truncate_summary(text) when is_binary(text) do
    if String.length(text) > 2000, do: String.slice(text, 0, 2000) <> "...", else: text
  end

  defp truncate_summary(other), do: inspect(other) |> truncate_summary()

  defp format_token_count(nil), do: "0"
  defp format_token_count(0), do: "0"
  defp format_token_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_token_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_token_count(n), do: to_string(n)
end
