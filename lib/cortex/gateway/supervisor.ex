defmodule Cortex.Gateway.Supervisor do
  @moduledoc """
  Supervisor for gateway processes.

  Starts and supervises `Gateway.Registry`, `Gateway.Health`, and optionally
  the gRPC data-plane endpoint as children under a `:one_for_one` strategy.
  This supervisor is itself a child of `Cortex.Supervisor`, placed after
  PubSub and before the web layer.

  ## Children

    * `Cortex.Gateway.Registry` — tracks connected agents, capabilities, health
    * `Cortex.Gateway.Health` — periodic heartbeat timeout enforcement
    * `GRPC.Server.Supervisor` — gRPC server on port 4001 (when enabled)
  """

  use Supervisor

  @doc """
  Starts the Gateway supervisor.

  ## Options

    * `:name` — the name to register the supervisor under (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    grpc_config = Application.get_env(:cortex, Cortex.Gateway.GrpcEndpoint, [])
    grpc_port = Keyword.get(grpc_config, :port, 4001)
    start_grpc = Keyword.get(grpc_config, :start_server, true)

    children =
      [
        {Cortex.Gateway.Registry, []},
        {Cortex.Gateway.Health, []}
      ] ++ grpc_children(start_grpc, grpc_port)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp grpc_children(true, port) do
    [
      {GRPC.Server.Supervisor,
       endpoint: Cortex.Gateway.GrpcEndpoint, port: port, start_server: true}
    ]
  end

  defp grpc_children(false, _port), do: []
end
