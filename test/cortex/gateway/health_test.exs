defmodule Cortex.Gateway.HealthTest do
  use ExUnit.Case, async: false

  alias Cortex.Gateway.{Health, Registry}

  setup do
    reg_name = :"health_test_registry_#{System.unique_integer()}"
    {:ok, reg_pid} = Registry.start_link(name: reg_name)
    %{registry: reg_name, reg_pid: reg_pid}
  end

  defp register_agent(registry, name \\ "test-agent", caps \\ ["code"]) do
    channel = spawn(fn -> Process.sleep(:infinity) end)

    info = %{
      "name" => name,
      "role" => "researcher",
      "capabilities" => caps
    }

    {:ok, agent} = Registry.register(registry, info, channel)
    {agent, channel}
  end

  defp set_stale_heartbeat(registry, agent_id, seconds_ago) do
    # We need to manipulate the last_heartbeat to be in the past.
    # Use update_heartbeat to set it, then rely on the fact that
    # we can't directly set timestamps. Instead, we'll use a workaround:
    # register the agent, then use a GenServer call to directly
    # manipulate state. But that breaks encapsulation.
    #
    # Better approach: set a very short heartbeat_timeout_ms and just
    # wait, or use the registry's internal state via :sys.get_state.
    state = :sys.get_state(registry)

    case Map.get(state.agents, agent_id) do
      nil ->
        :error

      agent ->
        stale_time = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
        updated = %{agent | last_heartbeat: stale_time}
        new_agents = Map.put(state.agents, agent_id, updated)
        :sys.replace_state(registry, fn s -> %{s | agents: new_agents} end)
        :ok
    end
  end

  describe "heartbeat timeout marking" do
    test "marks stale agents as disconnected", %{registry: reg} do
      {agent, _channel} = register_agent(reg)

      # Make the heartbeat stale (2 seconds ago, with 100ms timeout)
      set_stale_heartbeat(reg, agent.id, 2)

      # Start health with very short intervals
      {:ok, _health} =
        Health.start_link(
          registry: reg,
          check_interval_ms: 50,
          heartbeat_timeout_ms: 100,
          removal_timeout_ms: 60_000,
          name: :"health_test_#{System.unique_integer()}"
        )

      Process.sleep(150)

      {:ok, updated} = Registry.get(reg, agent.id)
      assert updated.status == :disconnected
    end

    test "does not touch agents with fresh heartbeats", %{registry: reg} do
      {agent, _channel} = register_agent(reg)

      # Heartbeat is fresh (just registered), timeout is 60s
      {:ok, _health} =
        Health.start_link(
          registry: reg,
          check_interval_ms: 50,
          heartbeat_timeout_ms: 60_000,
          removal_timeout_ms: 300_000,
          name: :"health_test_#{System.unique_integer()}"
        )

      Process.sleep(150)

      {:ok, updated} = Registry.get(reg, agent.id)
      assert updated.status == :idle
    end
  end

  describe "removal after extended disconnect" do
    test "removes agents that have been disconnected past removal_timeout", %{registry: reg} do
      {agent, _channel} = register_agent(reg)

      # Make heartbeat stale
      set_stale_heartbeat(reg, agent.id, 2)

      # Start health with very short timeouts
      {:ok, _health} =
        Health.start_link(
          registry: reg,
          check_interval_ms: 50,
          heartbeat_timeout_ms: 100,
          removal_timeout_ms: 150,
          name: :"health_test_#{System.unique_integer()}"
        )

      # First tick: marks disconnected (~50ms)
      Process.sleep(100)
      {:ok, updated} = Registry.get(reg, agent.id)
      assert updated.status == :disconnected

      # Wait for removal timeout to pass + another tick
      Process.sleep(250)

      assert {:error, :not_found} = Registry.get(reg, agent.id)
    end

    test "does not remove agents that resume heartbeats before removal", %{registry: reg} do
      {agent, _channel} = register_agent(reg)

      # Make heartbeat stale
      set_stale_heartbeat(reg, agent.id, 2)

      {:ok, health} =
        Health.start_link(
          registry: reg,
          check_interval_ms: 50,
          heartbeat_timeout_ms: 100,
          removal_timeout_ms: 5_000,
          name: :"health_test_#{System.unique_integer()}"
        )

      # First tick: marks disconnected
      Process.sleep(150)
      {:ok, updated} = Registry.get(reg, agent.id)
      assert updated.status == :disconnected

      # Stop health gracefully to avoid races
      GenServer.stop(health)

      # Resume heartbeat: refresh heartbeat first, then update status back to idle
      Registry.update_heartbeat_on(reg, agent.id, %{})
      Registry.update_status_on(reg, agent.id, :idle)

      # Restart health with a long heartbeat_timeout so the fresh heartbeat won't expire
      {:ok, _health2} =
        Health.start_link(
          registry: reg,
          check_interval_ms: 50,
          heartbeat_timeout_ms: 60_000,
          removal_timeout_ms: 5_000,
          name: :"health_test_#{System.unique_integer()}"
        )

      # Wait for a health check tick
      Process.sleep(150)

      # Agent should still be present and idle
      {:ok, refreshed} = Registry.get(reg, agent.id)
      assert refreshed.status == :idle
    end
  end

  describe "empty registry" do
    test "tolerates empty registry without crashing", %{registry: reg} do
      {:ok, health} =
        Health.start_link(
          registry: reg,
          check_interval_ms: 50,
          heartbeat_timeout_ms: 100,
          removal_timeout_ms: 300,
          name: :"health_test_#{System.unique_integer()}"
        )

      Process.sleep(150)

      # Health should still be alive
      assert Process.alive?(health)
      assert Registry.count(reg) == 0
    end
  end

  describe "periodic check" do
    test "runs on configured interval", %{registry: reg} do
      {agent, _channel} = register_agent(reg)
      set_stale_heartbeat(reg, agent.id, 10)

      {:ok, _health} =
        Health.start_link(
          registry: reg,
          check_interval_ms: 50,
          heartbeat_timeout_ms: 100,
          removal_timeout_ms: 60_000,
          name: :"health_test_#{System.unique_integer()}"
        )

      # After one interval, the agent should be marked disconnected
      Process.sleep(100)

      {:ok, updated} = Registry.get(reg, agent.id)
      assert updated.status == :disconnected
    end
  end
end
