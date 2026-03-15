defmodule Cortex.Orchestration.Runner.Reconciler do
  @moduledoc """
  Handles dead team recovery and run reconciliation.

  After a coordinator crash or network interruption, teams may finish their
  work but the results are never collected. This module provides two recovery
  paths:

  - `resume_run/2` — finds teams stuck in "running" state, extracts their
    session IDs from log files or the workspace registry, and calls
    `Spawner.resume/1` to continue each session.

  - `reconcile_run/2` — scans log files for teams marked "running" to
    determine their actual outcome (success, failure, or still in progress),
    then patches both workspace state and the DB to reflect reality.
  """

  alias Cortex.Orchestration.Runner.Store, as: RunnerStore
  alias Cortex.Orchestration.Runner.Outcomes
  alias Cortex.Orchestration.Spawner
  alias Cortex.Orchestration.State
  alias Cortex.Orchestration.TeamResult
  alias Cortex.Orchestration.Workspace

  require Logger

  # -- Public API --------------------------------------------------------------

  @doc """
  Resumes dead teams in a previously started run.

  Scans the workspace state for teams marked "running" that have no active
  process. For each dead team, extracts the session_id from the log file
  and calls `Spawner.resume/1` to continue the session.

  ## Parameters

    - `workspace_path` — the project root directory containing `.cortex/`
    - `opts` — keyword options:
      - `:command` — override the claude command (for testing)
      - `:timeout_minutes` — per-team timeout (default 30)
      - `:auto_retry` — automatically retry rate-limited teams (default false)
      - `:retry_delay_ms` — delay before resuming rate-limited teams (default 60_000)

  ## Returns

    - `{:ok, results}` — map of team_name => TeamResult for each resumed team
    - `{:error, reason}` — if workspace cannot be read
  """
  @spec resume_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resume_run(workspace_path, opts \\ []) do
    command = Keyword.get(opts, :command, "claude")
    timeout_minutes = Keyword.get(opts, :timeout_minutes, 30)
    auto_retry = Keyword.get(opts, :auto_retry, false)
    retry_delay_ms = Keyword.get(opts, :retry_delay_ms, 60_000)

    cortex_path = Path.join(workspace_path, ".cortex")
    workspace = %Workspace{path: cortex_path}

    with {:ok, state} <- Workspace.read_state(workspace) do
      dead_teams = find_dead_teams(state)

      if dead_teams == [] do
        Logger.info("No dead teams to resume")
        {:ok, %{}}
      else
        Logger.info("Found #{length(dead_teams)} dead teams: #{Enum.join(dead_teams, ", ")}")

        results =
          dead_teams
          |> Enum.map(fn team_name ->
            session_id = find_session_id(workspace, team_name)

            if session_id do
              Logger.info("Resuming #{team_name} (session: #{session_id})")

              log_path = Workspace.log_path(workspace, team_name)

              result =
                Spawner.resume(
                  team_name: team_name,
                  session_id: session_id,
                  timeout_minutes: timeout_minutes,
                  log_path: log_path,
                  command: command,
                  cwd: workspace_path
                )

              case result do
                {:ok, %TeamResult{status: :rate_limited}} when auto_retry ->
                  Logger.warning(
                    "#{team_name} hit rate limit, auto-retrying in #{div(retry_delay_ms, 1000)}s"
                  )

                  Process.sleep(retry_delay_ms)

                  retry_result =
                    Spawner.resume(
                      team_name: team_name,
                      session_id: session_id,
                      timeout_minutes: timeout_minutes,
                      log_path: log_path,
                      command: command,
                      cwd: workspace_path
                    )

                  {team_name, retry_result}

                {:ok, %TeamResult{status: :rate_limited}} ->
                  Logger.warning(
                    "#{team_name} hit rate limit — resume again later (or use auto_retry: true)"
                  )

                  {team_name, {:error, :rate_limited}}

                other ->
                  {team_name, other}
              end
            else
              Logger.warning("No session_id found for #{team_name}, cannot resume")
              {team_name, {:error, :no_session_id}}
            end
          end)

        # Update workspace state for resumed teams
        Enum.each(results, fn
          {team_name, {:ok, %TeamResult{status: :success} = tr}} ->
            Outcomes.apply_outcome(workspace, {team_name, :ok, %{type: :success, result: tr}})

          {team_name, {:ok, %TeamResult{} = tr}} ->
            Outcomes.apply_outcome(
              workspace,
              {team_name, {:error, tr.status}, %{type: :failure, result: tr}}
            )

          _ ->
            :ok
        end)

        {:ok, Map.new(results)}
      end
    end
  end

  @doc """
  Reconciles workspace state by scanning log files for completed sessions.

  When the coordinator dies, teams may finish but their results are never
  collected. This function reads each "running" team's log file, checks
  for a `type: "result"` line, and patches both state.json and the DB
  to reflect the actual outcome.

  Only updates teams that are marked "running" but have no live coordinator.
  Teams with no log file or incomplete logs are left as-is.

  ## Parameters

    - `run_id` — the UUID of the run to reconcile
    - `opts` — keyword options:
      - `:workspace_path` — override (reads from DB if not given)

  ## Returns

    - `{:ok, changes}` — list of `%{team: name, from: old_status, to: new_status, detail: ...}`
    - `{:error, reason}` — on failure
  """
  @spec reconcile_run(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def reconcile_run(run_id, opts \\ []) do
    run = RunnerStore.safe_call(fn -> Cortex.Store.get_run(run_id) end)

    cond do
      is_nil(run) ->
        {:error, :run_not_found}

      Cortex.Orchestration.Runner.coordinator_alive?(run_id) ->
        {:error, :coordinator_alive}

      true ->
        workspace_path = Keyword.get(opts, :workspace_path) || run.workspace_path

        if is_nil(workspace_path) do
          {:error, :no_workspace_path}
        else
          do_reconcile(run_id, workspace_path)
        end
    end
  end

  # -- Private -----------------------------------------------------------------

  @spec do_reconcile(String.t(), String.t()) :: {:ok, [map()]}
  defp do_reconcile(run_id, workspace_path) do
    workspace = %Workspace{path: Path.join(workspace_path, ".cortex")}
    team_runs = RunnerStore.safe_call(fn -> Cortex.Store.get_team_runs(run_id) end) || []

    # Only reconcile teams stuck in "running"
    running_teams =
      Enum.filter(team_runs, fn tr -> tr.status == "running" end)

    changes =
      Enum.flat_map(running_teams, fn tr ->
        log_path = Workspace.log_path(workspace, tr.team_name)

        case Cortex.Orchestration.LogParser.parse(log_path) do
          {:ok, report} ->
            reconcile_team(tr, report, workspace, run_id)

          {:error, _} ->
            []
        end
      end)

    # If all teams are now done, mark the run as completed
    if changes != [] do
      maybe_finalize_run(run_id)
    end

    {:ok, changes}
  end

  @spec reconcile_team(map(), map(), Workspace.t(), String.t()) :: [map()]
  defp reconcile_team(team_run, report, workspace, run_id) do
    cond do
      report.has_result and report.exit_subtype == "success" ->
        new_status = "completed"

        # Update workspace state.json
        Workspace.update_team_state(workspace, team_run.team_name,
          status: "done",
          result_summary: report.result_text,
          cost_usd: report.cost_usd,
          input_tokens: report.total_input_tokens,
          output_tokens: report.total_output_tokens
        )

        Workspace.update_registry_entry(workspace, team_run.team_name,
          status: "done",
          session_id: report.session_id
        )

        # Update DB
        RunnerStore.safe_call(fn ->
          fresh = Cortex.Store.get_team_run(run_id, team_run.team_name)

          if fresh do
            Cortex.Store.update_team_run(fresh, %{
              status: new_status,
              cost_usd: report.cost_usd,
              input_tokens: report.total_input_tokens,
              output_tokens: report.total_output_tokens,
              session_id: report.session_id,
              result_summary: RunnerStore.truncate_summary(report.result_text),
              completed_at: DateTime.utc_now()
            })
          end
        end)

        [
          %{
            team: team_run.team_name,
            from: "running",
            to: new_status,
            detail:
              "log shows successful completion ($#{Float.round((report.cost_usd || 0) * 1.0, 4)})"
          }
        ]

      report.has_result ->
        new_status = "failed"

        Workspace.update_team_state(workspace, team_run.team_name,
          status: "failed",
          result_summary: report.result_text,
          cost_usd: report.cost_usd
        )

        Workspace.update_registry_entry(workspace, team_run.team_name,
          status: "failed",
          session_id: report.session_id
        )

        RunnerStore.safe_call(fn ->
          fresh = Cortex.Store.get_team_run(run_id, team_run.team_name)

          if fresh do
            Cortex.Store.update_team_run(fresh, %{
              status: new_status,
              cost_usd: report.cost_usd,
              session_id: report.session_id,
              result_summary: RunnerStore.truncate_summary(report.result_text),
              completed_at: DateTime.utc_now()
            })
          end
        end)

        [
          %{
            team: team_run.team_name,
            from: "running",
            to: new_status,
            detail: "log shows exit: #{report.diagnosis_detail}"
          }
        ]

      report.line_count > 0 and report.diagnosis != :empty_log ->
        # Log exists but no result line — process died mid-execution
        # Don't change status, just report what we found
        [
          %{
            team: team_run.team_name,
            from: "running",
            to: "running",
            detail: "no result line — #{report.diagnosis_detail} (#{report.line_count} log lines)"
          }
        ]

      true ->
        []
    end
  end

  @spec maybe_finalize_run(String.t()) :: :ok
  defp maybe_finalize_run(run_id) do
    RunnerStore.safe_call(fn ->
      team_runs = Cortex.Store.get_team_runs(run_id)

      all_done =
        Enum.all?(team_runs, fn tr ->
          tr.status in ["completed", "done", "failed"]
        end)

      if all_done do
        run = Cortex.Store.get_run(run_id)

        if run && run.status == "running" do
          total_cost = team_runs |> Enum.map(&(&1.cost_usd || 0.0)) |> Enum.sum()
          total_input = team_runs |> Enum.map(&(&1.input_tokens || 0)) |> Enum.sum()
          total_output = team_runs |> Enum.map(&(&1.output_tokens || 0)) |> Enum.sum()

          has_failures = Enum.any?(team_runs, &(&1.status == "failed"))

          Cortex.Store.update_run(run, %{
            status: if(has_failures, do: "failed", else: "completed"),
            total_cost_usd: total_cost,
            total_input_tokens: total_input,
            total_output_tokens: total_output,
            completed_at: DateTime.utc_now()
          })
        end
      end
    end)

    :ok
  end

  @spec find_dead_teams(State.t()) :: [String.t()]
  defp find_dead_teams(state) do
    state.teams
    |> Enum.filter(fn {_name, ts} -> ts.status == "running" end)
    |> Enum.map(fn {name, _ts} -> name end)
    |> Enum.sort()
  end

  @spec find_session_id(Workspace.t(), String.t()) :: String.t() | nil
  defp find_session_id(workspace, team_name) do
    case Workspace.read_registry(workspace) do
      {:ok, registry} ->
        entry = Enum.find(registry.teams, fn e -> e.name == team_name end)

        if entry && entry.session_id do
          entry.session_id
        else
          log_path = Workspace.log_path(workspace, team_name)
          extract_session_id_from_log(log_path)
        end

      _ ->
        log_path = Workspace.log_path(workspace, team_name)
        extract_session_id_from_log(log_path)
    end
  end

  @spec extract_session_id_from_log(String.t()) :: String.t() | nil
  defp extract_session_id_from_log(log_path) do
    case Spawner.extract_session_id_from_log(log_path) do
      {:ok, sid} -> sid
      :error -> nil
    end
  end
end
