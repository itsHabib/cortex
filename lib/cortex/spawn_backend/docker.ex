defmodule Cortex.SpawnBackend.Docker do
  @moduledoc """
  Docker spawn backend — creates sidecar + worker containers via Docker Engine API.

  Implements the `Cortex.SpawnBackend` behaviour by talking to the Docker Engine
  API over the Unix socket. When YAML config specifies `backend: docker`, this
  module handles the full container lifecycle:

  1. Create a per-run bridge network
  2. Create and start the sidecar container
  3. Wait for sidecar to register in Gateway.Registry
  4. Create and start the worker container
  5. Return a handle for stream/stop/status

  Cleanup: `stop/1` removes worker, sidecar, and network. All containers are
  labeled with `cortex.managed=true` for orphan reaping.

  ## Options

    - `:team_name` — required, agent name
    - `:run_id` — required, run identifier
    - `:image` — container image (default: `"cortex-agent-worker:latest"`)
    - `:gateway_url` — gateway address for sidecar (default: `"host.docker.internal:4001"`)
    - `:gateway_token` — auth token (default: resolved from app config)
    - `:timeout_ms` — container-level timeout (default: `3_600_000`)
    - `:docker_client` — HTTP client module (default: `Docker.Client`)
    - `:socket_path` — Docker socket path (default: `"/var/run/docker.sock"`)
    - `:registration_timeout_ms` — sidecar registration timeout (default: `30_000`)
    - `:registry` — Gateway.Registry server (default: `Cortex.Gateway.Registry`)

  """

  @behaviour Cortex.SpawnBackend

  alias Cortex.SpawnBackend.Docker.{Client, Handle}
  alias Cortex.Gateway.Registry, as: GatewayRegistry

  require Logger

  @default_image "cortex-agent-worker:latest"
  @default_gateway_url "host.docker.internal:4001"
  @registration_poll_interval_ms 200
  @default_registration_timeout_ms 30_000

  # -- SpawnBackend Callbacks --

  @doc """
  Creates a per-run Docker network, starts sidecar and worker containers.

  Returns `{:ok, handle}` on success, or `{:error, reason}` if any step fails.
  On partial failure, already-created resources are cleaned up.
  """
  @impl Cortex.SpawnBackend
  @spec spawn(keyword()) :: {:ok, Handle.t()} | {:error, term()}
  def spawn(opts) when is_list(opts) do
    team_name = Keyword.fetch!(opts, :team_name)
    run_id = Keyword.fetch!(opts, :run_id)
    client = Keyword.get(opts, :docker_client, Client)
    client_opts = client_opts(opts)

    start_time = System.monotonic_time(:millisecond)

    emit_telemetry(:spawn_start, %{}, %{team_name: team_name, run_id: run_id})

    case do_spawn(team_name, run_id, client, client_opts, opts) do
      {:ok, handle} ->
        duration = System.monotonic_time(:millisecond) - start_time

        emit_telemetry(:spawn_complete, %{duration_ms: duration}, %{
          team_name: team_name,
          run_id: run_id
        })

        Logger.info(
          "SpawnBackend.Docker: spawned containers for #{team_name} (run=#{run_id}) in #{duration}ms"
        )

        {:ok, handle}

      {:error, reason} = error ->
        duration = System.monotonic_time(:millisecond) - start_time

        emit_telemetry(:spawn_failed, %{duration_ms: duration}, %{
          team_name: team_name,
          run_id: run_id,
          reason: reason
        })

        Logger.warning(
          "SpawnBackend.Docker: spawn failed for #{team_name} (run=#{run_id}): #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Returns a lazy stream of binary chunks from the worker container's logs.
  """
  @impl Cortex.SpawnBackend
  @spec stream(Handle.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(%Handle{worker_container_id: worker_id, docker_client: client} = handle) do
    client_opts = handle_client_opts(handle)
    client.container_logs(worker_id, client_opts)
  end

  @doc """
  Stops and removes both containers and the network. Idempotent.

  Stops worker first (graceful), then sidecar, then removes both, then
  removes the network. All operations are best-effort — partial failures
  are logged but do not prevent subsequent cleanup steps.
  """
  @impl Cortex.SpawnBackend
  @spec stop(Handle.t()) :: :ok
  def stop(%Handle{} = handle) do
    %Handle{
      worker_container_id: worker_id,
      sidecar_container_id: sidecar_id,
      network_id: network_id,
      team_name: team_name,
      run_id: run_id,
      docker_client: client
    } = handle

    start_time = System.monotonic_time(:millisecond)
    client_opts = handle_client_opts(handle)

    Logger.info("SpawnBackend.Docker: stopping containers for #{team_name} (run=#{run_id})")

    # Stop worker first, then sidecar
    safe_stop_remove(client, worker_id, client_opts)
    safe_stop_remove(client, sidecar_id, client_opts)

    # Remove network
    case client.remove_network(network_id, client_opts) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("Docker: network remove: #{inspect(reason)}")
    end

    duration = System.monotonic_time(:millisecond) - start_time

    emit_telemetry(:stop_complete, %{duration_ms: duration}, %{
      team_name: team_name,
      run_id: run_id
    })

    :ok
  end

  @doc """
  Returns the current status of the worker container.

  Maps Docker container state to:
    - `:running` — container is running
    - `:done` — container exited with code 0
    - `:failed` — container exited with non-zero code or is in an error state
  """
  @impl Cortex.SpawnBackend
  @spec status(Handle.t()) :: :running | :done | :failed
  def status(%Handle{worker_container_id: worker_id, docker_client: client} = handle) do
    client_opts = handle_client_opts(handle)

    case client.inspect_container(worker_id, client_opts) do
      {:ok, info} ->
        map_container_status(info)

      {:error, :container_not_found} ->
        :done

      {:error, _reason} ->
        :failed
    end
  end

  # -- Private Implementation --

  @spec do_spawn(String.t(), String.t(), module(), keyword(), keyword()) ::
          {:ok, Handle.t()} | {:error, term()}
  defp do_spawn(team_name, run_id, client, client_opts, opts) do
    # Step 0: Verify Docker is available
    with :ok <- client.ping(client_opts),
         # Step 1: Create per-run bridge network
         network_name = network_name(run_id, team_name),
         {:ok, network_id} <- client.create_network(network_name, client_opts),
         # Step 2: Create and start sidecar container
         sidecar_spec = build_sidecar_spec(team_name, run_id, network_name, opts),
         {:ok, sidecar_id} <- create_and_start(client, sidecar_spec, client_opts),
         # Step 3: Wait for sidecar registration
         registry = Keyword.get(opts, :registry, GatewayRegistry),
         reg_timeout =
           Keyword.get(opts, :registration_timeout_ms, @default_registration_timeout_ms),
         :ok <- wait_for_registration(team_name, registry, reg_timeout),
         # Step 4: Create and start worker container
         worker_spec = build_worker_spec(team_name, run_id, network_name, opts),
         {:ok, worker_id} <- create_and_start(client, worker_spec, client_opts) do
      handle = %Handle{
        sidecar_container_id: sidecar_id,
        worker_container_id: worker_id,
        team_name: team_name,
        run_id: run_id,
        network_id: network_id,
        docker_client: client
      }

      {:ok, handle}
    else
      {:error, reason} = error ->
        # Cleanup partial resources on failure
        Logger.debug("SpawnBackend.Docker: cleaning up after spawn failure: #{inspect(reason)}")
        cleanup_partial(client, run_id, team_name, client_opts)
        error
    end
  end

  @spec create_and_start(module(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defp create_and_start(client, spec, client_opts) do
    with {:ok, container_id} <- client.create_container(spec, client_opts),
         :ok <- client.start_container(container_id, client_opts) do
      {:ok, container_id}
    end
  end

  @spec build_sidecar_spec(String.t(), String.t(), String.t(), keyword()) :: map()
  defp build_sidecar_spec(team_name, run_id, network_name, opts) do
    image = Keyword.get(opts, :image, @default_image)
    gateway_url = Keyword.get(opts, :gateway_url, @default_gateway_url)
    gateway_token = Keyword.get(opts, :gateway_token, resolve_gateway_token())

    container_name = container_name(run_id, team_name, "sidecar")

    %{
      "name" => container_name,
      "Image" => image,
      "Env" => [
        "CORTEX_GATEWAY_URL=#{gateway_url}",
        "CORTEX_AGENT_NAME=#{team_name}",
        "CORTEX_AUTH_TOKEN=#{gateway_token}",
        "CORTEX_SIDECAR_PORT=9091"
      ],
      "Cmd" => ["/cortex-sidecar"],
      "Labels" => container_labels(run_id, team_name, "sidecar"),
      "HostConfig" => %{
        "NetworkMode" => network_name
      }
    }
  end

  @spec build_worker_spec(String.t(), String.t(), String.t(), keyword()) :: map()
  defp build_worker_spec(team_name, run_id, network_name, opts) do
    image = Keyword.get(opts, :image, @default_image)
    sidecar_name = container_name(run_id, team_name, "sidecar")
    api_key = System.get_env("ANTHROPIC_API_KEY") || ""

    container_name = container_name(run_id, team_name, "worker")

    %{
      "name" => container_name,
      "Image" => image,
      "Env" => [
        "SIDECAR_URL=http://#{sidecar_name}:9091",
        "ANTHROPIC_API_KEY=#{api_key}"
      ],
      "Cmd" => ["/agent-worker"],
      "Labels" => container_labels(run_id, team_name, "worker"),
      "HostConfig" => %{
        "NetworkMode" => network_name
      }
    }
  end

  @spec container_labels(String.t(), String.t(), String.t()) :: map()
  defp container_labels(run_id, team_name, role) do
    %{
      "cortex.run-id" => run_id,
      "cortex.team" => team_name,
      "cortex.role" => role,
      "cortex.managed" => "true"
    }
  end

  @spec container_name(String.t(), String.t(), String.t()) :: String.t()
  defp container_name(run_id, team_name, role) do
    "cortex-#{sanitize(run_id)}-#{sanitize(team_name)}-#{role}"
  end

  @spec network_name(String.t(), String.t()) :: String.t()
  defp network_name(run_id, team_name) do
    "cortex-#{sanitize(run_id)}-#{sanitize(team_name)}"
  end

  @spec sanitize(String.t()) :: String.t()
  defp sanitize(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.trim_leading("-")
    |> String.trim_trailing("-")
    |> String.slice(0, 30)
  end

  @spec safe_stop_remove(module(), String.t(), keyword()) :: :ok
  defp safe_stop_remove(client, container_id, client_opts) do
    case client.stop_container(container_id, client_opts) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("Docker: stop container: #{inspect(reason)}")
    end

    case client.remove_container(container_id, client_opts) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("Docker: remove container: #{inspect(reason)}")
    end

    :ok
  end

  @spec cleanup_partial(module(), String.t(), String.t(), keyword()) :: :ok
  defp cleanup_partial(client, run_id, team_name, client_opts) do
    # Best-effort cleanup of any containers and network created during a failed spawn
    for role <- ["worker", "sidecar"] do
      name = container_name(run_id, team_name, role)
      client.stop_container(name, client_opts)
      client.remove_container(name, client_opts)
    end

    net_name = network_name(run_id, team_name)
    client.remove_network(net_name, client_opts)

    :ok
  rescue
    _ -> :ok
  end

  @spec wait_for_registration(String.t(), GenServer.server(), non_neg_integer()) ::
          :ok | {:error, :registration_timeout}
  defp wait_for_registration(team_name, registry, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_registration(team_name, registry, deadline)
  end

  defp poll_registration(team_name, registry, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :registration_timeout}
    else
      if agent_registered?(team_name, registry) do
        Logger.debug("SpawnBackend.Docker: #{team_name} registered in Gateway.Registry")
        :ok
      else
        Process.sleep(@registration_poll_interval_ms)
        poll_registration(team_name, registry, deadline)
      end
    end
  end

  @spec agent_registered?(String.t(), GenServer.server()) :: boolean()
  defp agent_registered?(team_name, registry) do
    agents = GatewayRegistry.list(registry)
    Enum.any?(agents, fn agent -> agent.name == team_name end)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @spec resolve_gateway_token() :: String.t()
  defp resolve_gateway_token do
    Application.get_env(:cortex, :gateway_token) ||
      System.get_env("CORTEX_GATEWAY_TOKEN") ||
      "dev-token"
  end

  @spec map_container_status(map()) :: :running | :done | :failed
  defp map_container_status(%{"State" => %{"Status" => "running"}}), do: :running
  defp map_container_status(%{"State" => %{"Status" => "created"}}), do: :running

  defp map_container_status(%{"State" => %{"Status" => "exited", "ExitCode" => 0}}), do: :done

  defp map_container_status(%{"State" => %{"Status" => "exited"}}), do: :failed
  defp map_container_status(%{"State" => %{"Status" => "dead"}}), do: :failed
  defp map_container_status(%{"State" => %{"Status" => "removing"}}), do: :done
  defp map_container_status(_), do: :failed

  @spec client_opts(keyword()) :: keyword()
  defp client_opts(opts) do
    Keyword.take(opts, [:socket_path, :timeout])
  end

  @spec handle_client_opts(Handle.t()) :: keyword()
  defp handle_client_opts(%Handle{}) do
    # Handle doesn't carry socket_path; use defaults
    []
  end

  @spec emit_telemetry(atom(), map(), map()) :: :ok
  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(
      [:cortex, :docker, event],
      Map.put(measurements, :system_time, System.system_time()),
      metadata
    )
  end
end
