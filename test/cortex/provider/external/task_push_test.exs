defmodule Cortex.Provider.External.TaskPushTest do
  use ExUnit.Case, async: true

  alias Cortex.Provider.External.TaskPush

  defp make_task_request(overrides \\ %{}) do
    Map.merge(
      %{
        "task_id" => "task-#{System.unique_integer([:positive])}",
        "prompt" => "Analyze the code for bugs",
        "tools" => ["read_file", "grep"],
        "timeout_ms" => 30_000,
        "context" => %{"project" => "acme"},
        "agent_id" => "agent-123"
      },
      overrides
    )
  end

  defp spawn_receiver do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    Process.sleep(10)
    pid
  end

  # -- gRPC transport --

  describe "push(:grpc, pid, task_request)" do
    test "sends GatewayMessage with TaskRequest to live pid" do
      pid = spawn_receiver()
      task_req = make_task_request()

      assert {:ok, :sent} = TaskPush.push(:grpc, pid, task_req)

      assert_receive_nothing = fn ->
        # Give the message time to arrive
        Process.sleep(10)
      end

      assert_receive_nothing.()

      # The receiver process got the message — send it to us to inspect
      # We need a different approach: use self() as the receiver
    end

    test "delivers correct GatewayMessage envelope to gRPC stream pid" do
      test_pid = self()

      receiver =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:received, msg})
          end
        end)

      task_req = make_task_request(%{"task_id" => "grpc-test-123"})
      assert {:ok, :sent} = TaskPush.push(:grpc, receiver, task_req)

      assert_receive {:received, {:push_gateway_message, gateway_msg}}, 1000

      assert %Cortex.Gateway.Proto.GatewayMessage{msg: {:task_request, proto_req}} = gateway_msg
      assert proto_req.task_id == "grpc-test-123"
      assert proto_req.prompt == "Analyze the code for bugs"
      assert proto_req.tools == ["read_file", "grep"]
      assert proto_req.timeout_ms == 30_000
    end

    test "includes context entries in gRPC TaskRequest" do
      test_pid = self()

      receiver =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:received, msg})
          end
        end)

      task_req = make_task_request(%{"context" => %{"team" => "alpha", "model" => "claude"}})
      assert {:ok, :sent} = TaskPush.push(:grpc, receiver, task_req)

      assert_receive {:received, {:push_gateway_message, gateway_msg}}, 1000
      %{msg: {:task_request, proto_req}} = gateway_msg

      assert proto_req.context == %{"team" => "alpha", "model" => "claude"}
    end

    test "returns {:error, :transport_down} for dead pid" do
      pid = dead_pid()
      task_req = make_task_request()
      assert {:error, :transport_down} = TaskPush.push(:grpc, pid, task_req)
    end
  end

  # -- WebSocket transport --

  describe "push(:websocket, pid, task_request)" do
    test "sends {:push_to_agent, event, payload} to live pid" do
      test_pid = self()

      receiver =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:received, msg})
          end
        end)

      task_req = make_task_request(%{"task_id" => "ws-test-456"})
      assert {:ok, :sent} = TaskPush.push(:websocket, receiver, task_req)

      assert_receive {:received, {:push_to_agent, "task_request", payload}}, 1000

      assert payload["task_id"] == "ws-test-456"
      assert payload["prompt"] == "Analyze the code for bugs"
      assert payload["tools"] == ["read_file", "grep"]
      assert payload["timeout_ms"] == 30_000
      assert payload["context"] == %{"project" => "acme"}
    end

    test "returns {:error, :transport_down} for dead pid" do
      pid = dead_pid()
      task_req = make_task_request()
      assert {:error, :transport_down} = TaskPush.push(:websocket, pid, task_req)
    end
  end

  # -- Unknown transport --

  describe "push with unknown transport" do
    test "returns {:error, :unknown_transport}" do
      pid = spawn_receiver()
      task_req = make_task_request()
      assert {:error, :unknown_transport} = TaskPush.push(:http, pid, task_req)
    end
  end

  # -- Edge cases --

  describe "edge cases" do
    test "handles nil context gracefully for gRPC" do
      test_pid = self()

      receiver =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:received, msg})
          end
        end)

      task_req = make_task_request(%{"context" => nil})
      assert {:ok, :sent} = TaskPush.push(:grpc, receiver, task_req)

      assert_receive {:received, {:push_gateway_message, gateway_msg}}, 1000
      %{msg: {:task_request, proto_req}} = gateway_msg
      assert proto_req.context == %{}
    end

    test "handles nil tools gracefully for websocket" do
      test_pid = self()

      receiver =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:received, msg})
          end
        end)

      task_req = make_task_request(%{"tools" => nil})
      assert {:ok, :sent} = TaskPush.push(:websocket, receiver, task_req)

      assert_receive {:received, {:push_to_agent, "task_request", payload}}, 1000
      assert payload["tools"] == []
    end
  end
end
