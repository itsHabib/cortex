defmodule Cortex.Gateway.Supervisor do
  @moduledoc """
  Supervisor for gateway processes.

  Starts and supervises `Gateway.Registry` and `Gateway.Health` as children
  under a `:one_for_one` strategy. This supervisor is itself a child of
  `Cortex.Supervisor`, placed after PubSub and before the web layer.

  ## Children

    * `Cortex.Gateway.Registry` — tracks connected agents, capabilities, health
    * `Cortex.Gateway.Health` — periodic heartbeat timeout enforcement
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
    children = [
      {Cortex.Gateway.Registry, []},
      {Cortex.Gateway.Health, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
