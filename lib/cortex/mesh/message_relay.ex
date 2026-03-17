defmodule Cortex.Mesh.MessageRelay do
  @moduledoc """
  GenServer that polls agent outboxes and relays messages to recipients.

  In mesh mode, agents communicate by writing to their outbox files.
  The MessageRelay reads these outboxes, extracts messages with a `"to"` field,
  and delivers them to the target agent's inbox via `InboxBridge.deliver/3`.

  Also broadcasts `:team_progress` events for each new outbox entry.

  Stops on `:mesh_completed` event.
  """

  use GenServer

  alias Cortex.Messaging.InboxBridge

  require Logger

  @default_poll_interval_ms 3_000

  @doc """
  Starts a message relay for a mesh session.

  ## Options

    - `:workspace_path` — required. The project root directory.
    - `:run_id` — required. The run ID for event payloads.
    - `:agent_names` — required. List of agent name strings to watch.
    - `:poll_interval_ms` — optional. Poll frequency, default 3000ms.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Starts a message relay NOT linked to the calling process."
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    run_id = Keyword.fetch!(opts, :run_id)
    agent_names = Keyword.fetch!(opts, :agent_names)
    poll_interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)

    safe_subscribe()

    state = %{
      workspace_path: workspace_path,
      run_id: run_id,
      agent_names: agent_names,
      last_counts: Map.new(agent_names, fn name -> {name, 0} end),
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

  def handle_info(%{type: :mesh_completed}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp poll_outboxes(state) do
    Enum.reduce(state.agent_names, state, fn agent_name, acc ->
      poll_agent_outbox(acc, agent_name)
    end)
  end

  defp poll_agent_outbox(state, agent_name) do
    case InboxBridge.read_outbox(state.workspace_path, agent_name) do
      {:ok, entries} when is_list(entries) ->
        seen = Map.get(state.last_counts, agent_name, 0)
        new_entries = Enum.drop(entries, seen)

        Enum.each(new_entries, fn entry ->
          relay_message(state, agent_name, entry)

          safe_broadcast(:team_progress, %{
            run_id: state.run_id,
            team_name: agent_name,
            message: entry
          })
        end)

        %{state | last_counts: Map.put(state.last_counts, agent_name, length(entries))}

      _ ->
        state
    end
  end

  defp relay_message(state, from_agent, entry) do
    to = Map.get(entry, "to")

    if is_binary(to) and to != "" and to in state.agent_names and to != from_agent do
      message = %{
        from: from_agent,
        to: to,
        content: Map.get(entry, "content", ""),
        timestamp: Map.get(entry, "timestamp", DateTime.utc_now() |> DateTime.to_iso8601()),
        type: "mesh_message"
      }

      InboxBridge.deliver(state.workspace_path, to, message)
    end
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
