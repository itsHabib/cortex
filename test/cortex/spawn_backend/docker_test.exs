defmodule Cortex.SpawnBackend.DockerTest do
  use ExUnit.Case, async: true

  alias Cortex.SpawnBackend.Docker
  alias Cortex.SpawnBackend.Docker.Handle

  # -- Mock Client Module --

  defmodule MockClient do
    @moduledoc false

    # Uses the process dictionary to track calls and return configured responses.
    # Tests configure responses via `MockClient.setup/1`.

    def setup(responses) do
      Process.put(:mock_docker_responses, responses)
      Process.put(:mock_docker_calls, [])
    end

    def calls do
      Process.get(:mock_docker_calls, []) |> Enum.reverse()
    end

    defp record_call(call) do
      calls = Process.get(:mock_docker_calls, [])
      Process.put(:mock_docker_calls, [call | calls])
    end

    defp get_response(key, default) do
      responses = Process.get(:mock_docker_responses, %{})
      Map.get(responses, key, default)
    end

    def ping(_opts \\ []) do
      record_call({:ping, []})
      get_response(:ping, :ok)
    end

    def create_network(name, _opts \\ []) do
      record_call({:create_network, [name]})
      get_response({:create_network, name}, {:ok, "net-" <> name})
    end

    def create_container(spec, _opts \\ []) do
      name = Map.get(spec, "name", "unnamed")
      record_call({:create_container, [name, spec]})
      get_response({:create_container, name}, {:ok, "cid-" <> name})
    end

    def start_container(id, _opts \\ []) do
      record_call({:start_container, [id]})
      get_response({:start_container, id}, :ok)
    end

    def stop_container(id, _opts \\ []) do
      record_call({:stop_container, [id]})
      get_response({:stop_container, id}, :ok)
    end

    def remove_container(id, _opts \\ []) do
      record_call({:remove_container, [id]})
      get_response({:remove_container, id}, :ok)
    end

    def remove_network(id, _opts \\ []) do
      record_call({:remove_network, [id]})
      get_response({:remove_network, id}, :ok)
    end

    def inspect_container(id, _opts \\ []) do
      record_call({:inspect_container, [id]})
      get_response({:inspect_container, id}, {:ok, %{"State" => %{"Status" => "running"}}})
    end

    def container_logs(id, _opts \\ []) do
      record_call({:container_logs, [id]})
      get_response({:container_logs, id}, {:ok, Stream.map(["hello\n"], & &1)})
    end

    def list_containers(filters, _opts \\ []) do
      record_call({:list_containers, [filters]})
      get_response(:list_containers, {:ok, []})
    end
  end

  # -- Mock Registry --

  defmodule MockRegistry do
    @moduledoc false
    use GenServer

    def start_link(opts \\ []) do
      registered_agents = Keyword.get(opts, :agents, [])
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, registered_agents, name: name)
    end

    @impl true
    def init(agents), do: {:ok, agents}

    @impl true
    def handle_call(:list, _from, agents), do: {:reply, agents, agents}
  end

  # -- Helper --

  defp default_spawn_opts(registry_name) do
    [
      team_name: "backend",
      run_id: "run-123",
      docker_client: MockClient,
      registry: registry_name,
      registration_timeout_ms: 500
    ]
  end

  defp spawn_with_mock_registry(mock_responses \\ %{}) do
    # Start a mock registry with the agent already registered
    agent = %{name: "backend", id: "agent-1"}
    {:ok, registry} = MockRegistry.start_link(agents: [agent], name: nil)

    MockClient.setup(mock_responses)
    opts = default_spawn_opts(registry)

    result = Docker.spawn(opts)
    {result, MockClient.calls()}
  end

  # -- Tests --

  describe "spawn/1" do
    test "creates network, sidecar, and worker in correct order" do
      {result, calls} = spawn_with_mock_registry()

      assert {:ok, %Handle{}} = result

      call_ops = Enum.map(calls, fn {op, _args} -> op end)

      assert :ping in call_ops
      assert :create_network in call_ops

      # Verify order: network before containers
      network_idx = Enum.find_index(call_ops, &(&1 == :create_network))
      first_container_idx = Enum.find_index(call_ops, &(&1 == :create_container))
      assert network_idx < first_container_idx

      # Verify both containers created
      container_calls =
        Enum.filter(calls, fn {op, _} -> op == :create_container end)

      assert length(container_calls) == 2

      container_names = Enum.map(container_calls, fn {_, [name, _spec]} -> name end)
      assert Enum.any?(container_names, &String.contains?(&1, "sidecar"))
      assert Enum.any?(container_names, &String.contains?(&1, "worker"))
    end

    test "returns handle with correct fields" do
      {{:ok, handle}, _calls} = spawn_with_mock_registry()

      assert %Handle{
               team_name: "backend",
               run_id: "run-123",
               docker_client: MockClient
             } = handle

      assert handle.sidecar_container_id != nil
      assert handle.worker_container_id != nil
      assert handle.network_id != nil
    end

    test "passes correct env vars to sidecar" do
      {_result, calls} = spawn_with_mock_registry()

      sidecar_call =
        Enum.find(calls, fn
          {:create_container, [name, _spec]} -> String.contains?(name, "sidecar")
          _ -> false
        end)

      assert {:create_container, [_name, spec]} = sidecar_call

      env = Map.get(spec, "Env", [])
      assert Enum.any?(env, &String.starts_with?(&1, "CORTEX_GATEWAY_URL="))
      assert Enum.any?(env, &String.starts_with?(&1, "CORTEX_AGENT_NAME=backend"))
      assert Enum.any?(env, &String.starts_with?(&1, "CORTEX_AUTH_TOKEN="))
    end

    test "passes correct env vars to worker" do
      {_result, calls} = spawn_with_mock_registry()

      worker_call =
        Enum.find(calls, fn
          {:create_container, [name, _spec]} -> String.contains?(name, "worker")
          _ -> false
        end)

      assert {:create_container, [_name, spec]} = worker_call

      env = Map.get(spec, "Env", [])
      assert Enum.any?(env, &String.starts_with?(&1, "SIDECAR_URL="))
      assert Enum.any?(env, &String.starts_with?(&1, "ANTHROPIC_API_KEY="))
    end

    test "containers have correct labels" do
      {_result, calls} = spawn_with_mock_registry()

      container_calls = Enum.filter(calls, fn {op, _} -> op == :create_container end)

      for {:create_container, [_name, spec]} <- container_calls do
        labels = Map.get(spec, "Labels", %{})
        assert labels["cortex.managed"] == "true"
        assert labels["cortex.run-id"] == "run-123"
        assert labels["cortex.team"] == "backend"
        assert labels["cortex.role"] in ["sidecar", "worker"]
      end
    end

    test "container naming follows expected pattern" do
      {_result, calls} = spawn_with_mock_registry()

      container_calls = Enum.filter(calls, fn {op, _} -> op == :create_container end)
      names = Enum.map(container_calls, fn {_, [name, _]} -> name end)

      assert "cortex-run-123-backend-sidecar" in names
      assert "cortex-run-123-backend-worker" in names
    end

    test "returns error when Docker ping fails" do
      agent = %{name: "backend", id: "agent-1"}
      {:ok, registry} = MockRegistry.start_link(agents: [agent], name: nil)

      MockClient.setup(%{ping: {:error, :docker_unavailable}})
      opts = default_spawn_opts(registry)

      assert {:error, :docker_unavailable} = Docker.spawn(opts)
    end

    test "returns error when container creation fails" do
      agent = %{name: "backend", id: "agent-1"}
      {:ok, registry} = MockRegistry.start_link(agents: [agent], name: nil)

      MockClient.setup(%{
        {:create_container, "cortex-run-123-backend-sidecar"} => {:error, :image_not_found}
      })

      opts = default_spawn_opts(registry)

      assert {:error, :image_not_found} = Docker.spawn(opts)
    end

    test "returns error on registration timeout" do
      # Start registry with NO agents registered
      {:ok, registry} = MockRegistry.start_link(agents: [], name: nil)

      MockClient.setup(%{})
      opts = default_spawn_opts(registry) ++ [registration_timeout_ms: 300]

      assert {:error, :registration_timeout} = Docker.spawn(opts)
    end
  end

  describe "stop/1" do
    test "stops and removes both containers and network" do
      MockClient.setup(%{})

      handle = %Handle{
        sidecar_container_id: "sidecar-id",
        worker_container_id: "worker-id",
        team_name: "backend",
        run_id: "run-123",
        network_id: "net-id",
        docker_client: MockClient
      }

      assert :ok = Docker.stop(handle)

      calls = MockClient.calls()
      call_ops = Enum.map(calls, fn {op, _} -> op end)

      assert :stop_container in call_ops
      assert :remove_container in call_ops
      assert :remove_network in call_ops

      # Worker should be stopped before sidecar
      stop_calls = Enum.filter(calls, fn {op, _} -> op == :stop_container end)
      stop_ids = Enum.map(stop_calls, fn {_, [id]} -> id end)
      assert stop_ids == ["worker-id", "sidecar-id"]
    end

    test "is idempotent — does not error on already-removed containers" do
      MockClient.setup(%{
        {:stop_container, "worker-id"} => {:error, :container_not_found},
        {:stop_container, "sidecar-id"} => {:error, :container_not_found},
        {:remove_container, "worker-id"} => :ok,
        {:remove_container, "sidecar-id"} => :ok,
        {:remove_network, "net-id"} => :ok
      })

      handle = %Handle{
        sidecar_container_id: "sidecar-id",
        worker_container_id: "worker-id",
        team_name: "backend",
        run_id: "run-123",
        network_id: "net-id",
        docker_client: MockClient
      }

      assert :ok = Docker.stop(handle)
    end
  end

  describe "status/1" do
    test "returns :running for running container" do
      MockClient.setup(%{
        {:inspect_container, "worker-id"} => {:ok, %{"State" => %{"Status" => "running"}}}
      })

      handle = %Handle{
        sidecar_container_id: "sidecar-id",
        worker_container_id: "worker-id",
        team_name: "backend",
        run_id: "run-123",
        network_id: "net-id",
        docker_client: MockClient
      }

      assert :running = Docker.status(handle)
    end

    test "returns :done for exited container with code 0" do
      MockClient.setup(%{
        {:inspect_container, "worker-id"} =>
          {:ok, %{"State" => %{"Status" => "exited", "ExitCode" => 0}}}
      })

      handle = %Handle{
        sidecar_container_id: "sidecar-id",
        worker_container_id: "worker-id",
        team_name: "backend",
        run_id: "run-123",
        network_id: "net-id",
        docker_client: MockClient
      }

      assert :done = Docker.status(handle)
    end

    test "returns :failed for exited container with non-zero code" do
      MockClient.setup(%{
        {:inspect_container, "worker-id"} =>
          {:ok, %{"State" => %{"Status" => "exited", "ExitCode" => 1}}}
      })

      handle = %Handle{
        sidecar_container_id: "sidecar-id",
        worker_container_id: "worker-id",
        team_name: "backend",
        run_id: "run-123",
        network_id: "net-id",
        docker_client: MockClient
      }

      assert :failed = Docker.status(handle)
    end

    test "returns :done for container not found" do
      MockClient.setup(%{
        {:inspect_container, "worker-id"} => {:error, :container_not_found}
      })

      handle = %Handle{
        sidecar_container_id: "sidecar-id",
        worker_container_id: "worker-id",
        team_name: "backend",
        run_id: "run-123",
        network_id: "net-id",
        docker_client: MockClient
      }

      assert :done = Docker.status(handle)
    end

    test "returns :failed for dead container" do
      MockClient.setup(%{
        {:inspect_container, "worker-id"} => {:ok, %{"State" => %{"Status" => "dead"}}}
      })

      handle = %Handle{
        sidecar_container_id: "sidecar-id",
        worker_container_id: "worker-id",
        team_name: "backend",
        run_id: "run-123",
        network_id: "net-id",
        docker_client: MockClient
      }

      assert :failed = Docker.status(handle)
    end
  end

  describe "stream/1" do
    test "delegates to client container_logs" do
      test_stream = Stream.map(["line1\n", "line2\n"], & &1)

      MockClient.setup(%{
        {:container_logs, "worker-id"} => {:ok, test_stream}
      })

      handle = %Handle{
        sidecar_container_id: "sidecar-id",
        worker_container_id: "worker-id",
        team_name: "backend",
        run_id: "run-123",
        network_id: "net-id",
        docker_client: MockClient
      }

      assert {:ok, stream} = Docker.stream(handle)
      assert Enum.to_list(stream) == ["line1\n", "line2\n"]
    end
  end

  describe "telemetry" do
    test "emits spawn_start and spawn_complete events on success" do
      ref_start =
        :telemetry_test.attach_event_handlers(self(), [[:cortex, :docker, :spawn_start]])

      ref_complete =
        :telemetry_test.attach_event_handlers(self(), [[:cortex, :docker, :spawn_complete]])

      {{:ok, _handle}, _calls} = spawn_with_mock_registry()

      assert_receive {[:cortex, :docker, :spawn_start], ^ref_start, _measurements,
                      %{team_name: "backend", run_id: "run-123"}}

      assert_receive {[:cortex, :docker, :spawn_complete], ^ref_complete,
                      %{duration_ms: _duration}, %{team_name: "backend", run_id: "run-123"}}
    end

    test "emits spawn_failed event on failure" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:cortex, :docker, :spawn_failed]])

      agent = %{name: "backend", id: "agent-1"}
      {:ok, registry} = MockRegistry.start_link(agents: [agent], name: nil)
      MockClient.setup(%{ping: {:error, :docker_unavailable}})
      opts = default_spawn_opts(registry)

      assert {:error, :docker_unavailable} = Docker.spawn(opts)

      assert_receive {[:cortex, :docker, :spawn_failed], ^ref, %{duration_ms: _},
                      %{team_name: "backend", reason: :docker_unavailable}}
    end

    test "emits stop_complete event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:cortex, :docker, :stop_complete]])

      MockClient.setup(%{})

      handle = %Handle{
        sidecar_container_id: "sidecar-id",
        worker_container_id: "worker-id",
        team_name: "backend",
        run_id: "run-123",
        network_id: "net-id",
        docker_client: MockClient
      }

      Docker.stop(handle)

      assert_receive {[:cortex, :docker, :stop_complete], ^ref, %{duration_ms: _},
                      %{team_name: "backend", run_id: "run-123"}}
    end
  end
end
