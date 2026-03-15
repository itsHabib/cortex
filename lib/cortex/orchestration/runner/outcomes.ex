defmodule Cortex.Orchestration.Runner.Outcomes do
  @moduledoc """
  Handles workspace and DB state updates after team execution.

  When a team finishes (success, failure, or error), two kinds of state need
  updating:

  1. **Workspace** -- the JSON files under `.cortex/` that track team status,
     results, and registry entries. These are updated by `apply_outcome/2`.

  2. **Database** -- the Ecto-backed `Store` records for the orchestration run.
     These are updated by `apply_store_outcome/2`.

  Both functions pattern-match on the outcome type (`:success`, `:failure`,
  `:error`) and apply the appropriate updates. All DB calls are wrapped in
  `RunnerStore.safe_call/1` so that store failures never crash the
  orchestration coordinator.
  """

  alias Cortex.Orchestration.Runner.Store, as: RunnerStore
  alias Cortex.Orchestration.TeamResult
  alias Cortex.Orchestration.Workspace
  alias Cortex.Telemetry, as: Tel

  # -- Workspace outcomes -----------------------------------------------------

  @doc """
  Updates workspace files after a team finishes execution.

  Pattern-matches on the outcome type to update team state, registry entry,
  emit telemetry, and write the result JSON file.

  ## Parameters

    - `workspace` -- the `Workspace.t()` struct for the current run
    - `outcome` -- a three-element tuple of `{team_name, status, result_map}`
      where `result_map` contains a `:type` key of `:success`, `:failure`,
      or `:error`

  """
  @spec apply_outcome(Workspace.t(), {String.t(), term(), map()}) :: :ok
  def apply_outcome(workspace, {team_name, _status, %{type: :success, result: result}}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Workspace.update_team_state(workspace, team_name,
      status: "done",
      result_summary: result.result,
      cost_usd: result.cost_usd,
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens,
      cache_read_tokens: result.cache_read_tokens,
      cache_creation_tokens: result.cache_creation_tokens,
      duration_ms: result.duration_ms
    )

    Workspace.update_registry_entry(workspace, team_name,
      status: "done",
      session_id: result.session_id,
      ended_at: now
    )

    Tel.emit_team_completed(%{
      team_name: team_name,
      status: :success,
      duration_ms: result.duration_ms,
      cost_usd: result.cost_usd
    })

    write_team_result(workspace, team_name, result)
    :ok
  end

  def apply_outcome(workspace, {team_name, _status, %{type: :failure, result: result}}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Workspace.update_team_state(workspace, team_name,
      status: "failed",
      result_summary: result.result,
      cost_usd: result.cost_usd,
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens,
      cache_read_tokens: result.cache_read_tokens,
      cache_creation_tokens: result.cache_creation_tokens,
      duration_ms: result.duration_ms
    )

    Workspace.update_registry_entry(workspace, team_name,
      status: "failed",
      session_id: result.session_id,
      ended_at: now
    )

    Tel.emit_team_completed(%{
      team_name: team_name,
      status: :failed,
      duration_ms: result.duration_ms,
      cost_usd: result.cost_usd
    })

    write_team_result(workspace, team_name, result)
    :ok
  end

  def apply_outcome(workspace, {team_name, _status, %{type: :error, reason: reason}}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Workspace.update_team_state(workspace, team_name,
      status: "failed",
      result_summary: "Error: #{inspect(reason)}"
    )

    Workspace.update_registry_entry(workspace, team_name,
      status: "failed",
      ended_at: now
    )

    :ok
  end

  # -- Store (DB) outcomes ----------------------------------------------------

  @doc """
  Updates Ecto-backed DB records after a team finishes execution.

  When `run_id` is `nil`, this is a no-op (the run was not persisted).
  Otherwise, it looks up the team run record and updates it with the
  outcome data. All DB calls are wrapped in `RunnerStore.safe_call/1`.

  ## Parameters

    - `run_id` -- the orchestration run ID (or `nil` to skip)
    - `outcome` -- a three-element tuple of `{team_name, status, result_map}`

  """
  @spec apply_store_outcome(String.t() | nil, {String.t(), term(), map()}) :: :ok
  def apply_store_outcome(nil, _outcome), do: :ok

  def apply_store_outcome(run_id, {team_name, _status, %{type: :success, result: result}}) do
    RunnerStore.safe_call(fn ->
      case Cortex.Store.get_team_run(run_id, team_name) do
        nil ->
          :ok

        team_run ->
          Cortex.Store.update_team_run(team_run, %{
            status: "completed",
            cost_usd: result.cost_usd,
            input_tokens: result.input_tokens,
            output_tokens: result.output_tokens,
            cache_read_tokens: result.cache_read_tokens,
            cache_creation_tokens: result.cache_creation_tokens,
            duration_ms: result.duration_ms,
            num_turns: result.num_turns,
            session_id: result.session_id,
            result_summary: RunnerStore.truncate_summary(result.result),
            completed_at: DateTime.utc_now()
          })
      end
    end)

    :ok
  end

  def apply_store_outcome(run_id, {team_name, _status, %{type: :failure, result: result}}) do
    RunnerStore.safe_call(fn ->
      case Cortex.Store.get_team_run(run_id, team_name) do
        nil ->
          :ok

        team_run ->
          Cortex.Store.update_team_run(team_run, %{
            status: "failed",
            cost_usd: result.cost_usd,
            input_tokens: result.input_tokens,
            output_tokens: result.output_tokens,
            cache_read_tokens: result.cache_read_tokens,
            cache_creation_tokens: result.cache_creation_tokens,
            duration_ms: result.duration_ms,
            num_turns: result.num_turns,
            session_id: result.session_id,
            result_summary: RunnerStore.truncate_summary(result.result),
            completed_at: DateTime.utc_now()
          })
      end
    end)

    :ok
  end

  def apply_store_outcome(run_id, {team_name, _status, %{type: :error, reason: reason}}) do
    RunnerStore.safe_call(fn ->
      case Cortex.Store.get_team_run(run_id, team_name) do
        nil ->
          :ok

        team_run ->
          Cortex.Store.update_team_run(team_run, %{
            status: "failed",
            result_summary: "Error: #{inspect(reason)}",
            completed_at: DateTime.utc_now()
          })
      end
    end)

    :ok
  end

  # -- Result file writing ----------------------------------------------------

  @doc """
  Writes a team's result as a JSON file to the workspace.

  Converts the `TeamResult` struct into a string-keyed map and delegates
  to `Workspace.write_result/3`.

  ## Parameters

    - `workspace` -- the `Workspace.t()` struct
    - `team_name` -- the name of the team
    - `result` -- the `TeamResult.t()` struct to persist

  """
  @spec write_team_result(Workspace.t(), String.t(), TeamResult.t()) :: :ok | {:error, term()}
  def write_team_result(workspace, team_name, result) do
    result_map = %{
      "team" => result.team,
      "status" => Atom.to_string(result.status),
      "result" => result.result,
      "cost_usd" => result.cost_usd,
      "input_tokens" => result.input_tokens,
      "output_tokens" => result.output_tokens,
      "cache_read_tokens" => result.cache_read_tokens,
      "cache_creation_tokens" => result.cache_creation_tokens,
      "num_turns" => result.num_turns,
      "duration_ms" => result.duration_ms,
      "session_id" => result.session_id
    }

    Workspace.write_result(workspace, team_name, result_map)
  end
end
