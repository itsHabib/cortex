defmodule Cortex.Agent.Server do
  @moduledoc """
  GenServer implementation for a single Cortex agent.

  Each agent runs as an isolated GenServer process with its own state,
  registered in the global `Cortex.Agent.Registry` by its UUID. All
  lifecycle events are broadcast via `Cortex.Events` on the
  `"cortex:events"` topic.

  ## Lifecycle Events

  The following events are broadcast during an agent's lifetime:

    - `:agent_started` — `%{agent_id: id, name: name, role: role}`
    - `:agent_status_changed` — `%{agent_id: id, old_status: old, new_status: new}`
    - `:agent_work_assigned` — `%{agent_id: id, work: work}`
    - `:agent_stopped` — `%{agent_id: id, reason: reason}`

  ## Client API

  All client functions accept an `agent_id` (UUID string) and look up the
  process via the Registry. If the process is not found, they return
  `{:error, :not_found}`.

  ## Examples

      config = Cortex.Agent.Config.new!(%{name: "worker", role: "builder"})
      {:ok, pid} = Cortex.Agent.Server.start_link(config)

      {:ok, state} = Cortex.Agent.Server.get_state(agent_id)
      state.status
      #=> :idle

  """

  use GenServer, restart: :temporary

  alias Cortex.Agent.Config
  alias Cortex.Agent.State
  alias Cortex.Events

  @registry Cortex.Agent.Registry

  # --- Client API ---

  @doc """
  Starts a new agent GenServer from a validated `Config`.

  The agent generates a UUID during init, registers in the
  `Cortex.Agent.Registry`, and broadcasts an `:agent_started` event.

  ## Parameters

    - `config` — a validated `%Cortex.Agent.Config{}` struct

  ## Returns

    - `{:ok, pid}` on success
    - `{:error, reason}` on failure

  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config)
  end

  @doc """
  Retrieves the current state of an agent by ID.

  ## Parameters

    - `agent_id` — the UUID string of the agent

  ## Returns

    - `{:ok, %State{}}` if the agent exists
    - `{:error, :not_found}` if no agent is registered with that ID

  """
  @spec get_state(String.t()) :: {:ok, State.t()} | {:error, :not_found}
  def get_state(agent_id) do
    call(agent_id, :get_state)
  end

  @doc """
  Updates the status of an agent.

  Broadcasts an `:agent_status_changed` event on success.

  ## Parameters

    - `agent_id` — the UUID string of the agent
    - `new_status` — one of `:idle`, `:running`, `:done`, `:failed`

  ## Returns

    - `:ok` on success
    - `{:error, :invalid_status}` if the status is not valid
    - `{:error, :not_found}` if the agent is not registered

  """
  @spec update_status(String.t(), State.status()) ::
          :ok | {:error, :invalid_status | :not_found}
  def update_status(agent_id, new_status) do
    call(agent_id, {:update_status, new_status})
  end

  @doc """
  Updates a single key in the agent's metadata map.

  ## Parameters

    - `agent_id` — the UUID string of the agent
    - `key` — the metadata key to set
    - `value` — the value to associate with the key

  ## Returns

    - `:ok` on success
    - `{:error, :not_found}` if the agent is not registered

  """
  @spec update_metadata(String.t(), term(), term()) :: :ok | {:error, :not_found}
  def update_metadata(agent_id, key, value) do
    call(agent_id, {:update_metadata, key, value})
  end

  @doc """
  Asynchronously assigns work to an agent.

  Transitions the agent to `:running` status, stores the work under
  `metadata[:work]`, and broadcasts an `:agent_work_assigned` event.

  ## Parameters

    - `agent_id` — the UUID string of the agent
    - `work` — any term describing the work to perform

  ## Returns

    - `:ok` always (fire-and-forget cast)

  """
  @spec assign_work(String.t(), term()) :: :ok
  def assign_work(agent_id, work) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _}] -> GenServer.cast(pid, {:assign_work, work})
      [] -> :ok
    end
  end

  @doc """
  Gracefully stops an agent process.

  Triggers `terminate/2`, which broadcasts an `:agent_stopped` event.

  ## Parameters

    - `agent_id` — the UUID string of the agent

  ## Returns

    - `:ok` on success
    - `{:error, :not_found}` if the agent is not registered

  """
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _ -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(%Config{} = config) do
    state = State.new(config)

    # Register this process in the Registry with the agent's UUID.
    # We register in init/1 rather than via start_link name: option
    # because the UUID is generated here inside State.new/1.
    case Registry.register(@registry, state.id, nil) do
      {:ok, _} ->
        Events.broadcast(:agent_started, %{
          agent_id: state.id,
          name: config.name,
          role: config.role
        })

        {:ok, state}

      {:error, {:already_registered, _pid}} ->
        {:stop, :already_registered}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:update_status, new_status}, _from, state) do
    case State.update_status(state, new_status) do
      {:ok, new_state} ->
        Events.broadcast(:agent_status_changed, %{
          agent_id: state.id,
          old_status: state.status,
          new_status: new_status
        })

        {:reply, :ok, new_state}

      {:error, :invalid_status} ->
        {:reply, {:error, :invalid_status}, state}
    end
  end

  @impl true
  def handle_call({:update_metadata, key, value}, _from, state) do
    new_state = State.update_metadata(state, key, value)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:assign_work, work}, state) do
    {:ok, new_state} = State.update_status(state, :running)
    new_state = State.update_metadata(new_state, :work, work)

    Events.broadcast(:agent_work_assigned, %{
      agent_id: state.id,
      work: work
    })

    {:noreply, new_state}
  end

  @impl true
  def terminate(reason, state) do
    Events.broadcast(:agent_stopped, %{
      agent_id: state.id,
      reason: reason
    })

    :ok
  end

  # --- Private Helpers ---

  defp call(agent_id, message) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, message)
        catch
          :exit, _ -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end
end
