defmodule Cortex.Gateway.IntegrationTest do
  @moduledoc """
  Integration tests for the full gateway flow.

  Tests the complete lifecycle across all gateway modules working together:
  Channel + Protocol + Registry + Events + Auth.

  These tests are NOT async because they share the global Gateway.Registry
  started by the application supervision tree.
  """

  use CortexWeb.ChannelCase, async: false

  alias Cortex.Gateway.{Events, Registry}

  @valid_token "integration-test-token"

  setup do
    # Set the gateway token for auth
    prev_env = System.get_env("CORTEX_GATEWAY_TOKEN")
    System.put_env("CORTEX_GATEWAY_TOKEN", @valid_token)

    # Subscribe to gateway events (Channel broadcasts here)
    Events.subscribe()

    # Subscribe to main Cortex events (Registry broadcasts here)
    Cortex.Events.subscribe()

    # Clean up any leftover agents from previous tests
    for agent <- Registry.list() do
      Registry.unregister(agent.id)
    end

    on_exit(fn ->
      if prev_env,
        do: System.put_env("CORTEX_GATEWAY_TOKEN", prev_env),
        else: System.delete_env("CORTEX_GATEWAY_TOKEN")
    end)

    :ok
  end

  # -- Helpers --

  defp connect_socket do
    connect(CortexWeb.AgentSocket, %{"token" => @valid_token})
  end

  defp join_lobby(socket) do
    subscribe_and_join(socket, CortexWeb.AgentChannel, "agent:lobby")
  end

  defp register_agent(socket, name, capabilities) do
    payload = %{
      "type" => "register",
      "protocol_version" => 1,
      "agent" => %{
        "name" => name,
        "role" => "integration-test-role",
        "capabilities" => capabilities
      },
      "auth" => %{"token" => @valid_token}
    }

    ref = push(socket, "register", payload)
    assert_reply(ref, :ok, %{"agent_id" => agent_id})
    agent_id
  end

  defp connect_and_register(name \\ "test-agent", capabilities \\ ["testing"]) do
    {:ok, socket} = connect_socket()
    {:ok, _, socket} = join_lobby(socket)
    agent_id = register_agent(socket, name, capabilities)
    {socket, agent_id}
  end

  # -- Full Lifecycle --

  describe "full lifecycle: connect → register → heartbeat → status → task_result → disconnect" do
    test "complete agent lifecycle updates registry and emits events at each step" do
      # Step 1: Connect
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      # Registry should have 0 agents (not registered yet)
      assert Registry.count() == 0

      # Step 2: Register
      agent_id =
        register_agent(socket, "lifecycle-agent", ["code-review", "security"])

      # Registry should now have 1 agent
      assert Registry.count() == 1
      assert {:ok, agent} = Registry.get(agent_id)
      assert agent.name == "lifecycle-agent"
      assert agent.capabilities == ["code-review", "security"]
      assert agent.status == :idle

      # PubSub event for registration
      assert_receive %{type: :gateway_agent_registered, payload: reg_payload}
      assert reg_payload.agent_id == agent_id
      assert reg_payload.name == "lifecycle-agent"

      # Step 3: Heartbeat with load
      ref =
        push(socket, "heartbeat", %{
          "type" => "heartbeat",
          "protocol_version" => 1,
          "agent_id" => agent_id,
          "status" => "idle",
          "load" => %{"active_tasks" => 2, "queue_depth" => 1}
        })

      assert_reply(ref, :ok, %{"type" => "heartbeat_ack"})

      # Registry should reflect updated load
      {:ok, agent} = Registry.get(agent_id)
      assert agent.load == %{"active_tasks" => 2, "queue_depth" => 1}

      # Step 4: Status update
      ref =
        push(socket, "status_update", %{
          "type" => "status_update",
          "protocol_version" => 1,
          "agent_id" => agent_id,
          "status" => "working",
          "detail" => "Reviewing PR #42"
        })

      assert_reply(ref, :ok, %{})

      # Registry should reflect new status
      {:ok, agent} = Registry.get(agent_id)
      assert agent.status == :working

      # PubSub event for status change
      assert_receive %{type: :gateway_agent_status_changed, payload: status_payload}
      assert status_payload.agent_id == agent_id
      assert status_payload.status == "working"

      # Step 5: Task result
      ref =
        push(socket, "task_result", %{
          "type" => "task_result",
          "protocol_version" => 1,
          "task_id" => "task-001",
          "status" => "completed",
          "result" => %{
            "text" => "Found 3 security issues",
            "tokens" => %{"input" => 1500, "output" => 800},
            "duration_ms" => 12_000
          }
        })

      assert_reply(ref, :ok, %{})

      # Step 6: Disconnect
      Process.unlink(socket.channel_pid)
      close(socket)

      # PubSub event for disconnect
      assert_receive %{type: :gateway_agent_disconnected, payload: disc_payload}
      assert disc_payload.agent_id == agent_id

      # Give the Registry a moment to process the unregister
      Process.sleep(50)

      # Registry should be empty
      assert Registry.count() == 0
      assert {:error, :not_found} = Registry.get(agent_id)
    end
  end

  # -- Multi-Agent + Capability Discovery --

  describe "multi-agent capability discovery" do
    test "register multiple agents and query by capability" do
      {_s1, id1} = connect_and_register("security-bot", ["security-review", "cve-lookup"])
      {_s2, id2} = connect_and_register("code-bot", ["code-review", "refactoring"])
      {_s3, id3} = connect_and_register("all-rounder", ["security-review", "code-review"])

      assert Registry.count() == 3

      # Query by capability
      security_agents = Registry.list_by_capability("security-review")
      assert length(security_agents) == 2
      security_ids = Enum.map(security_agents, & &1.id) |> Enum.sort()
      assert Enum.sort([id1, id3]) == security_ids

      code_agents = Registry.list_by_capability("code-review")
      assert length(code_agents) == 2
      code_ids = Enum.map(code_agents, & &1.id) |> Enum.sort()
      assert Enum.sort([id2, id3]) == code_ids

      cve_agents = Registry.list_by_capability("cve-lookup")
      assert length(cve_agents) == 1
      assert hd(cve_agents).id == id1

      # No agents with this capability
      assert Registry.list_by_capability("nonexistent") == []
    end
  end

  # -- Process.monitor Auto-Cleanup --

  describe "process monitor auto-cleanup" do
    test "killing a channel pid removes agent from registry" do
      {socket, agent_id} = connect_and_register("doomed-agent", ["testing"])

      assert Registry.count() == 1
      assert {:ok, _} = Registry.get(agent_id)

      # Drain the registration event
      assert_receive %{type: :gateway_agent_registered}

      # Kill the channel process (simulates crash)
      Process.unlink(socket.channel_pid)
      Process.exit(socket.channel_pid, :kill)

      # Wait for the :DOWN message to propagate to Registry
      Process.sleep(100)

      # Agent should be gone
      assert Registry.count() == 0
      assert {:error, :not_found} = Registry.get(agent_id)

      # PubSub event for unregistration (from monitor cleanup)
      assert_receive %{type: :agent_unregistered, payload: payload}
      assert payload.agent_id == agent_id
      assert payload.reason == :channel_down
    end

    test "killing one agent does not affect others" do
      {socket1, id1} = connect_and_register("agent-a", ["cap-a"])
      {_socket2, id2} = connect_and_register("agent-b", ["cap-b"])
      {_socket3, id3} = connect_and_register("agent-c", ["cap-c"])

      assert Registry.count() == 3

      # Kill agent-a's channel
      Process.unlink(socket1.channel_pid)
      Process.exit(socket1.channel_pid, :kill)

      Process.sleep(100)

      # Only agent-a should be gone
      assert Registry.count() == 2
      assert {:error, :not_found} = Registry.get(id1)
      assert {:ok, _} = Registry.get(id2)
      assert {:ok, _} = Registry.get(id3)
    end
  end

  # -- Server-Initiated Push --

  describe "server-initiated push via channel pid" do
    test "task_request pushed to agent via registry channel pid" do
      {socket, agent_id} = connect_and_register("worker-agent", ["work"])

      # Look up channel pid from registry
      {:ok, channel_pid} = Registry.get_channel(agent_id)
      assert channel_pid == socket.channel_pid

      # Push a task_request via the channel pid
      task_payload = %{
        "type" => "task_request",
        "task_id" => "task-999",
        "prompt" => "Review auth module for vulnerabilities",
        "tools" => ["shell"],
        "timeout_ms" => 60_000
      }

      send(channel_pid, {:push_to_agent, "task_request", task_payload})

      assert_push("task_request", received)
      assert received["task_id"] == "task-999"
      assert received["prompt"] == "Review auth module for vulnerabilities"
    end
  end

  # -- Error Paths --

  describe "error paths" do
    test "unauthenticated connection is refused" do
      assert :error = connect(CortexWeb.AgentSocket, %{"token" => "bad-token"})
      assert :error = connect(CortexWeb.AgentSocket, %{})
    end

    test "heartbeat before register is rejected" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref =
        push(socket, "heartbeat", %{
          "type" => "heartbeat",
          "protocol_version" => 1,
          "agent_id" => "fake-id",
          "status" => "idle"
        })

      assert_reply(ref, :error, %{"reason" => "not_registered"})
    end

    test "status_update before register is rejected" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref =
        push(socket, "status_update", %{
          "type" => "status_update",
          "protocol_version" => 1,
          "agent_id" => "fake-id",
          "status" => "idle"
        })

      assert_reply(ref, :error, %{"reason" => "not_registered"})
    end

    test "task_result before register is rejected" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref =
        push(socket, "task_result", %{
          "type" => "task_result",
          "protocol_version" => 1,
          "task_id" => "task-1",
          "status" => "completed",
          "result" => %{"text" => "done"}
        })

      assert_reply(ref, :error, %{"reason" => "not_registered"})
    end

    test "invalid register payload returns all errors" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref =
        push(socket, "register", %{
          "type" => "register",
          "protocol_version" => 1,
          "agent" => %{},
          "auth" => %{}
        })

      assert_reply(ref, :error, %{"reason" => "invalid_payload", "detail" => detail})
      assert is_binary(detail)
      assert byte_size(detail) > 0
    end

    test "unsupported protocol version is rejected" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref =
        push(socket, "register", %{
          "type" => "register",
          "protocol_version" => 99,
          "agent" => %{
            "name" => "test",
            "role" => "tester",
            "capabilities" => ["test"]
          },
          "auth" => %{"token" => @valid_token}
        })

      assert_reply(ref, :error, %{"reason" => "invalid_payload"})
    end

    test "duplicate registration is rejected" do
      {socket, _agent_id} = connect_and_register("dup-agent", ["test"])

      ref =
        push(socket, "register", %{
          "type" => "register",
          "protocol_version" => 1,
          "agent" => %{
            "name" => "dup-agent-2",
            "role" => "tester",
            "capabilities" => ["test"]
          },
          "auth" => %{"token" => @valid_token}
        })

      assert_reply(ref, :error, %{"reason" => "already_registered"})
    end

    test "heartbeat with wrong agent_id is rejected" do
      {socket, _agent_id} = connect_and_register("hb-agent", ["test"])

      ref =
        push(socket, "heartbeat", %{
          "type" => "heartbeat",
          "protocol_version" => 1,
          "agent_id" => "wrong-id",
          "status" => "idle"
        })

      assert_reply(ref, :error, %{"reason" => "agent_id_mismatch"})
    end
  end
end
