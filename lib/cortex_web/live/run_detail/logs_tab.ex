defmodule CortexWeb.RunDetail.LogsTab do
  @moduledoc """
  Logs tab for RunDetailLive.

  Renders the log viewer with team selector, sort toggle, and
  expandable log lines. Stateless function component.
  """
  use Phoenix.Component

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the logs tab content.
  """
  attr(:run, :map, required: true)
  attr(:team_names, :list, required: true)
  attr(:selected_log_team, :any, default: nil)
  attr(:log_lines, :any, default: nil)
  attr(:log_sort, :atom, default: :desc)
  attr(:expanded_logs, :any, required: true)

  def logs_tab(assigns) do
    ~H"""
    <div>
      <%= if @run.workspace_path do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
          <div class="flex items-center gap-3">
            <label class="text-sm text-gray-400 shrink-0">{String.capitalize(Helpers.participant_label(@run, :singular))}:</label>
            <form phx-change="select_log_team" class="flex-1">
              <select
                name="team"
                class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
              >
                <option value="">Select {Helpers.participant_label(@run, :singular)}...</option>
                <option value="__all__" selected={@selected_log_team == "__all__"}>All {Helpers.participant_label(@run, :lower_plural)}</option>
                <option value="coordinator" selected={@selected_log_team == "coordinator"}>[internal] coordinator</option>
                <option value="summary-agent" selected={@selected_log_team == "summary-agent"}>[internal] summary-agent</option>
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
              {if @log_sort == :desc, do: "Newest first \u2193", else: "Oldest first \u2191"}
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

        <%= if @selected_log_team do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">
                {if @selected_log_team == "__all__", do: "All #{Helpers.participant_label(@run, :lower_plural)}", else: "#{@selected_log_team}.log"}
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
                        class={["shrink-0 rounded px-1.5 py-0.5 text-xs font-medium", Helpers.log_type_class(line.type)]}
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
                    <div :if={expanded && line.parsed} class="mt-2 ml-14 space-y-1 border-l-2 border-gray-700 pl-3">
                      <div :for={{key, val} <- line.parsed} class="flex items-start gap-2 text-xs font-mono">
                        <span class="text-cortex-400 shrink-0">{key}:</span>
                        <span class="text-gray-300 whitespace-pre-wrap break-all">{Helpers.format_json_value(val)}</span>
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
            <p class="text-gray-500 text-sm">Select a {Helpers.participant_label(@run, :singular)} to view its log.</p>
          </div>
        <% end %>
      <% else %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <p class="text-gray-500">No workspace path available. Logs require a workspace with .cortex/logs/ directory.</p>
        </div>
      <% end %>
    </div>
    """
  end
end
