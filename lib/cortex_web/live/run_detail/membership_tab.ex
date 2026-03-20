defmodule CortexWeb.RunDetail.MembershipTab do
  @moduledoc """
  Membership tab for RunDetailLive — Mesh mode only.

  Renders SWIM membership states, heartbeat config, and agent
  status cards. Stateless function component.
  """
  use Phoenix.Component

  import CortexWeb.StatusComponents
  import CortexWeb.TokenComponents, except: [format_token_count: 1, format_number: 1]
  import CortexWeb.MeshComponents, only: [communication_graph: 1]

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the mesh membership tab content.
  """
  attr(:run, :map, required: true)
  attr(:team_runs, :list, required: true)
  attr(:last_seen, :map, required: true)
  attr(:pid_status, :map, required: true)
  attr(:message_flows, :map, default: %{flows: [], total: 0, by_agent: %{}})
  attr(:membership_view, :string, default: "list")
  attr(:selected_graph_node, :string, default: nil)

  def membership_tab(assigns) do
    mesh_info = Helpers.parse_mesh_info(assigns.run)
    visible_runs = Enum.reject(assigns.team_runs, & &1.internal)
    max_flow = case assigns.message_flows.flows do
      [top | _] -> top.count
      [] -> 1
    end
    assigns = assign(assigns, mesh_info: mesh_info, visible_runs: visible_runs, max_flow: max_flow)

    ~H"""
    <div>
      <%!-- SWIM config (always visible) --%>
      <%= if @mesh_info do %>
        <div class="bg-gray-900 rounded-lg border border-emerald-900/50 p-4 mb-6">
          <h2 class="text-sm font-medium text-emerald-400 uppercase tracking-wider mb-3">SWIM Configuration</h2>
          <p class="text-sm text-gray-400 mb-4">
            SWIM-inspired failure detection — {length(@visible_runs)} autonomous agents with peer-to-peer messaging.
          </p>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div class="bg-gray-950 rounded p-3">
              <span class="text-xs text-gray-500 block">Heartbeat</span>
              <span class="text-sm text-white">{@mesh_info.heartbeat}s</span>
            </div>
            <div class="bg-gray-950 rounded p-3">
              <span class="text-xs text-gray-500 block">Suspect Timeout</span>
              <span class="text-sm text-yellow-300">{@mesh_info.suspect_timeout}s</span>
            </div>
            <div class="bg-gray-950 rounded p-3">
              <span class="text-xs text-gray-500 block">Dead Timeout</span>
              <span class="text-sm text-red-300">{@mesh_info.dead_timeout}s</span>
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
          <%= if @mesh_info.cluster_context do %>
            <div class="mt-4 border-t border-emerald-900/30 pt-3">
              <h3 class="text-xs font-medium text-emerald-400 uppercase tracking-wider mb-2">Cluster Context</h3>
              <p class="text-sm text-gray-400">{Helpers.truncate(@mesh_info.cluster_context, 300)}</p>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- View toggle --%>
      <div class="flex items-center gap-1 mb-4 bg-gray-900 rounded-lg border border-gray-800 p-1 w-fit">
        <button
          phx-click="set_membership_view"
          phx-value-view="list"
          class={[
            "px-3 py-1.5 text-sm rounded-md transition-colors",
            if(@membership_view == "list", do: "bg-gray-700 text-white", else: "text-gray-400 hover:text-gray-300")
          ]}
        >
          List
        </button>
        <button
          phx-click="set_membership_view"
          phx-value-view="graph"
          class={[
            "px-3 py-1.5 text-sm rounded-md transition-colors",
            if(@membership_view == "graph", do: "bg-gray-700 text-white", else: "text-gray-400 hover:text-gray-300")
          ]}
        >
          Graph
        </button>
      </div>

      <%!-- List view (default) --%>
      <div :if={@membership_view == "list"}>
        <h2 class="text-lg font-semibold text-white mb-4">Agents</h2>
        <%= if @visible_runs == [] do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
            <p class="text-gray-400">No agents recorded for this run.</p>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <div
              :for={team <- @visible_runs}
              class="bg-gray-900 rounded-lg border border-emerald-900/30 p-4"
            >
              <div class="flex items-center justify-between mb-2">
                <h3 class="font-medium text-white">{team.team_name}</h3>
                <.status_badge status={Helpers.display_status(team, @last_seen, @pid_status)} />
              </div>
              <p :if={team.role} class="text-sm text-emerald-300/70 mb-2">{team.role}</p>
              <div class="flex items-center gap-4 text-sm">
                <.token_display input={Helpers.total_input(team)} output={team.output_tokens} />
                <.duration_display ms={team.duration_ms} />
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Graph view --%>
      <div :if={@membership_view == "graph"}>
        <%= if length(@visible_runs) >= 2 do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
            <.communication_graph
              agents={Enum.map(@visible_runs, fn tr -> %{name: tr.team_name, status: Helpers.display_status(tr, @last_seen, @pid_status), role: tr.role} end)}
              message_flows={@message_flows}
              selected_node={@selected_graph_node}
              run_status={@run.status}
            />
          </div>
        <% end %>

        <%= if @message_flows.total > 0 do %>
          <div class="bg-gray-900 rounded-lg border border-cortex-900/50 p-4">
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-sm font-medium text-cortex-400 uppercase tracking-wider">Message Flows</h2>
              <span class="text-xs text-gray-500">{@message_flows.total} messages</span>
            </div>

            <div class="space-y-1.5 mb-4">
              <div
                :for={flow <- Enum.take(@message_flows.flows, 12)}
                class="flex items-center gap-2 text-sm"
              >
                <span class="text-white font-mono text-xs shrink-0 text-right truncate max-w-[10rem]" title={flow.from}>{flow.from}</span>
                <span class="text-gray-600 shrink-0">-></span>
                <span class="text-white font-mono text-xs shrink-0 truncate max-w-[10rem]" title={flow.to}>{flow.to}</span>
                <div class="flex-1 h-2 bg-gray-800 rounded-full overflow-hidden">
                  <div
                    class="h-full bg-cortex-600 rounded-full"
                    style={"width: #{round(flow.count / @max_flow * 100)}%"}
                  />
                </div>
                <span class="text-gray-400 font-mono text-xs w-6 text-right">{flow.count}</span>
              </div>
            </div>

            <div class="border-t border-gray-800 pt-3">
              <div class="flex flex-wrap gap-3">
                <div
                  :for={{name, stats} <- Enum.sort_by(@message_flows.by_agent, fn {_, s} -> -(s.sent + s.received) end)}
                  class="bg-gray-950 rounded px-3 py-2 text-xs"
                >
                  <span class="text-white font-medium">{name}</span>
                  <div class="flex gap-3 mt-1 text-gray-500">
                    <span><span class="text-cortex-400">{stats.sent}</span> sent</span>
                    <span><span class="text-cortex-400">{stats.received}</span> recv</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <% else %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
            <p class="text-gray-500 text-sm">No message traffic recorded yet.</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
