defmodule CortexWeb.RunDetail.OverviewTab do
  @moduledoc """
  Overview tab for RunDetailLive.

  Renders status cards, coordinator detail, mode-specific content
  (gossip knowledge, mesh membership, DAG graph), participant cards,
  and an activity feed. Stateless function component — receives all
  assigns from the parent LiveView.
  """
  use Phoenix.Component

  import CortexWeb.CoreComponents, only: []
  import CortexWeb.StatusComponents
  import CortexWeb.TokenComponents, except: [format_token_count: 1, format_number: 1]
  import CortexWeb.DAGComponents

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the overview tab content.
  """
  attr(:run, :map, required: true)
  attr(:team_runs, :list, required: true)
  attr(:tiers, :list, required: true)
  attr(:edges, :list, required: true)
  attr(:team_members, :map, required: true)
  attr(:last_seen, :map, required: true)
  attr(:pid_status, :map, required: true)
  attr(:coordinator_alive, :boolean, required: true)
  attr(:coordinator_expanded, :boolean, required: true)
  attr(:coordinator_log, :any, default: nil)
  attr(:coordinator_inbox, :list, default: [])
  attr(:activities, :list, required: true)
  attr(:expanded_activities, :any, required: true)
  attr(:gossip_round, :any, default: nil)
  attr(:gossip_knowledge, :any, default: nil)

  def overview_tab(assigns) do
    ~H"""
    <div>
      <%!-- Status Cards --%>
      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3 mb-6">
        <div
          phx-click="toggle_coordinator"
          class={[
            "bg-gray-900 rounded-lg border p-3 text-center cursor-pointer hover:bg-gray-800/50 transition-colors",
            if(@coordinator_alive, do: "border-green-900", else: "border-gray-800"),
            if(@coordinator_expanded, do: "ring-1 ring-cortex-500/30", else: "")
          ]}
        >
          <p class="text-xs text-gray-500 uppercase">Coordinator</p>
          <%= if @coordinator_alive do %>
            <p class="text-lg font-bold text-green-300">Alive</p>
            <button
              :if={@run}
              phx-click="stop_coordinator"
              class="mt-1 text-xs text-red-400 hover:text-red-300 underline"
            >
              Stop
            </button>
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
          <p class="text-xs text-gray-600 mt-1">{if @coordinator_expanded, do: "click to collapse", else: "click to expand"}</p>
        </div>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-3 text-center">
          <p class="text-xs text-gray-500 uppercase">Pending</p>
          <p class="text-lg font-bold text-gray-400">{Helpers.count_by_status(@team_runs, "pending")}</p>
        </div>
        <div class="bg-gray-900 rounded-lg border border-blue-900 p-3 text-center">
          <p class="text-xs text-blue-400 uppercase">Running</p>
          <p class="text-lg font-bold text-blue-300">{Helpers.count_active_running(@team_runs, @last_seen, @pid_status)}</p>
        </div>
        <div class="bg-gray-900 rounded-lg border border-yellow-900 p-3 text-center">
          <p class="text-xs text-yellow-400 uppercase">Stalled</p>
          <p class="text-lg font-bold text-yellow-300">{Helpers.count_stalled(@team_runs, @last_seen, @pid_status)}</p>
        </div>
        <div class="bg-gray-900 rounded-lg border border-green-900 p-3 text-center">
          <p class="text-xs text-green-400 uppercase">Done</p>
          <p class="text-lg font-bold text-green-300">{Helpers.count_by_status(@team_runs, ["completed", "done"])}</p>
        </div>
        <div class="bg-gray-900 rounded-lg border border-red-900 p-3 text-center">
          <p class="text-xs text-red-400 uppercase">Failed</p>
          <p class="text-lg font-bold text-red-300">{Helpers.count_by_status(@team_runs, "failed")}</p>
        </div>
      </div>

      <%!-- Coordinator Detail (expanded) --%>
      <div :if={@coordinator_expanded} class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-6">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Coordinator Detail</h2>
          <button
            phx-click="refresh_coordinator"
            class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
          >
            Refresh
          </button>
        </div>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <div>
            <h3 class="text-xs font-medium text-gray-500 uppercase mb-2">
              Log ({if @coordinator_log, do: length(@coordinator_log), else: 0} lines)
            </h3>
            <%= if @coordinator_log && @coordinator_log != [] do %>
              <div class="max-h-[40vh] overflow-y-auto rounded bg-gray-950 p-3 space-y-0.5">
                <div :for={line <- Enum.take(@coordinator_log, -100)} class="text-xs font-mono text-gray-400">
                  <span :if={line.type} class={["rounded px-1 py-0.5 mr-1 text-xs", Helpers.log_type_class(line.type)]}>
                    {line.type}
                  </span>
                  <span class="break-all">{Helpers.truncate(line.raw, 200)}</span>
                </div>
              </div>
            <% else %>
              <p class="text-gray-500 text-sm">No coordinator log found.</p>
            <% end %>
          </div>
          <div>
            <h3 class="text-xs font-medium text-gray-500 uppercase mb-2">
              Inbox ({length(@coordinator_inbox)})
            </h3>
            <%= if @coordinator_inbox != [] do %>
              <div class="max-h-[40vh] overflow-y-auto space-y-2">
                <div :for={msg <- @coordinator_inbox} class="bg-gray-950 rounded p-2 text-xs">
                  <span class="text-cortex-400">from: {Map.get(msg, "from", "?")}</span>
                  <span class="text-gray-500 ml-2">{Map.get(msg, "timestamp", "")}</span>
                  <p class="text-gray-300 mt-1">{Helpers.truncate(Map.get(msg, "content", ""), 200)}</p>
                </div>
              </div>
            <% else %>
              <p class="text-gray-500 text-sm">No messages yet.</p>
            <% end %>
          </div>
        </div>
      </div>

      <%= if Helpers.non_dag?(@run) do %>
        <%!-- Gossip Info --%>
        <% gossip_info = if(Helpers.gossip?(@run), do: Helpers.parse_gossip_info(@run)) %>
        <%= if gossip_info do %>
          <div class="bg-gray-900 rounded-lg border border-purple-900/50 p-4 mb-6">
            <h2 class="text-sm font-medium text-purple-400 uppercase tracking-wider mb-3">Knowledge Exchange</h2>
            <p class="text-sm text-gray-400 mb-4">
              {Helpers.topology_description(gossip_info.topology, length(@team_runs))}
              — {gossip_info.rounds} rounds, {gossip_info.exchange_interval}s apart.
            </p>
            <div class="flex items-center gap-4 mb-4">
              <div class="flex-1">
                <%= if @gossip_round do %>
                  <div class="flex items-center justify-between text-xs text-gray-500 mb-1">
                    <span>Round {@gossip_round.current} of {@gossip_round.total}</span>
                    <span class={if @gossip_round.current >= @gossip_round.total, do: "text-green-400", else: "text-purple-400"}>
                      {if @gossip_round.current >= @gossip_round.total, do: "Complete", else: "Exchanging"}
                    </span>
                  </div>
                  <div class="h-2 bg-gray-800 rounded-full overflow-hidden">
                    <div
                      class="h-full bg-purple-500 rounded-full transition-all duration-500"
                      style={"width: #{min(round(@gossip_round.current / max(@gossip_round.total, 1) * 100), 100)}%"}
                    />
                  </div>
                <% else %>
                  <div class="flex items-center justify-between text-xs text-gray-500 mb-1">
                    <span>{gossip_info.rounds} rounds configured</span>
                    <span class={if @run.status == "completed", do: "text-green-400", else: "text-gray-500"}>
                      {if @run.status == "completed", do: "Complete", else: "Waiting"}
                    </span>
                  </div>
                  <div class="h-2 bg-gray-800 rounded-full overflow-hidden">
                    <div
                      class={"h-full bg-#{if @run.status == "completed", do: "green", else: "gray"}-600 rounded-full"}
                      style={"width: #{if @run.status == "completed", do: "100", else: "0"}%"}
                    />
                  </div>
                <% end %>
              </div>
            </div>
            <%= if @gossip_knowledge do %>
              <div class="border-t border-purple-900/30 pt-4">
                <div class="flex items-center gap-3 mb-3">
                  <h3 class="text-xs font-medium text-purple-400 uppercase tracking-wider">Knowledge Discovered</h3>
                  <span class="text-xs text-gray-500">{@gossip_knowledge.total_entries} entries across {map_size(@gossip_knowledge.by_topic)} topics</span>
                </div>
                <div class="flex flex-wrap gap-2 mb-3">
                  <span
                    :for={{topic, count} <- Enum.sort_by(@gossip_knowledge.by_topic, fn {_t, c} -> -c end)}
                    class="bg-purple-900/30 text-purple-300 text-xs px-2 py-1 rounded"
                  >
                    {topic} <span class="text-purple-500">({count})</span>
                  </span>
                </div>
                <%= if @gossip_knowledge.top_entries != [] do %>
                  <div class="space-y-2 max-h-48 overflow-y-auto">
                    <div :for={entry <- @gossip_knowledge.top_entries} class="bg-gray-950 rounded p-2">
                      <div class="flex items-center gap-2 mb-1">
                        <span class="text-purple-300 text-xs font-medium">{entry.topic}</span>
                        <span class="text-gray-600 text-xs">from {entry.source}</span>
                        <span class={["text-xs ml-auto", Helpers.confidence_label_class(entry.confidence)]}>
                          {Helpers.confidence_label(entry.confidence)}
                        </span>
                      </div>
                      <p class="text-gray-400 text-xs">{Helpers.truncate(entry.content, 150)}</p>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Mesh Info --%>
        <%= if Helpers.mesh?(@run) do %>
          <% mesh_info = Helpers.parse_mesh_info(@run) %>
          <%= if mesh_info do %>
            <div class="bg-gray-900 rounded-lg border border-emerald-900/50 p-4 mb-6">
              <h2 class="text-sm font-medium text-emerald-400 uppercase tracking-wider mb-3">Mesh Membership</h2>
              <p class="text-sm text-gray-400 mb-4">
                SWIM-inspired failure detection — {length(@team_runs)} autonomous agents with peer-to-peer messaging.
              </p>
              <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
                <div class="bg-gray-950 rounded p-3">
                  <span class="text-xs text-gray-500 block">Heartbeat</span>
                  <span class="text-sm text-white">{mesh_info.heartbeat}s</span>
                </div>
                <div class="bg-gray-950 rounded p-3">
                  <span class="text-xs text-gray-500 block">Suspect Timeout</span>
                  <span class="text-sm text-yellow-300">{mesh_info.suspect_timeout}s</span>
                </div>
                <div class="bg-gray-950 rounded p-3">
                  <span class="text-xs text-gray-500 block">Dead Timeout</span>
                  <span class="text-sm text-red-300">{mesh_info.dead_timeout}s</span>
                </div>
                <div class="bg-gray-950 rounded p-3">
                  <span class="text-xs text-gray-500 block">Status</span>
                  <span class={["text-sm", if(@run.status == "completed", do: "text-green-400", else: if(@run.status == "running", do: "text-blue-400", else: "text-gray-400"))]}>
                    {cond do
                      @run.status == "completed" -> "Complete"
                      @run.status == "running" -> "Active"
                      @run.status == "failed" -> "Failed"
                      true -> @run.status
                    end}
                  </span>
                </div>
              </div>
              <%= if mesh_info.cluster_context do %>
                <div class="mt-4 border-t border-emerald-900/30 pt-3">
                  <h3 class="text-xs font-medium text-emerald-400 uppercase tracking-wider mb-2">Cluster Context</h3>
                  <p class="text-sm text-gray-400">{Helpers.truncate(mesh_info.cluster_context, 300)}</p>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>

        <%!-- Node/Agent Cards --%>
        <% visible_runs = Enum.reject(@team_runs, & &1.internal) %>
        <h2 class="text-lg font-semibold text-white mb-4">{Helpers.participant_label(@run, :plural)}</h2>
        <%= if visible_runs == [] do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
            <p class="text-gray-400">No {Helpers.participant_label(@run, :lower_plural)} recorded for this run.</p>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <a
              :for={team <- visible_runs}
              href={"/runs/#{@run.id}/teams/#{team.team_name}"}
              class="bg-gray-900 rounded-lg border border-purple-900/30 p-4 hover:border-purple-700/50 transition-colors block"
            >
              <div class="flex items-center justify-between mb-2">
                <div class="flex items-center gap-2">
                  <span class={["text-xs", if(team.status == "completed", do: "text-green-400", else: if(team.status == "running", do: "text-blue-400 animate-pulse", else: "text-gray-600"))]}>&bull;</span>
                  <h3 class="font-medium text-white">{team.team_name}</h3>
                </div>
                <.status_badge status={Helpers.display_status(team, @last_seen, @pid_status)} />
              </div>
              <p :if={team.role} class="text-sm text-purple-300/70 mb-2">topic: {team.role}</p>
              <div class="flex items-center gap-4 text-sm">
                <.token_display input={Helpers.total_input(team)} output={team.output_tokens} />
                <.duration_display ms={team.duration_ms} />
              </div>
              <%= if team.status == "failed" and team.result_summary do %>
                <p class="text-xs text-red-400/80 mt-2 truncate" title={team.result_summary}>
                  {Helpers.truncate(team.result_summary, 120)}
                </p>
              <% end %>
            </a>
          </div>
        <% end %>
      <% else %>
        <%!-- DAG Visualization --%>
        <%= if @tiers != [] do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-6">
            <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Dependency Graph</h2>
            <.dag_graph tiers={@tiers} teams={@team_runs} edges={@edges} run_id={@run.id} />
          </div>
        <% end %>

        <%!-- Team Cards --%>
        <% dag_visible_runs = Enum.reject(@team_runs, & &1.internal) %>
        <h2 class="text-lg font-semibold text-white mb-4">Teams</h2>
        <%= if dag_visible_runs == [] do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
            <p class="text-gray-400">No teams recorded for this run.</p>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <a
              :for={team <- dag_visible_runs}
              href={"/runs/#{@run.id}/teams/#{team.team_name}"}
              class="bg-gray-900 rounded-lg border border-gray-800 p-4 hover:border-gray-600 transition-colors block"
            >
              <div class="flex items-center justify-between mb-2">
                <h3 class="font-medium text-white">{team.team_name}</h3>
                <.status_badge status={Helpers.display_status(team, @last_seen, @pid_status)} />
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
                <.token_display input={Helpers.total_input(team)} output={team.output_tokens} />
                <.duration_display ms={team.duration_ms} />
              </div>
            </a>
          </div>
        <% end %>
      <% end %>

      <%!-- Activity Feed --%>
      <div class="mt-6">
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <div class="flex items-center gap-3 mb-3">
            <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Activity Feed</h2>
            <span class="text-xs text-gray-600 ml-auto">{length(@activities)} events</span>
          </div>
          <%= if @activities == [] do %>
            <p class="text-gray-500 text-sm">No activity yet. Events appear here in real-time.</p>
          <% else %>
            <div class="space-y-0.5 max-h-[50vh] overflow-y-auto" id="overview-activity-feed">
              <%= for {entry, idx} <- Enum.with_index(@activities) do %>
                <% expanded = MapSet.member?(@expanded_activities, idx) %>
                <div
                  phx-click="toggle_activity"
                  phx-value-index={idx}
                  class={["flex items-start gap-2 text-sm py-1 px-1 rounded cursor-pointer transition-colors", if(expanded, do: "bg-gray-800/40", else: "hover:bg-gray-800/20")]}
                >
                  <span class="text-gray-600 text-xs shrink-0 mt-0.5">{entry.at}</span>
                  <span class={Helpers.activity_icon_class(entry.kind)}>{Helpers.activity_icon(entry.kind)}</span>
                  <span class="text-cortex-400 font-medium shrink-0">{entry.team}:</span>
                  <%= if expanded do %>
                    <span class="text-gray-300 break-all min-w-0">{entry.text}</span>
                  <% else %>
                    <span class="text-gray-300 truncate min-w-0">{entry.text}</span>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
