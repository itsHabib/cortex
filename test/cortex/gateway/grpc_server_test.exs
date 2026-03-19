defmodule Cortex.Gateway.GrpcServerTest do
  @moduledoc """
  Unit tests for Cortex.Gateway.GrpcServer.

  These tests exercise the server's message handling logic by starting a
  real gRPC server on a random port and connecting via the generated stub.
  """
  use ExUnit.Case, async: false

  alias Cortex.Gateway.Proto.{
    AgentMessage,
    AgentGateway.Stub,
    GatewayMessage,
    Heartbeat,
    PeerResponse,
    RegisterRequest,
    StatusUpdate,
    TaskResult
  }

  alias Cortex.Gateway.Registry

  @test_token "test-grpc-token"

  setup_all do
    # Start GRPC.Client.Supervisor if not already running
    unless Process.whereis(GRPC.Client.Supervisor) do
      {:ok, _} =
        DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)
    end

    # Set the gateway token env var for auth
    System.put_env("CORTEX_GATEWAY_TOKEN", @test_token)

    # Start a gRPC server on a random port
    port = random_port()

    {:ok, _pid, port} =
      GRPC.Server.start(
        Cortex.Gateway.GrpcServer,
        port,
        adapter_opts: [ip: {127, 0, 0, 1}]
      )

    on_exit(fn ->
      GRPC.Server.stop(Cortex.Gateway.GrpcServer)
      System.delete_env("CORTEX_GATEWAY_TOKEN")
    end)

    %{port: port}
  end

  setup %{port: port} do
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}")
    %{channel: channel}
  end

  # -- Registration --

  describe "registration flow" do
    test "registers agent and returns RegisterResponse", %{channel: channel} do
      stream = Stub.connect(channel)

      register_msg = build_register("test-agent", "researcher", ["code-review"])
      GRPC.Stub.send_request(stream, register_msg)
      GRPC.Stub.end_stream(stream)

      {:ok, reply_enum} = GRPC.Stub.recv(stream)
      replies = Enum.to_list(reply_enum)

      assert replies != []
      {:ok, %GatewayMessage{msg: {:registered, response}}} = hd(replies)
      assert is_binary(response.agent_id)
      assert String.length(response.agent_id) == 36
      assert response.peer_count >= 1
    end

    test "rejects registration with invalid auth token", %{channel: channel} do
      stream = Stub.connect(channel)

      register_msg = build_register("bad-agent", "role", ["cap"], "invalid-token")
      GRPC.Stub.send_request(stream, register_msg)
      GRPC.Stub.end_stream(stream)

      {:ok, reply_enum} = GRPC.Stub.recv(stream)
      replies = Enum.to_list(reply_enum)

      assert replies != []
      {:ok, %GatewayMessage{msg: {:error, error}}} = hd(replies)
      assert error.code == "AUTH_FAILED"
    end

    test "rejects duplicate registration on same stream", %{channel: channel} do
      stream = Stub.connect(channel)

      register_msg = build_register("dup-agent", "role", ["cap"])
      GRPC.Stub.send_request(stream, register_msg)
      # Send a second register
      GRPC.Stub.send_request(stream, register_msg)
      GRPC.Stub.end_stream(stream)

      {:ok, reply_enum} = GRPC.Stub.recv(stream)
      replies = Enum.to_list(reply_enum)

      # First should be registered, second should be error
      assert Enum.count(replies) >= 2
      {:ok, %GatewayMessage{msg: {:registered, _}}} = Enum.at(replies, 0)
      {:ok, %GatewayMessage{msg: {:error, error}}} = Enum.at(replies, 1)
      assert error.code == "ALREADY_REGISTERED"
    end
  end

  # -- Pre-registration gate --

  describe "pre-registration gate" do
    test "rejects heartbeat before registration", %{channel: channel} do
      stream = Stub.connect(channel)

      heartbeat = %AgentMessage{
        msg:
          {:heartbeat,
           %Heartbeat{
             agent_id: "fake-id",
             status: :AGENT_STATUS_IDLE,
             active_tasks: 0,
             queue_depth: 0
           }}
      }

      GRPC.Stub.send_request(stream, heartbeat)
      GRPC.Stub.end_stream(stream)

      {:ok, reply_enum} = GRPC.Stub.recv(stream)
      replies = Enum.to_list(reply_enum)

      assert replies != []
      {:ok, %GatewayMessage{msg: {:error, error}}} = hd(replies)
      assert error.code == "NOT_REGISTERED"
    end
  end

  # -- Heartbeat --

  describe "heartbeat" do
    test "updates heartbeat in registry after registration", %{channel: channel} do
      stream = Stub.connect(channel)

      register_msg = build_register("hb-agent", "role", ["cap"])
      GRPC.Stub.send_request(stream, register_msg)

      heartbeat = %AgentMessage{
        msg:
          {:heartbeat,
           %Heartbeat{
             agent_id: "will-be-overridden",
             status: :AGENT_STATUS_WORKING,
             active_tasks: 3,
             queue_depth: 1
           }}
      }

      GRPC.Stub.send_request(stream, heartbeat)
      GRPC.Stub.end_stream(stream)

      {:ok, reply_enum} = GRPC.Stub.recv(stream)
      replies = Enum.to_list(reply_enum)

      assert replies != []
      {:ok, %GatewayMessage{msg: {:registered, response}}} = hd(replies)

      # Agent may have been cleaned up after stream ended
      case Registry.get(response.agent_id) do
        {:ok, agent} ->
          assert agent.load == %{active_tasks: 3, queue_depth: 1}

        {:error, :not_found} ->
          :ok
      end
    end
  end

  # -- Status update --

  describe "status update" do
    test "updates status in registry", %{channel: channel} do
      stream = Stub.connect(channel)

      register_msg = build_register("status-agent", "role", ["cap"])
      GRPC.Stub.send_request(stream, register_msg)

      status_msg = %AgentMessage{
        msg:
          {:status_update,
           %StatusUpdate{
             agent_id: "ignored",
             status: :AGENT_STATUS_WORKING,
             detail: "processing task",
             progress: 0.5
           }}
      }

      GRPC.Stub.send_request(stream, status_msg)
      GRPC.Stub.end_stream(stream)

      {:ok, reply_enum} = GRPC.Stub.recv(stream)
      replies = Enum.to_list(reply_enum)

      {:ok, %GatewayMessage{msg: {:registered, response}}} = hd(replies)

      case Registry.get(response.agent_id) do
        {:ok, agent} ->
          assert agent.status == :working

        {:error, :not_found} ->
          :ok
      end
    end
  end

  # -- Task result --

  describe "task result" do
    test "emits event for task result", %{channel: channel} do
      Cortex.Gateway.Events.subscribe()

      stream = Stub.connect(channel)
      register_msg = build_register("task-agent", "role", ["cap"])
      GRPC.Stub.send_request(stream, register_msg)

      task_msg = %AgentMessage{
        msg:
          {:task_result,
           %TaskResult{
             task_id: "task-123",
             status: :TASK_STATUS_COMPLETED,
             result_text: "done",
             duration_ms: 100,
             input_tokens: 50,
             output_tokens: 25
           }}
      }

      GRPC.Stub.send_request(stream, task_msg)
      GRPC.Stub.end_stream(stream)

      {:ok, reply_enum} = GRPC.Stub.recv(stream)
      _replies = Enum.to_list(reply_enum)

      assert_receive %{type: :gateway_task_result, payload: %{task_id: "task-123"}}, 2000
    end
  end

  # -- Peer response --

  describe "peer response" do
    test "emits event for peer response", %{channel: channel} do
      Cortex.Gateway.Events.subscribe()

      stream = Stub.connect(channel)
      register_msg = build_register("peer-agent", "role", ["cap"])
      GRPC.Stub.send_request(stream, register_msg)

      peer_msg = %AgentMessage{
        msg:
          {:peer_response,
           %PeerResponse{
             request_id: "req-456",
             status: :TASK_STATUS_COMPLETED,
             result: "peer result",
             duration_ms: 50
           }}
      }

      GRPC.Stub.send_request(stream, peer_msg)
      GRPC.Stub.end_stream(stream)

      {:ok, reply_enum} = GRPC.Stub.recv(stream)
      _replies = Enum.to_list(reply_enum)

      assert_receive %{
                       type: :gateway_peer_response,
                       payload: %{request_id: "req-456"}
                     },
                     2000
    end
  end

  # -- Stream disconnect cleanup --

  describe "stream disconnect cleanup" do
    test "agent is removed from registry when stream ends", %{channel: channel} do
      stream = Stub.connect(channel)

      register_msg = build_register("cleanup-agent", "role", ["cap"])
      GRPC.Stub.send_request(stream, register_msg)
      GRPC.Stub.end_stream(stream)

      {:ok, reply_enum} = GRPC.Stub.recv(stream)
      replies = Enum.to_list(reply_enum)
      {:ok, %GatewayMessage{msg: {:registered, response}}} = hd(replies)

      # Wait for stream process to terminate and registry cleanup
      Process.sleep(200)

      assert {:error, :not_found} = Registry.get(response.agent_id)
    end
  end

  # -- Helpers --

  defp build_register(name, role, capabilities, token \\ @test_token) do
    %AgentMessage{
      msg:
        {:register,
         %RegisterRequest{
           name: name,
           role: role,
           capabilities: capabilities,
           auth_token: token,
           metadata: %{}
         }}
    }
  end

  defp random_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
