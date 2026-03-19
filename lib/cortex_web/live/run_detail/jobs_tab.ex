defmodule CortexWeb.RunDetail.JobsTab do
  @moduledoc """
  Jobs tab for RunDetailLive.

  Renders per-run internal jobs (coordinator, summary agent,
  debug agent) with detail panel and log viewer.
  Stateless function component.
  """
  use Phoenix.Component

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the jobs tab content.
  """
  attr(:run, :map, required: true)
  attr(:run_jobs, :list, default: [])
  attr(:selected_run_job, :any, default: nil)
  attr(:run_job_log, :any, default: nil)

  def jobs_tab(assigns) do
    ~H"""
    <div>
      <%= if @run_jobs == [] do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 text-center">
          <p class="text-gray-400">No internal jobs for this run.</p>
          <p class="text-gray-500 text-sm mt-2">
            Jobs appear here when you generate summaries, debug reports, or start coordinators.
          </p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
          <div
            :for={job <- @run_jobs}
            phx-click="select_run_job"
            phx-value-id={job.id}
            class={[
              "bg-gray-900 rounded-lg border p-4 cursor-pointer transition-colors",
              if(@selected_run_job && @selected_run_job.id == job.id,
                do: "border-cortex-500 ring-1 ring-cortex-500/30",
                else: "border-gray-800 hover:border-gray-600"
              )
            ]}
          >
            <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
              <dt class="text-gray-500">Tool</dt>
              <dd class="text-white font-medium">{Helpers.job_type_label_for(job.team_name)}</dd>
              <dt class="text-gray-500">Requester</dt>
              <dd class="text-gray-300">{Helpers.job_target_from_role(job.role) || "system"}</dd>
              <dt class="text-gray-500">Status</dt>
              <dd class={Helpers.job_status_class(job.status)}>{job.status}</dd>
              <dt class="text-gray-500">Started</dt>
              <dd class="text-gray-400">{Helpers.format_job_datetime(job.started_at)}</dd>
              <dt :if={job.completed_at} class="text-gray-500">Completed</dt>
              <dd :if={job.completed_at} class="text-gray-400">
                {Helpers.format_job_datetime(job.completed_at)}
                <span :if={job.duration_ms} class="text-gray-600 ml-1">({Helpers.format_job_duration(job.duration_ms)})</span>
              </dd>
              <dt :if={job.input_tokens || job.output_tokens} class="text-gray-500">Tokens</dt>
              <dd :if={job.input_tokens || job.output_tokens} class="text-gray-400">
                {job.input_tokens || 0} in / {job.output_tokens || 0} out
              </dd>
            </dl>
          </div>
        </div>

        <%= if @selected_run_job do %>
          <div class="mt-4 bg-gray-900 rounded-lg border border-gray-800 p-4">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-sm font-medium text-white">
                {Helpers.job_type_label_for(@selected_run_job.team_name)}
                <span :if={Helpers.job_target_from_role(@selected_run_job.role)} class="text-gray-400 font-normal">
                  — {Helpers.job_target_from_role(@selected_run_job.role)}
                </span>
              </h3>
              <div class="flex items-center gap-2">
                <button
                  phx-click="refresh_run_job_log"
                  class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
                >
                  Refresh
                </button>
                <button phx-click="close_run_job" class="text-gray-500 hover:text-gray-300">
                  ✕
                </button>
              </div>
            </div>

            <dl class="grid grid-cols-2 md:grid-cols-4 gap-x-4 gap-y-2 text-sm mb-4">
              <div>
                <dt class="text-gray-500 text-xs">Status</dt>
                <dd class={Helpers.job_status_class(@selected_run_job.status)}>{@selected_run_job.status}</dd>
              </div>
              <div :if={@selected_run_job.input_tokens || @selected_run_job.output_tokens}>
                <dt class="text-gray-500 text-xs">Tokens</dt>
                <dd class="text-gray-300">{@selected_run_job.input_tokens || 0} in / {@selected_run_job.output_tokens || 0} out</dd>
              </div>
              <div :if={@selected_run_job.session_id}>
                <dt class="text-gray-500 text-xs">Session</dt>
                <dd class="text-gray-400 font-mono text-xs truncate" title={@selected_run_job.session_id}>
                  {String.slice(@selected_run_job.session_id, 0, 16)}...
                </dd>
              </div>
              <div :if={@selected_run_job.result_summary}>
                <dt class="text-gray-500 text-xs">Result</dt>
                <dd class="text-gray-300 text-xs truncate" title={@selected_run_job.result_summary}>
                  {Helpers.truncate(@selected_run_job.result_summary, 80)}
                </dd>
              </div>
            </dl>

            <div class="border-t border-gray-800 pt-4">
              <h3 class="text-xs font-medium text-gray-500 uppercase mb-2">
                Log
                <span :if={@run_job_log} class="text-gray-600 normal-case ml-1">({length(@run_job_log)} lines)</span>
              </h3>
              <%= if @run_job_log && @run_job_log != [] do %>
                <div class="max-h-[50vh] overflow-y-auto rounded bg-gray-950 p-3 space-y-0.5">
                  <div :for={line <- @run_job_log} class="text-xs font-mono text-gray-400">
                    <span :if={line.type} class={["rounded px-1 py-0.5 mr-1 text-xs", Helpers.run_job_log_class(line.type)]}>
                      {line.type}
                    </span>
                    <span class="break-all">{Helpers.truncate(line.text, 200)}</span>
                  </div>
                </div>
                <p class="text-xs text-gray-600 mt-2">
                  Showing last 200 lines. For full logs, use the
                  <button phx-click="switch_tab" phx-value-tab="logs" class="text-cortex-400 hover:text-cortex-300 underline">Logs tab</button>.
                </p>
              <% else %>
                <p class="text-gray-500 text-sm">
                  {if @selected_run_job.log_path, do: "No log content yet.", else: "No log path recorded."}
                </p>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
