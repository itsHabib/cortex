defmodule Cortex.Agent.ExternalAgent do
  @moduledoc """
  GenServer that bridges the Cortex control plane to a sidecar-connected agent.

  One `ExternalAgent` process per external agent. It owns the Elixir-side
  relationship with its assigned sidecar: confirms the sidecar is registered in
  `Gateway.Registry` at startup, delegates work via `Provider.External`, and
  monitors sidecar health via `Cortex.Events` PubSub.

  ## Lifecycle

      opts = [name: "backend-worker", registry: Gateway.Registry]
      {:ok, pid} = ExternalAgent.start_link(opts)

      {:ok, result} = ExternalAgent.run(pid, "Build the API", timeout_ms: 60_000)

      {:ok, info} = ExternalAgent.get_state(pid)
      info.status
      #=> :healthy

      :ok = ExternalAgent.stop(pid)

  ## PubSub Health Monitoring

  The GenServer subscribes to `Cortex.Events` and reacts to:

    - `:agent_unregistered` -- marks the agent unhealthy when the matching
      agent_id disconnects
    - `:agent_registered` -- re-acquires connection info and restores healthy
      status when a sidecar with the matching name reconnects
    - `:agent_status_changed` -- updates the cached gateway status

  ## Configuration

    - `:name` -- required, string matching the sidecar's registered name
    - `:registry` -- `GenServer.server()` for `Gateway.Registry` (default: `Gateway.Registry`)
    - `:timeout_ms` -- default task timeout in ms (default: 1,800,000 = 30 min)
    - `:pending_tasks` -- `GenServer.server()` for `PendingTasks` (default: `PendingTasks`)
    - `:push_fn` -- `(transport, pid, request) -> {:ok, :sent} | {:error, term()}`
      for test injection
  """

  use GenServer, restart: :temporary

  alias Cortex.Agent.Registry, as: AgentRegistry
  alias Cortex.Events
  alias Cortex.Gateway.Registry, as: GatewayRegistry
  alias Cortex.Provider.External, as: ProviderExternal

  require Logger

  @default_timeout_ms 1_800_000

  # -- Client API --

  @doc """
  Starts an ExternalAgent GenServer.

  Confirms that a sidecar with the given `:name` is registered in
  `Gateway.Registry`, subscribes to `Cortex.Events` PubSub, and stores
  the sidecar's connection info.

  Returns `{:error, :agent_not_found}` if no matching sidecar is registered,
  or `{:error, :registry_not_available}` if the Gateway Registry is not running.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    gen_opts = [name: AgentRegistry.via_tuple(name)]
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Dispatches a prompt to the sidecar agent and blocks until the result arrives.

  Builds a fresh `Provider.External` handle from the current GenServer state,
  calls `Provider.External.run/3`, and returns the result. Returns
  `{:error, :agent_unhealthy}` immediately if the agent is marked unhealthy.

  ## Options

    - `:timeout_ms` -- optional, overrides the default timeout
    - `:team_name` -- optional, overrides the agent name for the task context

  """
  @spec run(GenServer.server(), String.t(), keyword()) ::
          {:ok, Cortex.Orchestration.TeamResult.t()} | {:error, term()}
  def run(server, prompt, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms)

    # Use :infinity for GenServer.call so that Provider.External's internal
    # receive timeout fires first, producing a clean {:error, :timeout}.
    GenServer.call(server, {:run, prompt, opts}, timeout_or_infinity(timeout_ms))
  end

  @doc """
  Returns the current internal state for observability.

  Returns a map with `:name`, `:agent_id`, `:status`, and `:agent_info`.
  """
  @spec get_state(GenServer.server()) :: {:ok, map()}
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Gracefully stops the ExternalAgent GenServer.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    registry = Keyword.get(opts, :registry, GatewayRegistry)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    pending_tasks = Keyword.get(opts, :pending_tasks, Cortex.Provider.External.PendingTasks)
    push_fn = Keyword.get(opts, :push_fn)

    case find_agent_in_registry(registry, name) do
      {:ok, agent} ->
        subscribe_to_events()

        state = %{
          name: name,
          agent_id: agent.id,
          registry: registry,
          timeout_ms: timeout_ms,
          status: :healthy,
          agent_info: agent,
          pending_tasks: pending_tasks,
          push_fn: push_fn
        }

        Logger.info("ExternalAgent started for sidecar #{inspect(name)} (id=#{agent.id})")
        {:ok, state}

      {:error, :agent_not_found} ->
        {:stop, :agent_not_found}

      {:error, :registry_not_available} ->
        {:stop, :registry_not_available}
    end
  end

  @impl true
  def handle_call({:run, prompt, opts}, _from, %{status: :unhealthy} = state) do
    _ = opts
    _ = prompt
    {:reply, {:error, :agent_unhealthy}, state}
  end

  def handle_call({:run, prompt, opts}, _from, state) do
    result = dispatch_via_provider(state, prompt, opts)
    {:reply, result, state}
  end

  def handle_call(:get_state, _from, state) do
    info = %{
      name: state.name,
      agent_id: state.agent_id,
      status: state.status,
      agent_info: state.agent_info
    }

    {:reply, {:ok, info}, state}
  end

  # PubSub: agent disconnected
  @impl true
  def handle_info(
        %{type: :agent_unregistered, payload: %{agent_id: agent_id}},
        %{agent_id: agent_id} = state
      ) do
    Logger.warning("ExternalAgent #{state.name}: sidecar disconnected (id=#{agent_id})")
    {:noreply, %{state | status: :unhealthy}}
  end

  # PubSub: agent registered with matching name -- reconnect
  def handle_info(
        %{type: :agent_registered, payload: %{name: name} = payload},
        %{name: name} = state
      ) do
    new_agent_id = payload.agent_id

    case GatewayRegistry.get(state.registry, new_agent_id) do
      {:ok, agent} ->
        Logger.info("ExternalAgent #{name}: sidecar reconnected (new id=#{new_agent_id})")

        {:noreply, %{state | agent_id: new_agent_id, agent_info: agent, status: :healthy}}

      {:error, :not_found} ->
        # Agent was registered but already gone by the time we queried
        {:noreply, state}
    end
  end

  # PubSub: agent status changed for our agent
  def handle_info(
        %{type: :agent_status_changed, payload: %{agent_id: agent_id} = payload},
        %{agent_id: agent_id} = state
      ) do
    new_status = payload.new_status

    updated_info =
      if state.agent_info do
        %{state.agent_info | status: new_status}
      else
        state.agent_info
      end

    {:noreply, %{state | agent_info: updated_info}}
  end

  # Catch-all for unmatched PubSub events and other messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("ExternalAgent #{state.name} stopping: #{inspect(reason)}")
    :ok
  end

  # -- Private --

  @spec find_agent_in_registry(GenServer.server(), String.t()) ::
          {:ok, Cortex.Gateway.RegisteredAgent.t()}
          | {:error, :agent_not_found | :registry_not_available}
  defp find_agent_in_registry(registry, name) do
    agents = GatewayRegistry.list(registry)

    case Enum.find(agents, fn agent -> agent.name == name end) do
      nil -> {:error, :agent_not_found}
      agent -> {:ok, agent}
    end
  catch
    :exit, _ -> {:error, :registry_not_available}
  end

  @spec dispatch_via_provider(map(), String.t(), keyword()) ::
          {:ok, Cortex.Orchestration.TeamResult.t()} | {:error, term()}
  defp dispatch_via_provider(state, prompt, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, state.timeout_ms)
    team_name = Keyword.get(opts, :team_name, state.name)

    provider_config =
      [
        registry: state.registry,
        timeout_ms: timeout_ms,
        pending_tasks: state.pending_tasks
      ]
      |> maybe_add_push_fn(state.push_fn)

    try do
      with {:ok, handle} <- ProviderExternal.start(provider_config) do
        try do
          ProviderExternal.run(handle, prompt, team_name: team_name, timeout_ms: timeout_ms)
        after
          ProviderExternal.stop(handle)
        end
      end
    rescue
      e ->
        Logger.warning(
          "ExternalAgent #{state.name}: dispatch failed with exception: #{Exception.message(e)}"
        )

        {:error, {:dispatch_failed, Exception.message(e)}}
    end
  end

  @spec maybe_add_push_fn(keyword(), function() | nil) :: keyword()
  defp maybe_add_push_fn(config, nil), do: config
  defp maybe_add_push_fn(config, push_fn), do: Keyword.put(config, :push_fn, push_fn)

  defp subscribe_to_events do
    Events.subscribe()
  rescue
    _ -> :ok
  end

  @spec timeout_or_infinity(non_neg_integer() | nil) :: non_neg_integer() | :infinity
  defp timeout_or_infinity(nil), do: :infinity
  defp timeout_or_infinity(ms) when is_integer(ms) and ms > 0, do: ms + 5_000
  defp timeout_or_infinity(_), do: :infinity
end
