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
  alias Cortex.Store.Schemas.{Run, TeamRun, EventLog}

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
  """
  def list_runs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    status = Keyword.get(opts, :status)

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

    Repo.all(query)
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

  # ── Event Logs ────────────────────────────────────────────────────

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
