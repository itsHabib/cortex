defmodule Cortex.QETest do
  @moduledoc """
  Phase 2 QE tests — fault injection, stress, event ordering,
  cross-component lifecycle, and state consistency.

  These tests target gaps not covered by the existing 166 Phase 1 tests.
  They are async: false because they touch shared Registry and PubSub state.

  NOTE: Fault injection tests start agents directly with Server.start_link/1
  (not under the DynamicSupervisor) because the default GenServer child_spec
  uses restart: :permanent, which means killing supervised agents triggers
  supervisor restart intensity limits. Direct-started agents let us test
  Registry cleanup and process death without supervisor interference.
  """

  use ExUnit.Case, async: false

  alias Cortex.Agent.Config
  alias Cortex.Agent.Server
  alias Cortex.Agent.Supervisor, as: AgentSupervisor
  alias Cortex.Agent.Registry, as: AgentRegistry
  alias Cortex.Events
  alias Cortex.Tool.Executor

  # Helper: start an agent via the Supervisor, return {pid, agent_id}
  defp start_supervised_agent(name, role \\ "tester") do
    {:ok, pid} = AgentSupervisor.start_agent(%{name: name, role: role})
    {:ok, state} = GenServer.call(pid, :get_state)
    {pid, state.id}
  end

  # Helper: start an agent directly (not supervised), return {pid, agent_id}
  defp start_direct_agent(name, role \\ "tester") do
    config = Config.new!(%{name: name, role: role})
    {:ok, pid} = Server.start_link(config)
    {:ok, state} = GenServer.call(pid, :get_state)
    {pid, state.id}
  end

  # Helper: kill a pid and wait for it to actually die via monitor
  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5000 -> raise "Timed out waiting for process #{inspect(pid)} to die"
    end
  end

  # Helper: poll until a condition is true or timeout expires.
  defp wait_until(fun, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "wait_until timed out"
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  # ────────────────────────────────────────────────────────────
  # 1. Fault injection — Agent crash recovery
  # ────────────────────────────────────────────────────────────

  describe "fault injection — agent crash recovery" do
    test "killed agent is auto-deregistered from Registry" do
      # Start directly so killing doesn't trigger supervisor restart intensity
      {pid, agent_id} = start_direct_agent("crash-test")

      assert {:ok, ^pid} = AgentRegistry.lookup(agent_id)

      # Trap exits so the test process doesn't die when the linked process is killed
      Process.flag(:trap_exit, true)

      kill_and_wait(pid)

      # Poll until the Registry cleans up the dead entry
      wait_until(fn -> AgentRegistry.lookup(agent_id) == :not_found end)

      assert :not_found = AgentRegistry.lookup(agent_id)
    end

    test "DynamicSupervisor stays healthy after child terminates gracefully" do
      {_pid, agent_id} = start_supervised_agent("sup-health-test")

      # Graceful stop (does NOT trigger restart intensity)
      AgentSupervisor.stop_agent(agent_id)

      # The DynamicSupervisor itself should still be alive and accepting new children
      sup_pid = Process.whereis(Cortex.Agent.Supervisor)
      assert sup_pid != nil, "DynamicSupervisor should be registered"
      assert Process.alive?(sup_pid), "DynamicSupervisor should be alive"

      # We can still start new children (the real health check)
      {new_pid, new_id} = start_supervised_agent("post-stop-health")
      assert Process.alive?(new_pid)
      AgentSupervisor.stop_agent(new_id)
    end

    test "new agent starts successfully after another agent is killed" do
      # Start directly to avoid supervisor restart churn
      {pid, agent_id} = start_direct_agent("crash-then-new")

      Process.flag(:trap_exit, true)
      kill_and_wait(pid)

      # Poll until old agent_id is deregistered
      wait_until(fn -> AgentRegistry.lookup(agent_id) == :not_found end)

      # Start a fresh agent — should work fine
      {new_pid, new_agent_id} = start_direct_agent("post-crash")
      assert Process.alive?(new_pid)
      assert {:ok, ^new_pid} = AgentRegistry.lookup(new_agent_id)

      # The new agent is fully functional
      assert {:ok, state} = Server.get_state(new_agent_id)
      assert state.status == :idle

      Server.stop(new_agent_id)
    end
  end

  # ────────────────────────────────────────────────────────────
  # 2. Fault injection — Concurrent agent crashes
  # ────────────────────────────────────────────────────────────

  describe "fault injection — concurrent agent crashes" do
    test "killing 3 of 5 agents — killed agents cleaned up, survivors intact" do
      # Start directly to avoid supervisor restart churn
      agents =
        Enum.map(1..5, fn i ->
          start_direct_agent("concurrent-#{i}")
        end)

      # Verify all 5 are alive before we start killing
      Enum.each(agents, fn {pid, _id} -> assert Process.alive?(pid) end)

      {to_kill, survivors} = Enum.split(agents, 3)

      # Trap exits so the test process survives linked-process deaths
      Process.flag(:trap_exit, true)

      # Kill 3 agents and wait for each death confirmation
      Enum.each(to_kill, fn {pid, _id} ->
        kill_and_wait(pid)
      end)

      # Verify killed agents' original pids are dead
      Enum.each(to_kill, fn {pid, _agent_id} ->
        refute Process.alive?(pid)
      end)

      # Poll until killed agents' IDs are cleaned up from Registry
      Enum.each(to_kill, fn {_pid, agent_id} ->
        wait_until(fn -> AgentRegistry.lookup(agent_id) == :not_found end)
      end)

      # Verify survivors are still running and reachable
      Enum.each(survivors, fn {pid, agent_id} ->
        assert Process.alive?(pid),
               "Survivor #{agent_id} (#{inspect(pid)}) should still be alive"

        assert {:ok, state} = Server.get_state(agent_id),
               "Survivor #{agent_id} should be reachable via get_state"

        assert state.status == :idle
      end)

      # Cleanup survivors
      Enum.each(survivors, fn {_pid, agent_id} ->
        Server.stop(agent_id)
      end)
    end
  end

  # ────────────────────────────────────────────────────────────
  # 3. Stress test — Many concurrent agents
  # ────────────────────────────────────────────────────────────

  describe "stress test — many concurrent agents" do
    test "start 20 agents, verify all registered, stop all, verify cleanup" do
      agents =
        Enum.map(1..20, fn i ->
          start_supervised_agent("stress-#{i}")
        end)

      # All 20 should be alive and registered
      Enum.each(agents, fn {pid, agent_id} ->
        assert Process.alive?(pid), "Agent #{agent_id} should be alive"
        assert {:ok, ^pid} = AgentRegistry.lookup(agent_id)
      end)

      # All 20 should appear in list_agents
      all_agents = AgentSupervisor.list_agents()

      Enum.each(agents, fn {_pid, agent_id} ->
        assert Enum.any?(all_agents, fn {id, _p} -> id == agent_id end),
               "Agent #{agent_id} should appear in list_agents"
      end)

      # Stop all 20
      Enum.each(agents, fn {_pid, agent_id} ->
        assert :ok = AgentSupervisor.stop_agent(agent_id)
      end)

      # All 20 should be gone from Registry
      Enum.each(agents, fn {_pid, agent_id} ->
        wait_until(fn -> AgentRegistry.lookup(agent_id) == :not_found end)
      end)
    end
  end

  # ────────────────────────────────────────────────────────────
  # 4. Event ordering under load
  # ────────────────────────────────────────────────────────────

  describe "event ordering under load" do
    test "5 rapidly started agents each produce an :agent_started event" do
      :ok = Events.subscribe()

      agents =
        Enum.map(1..5, fn i ->
          start_supervised_agent("event-#{i}")
        end)

      agent_ids = MapSet.new(agents, fn {_pid, id} -> id end)

      # Collect 5 :agent_started events
      received_ids =
        Enum.map(1..5, fn _ ->
          assert_receive %{type: :agent_started, payload: %{agent_id: id}}, 2000
          id
        end)
        |> MapSet.new()

      # Every agent should have exactly one :agent_started event
      assert MapSet.equal?(agent_ids, received_ids)

      # Cleanup
      Enum.each(agents, fn {_pid, agent_id} ->
        AgentSupervisor.stop_agent(agent_id)
      end)
    end
  end

  # ────────────────────────────────────────────────────────────
  # 5. Cross-component lifecycle
  # ────────────────────────────────────────────────────────────

  describe "cross-component lifecycle" do
    test "full lifecycle: start -> subscribe -> tool exec -> status update -> events -> stop -> cleanup" do
      # Start an agent
      {pid, agent_id} = start_supervised_agent("lifecycle-agent")

      # Subscribe to events (after start, so we skip the :agent_started event)
      :ok = Events.subscribe()

      # Use Tool.Executor to run a tool
      {:ok, result} = Executor.run(Cortex.TestTools.Echo, %{"hello" => "world"})
      assert result == %{"hello" => "world"}

      # Update agent status to :done
      assert :ok = Server.update_status(agent_id, :done)

      # Verify we received the status_changed event
      assert_receive %{
                       type: :agent_status_changed,
                       payload: %{
                         agent_id: ^agent_id,
                         old_status: :idle,
                         new_status: :done
                       }
                     },
                     2000

      # Verify agent state reflects the update
      assert {:ok, state} = Server.get_state(agent_id)
      assert state.status == :done

      # Stop agent via Server.stop/1 (calls GenServer.stop which invokes terminate/2)
      # We use this instead of AgentSupervisor.stop_agent because
      # DynamicSupervisor.terminate_child sends :shutdown and terminate/2
      # is not guaranteed without trap_exit.
      assert :ok = Server.stop(agent_id)
      Process.sleep(50)

      # Verify full cleanup
      refute Process.alive?(pid)
      assert {:error, :not_found} = Server.get_state(agent_id)

      # Verify we received the stopped event
      assert_receive %{
                       type: :agent_stopped,
                       payload: %{agent_id: ^agent_id}
                     },
                     2000
    end
  end

  # ────────────────────────────────────────────────────────────
  # 6. Agent state consistency — concurrent metadata updates
  # ────────────────────────────────────────────────────────────

  describe "agent state consistency" do
    test "concurrent metadata updates from 5 processes — no lost updates" do
      {_pid, agent_id} = start_supervised_agent("concurrency-test")

      # Spawn 5 processes that each update a unique metadata key
      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            key = :"key_#{i}"
            value = "value_#{i}"
            :ok = Server.update_metadata(agent_id, key, value)
            {key, value}
          end)
        end)

      # Await all tasks
      expected =
        Enum.map(tasks, fn task ->
          Task.await(task, 5000)
        end)

      # Verify final state has ALL metadata keys (GenServer serializes calls)
      {:ok, state} = Server.get_state(agent_id)

      Enum.each(expected, fn {key, value} ->
        assert Map.get(state.metadata, key) == value,
               "Expected metadata key #{inspect(key)} to be #{inspect(value)}, " <>
                 "got #{inspect(Map.get(state.metadata, key))}"
      end)

      AgentSupervisor.stop_agent(agent_id)
    end

    test "concurrent status updates — final status is one of the written values" do
      {_pid, agent_id} = start_supervised_agent("status-race")

      # Spawn concurrent status updates
      statuses = [:running, :done, :failed, :idle, :running]

      tasks =
        Enum.map(statuses, fn status ->
          Task.async(fn ->
            Server.update_status(agent_id, status)
          end)
        end)

      Enum.each(tasks, &Task.await(&1, 5000))

      # The final status must be one of the valid statuses
      # (GenServer serializes, so one wins — we just can't predict which)
      {:ok, state} = Server.get_state(agent_id)
      assert state.status in [:idle, :running, :done, :failed]

      AgentSupervisor.stop_agent(agent_id)
    end
  end
end
