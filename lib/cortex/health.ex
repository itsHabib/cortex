defmodule Cortex.Health do
  @moduledoc """
  Health check module for Cortex system status.

  Inspects the critical components of the supervision tree and returns
  a structured health report. Used by health endpoints and monitoring
  to determine if the system is operational.

  ## Checks

    - **PubSub** -- is the `Cortex.PubSub` process alive?
    - **DynamicSupervisor** -- is the `Cortex.Agent.Supervisor` alive?
    - **Repo** -- can we run a simple query against the database?
    - **ToolRegistry** -- is the `Cortex.Tool.Registry` agent alive?

  ## Status Logic

    - `:ok` -- all checks pass
    - `:degraded` -- some checks pass (system partially functional)
    - `:down` -- no checks pass or critical components are down

  ## Examples

      %{status: :ok, checks: %{pubsub: true, supervisor: true, repo: true, tool_registry: true}}
        = Cortex.Health.check()

  """

  @doc """
  Runs all health checks and returns a summary.

  Returns a map with `:status` (`:ok`, `:degraded`, or `:down`) and
  `:checks` (a map of component name to boolean health status).
  """
  @spec check() :: %{status: :ok | :degraded | :down, checks: map()}
  def check do
    checks = %{
      pubsub: check_pubsub(),
      supervisor: check_supervisor(),
      repo: check_repo(),
      tool_registry: check_tool_registry()
    }

    status = determine_status(checks)
    %{status: status, checks: checks}
  end

  @spec check_pubsub() :: boolean()
  defp check_pubsub do
    case Process.whereis(Cortex.PubSub) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @spec check_supervisor() :: boolean()
  defp check_supervisor do
    case Process.whereis(Cortex.Agent.Supervisor) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @spec check_repo() :: boolean()
  defp check_repo do
    Cortex.Repo.query("SELECT 1")
    true
  rescue
    _ -> false
  end

  @spec check_tool_registry() :: boolean()
  defp check_tool_registry do
    case Process.whereis(Cortex.Tool.Registry) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @spec determine_status(map()) :: :ok | :degraded | :down
  defp determine_status(checks) do
    values = Map.values(checks)

    cond do
      Enum.all?(values) -> :ok
      Enum.any?(values) -> :degraded
      true -> :down
    end
  end
end
