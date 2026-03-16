defmodule Cortex.Store do
  @moduledoc """
  Context module for persisting and querying orchestration data.

  Provides CRUD operations for runs, team runs, and event logs.
  This is the primary interface for the persistence layer — LiveViews
  and other consumers should go through this module rather than
  calling Repo directly.
  """

  import Ecto.Query

  alias Cortex.Repo
  alias Cortex.Store.Schemas.{EventLog, Run, TeamRun}

  # ── Runs ──────────────────────────────────────────────────────────

  @doc "Creates a new run with the given attributes."
  def create_run(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates an existing run."
  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end

  @doc "Gets a run by ID. Returns nil if not found."
  def get_run(id) do
    Repo.get(Run, id)
  end

  @doc "Gets a run by ID. Raises if not found."
  def get_run!(id) do
    Repo.get!(Run, id)
  end

  @doc """
  Lists runs, ordered by most recent first.

  Options:
    - `:limit` — max number of runs (default 20)
    - `:offset` — offset for pagination (default 0)
    - `:status` — filter by status string
    - `:mode` — filter by mode ("workflow" or "gossip")
  """
  def list_runs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    status = Keyword.get(opts, :status)
    mode = Keyword.get(opts, :mode)

    query =
      from(r in Run,
        order_by: [desc: r.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    query =
      if status do
        from(r in query, where: r.status == ^status)
      else
        query
      end

    query =
      if mode do
        from(r in query, where: r.mode == ^mode)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Recomputes and persists a run's aggregate token/cost totals from its team_runs.

  Use this to fix stale `total_input_tokens` values or to backfill
  cache token breakdowns added in later migrations.
  """
  @spec recompute_run_totals(Run.t()) :: {:ok, Run.t()} | {:error, term()}
  def recompute_run_totals(%Run{} = run) do
    team_runs = get_team_runs(run.id)

    total_input =
      team_runs
      |> Enum.map(fn tr ->
        (tr.input_tokens || 0) + (tr.cache_read_tokens || 0) + (tr.cache_creation_tokens || 0)
      end)
      |> Enum.sum()

    total_output = team_runs |> Enum.map(&(&1.output_tokens || 0)) |> Enum.sum()
    total_cache_read = team_runs |> Enum.map(&(&1.cache_read_tokens || 0)) |> Enum.sum()
    total_cache_creation = team_runs |> Enum.map(&(&1.cache_creation_tokens || 0)) |> Enum.sum()
    total_cost = team_runs |> Enum.map(&(&1.cost_usd || 0.0)) |> Enum.sum()

    update_run(run, %{
      total_input_tokens: total_input,
      total_output_tokens: total_output,
      total_cache_read_tokens: total_cache_read,
      total_cache_creation_tokens: total_cache_creation,
      total_cost_usd: total_cost
    })
  end

  @doc "Recomputes totals for all completed and failed runs."
  @spec backfill_all_run_totals() :: :ok
  def backfill_all_run_totals do
    from(r in Run, where: r.status in ["completed", "failed"])
    |> Repo.all()
    |> Enum.each(&recompute_run_totals/1)
  end

  # ── Team Runs ─────────────────────────────────────────────────────

  @doc "Creates a new team run."
  def create_team_run(attrs) do
    %TeamRun{}
    |> TeamRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates an existing team run."
  def update_team_run(%TeamRun{} = team_run, attrs) do
    team_run
    |> TeamRun.changeset(attrs)
    |> Repo.update()
  end

  @doc "Gets all team runs for a given run, ordered by tier then team name."
  def get_team_runs(run_id) do
    from(tr in TeamRun,
      where: tr.run_id == ^run_id,
      order_by: [asc: tr.tier, asc: tr.team_name]
    )
    |> Repo.all()
  end

  @doc "Gets a specific team run by run_id and team_name."
  def get_team_run(run_id, team_name) do
    from(tr in TeamRun,
      where: tr.run_id == ^run_id and tr.team_name == ^team_name
    )
    |> Repo.one()
  end

  @internal_team_names ~w(coordinator summary-agent debug-agent)

  @doc "Gets all internal agent jobs (coordinator, summary-agent, debug-agent) across all runs."
  @spec get_internal_jobs(keyword()) :: [TeamRun.t()]
  def get_internal_jobs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(tr in TeamRun,
      join: r in Run,
      on: tr.run_id == r.id,
      where: tr.team_name in ^@internal_team_names,
      order_by: [desc: tr.started_at],
      limit: ^limit,
      preload: [:run]
    )
    |> Repo.all()
  end

  # ── Event Logs ────────────────────────────────────────────────────

  @doc "Deletes a run and its associated team runs and event logs."
  def delete_run(%Run{} = run) do
    Repo.delete(run)
  end

  @doc "Logs an event to the event_logs table."
  def log_event(attrs) do
    %EventLog{}
    |> EventLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Returns the most recent events for a run, newest first."
  def recent_events(run_id, limit \\ 50) do
    from(e in EventLog,
      where: e.run_id == ^run_id,
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end
end
