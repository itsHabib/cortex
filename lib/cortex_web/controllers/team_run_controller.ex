defmodule CortexWeb.TeamRunController do
  @moduledoc """
  JSON API controller for team runs within an orchestration run.

  Exposes:
    GET  /api/runs/:run_id/teams       — list all team runs for a run
    GET  /api/runs/:run_id/teams/:name — fetch a specific team run by name
  """
  use CortexWeb, :controller

  action_fallback(CortexWeb.FallbackController)

  alias Cortex.Store
  alias Cortex.Store.Schemas.TeamRun

  @doc "List all team runs for a given run."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"run_id" => run_id}) do
    case Store.get_run(run_id) do
      nil ->
        {:error, :not_found}

      _run ->
        team_runs = Store.get_team_runs(run_id)
        json(conn, %{data: Enum.map(team_runs, &serialize_team_run/1)})
    end
  end

  @doc "Fetch a specific team run by run_id and team name."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"run_id" => run_id, "name" => team_name}) do
    case Store.get_run(run_id) do
      nil ->
        {:error, :not_found}

      _run ->
        case Store.get_team_run(run_id, team_name) do
          nil -> {:error, :not_found}
          team_run -> json(conn, %{data: serialize_team_run(team_run)})
        end
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp serialize_team_run(%TeamRun{} = tr) do
    %{
      id: tr.id,
      run_id: tr.run_id,
      team_name: tr.team_name,
      role: tr.role,
      status: tr.status,
      tier: tr.tier,
      cost_usd: tr.cost_usd,
      input_tokens: tr.input_tokens,
      output_tokens: tr.output_tokens,
      cache_read_tokens: tr.cache_read_tokens,
      cache_creation_tokens: tr.cache_creation_tokens,
      duration_ms: tr.duration_ms,
      num_turns: tr.num_turns,
      session_id: tr.session_id,
      result_summary: tr.result_summary,
      log_path: tr.log_path,
      started_at: tr.started_at,
      completed_at: tr.completed_at,
      inserted_at: tr.inserted_at,
      updated_at: tr.updated_at
    }
  end
end
