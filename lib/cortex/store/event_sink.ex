defmodule Cortex.Store.EventSink do
  @moduledoc """
  GenServer that subscribes to Cortex.Events PubSub and persists
  all events to the EventLog table.

  This provides a durable event log for replay, debugging, and
  analytics. Events are written synchronously on receipt — for
  high-throughput scenarios, batching can be added later.
  """
  use GenServer

  require Logger

  alias Cortex.Store

  # ── Client API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── Server Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Cortex.Events.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info(%{type: type, payload: payload, timestamp: _timestamp}, state) do
    run_id = extract_run_id(payload)

    # Convert payload to string-keyed map for JSON storage
    safe_payload = stringify_payload(payload)

    attrs = %{
      event_type: Atom.to_string(type),
      run_id: run_id,
      payload: safe_payload,
      source: "pubsub"
    }

    try do
      case Store.log_event(attrs) do
        {:ok, _event} ->
          :ok

        {:error, changeset} ->
          Logger.warning("EventSink failed to persist event: #{inspect(changeset.errors)}")
      end
    rescue
      e ->
        Logger.warning("EventSink DB unavailable: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  # Ignore messages that don't match the event shape
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp extract_run_id(%{run_id: run_id}) when is_binary(run_id), do: run_id
  defp extract_run_id(_), do: nil

  defp stringify_payload(payload) when is_map(payload) do
    payload
    |> Map.drop([:run_id])
    |> Enum.map(fn {k, v} -> {to_string(k), stringify_value(v)} end)
    |> Map.new()
  end

  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v) when is_pid(v), do: inspect(v)
  defp stringify_value(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp stringify_value(v) when is_map(v), do: stringify_payload(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v), do: v
end
