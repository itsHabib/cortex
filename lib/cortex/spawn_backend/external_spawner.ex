defmodule Cortex.SpawnBackend.ExternalSpawner do
  @moduledoc """
  Spawns sidecar + agent-worker processes locally for `provider: external`.

  When a config specifies `provider: external` with `backend: local` (the
  default), Cortex needs to auto-spawn the Go sidecar and agent-worker
  binaries so users don't have to start them manually. This module handles:

  1. **Port allocation** — picks a free TCP port for the sidecar via `:gen_tcp`
  2. **Sidecar spawn** — forks the sidecar binary as an Erlang Port
  3. **Registration wait** — polls `Gateway.Registry` until the agent appears
  4. **Worker spawn** — forks the agent-worker binary as an Erlang Port
  5. **Cleanup** — kills both processes on demand

  ## Handle

  The opaque `t:handle/0` struct carries both Port references and metadata
  needed for lifecycle management. Pass it to `stop/1` for cleanup.

  ## Binary Discovery

  Binary paths are resolved in order:

  1. Env vars: `CORTEX_SIDECAR_BIN` / `CORTEX_WORKER_BIN`
  2. Application config: `config :cortex, Cortex.SpawnBackend.Local, sidecar_bin: ..., worker_bin: ...`
  3. Default: `sidecar/bin/cortex-sidecar` / `sidecar/bin/agent-worker` relative to CWD

  ## Gateway Token

  Read from `Application.get_env(:cortex, :gateway_token)` or
  `System.get_env("CORTEX_GATEWAY_TOKEN")`, falling back to `"dev-token"`.
  """

  alias Cortex.Gateway.Registry, as: GatewayRegistry

  require Logger

  @registration_poll_interval_ms 200
  @registration_timeout_ms 15_000

  defmodule Handle do
    @moduledoc false
    @enforce_keys [:sidecar_port, :worker_port, :team_name, :sidecar_port_number]
    defstruct [
      :sidecar_port,
      :worker_port,
      :team_name,
      :sidecar_port_number,
      :sidecar_os_pid,
      :worker_os_pid
    ]

    @type t :: %__MODULE__{
            sidecar_port: port(),
            worker_port: port(),
            team_name: String.t(),
            sidecar_port_number: non_neg_integer(),
            sidecar_os_pid: non_neg_integer() | nil,
            worker_os_pid: non_neg_integer() | nil
          }
  end

  @type handle :: Handle.t()

  # -- Public API --------------------------------------------------------------

  @doc """
  Spawns a sidecar + worker pair for the given team.

  1. Picks a free port
  2. Forks the sidecar with appropriate env vars
  3. Waits for the agent to appear in Gateway.Registry
  4. Forks the agent-worker pointing at the sidecar

  Returns `{:ok, handle}` or `{:error, reason}`.

  ## Options

    - `:team_name` — required, the agent name (matches `CORTEX_AGENT_NAME`)
    - `:registry` — Gateway.Registry server (default: `Gateway.Registry`)
    - `:gateway_port` — gRPC gateway port (default: 4001)
    - `:registration_timeout_ms` — how long to wait for registration (default: 15s)

  """
  @spec spawn(keyword()) :: {:ok, handle()} | {:error, term()}
  def spawn(opts) when is_list(opts) do
    team_name = Keyword.fetch!(opts, :team_name)
    registry = Keyword.get(opts, :registry, GatewayRegistry)
    gateway_port = Keyword.get(opts, :gateway_port, 4001)
    reg_timeout = Keyword.get(opts, :registration_timeout_ms, @registration_timeout_ms)

    with {:ok, sidecar_bin} <- resolve_sidecar_bin(),
         {:ok, worker_bin} <- resolve_worker_bin(),
         {:ok, free_port} <- pick_free_port(),
         {:ok, sidecar_port} <- spawn_sidecar(sidecar_bin, team_name, free_port, gateway_port),
         :ok <- wait_for_registration(team_name, registry, reg_timeout),
         {:ok, worker_port} <- spawn_worker(worker_bin, free_port) do
      sidecar_os_pid = port_os_pid(sidecar_port)
      worker_os_pid = port_os_pid(worker_port)

      handle = %Handle{
        sidecar_port: sidecar_port,
        worker_port: worker_port,
        team_name: team_name,
        sidecar_port_number: free_port,
        sidecar_os_pid: sidecar_os_pid,
        worker_os_pid: worker_os_pid
      }

      Logger.info(
        "ExternalSpawner: spawned sidecar (port=#{free_port}, pid=#{sidecar_os_pid}) " <>
          "and worker (pid=#{worker_os_pid}) for team #{team_name}"
      )

      {:ok, handle}
    else
      {:error, reason} = error ->
        Logger.warning(
          "ExternalSpawner: failed to spawn for team #{team_name}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Stops both the sidecar and worker processes.

  Idempotent — safe to call multiple times.
  """
  @spec stop(handle()) :: :ok
  def stop(%Handle{sidecar_port: sidecar_port, worker_port: worker_port, team_name: team_name}) do
    Logger.info("ExternalSpawner: stopping sidecar + worker for team #{team_name}")
    kill_port(worker_port)
    kill_port(sidecar_port)
    :ok
  end

  @doc """
  Checks whether the agent with `team_name` is already registered in
  the Gateway.Registry.

  Returns `true` if a sidecar for this name is already connected.
  """
  @spec already_registered?(String.t(), GenServer.server()) :: boolean()
  def already_registered?(team_name, registry \\ GatewayRegistry) do
    agents = GatewayRegistry.list(registry)
    Enum.any?(agents, fn agent -> agent.name == team_name end)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Picks a free TCP port by binding to port 0.
  """
  @spec pick_free_port() :: {:ok, non_neg_integer()} | {:error, term()}
  def pick_free_port do
    case :gen_tcp.listen(0, [:binary, reuseaddr: true]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :gen_tcp.close(socket)
        {:ok, port}

      {:error, reason} ->
        {:error, {:port_allocation_failed, reason}}
    end
  end

  # -- Binary Discovery --------------------------------------------------------

  @doc """
  Resolves the sidecar binary path.

  Checks (in order): `CORTEX_SIDECAR_BIN` env var, application config,
  default path. Returns error if the resolved path doesn't exist.
  """
  @spec resolve_sidecar_bin() :: {:ok, String.t()} | {:error, term()}
  def resolve_sidecar_bin do
    path =
      System.get_env("CORTEX_SIDECAR_BIN") ||
        get_config(:sidecar_bin) ||
        "sidecar/bin/cortex-sidecar"

    validate_binary_path(path, "sidecar")
  end

  @doc """
  Resolves the agent-worker binary path.

  Checks (in order): `CORTEX_WORKER_BIN` env var, application config,
  default path. Returns error if the resolved path doesn't exist.
  """
  @spec resolve_worker_bin() :: {:ok, String.t()} | {:error, term()}
  def resolve_worker_bin do
    path =
      System.get_env("CORTEX_WORKER_BIN") ||
        get_config(:worker_bin) ||
        "sidecar/bin/agent-worker"

    validate_binary_path(path, "worker")
  end

  # -- Private -----------------------------------------------------------------

  @spec spawn_sidecar(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, port()} | {:error, term()}
  defp spawn_sidecar(sidecar_bin, team_name, sidecar_port, gateway_port) do
    gateway_token = resolve_gateway_token()

    env = [
      {~c"CORTEX_GATEWAY_URL", ~c"localhost:#{gateway_port}"},
      {~c"CORTEX_AGENT_NAME", String.to_charlist(team_name)},
      {~c"CORTEX_AUTH_TOKEN", String.to_charlist(gateway_token)},
      {~c"CORTEX_SIDECAR_PORT", ~c"#{sidecar_port}"}
    ]

    try do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(sidecar_bin)},
          [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:env, env}]
        )

      {:ok, port}
    rescue
      e -> {:error, {:sidecar_spawn_failed, Exception.message(e)}}
    end
  end

  @spec spawn_worker(String.t(), non_neg_integer()) :: {:ok, port()} | {:error, term()}
  defp spawn_worker(worker_bin, sidecar_port) do
    env = [
      {~c"SIDECAR_URL", ~c"http://localhost:#{sidecar_port}"}
    ]

    try do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(worker_bin)},
          [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:env, env}]
        )

      {:ok, port}
    rescue
      e -> {:error, {:worker_spawn_failed, Exception.message(e)}}
    end
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
      if already_registered?(team_name, registry) do
        Logger.debug("ExternalSpawner: #{team_name} registered in Gateway.Registry")
        :ok
      else
        Process.sleep(@registration_poll_interval_ms)
        poll_registration(team_name, registry, deadline)
      end
    end
  end

  @spec resolve_gateway_token() :: String.t()
  defp resolve_gateway_token do
    Application.get_env(:cortex, :gateway_token) ||
      System.get_env("CORTEX_GATEWAY_TOKEN") ||
      "dev-token"
  end

  @spec get_config(atom()) :: String.t() | nil
  defp get_config(key) do
    case Application.get_env(:cortex, Cortex.SpawnBackend.Local) do
      nil -> nil
      config -> Keyword.get(config, key)
    end
  end

  @spec validate_binary_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp validate_binary_path(path, label) do
    abs_path =
      if Path.type(path) == :absolute do
        path
      else
        Path.join(File.cwd!(), path)
      end

    if File.exists?(abs_path) do
      {:ok, abs_path}
    else
      {:error, {:binary_not_found, label, abs_path}}
    end
  end

  @spec port_os_pid(port()) :: non_neg_integer() | nil
  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  @spec kill_port(port()) :: :ok
  defp kill_port(port) do
    try do
      # Try to get the OS pid and send SIGTERM for graceful shutdown
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end

      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end
end
