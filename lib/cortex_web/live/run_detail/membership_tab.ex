defmodule CortexWeb.RunDetail.MembershipTab do
  @moduledoc """
  Membership tab for RunDetailLive — Mesh mode only.

  Renders SWIM membership states, heartbeat config, and agent
  status cards. Stateless function component.
  """
  use Phoenix.Component

  import CortexWeb.StatusComponents
  import CortexWeb.TokenComponents, except: [format_token_count: 1, format_number: 1]

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the mesh membership tab content.
  """
  attr(:run, :map, required: true)
  attr(:team_runs, :list, required: true)
  attr(:last_seen, :map, required: true)
  attr(:pid_status, :map, required: true)

  def membership_tab(assigns) do
    mesh_info = Helpers.parse_mesh_info(assigns.run)
    visible_runs = Enum.reject(assigns.team_runs, & &1.internal)
    assigns = assign(assigns, mesh_info: mesh_info, visible_runs: visible_runs)

    ~H"""
    <div>
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
    """
  end
end
