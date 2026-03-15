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
  alias Cortex.Orchestration.Config
  alias Cortex.Orchestration.Config.Loader
  alias Cortex.Orchestration.DAG
  alias Cortex.Orchestration.Injection
  alias Cortex.Orchestration.Spawner
  alias Cortex.Orchestration.State
  alias Cortex.Orchestration.Summary
  alias Cortex.Orchestration.TeamResult
  alias Cortex.Orchestration.Workspace
  alias Cortex.Telemetry, as: Tel

  require Logger

  @default_task_timeout_ms :timer.minutes(60)

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

    with {:ok, config, _warnings} <- Loader.load(config_path),
         {:ok, tiers} <- DAG.build_tiers(config.teams) do
      if dry_run do
        build_dry_run_plan(config, tiers)
      else
        execute(config, tiers, workspace_path, command, continue_on_error, run_id)
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
    case Registry.lookup(Cortex.Orchestration.RunnerRegistry, {:runner, run_id}) do
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

  Scans the workspace state for teams marked "running" that have no active
  process. For each dead team, extracts the session_id from the log file
  and calls `Spawner.resume/1` to continue the session.

  ## Parameters

    - `workspace_path` — the project root directory containing `.cortex/`
    - `opts` — keyword options:
      - `:command` — override the claude command (for testing)
      - `:timeout_minutes` — per-team timeout (default 30)
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

    # Workspace struct path includes .cortex/
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
            apply_outcome(workspace, {team_name, :ok, %{type: :success, result: tr}})

          {team_name, {:ok, %TeamResult{} = tr}} ->
            apply_outcome(
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
  Continues a run that was interrupted (e.g., Runner process died, terminal closed).

  Reads the run's config_yaml from the DB, rebuilds the DAG, identifies which
  teams already completed, and executes the remaining tiers from where the run
  left off. Completed teams are skipped; their results are preserved and
  injected as context into downstream teams via the workspace state.

  Teams with status "running" (zombies from the dead Runner) are reset to
  "pending" before re-execution. Existing team_run records are updated
  rather than duplicated.

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

    run = safe_store_call(fn -> Cortex.Store.get_run(run_id) end)

    cond do
      is_nil(run) ->
        {:error, :run_not_found}

      is_nil(run.config_yaml) ->
        {:error, :no_config_yaml}

      is_nil(run.workspace_path) ->
        {:error, :no_workspace_path}

      true ->
        case Loader.load_string(run.config_yaml) do
          {:ok, config, _warnings} ->
            case DAG.build_tiers(config.teams) do
              {:ok, all_tiers} ->
                execute_continuation(
                  run,
                  config,
                  all_tiers,
                  command,
                  continue_on_error
                )

              {:error, _} = err ->
                err
            end

          {:error, errors} ->
            {:error, {:invalid_config, errors}}
        end
    end
  end

  @spec execute_continuation(map(), Config.t(), [[String.t()]], String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  defp execute_continuation(run, config, all_tiers, command, continue_on_error) do
    run_id = run.id
    workspace_path = run.workspace_path

    team_runs = safe_store_call(fn -> Cortex.Store.get_team_runs(run_id) end) || []

    completed_teams =
      team_runs
      |> Enum.filter(fn tr -> tr.status in ["completed", "done"] end)
      |> MapSet.new(& &1.team_name)

    filtered_tiers =
      Enum.map(all_tiers, fn tier_teams ->
        Enum.reject(tier_teams, &MapSet.member?(completed_teams, &1))
      end)

    if Enum.all?(filtered_tiers, &(&1 == [])) do
      {:error, :all_teams_completed}
    else
      # Reset zombie "running" teams back to pending
      Enum.each(team_runs, fn tr ->
        if tr.status == "running" do
          safe_store_call(fn ->
            fresh = Cortex.Repo.get(Cortex.Store.Schemas.TeamRun, tr.id)

            if fresh do
              Cortex.Store.update_team_run(fresh, %{
                status: "pending",
                started_at: nil,
                completed_at: nil,
                result_summary: nil,
                session_id: nil
              })
            end
          end)
        end
      end)

      # Mark run as running
      safe_store_call(fn ->
        fresh = Cortex.Store.get_run(run_id)
        if fresh, do: Cortex.Store.update_run(fresh, %{status: "running"})
      end)

      # Register this process as the coordinator for this run
      safe_register_runner(run_id)

      # Open existing workspace (don't re-init — state.json has completed results)
      workspace = %Workspace{path: Path.join(workspace_path, ".cortex")}
      team_names = Enum.map(config.teams, & &1.name)

      _watcher_pid =
        safe_start_watcher(
          workspace_path: workspace_path,
          run_id: run_id,
          team_names: team_names
        )

      broadcast(:run_started, %{project: config.name, teams: team_names})
      Tel.emit_run_started(%{project: config.name, teams: team_names})

      run_start = System.monotonic_time(:millisecond)

      result =
        run_continue_tiers(
          filtered_tiers,
          config,
          workspace,
          command,
          continue_on_error,
          run_id
        )

      run_duration = System.monotonic_time(:millisecond) - run_start

      finalize_continuation(result, run_id, config, run_duration)
    end
  end

  @spec run_continue_tiers(
          [[String.t()]],
          Config.t(),
          Workspace.t(),
          String.t(),
          boolean(),
          String.t() | nil
        ) ::
          {:ok, :complete} | {:error, {:tier_failed, non_neg_integer(), [String.t()]}}
  defp run_continue_tiers(filtered_tiers, config, workspace, command, continue_on_error, run_id) do
    filtered_tiers
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, :complete}, fn {team_names, tier_index}, acc ->
      if team_names == [] do
        # All teams in this tier already completed — skip
        {:cont, acc}
      else
        broadcast(:tier_started, %{tier: tier_index, teams: team_names})

        {:ok, state} = Workspace.read_state(workspace)

        now = DateTime.utc_now() |> DateTime.to_iso8601()

        Enum.each(team_names, fn name ->
          Workspace.update_team_state(workspace, name, status: "running")
          Workspace.update_registry_entry(workspace, name, status: "running", started_at: now)

          # Upsert team_run in DB (may already exist from original run)
          safe_store_call(fn ->
            if run_id do
              team = find_team(config.teams, name)
              team_prompt = Injection.build_prompt(team, config.name, state, config.defaults)
              team_log_path = Workspace.log_path(workspace, name)

              case Cortex.Store.get_team_run(run_id, name) do
                nil ->
                  Cortex.Store.create_team_run(%{
                    run_id: run_id,
                    team_name: name,
                    role: team && team.lead && team.lead.role,
                    tier: tier_index,
                    status: "running",
                    prompt: team_prompt,
                    log_path: team_log_path,
                    started_at: DateTime.utc_now()
                  })

                existing ->
                  Cortex.Store.update_team_run(existing, %{
                    status: "running",
                    prompt: team_prompt,
                    log_path: team_log_path,
                    started_at: DateTime.utc_now(),
                    completed_at: nil,
                    result_summary: nil,
                    session_id: nil
                  })
              end
            end
          end)
        end)

        outcomes =
          team_names
          |> Enum.map(fn name ->
            Task.async(fn ->
              run_team(name, config, workspace, state, command, run_id)
            end)
          end)
          |> Task.await_many(@default_task_timeout_ms)

        Enum.each(outcomes, fn outcome ->
          apply_outcome(workspace, outcome)
          apply_store_outcome(run_id, outcome)
        end)

        failures =
          outcomes
          |> Enum.filter(fn {_name, status, _data} -> status != :ok end)
          |> Enum.map(fn {name, _, _} -> name end)

        broadcast(:tier_completed, %{tier: tier_index, teams: team_names, failures: failures})
        Tel.emit_tier_completed(%{tier_index: tier_index, teams: team_names, failures: failures})

        cond do
          failures == [] ->
            {:cont, acc}

          continue_on_error ->
            {:cont, acc}

          true ->
            {:halt, {:error, {:tier_failed, tier_index, failures}}}
        end
      end
    end)
  end

  @spec finalize_continuation(
          {:ok, :complete} | {:error, term()},
          String.t(),
          Config.t(),
          non_neg_integer()
        ) :: {:ok, map()} | {:error, term()}
  defp finalize_continuation({:ok, _}, run_id, config, run_duration) do
    broadcast(:run_completed, %{project: config.name, duration_ms: run_duration})

    Tel.emit_run_completed(%{
      project: config.name,
      duration_ms: run_duration,
      status: :complete
    })

    safe_store_call(fn ->
      fresh = Cortex.Store.get_run(run_id)

      if fresh do
        all_team_runs = Cortex.Store.get_team_runs(run_id)
        total_cost = all_team_runs |> Enum.map(&(&1.cost_usd || 0.0)) |> Enum.sum()
        total_input = all_team_runs |> Enum.map(&(&1.input_tokens || 0)) |> Enum.sum()
        total_output = all_team_runs |> Enum.map(&(&1.output_tokens || 0)) |> Enum.sum()

        Cortex.Store.update_run(fresh, %{
          status: "completed",
          total_cost_usd: total_cost,
          total_input_tokens: total_input,
          total_output_tokens: total_output,
          total_duration_ms: (fresh.total_duration_ms || 0) + run_duration,
          completed_at: DateTime.utc_now()
        })
      end
    end)

    {:ok, %{status: :continued, run_id: run_id, duration_ms: run_duration}}
  end

  defp finalize_continuation({:error, _} = error, run_id, config, run_duration) do
    broadcast(:run_completed, %{
      project: config.name,
      duration_ms: run_duration,
      status: :failed
    })

    Tel.emit_run_completed(%{
      project: config.name,
      duration_ms: run_duration,
      status: :failed
    })

    safe_store_call(fn ->
      fresh = Cortex.Store.get_run(run_id)

      if fresh do
        Cortex.Store.update_run(fresh, %{
          status: "failed",
          total_duration_ms: (fresh.total_duration_ms || 0) + run_duration,
          completed_at: DateTime.utc_now()
        })
      end
    end)

    error
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
    # Try registry first
    case Workspace.read_registry(workspace) do
      {:ok, registry} ->
        entry = Enum.find(registry.teams, fn e -> e.name == team_name end)

        if entry && entry.session_id do
          entry.session_id
        else
          # Fall back to log file parsing
          log_path = Workspace.log_path(workspace, team_name)
          extract_session_id_from_log(log_path)
        end

      _ ->
        log_path = Workspace.log_path(workspace, team_name)
        extract_session_id_from_log(log_path)
    end
  end

  defp extract_session_id_from_log(log_path) do
    case Spawner.extract_session_id_from_log(log_path) do
      {:ok, sid} -> sid
      :error -> nil
    end
  end

  # -- Dry Run -----------------------------------------------------------------

  @spec build_dry_run_plan(Config.t(), [[String.t()]]) :: {:ok, map()}
  defp build_dry_run_plan(config, tiers) do
    tier_plans =
      tiers
      |> Enum.with_index()
      |> Enum.map(fn {team_names, index} ->
        teams =
          Enum.map(team_names, fn name ->
            team = find_team(config.teams, name)
            model = Injection.build_model(team, config.defaults)
            %{name: name, role: team.lead.role, model: model}
          end)

        %{tier: index, teams: teams}
      end)

    {:ok,
     %{
       status: :dry_run,
       project: config.name,
       tiers: tier_plans,
       total_teams: length(config.teams)
     }}
  end

  # -- Execution ---------------------------------------------------------------

  @spec execute(Config.t(), [[String.t()]], String.t(), String.t(), boolean(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  defp execute(config, tiers, workspace_path, command, continue_on_error, run_id) do
    team_names = Enum.map(config.teams, & &1.name)
    ws_config = %{project: config.name, teams: team_names}

    # If no run_id provided (CLI mode), try to create a Run record
    run_id =
      if run_id do
        safe_store_call(fn ->
          case Cortex.Store.get_run(run_id) do
            nil ->
              nil

            run ->
              Cortex.Store.update_run(run, %{
                status: "running",
                started_at: DateTime.utc_now(),
                workspace_path: workspace_path
              })

              run_id
          end
        end) || run_id
      else
        safe_store_call(fn ->
          case Cortex.Store.create_run(%{
                 name: config.name,
                 status: "running",
                 team_count: length(team_names),
                 started_at: DateTime.utc_now()
               }) do
            {:ok, run} -> run.id
            _ -> nil
          end
        end)
      end

    with {:ok, workspace} <- Workspace.init(workspace_path, ws_config) do
      # Register this process as the coordinator for this run
      safe_register_runner(run_id)

      # Start outbox watcher for progress messages
      _watcher_pid =
        safe_start_watcher(
          workspace_path: workspace_path,
          run_id: run_id,
          team_names: team_names
        )

      broadcast(:run_started, %{project: config.name, teams: team_names})
      Tel.emit_run_started(%{project: config.name, teams: team_names})

      run_start = System.monotonic_time(:millisecond)

      result =
        run_tiers(tiers, config, workspace, command, continue_on_error, run_id)

      run_duration = System.monotonic_time(:millisecond) - run_start

      case result do
        {:ok, _} ->
          broadcast(:run_completed, %{project: config.name, duration_ms: run_duration})

          Tel.emit_run_completed(%{
            project: config.name,
            duration_ms: run_duration,
            status: :complete
          })

          safe_store_call(fn ->
            if run_id do
              {:ok, state} = Workspace.read_state(workspace)

              total_cost =
                state.teams
                |> Map.values()
                |> Enum.map(fn ts -> ts.cost_usd || 0.0 end)
                |> Enum.sum()

              total_input_tokens =
                state.teams
                |> Map.values()
                |> Enum.map(fn ts -> ts.input_tokens || 0 end)
                |> Enum.sum()

              total_output_tokens =
                state.teams
                |> Map.values()
                |> Enum.map(fn ts -> ts.output_tokens || 0 end)
                |> Enum.sum()

              run = Cortex.Store.get_run(run_id)

              if run do
                Cortex.Store.update_run(run, %{
                  status: "completed",
                  total_cost_usd: total_cost,
                  total_input_tokens: total_input_tokens,
                  total_output_tokens: total_output_tokens,
                  total_duration_ms: run_duration,
                  completed_at: DateTime.utc_now()
                })
              end
            end
          end)

          build_summary(config, workspace, run_duration)

        {:error, {:tier_failed, _tier_index, _failures}} = error ->
          broadcast(:run_completed, %{
            project: config.name,
            duration_ms: run_duration,
            status: :failed
          })

          Tel.emit_run_completed(%{
            project: config.name,
            duration_ms: run_duration,
            status: :failed
          })

          safe_store_call(fn ->
            if run_id do
              run = Cortex.Store.get_run(run_id)

              if run do
                Cortex.Store.update_run(run, %{
                  status: "failed",
                  total_duration_ms: run_duration,
                  completed_at: DateTime.utc_now()
                })
              end
            end
          end)

          error
      end
    end
  end

  @spec run_tiers(
          [[String.t()]],
          Config.t(),
          Workspace.t(),
          String.t(),
          boolean(),
          String.t() | nil
        ) ::
          {:ok, :complete} | {:error, {:tier_failed, non_neg_integer(), [String.t()]}}
  defp run_tiers(tiers, config, workspace, command, continue_on_error, run_id) do
    tiers
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, :complete}, fn {team_names, tier_index}, acc ->
      broadcast(:tier_started, %{tier: tier_index, teams: team_names})

      # Read state once before the tier starts (for prompt building)
      {:ok, state} = Workspace.read_state(workspace)

      # Mark all teams in this tier as "running" sequentially before spawning
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      Enum.each(team_names, fn name ->
        Workspace.update_team_state(workspace, name, status: "running")
        Workspace.update_registry_entry(workspace, name, status: "running", started_at: now)

        # Persist team start to Store
        safe_store_call(fn ->
          if run_id do
            team = find_team(config.teams, name)

            team_prompt = Injection.build_prompt(team, config.name, state, config.defaults)
            team_log_path = Workspace.log_path(workspace, name)

            Cortex.Store.create_team_run(%{
              run_id: run_id,
              team_name: name,
              role: team && team.lead && team.lead.role,
              tier: tier_index,
              status: "running",
              prompt: team_prompt,
              log_path: team_log_path,
              started_at: DateTime.utc_now()
            })
          end
        end)
      end)

      # Spawn all teams in parallel, each returns an outcome tuple
      outcomes =
        team_names
        |> Enum.map(fn name ->
          Task.async(fn ->
            run_team(name, config, workspace, state, command, run_id)
          end)
        end)
        |> Task.await_many(@default_task_timeout_ms)

      # Apply workspace updates sequentially to avoid read-modify-write races
      Enum.each(outcomes, fn outcome ->
        apply_outcome(workspace, outcome)
        apply_store_outcome(run_id, outcome)
      end)

      failures =
        outcomes
        |> Enum.filter(fn {_name, status, _data} -> status != :ok end)
        |> Enum.map(fn {name, _, _} -> name end)

      broadcast(:tier_completed, %{tier: tier_index, teams: team_names, failures: failures})
      Tel.emit_tier_completed(%{tier_index: tier_index, teams: team_names, failures: failures})

      cond do
        failures == [] ->
          {:cont, acc}

        continue_on_error ->
          {:cont, acc}

        true ->
          {:halt, {:error, {:tier_failed, tier_index, failures}}}
      end
    end)
  end

  # Each team task returns {name, :ok | {:error, reason}, outcome_data}
  # outcome_data is a map with the info needed to update workspace

  @spec run_team(String.t(), Config.t(), Workspace.t(), State.t(), String.t(), String.t() | nil) ::
          {String.t(), :ok | {:error, term()}, map()}
  defp run_team(team_name, config, workspace, state, command, run_id) do
    team = find_team(config.teams, team_name)
    model = Injection.build_model(team, config.defaults)
    max_turns = Injection.build_max_turns(config.defaults)
    permission_mode = Injection.build_permission_mode(config.defaults)
    timeout_minutes = config.defaults.timeout_minutes
    prompt = Injection.build_prompt(team, config.name, state, config.defaults)
    log_path = Workspace.log_path(workspace, team_name)

    on_token_update = fn name, tokens ->
      broadcast(:team_tokens_updated, %{
        run_id: run_id,
        team_name: name,
        input_tokens: tokens.input_tokens,
        output_tokens: tokens.output_tokens,
        cache_read_tokens: tokens.cache_read_tokens,
        cache_creation_tokens: tokens.cache_creation_tokens
      })
    end

    on_activity = fn name, activity ->
      case activity.type do
        :session_started ->
          # Persist session_id immediately so it survives crashes
          sid = Map.get(activity, :session_id)

          Workspace.update_registry_entry(workspace, name, session_id: sid)

          broadcast(:team_activity, %{
            run_id: run_id,
            team_name: name,
            type: :session_started,
            tools: [],
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        _ ->
          broadcast(:team_activity, %{
            run_id: run_id,
            team_name: name,
            type: activity.type,
            tools: Map.get(activity, :tools, []),
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          })
      end
    end

    spawner_opts = [
      team_name: team_name,
      prompt: prompt,
      model: model,
      max_turns: max_turns,
      permission_mode: permission_mode,
      timeout_minutes: timeout_minutes,
      log_path: log_path,
      command: command,
      cwd: workspace.path,
      on_token_update: on_token_update,
      on_activity: on_activity
    ]

    case Spawner.spawn(spawner_opts) do
      {:ok, %TeamResult{status: :success} = result} ->
        {team_name, :ok, %{type: :success, result: result}}

      {:ok, %TeamResult{} = result} ->
        {team_name, {:error, result.status}, %{type: :failure, result: result}}

      {:error, reason} ->
        {team_name, {:error, reason}, %{type: :error, reason: reason}}
    end
  end

  # -- Workspace Update (called sequentially, no races) -------------------------

  @spec apply_outcome(Workspace.t(), {String.t(), term(), map()}) :: :ok
  defp apply_outcome(workspace, {team_name, _status, %{type: :success, result: result}}) do
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

  defp apply_outcome(workspace, {team_name, _status, %{type: :failure, result: result}}) do
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

  defp apply_outcome(workspace, {team_name, _status, %{type: :error, reason: reason}}) do
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

  # -- Store Persistence (best-effort, wrapped in try/rescue) ----------------

  @spec apply_store_outcome(String.t() | nil, {String.t(), term(), map()}) :: :ok
  defp apply_store_outcome(nil, _outcome), do: :ok

  defp apply_store_outcome(run_id, {team_name, _status, %{type: :success, result: result}}) do
    safe_store_call(fn ->
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
            result_summary: truncate_summary(result.result),
            completed_at: DateTime.utc_now()
          })
      end
    end)

    :ok
  end

  defp apply_store_outcome(run_id, {team_name, _status, %{type: :failure, result: result}}) do
    safe_store_call(fn ->
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
            result_summary: truncate_summary(result.result),
            completed_at: DateTime.utc_now()
          })
      end
    end)

    :ok
  end

  defp apply_store_outcome(run_id, {team_name, _status, %{type: :error, reason: reason}}) do
    safe_store_call(fn ->
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

  defp truncate_summary(nil), do: nil

  defp truncate_summary(text) when is_binary(text) do
    if String.length(text) > 2000 do
      String.slice(text, 0, 2000) <> "..."
    else
      text
    end
  end

  defp truncate_summary(other), do: inspect(other) |> truncate_summary()

  @spec safe_store_call((-> any())) :: any()
  defp safe_store_call(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    end
  end

  @spec safe_register_runner(String.t() | nil) :: :ok
  defp safe_register_runner(nil), do: :ok

  defp safe_register_runner(run_id) do
    Registry.register(
      Cortex.Orchestration.RunnerRegistry,
      {:runner, run_id},
      %{started_at: DateTime.utc_now()}
    )

    :ok
  rescue
    _ -> :ok
  end

  @spec safe_start_watcher(keyword()) :: pid() | nil
  defp safe_start_watcher(opts) do
    case Cortex.Messaging.OutboxWatcher.start_link(opts) do
      {:ok, pid} -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @spec write_team_result(Workspace.t(), String.t(), TeamResult.t()) :: :ok | {:error, term()}
  defp write_team_result(workspace, team_name, result) do
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

  # -- Helpers -----------------------------------------------------------------

  defp find_team(teams, name) do
    Enum.find(teams, fn t -> t.name == name end)
  end

  @spec build_summary(Config.t(), Workspace.t(), non_neg_integer()) :: {:ok, map()}
  defp build_summary(config, workspace, wall_clock_ms) do
    {:ok, state} = Workspace.read_state(workspace)

    total_cost =
      state.teams
      |> Map.values()
      |> Enum.map(fn ts -> ts.cost_usd || 0.0 end)
      |> Enum.sum()

    total_input_tokens =
      state.teams
      |> Map.values()
      |> Enum.map(fn ts -> ts.input_tokens || 0 end)
      |> Enum.sum()

    total_output_tokens =
      state.teams
      |> Map.values()
      |> Enum.map(fn ts -> ts.output_tokens || 0 end)
      |> Enum.sum()

    total_duration =
      state.teams
      |> Map.values()
      |> Enum.map(fn ts -> ts.duration_ms || 0 end)
      |> Enum.sum()

    overall_status =
      if Enum.any?(Map.values(state.teams), fn ts -> ts.status == "failed" end),
        do: :failed,
        else: :complete

    team_results =
      Enum.map(state.teams, fn {name, ts} ->
        {name,
         %{
           status: ts.status,
           cost_usd: ts.cost_usd,
           input_tokens: ts.input_tokens,
           output_tokens: ts.output_tokens,
           duration_ms: ts.duration_ms,
           result_summary: ts.result_summary
         }}
      end)
      |> Map.new()

    summary_text = Summary.format(state)

    {:ok,
     %{
       status: overall_status,
       project: config.name,
       teams: team_results,
       total_cost: total_cost,
       total_input_tokens: total_input_tokens,
       total_output_tokens: total_output_tokens,
       total_duration_ms: total_duration,
       wall_clock_ms: wall_clock_ms,
       summary: summary_text
     }}
  end

  @spec broadcast(atom(), map()) :: :ok
  defp broadcast(type, payload) do
    Cortex.Events.broadcast(type, payload)
    :ok
  rescue
    # If PubSub is not started (e.g., in tests), silently continue
    _ -> :ok
  end
end
