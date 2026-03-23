defmodule Cortex.SpawnBackend.K8s do
  @moduledoc """
  Kubernetes spawn backend — creates Pods with sidecar + worker containers.

  Implements the `Cortex.SpawnBackend` behaviour for Kubernetes-based agent
  execution. When a YAML config specifies `backend: k8s`, the orchestration
  layer calls this module to create K8s Pods containing:

    - A **sidecar** container that connects to the Cortex Gateway via gRPC
      and registers the agent
    - A **worker** container that polls the sidecar for tasks and executes them

  Both containers share localhost networking within the Pod.

  ## Lifecycle

      {:ok, handle} = SpawnBackend.K8s.spawn(team_name: "researcher", run_id: "abc")
      :running = SpawnBackend.K8s.status(handle)
      {:ok, stream} = SpawnBackend.K8s.stream(handle)
      :ok = SpawnBackend.K8s.stop(handle)

  ## Configuration

  Application config under `config :cortex, Cortex.SpawnBackend.K8s`:

    - `:namespace` — K8s namespace (default: `"cortex"`)
    - `:sidecar_image` — sidecar container image
    - `:worker_image` — worker container image
    - `:gateway_url` — gRPC gateway address for sidecars
    - `:kubeconfig` — path to kubeconfig file
    - `:context` — kubeconfig context name

  ## Handle

  The opaque handle carries the pod name, namespace, and K8s connection
  needed for lifecycle management. Callers should not inspect handle internals.
  """

  @behaviour Cortex.SpawnBackend

  alias Cortex.SpawnBackend.K8s.{Connection, PodSpec}
  alias Cortex.Gateway.Registry, as: GatewayRegistry

  require Logger

  @pod_start_poll_interval_ms 500
  @pod_start_timeout_ms 120_000
  @registration_poll_interval_ms 200
  @default_registration_timeout_ms 60_000

  defmodule Handle do
    @moduledoc false
    @enforce_keys [:pod_name, :namespace, :team_name]
    defstruct [
      :pod_name,
      :namespace,
      :team_name,
      :run_id,
      :conn,
      :created_at
    ]

    @type t :: %__MODULE__{
            pod_name: String.t(),
            namespace: String.t(),
            team_name: String.t(),
            run_id: String.t() | nil,
            conn: K8s.Conn.t() | nil,
            created_at: integer() | nil
          }
  end

  @type handle :: Handle.t()

  # -- SpawnBackend Behaviour Callbacks ----------------------------------------

  @doc """
  Creates a Kubernetes Pod with sidecar + worker containers.

  Builds a Pod manifest, creates it via the K8s API, waits for the Pod
  to reach Running phase, then waits for the sidecar to register with
  the Gateway. On any failure, the Pod is cleaned up before returning
  the error.

  ## Options

    - `:team_name` — agent name (required)
    - `:run_id` — unique run identifier (required)
    - `:namespace` — K8s namespace (default from config)
    - `:gateway_url` — gRPC gateway address
    - `:sidecar_image` — sidecar container image
    - `:worker_image` — worker container image
    - `:timeout_ms` — max pod lifetime in ms (default: 3,600,000)
    - `:resources` — resource requests/limits override
    - `:service_account` — K8s service account name
    - `:auth_token` — gateway auth token
    - `:image_pull_secrets` — list of image pull secret names
    - `:registration_timeout_ms` — how long to wait for sidecar registration
    - `:k8s_conn` — pre-established K8s connection (for testing)
    - `:registry` — Gateway.Registry server (for testing)
  """
  @impl Cortex.SpawnBackend
  @spec spawn(keyword()) :: {:ok, handle()} | {:error, term()}
  def spawn(opts) when is_list(opts) do
    team_name = Keyword.fetch!(opts, :team_name)
    run_id = Keyword.fetch!(opts, :run_id)
    reg_timeout = Keyword.get(opts, :registration_timeout_ms, @default_registration_timeout_ms)
    registry = Keyword.get(opts, :registry, GatewayRegistry)
    created_at = System.monotonic_time(:millisecond)

    with {:ok, conn} <- get_connection(opts),
         pod_spec <- PodSpec.build(opts),
         pod_name <- get_in(pod_spec, ["metadata", "name"]),
         namespace <- get_in(pod_spec, ["metadata", "namespace"]),
         :ok <- create_pod(conn, pod_spec),
         :ok <- emit_pod_created(pod_name, namespace, team_name, run_id),
         :ok <- wait_for_running(conn, pod_name, namespace),
         :ok <- emit_pod_ready(pod_name, namespace, team_name, created_at),
         :ok <- wait_for_registration(team_name, registry, reg_timeout) do
      handle = %Handle{
        pod_name: pod_name,
        namespace: namespace,
        team_name: team_name,
        run_id: run_id,
        conn: conn,
        created_at: created_at
      }

      Logger.info(
        "SpawnBackend.K8s: pod #{pod_name} running in #{namespace} for team #{team_name}"
      )

      {:ok, handle}
    else
      {:error, reason} = error ->
        Logger.warning(
          "SpawnBackend.K8s: failed to spawn pod for team #{team_name}: #{inspect(reason)}"
        )

        # Attempt cleanup on partial failure
        cleanup_on_failure(opts, run_id, team_name)
        error
    end
  end

  @doc """
  Returns a lazy stream of Pod lifecycle status events.

  Unlike the Local backend, K8s pods don't pipe stdout directly. The
  stream monitors pod phase transitions and registration status.

  Events emitted:

    - `{:pod_phase, phase}` — Pod phase changes ("Pending", "Running", etc.)
    - `{:registered, team_name}` — agent registered in Gateway
    - `{:done}` — Pod completed
  """
  @impl Cortex.SpawnBackend
  @spec stream(handle()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(%Handle{} = handle) do
    stream =
      Stream.resource(
        fn -> {:polling, handle} end,
        fn
          {:done, _handle} ->
            {:halt, :done}

          {:polling, %Handle{conn: conn, pod_name: pod_name, namespace: namespace} = h} ->
            case get_pod_phase(conn, pod_name, namespace) do
              {:ok, "Succeeded"} ->
                {[{:pod_phase, "Succeeded"}, {:done}], {:done, h}}

              {:ok, "Failed"} ->
                {[{:pod_phase, "Failed"}, {:done}], {:done, h}}

              {:ok, phase} ->
                Process.sleep(@pod_start_poll_interval_ms)
                {[{:pod_phase, phase}], {:polling, h}}

              {:error, :not_found} ->
                {[{:done}], {:done, h}}

              {:error, _reason} ->
                Process.sleep(@pod_start_poll_interval_ms)
                {[], {:polling, h}}
            end
        end,
        fn _ -> :ok end
      )

    {:ok, stream}
  end

  @doc """
  Deletes the Pod from the K8s cluster.

  Idempotent — calling on an already-deleted Pod returns `:ok`.
  """
  @impl Cortex.SpawnBackend
  @spec stop(handle()) :: :ok
  def stop(%Handle{conn: conn, pod_name: pod_name, namespace: namespace, team_name: team_name}) do
    Logger.info("SpawnBackend.K8s: deleting pod #{pod_name} in #{namespace}")

    op = K8s.Client.delete("v1", "Pod", namespace: namespace, name: pod_name)

    case K8s.Client.run(conn, op) do
      {:ok, _} ->
        emit_pod_deleted(pod_name, namespace, team_name)
        :ok

      {:error, %K8s.Client.APIError{reason: "NotFound"}} ->
        :ok

      {:error, reason} ->
        Logger.warning("SpawnBackend.K8s: failed to delete pod #{pod_name}: #{inspect(reason)}")

        # Still return :ok for idempotency — the pod may already be gone
        :ok
    end
  end

  @doc """
  Polls the K8s API for Pod phase and maps to status.

  Phase mapping:

    - `"Pending"` -> `:running` (still starting)
    - `"Running"` -> `:running`
    - `"Succeeded"` -> `:done`
    - `"Failed"` -> `:failed`
    - `"Unknown"` -> `:failed`
    - not found -> `:done` (already cleaned up)
  """
  @impl Cortex.SpawnBackend
  @spec status(handle()) :: :running | :done | :failed
  def status(%Handle{conn: conn, pod_name: pod_name, namespace: namespace}) do
    case get_pod_phase(conn, pod_name, namespace) do
      {:ok, "Pending"} -> :running
      {:ok, "Running"} -> :running
      {:ok, "Succeeded"} -> :done
      {:ok, "Failed"} -> :failed
      {:ok, "Unknown"} -> :failed
      {:ok, _other} -> :failed
      {:error, :not_found} -> :done
      {:error, _} -> :failed
    end
  end

  # -- Helper Functions (not part of behaviour) --------------------------------

  @doc """
  Deletes all pods with the given run-id label in the namespace.

  Used for batch cleanup when a run finishes.
  """
  @spec cleanup_run_pods(K8s.Conn.t(), String.t(), String.t()) :: :ok
  def cleanup_run_pods(conn, run_id, namespace) do
    op =
      K8s.Client.list("v1", "Pod", namespace: namespace)
      |> K8s.Selector.label({"cortex.dev/run-id", run_id})

    case K8s.Client.run(conn, op) do
      {:ok, %{"items" => items}} ->
        Enum.each(items, fn pod ->
          pod_name = get_in(pod, ["metadata", "name"])
          delete_op = K8s.Client.delete("v1", "Pod", namespace: namespace, name: pod_name)
          K8s.Client.run(conn, delete_op)
        end)

        :ok

      {:error, reason} ->
        Logger.warning(
          "SpawnBackend.K8s: failed to list pods for cleanup (run=#{run_id}): #{inspect(reason)}"
        )

        :ok
    end
  end

  # -- Private -----------------------------------------------------------------

  @spec get_connection(keyword()) :: {:ok, K8s.Conn.t()} | {:error, term()}
  defp get_connection(opts) do
    case Keyword.get(opts, :k8s_conn) do
      nil -> Connection.connect(opts)
      conn -> {:ok, conn}
    end
  end

  @spec create_pod(K8s.Conn.t(), map()) :: :ok | {:error, term()}
  defp create_pod(conn, pod_spec) do
    op = K8s.Client.create(pod_spec)

    case K8s.Client.run(conn, op) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:pod_create_failed, reason}}
    end
  end

  @spec get_pod_phase(K8s.Conn.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp get_pod_phase(conn, pod_name, namespace) do
    op = K8s.Client.get("v1", "Pod", namespace: namespace, name: pod_name)

    case K8s.Client.run(conn, op) do
      {:ok, %{"status" => %{"phase" => phase}}} ->
        {:ok, phase}

      {:ok, _} ->
        {:ok, "Pending"}

      {:error, %K8s.Client.APIError{reason: "NotFound"}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec wait_for_running(K8s.Conn.t(), String.t(), String.t()) ::
          :ok | {:error, :pod_start_timeout}
  defp wait_for_running(conn, pod_name, namespace) do
    deadline = System.monotonic_time(:millisecond) + @pod_start_timeout_ms
    poll_pod_status(conn, pod_name, namespace, deadline)
  end

  @spec poll_pod_status(K8s.Conn.t(), String.t(), String.t(), integer()) ::
          :ok | {:error, :pod_start_timeout | :pod_failed}
  defp poll_pod_status(conn, pod_name, namespace, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :pod_start_timeout}
    else
      case get_pod_phase(conn, pod_name, namespace) do
        {:ok, "Running"} ->
          :ok

        {:ok, "Succeeded"} ->
          :ok

        {:ok, "Failed"} ->
          {:error, :pod_failed}

        {:ok, _pending_or_other} ->
          Process.sleep(@pod_start_poll_interval_ms)
          poll_pod_status(conn, pod_name, namespace, deadline)

        {:error, :not_found} ->
          Process.sleep(@pod_start_poll_interval_ms)
          poll_pod_status(conn, pod_name, namespace, deadline)

        {:error, _} ->
          Process.sleep(@pod_start_poll_interval_ms)
          poll_pod_status(conn, pod_name, namespace, deadline)
      end
    end
  end

  @spec wait_for_registration(String.t(), GenServer.server(), non_neg_integer()) ::
          :ok | {:error, :registration_timeout}
  defp wait_for_registration(team_name, registry, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_registration(team_name, registry, deadline)
  end

  @spec poll_registration(String.t(), GenServer.server(), integer()) ::
          :ok | {:error, :registration_timeout}
  defp poll_registration(team_name, registry, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :registration_timeout}
    else
      if agent_registered?(team_name, registry) do
        Logger.debug("SpawnBackend.K8s: #{team_name} registered in Gateway.Registry")
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

  @spec cleanup_on_failure(keyword(), String.t(), String.t()) :: :ok
  defp cleanup_on_failure(opts, run_id, team_name) do
    case get_connection(opts) do
      {:ok, conn} ->
        namespace =
          Keyword.get(
            opts,
            :namespace,
            Application.get_env(:cortex, Cortex.SpawnBackend.K8s, [])
            |> Keyword.get(:namespace, "cortex")
          )

        pod_name = PodSpec.pod_name(run_id, team_name)
        delete_op = K8s.Client.delete("v1", "Pod", namespace: namespace, name: pod_name)
        K8s.Client.run(conn, delete_op)
        :ok

      {:error, _} ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # -- Telemetry ---------------------------------------------------------------

  @spec emit_pod_created(String.t(), String.t(), String.t(), String.t()) :: :ok
  defp emit_pod_created(pod_name, namespace, team_name, run_id) do
    :telemetry.execute(
      [:cortex, :k8s, :pod, :created],
      %{system_time: System.system_time()},
      %{pod_name: pod_name, namespace: namespace, team_name: team_name, run_id: run_id}
    )
  end

  @spec emit_pod_ready(String.t(), String.t(), String.t(), integer()) :: :ok
  defp emit_pod_ready(pod_name, namespace, team_name, created_at) do
    duration_ms = System.monotonic_time(:millisecond) - created_at

    :telemetry.execute(
      [:cortex, :k8s, :pod, :ready],
      %{duration_ms: duration_ms},
      %{pod_name: pod_name, namespace: namespace, team_name: team_name}
    )
  end

  @spec emit_pod_deleted(String.t(), String.t(), String.t()) :: :ok
  defp emit_pod_deleted(pod_name, namespace, team_name) do
    :telemetry.execute(
      [:cortex, :k8s, :pod, :deleted],
      %{system_time: System.system_time()},
      %{pod_name: pod_name, namespace: namespace, team_name: team_name}
    )
  end
end
