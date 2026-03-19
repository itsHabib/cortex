defmodule Cortex.GrpcHelpers do
  @moduledoc """
  Test helpers for gRPC integration tests.

  Provides functions to connect to the gRPC gateway, send agent messages,
  receive gateway messages, and assert PubSub events. These helpers abstract
  the gRPC client setup so integration tests can focus on behaviour verification.

  ## Dependencies

  These helpers depend on:
  - `Cortex.Gateway.GrpcServer` (Gateway gRPC Engineer) — the gRPC server
  - Generated proto modules (Proto & Codegen Engineer) — message types

  Until those modules exist, the integration tests using these helpers should
  be tagged `@tag :pending`.
  """

  alias Cortex.Gateway.Registry

  # -------------------------------------------------------------------
  # Connection helpers
  # -------------------------------------------------------------------

  @doc """
  Opens a gRPC Connect stream to localhost on the given port.

  Returns `{:ok, channel, stream}` where `channel` is the gRPC channel
  and `stream` is the bidirectional Connect stream handle.

  ## Options

    - `:timeout` — connection timeout in milliseconds (default 5000)

  ## Example

      {:ok, channel, stream} = GrpcHelpers.connect_grpc(port)
  """
  @spec connect_grpc(non_neg_integer(), keyword()) ::
          {:ok, term(), term()} | {:error, term()}
  def connect_grpc(port, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)

    # Connect to the gRPC server on localhost
    # Uses the stub gRPC client interfaces. When the grpc hex package
    # and proto codegen land, this will use:
    #   GRPC.Stub.connect("localhost:#{port}")
    # For now, this is a specification of the expected interface.
    try do
      {:ok, channel} =
        GRPC.Stub.connect("localhost:#{port}",
          interceptors: [],
          timeout: timeout
        )

      {:ok, stream} =
        channel
        |> Cortex.Gateway.Proto.AgentGateway.Stub.connect()

      {:ok, channel, stream}
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Disconnects a gRPC channel.
  """
  @spec disconnect(term()) :: :ok
  def disconnect(channel) do
    GRPC.Stub.disconnect(channel)
    :ok
  rescue
    _ -> :ok
  end

  # -------------------------------------------------------------------
  # Send helpers
  # -------------------------------------------------------------------

  @doc """
  Sends a RegisterRequest on the stream and waits for the RegisterResponse.

  Returns `{:ok, agent_id}` on success or `{:error, reason}` on failure.
  """
  @spec send_register(term(), String.t(), String.t(), [String.t()], String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def send_register(stream, name, role, capabilities, token) do
    msg =
      build_agent_message(:register, %{
        name: name,
        role: role,
        capabilities: capabilities,
        auth_token: token,
        metadata: %{}
      })

    GRPC.Stub.send_request(stream, msg)

    case receive_gateway_message(stream) do
      {:ok, %{registered: %{agent_id: agent_id}}} when is_binary(agent_id) ->
        {:ok, agent_id}

      {:ok, %{error: %{code: code, message: message}}} ->
        {:error, {code, message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a Heartbeat message on the stream.
  """
  @spec send_heartbeat(term(), String.t(), atom() | String.t(), map()) :: :ok | {:error, term()}
  def send_heartbeat(stream, agent_id, status, load \\ %{}) do
    status_value = normalize_agent_status(status)

    msg =
      build_agent_message(:heartbeat, %{
        agent_id: agent_id,
        status: status_value,
        active_tasks: Map.get(load, :active_tasks, 0),
        queue_depth: Map.get(load, :queue_depth, 0)
      })

    GRPC.Stub.send_request(stream, msg)
  end

  @doc """
  Sends a TaskResult message on the stream.
  """
  @spec send_task_result(term(), String.t(), atom() | String.t(), String.t()) ::
          :ok | {:error, term()}
  def send_task_result(stream, task_id, status, result_text) do
    status_value = normalize_task_status(status)

    msg =
      build_agent_message(:task_result, %{
        task_id: task_id,
        status: status_value,
        result_text: result_text,
        duration_ms: 1000,
        input_tokens: 100,
        output_tokens: 50
      })

    GRPC.Stub.send_request(stream, msg)
  end

  @doc """
  Sends a StatusUpdate message on the stream.
  """
  @spec send_status_update(term(), String.t(), atom() | String.t(), String.t()) ::
          :ok | {:error, term()}
  def send_status_update(stream, agent_id, status, detail \\ "") do
    status_value = normalize_agent_status(status)

    msg =
      build_agent_message(:status_update, %{
        agent_id: agent_id,
        status: status_value,
        detail: detail,
        progress: 0.0
      })

    GRPC.Stub.send_request(stream, msg)
  end

  @doc """
  Sends a PeerResponse message on the stream.
  """
  @spec send_peer_response(term(), String.t(), atom() | String.t(), String.t()) ::
          :ok | {:error, term()}
  def send_peer_response(stream, request_id, status, result) do
    status_value = normalize_task_status(status)

    msg =
      build_agent_message(:peer_response, %{
        request_id: request_id,
        status: status_value,
        result: result,
        duration_ms: 500
      })

    GRPC.Stub.send_request(stream, msg)
  end

  # -------------------------------------------------------------------
  # Receive helpers
  # -------------------------------------------------------------------

  @doc """
  Receives the next GatewayMessage from the stream.

  Blocks until a message arrives or the timeout expires.
  Returns `{:ok, message}` or `{:error, :timeout}`.
  """
  @spec receive_gateway_message(term(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout | term()}
  def receive_gateway_message(stream, timeout \\ 5000) do
    task =
      Task.async(fn ->
        GRPC.Stub.recv(stream)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, message}} -> {:ok, message}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  # -------------------------------------------------------------------
  # PubSub assertion helpers
  # -------------------------------------------------------------------

  @doc """
  Asserts that a gateway PubSub event of the given type is received.

  Subscribes to both `Cortex.Events` and `Cortex.Gateway.Events` topics.
  Returns the event payload on success.

  ## Options

    - `:timeout` — assertion timeout in milliseconds (default 5000)
    - `:payload` — expected payload fields to match (partial match)

  ## Example

      payload = assert_gateway_event(:agent_registered, timeout: 2000)
      assert payload.name == "test-agent"
  """
  @spec assert_gateway_event(atom(), keyword()) :: map()
  def assert_gateway_event(event_type, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    expected_payload = Keyword.get(opts, :payload, %{})

    receive do
      %{type: ^event_type, payload: payload} ->
        # Verify expected payload fields match
        for {key, value} <- expected_payload do
          actual = Map.get(payload, key)

          unless actual == value do
            raise ExUnit.AssertionError,
              message:
                "Expected #{inspect(event_type)} payload.#{key} to be #{inspect(value)}, got #{inspect(actual)}"
          end
        end

        payload
    after
      timeout ->
        raise ExUnit.AssertionError,
          message:
            "Expected to receive #{inspect(event_type)} event within #{timeout}ms, but none arrived"
    end
  end

  @doc """
  Subscribes the current process to both Cortex.Events and Gateway.Events PubSub topics.
  """
  @spec subscribe_to_events() :: :ok
  def subscribe_to_events do
    Cortex.Events.subscribe()
    Cortex.Gateway.Events.subscribe()
    :ok
  end

  # -------------------------------------------------------------------
  # Registry helpers
  # -------------------------------------------------------------------

  @doc """
  Clears all agents from the Gateway Registry.

  Used in test setup to ensure a clean state.
  """
  @spec clear_registry() :: :ok
  def clear_registry do
    for agent <- Registry.list() do
      Registry.unregister(agent.id)
    end

    :ok
  end

  @doc """
  Waits for a specific agent to appear in the Registry.

  Returns `{:ok, agent}` or `{:error, :timeout}`.
  """
  @spec wait_for_agent(String.t(), non_neg_integer()) ::
          {:ok, Cortex.Gateway.RegisteredAgent.t()} | {:error, :timeout}
  def wait_for_agent(agent_id, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_agent(agent_id, deadline)
  end

  defp do_wait_for_agent(agent_id, deadline) do
    case Registry.get(agent_id) do
      {:ok, agent} ->
        {:ok, agent}

      {:error, :not_found} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_wait_for_agent(agent_id, deadline)
        else
          {:error, :timeout}
        end
    end
  end

  # -------------------------------------------------------------------
  # Message builder helpers (internal)
  # -------------------------------------------------------------------

  # These build the protobuf AgentMessage wrapper with the appropriate
  # oneof field set. When proto codegen lands, these will use the
  # generated struct modules directly.

  defp build_agent_message(:register, fields) do
    %{register: struct_from_fields(:register_request, fields)}
  end

  defp build_agent_message(:heartbeat, fields) do
    %{heartbeat: struct_from_fields(:heartbeat, fields)}
  end

  defp build_agent_message(:task_result, fields) do
    %{task_result: struct_from_fields(:task_result, fields)}
  end

  defp build_agent_message(:status_update, fields) do
    %{status_update: struct_from_fields(:status_update, fields)}
  end

  defp build_agent_message(:peer_response, fields) do
    %{peer_response: struct_from_fields(:peer_response, fields)}
  end

  # Build a map representing a proto struct from fields.
  # When proto codegen lands, this will create actual generated structs.
  defp struct_from_fields(_type, fields) when is_map(fields), do: fields

  defp normalize_agent_status(:idle), do: :AGENT_STATUS_IDLE
  defp normalize_agent_status(:working), do: :AGENT_STATUS_WORKING
  defp normalize_agent_status(:draining), do: :AGENT_STATUS_DRAINING
  defp normalize_agent_status(:disconnected), do: :AGENT_STATUS_DISCONNECTED
  defp normalize_agent_status(other), do: other

  defp normalize_task_status(:completed), do: :TASK_STATUS_COMPLETED
  defp normalize_task_status(:failed), do: :TASK_STATUS_FAILED
  defp normalize_task_status(:cancelled), do: :TASK_STATUS_CANCELLED
  defp normalize_task_status(other), do: other
end
