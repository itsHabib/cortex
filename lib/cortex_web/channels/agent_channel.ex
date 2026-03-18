defmodule CortexWeb.AgentChannel do
  @moduledoc """
  Phoenix Channel for the agent gateway lobby (`"agent:lobby"`).

  This is a thin routing layer that delegates message validation to
  `Gateway.Protocol` and state management to `Gateway.Registry`.
  All durable agent state lives in the Registry; the channel stores
  only minimal assigns in the socket.

  ## Inbound messages

  | Event             | Gate          | Delegates to                  |
  |-------------------|---------------|-------------------------------|
  | `"register"`      | not yet registered | Protocol + Registry      |
  | `"heartbeat"`     | registered    | Registry.update_heartbeat     |
  | `"task_result"`   | registered    | Protocol validation + ack     |
  | `"status_update"` | registered    | Registry.update_status        |

  ## Outbound messages (server-initiated via `handle_info`)

  | Event             | Trigger                             |
  |-------------------|-------------------------------------|
  | `"task_request"`  | Orchestration dispatches work       |
  | `"peer_request"`  | Another agent invokes this one      |

  ## Registration timeout

  Agents have 30 seconds after joining to send a `"register"` message.
  If they do not, the channel is stopped.
  """

  use CortexWeb, :channel

  require Logger

  alias Cortex.Gateway.{Events, Protocol, Registry}

  @registration_timeout_ms 30_000

  # -- Join --

  @impl true
  @doc """
  Handles an agent joining the `"agent:lobby"` topic.

  Sets initial assigns and starts the registration timeout timer.
  """
  @spec join(String.t(), map(), Phoenix.Socket.t()) ::
          {:ok, Phoenix.Socket.t()} | {:error, map()}
  def join("agent:lobby", _payload, socket) do
    Process.send_after(self(), :registration_timeout, @registration_timeout_ms)

    socket =
      socket
      |> assign(:agent_id, nil)
      |> assign(:agent_name, nil)
      |> assign(:registered, false)
      |> assign(:joined_at, DateTime.utc_now())

    {:ok, socket}
  end

  def join(_topic, _payload, _socket) do
    {:error, %{"reason" => "invalid_topic"}}
  end

  # -- Inbound: register --

  @impl true
  def handle_in("register", payload, socket) do
    if socket.assigns.registered do
      {:reply,
       {:error,
        %{
          "reason" => "already_registered",
          "detail" => "Agent already registered with id #{socket.assigns.agent_id}"
        }}, socket}
    else
      handle_register(payload, socket)
    end
  end

  # -- Inbound: heartbeat (registration gate) --

  def handle_in("heartbeat", _payload, %{assigns: %{registered: false}} = socket) do
    {:reply, {:error, not_registered_error()}, socket}
  end

  def handle_in("heartbeat", payload, socket) do
    handle_heartbeat(payload, socket)
  end

  # -- Inbound: task_result (registration gate) --

  def handle_in("task_result", _payload, %{assigns: %{registered: false}} = socket) do
    {:reply, {:error, not_registered_error()}, socket}
  end

  def handle_in("task_result", payload, socket) do
    handle_task_result(payload, socket)
  end

  # -- Inbound: status_update (registration gate) --

  def handle_in("status_update", _payload, %{assigns: %{registered: false}} = socket) do
    {:reply, {:error, not_registered_error()}, socket}
  end

  def handle_in("status_update", payload, socket) do
    handle_status_update(payload, socket)
  end

  # -- Catch-all for unknown events --

  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{"reason" => "unknown_event", "detail" => "Unknown event: #{event}"}},
     socket}
  end

  # -- Server-initiated pushes --

  @impl true
  def handle_info({:push_to_agent, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  # -- Registration timeout --

  def handle_info(:registration_timeout, socket) do
    if socket.assigns.registered do
      {:noreply, socket}
    else
      Logger.warning("AgentChannel: registration timeout — disconnecting unregistered agent")
      {:stop, :normal, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Terminate --

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:registered] && socket.assigns[:agent_id] do
      agent_id = socket.assigns.agent_id

      Registry.unregister(agent_id)

      Events.broadcast(:gateway_agent_disconnected, %{
        agent_id: agent_id,
        name: socket.assigns[:agent_name]
      })

      Logger.info("AgentChannel: agent #{agent_id} disconnected")
    end

    :ok
  end

  # -- Private helpers --

  defp handle_register(payload, socket) do
    with :ok <- check_protocol_version(payload),
         {:ok, register_msg} <- Protocol.validate_register(payload) do
      agent_info = %{
        "name" => register_msg.name,
        "role" => register_msg.role,
        "capabilities" => register_msg.capabilities,
        "metadata" => register_msg.metadata
      }

      case Registry.register(agent_info, self()) do
        {:ok, agent} ->
          socket =
            socket
            |> assign(:agent_id, agent.id)
            |> assign(:agent_name, agent.name)
            |> assign(:registered, true)

          Events.broadcast(:gateway_agent_registered, %{
            agent_id: agent.id,
            name: agent.name,
            role: agent.role,
            capabilities: agent.capabilities
          })

          reply_payload = %{
            "type" => "registered",
            "agent_id" => agent.id
          }

          {:reply, {:ok, reply_payload}, socket}

        {:error, reason} ->
          {:reply,
           {:error,
            %{
              "reason" => "registration_failed",
              "detail" => inspect(reason)
            }}, socket}
      end
    else
      {:error, reasons} ->
        {:reply, {:error, validation_error(reasons)}, socket}
    end
  rescue
    error ->
      Logger.error("AgentChannel: registration error — #{inspect(error)}")

      {:reply,
       {:error,
        %{
          "reason" => "service_unavailable",
          "detail" => "Internal error during registration"
        }}, socket}
  end

  defp handle_heartbeat(payload, socket) do
    case Protocol.validate_heartbeat(payload) do
      {:ok, heartbeat_msg} ->
        agent_id = socket.assigns.agent_id

        if heartbeat_msg.agent_id != agent_id do
          {:reply,
           {:error,
            %{
              "reason" => "agent_id_mismatch",
              "detail" =>
                "Heartbeat agent_id #{heartbeat_msg.agent_id} does not match registered id #{agent_id}"
            }}, socket}
        else
          load = heartbeat_msg.load || %{}
          Registry.update_heartbeat(agent_id, load)

          {:reply, {:ok, %{"type" => "heartbeat_ack"}}, socket}
        end

      {:error, reasons} ->
        {:reply, {:error, validation_error(reasons)}, socket}
    end
  end

  defp handle_task_result(payload, socket) do
    case Protocol.validate_task_result(payload) do
      {:ok, _task_result_msg} ->
        {:reply, {:ok, %{}}, socket}

      {:error, reasons} ->
        {:reply, {:error, validation_error(reasons)}, socket}
    end
  end

  defp handle_status_update(payload, socket) do
    case Protocol.validate_status_update(payload) do
      {:ok, status_msg} ->
        agent_id = socket.assigns.agent_id
        status_atom = String.to_existing_atom(status_msg.status)
        detail = status_msg.detail || ""

        Registry.update_status(agent_id, status_atom)

        Events.broadcast(:gateway_agent_status_changed, %{
          agent_id: agent_id,
          status: status_msg.status,
          detail: detail
        })

        {:reply, {:ok, %{}}, socket}

      {:error, reasons} ->
        {:reply, {:error, validation_error(reasons)}, socket}
    end
  end

  defp not_registered_error do
    %{
      "reason" => "not_registered",
      "detail" => "Must send 'register' message before other operations"
    }
  end

  defp validation_error(reasons) do
    %{
      "reason" => "invalid_payload",
      "detail" => Enum.join(List.wrap(reasons), "; ")
    }
  end

  defp check_protocol_version(%{"protocol_version" => v}) do
    if v in Protocol.supported_versions() do
      :ok
    else
      supported = inspect(Protocol.supported_versions())
      {:error, ["unsupported protocol version: #{v}, supported: #{supported}"]}
    end
  end

  defp check_protocol_version(_) do
    {:error, ["missing required field: protocol_version"]}
  end
end
