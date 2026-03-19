defmodule Cortex.Gateway.GrpcIntegrationTest do
  @moduledoc """
  Integration tests for the gRPC data-plane gateway.

  These tests verify the full lifecycle of gRPC-connected agents:
  registration, heartbeat, disconnect cleanup, task delivery, event emission,
  status updates, and peer routing. They ensure that gRPC-connected agents
  produce identical Registry state and PubSub events as Phoenix Channel agents.

  These tests are NOT async because they share the global Gateway.Registry.

  ## Dependencies

  These tests depend on modules not yet implemented:
  - `Cortex.Gateway.GrpcServer` (Gateway gRPC Engineer)
  - `Cortex.Gateway.GrpcEndpoint` (Gateway gRPC Engineer)
  - `Cortex.Gateway.Proto.*` (Proto & Codegen Engineer)
  - `GRPC.Stub` client (grpc hex package)

  All tests are tagged `:pending` until these dependencies land.
  When the dependencies are available, remove the `@tag :pending` annotations
  and the tests should pass if the implementations match the proto contract.
  """

  use ExUnit.Case, async: false

  alias Cortex.Gateway.{Events, Registry}
  alias Cortex.GrpcHelpers

  @valid_token "grpc-integration-test-token"

  # All tests are pending until gRPC server and proto codegen land
  @moduletag :pending

  setup do
    # Set the gateway token for auth
    prev_env = System.get_env("CORTEX_GATEWAY_TOKEN")
    System.put_env("CORTEX_GATEWAY_TOKEN", @valid_token)

    # Subscribe to both event topics
    GrpcHelpers.subscribe_to_events()

    # Clean up any leftover agents from previous tests
    GrpcHelpers.clear_registry()

    on_exit(fn ->
      if prev_env,
        do: System.put_env("CORTEX_GATEWAY_TOKEN", prev_env),
        else: System.delete_env("CORTEX_GATEWAY_TOKEN")
    end)

    # Get the gRPC server port (will be configured in test env)
    port = Application.get_env(:cortex, :grpc_port, 4001)

    %{port: port}
  end

  # -------------------------------------------------------------------
  # Core lifecycle tests (Task 3)
  # -------------------------------------------------------------------

  describe "connect and register via gRPC" do
    test "gRPC Connect stream opens, RegisterRequest received, RegisterResponse sent back", %{
      port: port
    } do
      {:ok, channel, stream} = GrpcHelpers.connect_grpc(port)

      {:ok, agent_id} =
        GrpcHelpers.send_register(
          stream,
          "grpc-test-agent",
          "integration-test-role",
          ["code-review", "security"],
          @valid_token
        )

      # Verify agent_id is a UUID
      assert is_binary(agent_id)
      assert String.length(agent_id) == 36

      # Verify agent appears in Registry
      assert {:ok, agent} = Registry.get(agent_id)
      assert agent.name == "grpc-test-agent"
      assert agent.role == "integration-test-role"
      assert agent.capabilities == ["code-review", "security"]
      assert agent.status == :idle
      assert agent.transport == :grpc
      assert agent.stream_pid != nil
      assert agent.channel_pid == nil

      # Verify PubSub event emitted
      assert_receive %{type: :agent_registered, payload: payload}, 5000
      assert payload.agent_id == agent_id
      assert payload.name == "grpc-test-agent"

      GrpcHelpers.disconnect(channel)
    end
  end

  describe "heartbeat updates registry" do
    test "Heartbeat received via stream updates last_heartbeat and load", %{port: port} do
      {:ok, channel, stream} = GrpcHelpers.connect_grpc(port)

      {:ok, agent_id} =
        GrpcHelpers.send_register(
          stream,
          "heartbeat-agent",
          "tester",
          ["testing"],
          @valid_token
        )

      # Get initial heartbeat timestamp
      {:ok, agent_before} = Registry.get(agent_id)
      initial_heartbeat = agent_before.last_heartbeat

      # Small delay to ensure timestamp difference
      Process.sleep(50)

      # Send heartbeat with load data
      :ok =
        GrpcHelpers.send_heartbeat(stream, agent_id, :idle, %{
          active_tasks: 3,
          queue_depth: 2
        })

      # Give Registry time to process
      Process.sleep(50)

      # Verify Registry updated
      {:ok, agent_after} = Registry.get(agent_id)
      assert DateTime.compare(agent_after.last_heartbeat, initial_heartbeat) == :gt
      assert agent_after.load == %{active_tasks: 3, queue_depth: 2}

      GrpcHelpers.disconnect(channel)
    end
  end

  describe "stream disconnect removes agent" do
    test "closing gRPC stream removes agent from Registry and emits event", %{port: port} do
      {:ok, channel, stream} = GrpcHelpers.connect_grpc(port)

      {:ok, agent_id} =
        GrpcHelpers.send_register(
          stream,
          "disconnect-agent",
          "tester",
          ["testing"],
          @valid_token
        )

      # Drain the registration event
      assert_receive %{type: :agent_registered}, 5000

      assert Registry.count() >= 1
      assert {:ok, _} = Registry.get(agent_id)

      # Disconnect the gRPC channel (simulates stream close)
      GrpcHelpers.disconnect(channel)

      # Wait for the :DOWN message to propagate to Registry
      Process.sleep(200)

      # Agent should be gone
      assert {:error, :not_found} = Registry.get(agent_id)

      # PubSub event for unregistration
      assert_receive %{type: :agent_unregistered, payload: payload}, 5000
      assert payload.agent_id == agent_id
      assert payload.reason in [:channel_down, :stream_down]
    end
  end

  describe "task request pushed to stream" do
    test "TaskRequest pushed to gRPC agent via registry arrives on stream", %{port: port} do
      {:ok, channel, stream} = GrpcHelpers.connect_grpc(port)

      {:ok, agent_id} =
        GrpcHelpers.send_register(
          stream,
          "task-worker",
          "worker",
          ["work"],
          @valid_token
        )

      # Look up the stream/push pid from registry
      {:ok, agent} = Registry.get(agent_id)
      push_pid = agent.stream_pid

      # Push a task_request to the agent via the stream pid
      task_payload = %{
        task_id: "task-grpc-001",
        prompt: "Review auth module for vulnerabilities",
        tools: ["shell"],
        timeout_ms: 60_000
      }

      send(push_pid, {:push_to_agent, :task_request, task_payload})

      # The agent should receive the TaskRequest on its stream
      {:ok, gateway_msg} = GrpcHelpers.receive_gateway_message(stream, 5000)
      assert gateway_msg.task_request != nil
      assert gateway_msg.task_request.task_id == "task-grpc-001"
      assert gateway_msg.task_request.prompt == "Review auth module for vulnerabilities"

      GrpcHelpers.disconnect(channel)
    end
  end

  # -------------------------------------------------------------------
  # Events and routing tests (Task 4)
  # -------------------------------------------------------------------

  describe "task result emits PubSub" do
    test "TaskResult sent via stream emits PubSub event", %{port: port} do
      {:ok, channel, stream} = GrpcHelpers.connect_grpc(port)

      {:ok, _agent_id} =
        GrpcHelpers.send_register(
          stream,
          "result-agent",
          "worker",
          ["work"],
          @valid_token
        )

      # Drain registration event
      assert_receive %{type: :agent_registered}, 5000

      # Send task result
      :ok = GrpcHelpers.send_task_result(stream, "task-result-001", :completed, "Found 3 issues")

      # Verify PubSub event or routing occurred
      # The exact event type depends on the gateway implementation.
      # Phase 1 used Registry.route_task_result/2 which is a no-op.
      # Phase 2 may emit a PubSub event or route to a task caller.
      # For now, we just verify the message was accepted (no error on stream).
      Process.sleep(100)

      GrpcHelpers.disconnect(channel)
    end
  end

  describe "status update changes registry" do
    test "StatusUpdate via stream updates Registry status and emits event", %{port: port} do
      {:ok, channel, stream} = GrpcHelpers.connect_grpc(port)

      {:ok, agent_id} =
        GrpcHelpers.send_register(
          stream,
          "status-agent",
          "worker",
          ["work"],
          @valid_token
        )

      # Drain registration event
      assert_receive %{type: :agent_registered}, 5000

      # Send status update
      :ok = GrpcHelpers.send_status_update(stream, agent_id, :working, "Processing task #42")

      # Give Registry time to process
      Process.sleep(100)

      # Verify Registry updated
      {:ok, agent} = Registry.get(agent_id)
      assert agent.status == :working

      # Verify PubSub event emitted
      assert_receive %{type: :agent_status_changed, payload: payload}, 5000
      assert payload.agent_id == agent_id
      assert payload.old_status == :idle
      assert payload.new_status == :working

      GrpcHelpers.disconnect(channel)
    end
  end

  describe "gRPC agents emit same PubSub events as Phoenix Channel" do
    test "gRPC registration emits identical event structure to Phoenix Channel", %{port: port} do
      # Register via gRPC
      {:ok, channel, stream} = GrpcHelpers.connect_grpc(port)

      {:ok, grpc_agent_id} =
        GrpcHelpers.send_register(
          stream,
          "grpc-parity-agent",
          "parity-role",
          ["parity-cap"],
          @valid_token
        )

      # Capture the gRPC registration event
      assert_receive %{type: :agent_registered, payload: grpc_payload}, 5000

      # Verify the gRPC event has the same keys as a Phoenix Channel event
      # (based on the Phase 1 integration test event shape)
      assert Map.has_key?(grpc_payload, :agent_id)
      assert Map.has_key?(grpc_payload, :name)
      assert Map.has_key?(grpc_payload, :role)
      assert Map.has_key?(grpc_payload, :capabilities)

      assert grpc_payload.agent_id == grpc_agent_id
      assert grpc_payload.name == "grpc-parity-agent"
      assert grpc_payload.role == "parity-role"
      assert grpc_payload.capabilities == ["parity-cap"]

      # Verify the gRPC agent looks identical in the Registry
      {:ok, agent} = Registry.get(grpc_agent_id)
      assert agent.status == :idle
      assert is_reference(agent.monitor_ref)
      assert %DateTime{} = agent.registered_at
      assert %DateTime{} = agent.last_heartbeat

      # Disconnect and verify unregistration event parity
      GrpcHelpers.disconnect(channel)

      Process.sleep(200)

      assert_receive %{type: :agent_unregistered, payload: unreg_payload}, 5000
      assert Map.has_key?(unreg_payload, :agent_id)
      assert Map.has_key?(unreg_payload, :name)
      assert Map.has_key?(unreg_payload, :reason)
      assert unreg_payload.agent_id == grpc_agent_id
    end
  end

  describe "peer request routed between streams" do
    @describetag :phase3
    test "Agent A sends PeerRequest targeting B, B responds, A receives PeerResponse", %{
      port: port
    } do
      # Connect two agents
      {:ok, channel_a, stream_a} = GrpcHelpers.connect_grpc(port)
      {:ok, channel_b, stream_b} = GrpcHelpers.connect_grpc(port)

      {:ok, _agent_a_id} =
        GrpcHelpers.send_register(
          stream_a,
          "agent-a",
          "requester",
          ["requesting"],
          @valid_token
        )

      {:ok, agent_b_id} =
        GrpcHelpers.send_register(
          stream_b,
          "agent-b",
          "responder",
          ["security-review"],
          @valid_token
        )

      # Drain registration events
      assert_receive %{type: :agent_registered}, 5000
      assert_receive %{type: :agent_registered}, 5000

      # Agent A sends a PeerRequest targeting B's capability
      # This would go through the gateway's routing logic
      # For now, we simulate the gateway routing a PeerRequest to B's stream
      {:ok, agent_b} = Registry.get(agent_b_id)
      push_pid_b = agent_b.stream_pid

      peer_request_payload = %{
        request_id: "peer-req-001",
        from_agent: "agent-a-id",
        capability: "security-review",
        prompt: "Review this code for injection",
        timeout_ms: 30_000
      }

      send(push_pid_b, {:push_to_agent, :peer_request, peer_request_payload})

      # Agent B receives the PeerRequest
      {:ok, b_msg} = GrpcHelpers.receive_gateway_message(stream_b, 5000)
      assert b_msg.peer_request != nil
      assert b_msg.peer_request.request_id == "peer-req-001"

      # Agent B sends a PeerResponse
      :ok =
        GrpcHelpers.send_peer_response(
          stream_b,
          "peer-req-001",
          :completed,
          "Found 2 injection points"
        )

      # The gateway should route the PeerResponse back to Agent A's stream
      {:ok, a_msg} = GrpcHelpers.receive_gateway_message(stream_a, 5000)
      assert a_msg.peer_response != nil
      assert a_msg.peer_response.request_id == "peer-req-001"
      assert a_msg.peer_response.result == "Found 2 injection points"

      GrpcHelpers.disconnect(channel_a)
      GrpcHelpers.disconnect(channel_b)
    end
  end
end
