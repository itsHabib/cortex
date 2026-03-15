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
                started_at: DateTime.utc_now()
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
            run_team(name, config, workspace, state, command)
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

  @spec run_team(String.t(), Config.t(), Workspace.t(), State.t(), String.t()) ::
          {String.t(), :ok | {:error, term()}, map()}
  defp run_team(team_name, config, workspace, state, command) do
    team = find_team(config.teams, team_name)
    model = Injection.build_model(team, config.defaults)
    max_turns = Injection.build_max_turns(config.defaults)
    permission_mode = Injection.build_permission_mode(config.defaults)
    timeout_minutes = config.defaults.timeout_minutes
    prompt = Injection.build_prompt(team, config.name, state, config.defaults)
    log_path = Workspace.log_path(workspace, team_name)

    spawner_opts = [
      team_name: team_name,
      prompt: prompt,
      model: model,
      max_turns: max_turns,
      permission_mode: permission_mode,
      timeout_minutes: timeout_minutes,
      log_path: log_path,
      command: command,
      cwd: workspace.path
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
