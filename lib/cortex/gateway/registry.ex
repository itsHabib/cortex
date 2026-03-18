defmodule Cortex.Gateway.Registry do
  @moduledoc """
  GenServer that maintains the authoritative registry of externally connected agents.

  Tracks all agents registered via the WebSocket gateway, their capabilities, health
  state, and channel pids. Provides capability-based discovery, automatic cleanup on
  channel disconnect (via `Process.monitor`), and status/heartbeat updates.

  This is separate from `Cortex.Agent.Registry`, which tracks locally-spawned GenServer
  agents. The two registries have fundamentally different data models — this one tracks
  rich metadata (capabilities, health, load) for external WebSocket-connected agents.

  ## State

      %{
        agents: %{agent_id => RegisteredAgent.t()},
        monitors: %{monitor_ref => agent_id}
      }

  """

  use GenServer

  alias Cortex.Gateway.RegisteredAgent

  require Logger

  # -- Public API --

  @doc "Starts the Gateway Registry GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a new external agent.

  Assigns a UUID, monitors the channel pid, stores the agent, and broadcasts
  an `:agent_registered` event. Returns the complete `RegisteredAgent` struct.

  ## Parameters

    - `agent_info` — map with keys: `"name"`, `"role"`, `"capabilities"`, and
      optionally `"metadata"`.
    - `channel_pid` — the Phoenix Channel process pid for this connection.

  """
  @spec register(GenServer.server(), map(), pid()) ::
          {:ok, RegisteredAgent.t()} | {:error, term()}
  def register(server \\ __MODULE__, agent_info, channel_pid) do
    GenServer.call(server, {:register, agent_info, channel_pid})
  end

  @doc """
  Unregisters an agent by ID.

  Demonitors the channel pid and broadcasts an `:agent_unregistered` event.
  Returns `:ok` on success or `{:error, :not_found}` if the agent does not exist.
  """
  @spec unregister(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def unregister(server \\ __MODULE__, agent_id) do
    GenServer.call(server, {:unregister, agent_id})
  end

  @doc """
  Looks up an agent by ID.

  Returns `{:ok, agent}` or `{:error, :not_found}`.
  """
  @spec get(GenServer.server(), String.t()) :: {:ok, RegisteredAgent.t()} | {:error, :not_found}
  def get(server \\ __MODULE__, agent_id) do
    GenServer.call(server, {:get, agent_id})
  end

  @doc """
  Returns all registered agents.
  """
  @spec list(GenServer.server()) :: [RegisteredAgent.t()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc """
  Returns agents that advertise the given capability.
  """
  @spec list_by_capability(GenServer.server(), String.t()) :: [RegisteredAgent.t()]
  def list_by_capability(server \\ __MODULE__, capability) do
    GenServer.call(server, {:list_by_capability, capability})
  end

  @doc """
  Updates an agent's status.

  Only accepts valid status atoms: `:idle`, `:working`, `:draining`, `:disconnected`.
  The status may be given as an atom or a string (strings are converted to atoms).
  An optional `detail` string is accepted but not stored (for forward compatibility).
  Broadcasts an `:agent_status_changed` event on success.
  """
  @spec update_status(String.t(), atom() | String.t(), String.t()) ::
          :ok | {:error, :not_found | :invalid_status}
  def update_status(agent_id, status, _detail \\ "") when is_binary(agent_id) do
    status_atom = normalize_status(status)
    GenServer.call(__MODULE__, {:update_status, agent_id, status_atom})
  end

  @doc """
  Updates an agent's status on a specific registry server.
  """
  @spec update_status_on(GenServer.server(), String.t(), atom() | String.t()) ::
          :ok | {:error, :not_found | :invalid_status}
  def update_status_on(server, agent_id, status) do
    status_atom = normalize_status(status)
    GenServer.call(server, {:update_status, agent_id, status_atom})
  end

  @doc """
  Updates an agent's last heartbeat timestamp and load info.
  """
  @spec update_heartbeat(String.t(), map()) :: :ok | {:error, :not_found}
  def update_heartbeat(agent_id, load \\ %{}) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:update_heartbeat, agent_id, load})
  end

  @doc """
  Updates an agent's last heartbeat on a specific registry server.
  """
  @spec update_heartbeat_on(GenServer.server(), String.t(), map()) :: :ok | {:error, :not_found}
  def update_heartbeat_on(server, agent_id, load \\ %{}) do
    GenServer.call(server, {:update_heartbeat, agent_id, load})
  end

  @doc """
  Returns the channel pid for the given agent, for routing messages.
  """
  @spec get_channel(GenServer.server(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_channel(server \\ __MODULE__, agent_id) do
    GenServer.call(server, {:get_channel, agent_id})
  end

  @doc """
  Routes a completed task result.

  This is a placeholder for Phase 3 orchestration integration. Currently a no-op
  that returns `:ok`. The channel calls this when it receives a `"task_result"` message.
  """
  @spec route_task_result(String.t(), map()) :: :ok
  def route_task_result(_task_id, _result) do
    Logger.debug("Gateway.Registry: route_task_result called (no-op in Phase 1)")
    :ok
  end

  @doc """
  Returns the number of currently registered agents.
  """
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server \\ __MODULE__) do
    GenServer.call(server, :count)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(_opts) do
    state = %{
      agents: %{},
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, agent_info, channel_pid}, _from, state) do
    with :ok <- validate_agent_info(agent_info),
         true <- is_pid(channel_pid) and Process.alive?(channel_pid) do
      id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      monitor_ref = Process.monitor(channel_pid)

      agent = %RegisteredAgent{
        id: id,
        name: Map.get(agent_info, "name"),
        role: Map.get(agent_info, "role"),
        capabilities: Map.get(agent_info, "capabilities"),
        status: :idle,
        channel_pid: channel_pid,
        monitor_ref: monitor_ref,
        metadata: Map.get(agent_info, "metadata", %{}),
        registered_at: now,
        last_heartbeat: now,
        load: %{active_tasks: 0, queue_depth: 0}
      }

      new_agents = Map.put(state.agents, id, agent)
      new_monitors = Map.put(state.monitors, monitor_ref, id)
      new_state = %{state | agents: new_agents, monitors: new_monitors}

      safe_broadcast(:agent_registered, %{
        agent_id: id,
        name: agent.name,
        role: agent.role,
        capabilities: agent.capabilities
      })

      {:reply, {:ok, agent}, new_state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      false ->
        {:reply, {:error, :invalid_channel_pid}, state}
    end
  end

  def handle_call({:unregister, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      agent ->
        Process.demonitor(agent.monitor_ref, [:flush])
        new_agents = Map.delete(state.agents, agent_id)
        new_monitors = Map.delete(state.monitors, agent.monitor_ref)
        new_state = %{state | agents: new_agents, monitors: new_monitors}

        safe_broadcast(:agent_unregistered, %{
          agent_id: agent_id,
          name: agent.name,
          reason: :explicit
        })

        {:reply, :ok, new_state}
    end
  end

  def handle_call({:get, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil -> {:reply, {:error, :not_found}, state}
      agent -> {:reply, {:ok, agent}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.agents), state}
  end

  def handle_call({:list_by_capability, capability}, _from, state) do
    matching =
      state.agents
      |> Map.values()
      |> Enum.filter(fn agent -> capability in agent.capabilities end)

    {:reply, matching, state}
  end

  def handle_call({:update_status, agent_id, status}, _from, state) do
    unless RegisteredAgent.valid_status?(status) do
      {:reply, {:error, :invalid_status}, state}
    else
      case Map.get(state.agents, agent_id) do
        nil ->
          {:reply, {:error, :not_found}, state}

        agent ->
          old_status = agent.status
          updated = %{agent | status: status}
          new_agents = Map.put(state.agents, agent_id, updated)
          new_state = %{state | agents: new_agents}

          safe_broadcast(:agent_status_changed, %{
            agent_id: agent_id,
            old_status: old_status,
            new_status: status
          })

          {:reply, :ok, new_state}
      end
    end
  end

  def handle_call({:update_heartbeat, agent_id, load}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      agent ->
        updated = %{agent | last_heartbeat: DateTime.utc_now(), load: load}
        new_agents = Map.put(state.agents, agent_id, updated)
        {:reply, :ok, %{state | agents: new_agents}}
    end
  end

  def handle_call({:get_channel, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil -> {:reply, {:error, :not_found}, state}
      agent -> {:reply, {:ok, agent.channel_pid}, state}
    end
  end

  def handle_call(:count, _from, state) do
    {:reply, map_size(state.agents), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      agent_id ->
        case Map.get(state.agents, agent_id) do
          nil ->
            new_monitors = Map.delete(state.monitors, ref)
            {:noreply, %{state | monitors: new_monitors}}

          agent ->
            new_agents = Map.delete(state.agents, agent_id)
            new_monitors = Map.delete(state.monitors, ref)
            new_state = %{state | agents: new_agents, monitors: new_monitors}

            safe_broadcast(:agent_unregistered, %{
              agent_id: agent_id,
              name: agent.name,
              reason: :channel_down
            })

            {:noreply, new_state}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp validate_agent_info(info) when is_map(info) do
    name = Map.get(info, "name")
    role = Map.get(info, "role")
    capabilities = Map.get(info, "capabilities")

    cond do
      not is_binary(name) or name == "" ->
        {:error, :invalid_name}

      not is_binary(role) or role == "" ->
        {:error, :invalid_role}

      not is_list(capabilities) ->
        {:error, :invalid_capabilities}

      not Enum.all?(capabilities, &is_binary/1) ->
        {:error, :invalid_capabilities}

      true ->
        :ok
    end
  end

  defp validate_agent_info(_), do: {:error, :invalid_agent_info}

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case status do
      "idle" -> :idle
      "working" -> :working
      "draining" -> :draining
      "disconnected" -> :disconnected
      _ -> status
    end
  end

  defp safe_broadcast(type, payload) do
    Cortex.Events.broadcast(type, payload)
  rescue
    _ -> :ok
  end
end
