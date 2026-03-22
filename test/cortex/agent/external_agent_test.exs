defmodule Cortex.Agent.ExternalAgentTest do
  use ExUnit.Case, async: false

  alias Cortex.Agent.ExternalAgent
  alias Cortex.Gateway.Registry, as: GatewayRegistry
  alias Cortex.Provider.External.PendingTasks

  @agent_name "test-external-agent"

  setup do
    # Cortex.PubSub is already started by the application supervision tree.

    # Start Gateway.Registry with a unique name per test
    registry_name = :"gateway_registry_#{System.unique_integer([:positive])}"
    start_supervised!({GatewayRegistry, name: registry_name})

    # Start PendingTasks with a unique name per test
    pending_name = :"pending_tasks_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Cortex.Provider.External.PendingTasks, name: pending_name, table_name: pending_name}
    )

    %{registry: registry_name, pending_tasks: pending_name}
  end

  defp register_mock_agent(registry, name) do
    # Spawn a long-lived process to act as the transport pid
    transport_pid = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, agent} =
      GatewayRegistry.register_grpc(
        registry,
        %{
          "name" => name,
          "role" => "worker",
          "capabilities" => ["general"]
        },
        transport_pid
      )

    {agent, transport_pid}
  end

  defp start_external_agent(ctx, opts \\ []) do
    name = Keyword.get(opts, :name, @agent_name)

    agent_opts =
      [
        name: name,
        registry: ctx.registry,
        timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
        pending_tasks: ctx.pending_tasks
      ]
      |> maybe_add_push_fn(Keyword.get(opts, :push_fn))

    start_supervised!({ExternalAgent, agent_opts}, id: :"external_agent_#{name}")
  end

  defp maybe_add_push_fn(opts, nil), do: opts
  defp maybe_add_push_fn(opts, push_fn), do: Keyword.put(opts, :push_fn, push_fn)

  # -- Init Tests --

  describe "start_link/1" do
    test "succeeds when sidecar is registered", ctx do
      {_agent, _pid} = register_mock_agent(ctx.registry, @agent_name)
      pid = start_external_agent(ctx)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns error when no matching agent in registry", ctx do
      Process.flag(:trap_exit, true)

      result =
        ExternalAgent.start_link(
          name: "nonexistent-agent",
          registry: ctx.registry,
          pending_tasks: ctx.pending_tasks
        )

      assert {:error, :agent_not_found} = result
    end

    test "returns error when registry is not available", ctx do
      Process.flag(:trap_exit, true)

      result =
        ExternalAgent.start_link(
          name: @agent_name,
          registry: :nonexistent_registry,
          pending_tasks: ctx.pending_tasks
        )

      assert {:error, :registry_not_available} = result
    end
  end

  # -- get_state Tests --

  describe "get_state/1" do
    test "returns correct agent info", ctx do
      {agent, _pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      {:ok, state} = ExternalAgent.get_state(ea_pid)

      assert state.name == @agent_name
      assert state.agent_id == agent.id
      assert state.status == :healthy
      assert state.agent_info.name == @agent_name
    end
  end

  # -- run/3 Tests --

  describe "run/3" do
    test "delegates to Provider.External and returns result", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)

      # Create a push_fn that simulates a sidecar: captures the request,
      # and resolves the pending task with a success result
      test_pid = self()
      pending = ctx.pending_tasks

      push_fn = fn _transport, _pid, task_request ->
        send(test_pid, {:push_called, task_request})

        # Simulate sidecar returning a result after a short delay
        spawn(fn ->
          Process.sleep(10)
          task_id = task_request["task_id"]

          result = %{
            "task_id" => task_id,
            "status" => "completed",
            "result_text" => "Task done!",
            "duration_ms" => 100,
            "input_tokens" => 50,
            "output_tokens" => 25
          }

          PendingTasks.resolve_task(pending, task_id, result)
        end)

        {:ok, :sent}
      end

      ea_pid = start_external_agent(ctx, push_fn: push_fn)
      {:ok, team_result} = ExternalAgent.run(ea_pid, "Build the API")

      assert team_result.team == @agent_name
      assert team_result.status == :success
      assert team_result.result == "Task done!"

      # Verify push was called
      assert_received {:push_called, request}
      assert request["prompt"] == "Build the API"
    end

    test "returns {:error, :agent_unhealthy} on unhealthy agent", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      # Simulate sidecar disconnect by broadcasting agent_unregistered
      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: agent.id,
        name: @agent_name,
        reason: :channel_down
      })

      # Give PubSub a moment to deliver
      Process.sleep(50)

      result = ExternalAgent.run(ea_pid, "Should fail")
      assert {:error, :agent_unhealthy} = result
    end

    test "returns {:error, :timeout} when sidecar doesn't respond", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)

      # Push function that succeeds but never resolves the task
      push_fn = fn _transport, _pid, _task_request ->
        {:ok, :sent}
      end

      ea_pid = start_external_agent(ctx, push_fn: push_fn, timeout_ms: 100)
      result = ExternalAgent.run(ea_pid, "Should timeout", timeout_ms: 100)
      assert {:error, :timeout} = result
    end
  end

  # -- PubSub Event Tests --

  describe "PubSub event handling" do
    test "agent_unregistered for matching agent_id transitions to unhealthy", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :healthy

      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: agent.id,
        name: @agent_name,
        reason: :channel_down
      })

      Process.sleep(50)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :unhealthy
    end

    test "agent_unregistered for non-matching agent_id is ignored", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: "some-other-id",
        name: "other-agent",
        reason: :channel_down
      })

      Process.sleep(50)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :healthy
    end

    test "agent_registered with matching name restores healthy and updates agent info", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      # Mark unhealthy via disconnect
      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: agent.id,
        name: @agent_name,
        reason: :channel_down
      })

      Process.sleep(50)
      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :unhealthy

      # Register a new agent with the same name (simulating reconnect)
      new_transport_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, new_agent} =
        GatewayRegistry.register_grpc(
          ctx.registry,
          %{
            "name" => @agent_name,
            "role" => "worker",
            "capabilities" => ["general"]
          },
          new_transport_pid
        )

      # The agent_registered event was broadcast by Gateway.Registry.register_grpc
      Process.sleep(50)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :healthy
      assert state.agent_id == new_agent.id
    end

    test "agent_registered with non-matching name is ignored", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      Cortex.Events.broadcast(:agent_registered, %{
        agent_id: "some-new-id",
        name: "different-agent",
        role: "worker",
        capabilities: ["general"]
      })

      Process.sleep(50)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.agent_id == agent.id
      assert state.status == :healthy
    end

    test "agent_status_changed updates cached agent_info", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      Cortex.Events.broadcast(:agent_status_changed, %{
        agent_id: agent.id,
        old_status: :idle,
        new_status: :working
      })

      Process.sleep(50)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.agent_info.status == :working
    end
  end

  # -- stop/1 Tests --

  describe "stop/1" do
    test "gracefully stops the GenServer", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      assert Process.alive?(ea_pid)
      :ok = ExternalAgent.stop(ea_pid)
      refute Process.alive?(ea_pid)
    end
  end

  # -- Edge Case Tests --

  describe "edge cases" do
    test "sidecar disconnect mid-task — PubSub queued behind handle_call", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      pending = ctx.pending_tasks

      # push_fn that sleeps 200ms before resolving, giving time to broadcast disconnect
      push_fn = fn _transport, _pid, task_request ->
        spawn(fn ->
          Process.sleep(200)
          task_id = task_request["task_id"]

          PendingTasks.resolve_task(pending, task_id, %{
            "task_id" => task_id,
            "status" => "completed",
            "result_text" => "Done mid-disconnect",
            "duration_ms" => 200,
            "input_tokens" => 10,
            "output_tokens" => 5
          })
        end)

        {:ok, :sent}
      end

      ea_pid = start_external_agent(ctx, push_fn: push_fn)

      # Start run/3 in a Task — it will block for ~200ms
      run_task =
        Task.async(fn ->
          ExternalAgent.run(ea_pid, "Long task")
        end)

      # While handle_call is blocking, broadcast disconnect
      Process.sleep(50)

      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: agent.id,
        name: @agent_name,
        reason: :channel_down
      })

      # run/3 should still succeed — the task was already in-flight
      assert {:ok, result} = Task.await(run_task, 5_000)
      assert result.result == "Done mid-disconnect"

      # After run completes, the queued PubSub event should have transitioned to :unhealthy
      poll_until(fn ->
        {:ok, state} = ExternalAgent.get_state(ea_pid)
        state.status == :unhealthy
      end)

      # Subsequent run/3 should be rejected
      assert {:error, :agent_unhealthy} = ExternalAgent.run(ea_pid, "Should fail")
    end

    test "rapid disconnect/reconnect — final state is healthy with new agent_id", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      # Broadcast disconnect for old agent
      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: agent.id,
        name: @agent_name,
        reason: :channel_down
      })

      # Immediately register a new agent with the same name (reconnect)
      new_transport_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, new_agent} =
        GatewayRegistry.register_grpc(
          ctx.registry,
          %{
            "name" => @agent_name,
            "role" => "worker",
            "capabilities" => ["general"]
          },
          new_transport_pid
        )

      # Wait for both PubSub events to be processed
      poll_until(fn ->
        {:ok, state} = ExternalAgent.get_state(ea_pid)
        state.agent_id == new_agent.id and state.status == :healthy
      end)

      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :healthy
      assert state.agent_id == new_agent.id
      assert state.agent_id != agent.id
    end

    test "stale reconnect — registry returns :not_found, state unchanged", ctx do
      {agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      # Disconnect
      Cortex.Events.broadcast(:agent_unregistered, %{
        agent_id: agent.id,
        name: @agent_name,
        reason: :channel_down
      })

      Process.sleep(50)
      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :unhealthy

      # Broadcast agent_registered with matching name but agent_id NOT in registry
      # (simulates: agent registered then immediately gone before we can look it up)
      Cortex.Events.broadcast(:agent_registered, %{
        agent_id: "stale-agent-id-not-in-registry",
        name: @agent_name,
        role: "worker",
        capabilities: ["general"]
      })

      Process.sleep(50)

      # State should remain unhealthy with original agent_id
      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.status == :unhealthy
      assert state.agent_id == agent.id
    end

    test "multiple queued run/3 calls — both get correct results", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      pending = ctx.pending_tasks
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      # push_fn that resolves after 100ms, tracks call order
      push_fn = fn _transport, _pid, task_request ->
        order = :counters.add(call_count, 1, 1) || :counters.get(call_count, 1)
        send(test_pid, {:push_order, task_request["prompt"], order})

        spawn(fn ->
          Process.sleep(100)
          task_id = task_request["task_id"]

          PendingTasks.resolve_task(pending, task_id, %{
            "task_id" => task_id,
            "status" => "completed",
            "result_text" => "Result for: #{task_request["prompt"]}",
            "duration_ms" => 100,
            "input_tokens" => 10,
            "output_tokens" => 5
          })
        end)

        {:ok, :sent}
      end

      ea_pid = start_external_agent(ctx, push_fn: push_fn)

      # Spawn two concurrent callers
      task1 = Task.async(fn -> ExternalAgent.run(ea_pid, "First prompt") end)
      task2 = Task.async(fn -> ExternalAgent.run(ea_pid, "Second prompt") end)

      # Both should succeed
      assert {:ok, result1} = Task.await(task1, 5_000)
      assert {:ok, result2} = Task.await(task2, 5_000)

      # Each gets its own correct result
      assert result1.result == "Result for: First prompt"
      assert result2.result == "Result for: Second prompt"

      # Both results have the correct team name
      assert result1.team == @agent_name
      assert result2.team == @agent_name
    end

    test "GenServer killed while run/3 is in progress — caller gets clean exit", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)

      # push_fn that never resolves (simulates hung sidecar)
      push_fn = fn _transport, _pid, _task_request ->
        {:ok, :sent}
      end

      ea_pid = start_external_agent(ctx, push_fn: push_fn, timeout_ms: 30_000)

      # Start run/3 in a Task — it will block indefinitely
      run_task =
        Task.async(fn ->
          try do
            ExternalAgent.run(ea_pid, "Hung task", timeout_ms: 30_000)
          catch
            :exit, reason -> {:caught_exit, reason}
          end
        end)

      # Give the GenServer.call time to start blocking
      Process.sleep(50)

      # Kill the GenServer while run/3 is in progress (simulates crash or
      # supervisor shutdown). Process.exit(:kill) is immediate — no need to
      # wait for GenServer.stop's synchronous handshake.
      Process.exit(ea_pid, :kill)

      # The run/3 caller should get a clean exit, not hang
      result = Task.await(run_task, 5_000)
      assert {:caught_exit, _reason} = result

      # GenServer should be dead
      refute Process.alive?(ea_pid)
    end

    test "dispatch_via_provider handles Provider.External.start raising", ctx do
      {_agent, transport_pid} = register_mock_agent(ctx.registry, @agent_name)
      ea_pid = start_external_agent(ctx)

      # Kill the transport pid to make the agent unresolvable in the registry
      # for get_push_pid, WITHOUT broadcasting PubSub (so GenServer stays :healthy)
      Process.exit(transport_pid, :kill)
      Process.sleep(20)

      # Now run/3 will call dispatch_via_provider, which calls Provider.External.start,
      # which calls Registry.get_push_pid — the transport pid is dead, so the agent
      # entry was cleaned up by the :DOWN monitor in Gateway.Registry, meaning
      # find_agent_by_name returns :agent_not_found.
      # The key invariant: GenServer must survive and return {:error, _}
      result = ExternalAgent.run(ea_pid, "Should fail gracefully")
      assert {:error, _reason} = result

      # GenServer must still be alive
      assert Process.alive?(ea_pid)
      {:ok, state} = ExternalAgent.get_state(ea_pid)
      assert state.name == @agent_name
    end

    test "dispatch_via_provider handles exception from Provider.External without crashing", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)

      # push_fn that raises an exception
      push_fn = fn _transport, _pid, _task_request ->
        raise "Sidecar connection exploded"
      end

      ea_pid = start_external_agent(ctx, push_fn: push_fn)

      # The raise happens inside Provider.External.run -> dispatch_and_wait -> push_task
      # which is inside dispatch_via_provider's try/after block.
      # This should NOT crash the GenServer.
      result = ExternalAgent.run(ea_pid, "Should not crash GenServer")
      assert {:error, _reason} = result

      # GenServer must still be alive
      assert Process.alive?(ea_pid)
    end
  end

  # -- Helpers --

  defp poll_until(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1_000)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_poll(fun, interval, deadline)
  end

  defp do_poll(fun, interval, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("poll_until timed out waiting for condition")
      else
        Process.sleep(interval)
        do_poll(fun, interval, deadline)
      end
    end
  end
end
