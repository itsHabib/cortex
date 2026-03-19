defmodule Cortex.Gateway.GrpcServer do
  @moduledoc """
  gRPC server implementation for the AgentGateway.Connect bidirectional stream.

  Handles agent registration, heartbeats, task results, status updates,
  peer responses, direct messages, and broadcasts over a single gRPC stream
  per agent. Writes to the same `Gateway.Registry` as the Phoenix Channel
  control plane, emitting identical PubSub events.

  ## Stream lifecycle

  1. Client opens a `Connect` stream
  2. First message MUST be a `RegisterRequest` with a valid auth token
  3. Server responds with `RegisterResponse`
  4. Both sides exchange messages for the lifetime of the connection
  5. On disconnect, the agent is automatically unregistered via `Process.monitor`

  ## Message handling

  Messages received before a successful `RegisterRequest` are rejected with
  an `Error` response. The stream process holds only transient state (agent_id,
  registration flag); all durable state lives in `Gateway.Registry`.
  """

  use GRPC.Server, service: Cortex.Gateway.Proto.AgentGateway.Service

  require Logger

  alias Cortex.Gateway.{Auth, Events, Registry}

  alias Cortex.Gateway.Proto.{
    AgentMessage,
    BroadcastRequest,
    DirectMessage,
    Error,
    GatewayMessage,
    Heartbeat,
    PeerResponse,
    RegisterRequest,
    RegisterResponse,
    StatusUpdate,
    TaskResult
  }

  @doc """
  Handles the bidirectional Connect stream.

  Receives an `Enumerable.t()` of `AgentMessage` structs and processes each
  one sequentially, sending replies via `GRPC.Server.send_reply/2`.
  """
  @spec connect(Enumerable.t(), GRPC.Server.Stream.t()) :: any()
  def connect(request_enum, stream) do
    state = %{
      agent_id: nil,
      registered: false,
      stream: stream
    }

    _final_state =
      Enum.reduce(request_enum, state, fn msg, acc ->
        handle_agent_message(msg, acc)
      end)

    stream
  end

  # -- Message dispatch --

  defp handle_agent_message(%AgentMessage{msg: {:register, register_req}}, state) do
    handle_register(register_req, state)
  end

  defp handle_agent_message(%AgentMessage{msg: {:heartbeat, heartbeat}}, state) do
    handle_heartbeat(heartbeat, state)
  end

  defp handle_agent_message(%AgentMessage{msg: {:task_result, task_result}}, state) do
    handle_task_result(task_result, state)
  end

  defp handle_agent_message(%AgentMessage{msg: {:status_update, status_update}}, state) do
    handle_status_update(status_update, state)
  end

  defp handle_agent_message(%AgentMessage{msg: {:peer_response, peer_response}}, state) do
    handle_peer_response(peer_response, state)
  end

  defp handle_agent_message(%AgentMessage{msg: {:direct_message, dm}}, state) do
    handle_direct_message(dm, state)
  end

  defp handle_agent_message(%AgentMessage{msg: {:broadcast, broadcast}}, state) do
    handle_broadcast(broadcast, state)
  end

  defp handle_agent_message(_unknown, state) do
    if state.registered do
      push_error(state.stream, "INVALID_MESSAGE", "Unknown or empty message type")
    end

    state
  end

  # -- Registration --

  defp handle_register(%RegisterRequest{} = req, %{registered: true} = state) do
    push_error(
      state.stream,
      "ALREADY_REGISTERED",
      "Agent already registered with id #{state.agent_id}. " <>
        "Registration request for '#{req.name}' rejected."
    )

    state
  end

  defp handle_register(%RegisterRequest{} = req, state) do
    case Auth.authenticate(req.auth_token) do
      {:ok, _identity} ->
        do_register(req, state)

      {:error, :unauthorized} ->
        push_error(state.stream, "AUTH_FAILED", "Invalid or missing auth token")
        state
    end
  end

  defp do_register(%RegisterRequest{} = req, state) do
    agent_info = %{
      "name" => req.name,
      "role" => req.role,
      "capabilities" => req.capabilities,
      "metadata" => Map.new(req.metadata || [])
    }

    case Registry.register_grpc(agent_info, self()) do
      {:ok, agent} ->
        :telemetry.execute(
          [:cortex, :gateway, :grpc, :connect],
          %{count: 1},
          %{agent_id: agent.id, name: agent.name}
        )

        peer_count = Registry.count()

        response =
          %GatewayMessage{
            msg:
              {:registered,
               %RegisterResponse{
                 agent_id: agent.id,
                 peer_count: peer_count,
                 run_id: ""
               }}
          }

        GRPC.Server.send_reply(state.stream, response)

        Events.broadcast(:gateway_agent_registered, %{
          agent_id: agent.id,
          name: agent.name,
          role: agent.role,
          capabilities: agent.capabilities
        })

        %{state | agent_id: agent.id, registered: true}

      {:error, reason} ->
        push_error(state.stream, "REGISTRATION_FAILED", "Registration failed: #{inspect(reason)}")
        state
    end
  end

  # -- Registration gate --

  defp require_registered(state, callback) do
    if state.registered do
      callback.()
    else
      push_error(state.stream, "NOT_REGISTERED", "Must register before sending other messages")
      state
    end
  end

  # -- Heartbeat --

  defp handle_heartbeat(%Heartbeat{} = hb, state) do
    require_registered(state, fn ->
      load = %{active_tasks: hb.active_tasks, queue_depth: hb.queue_depth}
      Registry.update_heartbeat(state.agent_id, load)

      :telemetry.execute(
        [:cortex, :gateway, :grpc, :heartbeat],
        %{count: 1},
        %{agent_id: state.agent_id}
      )

      state
    end)
  end

  # -- Task result --

  defp handle_task_result(%TaskResult{} = result, state) do
    require_registered(state, fn ->
      Events.broadcast(:gateway_task_result, %{
        agent_id: state.agent_id,
        task_id: result.task_id,
        status: result.status,
        result_text: result.result_text,
        duration_ms: result.duration_ms
      })

      Registry.route_task_result(result.task_id, %{
        "status" => to_string(result.status),
        "result_text" => result.result_text,
        "duration_ms" => result.duration_ms,
        "input_tokens" => result.input_tokens,
        "output_tokens" => result.output_tokens
      })

      state
    end)
  end

  # -- Status update --

  defp handle_status_update(%StatusUpdate{} = update, state) do
    require_registered(state, fn ->
      status_atom = proto_status_to_atom(update.status)

      case Registry.update_status(state.agent_id, status_atom) do
        :ok ->
          Events.broadcast(:gateway_agent_status_changed, %{
            agent_id: state.agent_id,
            status: to_string(status_atom),
            detail: update.detail
          })

        {:error, reason} ->
          push_error(
            state.stream,
            "STATUS_UPDATE_FAILED",
            "Status update failed: #{inspect(reason)}"
          )
      end

      state
    end)
  end

  # -- Peer response --

  defp handle_peer_response(%PeerResponse{} = response, state) do
    require_registered(state, fn ->
      Events.broadcast(:gateway_peer_response, %{
        agent_id: state.agent_id,
        request_id: response.request_id,
        status: response.status,
        result: response.result
      })

      state
    end)
  end

  # -- Direct message --

  defp handle_direct_message(%DirectMessage{} = dm, state) do
    require_registered(state, fn ->
      case Registry.get_push_pid(dm.to_agent) do
        {:ok, {:grpc, target_pid}} ->
          send(target_pid, {:push_gateway_message, build_direct_message(dm, state.agent_id)})

        {:ok, {:websocket, channel_pid}} ->
          payload = %{
            "message_id" => dm.message_id,
            "from_agent" => state.agent_id,
            "content" => dm.content,
            "timestamp" => dm.timestamp
          }

          send(channel_pid, {:push_to_agent, "direct_message", payload})

        {:error, :not_found} ->
          push_error(
            state.stream,
            "AGENT_NOT_FOUND",
            "Target agent '#{dm.to_agent}' not found"
          )
      end

      state
    end)
  end

  # -- Broadcast --

  defp handle_broadcast(%BroadcastRequest{} = broadcast, state) do
    require_registered(state, fn ->
      agents = Registry.list()

      inner_dm = %DirectMessage{
        message_id: Ecto.UUID.generate(),
        content: broadcast.content,
        timestamp: System.system_time(:millisecond)
      }

      gateway_msg = build_direct_message(inner_dm, state.agent_id)

      agents
      |> Enum.reject(fn agent -> agent.id == state.agent_id end)
      |> Enum.each(fn agent ->
        push_to_agent(agent, gateway_msg, inner_dm, state.agent_id)
      end)

      state
    end)
  end

  defp push_to_agent(%{transport: :grpc, stream_pid: pid}, gateway_msg, _inner_dm, _from_id)
       when is_pid(pid) do
    send(pid, {:push_gateway_message, gateway_msg})
  end

  defp push_to_agent(%{transport: :websocket, channel_pid: pid}, _gateway_msg, inner_dm, from_id)
       when is_pid(pid) do
    payload = %{
      "message_id" => inner_dm.message_id,
      "from_agent" => from_id,
      "content" => inner_dm.content,
      "timestamp" => inner_dm.timestamp
    }

    send(pid, {:push_to_agent, "direct_message", payload})
  end

  defp push_to_agent(_agent, _gateway_msg, _inner_dm, _from_id), do: :ok

  # -- Helpers --

  defp push_error(stream, code, message) do
    error_msg = %GatewayMessage{
      msg: {:error, %Error{code: code, message: message}}
    }

    GRPC.Server.send_reply(stream, error_msg)
  end

  defp build_direct_message(%DirectMessage{} = dm, from_agent_id) do
    %GatewayMessage{
      msg:
        {:direct_message,
         %DirectMessage{
           message_id: dm.message_id || Ecto.UUID.generate(),
           to_agent: dm.to_agent || "",
           from_agent: from_agent_id,
           content: dm.content,
           timestamp: dm.timestamp || System.system_time(:millisecond)
         }}
    }
  end

  defp proto_status_to_atom(status) do
    case status do
      :AGENT_STATUS_IDLE -> :idle
      :AGENT_STATUS_WORKING -> :working
      :AGENT_STATUS_DRAINING -> :draining
      :AGENT_STATUS_DISCONNECTED -> :disconnected
      _ -> :idle
    end
  end
end
