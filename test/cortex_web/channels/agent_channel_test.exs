defmodule CortexWeb.AgentChannelTest do
  use CortexWeb.ChannelCase, async: false

  alias Cortex.Gateway.{Events, Registry}

  @valid_token "test-gateway-token"

  setup do
    # Start the Registry for each test
    registry = start_supervised!({Registry, name: :"test_registry_#{System.unique_integer()}"})

    # Configure Auth to use our test token
    prev_env = System.get_env("CORTEX_GATEWAY_TOKEN")
    System.put_env("CORTEX_GATEWAY_TOKEN", @valid_token)

    on_exit(fn ->
      if prev_env,
        do: System.put_env("CORTEX_GATEWAY_TOKEN", prev_env),
        else: System.delete_env("CORTEX_GATEWAY_TOKEN")
    end)

    # Subscribe to gateway events for assertions
    Events.subscribe()

    {:ok, registry: registry}
  end

  defp connect_socket(token \\ @valid_token) do
    connect(CortexWeb.AgentSocket, %{"token" => token})
  end

  defp join_lobby(socket) do
    subscribe_and_join(socket, CortexWeb.AgentChannel, "agent:lobby")
  end

  defp valid_register_payload do
    %{
      "type" => "register",
      "protocol_version" => 1,
      "agent" => %{
        "name" => "test-agent",
        "role" => "tester",
        "capabilities" => ["testing"]
      },
      "auth" => %{
        "token" => @valid_token
      }
    }
  end

  # ---- Socket connect tests ----

  describe "socket connect" do
    test "connect with valid token succeeds" do
      assert {:ok, socket} = connect_socket()
      assert socket.assigns.authenticated == true
      assert %DateTime{} = socket.assigns.connect_time
    end

    test "connect with invalid token returns error" do
      assert :error = connect_socket("wrong-token")
    end

    test "connect with missing token returns error" do
      assert :error = connect(CortexWeb.AgentSocket, %{})
    end

    test "connect with empty token returns error" do
      assert :error = connect_socket("")
    end
  end

  # ---- Join tests ----

  describe "join" do
    test "join agent:lobby succeeds for authenticated socket" do
      {:ok, socket} = connect_socket()
      assert {:ok, _, socket} = join_lobby(socket)
      assert socket.assigns.registered == false
      assert socket.assigns.agent_id == nil
      assert %DateTime{} = socket.assigns.joined_at
    end

    test "join invalid topic returns error" do
      {:ok, socket} = connect_socket()

      assert {:error, %{"reason" => "invalid_topic"}} =
               subscribe_and_join(socket, CortexWeb.AgentChannel, "agent:other")
    end
  end

  # ---- Registration tests ----

  describe "register" do
    test "register with valid payload succeeds" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref = push(socket, "register", valid_register_payload())
      assert_reply(ref, :ok, reply)

      assert %{"type" => "registered", "agent_id" => agent_id} = reply
      assert is_binary(agent_id)
      assert byte_size(agent_id) > 0
    end

    test "register sets socket assigns" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref = push(socket, "register", valid_register_payload())
      assert_reply(ref, :ok, %{"agent_id" => agent_id})

      # The socket state in the channel process should have updated assigns
      # We verify indirectly by sending a heartbeat with the correct agent_id
      ref =
        push(socket, "heartbeat", %{
          "type" => "heartbeat",
          "protocol_version" => 1,
          "agent_id" => agent_id,
          "status" => "idle"
        })

      assert_reply(ref, :ok, %{"type" => "heartbeat_ack"})
    end

    test "register with missing fields returns error" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref =
        push(socket, "register", %{
          "type" => "register",
          "protocol_version" => 1,
          "agent" => %{},
          "auth" => %{}
        })

      assert_reply(ref, :error, %{"reason" => "invalid_payload"})
    end

    test "register twice returns already_registered error" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref = push(socket, "register", valid_register_payload())
      assert_reply(ref, :ok, %{"agent_id" => _})

      ref = push(socket, "register", valid_register_payload())
      assert_reply(ref, :error, %{"reason" => "already_registered"})
    end

    test "register with unsupported protocol version returns error" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      payload = put_in(valid_register_payload(), ["protocol_version"], 99)
      ref = push(socket, "register", payload)
      assert_reply(ref, :error, %{"reason" => "invalid_payload"})
    end

    test "register emits PubSub event" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref = push(socket, "register", valid_register_payload())
      assert_reply(ref, :ok, _)

      assert_receive %{type: :gateway_agent_registered, payload: payload}
      assert payload.name == "test-agent"
      assert payload.role == "tester"
      assert payload.capabilities == ["testing"]
    end
  end

  # ---- Heartbeat tests ----

  describe "heartbeat" do
    test "heartbeat after registration succeeds" do
      {:ok, socket} = connect_and_register()

      agent_id = socket_agent_id(socket)

      ref =
        push(socket, "heartbeat", %{
          "type" => "heartbeat",
          "protocol_version" => 1,
          "agent_id" => agent_id,
          "status" => "idle"
        })

      assert_reply(ref, :ok, %{"type" => "heartbeat_ack"})
    end

    test "heartbeat before registration returns not_registered error" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref =
        push(socket, "heartbeat", %{
          "type" => "heartbeat",
          "protocol_version" => 1,
          "agent_id" => "some-id",
          "status" => "idle"
        })

      assert_reply(ref, :error, %{"reason" => "not_registered"})
    end

    test "heartbeat with mismatched agent_id returns error" do
      {:ok, socket} = connect_and_register()

      ref =
        push(socket, "heartbeat", %{
          "type" => "heartbeat",
          "protocol_version" => 1,
          "agent_id" => "wrong-agent-id",
          "status" => "idle"
        })

      assert_reply(ref, :error, %{"reason" => "agent_id_mismatch"})
    end

    test "heartbeat with load data succeeds" do
      {:ok, socket} = connect_and_register()

      agent_id = socket_agent_id(socket)

      ref =
        push(socket, "heartbeat", %{
          "type" => "heartbeat",
          "protocol_version" => 1,
          "agent_id" => agent_id,
          "status" => "working",
          "load" => %{"active_tasks" => 3, "queue_depth" => 2}
        })

      assert_reply(ref, :ok, %{"type" => "heartbeat_ack"})
    end
  end

  # ---- Task result tests ----

  describe "task_result" do
    test "task_result with valid payload succeeds" do
      {:ok, socket} = connect_and_register()

      ref =
        push(socket, "task_result", %{
          "type" => "task_result",
          "protocol_version" => 1,
          "task_id" => "task-123",
          "status" => "completed",
          "result" => %{"text" => "Done!"}
        })

      assert_reply(ref, :ok, %{})
    end

    test "task_result before registration returns error" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref =
        push(socket, "task_result", %{
          "type" => "task_result",
          "protocol_version" => 1,
          "task_id" => "task-123",
          "status" => "completed",
          "result" => %{"text" => "Done!"}
        })

      assert_reply(ref, :error, %{"reason" => "not_registered"})
    end

    test "task_result with invalid payload returns error" do
      {:ok, socket} = connect_and_register()

      ref =
        push(socket, "task_result", %{
          "type" => "task_result",
          "protocol_version" => 1
        })

      assert_reply(ref, :error, %{"reason" => "invalid_payload"})
    end
  end

  # ---- Status update tests ----

  describe "status_update" do
    test "status_update with valid payload succeeds" do
      {:ok, socket} = connect_and_register()

      agent_id = socket_agent_id(socket)

      ref =
        push(socket, "status_update", %{
          "type" => "status_update",
          "protocol_version" => 1,
          "agent_id" => agent_id,
          "status" => "working",
          "detail" => "Processing task"
        })

      assert_reply(ref, :ok, %{})
    end

    test "status_update before registration returns error" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      ref =
        push(socket, "status_update", %{
          "type" => "status_update",
          "protocol_version" => 1,
          "agent_id" => "some-id",
          "status" => "idle"
        })

      assert_reply(ref, :error, %{"reason" => "not_registered"})
    end

    test "status_update emits PubSub event" do
      {:ok, socket} = connect_and_register()

      # Drain the registration event
      assert_receive %{type: :gateway_agent_registered}

      agent_id = socket_agent_id(socket)

      ref =
        push(socket, "status_update", %{
          "type" => "status_update",
          "protocol_version" => 1,
          "agent_id" => agent_id,
          "status" => "working",
          "detail" => "Busy now"
        })

      assert_reply(ref, :ok, %{})

      assert_receive %{type: :gateway_agent_status_changed, payload: payload}
      assert payload.agent_id == agent_id
      assert payload.status == "working"
      assert payload.detail == "Busy now"
    end
  end

  # ---- Outbound push tests ----

  describe "outbound push" do
    test "push_to_agent delivers task_request to the agent" do
      {:ok, socket} = connect_and_register()

      task_payload = %{
        "type" => "task_request",
        "task_id" => "task-456",
        "prompt" => "Review this code",
        "timeout_ms" => 30_000
      }

      send(socket.channel_pid, {:push_to_agent, "task_request", task_payload})

      assert_push("task_request", ^task_payload)
    end

    test "push_to_agent delivers peer_request to the agent" do
      {:ok, socket} = connect_and_register()

      peer_payload = %{
        "type" => "peer_request",
        "request_id" => "req-789",
        "from_agent" => "agent-A",
        "capability" => "security-review",
        "input" => "Check this",
        "timeout_ms" => 60_000
      }

      send(socket.channel_pid, {:push_to_agent, "peer_request", peer_payload})

      assert_push("peer_request", ^peer_payload)
    end
  end

  # ---- Unknown event tests ----

  describe "unknown events" do
    test "unknown event returns error" do
      {:ok, socket} = connect_and_register()

      ref = push(socket, "foobar", %{})

      assert_reply(ref, :error, %{
        "reason" => "unknown_event",
        "detail" => "Unknown event: foobar"
      })
    end
  end

  # ---- Disconnect tests ----

  describe "disconnect" do
    test "closing the channel emits PubSub event" do
      {:ok, socket} = connect_and_register()

      # Drain the registration event
      assert_receive %{type: :gateway_agent_registered}

      Process.unlink(socket.channel_pid)
      close(socket)

      assert_receive %{type: :gateway_agent_disconnected, payload: payload}
      assert is_binary(payload.agent_id)
      assert payload.name == "test-agent"
    end
  end

  # ---- Registration timeout tests ----

  describe "registration timeout" do
    test "timeout does not disconnect registered agent" do
      {:ok, socket} = connect_and_register()

      send(socket.channel_pid, :registration_timeout)

      # Channel should still be alive — send a heartbeat to verify
      agent_id = socket_agent_id(socket)

      ref =
        push(socket, "heartbeat", %{
          "type" => "heartbeat",
          "protocol_version" => 1,
          "agent_id" => agent_id,
          "status" => "idle"
        })

      assert_reply(ref, :ok, %{"type" => "heartbeat_ack"})
    end

    test "timeout disconnects unregistered agent" do
      {:ok, socket} = connect_socket()
      {:ok, _, socket} = join_lobby(socket)

      Process.monitor(socket.channel_pid)
      send(socket.channel_pid, :registration_timeout)

      assert_receive {:DOWN, _, :process, _, :normal}
    end
  end

  # ---- Socket id tests ----

  describe "socket id" do
    test "id returns nil before registration" do
      {:ok, socket} = connect_socket()
      assert CortexWeb.AgentSocket.id(socket) == nil
    end
  end

  # -- Helpers --

  defp connect_and_register do
    {:ok, socket} = connect_socket()
    {:ok, _, socket} = join_lobby(socket)

    ref = push(socket, "register", valid_register_payload())
    assert_reply(ref, :ok, %{"agent_id" => agent_id})

    # Store the agent_id in process dictionary for helper access
    Process.put(:test_agent_id, agent_id)

    {:ok, socket}
  end

  defp socket_agent_id(_socket) do
    Process.get(:test_agent_id)
  end
end
