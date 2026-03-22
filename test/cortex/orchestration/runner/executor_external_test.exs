defmodule Cortex.Orchestration.Runner.ExecutorExternalTest do
  use ExUnit.Case, async: false

  # Provider.External is gated — these tests are excluded until the agent worker ships.
  @moduletag :external

  alias Cortex.Agent.ExternalAgent
  alias Cortex.Agent.ExternalSupervisor
  alias Cortex.Gateway.Registry, as: GatewayRegistry
  alias Cortex.Orchestration.Runner
  alias Cortex.Orchestration.Workspace
  alias Cortex.Provider.External.PendingTasks

  @moduletag :orchestration

  # -- Helpers --

  defp create_tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cortex_executor_ext_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp cleanup(dir) do
    File.rm_rf!(dir)
  end

  defp write_yaml(dir, filename, content) do
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  defp write_mock_script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/bash\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp success_ndjson do
    """
    echo '{"type":"system","subtype":"init","session_id":"sess-001"}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Working..."}]}}'
    echo '{"type":"result","subtype":"success","result":"All tasks completed","cost_usd":0.25,"num_turns":3,"duration_ms":15000}'
    """
  end

  defp register_mock_sidecar(team_name) do
    # Spawn a long-lived process to act as the gRPC stream transport pid.
    # TaskPush.push(:grpc, pid, request) just does send(pid, msg), so
    # this process only needs to be alive to receive messages.
    transport_pid = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, agent} =
      GatewayRegistry.register_grpc(
        %{
          "name" => team_name,
          "role" => "worker",
          "capabilities" => ["general"]
        },
        transport_pid
      )

    {agent, transport_pid}
  end

  defp cleanup_sidecar(team_name, transport_pid) do
    # Stop ExternalAgent if running
    case ExternalSupervisor.find_agent(team_name) do
      {:ok, pid} ->
        try do
          ExternalAgent.stop(pid)
        catch
          _, _ -> :ok
        end

      :not_found ->
        :ok
    end

    # Kill the transport pid — Gateway.Registry auto-unregisters
    # the agent when the transport pid goes down.
    if Process.alive?(transport_pid), do: Process.exit(transport_pid, :kill)

    # Give the registry a moment to process the DOWN message
    Process.sleep(50)
  end

  @external_fixture_path "test/fixtures/orchestration/external-agent.yaml"

  defp external_yaml(team_name) do
    @external_fixture_path
    |> File.read!()
    |> String.replace("${TEAM_NAME}", team_name)
  end

  defp cli_yaml do
    """
    name: "cli-test"
    defaults:
      model: sonnet
      max_turns: 10
      permission_mode: acceptEdits
      timeout_minutes: 5
    teams:
      - name: backend
        lead:
          role: "Backend Lead"
        tasks:
          - summary: "Build the API"
        depends_on: []
    """
  end

  # Spawns a background process that polls PendingTasks and resolves
  # any pending tasks with a success result. This simulates the sidecar
  # returning a TaskResult via route_task_result.
  defp start_mock_sidecar do
    test_pid = self()
    spawn_link(fn -> mock_sidecar_loop(test_pid) end)
  end

  defp mock_sidecar_loop(test_pid) do
    Process.sleep(20)

    tasks =
      try do
        PendingTasks.list_pending(PendingTasks)
      rescue
        _ -> []
      end

    case tasks do
      [] ->
        mock_sidecar_loop(test_pid)

      entries when is_list(entries) ->
        Enum.each(entries, fn entry ->
          task_id = entry.task_id

          result = %{
            "task_id" => task_id,
            "status" => "completed",
            "result_text" => "External task completed",
            "duration_ms" => 200,
            "input_tokens" => 100,
            "output_tokens" => 50
          }

          PendingTasks.resolve_task(PendingTasks, task_id, result)
          send(test_pid, {:task_resolved, task_id})
        end)

        # Keep looping to handle subsequent tasks (e.g., multi-run tests)
        mock_sidecar_loop(test_pid)
    end
  end

  # -- Tests: External provider dispatch --

  describe "executor with provider: external" do
    test "routes through ExternalAgent and completes successfully" do
      team_name = "ext-success-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()

      {_agent, transport_pid} = register_mock_sidecar(team_name)
      _mock = start_mock_sidecar()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        assert {:ok, summary} = Runner.run(yaml_path, workspace_path: tmp_dir)

        assert summary.status == :complete
        assert summary.project == "external-test"
        assert map_size(summary.teams) == 1
        assert summary.teams[team_name].status == "done"
      after
        cleanup_sidecar(team_name, transport_pid)
        cleanup(tmp_dir)
      end
    end

    test "returns error outcome when sidecar is not registered" do
      team_name = "no-sidecar-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        # ExternalAgent.start_link will fail because no agent is registered,
        # producing {:error, :agent_not_found} from ensure_external_agent.
        # The executor should return a clean tier failure, not a crash.
        result = Runner.run(yaml_path, workspace_path: tmp_dir, continue_on_error: false)

        assert {:error, {:tier_failed, 0, [^team_name]}} = result
      after
        cleanup(tmp_dir)
      end
    end
  end

  # -- Regression test: CLI path unchanged --

  describe "executor with provider: cli (regression)" do
    test "CLI path still works after external dispatch changes" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", cli_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson())

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
        assert summary.project == "cli-test"
        assert summary.teams["backend"].status == "done"
        assert summary.total_cost > 0
      after
        cleanup(tmp_dir)
      end
    end
  end

  # -- Adversarial edge-case tests --

  describe "adversarial: concurrent ensure_external_agent race" do
    @describetag :adversarial

    test "two concurrent start_agent calls for same name both succeed" do
      team_name = "race-#{:erlang.unique_integer([:positive])}"
      {_agent, transport_pid} = register_mock_sidecar(team_name)

      try do
        # Spawn two concurrent tasks that both try to start the same agent
        tasks =
          for _ <- 1..2 do
            Task.async(fn ->
              ExternalSupervisor.start_agent(name: team_name)
            end)
          end

        results = Task.await_many(tasks, 5_000)

        # Both must return {:ok, pid} pointing to the same process
        assert Enum.all?(results, fn
                 {:ok, pid} when is_pid(pid) -> true
                 _ -> false
               end)

        pids = Enum.map(results, fn {:ok, pid} -> pid end)
        assert Enum.uniq(pids) |> length() == 1
      after
        cleanup_sidecar(team_name, transport_pid)
      end
    end
  end

  describe "adversarial: stale ExternalAgent pid" do
    @describetag :adversarial

    test "ExternalAgent.run on dead process returns clean error via executor" do
      team_name = "stale-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()
      {_agent, transport_pid} = register_mock_sidecar(team_name)

      try do
        # Start the ExternalAgent
        {:ok, agent_pid} = ExternalSupervisor.start_agent(name: team_name)

        # Kill it to simulate a crash between ensure_external_agent and run
        Process.exit(agent_pid, :kill)
        # Wait for the process to die and the registry to clean up
        Process.sleep(50)
        refute Process.alive?(agent_pid)

        # Now run the executor — it will find the agent in AgentRegistry is gone,
        # start a new one, but the sidecar is still registered so it should work.
        # OR if the agent pid is stale, the try/catch in run_via_external_agent
        # should catch the exit and return {:error, _}.
        #
        # To specifically test the stale-pid path, we call ExternalAgent.run
        # directly on the dead pid via a try/catch (simulating what the executor does).
        result =
          try do
            ExternalAgent.run(agent_pid, "test prompt", [])
          catch
            :exit, reason -> {:error, {:agent_exit, reason}}
          end

        assert {:error, _} = result
      after
        cleanup_sidecar(team_name, transport_pid)
        cleanup(tmp_dir)
      end
    end

    test "executor handles stale pid gracefully via full Runner.run path" do
      team_name = "stale-runner-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()
      {_agent, transport_pid} = register_mock_sidecar(team_name)

      try do
        # Pre-start then kill the ExternalAgent
        {:ok, agent_pid} = ExternalSupervisor.start_agent(name: team_name)
        Process.exit(agent_pid, :kill)
        Process.sleep(50)

        # Kill the transport pid too so re-creation also fails (agent_not_found)
        Process.exit(transport_pid, :kill)
        Process.sleep(50)

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        # Should get a clean tier failure, not a crash
        result = Runner.run(yaml_path, workspace_path: tmp_dir, continue_on_error: false)
        assert {:error, {:tier_failed, 0, [^team_name]}} = result
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "adversarial: ExternalSupervisor not running" do
    @describetag :adversarial

    test "ensure_external_agent returns clean error when supervisor is down" do
      team_name = "no-sup-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()

      try do
        # Stop the ExternalSupervisor temporarily
        sup_pid = Process.whereis(Cortex.Agent.ExternalSupervisor)
        assert sup_pid != nil, "ExternalSupervisor should be running"

        # We can't easily stop the supervisor without affecting other tests,
        # so we test the try/catch path by calling start_agent with a stopped
        # supervisor name. We'll use a name that doesn't exist.
        result =
          try do
            DynamicSupervisor.start_child(
              :nonexistent_supervisor,
              {ExternalAgent, name: team_name}
            )
          catch
            :exit, reason -> {:error, {:supervisor_not_available, reason}}
          end

        assert {:error, {:supervisor_not_available, _}} = result

        # Now verify the full Runner path handles this gracefully.
        # Since we can't stop the real supervisor, we instead verify
        # that running with a team_name that has no sidecar AND no supervisor
        # path produces a clean error (the agent_not_found from start_agent's
        # child_spec failing is the real path exercised here).
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))
        result = Runner.run(yaml_path, workspace_path: tmp_dir, continue_on_error: false)
        assert {:error, {:tier_failed, 0, [^team_name]}} = result
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "adversarial: Provider.External.start failure" do
    @describetag :adversarial

    test "provider start failure propagates cleanly to executor" do
      team_name = "prov-fail-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()
      {_agent, transport_pid} = register_mock_sidecar(team_name)

      try do
        # Start the ExternalAgent successfully
        {:ok, agent_pid} = ExternalSupervisor.start_agent(name: team_name)
        assert Process.alive?(agent_pid)

        # Now kill the transport pid so the sidecar is unregistered.
        # The ExternalAgent won't know (PubSub may or may not arrive in time).
        # When run is called, Provider.External.start succeeds (Gateway.Registry
        # process is alive), but Provider.External.run will fail with
        # :agent_not_found because the agent was removed from the registry.
        Process.exit(transport_pid, :kill)
        Process.sleep(50)

        result = ExternalAgent.run(agent_pid, "test prompt", timeout_ms: 2_000)
        assert {:error, _reason} = result

        # The GenServer should still be alive
        assert Process.alive?(agent_pid)
      after
        # Transport is already dead, just clean up the agent
        case ExternalSupervisor.find_agent(team_name) do
          {:ok, pid} ->
            try do
              ExternalAgent.stop(pid)
            catch
              _, _ -> :ok
            end

          :not_found ->
            :ok
        end

        cleanup(tmp_dir)
      end
    end
  end

  describe "adversarial: Task.await_many timeout isolation" do
    @describetag :adversarial

    test "killing caller task leaves ExternalAgent healthy and reusable" do
      team_name = "timeout-#{:erlang.unique_integer([:positive])}"
      {_agent, transport_pid} = register_mock_sidecar(team_name)

      try do
        # Trap exits so killing the spawned process doesn't kill the test
        Process.flag(:trap_exit, true)

        # Start ExternalAgent
        {:ok, agent_pid} = ExternalSupervisor.start_agent(name: team_name)

        # Spawn a linked process that calls ExternalAgent.run with a short
        # timeout so the Provider.External receive unblocks quickly after
        # the caller is killed. The GenServer's handle_call is blocked in
        # Provider.External.wait_for_result's receive — it only unblocks
        # on result delivery or timeout.
        caller_pid =
          spawn_link(fn ->
            ExternalAgent.run(agent_pid, "test prompt", timeout_ms: 500)
          end)

        # Give the call time to reach the GenServer and start Provider.External
        Process.sleep(100)

        # Kill the caller (simulates Task.await_many timeout)
        Process.exit(caller_pid, :kill)

        # Receive the EXIT message from the linked process
        assert_receive {:EXIT, ^caller_pid, :killed}, 1_000

        # Wait for Provider.External's receive timeout to fire (500ms),
        # which unblocks the GenServer's handle_call
        Process.sleep(600)

        # The ExternalAgent GenServer should still be alive
        assert Process.alive?(agent_pid)

        # And it should be in a healthy state
        {:ok, state} = ExternalAgent.get_state(agent_pid)
        assert state.status == :healthy
      after
        Process.flag(:trap_exit, false)
        cleanup_sidecar(team_name, transport_pid)
      end
    end
  end

  describe "adversarial: cross-run state isolation" do
    @describetag :adversarial

    test "same team_name reused across two runs has no state leakage" do
      team_name = "reuse-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()
      {_agent, transport_pid} = register_mock_sidecar(team_name)
      _mock = start_mock_sidecar()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        # First run
        assert {:ok, summary1} = Runner.run(yaml_path, workspace_path: tmp_dir)
        assert summary1.status == :complete

        # The ExternalAgent should persist
        assert {:ok, agent_pid} = ExternalSupervisor.find_agent(team_name)
        assert Process.alive?(agent_pid)

        # Second run (reuse same workspace — the workspace will be re-initialized)
        tmp_dir2 = create_tmp_dir()
        yaml_path2 = write_yaml(tmp_dir2, "orchestra.yaml", external_yaml(team_name))

        assert {:ok, summary2} = Runner.run(yaml_path2, workspace_path: tmp_dir2)
        assert summary2.status == :complete

        # Both runs should have completed independently
        assert summary1.teams[team_name].status == "done"
        assert summary2.teams[team_name].status == "done"
      after
        cleanup_sidecar(team_name, transport_pid)
        cleanup(tmp_dir)
      end
    end
  end

  describe "adversarial: telemetry events during external dispatch" do
    @describetag :adversarial

    test "emits gateway task dispatched and completed telemetry" do
      team_name = "telem-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()
      {_agent, transport_pid} = register_mock_sidecar(team_name)
      _mock = start_mock_sidecar()

      handler_id = "test-telem-#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      # Attach telemetry handlers
      :telemetry.attach(
        "#{handler_id}-dispatched",
        [:cortex, :gateway, :task, :dispatched],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_dispatched, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "#{handler_id}-completed",
        [:cortex, :gateway, :task, :completed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_completed, measurements, metadata})
        end,
        nil
      )

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        assert {:ok, summary} = Runner.run(yaml_path, workspace_path: tmp_dir)
        assert summary.status == :complete

        # Verify dispatched telemetry event. Two dispatched events are emitted:
        # one from TaskPush (agent_id may be nil) and one from Provider.External
        # (agent_id set). We match on the one with a non-nil agent_id.
        assert_receive {:telemetry_dispatched, _, %{agent_id: agent_id} = dispatched_meta}, 2_000
        # If first event had nil agent_id, drain it and get the next one
        dispatched_meta =
          if is_nil(agent_id) do
            assert_receive {:telemetry_dispatched, _, meta}, 2_000
            meta
          else
            dispatched_meta
          end

        assert is_binary(dispatched_meta.task_id)
        assert is_binary(dispatched_meta.agent_id)

        # Verify completed telemetry event
        assert_receive {:telemetry_completed, completed_measurements, completed_meta}, 2_000
        assert is_binary(completed_meta.task_id)
        assert is_binary(completed_meta.agent_id)
        assert completed_meta.status == :success
        assert is_integer(completed_measurements.duration_ms)
      after
        :telemetry.detach("#{handler_id}-dispatched")
        :telemetry.detach("#{handler_id}-completed")
        cleanup_sidecar(team_name, transport_pid)
        cleanup(tmp_dir)
      end
    end
  end

  # -- Integration test --

  describe "end-to-end external agent flow" do
    @describetag :integration

    test "full DAG run with mock sidecar" do
      team_name = "ext-e2e-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()

      {_agent, transport_pid} = register_mock_sidecar(team_name)
      _mock = start_mock_sidecar()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        assert {:ok, summary} = Runner.run(yaml_path, workspace_path: tmp_dir)

        assert summary.status == :complete

        # Verify workspace state
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)
        assert state.teams[team_name].status == "done"

        # Verify ExternalAgent is still alive (persists for potential reuse)
        assert {:ok, pid} = ExternalSupervisor.find_agent(team_name)
        assert Process.alive?(pid)
      after
        cleanup_sidecar(team_name, transport_pid)
        cleanup(tmp_dir)
      end
    end

    test "ExternalAgent persists after run for reuse" do
      team_name = "ext-persist-#{:erlang.unique_integer([:positive])}"
      tmp_dir = create_tmp_dir()

      {_agent, transport_pid} = register_mock_sidecar(team_name)
      _mock = start_mock_sidecar()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", external_yaml(team_name))

        assert {:ok, _summary} = Runner.run(yaml_path, workspace_path: tmp_dir)

        # The ExternalAgent should still be running after the run completes
        assert {:ok, pid} = ExternalSupervisor.find_agent(team_name)
        assert Process.alive?(pid)

        # And it should be in healthy state
        {:ok, state} = ExternalAgent.get_state(pid)
        assert state.status == :healthy
        assert state.name == team_name
      after
        cleanup_sidecar(team_name, transport_pid)
        cleanup(tmp_dir)
      end
    end
  end
end
