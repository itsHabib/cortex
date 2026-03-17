defmodule CortexWeb.JobsLive do
  @moduledoc """
  LiveView for viewing internal agent jobs (coordinator, summary-agent, debug-agent).

  Shows all internal jobs across runs with status, timestamps, and log viewers.
  """
  use CortexWeb, :live_view

  require Logger

  @max_log_lines 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: safe_subscribe()

    jobs = safe_get_jobs()

    {:ok,
     assign(socket,
       page_title: "Jobs",
       jobs: jobs,
       selected_job_id: nil,
       job_log_lines: nil
     )}
  end

  @impl true
  def handle_info(%{type: type}, socket)
      when type in [:team_status_changed, :run_completed, :tier_completed] do
    {:noreply, assign(socket, jobs: safe_get_jobs())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, jobs: safe_get_jobs())}
  end

  def handle_event("select_job", %{"id" => job_id}, socket) do
    job = Enum.find(socket.assigns.jobs, &(&1.id == job_id))

    log_lines =
      if job && job.log_path do
        parse_log_file(job.log_path)
      end

    {:noreply, assign(socket, selected_job_id: job_id, job_log_lines: log_lines)}
  end

  def handle_event("close_job", _params, socket) do
    {:noreply, assign(socket, selected_job_id: nil, job_log_lines: nil)}
  end

  def handle_event("refresh_job_log", _params, socket) do
    job = Enum.find(socket.assigns.jobs, &(&1.id == socket.assigns.selected_job_id))

    log_lines =
      if job && job.log_path do
        parse_log_file(job.log_path)
      end

    {:noreply, assign(socket, job_log_lines: log_lines)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Jobs
      <:subtitle>Internal agent jobs across all runs</:subtitle>
      <:actions>
        <button
          phx-click="refresh"
          class="text-sm text-gray-400 hover:text-white px-3 py-1 rounded border border-gray-700 hover:border-gray-500"
        >
          Refresh
        </button>
      </:actions>
    </.header>

    <div class="flex gap-6 mt-6">
      <!-- Job list -->
      <div class={if @selected_job_id, do: "w-1/2", else: "w-full"}>
        <%= if @jobs == [] do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 text-center">
            <p class="text-gray-400">No internal jobs yet.</p>
            <p class="text-gray-500 text-sm mt-2">
              Jobs appear here when you spawn agent summaries, debug reports, or coordinators from a run.
            </p>
          </div>
        <% else %>
          <div class="space-y-2">
            <%= for job <- @jobs do %>
              <div
                phx-click="select_job"
                phx-value-id={job.id}
                class={[
                  "bg-gray-900 rounded-lg border p-4 cursor-pointer transition-colors",
                  if(@selected_job_id == job.id,
                    do: "border-cortex-500 ring-1 ring-cortex-500/30",
                    else: "border-gray-800 hover:border-gray-600"
                  )
                ]}
              >
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center gap-3">
                    <span class={["text-xs font-medium px-2 py-0.5 rounded", status_badge_class(job.status)]}>
                      {job.status}
                    </span>
                    <span class="font-medium text-white text-sm">Tool: {job_type_label(job.team_name)}</span>
                    <span :if={job_target(job)} class="text-gray-400 text-sm">— {job_target(job)}</span>
                  </div>
                  <span class="text-xs text-gray-500">{format_datetime(job.started_at)}</span>
                </div>
                <div class="flex items-center gap-4 text-xs text-gray-400">
                  <span :if={job.run} class="text-gray-600">
                    run: <a href={"/runs/#{job.run_id}"} class="text-cortex-400 hover:text-cortex-300">{job.run.name || truncate_id(job.run_id)}</a>
                  </span>
                  <span :if={job.input_tokens || job.output_tokens} class="text-gray-500">
                    {job.input_tokens || 0} in / {job.output_tokens || 0} out
                  </span>
                </div>
                <div :if={job.status in ["completed", "failed"] and job.completed_at} class="mt-2 text-xs text-gray-500">
                  Completed {format_datetime(job.completed_at)}
                  <span :if={job.duration_ms}> — {format_duration(job.duration_ms)}</span>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Selected job detail -->
      <div :if={@selected_job_id} class="w-1/2">
        <% selected = Enum.find(@jobs, &(&1.id == @selected_job_id)) %>
        <%= if selected do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 sticky top-4">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-sm font-medium text-white">
                {job_type_label(selected.team_name)}
              </h2>
              <div class="flex items-center gap-2">
                <button
                  phx-click="refresh_job_log"
                  class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
                >
                  Refresh Log
                </button>
                <button
                  phx-click="close_job"
                  class="text-gray-500 hover:text-gray-300"
                >
                  &times;
                </button>
              </div>
            </div>

            <!-- Detail fields -->
            <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-sm mb-4">
              <div>
                <dt class="text-gray-500 text-xs">Status</dt>
                <dd class={status_text_class(selected.status)}>{selected.status}</dd>
              </div>
              <div>
                <dt class="text-gray-500 text-xs">Started</dt>
                <dd class="text-gray-300">{format_datetime(selected.started_at)}</dd>
              </div>
              <div :if={selected.completed_at}>
                <dt class="text-gray-500 text-xs">Completed</dt>
                <dd class="text-gray-300">{format_datetime(selected.completed_at)}</dd>
              </div>
              <div :if={selected.input_tokens || selected.output_tokens}>
                <dt class="text-gray-500 text-xs">Tokens</dt>
                <dd class="text-gray-300">{selected.input_tokens || 0} in / {selected.output_tokens || 0} out</dd>
              </div>
              <div :if={selected.session_id}>
                <dt class="text-gray-500 text-xs">Session</dt>
                <dd class="text-gray-400 font-mono text-xs truncate" title={selected.session_id}>{truncate_id(selected.session_id)}</dd>
              </div>
              <div :if={selected.run}>
                <dt class="text-gray-500 text-xs">Run</dt>
                <dd>
                  <a href={"/runs/#{selected.run_id}"} class="text-cortex-400 hover:text-cortex-300 text-xs">
                    {selected.run.name || truncate_id(selected.run_id)}
                  </a>
                </dd>
              </div>
            </dl>

            <!-- Log viewer -->
            <div class="border-t border-gray-800 pt-4">
              <h3 class="text-xs font-medium text-gray-500 uppercase mb-2">
                Log
                <span :if={@job_log_lines} class="text-gray-600 normal-case ml-1">({length(@job_log_lines)} lines)</span>
              </h3>
              <%= if @job_log_lines && @job_log_lines != [] do %>
                <div class="max-h-[60vh] overflow-y-auto rounded bg-gray-950 p-3 space-y-0.5">
                  <div :for={line <- @job_log_lines} class="text-xs font-mono text-gray-400">
                    <span :if={line.type} class={["rounded px-1 py-0.5 mr-1 text-xs", log_type_class(line.type)]}>
                      {line.type}
                    </span>
                    <span class="break-all">{truncate(line.raw, 200)}</span>
                  </div>
                </div>
              <% else %>
                <p class="text-gray-500 text-sm">
                  {if selected.log_path, do: "No log content yet.", else: "No log path recorded."}
                </p>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # -- Helpers --

  defp safe_get_jobs do
    Cortex.Store.get_internal_jobs(limit: 200)
  rescue
    _ -> []
  end

  defp safe_subscribe do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp parse_log_file(log_path) do
    case File.read(log_path) do
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

      {:error, _} ->
        nil
    end
  end

  defp parse_log_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = parsed} -> {type, parsed}
      {:ok, parsed} when is_map(parsed) -> {nil, parsed}
      _ -> {nil, nil}
    end
  end

  defp job_type_label("coordinator"), do: "Coordinator"
  defp job_type_label("summary-agent"), do: "Summary"
  defp job_type_label("debug-agent"), do: "Debug Report"
  defp job_type_label(name), do: name

  # Extract the target from the role, e.g. "Debug Report — competitor-analysis" → "competitor-analysis"
  defp job_target(%{role: role}) when is_binary(role) do
    case String.split(role, " — ", parts: 2) do
      [_, target] -> target
      _ -> nil
    end
  end

  defp job_target(_), do: nil

  defp status_badge_class("running"), do: "bg-blue-900/50 text-blue-300"
  defp status_badge_class("completed"), do: "bg-green-900/50 text-green-300"
  defp status_badge_class("failed"), do: "bg-red-900/50 text-red-300"
  defp status_badge_class("stopped"), do: "bg-orange-900/50 text-orange-300"
  defp status_badge_class("pending"), do: "bg-gray-800/50 text-gray-400"
  defp status_badge_class(_), do: "bg-gray-800/50 text-gray-400"

  defp status_text_class("running"), do: "text-blue-300"
  defp status_text_class("completed"), do: "text-green-300"
  defp status_text_class("failed"), do: "text-red-300"
  defp status_text_class("stopped"), do: "text-orange-300"
  defp status_text_class(_), do: "text-gray-400"

  defp log_type_class("assistant"), do: "bg-blue-900/50 text-blue-300"
  defp log_type_class("system"), do: "bg-purple-900/50 text-purple-300"
  defp log_type_class("result"), do: "bg-cyan-900/50 text-cyan-300"
  defp log_type_class("error"), do: "bg-red-900/50 text-red-300"
  defp log_type_class("tool_use"), do: "bg-green-900/50 text-green-300"
  defp log_type_class("tool_result"), do: "bg-emerald-900/50 text-emerald-300"
  defp log_type_class(_), do: "bg-gray-800/50 text-gray-400"

  defp format_datetime(nil), do: "--"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_datetime(_), do: "--"

  defp format_duration(nil), do: nil

  defp format_duration(ms) when ms < 60_000 do
    "#{div(ms, 1000)}s"
  end

  defp format_duration(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1000)
    "#{mins}m #{String.pad_leading(to_string(secs), 2, "0")}s"
  end

  defp truncate_id(nil), do: "--"
  defp truncate_id(id) when byte_size(id) <= 12, do: id
  defp truncate_id(id), do: String.slice(id, 0, 8) <> "..."

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end
end
