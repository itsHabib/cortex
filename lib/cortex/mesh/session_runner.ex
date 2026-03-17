defmodule Cortex.Mesh.SessionRunner do
  @moduledoc """
  Thin orchestrator for mesh mode sessions.

  Spawns autonomous agents that can see each other's roster and optionally
  message peers. No forced coordination, no exchange rounds — agents work
  independently and reach out only when they need info from another domain.

  ## Flow

  1. Load config
  2. Create workspace dirs via InboxBridge
  3. Create DB records (Run with mode: "mesh", TeamRun per agent)
  4. Start Mesh.Supervisor (MemberList + Detector)
  5. Build roster from MemberList
  6. Build prompts via Mesh.Prompt
  7. Spawn all agents via Spawner in parallel Tasks
  8. Register each in MemberList on port open
  9. Start MessageRelay
  10. Broadcast :mesh_started
  11. Await all Tasks (timeout from config)
  12. Mark completed agents :left in MemberList
  13. Update DB records
  14. Broadcast :mesh_completed
  15. Stop Supervisor + MessageRelay
  16. Write summary to .cortex/summaries/
  17. Return {:ok, summary}

  ## Options

    - `:workspace_path` — directory for `.cortex/` workspace (default: `"."`)
    - `:command` — override claude command (default: `"claude"`, useful for tests)
    - `:dry_run` — if true, return execution plan without spawning (default: `false`)

  """

  alias Cortex.Mesh.Config, as: MeshConfig
  alias Cortex.Mesh.Config.Loader
  alias Cortex.Mesh.Coordinator.Lifecycle, as: CoordLifecycle
  alias Cortex.Mesh.Member
  alias Cortex.Mesh.{MemberList, MessageRelay, Prompt}
  alias Cortex.Messaging.InboxBridge
  alias Cortex.Orchestration.Spawner
  alias Cortex.Orchestration.TeamResult
  alias Cortex.Telemetry, as: Tel

  require Logger

  @doc """
  Runs a mesh session from a YAML config file.

  Returns `{:ok, summary}` on success, `{:error, term()}` on failure.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(config_path, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, config} <- Loader.load(config_path) do
      if dry_run do
        build_dry_run_plan(config)
      else
        execute(config, opts)
      end
    end
  end

  @doc """
  Runs a mesh session from an already-loaded config struct.
  """
  @spec run_config(MeshConfig.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_config(config, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      build_dry_run_plan(config)
    else
      execute(config, opts)
    end
  end

  # -- Dry Run -----------------------------------------------------------------

  @spec build_dry_run_plan(MeshConfig.t()) :: {:ok, map()}
  defp build_dry_run_plan(config) do
    agents =
      Enum.map(config.agents, fn agent ->
        model = agent.model || config.defaults.model
        %{name: agent.name, role: agent.role, model: model}
      end)

    {:ok,
     %{
       status: :dry_run,
       mode: :mesh,
       project: config.name,
       agents: agents,
       total_agents: length(config.agents),
       heartbeat_interval: config.mesh.heartbeat_interval_seconds,
       suspect_timeout: config.mesh.suspect_timeout_seconds,
       dead_timeout: config.mesh.dead_timeout_seconds
     }}
  end

  # -- Execution ---------------------------------------------------------------

  @spec execute(MeshConfig.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp execute(config, opts) do
    workspace_path = Keyword.get(opts, :workspace_path, ".")
    command = Keyword.get(opts, :command, "claude")
    existing_run_id = Keyword.get(opts, :run_id)

    agent_names = Enum.map(config.agents, & &1.name)
    coordinator? = config.mesh.coordinator

    # Step 1: Set up workspace directories (include coordinator if enabled)
    all_participants = if coordinator?, do: agent_names ++ ["coordinator"], else: agent_names
    InboxBridge.setup(workspace_path, all_participants)

    # Step 2: Create DB records (reuse existing run_id if provided by caller)
    run_id = existing_run_id || create_run_record(config, workspace_path)
    create_team_run_records(run_id, config, workspace_path)

    # Step 3: Start Mesh.Supervisor (MemberList + Detector)
    {:ok, sup_pid} =
      Cortex.Mesh.Supervisor.start_link(
        cluster_name: config.name,
        run_id: run_id,
        heartbeat_interval_ms: config.mesh.heartbeat_interval_seconds * 1_000,
        suspect_timeout_ms: config.mesh.suspect_timeout_seconds * 1_000,
        dead_timeout_ms: config.mesh.dead_timeout_seconds * 1_000
      )

    member_list = find_child(sup_pid, MemberList)

    try do
      # Step 4: Pre-register all agents so roster is available before spawn
      Enum.each(config.agents, fn agent ->
        member = %Member{
          id: agent.name,
          name: agent.name,
          role: agent.role,
          prompt: agent.prompt,
          metadata: agent.metadata
        }

        MemberList.register(member_list, member)
      end)

      # Step 5: Build roster and prompts
      roster = MemberList.roster(member_list)

      prompts =
        Map.new(config.agents, fn agent ->
          {agent.name, Prompt.build(agent, config, roster, workspace_path)}
        end)

      broadcast(:mesh_started, %{project: config.name, agents: agent_names})
      Tel.emit_mesh_started(%{project: config.name, agents: agent_names})

      run_start = System.monotonic_time(:millisecond)

      # Step 6: Spawn all agents in parallel
      agent_tasks =
        spawn_all_agents(config, prompts, workspace_path, command, run_id, member_list)

      # Step 6b: Spawn coordinator if enabled
      coordinator_task =
        if coordinator? do
          CoordLifecycle.spawn(config, workspace_path, command, run_id, roster)
        end

      # Step 7: Start MessageRelay
      {:ok, relay_pid} =
        MessageRelay.start(
          workspace_path: workspace_path,
          run_id: run_id || "no-run-id",
          agent_names: agent_names
        )

      # Step 8: Await all agent results
      timeout_ms = round(config.defaults.timeout_minutes * 60 * 1_000)
      results = await_agents(agent_tasks, timeout_ms)

      run_duration = System.monotonic_time(:millisecond) - run_start

      # Stop coordinator (it runs for the session duration)
      if coordinator_task, do: CoordLifecycle.stop(coordinator_task)

      # Step 9: Mark completed agents as :left
      Enum.each(results, fn {name, _status, _data} ->
        MemberList.mark_left(member_list, name)
      end)

      # Step 10: Update DB records
      update_run_record(run_id, results, run_duration)
      update_team_run_records(run_id, results)

      broadcast(:mesh_completed, %{
        project: config.name,
        duration_ms: run_duration
      })

      Tel.emit_mesh_completed(%{
        project: config.name,
        duration_ms: run_duration,
        status: :complete
      })

      # Step 11: Stop relay
      safe_stop(relay_pid)

      # Step 12: Write summary file
      write_run_summary(workspace_path, config, results, run_duration)

      build_summary(config, results, run_duration)
    after
      Supervisor.stop(sup_pid, :normal)
    end
  end

  # -- Agent Spawning ----------------------------------------------------------

  defp spawn_all_agents(config, prompts, workspace_path, command, run_id, member_list) do
    Enum.map(config.agents, fn agent ->
      task =
        Task.async(fn ->
          spawn_agent(agent, config, prompts, workspace_path, command, run_id, member_list)
        end)

      {agent.name, task}
    end)
  end

  defp spawn_agent(agent, config, prompts, workspace_path, command, run_id, member_list) do
    model = agent.model || config.defaults.model
    prompt = Map.fetch!(prompts, agent.name)

    log_dir = Path.join([workspace_path, ".cortex", "logs"])
    File.mkdir_p!(log_dir)
    log_path = Path.join(log_dir, "#{agent.name}.log")

    on_port_opened = fn name, os_pid ->
      MemberList.update_member(member_list, name, %{os_pid: os_pid})
    end

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
        type: Map.get(activity, :type, :unknown),
        tools: Map.get(activity, :tools, []),
        details: Map.get(activity, :details, []),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end

    spawner_opts = [
      team_name: agent.name,
      prompt: prompt,
      model: model,
      max_turns: config.defaults.max_turns,
      permission_mode: config.defaults.permission_mode,
      timeout_minutes: config.defaults.timeout_minutes,
      log_path: log_path,
      command: command,
      on_port_opened: on_port_opened,
      on_token_update: on_token_update,
      on_activity: on_activity
    ]

    case Spawner.spawn(spawner_opts) do
      {:ok, %TeamResult{status: :success} = result} ->
        {agent.name, :ok, %{type: :success, result: result}}

      {:ok, %TeamResult{} = result} ->
        {agent.name, {:error, result.status}, %{type: :failure, result: result}}

      {:error, reason} ->
        {agent.name, {:error, reason}, %{type: :error, reason: reason}}
    end
  end

  # -- Awaiting Results --------------------------------------------------------

  defp await_agents(agent_tasks, timeout_ms) do
    tasks = Enum.map(agent_tasks, fn {_name, task} -> task end)

    Task.yield_many(tasks, timeout_ms)
    |> Enum.zip(agent_tasks)
    |> Enum.map(fn {{task, result}, {name, _task}} ->
      case result do
        {:ok, outcome} ->
          outcome

        {:exit, reason} ->
          {name, {:error, reason}, %{type: :error, reason: reason}}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {name, {:error, :timeout}, %{type: :error, reason: :timeout}}
      end
    end)
  end

  # -- DB Persistence ----------------------------------------------------------

  defp create_run_record(config, workspace_path) do
    case Cortex.Store.create_run(%{
           name: config.name,
           status: "running",
           team_count: length(config.agents),
           started_at: DateTime.utc_now(),
           workspace_path: workspace_path,
           mode: "mesh"
         }) do
      {:ok, run} -> run.id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp create_team_run_records(nil, _config, _workspace_path), do: :ok

  defp create_team_run_records(run_id, config, workspace_path) do
    Enum.each(config.agents, fn agent ->
      log_path = Path.join([workspace_path, ".cortex", "logs", "#{agent.name}.log"])

      Cortex.Store.create_team_run(%{
        run_id: run_id,
        team_name: agent.name,
        role: agent.role,
        status: "running",
        prompt: agent.prompt,
        log_path: log_path,
        started_at: DateTime.utc_now()
      })
    end)
  rescue
    _ -> :ok
  end

  defp update_run_record(nil, _results, _duration), do: :ok

  defp update_run_record(run_id, results, duration_ms) do
    total_cost = sum_result_field(results, :cost_usd, 0.0)
    total_input = sum_result_field(results, :input_tokens, 0)
    total_output = sum_result_field(results, :output_tokens, 0)

    status =
      if Enum.all?(results, fn {_n, s, _d} -> s == :ok end), do: "completed", else: "failed"

    case Cortex.Store.get_run(run_id) do
      nil ->
        :ok

      run ->
        Cortex.Store.update_run(run, %{
          status: status,
          total_cost_usd: total_cost,
          total_input_tokens: total_input,
          total_output_tokens: total_output,
          total_duration_ms: duration_ms,
          completed_at: DateTime.utc_now()
        })
    end
  rescue
    _ -> :ok
  end

  defp update_team_run_records(nil, _results), do: :ok

  defp update_team_run_records(run_id, results) do
    Enum.each(results, fn {name, status, data} ->
      db_status = if status == :ok, do: "completed", else: "failed"

      attrs =
        case data do
          %{result: result} ->
            %{
              status: db_status,
              cost_usd: result.cost_usd,
              input_tokens: result.input_tokens,
              output_tokens: result.output_tokens,
              duration_ms: result.duration_ms,
              num_turns: result.num_turns,
              session_id: result.session_id,
              result_summary: truncate(result.result, 2000),
              completed_at: DateTime.utc_now()
            }

          %{type: :error, reason: reason} ->
            %{
              status: db_status,
              result_summary: "Error: #{inspect(reason)}",
              completed_at: DateTime.utc_now()
            }

          _ ->
            %{status: db_status, completed_at: DateTime.utc_now()}
        end

      case Cortex.Store.get_team_run(run_id, name) do
        nil -> :ok
        team_run -> Cortex.Store.update_team_run(team_run, attrs)
      end
    end)
  rescue
    _ -> :ok
  end

  # -- Summary ----------------------------------------------------------------

  defp build_summary(config, results, run_duration) do
    agent_results = build_agent_results(results)
    total_cost = sum_result_field(results, :cost_usd, 0.0)
    total_input = sum_result_field(results, :input_tokens, 0)
    total_output = sum_result_field(results, :output_tokens, 0)

    overall_status =
      if Enum.all?(results, fn {_name, status, _data} -> status == :ok end),
        do: :complete,
        else: :partial

    {:ok,
     %{
       status: overall_status,
       mode: :mesh,
       project: config.name,
       agents: agent_results,
       total_agents: length(config.agents),
       total_cost: total_cost,
       total_input_tokens: total_input,
       total_output_tokens: total_output,
       total_duration_ms: run_duration
     }}
  end

  defp build_agent_results(results) do
    Map.new(results, fn {name, _status, data} ->
      {name, agent_result_info(data)}
    end)
  end

  defp agent_result_info(%{type: :success, result: result}) do
    %{
      status: :success,
      cost_usd: result.cost_usd,
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens,
      duration_ms: result.duration_ms,
      result_summary: truncate(result.result, 2000)
    }
  end

  defp agent_result_info(%{type: :failure, result: result}) do
    %{
      status: :failed,
      cost_usd: result.cost_usd,
      result_summary: truncate(result.result, 2000)
    }
  end

  defp agent_result_info(%{type: :error, reason: reason}) do
    %{status: :error, reason: inspect(reason)}
  end

  # -- Summary File ------------------------------------------------------------

  defp write_run_summary(workspace_path, config, results, run_duration) do
    summaries_dir = Path.join([workspace_path, ".cortex", "summaries"])
    File.mkdir_p!(summaries_dir)

    timestamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601()
      |> String.replace(~r/[:\-]/, "")
      |> String.slice(0, 15)

    filename = "#{timestamp}_mesh_complete.md"

    succeeded = Enum.count(results, fn {_n, s, _d} -> s == :ok end)
    failed = Enum.count(results, fn {_n, s, _d} -> s != :ok end)
    total_input = sum_result_field(results, :input_tokens, 0)
    total_output = sum_result_field(results, :output_tokens, 0)

    agent_lines =
      Enum.map_join(results, "\n", fn {name, status, data} ->
        status_str = if status == :ok, do: "completed", else: "FAILED"
        "- **#{name}**: #{status_str} — #{format_agent_detail(data)}"
      end)

    content = """
    # Mesh Run Summary: #{config.name}

    **Status**: #{succeeded}/#{length(results)} agents completed, #{failed} failed
    **Duration**: #{div(run_duration, 1000)}s
    **Tokens**: #{total_input} in / #{total_output} out
    **Mode**: mesh (autonomous agents)

    ## Agent Results
    #{agent_lines}
    """

    File.write!(Path.join(summaries_dir, filename), String.trim(content))
    :ok
  rescue
    _ -> :ok
  end

  defp format_agent_detail(%{result: result}) do
    input = result.input_tokens || 0
    output = result.output_tokens || 0
    turns = result.num_turns || 0
    "#{input} in / #{output} out, #{turns} turns"
  end

  defp format_agent_detail(%{type: :error, reason: reason}), do: "Error: #{inspect(reason)}"
  defp format_agent_detail(_), do: "No result data"

  # -- Helpers -----------------------------------------------------------------

  defp sum_result_field(results, field, default) do
    results
    |> Enum.map(fn {_name, _status, data} ->
      case data do
        %{result: result} -> Map.get(result, field) || default
        _ -> default
      end
    end)
    |> Enum.sum()
  end

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp truncate(other, max), do: inspect(other) |> truncate(max)

  defp find_child(sup_pid, child_module) do
    Supervisor.which_children(sup_pid)
    |> Enum.find_value(fn
      {^child_module, pid, _, _} -> pid
      _ -> nil
    end)
  end

  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp safe_stop(_), do: :ok

  defp broadcast(type, payload) do
    Cortex.Events.broadcast(type, payload)
    :ok
  rescue
    _ -> :ok
  end
end
