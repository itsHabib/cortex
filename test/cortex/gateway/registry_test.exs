defmodule Cortex.Gateway.RegistryTest do
  use ExUnit.Case, async: false

  alias Cortex.Gateway.{RegisteredAgent, Registry}

  setup do
    {:ok, pid} = Registry.start_link(name: :"registry_test_#{System.unique_integer()}")
    %{registry: pid}
  end

  defp make_agent_info(name \\ "test-agent", role \\ "researcher", caps \\ ["code-review"]) do
    %{
      "name" => name,
      "role" => role,
      "capabilities" => caps,
      "metadata" => %{"model" => "claude-4"}
    }
  end

  defp spawn_channel do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  # -- register/3 --

  describe "register/3" do
    test "assigns UUID, stores agent, returns {:ok, agent}", %{registry: reg} do
      channel = spawn_channel()
      info = make_agent_info()
      assert {:ok, %RegisteredAgent{} = agent} = Registry.register(reg, info, channel)
      assert is_binary(agent.id)
      assert String.length(agent.id) == 36
      assert agent.name == "test-agent"
      assert agent.role == "researcher"
      assert agent.capabilities == ["code-review"]
      assert agent.status == :idle
      assert agent.channel_pid == channel
      assert is_reference(agent.monitor_ref)
      assert %DateTime{} = agent.registered_at
      assert %DateTime{} = agent.last_heartbeat
      assert agent.metadata == %{"model" => "claude-4"}
      assert agent.load == %{active_tasks: 0, queue_depth: 0}
    end

    test "returns error for missing name", %{registry: reg} do
      channel = spawn_channel()
      info = %{"name" => "", "role" => "r", "capabilities" => ["a"]}
      assert {:error, :invalid_name} = Registry.register(reg, info, channel)
    end

    test "returns error for missing role", %{registry: reg} do
      channel = spawn_channel()
      info = %{"name" => "a", "role" => "", "capabilities" => ["a"]}
      assert {:error, :invalid_role} = Registry.register(reg, info, channel)
    end

    test "returns error for non-list capabilities", %{registry: reg} do
      channel = spawn_channel()
      info = %{"name" => "a", "role" => "r", "capabilities" => "not-a-list"}
      assert {:error, :invalid_capabilities} = Registry.register(reg, info, channel)
    end

    test "returns error for non-string capability items", %{registry: reg} do
      channel = spawn_channel()
      info = %{"name" => "a", "role" => "r", "capabilities" => [123]}
      assert {:error, :invalid_capabilities} = Registry.register(reg, info, channel)
    end

    test "returns error for dead channel pid", %{registry: reg} do
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      info = make_agent_info()
      assert {:error, :invalid_channel_pid} = Registry.register(reg, info, dead_pid)
    end

    test "broadcasts :agent_registered event", %{registry: reg} do
      Cortex.Events.subscribe()
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)

      assert_receive %{
                       type: :agent_registered,
                       payload: %{agent_id: agent_id, name: "test-agent"}
                     },
                     1000

      assert agent_id == agent.id
    end
  end

  # -- get/2 --

  describe "get/2" do
    test "returns {:ok, agent} for registered agent", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)
      assert {:ok, ^agent} = Registry.get(reg, agent.id)
    end

    test "returns {:error, :not_found} for unknown ID", %{registry: reg} do
      assert {:error, :not_found} = Registry.get(reg, "nonexistent")
    end
  end

  # -- list/1 --

  describe "list/1" do
    test "returns all registered agents", %{registry: reg} do
      c1 = spawn_channel()
      c2 = spawn_channel()
      {:ok, _} = Registry.register(reg, make_agent_info("agent-1"), c1)
      {:ok, _} = Registry.register(reg, make_agent_info("agent-2"), c2)

      agents = Registry.list(reg)
      assert length(agents) == 2
      names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert names == ["agent-1", "agent-2"]
    end

    test "returns empty list when no agents registered", %{registry: reg} do
      assert Registry.list(reg) == []
    end
  end

  # -- list_by_capability/2 --

  describe "list_by_capability/2" do
    test "returns only agents with matching capability", %{registry: reg} do
      c1 = spawn_channel()
      c2 = spawn_channel()
      c3 = spawn_channel()
      {:ok, _} = Registry.register(reg, make_agent_info("a1", "r", ["security", "code"]), c1)
      {:ok, _} = Registry.register(reg, make_agent_info("a2", "r", ["code"]), c2)
      {:ok, _} = Registry.register(reg, make_agent_info("a3", "r", ["testing"]), c3)

      matching = Registry.list_by_capability(reg, "security")
      assert length(matching) == 1
      assert hd(matching).name == "a1"

      matching = Registry.list_by_capability(reg, "code")
      assert length(matching) == 2
    end

    test "returns empty list when no match", %{registry: reg} do
      c1 = spawn_channel()
      {:ok, _} = Registry.register(reg, make_agent_info("a1", "r", ["code"]), c1)
      assert Registry.list_by_capability(reg, "nonexistent") == []
    end
  end

  # -- update_status/2,3 --

  describe "update_status" do
    test "changes agent status", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)
      assert :ok = Registry.update_status_on(reg, agent.id, :working)
      {:ok, updated} = Registry.get(reg, agent.id)
      assert updated.status == :working
    end

    test "rejects invalid status atoms", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)
      assert {:error, :invalid_status} = Registry.update_status_on(reg, agent.id, :banana)
    end

    test "returns {:error, :not_found} for unknown agent", %{registry: reg} do
      assert {:error, :not_found} = Registry.update_status_on(reg, "nonexistent", :idle)
    end

    test "broadcasts :agent_status_changed event", %{registry: reg} do
      Cortex.Events.subscribe()
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)

      # Drain the register event
      assert_receive %{type: :agent_registered}, 1000

      Registry.update_status_on(reg, agent.id, :working)

      assert_receive %{
                       type: :agent_status_changed,
                       payload: %{agent_id: _, old_status: :idle, new_status: :working}
                     },
                     1000
    end

    test "accepts string status and normalizes to atom", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)
      assert :ok = Registry.update_status_on(reg, agent.id, :draining)
      {:ok, updated} = Registry.get(reg, agent.id)
      assert updated.status == :draining
    end
  end

  # -- update_heartbeat/2,3 --

  describe "update_heartbeat" do
    test "updates last_heartbeat and load", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)

      original_hb = agent.last_heartbeat
      Process.sleep(10)

      load = %{active_tasks: 3, queue_depth: 1}
      assert :ok = Registry.update_heartbeat_on(reg, agent.id, load)

      {:ok, updated} = Registry.get(reg, agent.id)
      assert DateTime.compare(updated.last_heartbeat, original_hb) == :gt
      assert updated.load == load
    end

    test "returns {:error, :not_found} for unknown agent", %{registry: reg} do
      assert {:error, :not_found} = Registry.update_heartbeat_on(reg, "nonexistent", %{})
    end
  end

  # -- get_channel/2 --

  describe "get_channel/2" do
    test "returns channel pid for registered agent", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)
      assert {:ok, ^channel} = Registry.get_channel(reg, agent.id)
    end

    test "returns {:error, :not_found} for unknown agent", %{registry: reg} do
      assert {:error, :not_found} = Registry.get_channel(reg, "nonexistent")
    end
  end

  # -- unregister/2 --

  describe "unregister/2" do
    test "removes agent and demonitors", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)
      assert :ok = Registry.unregister(reg, agent.id)
      assert {:error, :not_found} = Registry.get(reg, agent.id)
    end

    test "returns {:error, :not_found} for unknown ID", %{registry: reg} do
      assert {:error, :not_found} = Registry.unregister(reg, "nonexistent")
    end

    test "broadcasts :agent_unregistered event", %{registry: reg} do
      Cortex.Events.subscribe()
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)

      assert_receive %{type: :agent_registered}, 1000

      Registry.unregister(reg, agent.id)

      assert_receive %{
                       type: :agent_unregistered,
                       payload: %{agent_id: _, name: "test-agent", reason: :explicit}
                     },
                     1000
    end
  end

  # -- count/1 --

  describe "count/1" do
    test "returns correct count after register/unregister", %{registry: reg} do
      assert Registry.count(reg) == 0

      c1 = spawn_channel()
      c2 = spawn_channel()
      {:ok, a1} = Registry.register(reg, make_agent_info("a1"), c1)
      {:ok, _a2} = Registry.register(reg, make_agent_info("a2"), c2)
      assert Registry.count(reg) == 2

      Registry.unregister(reg, a1.id)
      assert Registry.count(reg) == 1
    end
  end

  # -- monitor-based cleanup --

  describe "monitor-based cleanup" do
    test "auto-removes agent when channel pid dies", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)
      assert Registry.count(reg) == 1

      Process.exit(channel, :kill)
      Process.sleep(50)

      assert Registry.count(reg) == 0
      assert {:error, :not_found} = Registry.get(reg, agent.id)
    end

    test "emits :agent_unregistered event on channel death", %{registry: reg} do
      Cortex.Events.subscribe()
      channel = spawn_channel()
      {:ok, _agent} = Registry.register(reg, make_agent_info(), channel)

      assert_receive %{type: :agent_registered}, 1000

      Process.exit(channel, :kill)

      assert_receive %{
                       type: :agent_unregistered,
                       payload: %{name: "test-agent", reason: :channel_down}
                     },
                     1000
    end

    test "double unregister: explicit then DOWN does not crash", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info(), channel)

      Registry.unregister(reg, agent.id)
      Process.exit(channel, :kill)
      Process.sleep(50)

      # Registry should still be alive and functional
      assert Registry.count(reg) == 0
    end
  end

  # -- route_task_result/2 --

  describe "route_task_result/2" do
    test "returns :ok (Phase 1 no-op)" do
      assert :ok = Registry.route_task_result("task-123", %{"text" => "result"})
    end
  end

  # -- register_grpc/3 --

  describe "register_grpc/3" do
    test "registers a gRPC agent with stream_pid and transport :grpc", %{registry: reg} do
      stream_pid = spawn_channel()
      info = make_agent_info("grpc-agent")
      assert {:ok, %RegisteredAgent{} = agent} = Registry.register_grpc(reg, info, stream_pid)
      assert agent.stream_pid == stream_pid
      assert agent.channel_pid == nil
      assert agent.transport == :grpc
      assert agent.name == "grpc-agent"
      assert agent.status == :idle
    end

    test "returns error for dead stream pid", %{registry: reg} do
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      info = make_agent_info()
      assert {:error, :invalid_stream_pid} = Registry.register_grpc(reg, info, dead_pid)
    end

    test "broadcasts :agent_registered event", %{registry: reg} do
      Cortex.Events.subscribe()
      stream_pid = spawn_channel()
      {:ok, agent} = Registry.register_grpc(reg, make_agent_info("grpc-evt"), stream_pid)

      assert_receive %{
                       type: :agent_registered,
                       payload: %{agent_id: agent_id, name: "grpc-evt"}
                     },
                     1000

      assert agent_id == agent.id
    end
  end

  # -- get_stream/2 --

  describe "get_stream/2" do
    test "returns stream pid for gRPC agent", %{registry: reg} do
      stream_pid = spawn_channel()
      {:ok, agent} = Registry.register_grpc(reg, make_agent_info("grpc"), stream_pid)
      assert {:ok, ^stream_pid} = Registry.get_stream(reg, agent.id)
    end

    test "returns {:error, :not_found} for WS agent", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info("ws"), channel)
      assert {:error, :not_found} = Registry.get_stream(reg, agent.id)
    end

    test "returns {:error, :not_found} for unknown ID", %{registry: reg} do
      assert {:error, :not_found} = Registry.get_stream(reg, "nonexistent")
    end
  end

  # -- get_push_pid/2 --

  describe "get_push_pid/2" do
    test "returns {:grpc, pid} for gRPC agent", %{registry: reg} do
      stream_pid = spawn_channel()
      {:ok, agent} = Registry.register_grpc(reg, make_agent_info("grpc"), stream_pid)
      assert {:ok, {:grpc, ^stream_pid}} = Registry.get_push_pid(reg, agent.id)
    end

    test "returns {:websocket, pid} for WS agent", %{registry: reg} do
      channel = spawn_channel()
      {:ok, agent} = Registry.register(reg, make_agent_info("ws"), channel)
      assert {:ok, {:websocket, ^channel}} = Registry.get_push_pid(reg, agent.id)
    end

    test "returns {:error, :not_found} for unknown ID", %{registry: reg} do
      assert {:error, :not_found} = Registry.get_push_pid(reg, "nonexistent")
    end
  end

  # -- monitor-based cleanup (gRPC) --

  describe "monitor-based cleanup (gRPC)" do
    test "auto-removes gRPC agent when stream pid dies", %{registry: reg} do
      stream_pid = spawn_channel()
      {:ok, agent} = Registry.register_grpc(reg, make_agent_info("grpc"), stream_pid)
      assert Registry.count(reg) == 1

      Process.exit(stream_pid, :kill)
      Process.sleep(50)

      assert Registry.count(reg) == 0
      assert {:error, :not_found} = Registry.get(reg, agent.id)
    end

    test "emits :agent_unregistered event on stream pid death", %{registry: reg} do
      Cortex.Events.subscribe()
      stream_pid = spawn_channel()
      {:ok, _agent} = Registry.register_grpc(reg, make_agent_info("grpc-down"), stream_pid)

      assert_receive %{type: :agent_registered}, 1000

      Process.exit(stream_pid, :kill)

      assert_receive %{
                       type: :agent_unregistered,
                       payload: %{name: "grpc-down", reason: :channel_down}
                     },
                     1000
    end
  end

  # -- mixed transport listing --

  describe "mixed transport listing" do
    test "list/1 returns both WS and gRPC agents", %{registry: reg} do
      ws_channel = spawn_channel()
      grpc_stream = spawn_channel()
      {:ok, _} = Registry.register(reg, make_agent_info("ws-agent"), ws_channel)
      {:ok, _} = Registry.register_grpc(reg, make_agent_info("grpc-agent"), grpc_stream)

      agents = Registry.list(reg)
      assert length(agents) == 2
      transports = Enum.map(agents, & &1.transport) |> Enum.sort()
      assert transports == [:grpc, :websocket]
    end
  end
end
