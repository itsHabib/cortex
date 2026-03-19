defmodule CortexWeb.WorkflowsLive.Launcher do
  @moduledoc """
  Shared launch logic for all coordination modes.

  Handles the common flow: create a Run record, write temp YAML,
  call the correct SessionRunner, and return the run for redirect.
  Extracted from WorkflowsLive to keep the parent LiveView thin.
  """

  require Logger

  alias Cortex.Orchestration.Runner
  alias Cortex.Store

  @doc """
  Launches a run for the given mode.

  Creates a Run record in the store, spawns the appropriate session runner
  in a background Task, and returns `{:ok, run}` for redirect.

  ## Parameters

    * `yaml` - The YAML config string
    * `config` - The parsed config struct (mode-specific)
    * `mode` - `"dag"` | `"mesh"` | `"gossip"`
    * `workspace_path` - Resolved workspace directory

  ## Returns

    * `{:ok, run}` on success
    * `{:error, reason}` if Run creation fails
  """
  @spec launch(String.t(), struct(), String.t(), String.t()) ::
          {:ok, struct()} | {:error, any()}
  def launch(yaml, config, mode, workspace_path) do
    run_attrs = %{
      name: config.name,
      config_yaml: yaml,
      status: "pending",
      mode: normalize_mode(mode),
      team_count: count_participants(config, mode),
      started_at: DateTime.utc_now(),
      workspace_path: workspace_path
    }

    case safe_create_run(run_attrs) do
      {:ok, run} ->
        spawn_run(run, config, mode, workspace_path)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolves the workspace path from config and UI input.

  Priority: UI workspace > config workspace > generated temp dir.
  """
  @spec resolve_workspace(struct(), String.t(), String.t()) :: String.t()
  def resolve_workspace(config, mode, ui_workspace) do
    cond do
      ui_workspace != "" ->
        ui_workspace

      mode in ["gossip", "mesh"] ->
        Path.join(
          System.tmp_dir!(),
          "cortex_#{mode}_#{Uniq.UUID.uuid4() |> String.slice(0, 8)}"
        )

      Map.get(config, :workspace_path) not in [nil, ""] ->
        config.workspace_path

      true ->
        Path.join(System.tmp_dir!(), "cortex_pending")
    end
  end

  # -- Private --

  defp normalize_mode("dag"), do: "workflow"
  defp normalize_mode(mode), do: mode

  defp count_participants(config, "gossip"), do: length(config.agents)
  defp count_participants(config, "mesh"), do: length(config.agents)
  defp count_participants(config, _), do: length(config.teams)

  defp safe_create_run(attrs) do
    Store.create_run(attrs)
  rescue
    e -> {:error, e}
  end

  defp spawn_run(run, config, "gossip", workspace_path) do
    run_id = run.id
    yaml = run.config_yaml

    Task.start(fn ->
      tmp_path = Path.join(System.tmp_dir!(), "cortex_gossip_#{run_id}.yaml")
      File.write!(tmp_path, yaml)
      safe_update_run_status(run, "running")

      try do
        {:ok, summary} =
          Cortex.Gossip.SessionRunner.run_config(config,
            workspace_path: workspace_path,
            run_id: run_id
          )

        safe_update_run_complete(run, summary)
      rescue
        e ->
          safe_update_run_status(run, "failed")
          Logger.error("Gossip run #{run_id} crashed: #{inspect(e)}")
      after
        File.rm(tmp_path)
      end
    end)
  end

  defp spawn_run(run, config, "mesh", workspace_path) do
    run_id = run.id
    yaml = run.config_yaml

    Task.start(fn ->
      tmp_path = Path.join(System.tmp_dir!(), "cortex_mesh_#{run_id}.yaml")
      File.write!(tmp_path, yaml)
      safe_update_run_status(run, "running")

      try do
        {:ok, summary} =
          Cortex.Mesh.SessionRunner.run_config(config,
            workspace_path: workspace_path,
            run_id: run_id
          )

        safe_update_run_complete(run, summary)
      rescue
        e ->
          trace = Exception.format(:error, e, __STACKTRACE__)
          safe_update_run_status(run, "failed")
          Logger.error("Mesh run #{run_id} crashed:\n#{trace}")
      after
        File.rm(tmp_path)
      end
    end)
  end

  defp spawn_run(run, _config, _dag, workspace_path) do
    yaml = run.config_yaml
    run_id = run.id

    Task.start(fn ->
      tmp_path = Path.join(System.tmp_dir!(), "cortex_run_#{run_id}.yaml")
      File.write!(tmp_path, yaml)

      try do
        result =
          Runner.run(tmp_path,
            workspace_path: workspace_path,
            run_id: run_id,
            coordinator: true
          )

        case result do
          {:ok, _summary} ->
            safe_update_run_status(run, "completed")

          {:error, reason} ->
            safe_update_run_status(run, "failed")
            Logger.error("Run #{run_id} failed: #{inspect(reason)}")
        end
      rescue
        e ->
          safe_update_run_status(run, "failed")
          Logger.error("Run #{run_id} crashed: #{inspect(e)}")
      after
        File.rm(tmp_path)
      end
    end)
  end

  defp safe_update_run_status(run, status) do
    case Store.get_run(run.id) do
      nil -> :ok
      fresh -> Store.update_run(fresh, %{status: status, completed_at: DateTime.utc_now()})
    end
  rescue
    _ -> :ok
  end

  defp safe_update_run_complete(run, summary) do
    case Store.get_run(run.id) do
      nil ->
        :ok

      fresh ->
        Store.update_run(fresh, %{
          status: "completed",
          completed_at: DateTime.utc_now(),
          total_cost_usd: Map.get(summary, :total_cost, 0.0),
          total_input_tokens: Map.get(summary, :total_input_tokens, 0),
          total_output_tokens: Map.get(summary, :total_output_tokens, 0),
          total_duration_ms: Map.get(summary, :total_duration_ms, 0)
        })
    end
  rescue
    _ -> :ok
  end
end
