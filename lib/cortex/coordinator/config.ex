defmodule Cortex.Coordinator.Config do
  @moduledoc """
  Configuration constants for the orchestration coordinator agent.

  The coordinator is a lightweight `claude -p` session that runs alongside
  DAG teams, monitors progress, relays messages, and reports status.
  """

  @name "coordinator"
  @model "haiku"
  @max_turns 500
  @permission_mode "bypassPermissions"

  @doc "The team name used for the coordinator agent."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The default model for the coordinator agent."
  @spec model() :: String.t()
  def model, do: @model

  @doc "The maximum number of turns for the coordinator session."
  @spec max_turns() :: pos_integer()
  def max_turns, do: @max_turns

  @doc "The permission mode for the coordinator session."
  @spec permission_mode() :: String.t()
  def permission_mode, do: @permission_mode

  @doc """
  Calculates the coordinator timeout based on the number of DAG tiers.

  The coordinator needs to run for the entire duration of the workflow,
  so its timeout scales with tier count.
  """
  @spec timeout_minutes(pos_integer(), non_neg_integer()) :: pos_integer()
  def timeout_minutes(base_timeout_minutes, tier_count) do
    base_timeout_minutes * max(tier_count, 1)
  end
end
