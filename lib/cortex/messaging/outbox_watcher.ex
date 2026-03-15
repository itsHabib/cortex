defmodule Cortex.Messaging.OutboxWatcher do
  @moduledoc """
  Polls team outbox files for new progress messages during a run.

  Started dynamically per-run. Reads `.cortex/messages/<team>/outbox.json`
  every `:poll_interval_ms` milliseconds, detects new entries, and broadcasts
  `:team_progress` events via `Cortex.Events`.

  Stops itself when `:run_completed` is received.
  """

  use GenServer

  alias Cortex.Messaging.InboxBridge

  require Logger

  @default_poll_interval_ms 3_000

  @doc """
  Starts an outbox watcher for the given run.

  ## Options

    - `:workspace_path` — required. The project root directory.
    - `:run_id` — required. The run ID for event payloads.
    - `:team_names` — required. List of team name strings to watch.
    - `:poll_interval_ms` — optional. Poll frequency, default 3000ms.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Starts an outbox watcher NOT linked to the calling process.

  Use this instead of `start_link/1` when the caller (e.g., a Runner
  coordinator) should not be killed if the watcher crashes.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    run_id = Keyword.fetch!(opts, :run_id)
    team_names = Keyword.fetch!(opts, :team_names)
    poll_interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)

    safe_subscribe()

    state = %{
      workspace_path: workspace_path,
      run_id: run_id,
      team_names: team_names,
      last_counts: Map.new(team_names, fn name -> {name, 0} end),
      poll_interval: poll_interval
    }

    schedule_poll(poll_interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = poll_outboxes(state)
    schedule_poll(state.poll_interval)
    {:noreply, new_state}
  end

  def handle_info(%{type: :run_completed, payload: %{project: _}}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp poll_outboxes(state) do
    Enum.reduce(state.team_names, state, fn team_name, acc ->
      case InboxBridge.read_outbox(acc.workspace_path, team_name) do
        {:ok, entries} when is_list(entries) ->
          seen = Map.get(acc.last_counts, team_name, 0)
          new_entries = Enum.drop(entries, seen)

          Enum.each(new_entries, fn entry ->
            safe_broadcast(:team_progress, %{
              run_id: acc.run_id,
              team_name: team_name,
              message: entry
            })
          end)

          %{acc | last_counts: Map.put(acc.last_counts, team_name, length(entries))}

        _ ->
          acc
      end
    end)
  end

  defp safe_subscribe do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp safe_broadcast(type, payload) do
    Cortex.Events.broadcast(type, payload)
  rescue
    _ -> :ok
  end
end
