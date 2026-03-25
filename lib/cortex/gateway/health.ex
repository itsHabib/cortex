defmodule Cortex.Gateway.Health do
  @moduledoc """
  GenServer that performs periodic health checks on registered gateway agents.

  Reads agents from `Gateway.Registry`, checks their `last_heartbeat` timestamps
  against configurable thresholds, and enforces a two-phase removal process:

  1. Agents that exceed `heartbeat_timeout_ms` since their last heartbeat are
     marked `:disconnected` via `Registry.update_status/2`.
  2. Agents that have been `:disconnected` for longer than `removal_timeout_ms`
     are fully removed via `Registry.unregister/1`.

  This follows the same periodic-check pattern as `Cortex.Mesh.Detector`.

  ## Configuration

    - `registry` — the Registry GenServer name/pid (default: `Cortex.Gateway.Registry`)
    - `check_interval_ms` — how often to run the health check (default: `15_000`)
    - `heartbeat_timeout_ms` — how long since last heartbeat before marking
      `:disconnected` (default: `60_000`)
    - `removal_timeout_ms` — how long in `:disconnected` state before removal
      (default: `300_000`)

  """

  use GenServer

  alias Cortex.Gateway.Registry

  require Logger

  @doc "Starts the Health monitor GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    state = %{
      registry: Keyword.get(opts, :registry, Registry),
      check_interval_ms: Keyword.get(opts, :check_interval_ms, 15_000),
      heartbeat_timeout_ms: Keyword.get(opts, :heartbeat_timeout_ms, 60_000),
      removal_timeout_ms: Keyword.get(opts, :removal_timeout_ms, 300_000),
      disconnected_at: %{}
    }

    schedule_check(state.check_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = run_health_check(state)
    schedule_check(state.check_interval_ms)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :health_check, interval_ms)
  end

  defp run_health_check(state) do
    agents = Registry.list(state.registry)
    now = DateTime.utc_now()

    Enum.reduce(agents, state, fn agent, acc ->
      try do
        cond do
          agent.status == :disconnected ->
            handle_disconnected_agent(agent, acc, now)

          heartbeat_stale?(agent, acc.heartbeat_timeout_ms, now) ->
            mark_disconnected(agent, acc, now)

          true ->
            # Agent is healthy — remove from disconnected_at tracking if present
            %{acc | disconnected_at: Map.delete(acc.disconnected_at, agent.id)}
        end
      rescue
        e ->
          Logger.warning(
            "Gateway.Health: error checking agent #{inspect(agent.id)}: #{Exception.message(e)}"
          )

          acc
      end
    end)
  end

  defp heartbeat_stale?(agent, timeout_ms, now) do
    case agent.last_heartbeat do
      nil ->
        true

      last_hb ->
        diff_ms = DateTime.diff(now, last_hb, :millisecond)
        diff_ms > timeout_ms
    end
  end

  defp mark_disconnected(agent, state, now) do
    result = Registry.update_status_on(state.registry, agent.id, :disconnected)

    stale_ms =
      case agent.last_heartbeat do
        nil -> "never"
        hb -> "#{DateTime.diff(now, hb, :second)}s ago"
      end

    Logger.info(
      "Gateway.Health: marking agent #{agent.name} (#{agent.id}) as disconnected — heartbeat #{stale_ms}, result: #{inspect(result)}"
    )

    %{state | disconnected_at: Map.put(state.disconnected_at, agent.id, now)}
  end

  defp handle_disconnected_agent(agent, state, now) do
    disconnected_since = Map.get(state.disconnected_at, agent.id)

    cond do
      is_nil(disconnected_since) ->
        # Agent was disconnected but we don't have a timestamp — start tracking now
        %{state | disconnected_at: Map.put(state.disconnected_at, agent.id, now)}

      removal_due?(disconnected_since, state.removal_timeout_ms, now) ->
        Registry.unregister(state.registry, agent.id)

        Logger.info(
          "Gateway.Health: removing agent #{agent.id} (#{agent.name}) — disconnected too long"
        )

        %{state | disconnected_at: Map.delete(state.disconnected_at, agent.id)}

      true ->
        state
    end
  end

  defp removal_due?(disconnected_since, removal_timeout_ms, now) do
    diff_ms = DateTime.diff(now, disconnected_since, :millisecond)
    diff_ms > removal_timeout_ms
  end
end
