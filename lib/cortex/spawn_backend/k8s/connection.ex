defmodule Cortex.SpawnBackend.K8s.Connection do
  @moduledoc """
  Handles Kubernetes API connection setup.

  Supports two connection modes:

    - **In-cluster** — when Cortex runs inside a K8s pod, uses the
      mounted service account token at the standard path
    - **Kubeconfig** — when Cortex runs outside the cluster, reads
      `~/.kube/config` or the path in `KUBECONFIG` env var

  The connection mode is auto-detected: if the service account path
  exists, in-cluster is used; otherwise kubeconfig is tried.

  ## Configuration

  Application config under `config :cortex, Cortex.SpawnBackend.K8s`:

    - `:kubeconfig` — explicit path to kubeconfig file (optional)
    - `:context` — kubeconfig context name (optional, uses current-context)

  Environment variables:

    - `KUBECONFIG` — path to kubeconfig file
    - `K8S_CONTEXT` — kubeconfig context to use
  """

  require Logger

  @service_account_path "/var/run/secrets/kubernetes.io/serviceaccount"

  @doc """
  Establishes a connection to the Kubernetes API.

  Auto-detects in-cluster vs kubeconfig mode. Returns `{:ok, conn}` or
  `{:error, reason}`.
  """
  @spec connect() :: {:ok, K8s.Conn.t()} | {:error, term()}
  def connect do
    connect([])
  end

  @doc """
  Establishes a connection with explicit options.

  ## Options

    - `:kubeconfig` — path to kubeconfig file
    - `:context` — kubeconfig context name
  """
  @spec connect(keyword()) :: {:ok, K8s.Conn.t()} | {:error, term()}
  def connect(opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :kubeconfig) ->
        from_kubeconfig(Keyword.fetch!(opts, :kubeconfig), Keyword.get(opts, :context))

      in_cluster?() ->
        from_service_account()

      true ->
        kubeconfig_path = resolve_kubeconfig_path()
        context = Keyword.get(opts, :context) || resolve_context()
        from_kubeconfig(kubeconfig_path, context)
    end
  end

  # -- Private -----------------------------------------------------------------

  @spec in_cluster?() :: boolean()
  defp in_cluster? do
    File.exists?(Path.join(@service_account_path, "token"))
  end

  @spec from_service_account() :: {:ok, K8s.Conn.t()} | {:error, term()}
  defp from_service_account do
    K8s.Conn.from_service_account(@service_account_path)
  rescue
    e -> {:error, {:k8s_connection_failed, Exception.message(e)}}
  end

  @spec from_kubeconfig(String.t(), String.t() | nil) :: {:ok, K8s.Conn.t()} | {:error, term()}
  defp from_kubeconfig(path, context) do
    opts = if context, do: [context: context], else: []

    case K8s.Conn.from_file(path, opts) do
      {:ok, _conn} = ok ->
        ok

      {:error, reason} ->
        {:error, {:k8s_connection_failed, reason}}
    end
  rescue
    e -> {:error, {:k8s_connection_failed, Exception.message(e)}}
  end

  @spec resolve_kubeconfig_path() :: String.t()
  defp resolve_kubeconfig_path do
    app_config = Application.get_env(:cortex, Cortex.SpawnBackend.K8s, [])

    Keyword.get(app_config, :kubeconfig) ||
      System.get_env("KUBECONFIG") ||
      Path.expand("~/.kube/config")
  end

  @spec resolve_context() :: String.t() | nil
  defp resolve_context do
    app_config = Application.get_env(:cortex, Cortex.SpawnBackend.K8s, [])
    Keyword.get(app_config, :context) || System.get_env("K8S_CONTEXT")
  end
end
