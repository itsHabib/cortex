defmodule Cortex.Telemetry do
  @moduledoc """
  Telemetry event definitions and emission helpers for Cortex.

  Defines all telemetry event names as module attributes and provides
  convenience functions for emitting events at key points in the system.
  All events use the `[:cortex, ...]` prefix for namespace isolation.

  ## Event Catalog

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:cortex, :agent, :started]` | `%{}` | `agent_id`, `name`, `role` |
  | `[:cortex, :agent, :stopped]` | `%{}` | `agent_id`, `reason` |
  | `[:cortex, :run, :started]` | `%{team_count: n}` | `project` |
  | `[:cortex, :run, :completed]` | `%{duration_ms: n}` | `project`, `status` |
  | `[:cortex, :tier, :completed]` | `%{team_count: n}` | `tier_index`, `failures` |
  | `[:cortex, :team, :completed]` | `%{duration_ms: n, cost_usd: f}` | `team_name`, `status` |
  | `[:cortex, :gossip, :exchange]` | `%{duration_us: n}` | `store_a`, `store_b` |
  | `[:cortex, :tool, :executed]` | `%{duration_ms: n}` | `tool_name`, `success` |

  ## Usage

      Cortex.Telemetry.emit_agent_started(%{agent_id: id, name: name, role: role})
      Cortex.Telemetry.emit_run_completed(%{project: "demo", duration_ms: 1234, status: :complete})

  """

  # -- Event Name Definitions --

  @agent_started [:cortex, :agent, :started]
  @agent_stopped [:cortex, :agent, :stopped]
  @run_started [:cortex, :run, :started]
  @run_completed [:cortex, :run, :completed]
  @tier_completed [:cortex, :tier, :completed]
  @team_completed [:cortex, :team, :completed]
  @gossip_exchange [:cortex, :gossip, :exchange]
  @tool_executed [:cortex, :tool, :executed]

  @doc "Returns the list of all Cortex telemetry event names."
  @spec event_names() :: [list(atom())]
  def event_names do
    [
      @agent_started,
      @agent_stopped,
      @run_started,
      @run_completed,
      @tier_completed,
      @team_completed,
      @gossip_exchange,
      @tool_executed
    ]
  end

  # -- Emission Helpers --

  @doc "Emits a `[:cortex, :agent, :started]` event."
  @spec emit_agent_started(map()) :: :ok
  def emit_agent_started(metadata) when is_map(metadata) do
    :telemetry.execute(@agent_started, %{}, metadata)
  end

  @doc "Emits a `[:cortex, :agent, :stopped]` event."
  @spec emit_agent_stopped(map()) :: :ok
  def emit_agent_stopped(metadata) when is_map(metadata) do
    :telemetry.execute(@agent_stopped, %{}, metadata)
  end

  @doc "Emits a `[:cortex, :run, :started]` event."
  @spec emit_run_started(map()) :: :ok
  def emit_run_started(metadata) when is_map(metadata) do
    team_count = metadata |> Map.get(:teams, []) |> length()
    :telemetry.execute(@run_started, %{team_count: team_count}, metadata)
  end

  @doc "Emits a `[:cortex, :run, :completed]` event."
  @spec emit_run_completed(map()) :: :ok
  def emit_run_completed(metadata) when is_map(metadata) do
    measurements = %{duration_ms: Map.get(metadata, :duration_ms, 0)}
    :telemetry.execute(@run_completed, measurements, metadata)
  end

  @doc "Emits a `[:cortex, :tier, :completed]` event."
  @spec emit_tier_completed(map()) :: :ok
  def emit_tier_completed(metadata) when is_map(metadata) do
    team_count = metadata |> Map.get(:teams, []) |> length()
    :telemetry.execute(@tier_completed, %{team_count: team_count}, metadata)
  end

  @doc "Emits a `[:cortex, :team, :completed]` event."
  @spec emit_team_completed(map()) :: :ok
  def emit_team_completed(metadata) when is_map(metadata) do
    measurements = %{
      duration_ms: Map.get(metadata, :duration_ms, 0),
      cost_usd: Map.get(metadata, :cost_usd, 0.0)
    }

    :telemetry.execute(@team_completed, measurements, metadata)
  end

  @doc "Emits a `[:cortex, :gossip, :exchange]` event."
  @spec emit_gossip_exchange(map()) :: :ok
  def emit_gossip_exchange(metadata) when is_map(metadata) do
    measurements = %{duration_us: Map.get(metadata, :duration_us, 0)}
    :telemetry.execute(@gossip_exchange, measurements, metadata)
  end

  @doc "Emits a `[:cortex, :tool, :executed]` event."
  @spec emit_tool_executed(map()) :: :ok
  def emit_tool_executed(metadata) when is_map(metadata) do
    measurements = %{duration_ms: Map.get(metadata, :duration_ms, 0)}
    :telemetry.execute(@tool_executed, measurements, metadata)
  end
end
