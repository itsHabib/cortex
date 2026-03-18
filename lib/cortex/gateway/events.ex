defmodule Cortex.Gateway.Events do
  @moduledoc """
  PubSub helper for broadcasting and subscribing to gateway-specific events.

  All gateway events are published on the `"cortex:gateway"` topic using
  Phoenix.PubSub. This is separate from the main `"cortex:events"` topic
  to avoid heartbeat noise reaching existing LiveView subscribers.

  ## Event shape

  Each broadcast message is a map with three keys, matching `Cortex.Events`:

      %{
        type: atom(),        # e.g. :agent_registered, :agent_unregistered
        payload: map(),      # arbitrary data relevant to the event
        timestamp: DateTime  # UTC timestamp of when the event was emitted
      }

  ## Usage

      # Subscribe the current process to gateway events:
      Cortex.Gateway.Events.subscribe()

      # Broadcast an event:
      Cortex.Gateway.Events.broadcast(:agent_registered, %{agent_id: "abc-123"})

      # Receive in a LiveView or GenServer:
      def handle_info(%{type: :agent_registered, payload: payload}, state) do
        # ...
      end
  """

  @pubsub Cortex.PubSub
  @topic "cortex:gateway"

  @type event_type :: atom()

  @doc """
  Subscribes the calling process to the `"cortex:gateway"` PubSub topic.

  The process will receive all gateway events broadcast via `broadcast/2`
  as messages in its mailbox.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Broadcasts a gateway event to all subscribers on the `"cortex:gateway"` topic.

  The broadcast message is a map with `:type`, `:payload`, and `:timestamp` keys,
  matching the shape used by `Cortex.Events`.

  Uses a safe broadcast pattern — rescues PubSub errors and returns `:ok`
  to avoid crashing the caller on transient failures.
  """
  @spec broadcast(event_type(), map()) :: :ok | {:error, term()}
  def broadcast(type, payload \\ %{}) when is_atom(type) and is_map(payload) do
    message = %{
      type: type,
      payload: payload,
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(@pubsub, @topic, message)
  rescue
    _ -> :ok
  end

  @doc """
  Returns the PubSub topic string used for gateway events.
  """
  @spec topic() :: String.t()
  def topic, do: @topic
end
