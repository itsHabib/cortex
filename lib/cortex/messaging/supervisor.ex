defmodule Cortex.Messaging.Supervisor do
  @moduledoc """
  DynamicSupervisor for Mailbox processes.

  Each agent's `Cortex.Messaging.Mailbox` GenServer is started as a
  child of this supervisor. Mailboxes are created on demand via
  `AgentIntegration.setup/1` and removed via `AgentIntegration.teardown/1`.

  Uses `:one_for_one` strategy — a crashed mailbox does not affect others.
  """

  use DynamicSupervisor

  @doc """
  Starts the Messaging DynamicSupervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
