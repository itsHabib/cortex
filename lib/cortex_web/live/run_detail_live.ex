defmodule CortexWeb.RunDetailLive do
  use CortexWeb, :live_view

  import CortexWeb.DAGComponents

  alias Cortex.Orchestration.DAG

  @max_activities 150
  @stale_threshold_seconds 600
  @max_log_lines 500

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
           log_content: nil,
           messages_team: nil,
           team_inbox: [],
           team_outbox: []
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
           page_title: "Run: #{run.name}",
           current_tab: "overview",
           last_seen: %{},
           selected_log_team: nil,
           log_content: nil,
           messages_team: nil,
           team_inbox: [],
           team_outbox: []
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

  # -- Event handlers: live token updates (+ last_seen tracking) --

  def handle_info(%{type: :team_tokens_updated, payload: payload}, socket) do
    run = socket.assigns.run

    if run && Map.get(payload, :run_id) == run.id do
      team_name = payload.team_name
      last_seen = Map.put(socket.assigns.last_seen, team_name, DateTime.utc_now())

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

      {:noreply, assign(socket, team_runs: team_runs, run: updated_run, last_seen: last_seen)}
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
      tool_str = Enum.join(tools, ", ")

      entry = %{
        team: team_name,
        text: "using #{tool_str}",
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Event handlers: tab switching --

  @impl true
  def handle_event("switch_tab", %{"tab" => "logs"}, socket) do
    socket =
      cond do
        socket.assigns.selected_log_team ->
          log_content = read_team_log(socket.assigns.run, socket.assigns.selected_log_team)
          assign(socket, log_content: log_content)

        socket.assigns.team_names != [] ->
          first = hd(socket.assigns.team_names)
          log_content = read_team_log(socket.assigns.run, first)
          assign(socket, selected_log_team: first, log_content: log_content)

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

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, current_tab: tab)}
  end

  # -- Event handlers: log team selection --

  def handle_event("select_log_team", %{"team" => ""}, socket) do
    {:noreply, assign(socket, selected_log_team: nil, log_content: nil)}
  end

  def handle_event("select_log_team", %{"team" => team_name}, socket) do
    log_content = read_team_log(socket.assigns.run, team_name)
    {:noreply, assign(socket, selected_log_team: team_name, log_content: log_content)}
  end

  def handle_event("refresh_logs", _params, socket) do
    if socket.assigns.selected_log_team do
      log_content = read_team_log(socket.assigns.run, socket.assigns.selected_log_team)
      {:noreply, assign(socket, log_content: log_content)}
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

        # Refresh messages if viewing this team
        socket =
          if socket.assigns.messages_team == to do
            {inbox, outbox} = read_team_messages(run, to)

            assign(socket,
              activities: activities,
              msg_content: "",
              team_inbox: inbox,
              team_outbox: outbox
            )
          else
            assign(socket, activities: activities, msg_content: "")
          end

        {:noreply, socket |> put_flash(:info, "Message sent to #{to}")}
      else
        {:noreply, put_flash(socket, :error, "No workspace path -- cannot send messages")}
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
        text: "Resuming stalled teams at #{workspace_path}...",
        kind: :resume,
        at: format_now()
      }

      socket = assign(socket, activities: prepend_activity(socket.assigns.activities, entry))

      # Capture run.id for closure
      run_id = run.id

      # Run resume in a background task so LiveView stays responsive
      Task.start(fn ->
        case Cortex.Orchestration.Runner.resume_run(workspace_path) do
          {:ok, results} ->
            # Broadcast per-team results
            Enum.each(results, fn {team_name, result} ->
              {status, reason} = classify_resume_result(result)

              Cortex.Events.broadcast(:team_resume_result, %{
                run_id: run_id,
                team_name: team_name,
                status: status,
                reason: reason
              })
            end)

            # Signal all resumes done
            Cortex.Events.broadcast(:run_resumed, %{run_id: run_id})

          {:error, reason} ->
            Cortex.Events.broadcast(:team_resume_result, %{
              run_id: run_id,
              team_name: "system",
              status: :failure,
              reason: inspect(reason)
            })
        end
      end)

      {:noreply, put_flash(socket, :info, "Resuming stalled teams...")}
    else
      {:noreply, put_flash(socket, :error, "No workspace path -- cannot resume")}
    end
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

      <!-- Resume Banner (visible across all tabs when stalled teams detected) -->
      <%= if has_stalled_teams?(@team_runs, @run.status, @last_seen) do %>
        <div class="bg-yellow-900/30 border border-yellow-800 rounded-lg p-4 mb-6">
          <div class="flex items-center justify-between mb-2">
            <div>
              <p class="text-yellow-300 font-medium">Stalled teams detected</p>
              <p class="text-yellow-200/70 text-sm">
                {count_stalled(@team_runs, @last_seen)} team(s) show as "running" but have not sent events in over 10 minutes. You can resume their sessions.
              </p>
            </div>
            <button
              phx-click="resume_dead_teams"
              class="rounded bg-yellow-600 px-4 py-2 text-sm font-medium text-white hover:bg-yellow-500 shrink-0"
            >
              Resume Stalled Teams
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

      <!-- Tab Bar -->
      <div class="flex border-b border-gray-800 mb-6">
        <button
          :for={tab <- ~w(overview activity messages logs)}
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
        <!-- Status Summary -->
        <div class="grid grid-cols-2 md:grid-cols-5 gap-3 mb-6">
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-3 text-center">
            <p class="text-xs text-gray-500 uppercase">Pending</p>
            <p class="text-lg font-bold text-gray-400">{count_by_status(@team_runs, "pending")}</p>
          </div>
          <div class="bg-gray-900 rounded-lg border border-blue-900 p-3 text-center">
            <p class="text-xs text-blue-400 uppercase">Running</p>
            <p class="text-lg font-bold text-blue-300">{count_active_running(@team_runs, @last_seen)}</p>
          </div>
          <div class="bg-gray-900 rounded-lg border border-yellow-900 p-3 text-center">
            <p class="text-xs text-yellow-400 uppercase">Stalled</p>
            <p class="text-lg font-bold text-yellow-300">{count_stalled(@team_runs, @last_seen)}</p>
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
                <.status_badge status={display_status(team, @last_seen)} />
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
            <p class="text-gray-500 text-sm">No activity yet. Events will appear here in real-time.</p>
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
                  <option :for={name <- @team_names} value={name} selected={name == @selected_log_team}>
                    {name}
                  </option>
                </select>
              </form>
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
                  {@selected_log_team}.log
                </h2>
                <span :if={@log_content} class="text-xs text-gray-600">
                  {length(String.split(@log_content, "\n"))} lines (last {@max_log_lines})
                </span>
              </div>
              <%= if @log_content do %>
                <pre class="bg-gray-950 rounded p-4 text-xs text-gray-400 font-mono overflow-x-auto max-h-[75vh] overflow-y-auto whitespace-pre-wrap break-all"><%= @log_content %></pre>
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

  # -- Tab helpers --

  defp tab_label("overview", _assigns), do: "Overview"

  defp tab_label("activity", assigns) do
    count = length(assigns.activities)
    if count > 0, do: "Activity (#{count})", else: "Activity"
  end

  defp tab_label("messages", _assigns), do: "Messages"
  defp tab_label("logs", _assigns), do: "Logs"
  defp tab_label(tab, _assigns), do: String.capitalize(tab)

  # -- Stalled detection (Priority 3) --

  defp has_stalled_teams?(team_runs, run_status, last_seen) do
    run_status in ["running", "failed"] and
      Enum.any?(team_runs, fn tr -> team_stalled?(tr, last_seen) end)
  end

  defp team_stalled?(team_run, last_seen) do
    (team_run.status || "pending") == "running" and
      case Map.get(last_seen, team_run.team_name) do
        nil -> true
        ts -> DateTime.diff(DateTime.utc_now(), ts, :second) > @stale_threshold_seconds
      end
  end

  defp display_status(team, last_seen) do
    raw = team.status || "pending"

    if raw == "running" and team_stalled?(team, last_seen) do
      "stalled"
    else
      raw
    end
  end

  defp count_stalled(team_runs, last_seen) do
    Enum.count(team_runs, fn tr -> team_stalled?(tr, last_seen) end)
  end

  defp count_active_running(team_runs, last_seen) do
    Enum.count(team_runs, fn tr ->
      (tr.status || "pending") == "running" and not team_stalled?(tr, last_seen)
    end)
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

      case File.read(log_path) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.take(-@max_log_lines)
          |> Enum.join("\n")

        {:error, _} ->
          nil
      end
    end
  end

  defp read_team_messages(run, team_name) do
    if run && run.workspace_path do
      inbox =
        case Cortex.Messaging.InboxBridge.read_inbox(run.workspace_path, team_name) do
          {:ok, messages} -> messages
          _ -> []
        end

      outbox =
        case Cortex.Messaging.InboxBridge.read_outbox(run.workspace_path, team_name) do
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
end
