defmodule Cortex.Orchestration.Runner.Executor do
  @moduledoc """
  Core DAG execution engine for orchestration runs.

  This module handles the main execution flow for both fresh and continued
  (resumed) runs: tier walking, parallel team spawning, coordinator agent
  lifecycle management, and run finalization with cost/token aggregation.

  Extracted from `Cortex.Orchestration.Runner` to isolate the execution
  logic from the top-level API surface. The tier walker (`run_tiers/6`) is
  a unified implementation that handles both fresh and continuation runs --
  it always skips empty tiers, which is safe because fresh runs never
  produce empty tiers.
  """

  alias Cortex.Messaging.InboxBridge
  alias Cortex.Orchestration.Config
  alias Cortex.Orchestration.Injection
  alias Cortex.Orchestration.Config
  alias Cortex.Orchestration.Runner.Store, as: RunnerStore
  alias Cortex.Orchestration.Runner.Outcomes
  alias Cortex.Orchestration.Spawner
  alias Cortex.Orchestration.Summary
  alias Cortex.Orchestration.TeamResult
  alias Cortex.Orchestration.Workspace
  alias Cortex.Telemetry, as: Tel

  require Logger

  @default_task_timeout_ms :timer.minutes(60)

  @coordinator_name "coordinator"
  @coordinator_model "haiku"
  @coordinator_max_turns 500

  # -- Public API -------------------------------------------------------------

  @doc """
  Executes a fresh orchestration run.

  Initializes the workspace, optionally spawns a coordinator agent, then
  walks the DAG tiers in order -- spawning all teams in each tier in
  parallel. After all tiers complete (or a tier fails and
  `continue_on_error` is false), the run is finalized with cost/token
  totals and a summary.

  ## Parameters

    - `config` -- the parsed `Config.t()` for this project
    - `tiers` -- a list of lists of team names (DAG tier order)
    - `workspace_path` -- filesystem path for the workspace root
    - `command` -- the CLI command string (e.g. `"claude"`)
    - `continue_on_error` -- whether to continue past tier failures
    - `run_id` -- an existing run ID to attach to, or `nil` for CLI mode
    - `coordinator` -- whether to spawn a coordinator agent

  ## Returns

    - `{:ok, summary_map}` on success
    - `{:error, {:tier_failed, tier_index, failures}}` on failure

  """
  @spec execute(
          Config.t(),
          [[String.t()]],
          String.t(),
          String.t(),
          boolean(),
          String.t() | nil,
          boolean()
        ) :: {:ok, map()} | {:error, term()}
  def execute(config, tiers, workspace_path, command, continue_on_error, run_id, coordinator) do
    team_names = Enum.map(config.teams, & &1.name)
    ws_config = %{project: config.name, teams: team_names}

    run_id = resolve_run_id(run_id, config, workspace_path, team_names)

    with {:ok, workspace} <- Workspace.init(workspace_path, ws_config) do
      safe_register_runner(run_id)

      watcher_names =
        if coordinator do
          InboxBridge.setup(workspace_path, ["coordinator"])
          team_names ++ ["coordinator"]
        else
          team_names
        end

      _watcher_pid =
        safe_start_watcher(
          workspace_path: workspace_path,
          run_id: run_id,
          team_names: watcher_names
        )

      broadcast(:run_started, %{project: config.name, teams: team_names})
      Tel.emit_run_started(%{project: config.name, teams: team_names})

      coordinator_task =
        if coordinator do
          spawn_coordinator(config, tiers, workspace, command, run_id)
        end

      run_start = System.monotonic_time(:millisecond)

      result =
        run_tiers(tiers, config, workspace, command, continue_on_error, run_id)

      stop_coordinator(coordinator_task)

      run_duration = System.monotonic_time(:millisecond) - run_start

      finalize_fresh(result, run_id, config, workspace, run_duration)
    end
  end

  @doc """
  Continues an interrupted orchestration run.

  Reads the existing run and team-run records from the store, filters out
  already-completed teams, resets zombie "running" teams back to pending,
  then walks the remaining tiers using the same unified `run_tiers/6`.

  ## Parameters

    - `run` -- the existing run record (must have `.id` and `.workspace_path`)
    - `config` -- the parsed `Config.t()` for this project
    - `all_tiers` -- the full list of DAG tiers (unfiltered)
    - `command` -- the CLI command string
    - `continue_on_error` -- whether to continue past tier failures

  ## Returns

    - `{:ok, %{status: :continued, run_id: ..., duration_ms: ...}}` on success
    - `{:error, :all_teams_completed}` if nothing remains to run
    - `{:error, {:tier_failed, tier_index, failures}}` on failure

  """
  @spec execute_continuation(map(), Config.t(), [[String.t()]], String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def execute_continuation(run, config, all_tiers, command, continue_on_error) do
    run_id = run.id
    workspace_path = run.workspace_path

    team_runs = RunnerStore.safe_call(fn -> Cortex.Store.get_team_runs(run_id) end) || []

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
      reset_zombie_teams(team_runs)

      RunnerStore.safe_call(fn ->
        fresh = Cortex.Store.get_run(run_id)
        if fresh, do: Cortex.Store.update_run(fresh, %{status: "running"})
      end)

      safe_register_runner(run_id)

      workspace = %Workspace{path: Path.join(workspace_path, ".cortex")}
      team_names = Enum.map(config.teams, & &1.name)

      InboxBridge.setup(workspace_path, ["coordinator"])

      _watcher_pid =
        safe_start_watcher(
          workspace_path: workspace_path,
          run_id: run_id,
          team_names: team_names ++ ["coordinator"]
        )

      broadcast(:run_started, %{project: config.name, teams: team_names})
      Tel.emit_run_started(%{project: config.name, teams: team_names})

      coordinator_task = spawn_coordinator(config, all_tiers, workspace, command, run_id)

      run_start = System.monotonic_time(:millisecond)

      result =
        run_tiers(filtered_tiers, config, workspace, command, continue_on_error, run_id)

      stop_coordinator(coordinator_task)

      run_duration = System.monotonic_time(:millisecond) - run_start

      finalize_continuation(result, run_id, config, run_duration)
    end
  end

  @doc """
  Builds a dry-run execution plan without spawning any agents.

  Returns a map describing the tiers, teams, roles, and models that
  *would* be used for a real run.

  ## Parameters

    - `config` -- the parsed `Config.t()`
    - `tiers` -- the list of DAG tiers

  ## Returns

    - `{:ok, plan_map}` with status `:dry_run`

  """
  @spec build_dry_run_plan(Config.t(), [[String.t()]]) :: {:ok, map()}
  def build_dry_run_plan(config, tiers) do
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

  @doc """
  Reads workspace state and builds a summary map with aggregated costs,
  tokens, durations, per-team results, and a formatted summary string.

  ## Parameters

    - `config` -- the parsed `Config.t()`
    - `workspace` -- the `Workspace.t()` struct
    - `wall_clock_ms` -- elapsed wall-clock time in milliseconds

  ## Returns

    - `{:ok, summary_map}`

  """
  @spec build_summary(Config.t(), Workspace.t(), non_neg_integer()) :: {:ok, map()}
  def build_summary(config, workspace, wall_clock_ms) do
    {:ok, state} = Workspace.read_state(workspace)

    team_states = Map.values(state.teams)

    total_cost = team_states |> Enum.map(fn ts -> ts.cost_usd || 0.0 end) |> Enum.sum()
    total_input_tokens = team_states |> Enum.map(fn ts -> ts.input_tokens || 0 end) |> Enum.sum()

    total_output_tokens =
      team_states |> Enum.map(fn ts -> ts.output_tokens || 0 end) |> Enum.sum()

    total_duration = team_states |> Enum.map(fn ts -> ts.duration_ms || 0 end) |> Enum.sum()

    overall_status =
      if Enum.any?(team_states, fn ts -> ts.status == "failed" end),
        do: :failed,
        else: :complete

    team_results =
      state.teams
      |> Enum.map(fn {name, ts} ->
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

  # -- Unified tier walker ----------------------------------------------------

  # Walks DAG tiers in order, spawning all teams in each tier in parallel.
  # Skips empty tiers (used by continuation runs where completed teams have
  # been filtered out). Fresh runs never have empty tiers, so the skip is
  # always safe.
  defp run_tiers(tiers, config, workspace, command, continue_on_error, run_id) do
    tiers
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, :complete}, fn {team_names, tier_index}, acc ->
      if team_names == [] do
        # All teams in this tier already completed -- skip
        {:cont, acc}
      else
        broadcast(:tier_started, %{tier: tier_index, teams: team_names})

        {:ok, state} = Workspace.read_state(workspace)

        now = DateTime.utc_now() |> DateTime.to_iso8601()

        Enum.each(team_names, fn name ->
          Workspace.update_team_state(workspace, name, status: "running")
          Workspace.update_registry_entry(workspace, name, status: "running", started_at: now)

          RunnerStore.safe_call(fn ->
            if run_id do
              team = find_team(config.teams, name)
              team_prompt = Injection.build_prompt(team, config.name, state, config.defaults)
              team_log_path = Workspace.log_path(workspace, name)

              case Cortex.Store.get_team_run(run_id, name) do
                nil ->
                  Cortex.Store.create_team_run(%{
                    run_id: run_id,
                    team_name: name,
                    role: team.lead.role,
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
          Outcomes.apply_outcome(workspace, outcome)
          Outcomes.apply_store_outcome(run_id, outcome)
        end)

        failures =
          outcomes
          |> Enum.filter(fn {_name, status, _data} -> status != :ok end)
          |> Enum.map(fn {name, _, _} -> name end)

        broadcast(:tier_completed, %{
          tier: tier_index,
          teams: team_names,
          failures: failures
        })

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

  # -- Team execution ---------------------------------------------------------

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
            details: Map.get(activity, :details, []),
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          })
      end
    end

    on_port_opened = fn name, os_pid ->
      if os_pid do
        Workspace.update_registry_entry(workspace, name, pid: os_pid)
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
      on_activity: on_activity,
      on_port_opened: on_port_opened
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

  # -- Coordinator agent management -------------------------------------------

  defp spawn_coordinator(config, tiers, workspace, command, run_id) do
    prompt = Injection.build_coordinator_prompt(config, tiers, workspace.path)
    log_path = Workspace.log_path(workspace, @coordinator_name)

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
      broadcast(:team_activity, %{
        run_id: run_id,
        team_name: name,
        type: activity.type,
        tools: Map.get(activity, :tools, []),
        details: Map.get(activity, :details, []),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end

    spawner_opts = [
      team_name: @coordinator_name,
      prompt: prompt,
      model: @coordinator_model,
      max_turns: @coordinator_max_turns,
      permission_mode: "bypassPermissions",
      timeout_minutes: config.defaults.timeout_minutes * max(length(tiers), 1),
      log_path: log_path,
      command: command,
      cwd: Path.dirname(workspace.path),
      on_token_update: on_token_update,
      on_activity: on_activity,
      on_port_opened: fn _name, _pid -> :ok end
    ]

    Task.async(fn ->
      Spawner.spawn(spawner_opts)
    end)
  rescue
    e ->
      Logger.warning("Failed to spawn coordinator agent: #{inspect(e)}")
      nil
  end

  defp stop_coordinator(nil), do: :ok

  defp stop_coordinator(task) do
    case Task.yield(task, 5_000) do
      {:ok, _result} -> :ok
      nil -> Task.shutdown(task, :brutal_kill)
    end

    :ok
  rescue
    _ -> :ok
  end

  # -- Run ID resolution ------------------------------------------------------

  # Resolves or creates a run ID for a fresh execution. When a `run_id` is
  # provided (dashboard mode), it updates the existing record. When `nil`
  # (CLI mode), it creates a new Run record and returns its ID.
  defp resolve_run_id(run_id, _config, workspace_path, _team_names) when is_binary(run_id) do
    RunnerStore.safe_call(fn ->
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
  end

  defp resolve_run_id(nil, config, _workspace_path, team_names) do
    RunnerStore.safe_call(fn ->
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

  # -- Fresh run finalization -------------------------------------------------

  defp finalize_fresh({:ok, _}, run_id, config, workspace, run_duration) do
    broadcast(:run_completed, %{project: config.name, duration_ms: run_duration})

    Tel.emit_run_completed(%{
      project: config.name,
      duration_ms: run_duration,
      status: :complete
    })

    RunnerStore.safe_call(fn ->
      if run_id do
        {:ok, state} = Workspace.read_state(workspace)

        team_states = Map.values(state.teams)
        total_cost = team_states |> Enum.map(fn ts -> ts.cost_usd || 0.0 end) |> Enum.sum()

        total_input_tokens =
          team_states |> Enum.map(fn ts -> ts.input_tokens || 0 end) |> Enum.sum()

        total_output_tokens =
          team_states |> Enum.map(fn ts -> ts.output_tokens || 0 end) |> Enum.sum()

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
  end

  defp finalize_fresh(
         {:error, {:tier_failed, _tier_index, _failures}} = error,
         run_id,
         config,
         _workspace,
         run_duration
       ) do
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

    RunnerStore.safe_call(fn ->
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

  # -- Continuation run finalization ------------------------------------------

  defp finalize_continuation({:ok, _}, run_id, config, run_duration) do
    broadcast(:run_completed, %{project: config.name, duration_ms: run_duration})

    Tel.emit_run_completed(%{
      project: config.name,
      duration_ms: run_duration,
      status: :complete
    })

    RunnerStore.safe_call(fn ->
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

    RunnerStore.safe_call(fn ->
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

  # -- Shared private functions ------------------------------------------------

  defp find_team(teams, name) do
    Enum.find(teams, fn t -> t.name == name end)
  end

  defp broadcast(type, payload) do
    Cortex.Events.broadcast(type, payload)
    :ok
  rescue
    _ -> :ok
  end

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

  defp safe_start_watcher(opts) do
    case Cortex.Messaging.OutboxWatcher.start(opts) do
      {:ok, pid} -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # -- Zombie team reset ------------------------------------------------------

  # Resets team runs stuck in "running" status (zombies from a crashed run)
  # back to "pending" so they can be re-executed.
  defp reset_zombie_teams(team_runs) do
    Enum.each(team_runs, fn tr ->
      if tr.status == "running" do
        RunnerStore.safe_call(fn ->
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
  end
end
