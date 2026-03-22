defmodule Cortex.Provider.External.TaskPush do
  @moduledoc """
  Stateless module for pushing `TaskRequest` messages to sidecar-connected agents.

  Supports two transport types:

    - `:grpc` — sends a `GatewayMessage` with a `TaskRequest` payload to the
      agent's gRPC stream process via `send/2`.
    - `:websocket` — sends a `{:push_to_agent, "task_request", payload}` tuple
      to the agent's Phoenix Channel process via `send/2`.

  Both paths check `Process.alive?/1` before sending to catch the common case
  of a dead transport pid. The TOCTOU race between the check and the send is
  acceptable because `Provider.External` has its own timeout as a backstop.

  This module has no process, no state, and no GenServer — it is a pure
  dispatch function.
  """

  require Logger

  alias Cortex.Gateway.Proto.{GatewayMessage, TaskRequest}

  @typedoc "Transport type for agent connections."
  @type transport :: :grpc | :websocket

  @doc """
  Pushes a `TaskRequest` to an agent via the given transport.

  ## Parameters

    - `transport` — `:grpc` or `:websocket`
    - `pid` — the gRPC stream pid or WebSocket channel pid
    - `task_request` — map with keys: `"task_id"`, `"prompt"`, `"tools"`,
      `"timeout_ms"`, `"context"`

  ## Returns

    - `{:ok, :sent}` — message was sent to the transport process
    - `{:error, :transport_down}` — the transport pid is not alive
    - `{:error, :send_failed}` — an unexpected error occurred during send
    - `{:error, :unknown_transport}` — unrecognized transport atom

  ## Examples

      iex> TaskPush.push(:grpc, stream_pid, %{"task_id" => "abc", "prompt" => "hello", ...})
      {:ok, :sent}

      iex> TaskPush.push(:websocket, dead_pid, %{"task_id" => "abc", ...})
      {:error, :transport_down}
  """
  @spec push(transport(), pid(), map()) ::
          {:ok, :sent} | {:error, :transport_down | :send_failed | :unknown_transport}
  def push(:grpc, pid, task_request) when is_pid(pid) and is_map(task_request) do
    if Process.alive?(pid) do
      do_push_grpc(pid, task_request)
    else
      {:error, :transport_down}
    end
  end

  def push(:websocket, pid, task_request) when is_pid(pid) and is_map(task_request) do
    if Process.alive?(pid) do
      do_push_websocket(pid, task_request)
    else
      {:error, :transport_down}
    end
  end

  def push(transport, _pid, _task_request) when transport not in [:grpc, :websocket] do
    {:error, :unknown_transport}
  end

  # -- Private --

  defp do_push_grpc(pid, task_request) do
    # context is a protobuf map field — pass a plain Elixir map, not ContextEntry structs
    context = task_request["context"] || %{}

    proto_request = %TaskRequest{
      task_id: task_request["task_id"],
      prompt: task_request["prompt"],
      tools: task_request["tools"] || [],
      timeout_ms: task_request["timeout_ms"] || 0,
      context: context
    }

    gateway_msg = %GatewayMessage{
      msg: {:task_request, proto_request}
    }

    send(pid, {:push_gateway_message, gateway_msg})

    Cortex.Telemetry.emit_gateway_task_dispatched(%{
      task_id: task_request["task_id"],
      agent_id: task_request["agent_id"]
    })

    {:ok, :sent}
  rescue
    error ->
      Logger.error("TaskPush: gRPC push failed — #{inspect(error)}")
      {:error, :send_failed}
  end

  defp do_push_websocket(pid, task_request) do
    payload = %{
      "task_id" => task_request["task_id"],
      "prompt" => task_request["prompt"],
      "tools" => task_request["tools"] || [],
      "timeout_ms" => task_request["timeout_ms"] || 0,
      "context" => task_request["context"] || %{}
    }

    send(pid, {:push_to_agent, "task_request", payload})

    Cortex.Telemetry.emit_gateway_task_dispatched(%{
      task_id: task_request["task_id"],
      agent_id: task_request["agent_id"]
    })

    {:ok, :sent}
  rescue
    error ->
      Logger.error("TaskPush: WebSocket push failed — #{inspect(error)}")
      {:error, :send_failed}
  end
end
