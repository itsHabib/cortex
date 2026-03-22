defmodule Cortex.E2E.ExternalAgentTest do
  @moduledoc """
  True end-to-end test: Go sidecar ↔ gRPC ↔ ExternalAgent ↔ Executor.

  Starts the real Go sidecar binary, connects it to the Cortex Gateway via gRPC,
  dispatches a task through the full ExternalAgent → Provider.External pipeline,
  and uses a poller to auto-respond via the sidecar's HTTP API.

  Tagged `:e2e` — excluded by default. Run with:

      mix test test/e2e/external_agent_e2e_test.exs --include e2e

  Requires:
    - Go sidecar binary built at `sidecar/bin/cortex-sidecar`
    - Ports 4011, 9091 free
  """

  use ExUnit.Case, async: false

  alias Cortex.Agent.{ExternalAgent, ExternalSupervisor}
  alias Cortex.Gateway.Registry, as: GatewayRegistry

  require Logger

  @moduletag :e2e
  @moduletag timeout: 60_000

  @sidecar_bin Path.expand("../../sidecar/bin/cortex-sidecar", __DIR__)
  @sidecar_port 9091
  @grpc_port 4011
  @auth_token "e2e-test-token"
  @agent_name "e2e-test-agent"

  setup do
    unless File.exists?(@sidecar_bin) do
      flunk("Go sidecar binary not found at #{@sidecar_bin}. Run: cd sidecar && make build")
    end

    # Ensure :inets is started for :httpc
    :inets.start()

    # Set gateway auth token
    prev_token = System.get_env("CORTEX_GATEWAY_TOKEN")
    System.put_env("CORTEX_GATEWAY_TOKEN", @auth_token)

    # Start gRPC endpoint (disabled in test config)
    {:ok, grpc_pid} =
      GRPC.Server.Supervisor.start_link(
        endpoint: Cortex.Gateway.GrpcEndpoint,
        port: @grpc_port,
        start_server: true
      )

    # Start a process to drain sidecar stdout (prevents blocking on full pipe)
    drain_pid = spawn_link(fn -> drain_loop() end)

    # Start the Go sidecar
    sidecar_port = start_sidecar(drain_pid)

    # Wait for sidecar to register in Gateway.Registry
    :ok = wait_for_registration(@agent_name, 15_000)
    Logger.info("E2E setup complete: sidecar registered as #{@agent_name}")

    on_exit(fn ->
      # Kill sidecar
      try do
        Port.close(sidecar_port)
      catch
        _, _ -> :ok
      end

      # Stop gRPC server
      Process.exit(grpc_pid, :shutdown)

      # Clean up ExternalAgent
      case ExternalSupervisor.find_agent(@agent_name) do
        {:ok, pid} -> ExternalAgent.stop(pid)
        :not_found -> :ok
      end

      # Restore env
      if prev_token,
        do: System.put_env("CORTEX_GATEWAY_TOKEN", prev_token),
        else: System.delete_env("CORTEX_GATEWAY_TOKEN")
    end)

    %{sidecar_port: sidecar_port}
  end

  test "full pipeline: ExternalAgent.run dispatches to real sidecar and gets result" do
    poller_pid = start_task_poller(self())

    # Start an ExternalAgent for our sidecar
    {:ok, agent_pid} = ExternalSupervisor.start_agent(name: @agent_name)

    {:ok, state} = ExternalAgent.get_state(agent_pid)
    assert state.status == :healthy
    assert state.name == @agent_name

    # Dispatch work — the poller will auto-respond via sidecar HTTP API
    result =
      ExternalAgent.run(agent_pid, "What is 2 + 2?",
        team_name: @agent_name,
        timeout_ms: 30_000
      )

    assert {:ok, team_result} = result

    # Verify the poller saw and responded to a task
    assert_receive {:task_completed, task_id}, 10_000
    assert is_binary(task_id)

    # ExternalAgent should still be healthy
    {:ok, state} = ExternalAgent.get_state(agent_pid)
    assert state.status == :healthy

    Process.exit(poller_pid, :normal)
  end

  test "full pipeline via Runner.run with YAML config" do
    poller_pid = start_task_poller(self())

    tmp_dir = Path.join(System.tmp_dir!(), "cortex-e2e-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    try do
      yaml_content =
        "test/fixtures/orchestration/external-agent.yaml"
        |> File.read!()
        |> String.replace("${TEAM_NAME}", @agent_name)

      yaml_path = Path.join(tmp_dir, "orchestra.yaml")
      File.write!(yaml_path, yaml_content)

      assert {:ok, summary} = Cortex.Orchestration.Runner.run(yaml_path, workspace_path: tmp_dir)
      assert summary.status == :complete
      assert summary.teams[@agent_name].status == "done"

      assert_receive {:task_completed, _task_id}, 10_000
    after
      Process.exit(poller_pid, :normal)
      File.rm_rf!(tmp_dir)
    end
  end

  # -- Helpers --

  defp start_sidecar(drain_pid) do
    env = [
      {~c"CORTEX_GATEWAY_URL", ~c"localhost:#{@grpc_port}"},
      {~c"CORTEX_AGENT_NAME", ~c"#{@agent_name}"},
      {~c"CORTEX_AGENT_ROLE", ~c"e2e-test-worker"},
      {~c"CORTEX_AGENT_CAPABILITIES", ~c"testing,e2e"},
      {~c"CORTEX_AUTH_TOKEN", ~c"#{@auth_token}"},
      {~c"CORTEX_SIDECAR_PORT", ~c"#{@sidecar_port}"}
    ]

    port =
      Port.open({:spawn_executable, @sidecar_bin}, [
        :binary,
        :stderr_to_stdout,
        :exit_status,
        env: env
      ])

    # Forward port ownership to drain process so it receives the output
    Port.connect(port, drain_pid)
    port
  end

  defp drain_loop do
    receive do
      {_port, {:data, data}} ->
        Logger.debug("[sidecar] #{String.trim(data)}")
        drain_loop()

      {_port, {:exit_status, code}} ->
        Logger.warning("[sidecar] exited with code #{code}")

      _ ->
        drain_loop()
    end
  end

  defp wait_for_registration(agent_name, timeout) when timeout > 0 do
    agents = GatewayRegistry.list(GatewayRegistry)

    case Enum.find(agents, fn a -> a.name == agent_name end) do
      nil ->
        Process.sleep(500)
        wait_for_registration(agent_name, timeout - 500)

      _agent ->
        :ok
    end
  end

  defp wait_for_registration(agent_name, _timeout) do
    # Dump registry state for debugging
    agents = GatewayRegistry.list(GatewayRegistry)
    agent_names = Enum.map(agents, & &1.name)

    flunk("""
    Sidecar "#{agent_name}" did not register in Gateway.Registry within timeout.
    Registered agents: #{inspect(agent_names)}
    """)
  end

  defp start_task_poller(notify_pid) do
    spawn_link(fn -> poll_loop(notify_pid) end)
  end

  defp poll_loop(notify_pid) do
    case poll_for_task() do
      {:ok, %{"task_id" => task_id}} when is_binary(task_id) and task_id != "" ->
        Logger.info("E2E poller: Got task #{task_id}, submitting result")
        submit_task_result(task_id)
        send(notify_pid, {:task_completed, task_id})
        # Keep polling for more tasks
        Process.sleep(100)
        poll_loop(notify_pid)

      _ ->
        Process.sleep(200)
        poll_loop(notify_pid)
    end
  end

  defp poll_for_task do
    url = ~c"http://localhost:#{@sidecar_port}/task"

    case :httpc.request(:get, {url, []}, [{:timeout, 2_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, %{"task" => nil}} -> {:ok, %{}}
          {:ok, %{"task" => task}} when is_map(task) -> {:ok, task}
          _ -> {:error, :bad_json}
        end

      _ ->
        {:error, :request_failed}
    end
  catch
    _, _ -> {:error, :httpc_error}
  end

  defp submit_task_result(task_id) do
    url = ~c"http://localhost:#{@sidecar_port}/task/result"

    body =
      Jason.encode!(%{
        task_id: task_id,
        status: "completed",
        result_text: "E2E test result: task completed successfully",
        duration_ms: 100,
        input_tokens: 10,
        output_tokens: 20
      })

    headers = [{~c"content-type", ~c"application/json"}]

    case :httpc.request(
           :post,
           {url, headers, ~c"application/json", body},
           [{:timeout, 5_000}],
           []
         ) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      other -> Logger.warning("E2E: submit_task_result failed: #{inspect(other)}")
    end
  catch
    _, reason -> Logger.warning("E2E: submit_task_result error: #{inspect(reason)}")
  end
end
