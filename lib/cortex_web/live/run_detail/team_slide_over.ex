defmodule CortexWeb.RunDetail.TeamSlideOver do
  @moduledoc """
  Team slide-over panel component for RunDetailLive.

  Renders team detail (result, logs, diagnostics, resume/restart
  actions) in a slide-over panel within RunDetailLive, replacing
  the standalone TeamDetailLive page.
  Stateless function component using CoreComponents.slide_over.
  """
  use Phoenix.Component

  import CortexWeb.CoreComponents, only: [slide_over: 1]
  import CortexWeb.StatusComponents
  import CortexWeb.TokenComponents, except: [format_token_count: 1, format_number: 1]

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the team slide-over panel.
  """
  attr(:show, :boolean, default: false)
  attr(:team_run, :any, default: nil)
  attr(:panel_log, :any, default: nil)
  attr(:panel_diagnostics, :any, default: nil)
  attr(:run, :map, required: true)

  def team_slide_over(assigns) do
    team_name = if assigns.team_run, do: assigns.team_run.team_name, else: nil
    assigns = assign(assigns, :team_name, team_name)

    ~H"""
    <.slide_over show={@show} on_close="close_team_panel" title={@team_name}>
      <%= if @team_run do %>
        <div class="space-y-4">
          <%!-- Status & Tokens --%>
          <div class="flex items-center gap-3">
            <.status_badge status={@team_run.status || "pending"} />
            <.token_display input={Helpers.total_input(@team_run)} output={@team_run.output_tokens} />
            <.duration_display ms={@team_run.duration_ms} />
          </div>

          <%!-- Role --%>
          <p :if={@team_run.role} class="text-sm text-gray-400">{@team_run.role}</p>

          <%!-- Result --%>
          <%= if @team_run.result_summary do %>
            <div class="bg-gray-950 rounded p-3">
              <h3 class="text-xs font-medium text-gray-500 uppercase mb-2">Result</h3>
              <pre class="text-gray-300 text-sm whitespace-pre-wrap">{@team_run.result_summary}</pre>
            </div>
          <% end %>

          <%!-- Diagnostics --%>
          <%= if @panel_diagnostics do %>
            <div class={[
              "rounded-lg border p-3",
              Helpers.diag_banner_class(@panel_diagnostics.diagnosis)
            ]}>
              <div class="flex items-center gap-2">
                <span class="text-sm">{Helpers.diag_icon(@panel_diagnostics.diagnosis)}</span>
                <span class="font-medium text-sm">{Helpers.diag_title(@panel_diagnostics.diagnosis)}</span>
              </div>
              <p class="text-xs opacity-80 mt-1">{@panel_diagnostics.diagnosis_detail}</p>
            </div>
          <% end %>

          <%!-- Log --%>
          <div>
            <h3 class="text-xs font-medium text-gray-500 uppercase mb-2">
              Log
              <span :if={@panel_log} class="text-gray-600 normal-case ml-1">({length(@panel_log)} lines)</span>
            </h3>
            <%= if @panel_log && @panel_log != [] do %>
              <div class="max-h-[40vh] overflow-y-auto rounded bg-gray-950 p-3 space-y-0.5">
                <div :for={line <- Enum.take(@panel_log, -100)} class="text-xs font-mono text-gray-400">
                  <span :if={line.type} class={["rounded px-1 py-0.5 mr-1 text-xs", Helpers.log_type_class(line.type)]}>
                    {line.type}
                  </span>
                  <span class="break-all">{Helpers.truncate(line.raw, 200)}</span>
                </div>
              </div>
            <% else %>
              <p class="text-gray-500 text-sm">No log available.</p>
            <% end %>
          </div>

          <%!-- Actions --%>
          <% team_status = @team_run.status || "pending" %>
          <div
            :if={team_status != "running" && team_status not in ["completed", "done"]}
            class="flex items-center gap-2 pt-2 border-t border-gray-800"
          >
            <button
              phx-click="resume_single_team"
              phx-value-team={@team_name}
              class="rounded bg-cortex-600 px-4 py-2 text-sm font-medium text-white hover:bg-cortex-500"
            >
              Resume
            </button>
            <button
              phx-click="restart_team"
              phx-value-team={@team_name}
              class="rounded bg-yellow-600 px-4 py-2 text-sm font-medium text-white hover:bg-yellow-500"
              title="Start fresh session with context from previous run"
            >
              Restart
            </button>
          </div>
        </div>
      <% end %>
    </.slide_over>
    """
  end
end
