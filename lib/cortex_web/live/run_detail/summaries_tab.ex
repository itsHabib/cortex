defmodule CortexWeb.RunDetail.SummariesTab do
  @moduledoc """
  Summaries tab for RunDetailLive.

  Renders agent + DB summaries with generate buttons and summary
  job tracking. Stateless function component.
  """
  use Phoenix.Component

  import CortexWeb.TokenComponents, except: [format_token_count: 1, format_number: 1]

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the summaries tab content.
  """
  attr(:run, :map, required: true)
  attr(:summary_jobs, :list, default: [])
  attr(:coordinator_summaries, :list, default: [])
  attr(:summaries_expanded, :boolean, default: false)
  attr(:selected_summary, :any, default: nil)
  attr(:run_summary, :any, default: nil)

  def summaries_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
        <div class="flex items-center gap-4">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Generate</h2>
          <% loading = has_running_summary_job?(@summary_jobs) %>
          <button
            :if={@run && @run.workspace_path}
            phx-click="request_ai_summary"
            disabled={loading}
            class={[
              "rounded px-4 py-2 text-sm font-medium transition-colors",
              if(loading,
                do: "bg-gray-700 text-gray-400 cursor-wait",
                else: "bg-cortex-600 text-white hover:bg-cortex-500"
              )
            ]}
          >
            {if loading, do: "Generating Agent Summary...", else: "Generate Agent Summary"}
          </button>
          <button
            phx-click="generate_summary"
            class="rounded px-4 py-2 text-sm font-medium bg-gray-700 text-gray-300 hover:bg-gray-600 transition-colors"
          >
            Generate DB Summary
          </button>
          <button
            phx-click="refresh_summaries"
            class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500 ml-auto"
          >
            Reload from disk
          </button>
        </div>
        <p class="text-xs text-gray-500 mt-2">
          Agent Summary spawns a haiku agent to analyze workspace files (state, logs, registry). DB Summary builds from Ecto state.
        </p>
      </div>

      <%= if @summary_jobs != [] do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Summary Jobs</h2>
          <div class="space-y-2">
            <%= for job <- @summary_jobs do %>
              <div class={["flex items-center justify-between rounded p-3 text-sm", Helpers.job_row_class(job.status)]}>
                <div class="flex items-center gap-3">
                  <span class={["text-xs font-medium px-2 py-0.5 rounded", Helpers.job_badge_class(job.status)]}>
                    {Helpers.job_label(job.status)}
                  </span>
                  <span class="text-gray-400">Agent Summary</span>
                  <span :if={job.status == :running} class="text-gray-500 text-xs">{Helpers.elapsed_since(job.started_at)}</span>
                </div>
                <div class="flex items-center gap-3 text-xs">
                  <span :if={job.input_tokens} class="text-cortex-400">
                    <.token_display input={job.input_tokens} output={job.output_tokens} />
                  </span>
                  <span class="text-gray-600">{Calendar.strftime(job.started_at, "%H:%M:%S")}</span>
                  <button
                    :if={job.status != :running}
                    phx-click="dismiss_summary_job"
                    phx-value-id={job.id}
                    class="text-gray-600 hover:text-gray-400"
                  >
                    &times;
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @coordinator_summaries != [] do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <button phx-click="toggle_summaries" class="flex items-center justify-between w-full group">
            <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">
              Agent Summaries
              <span class="text-xs text-gray-600 normal-case ml-2">({length(@coordinator_summaries)})</span>
            </h2>
            <svg class={["w-4 h-4 text-gray-500 transition-transform", if(@summaries_expanded, do: "rotate-180", else: "")]} fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
            </svg>
          </button>
          <div :if={@summaries_expanded} class="mt-3">
            <div class="flex flex-wrap gap-2 mb-3">
              <button
                :for={file <- @coordinator_summaries}
                phx-click="select_summary"
                phx-value-file={file}
                class={[
                  "text-xs px-3 py-1.5 rounded border transition-colors",
                  if(@selected_summary && @selected_summary.name == file,
                    do: "border-cortex-500 text-cortex-300 bg-cortex-900/30",
                    else: "border-gray-700 text-gray-400 hover:text-gray-300 hover:border-gray-500"
                  )
                ]}
              >
                {Helpers.pretty_filename(file)}
              </button>
            </div>
            <div :if={@selected_summary} class="bg-gray-950 rounded p-4 max-h-[60vh] overflow-y-auto">
              <pre class="text-gray-300 text-sm font-mono whitespace-pre-wrap overflow-x-auto">{@selected_summary.content}</pre>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @run_summary do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">DB Summary</h2>
          <pre class="text-gray-300 text-sm font-mono whitespace-pre overflow-x-auto bg-gray-950 rounded p-4 max-h-[60vh] overflow-y-auto">{@run_summary}</pre>
        </div>
      <% end %>

      <%= if @coordinator_summaries == [] and !@run_summary and @summary_jobs == [] do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 text-center">
          <p class="text-gray-400 mb-3">No summaries yet.</p>
          <p class="text-gray-500 text-sm">Click "Generate Agent Summary" to spawn a haiku agent that analyzes your workspace files, or "Generate DB Summary" for a quick snapshot from database state.</p>
        </div>
      <% end %>
    </div>
    """
  end

  defp has_running_summary_job?(jobs) do
    Enum.any?(jobs, fn j -> j.status == :running end)
  end
end
