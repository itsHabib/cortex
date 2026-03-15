defmodule CortexWeb.TeamDetailLive do
  use CortexWeb, :live_view

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
      run_id = run.id

      Task.start(fn ->
        log_path = Path.join([workspace_path, ".cortex", "logs", "#{team_name}.log"])

        session_id =
          case Cortex.Orchestration.Spawner.extract_session_id_from_log(log_path) do
            {:ok, sid} -> sid
            :error -> nil
          end

        {status, reason} =
          if session_id do
            case Cortex.Orchestration.Spawner.resume(
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
          else
            {:no_session_id, "no session_id found in logs"}
          end

        Cortex.Events.broadcast(:team_resume_result, %{
          run_id: run_id,
          team_name: team_name,
          status: status,
          reason: reason
        })

        Cortex.Events.broadcast(:run_resumed, %{run_id: run_id})
      end)

      {:noreply, put_flash(socket, :info, "Resuming #{team_name}...")}
    else
      {:noreply, put_flash(socket, :error, "No workspace path — cannot resume")}
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

    <!-- Resume Banner (for stalled/running teams with a session to resume) -->
    <%= if @team_run && (@team_run.status || "pending") == "running" && @diagnostics do %>
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
              <%= if @diagnostics.cost_usd do %>
                | Cost: ${Float.round(@diagnostics.cost_usd * 1.0, 4)}
              <% end %>
              <%= if @diagnostics.total_input_tokens > 0 do %>
                | Tokens: {format_token_count(@diagnostics.total_input_tokens)} in / {format_token_count(@diagnostics.total_output_tokens)} out
              <% end %>
            </p>
          </div>
          <button
            :if={@diagnostics.session_id && not @diagnostics.has_result}
            phx-click="resume_team"
            class="rounded bg-yellow-600 px-4 py-2 text-sm font-medium text-white hover:bg-yellow-500 shrink-0"
          >
            Resume {@team_name}
          </button>
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

  defp extract_team_config(nil, _team_name), do: nil

  defp extract_team_config(run, team_name) do
    if run.config_yaml do
      case YamlElixir.read_from_string(run.config_yaml) do
        {:ok, raw} ->
          teams = Map.get(raw, "teams", [])

          case Enum.find(teams, fn t -> Map.get(t, "name") == team_name end) do
            nil -> nil
            team_map -> Jason.encode!(team_map, pretty: true)
          end

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp extract_members(nil, _team_name), do: []

  defp extract_members(run, team_name) do
    if run.config_yaml do
      case YamlElixir.read_from_string(run.config_yaml) do
        {:ok, raw} ->
          teams = Map.get(raw, "teams", [])

          case Enum.find(teams, fn t -> Map.get(t, "name") == team_name end) do
            nil ->
              []

            team_map ->
              (Map.get(team_map, "members") || [])
              |> Enum.map(fn m ->
                %{role: Map.get(m, "role", ""), focus: Map.get(m, "focus")}
              end)
          end

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  # -- Log parsing (same as run_detail_live) --

  defp parse_log(nil), do: nil

  defp parse_log(team_run) do
    if team_run.log_path && File.exists?(team_run.log_path) do
      case File.read(team_run.log_path) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(-@max_log_lines)
          |> Enum.with_index(1)
          |> Enum.map(fn {line, idx} ->
            {type, parsed} = parse_log_line(line)
            %{raw: line, type: type, parsed: parsed, num: idx}
          end)
          |> sort_log_lines(:desc)

        {:error, _} ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
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
      case Cortex.Orchestration.LogParser.parse(team_run.log_path) do
        {:ok, report} -> report
        {:error, _} -> nil
      end
    end
  end

  defp format_token_count(nil), do: "0"
  defp format_token_count(0), do: "0"
  defp format_token_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_token_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_token_count(n), do: to_string(n)
end
