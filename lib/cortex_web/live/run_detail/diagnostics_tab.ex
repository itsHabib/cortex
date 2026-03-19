defmodule CortexWeb.RunDetail.DiagnosticsTab do
  @moduledoc """
  Diagnostics tab for RunDetailLive.

  Renders merged diagnostics + debug reports with team selector,
  diagnosis banner, AI diagnostic report, resume/restart buttons,
  and event timeline. Stateless function component.
  """
  use Phoenix.Component

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the diagnostics tab content.
  """
  attr(:run, :map, required: true)
  attr(:team_runs, :list, required: true)
  attr(:team_names, :list, required: true)
  attr(:diagnostics_team, :any, default: nil)
  attr(:diagnostics_report, :any, default: nil)
  attr(:debug_report, :any, default: nil)
  attr(:debug_loading, :boolean, default: false)
  attr(:debug_reports, :list, default: [])
  attr(:selected_debug_report, :any, default: nil)

  def diagnostics_tab(assigns) do
    ~H"""
    <div>
      <%= if @run.workspace_path do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
          <div class="flex items-center gap-3">
            <label class="text-sm text-gray-400 shrink-0">{String.capitalize(Helpers.participant_label(@run, :singular))}:</label>
            <form phx-change="select_diag_team" class="flex-1">
              <select
                name="team"
                class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
              >
                <option value="">Select {Helpers.participant_label(@run, :singular)}...</option>
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
          <div class={["rounded-lg border p-4 mb-4", Helpers.diag_banner_class(report.diagnosis)]}>
            <div class="flex items-center gap-3">
              <span class="text-lg">{Helpers.diag_icon(report.diagnosis)}</span>
              <div>
                <p class="font-medium">{Helpers.diag_title(report.diagnosis)}</p>
                <p class="text-sm opacity-80">{report.diagnosis_detail}</p>
              </div>
            </div>
            <div class="flex items-center gap-4 mt-3 text-sm opacity-70 flex-wrap">
              <span :if={report.session_id}>Session: <code class="font-mono">{report.session_id}</code></span>
              <span :if={report.model}>Model: {report.model}</span>
              <span :if={report.total_input_tokens > 0 or report.total_output_tokens > 0}>
                Tokens: {Helpers.format_token_count(report.total_input_tokens)} in / {Helpers.format_token_count(report.total_output_tokens)} out
              </span>
              <span>{report.line_count} log lines</span>
            </div>
          </div>

          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
            <div class="flex items-center justify-between mb-3">
              <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">AI Diagnostic Report</h3>
              <button
                :if={@run && @run.workspace_path}
                phx-click="request_debug_report"
                disabled={@debug_loading}
                class={[
                  "rounded px-4 py-2 text-sm font-medium transition-colors",
                  if(@debug_loading,
                    do: "bg-gray-700 text-gray-400 cursor-wait",
                    else: "bg-cortex-600 text-white hover:bg-cortex-500"
                  )
                ]}
              >
                {if @debug_loading, do: "Analyzing...", else: "Generate Diagnostic Report"}
              </button>
            </div>
            <%= if @debug_report do %>
              <div class="bg-gray-950 rounded p-4 max-h-[50vh] overflow-y-auto">
                <pre class="text-gray-300 text-sm font-mono whitespace-pre-wrap overflow-x-auto">{@debug_report.content}</pre>
              </div>
            <% else %>
              <p class="text-gray-500 text-sm">Spawns a haiku agent to analyze this {Helpers.participant_label(@run, :singular)}'s log and produce a diagnostic report.</p>
            <% end %>
          </div>

          <% diag_team_run = Enum.find(@team_runs, &(&1.team_name == @diagnostics_team)) %>
          <% diag_team_status = if(diag_team_run, do: diag_team_run.status || "pending", else: "pending") %>
          <div
            :if={report.session_id && report.diagnosis not in [:completed] && diag_team_status != "running"}
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

          <div :if={report.result_text} class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
            <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-2">Result</h3>
            <pre class="text-gray-300 text-sm whitespace-pre-wrap">{report.result_text}</pre>
          </div>

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
                    Helpers.diag_entry_class(entry.type)
                  ]}>
                    {Helpers.diag_entry_label(entry.type)}
                  </span>
                  <span :if={entry.tools != []} class="text-cortex-400 font-medium shrink-0">
                    {Enum.join(entry.tools, ", ")}
                  </span>
                  <span class="text-gray-300 break-all">{entry.detail}</span>
                  <span :if={entry.timestamp} class="text-gray-500 text-xs shrink-0 ml-auto">
                    {Helpers.format_iso_time(entry.timestamp)}
                  </span>
                </div>

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
            <p class="text-gray-500 text-sm">Select a {Helpers.participant_label(@run, :singular)} to view diagnostics.</p>
          </div>
        <% end %>

        <%= if @debug_reports != [] do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mt-4">
            <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">
              Previous Diagnostic Reports
              <span class="text-xs text-gray-600 normal-case ml-2">({length(@debug_reports)})</span>
            </h3>
            <div class="flex flex-wrap gap-2 mb-3">
              <button
                :for={file <- @debug_reports}
                phx-click="select_debug_report"
                phx-value-file={file}
                class={[
                  "text-xs px-3 py-1.5 rounded border transition-colors",
                  if(@selected_debug_report && @selected_debug_report.name == file,
                    do: "border-cortex-500 text-cortex-300 bg-cortex-900/30",
                    else: "border-gray-700 text-gray-400 hover:text-gray-300 hover:border-gray-500"
                  )
                ]}
              >
                {Helpers.pretty_filename(file)}
              </button>
            </div>
            <div :if={@selected_debug_report} class="bg-gray-950 rounded p-4 max-h-[60vh] overflow-y-auto">
              <pre class="text-gray-300 text-sm font-mono whitespace-pre-wrap overflow-x-auto">{@selected_debug_report.content}</pre>
            </div>
          </div>
        <% end %>
      <% else %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <p class="text-gray-500">No workspace path available. Diagnostics require a workspace with .cortex/logs/ directory.</p>
        </div>
      <% end %>
    </div>
    """
  end
end
