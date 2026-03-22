defmodule CortexWeb.RunController do
  @moduledoc """
  JSON API controller for orchestration runs.

  Exposes:
    GET  /api/runs         — list runs (supports ?limit, ?offset, ?status)
    POST /api/runs         — create a run
    GET  /api/runs/:id     — fetch a single run
  """
  use CortexWeb, :controller

  action_fallback(CortexWeb.FallbackController)

  alias Cortex.Store
  alias Cortex.Store.Schemas.Run

  @doc "List runs. Query params: limit (default 20), offset (default 0), status."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    opts = [
      limit: parse_int(params["limit"], 20),
      offset: parse_int(params["offset"], 0),
      status: params["status"]
    ]

    runs = Store.list_runs(opts)
    json(conn, %{data: Enum.map(runs, &serialize_run/1)})
  end

  @doc """
  Create a run.

  If `config_yaml` is provided, the run is created and then executed
  asynchronously via `Runner.run/2`. The response returns immediately
  with status `"pending"`. Poll `GET /api/runs/:id` for progress.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"config_yaml" => yaml} = params) when is_binary(yaml) and yaml != "" do
    run_attrs = Map.merge(params, %{"status" => "pending"})

    with {:ok, %Run{} = run} <- Store.create_run(run_attrs) do
      start_async_run(run, yaml)

      conn
      |> put_status(:created)
      |> json(%{data: serialize_run(run)})
    end
  end

  def create(conn, params) do
    with {:ok, %Run{} = run} <- Store.create_run(params) do
      conn
      |> put_status(:created)
      |> json(%{data: serialize_run(run)})
    end
  end

  @doc "Fetch a single run by ID."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    case Store.get_run(id) do
      nil -> {:error, :not_found}
      run -> json(conn, %{data: serialize_run(run)})
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  alias Cortex.Orchestration.Runner

  require Logger

  defp start_async_run(%Run{} = run, yaml) do
    Task.Supervisor.start_child(Cortex.TaskSupervisor, fn ->
      tmp_dir = Path.join(System.tmp_dir!(), "cortex-run-#{run.id}")

      try do
        File.mkdir_p!(tmp_dir)
        yaml_path = Path.join(tmp_dir, "orchestra.yaml")
        File.write!(yaml_path, yaml)

        Store.update_run(run, %{
          status: "running",
          workspace_path: tmp_dir,
          started_at: DateTime.utc_now()
        })

        case Runner.run(yaml_path, workspace_path: tmp_dir, run_id: run.id) do
          {:ok, _summary} ->
            Store.update_run(run, %{status: "completed", completed_at: DateTime.utc_now()})
            Logger.info("Run #{run.id} completed")

          {:error, reason} ->
            Store.update_run(run, %{status: "failed", completed_at: DateTime.utc_now()})
            Logger.warning("Run #{run.id} failed: #{inspect(reason)}")
        end
      after
        File.rm_rf!(tmp_dir)
      end
    end)
  end

  defp serialize_run(%Run{} = run) do
    %{
      id: run.id,
      name: run.name,
      status: run.status,
      team_count: run.team_count,
      total_cost_usd: run.total_cost_usd,
      total_duration_ms: run.total_duration_ms,
      started_at: run.started_at,
      completed_at: run.completed_at,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
end
