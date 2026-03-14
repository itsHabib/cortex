defmodule Cortex.Gossip.Supervisor do
  @moduledoc """
  DynamicSupervisor for gossip-mode agent processes (KnowledgeStores).

  Each gossip agent gets a `KnowledgeStore` child process managed by this
  supervisor. Stores can be started and stopped dynamically as agents
  join and leave the gossip network.
  """

  use DynamicSupervisor

  alias Cortex.Gossip.KnowledgeStore

  @doc """
  Starts the gossip DynamicSupervisor.

  ## Options

    - `:name` — optional name for the supervisor (default: `Cortex.Gossip.Supervisor`)

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts a `KnowledgeStore` child process under this supervisor.

  ## Parameters

    - `supervisor` — the supervisor pid or name
    - `opts` — keyword options passed to `KnowledgeStore.start_link/1`
      - `:agent_id` (required)
      - `:name` (optional)

  ## Returns

    - `{:ok, pid}` on success
    - `{:error, reason}` on failure

  """
  @spec start_store(GenServer.server(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_store(supervisor \\ __MODULE__, opts) do
    child_spec = {KnowledgeStore, opts}
    DynamicSupervisor.start_child(supervisor, child_spec)
  end

  @doc """
  Stops a `KnowledgeStore` child process.

  ## Parameters

    - `supervisor` — the supervisor pid or name
    - `pid` — the pid of the KnowledgeStore to stop

  """
  @spec stop_store(GenServer.server(), pid()) :: :ok | {:error, :not_found}
  def stop_store(supervisor \\ __MODULE__, pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
