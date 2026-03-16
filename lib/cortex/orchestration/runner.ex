defmodule Cortex.Orchestration.Runner do
  @moduledoc """
  The main orchestration engine that executes multi-team projects end-to-end.

  `run/2` is the top-level entry point. It loads a YAML config, builds a DAG
  of execution tiers, initializes a workspace, then walks through each tier
  spawning teams in parallel. Results from earlier tiers are injected as
  context into later tiers.

  ## Flow

  1. Load and validate config via `Config.Loader.load/1`
  2. Initialize workspace via `Workspace.init/2`
  3. Build DAG tiers via `DAG.build_tiers/1`
  4. Broadcast `:run_started`
  5. For each tier:
     - Broadcast `:tier_started`
     - Spawn all teams in the tier as concurrent `Task`s
     - Each task: build prompt, call `Spawner.spawn/1`, return outcome
     - Await all tasks, then apply workspace updates sequentially
     - If any failed and `continue_on_error` is false, stop early
     - Broadcast `:tier_completed`
  6. Broadcast `:run_completed`
  7. Return `{:ok, summary_map}`

  ## Sub-modules

    - `Runner.Executor` — core DAG tier walking, team spawning, coordinator
    - `Runner.Outcomes` — workspace + DB state updates after team completion
    - `Runner.Reconciler` — dead team recovery and run reconciliation
    - `Runner.Store` — safe DB operation wrappers

  ## Options

    - `:continue_on_error` -- `false` (default). If true, continue to the
      next tier even when a team in the current tier fails.
    - `:dry_run` -- `false` (default). If true, return the execution plan
      without spawning any processes.
    - `:workspace_path` -- `"."` (default). The directory where `.cortex/`
      will be created.
    - `:command` -- `"claude"` (default). Override the spawner command
      (useful for tests with a mock script).

  """

  alias Cortex.Messaging.InboxBridge
  alias Cortex.Orchestration.Config.Loader
  alias Cortex.Orchestration.DAG
  alias Cortex.Orchestration.Runner.Executor
  alias Cortex.Orchestration.Runner.Reconciler

  @doc """
  Runs a full orchestration from a YAML config file.

  Loads the config, builds the DAG, initializes the workspace, and executes
  each tier of teams in parallel. Returns a summary map on success.

  ## Parameters

    - `config_path` -- path to the `orchestra.yaml` file
    - `opts` -- keyword list of options (see module doc)

  ## Returns

    - `{:ok, summary_map}` -- on success, a map with `:status`, `:project`,
      `:teams`, `:total_cost`, `:total_duration_ms`, and `:summary` keys
    - `{:error, term()}` -- on failure

  ## Examples

      iex> Runner.run("path/to/orchestra.yaml", command: "/path/to/mock")
      {:ok, %{status: :complete, project: "demo", ...}}

  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(config_path, opts \\ []) do
    continue_on_error = Keyword.get(opts, :continue_on_error, false)
    dry_run = Keyword.get(opts, :dry_run, false)
    workspace_path = Keyword.get(opts, :workspace_path, ".")
    command = Keyword.get(opts, :command, "claude")
    run_id = Keyword.get(opts, :run_id)
    coordinator = Keyword.get(opts, :coordinator, false)

    with {:ok, config, _warnings} <- Loader.load(config_path),
         {:ok, tiers} <- DAG.build_tiers(config.teams) do
      if dry_run do
        Executor.build_dry_run_plan(config, tiers)
      else
        Executor.execute(
          config,
          tiers,
          workspace_path,
          command,
          continue_on_error,
          run_id,
          coordinator
        )
      end
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  Checks whether a Runner coordinator process is alive for a given run.

  Returns `true` if a process registered under `{:runner, run_id}` exists
  and is alive, `false` otherwise. Uses an Elixir Registry lookup (ETS),
  so this is very fast.
  """
  @spec coordinator_alive?(String.t()) :: boolean()
  def coordinator_alive?(run_id) do
    case Registry.lookup(Cortex.Orchestration.RunnerRegistry, {:coordinator, run_id}) do
      [{pid, _value}] -> Process.alive?(pid)
      [] -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Sends a message to a running team's file-based inbox.

  Delivers a message to the team's inbox file so that the team's
  `claude -p` session can pick it up via its `/loop` polling.

  ## Parameters

    - `workspace_path` -- the project root directory
    - `from` -- sender identifier (e.g. "coordinator" or another team name)
    - `to_team` -- the recipient team name
    - `content` -- the message content string

  ## Returns

  `:ok`
  """
  @spec send_message(String.t(), String.t(), String.t(), String.t()) :: :ok
  def send_message(workspace_path, from, to_team, content) do
    message = %{
      from: from,
      to: to_team,
      content: content,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: "message"
    }

    InboxBridge.deliver(workspace_path, to_team, message)
  end

  @doc """
  Resumes dead teams in a previously started run.

  Delegates to `Runner.Reconciler.resume_run/2`.
  """
  @spec resume_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate resume_run(workspace_path, opts \\ []), to: Reconciler

  @doc """
  Reconciles workspace state by scanning log files for completed sessions.

  Delegates to `Runner.Reconciler.reconcile_run/2`.
  """
  @spec reconcile_run(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate reconcile_run(run_id, opts \\ []), to: Reconciler

  @doc """
  Continues a run that was interrupted (e.g., Runner process died, terminal closed).

  Reads the run's config_yaml from the DB, rebuilds the DAG, identifies which
  teams already completed, and executes the remaining tiers from where the run
  left off.

  ## Parameters

    - `run_id` — the UUID of the run to continue
    - `opts` — keyword options:
      - `:command` — override the claude command (default "claude")
      - `:continue_on_error` — continue past tier failures (default true)

  ## Returns

    - `{:ok, summary_map}` — on success
    - `{:error, reason}` — on failure

  """
  @spec continue_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def continue_run(run_id, opts \\ []) do
    command = Keyword.get(opts, :command, "claude")
    continue_on_error = Keyword.get(opts, :continue_on_error, true)

    with {:ok, run} <- fetch_run(run_id),
         {:ok, _yaml} <- validate_run_config(run),
         {:ok, _path} <- validate_run_workspace(run),
         {:ok, config, _warnings} <- load_run_config(run),
         {:ok, all_tiers} <- DAG.build_tiers(config.teams) do
      Executor.execute_continuation(run, config, all_tiers, command, continue_on_error)
    end
  end

  defp fetch_run(run_id) do
    run =
      try do
        Cortex.Store.get_run(run_id)
      rescue
        _ -> nil
      end

    if is_nil(run), do: {:error, :run_not_found}, else: {:ok, run}
  end

  defp validate_run_config(run) do
    if is_nil(run.config_yaml), do: {:error, :no_config_yaml}, else: {:ok, run.config_yaml}
  end

  defp validate_run_workspace(run) do
    if is_nil(run.workspace_path),
      do: {:error, :no_workspace_path},
      else: {:ok, run.workspace_path}
  end

  defp load_run_config(run) do
    case Loader.load_string(run.config_yaml) do
      {:ok, config, warnings} -> {:ok, config, warnings}
      {:error, errors} -> {:error, {:invalid_config, errors}}
    end
  end
end
