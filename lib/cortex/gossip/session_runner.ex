defmodule Cortex.Gossip.SessionRunner do
  @moduledoc """
  Runs a gossip exploration session with real `claude -p` agents.

  The coordinator manages the full lifecycle:

  1. Parse gossip config and set up workspace
  2. Start KnowledgeStores for each agent
  3. Seed initial knowledge
  4. Spawn all agents simultaneously as `claude -p` processes
  5. Run exchange rounds — periodically read agent findings, gossip-exchange between stores, deliver new knowledge to agent inboxes
  6. Wait for all agents to complete
  7. Collect and return merged knowledge

  ## How Agents Communicate

  Each agent writes findings to `.cortex/knowledge/<agent>/findings.json`
  and reads shared knowledge from `.cortex/messages/<agent>/inbox.json`.
  The coordinator mediates: it reads findings, runs gossip protocol
  exchanges between KnowledgeStores, and delivers new entries to inboxes.

  ## Options

    - `:workspace_path` — directory for `.cortex/` workspace (default: `"."`)
    - `:command` — override claude command (default: `"claude"`, useful for tests)
    - `:dry_run` — if true, return execution plan without spawning (default: `false`)

  """

  alias Cortex.Gossip.Config, as: GossipConfig
  alias Cortex.Gossip.Config.Loader
  alias Cortex.Gossip.Coordinator.Lifecycle, as: CoordLifecycle
  alias Cortex.Gossip.Entry
  alias Cortex.Gossip.KnowledgeStore
  alias Cortex.Gossip.Protocol
  alias Cortex.Gossip.Topology
  alias Cortex.Messaging.InboxBridge
  alias Cortex.Orchestration.Spawner
  alias Cortex.Orchestration.TeamResult
  alias Cortex.Telemetry, as: Tel

  require Logger

  @doc """
  Runs a gossip exploration session from a YAML config file.

  Loads the config, sets up workspace, spawns agents, runs gossip
  exchange rounds, and returns merged results.

  ## Parameters

    - `config_path` — path to the gossip.yaml file
    - `opts` — keyword list of options (see module doc)

  ## Returns

    - `{:ok, summary}` — on success, a map with status, agents, knowledge, costs
    - `{:error, term()}` — on failure

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
  Runs a gossip session from an already-loaded config struct.

  Useful when config has been loaded/validated separately.
  """
  @spec run_config(GossipConfig.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_config(config, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      build_dry_run_plan(config)
    else
      execute(config, opts)
    end
  end

  # -- Dry Run -----------------------------------------------------------------

  @spec build_dry_run_plan(GossipConfig.t()) :: {:ok, map()}
  defp build_dry_run_plan(config) do
    agents =
      Enum.map(config.agents, fn agent ->
        model = agent.model || config.defaults.model
        %{name: agent.name, topic: agent.topic, model: model}
      end)

    {:ok,
     %{
       status: :dry_run,
       mode: :gossip,
       project: config.name,
       agents: agents,
       total_agents: length(config.agents),
       gossip_rounds: config.gossip.rounds,
       topology: config.gossip.topology,
       exchange_interval: config.gossip.exchange_interval_seconds
     }}
  end

  # -- Execution ---------------------------------------------------------------

  @spec execute(GossipConfig.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp execute(config, opts) do
    workspace_path = Keyword.get(opts, :workspace_path, ".")
    command = Keyword.get(opts, :command, "claude")
    run_id = Keyword.get(opts, :run_id)

    agent_names = Enum.map(config.agents, & &1.name)
    coordinator? = config.gossip.coordinator and config.defaults.provider != :external

    # Step 1: Set up workspace directories (include coordinator if enabled)
    all_participants = if coordinator?, do: agent_names ++ ["coordinator"], else: agent_names
    setup_workspace(workspace_path, all_participants)

    # Step 2: Start KnowledgeStores
    stores = start_stores(agent_names)

    try do
      # Step 3: Seed initial knowledge
      seed_stores(stores, config.seed_knowledge)

      # Step 4: Write seed knowledge to files for agents to read
      write_seed_files(workspace_path, config)

      # Step 4b: Create TeamRun records so the UI can track agents
      create_team_run_records(run_id, config, workspace_path)

      # Persist gossip round total to DB
      persist_gossip_rounds(run_id, 0, config.gossip.rounds)

      broadcast(:gossip_started, %{project: config.name, agents: agent_names})
      Tel.emit_run_started(%{project: config.name, teams: agent_names, mode: :gossip})

      run_start = System.monotonic_time(:millisecond)

      # Step 5: Spawn all agents simultaneously
      agent_tasks = spawn_all_agents(config, workspace_path, command, run_id)

      # Step 5b: Spawn coordinator if enabled
      coordinator_task =
        if coordinator? do
          CoordLifecycle.spawn(config, workspace_path, command, run_id)
        end

      # Step 6: Run exchange rounds (agents are running concurrently)
      run_exchange_loop(config, stores, workspace_path, coordinator?, run_id)

      # Step 6b: Signal agents to wrap up after rounds complete
      signal_agents_to_wrap_up(workspace_path, agent_names)

      # Step 7: Await all agent results (short timeout — rounds are done)
      wrap_up_ms = :timer.minutes(2)
      results = await_agents(agent_tasks, wrap_up_ms)

      # Stop coordinator (it runs for the session duration)
      if coordinator_task, do: CoordLifecycle.stop(coordinator_task)

      run_duration = System.monotonic_time(:millisecond) - run_start

      # Step 8: Ingest final findings from completed agents
      ingest_all_findings(stores, workspace_path, config.agents)

      # Step 9: One final exchange round to propagate everything
      topology = Topology.build(agent_names, config.gossip.topology)
      do_exchange(stores, topology)

      # Step 10: Collect merged knowledge
      all_entries = collect_all_entries(stores)

      # Step 10b: Update TeamRun records with final results
      update_team_run_records(run_id, results)

      # Step 11: Write end-of-run summary to .cortex/summaries/
      write_run_summary(workspace_path, config, results, all_entries, run_duration)

      broadcast(:gossip_completed, %{
        project: config.name,
        duration_ms: run_duration,
        total_entries: length(all_entries),
        by_topic: group_entries_by_topic(all_entries),
        top_entries:
          all_entries
          |> Enum.sort_by(& &1.confidence, :desc)
          |> Enum.take(10)
          |> Enum.map(&entry_to_map/1)
      })

      Tel.emit_run_completed(%{
        project: config.name,
        duration_ms: run_duration,
        status: :complete,
        mode: :gossip
      })

      build_summary(config, results, all_entries, run_duration)
    after
      stop_stores(stores)
    end
  end

  # -- Workspace Setup ---------------------------------------------------------

  @spec setup_workspace(String.t(), [String.t()]) :: :ok
  defp setup_workspace(workspace_path, agent_names) do
    # Create knowledge directories for each agent
    Enum.each(agent_names, fn name ->
      knowledge_dir = Path.join([workspace_path, ".cortex", "knowledge", name])
      File.mkdir_p!(knowledge_dir)

      # Initialize empty findings file
      findings_path = Path.join(knowledge_dir, "findings.json")

      unless File.exists?(findings_path) do
        File.write!(findings_path, Jason.encode!([], pretty: true))
      end
    end)

    # Set up message inboxes
    InboxBridge.setup(workspace_path, agent_names)
  end

  @spec write_seed_files(String.t(), GossipConfig.t()) :: :ok
  defp write_seed_files(_workspace_path, %{seed_knowledge: []}), do: :ok

  defp write_seed_files(workspace_path, config) do
    seed_json =
      Enum.map(config.seed_knowledge, fn seed ->
        %{"topic" => seed.topic, "content" => seed.content}
      end)

    Enum.each(config.agents, fn agent ->
      seed_path =
        Path.join([workspace_path, ".cortex", "knowledge", agent.name, "seed.json"])

      File.write!(seed_path, Jason.encode!(seed_json, pretty: true))
    end)
  end

  # -- TeamRun Persistence (so the LiveView UI can track gossip agents) --------

  @spec create_team_run_records(String.t() | nil, GossipConfig.t(), String.t()) :: :ok
  defp create_team_run_records(nil, _config, _workspace_path), do: :ok

  defp create_team_run_records(run_id, config, workspace_path) do
    Enum.each(config.agents, fn agent ->
      log_path = Path.join([workspace_path, ".cortex", "logs", run_id, "#{agent.name}.log"])

      Cortex.Store.create_team_run(%{
        run_id: run_id,
        team_name: agent.name,
        role: agent.topic,
        status: "running",
        tier: nil,
        prompt: agent.prompt,
        log_path: log_path,
        started_at: DateTime.utc_now()
      })
    end)
  rescue
    _ -> :ok
  end

  @spec update_team_run_records(String.t() | nil, list()) :: :ok
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

  # -- KnowledgeStore Management -----------------------------------------------

  @spec start_stores([String.t()]) :: %{String.t() => pid()}
  defp start_stores(agent_names) do
    Map.new(agent_names, fn name ->
      {:ok, pid} = KnowledgeStore.start_link(agent_id: name)
      {name, pid}
    end)
  end

  @spec stop_stores(%{String.t() => pid()}) :: :ok
  defp stop_stores(stores) do
    Enum.each(stores, fn {_name, pid} ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)
  end

  @spec seed_stores(%{String.t() => pid()}, [GossipConfig.SeedKnowledge.t()]) :: :ok
  defp seed_stores(_stores, []), do: :ok

  defp seed_stores(stores, seed_knowledge) do
    # Seed all stores with the same initial knowledge
    Enum.each(stores, fn {_agent_name, pid} ->
      Enum.each(seed_knowledge, fn seed ->
        entry =
          Entry.new(
            topic: seed.topic,
            content: seed.content,
            source: "seed",
            confidence: 1.0
          )

        KnowledgeStore.put(pid, entry)
      end)
    end)
  end

  # -- Agent Spawning ----------------------------------------------------------

  @spec spawn_all_agents(GossipConfig.t(), String.t(), String.t(), String.t() | nil) :: [
          {String.t(), Task.t()}
        ]
  defp spawn_all_agents(config, workspace_path, command, run_id) do
    Enum.map(config.agents, fn agent ->
      task =
        Task.async(fn ->
          spawn_agent(agent, config, workspace_path, command, run_id)
        end)

      {agent.name, task}
    end)
  end

  defp spawn_agent(agent, config, workspace_path, command, run_id) do
    model = agent.model || config.defaults.model
    prompt = build_agent_prompt(agent, config, workspace_path)

    log_dir =
      if run_id,
        do: Path.join([workspace_path, ".cortex", "logs", run_id]),
        else: Path.join([workspace_path, ".cortex", "logs"])

    File.mkdir_p!(log_dir)
    log_path = Path.join(log_dir, "#{agent.name}.log")

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

  # -- Prompt Building ---------------------------------------------------------

  @spec build_agent_prompt(GossipConfig.Agent.t(), GossipConfig.t(), String.t()) :: String.t()
  defp build_agent_prompt(agent, config, workspace_path) do
    findings_path =
      Path.join([workspace_path, ".cortex", "knowledge", agent.name, "findings.json"])

    inbox_path = InboxBridge.inbox_path(workspace_path, agent.name)

    seed_section = build_seed_section(config.seed_knowledge)

    cluster_section = build_cluster_section(config.cluster_context, config)

    poll_interval = inbox_poll_interval(config.gossip.exchange_interval_seconds)

    """
    You are an exploration agent in a multi-agent gossip system.

    ## Project: #{config.name}
    #{cluster_section}
    ## Your Assignment
    Topic: #{agent.topic}

    #{String.trim(agent.prompt)}

    ## How to Record Findings

    As you discover information, write your findings to:
      #{findings_path}

    The file should be a JSON array of finding objects:
    ```json
    [
      {"topic": "#{agent.topic}", "content": "what you found", "confidence": 0.8},
      {"topic": "#{agent.topic}", "content": "another finding", "confidence": 0.6}
    ]
    ```

    Write to this file frequently — other agents will read your findings and share theirs with you.
    Each finding should have a "topic" (string), "content" (string), and "confidence" (0.0 to 1.0).
    Overwrite the file each time with the complete list of your findings so far.

    ## Incoming Knowledge

    Other agents will share their findings with you via:
      #{inbox_path}

    Set up a loop to check for new knowledge from other agents:
    /loop #{poll_interval} cat #{inbox_path}

    When you see new entries, read them and use them to deepen your exploration.
    Don't just repeat what others found — build on it, find new angles, go deeper.
    #{seed_section}
    ## Instructions

    1. Set up your inbox loop: /loop #{poll_interval} cat #{inbox_path}
    2. Explore your topic thoroughly
    3. Record each discrete finding in findings.json (update frequently)
    4. When inbox delivers knowledge from other agents, use it to guide your exploration
    5. You are part of a #{config.gossip.rounds}-round gossip session. Do NOT finish early.
       Keep exploring and refining your findings until you have received and incorporated
       at least #{max(config.gossip.rounds - 1, 1)} round(s) of peer knowledge from your inbox.
       After incorporating peer knowledge, update your findings.json with improved/new entries.
    6. When done, provide a final summary of all your findings
    """
  end

  @spec build_cluster_section(String.t() | nil, GossipConfig.t()) :: String.t()
  defp build_cluster_section(nil, _config), do: ""

  defp build_cluster_section(context, config) when is_binary(context) do
    agent_names = Enum.map(config.agents, & &1.name)
    agent_list = Enum.map_join(agent_names, "\n", fn name -> "  - #{name}" end)

    """

    ## Cluster Context
    #{String.trim(context)}

    You are part of a cluster of #{length(agent_names)} agents:
    #{agent_list}

    Each agent explores a different angle of the project. You'll receive findings
    from other agents via your inbox — use their discoveries to deepen your own work.
    """
  end

  @spec build_seed_section([GossipConfig.SeedKnowledge.t()]) :: String.t()
  defp build_seed_section([]), do: ""

  defp build_seed_section(seeds) do
    entries =
      Enum.map(seeds, fn seed ->
        "- **#{seed.topic}**: #{seed.content}"
      end)

    "\n## Starting Knowledge\n\n#{Enum.join(entries, "\n")}\n"
  end

  # Poll at half the exchange interval so agents catch new knowledge before
  # the next gossip round. Clamp to a minimum of 10s.
  @spec inbox_poll_interval(pos_integer()) :: String.t()
  defp inbox_poll_interval(exchange_interval_seconds) do
    poll_seconds = max(div(exchange_interval_seconds, 2), 10)

    cond do
      poll_seconds < 60 -> "#{poll_seconds}s"
      rem(poll_seconds, 60) == 0 -> "#{div(poll_seconds, 60)}m"
      true -> "#{poll_seconds}s"
    end
  end

  # -- Exchange Loop -----------------------------------------------------------

  @spec run_exchange_loop(
          GossipConfig.t(),
          %{String.t() => pid()},
          String.t(),
          boolean(),
          String.t() | nil
        ) :: :ok
  defp run_exchange_loop(config, stores, workspace_path, coordinator?, run_id) do
    agent_names = Enum.map(config.agents, & &1.name)

    ctx = %{
      stores: stores,
      workspace_path: workspace_path,
      coordinator?: coordinator?,
      agent_names: agent_names,
      topology: Topology.build(agent_names, config.gossip.topology),
      interval_ms: config.gossip.exchange_interval_seconds * 1_000,
      run_id: run_id
    }

    run_exchange_rounds(config, ctx, 1)
  end

  defp run_exchange_rounds(config, _ctx, round) when round > config.gossip.rounds, do: :ok

  defp run_exchange_rounds(config, ctx, round) do
    # Wait for agents to accumulate findings
    Process.sleep(ctx.interval_ms)

    Cortex.Logger.info(
      "Gossip round #{round}/#{config.gossip.rounds} — reading findings and exchanging",
      project: config.name,
      round: round,
      total_rounds: config.gossip.rounds
    )

    # Read findings from all agents into their KnowledgeStores
    ingest_all_findings(ctx.stores, ctx.workspace_path, config.agents)

    # Run gossip exchange between stores
    do_exchange(ctx.stores, ctx.topology)

    # Deliver new knowledge to agent inboxes
    deliver_knowledge_to_inboxes(ctx.stores, ctx.workspace_path, ctx.agent_names)

    # If coordinator is active, feed it the merged knowledge and process its output
    if ctx.coordinator? do
      deliver_knowledge_to_coordinator(
        ctx.stores,
        ctx.workspace_path,
        ctx.agent_names,
        round,
        config.gossip.rounds
      )

      process_coordinator_outbox(ctx.workspace_path, ctx.agent_names)
    end

    # Collect current knowledge state for UI updates
    current_entries = collect_all_entries(ctx.stores)

    broadcast(:gossip_round_completed, %{
      round: round,
      total: config.gossip.rounds,
      total_entries: length(current_entries),
      by_topic: group_entries_by_topic(current_entries),
      top_entries:
        current_entries
        |> Enum.sort_by(& &1.confidence, :desc)
        |> Enum.take(10)
        |> Enum.map(&entry_to_map/1)
    })

    persist_gossip_rounds(ctx.run_id, round, config.gossip.rounds)

    # Check for early termination from coordinator
    if ctx.coordinator? && coordinator_requested_termination?(ctx.workspace_path) do
      Cortex.Logger.info(
        "Coordinator requested early termination after round #{round}",
        project: config.name,
        round: round
      )

      broadcast(:gossip_early_termination, %{round: round, total: config.gossip.rounds})
      :ok
    else
      run_exchange_rounds(config, ctx, round + 1)
    end
  end

  @spec signal_agents_to_wrap_up(String.t(), [String.t()]) :: :ok
  defp signal_agents_to_wrap_up(workspace_path, agent_names) do
    Cortex.Logger.info("All gossip rounds complete — signaling agents to wrap up")

    Enum.each(agent_names, fn name ->
      message = %{
        from: "system",
        to: name,
        content:
          "All gossip rounds are complete. Please finalize your findings.json " <>
            "with your best findings, provide a final summary, and finish up. " <>
            "Do not start new research.",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        type: "terminate"
      }

      InboxBridge.deliver(workspace_path, name, message)
    end)

    :ok
  end

  @spec ingest_all_findings(
          %{String.t() => pid()},
          String.t(),
          [GossipConfig.Agent.t()]
        ) :: :ok
  defp ingest_all_findings(stores, workspace_path, agents) do
    Enum.each(agents, fn agent ->
      findings_path =
        Path.join([workspace_path, ".cortex", "knowledge", agent.name, "findings.json"])

      ingest_agent_findings(stores, agent, findings_path)
    end)
  end

  defp ingest_agent_findings(stores, agent, findings_path) do
    case read_findings(findings_path) do
      {:ok, findings} ->
        pid = Map.fetch!(stores, agent.name)

        Enum.each(findings, fn finding ->
          entry =
            Entry.new(
              topic: Map.get(finding, "topic", agent.topic),
              content: Map.get(finding, "content", ""),
              source: agent.name,
              confidence: Map.get(finding, "confidence", 0.5)
            )

          KnowledgeStore.put(pid, entry)
        end)

      {:error, _reason} ->
        :ok
    end
  end

  @spec read_findings(String.t()) :: {:ok, [map()]} | {:error, term()}
  defp read_findings(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) -> {:ok, list}
          {:ok, _} -> {:ok, []}
          {:error, _} -> {:ok, []}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec do_exchange(%{String.t() => pid()}, %{String.t() => [String.t()]}) :: :ok
  defp do_exchange(stores, topology) do
    pairs = select_pairs(topology)

    Enum.each(pairs, fn {agent_a, agent_b} ->
      store_a = Map.get(stores, agent_a)
      store_b = Map.get(stores, agent_b)

      if store_a && store_b do
        start_us = System.monotonic_time(:microsecond)
        Protocol.exchange(store_a, store_b)
        duration_us = System.monotonic_time(:microsecond) - start_us

        Tel.emit_gossip_exchange(%{
          store_a: agent_a,
          store_b: agent_b,
          duration_us: duration_us
        })
      end
    end)
  end

  @spec select_pairs(%{String.t() => [String.t()]}) :: [{String.t(), String.t()}]
  defp select_pairs(topology) do
    topology
    |> Enum.flat_map(fn {agent_id, peers} ->
      case peers do
        [] -> []
        peers -> [{agent_id, Enum.random(peers)}]
      end
    end)
    |> Enum.map(fn {a, b} -> if a < b, do: {a, b}, else: {b, a} end)
    |> Enum.uniq()
  end

  @spec deliver_knowledge_to_inboxes(
          %{String.t() => pid()},
          String.t(),
          [String.t()]
        ) :: :ok
  defp deliver_knowledge_to_inboxes(stores, workspace_path, agent_names) do
    Enum.each(agent_names, fn agent_name ->
      pid = Map.fetch!(stores, agent_name)
      entries = KnowledgeStore.all(pid)

      # Only deliver entries from OTHER agents
      foreign_entries =
        entries
        |> Enum.filter(fn entry -> entry.source != agent_name && entry.source != "seed" end)
        |> Enum.map(fn entry ->
          %{
            "from" => entry.source,
            "topic" => entry.topic,
            "content" => entry.content,
            "confidence" => entry.confidence
          }
        end)

      if foreign_entries != [] do
        message = %{
          from: "gossip-coordinator",
          to: agent_name,
          content: Jason.encode!(foreign_entries, pretty: true),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          type: "knowledge_exchange"
        }

        InboxBridge.deliver(workspace_path, agent_name, message)
      end
    end)
  end

  defp persist_gossip_rounds(nil, _current, _total), do: :ok

  defp persist_gossip_rounds(run_id, current, total) do
    case Cortex.Store.get_run(run_id) do
      nil ->
        :ok

      run ->
        Cortex.Store.update_run(run, %{
          gossip_rounds_completed: current,
          gossip_rounds_total: total
        })
    end
  rescue
    _ -> :ok
  end

  @spec deliver_knowledge_to_coordinator(
          %{String.t() => pid()},
          String.t(),
          [String.t()],
          pos_integer(),
          pos_integer()
        ) :: :ok
  defp deliver_knowledge_to_coordinator(stores, workspace_path, agent_names, round, total_rounds) do
    # Gather ALL knowledge entries from all stores
    all_entries =
      stores
      |> Enum.flat_map(fn {_name, pid} -> KnowledgeStore.all(pid) end)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn entry ->
        %{
          "source" => entry.source,
          "topic" => entry.topic,
          "content" => entry.content,
          "confidence" => entry.confidence
        }
      end)

    message = %{
      from: "system",
      to: "coordinator",
      type: "knowledge_digest",
      content:
        Jason.encode!(
          %{
            "round" => round,
            "total_rounds" => total_rounds,
            "agents" => agent_names,
            "total_entries" => length(all_entries),
            "entries" => all_entries
          },
          pretty: true
        ),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    InboxBridge.deliver(workspace_path, "coordinator", message)
  end

  @spec process_coordinator_outbox(String.t(), [String.t()]) :: :ok
  defp process_coordinator_outbox(workspace_path, agent_names) do
    {:ok, messages} = InboxBridge.read_outbox(workspace_path, "coordinator")

    # Relay steering messages to target agents
    messages
    |> Enum.filter(fn msg ->
      to = Map.get(msg, "to", "")
      to != "system" && to != "" && to in agent_names
    end)
    |> Enum.each(fn msg ->
      to = Map.get(msg, "to")

      steering = %{
        from: "coordinator",
        to: to,
        type: "steering",
        content: Map.get(msg, "content", ""),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      InboxBridge.deliver(workspace_path, to, steering)
    end)

    :ok
  end

  @spec coordinator_requested_termination?(String.t()) :: boolean()
  defp coordinator_requested_termination?(workspace_path) do
    {:ok, messages} = InboxBridge.read_outbox(workspace_path, "coordinator")

    Enum.any?(messages, fn msg ->
      Map.get(msg, "type") == "terminate" && Map.get(msg, "to") == "system"
    end)
  end

  # -- Awaiting Results --------------------------------------------------------

  @spec await_agents([{String.t(), Task.t()}], pos_integer()) :: [
          {String.t(), :ok | {:error, term()}, map()}
        ]
  defp await_agents(agent_tasks, timeout_ms) do
    tasks = Enum.map(agent_tasks, fn {_name, task} -> task end)

    results =
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

    results
  end

  # -- Collecting Results ------------------------------------------------------

  @spec collect_all_entries(%{String.t() => pid()}) :: [Entry.t()]
  defp collect_all_entries(stores) do
    stores
    |> Enum.flat_map(fn {_name, pid} -> KnowledgeStore.all(pid) end)
    |> Enum.uniq_by(& &1.id)
  end

  # -- Summary -----------------------------------------------------------------

  @spec build_summary(GossipConfig.t(), list(), [Entry.t()], non_neg_integer()) ::
          {:ok, map()}
  defp build_summary(config, results, entries, run_duration) do
    agent_results = build_agent_results(results)
    total_cost = sum_result_field(results, :cost_usd, 0.0)
    total_input_tokens = sum_result_field(results, :input_tokens, 0)
    total_output_tokens = sum_result_field(results, :output_tokens, 0)
    knowledge_by_topic = group_entries_by_topic(entries)

    overall_status =
      if Enum.all?(results, fn {_name, status, _data} -> status == :ok end),
        do: :complete,
        else: :partial

    {:ok,
     %{
       status: overall_status,
       mode: :gossip,
       project: config.name,
       agents: agent_results,
       total_agents: length(config.agents),
       total_cost: total_cost,
       total_input_tokens: total_input_tokens,
       total_output_tokens: total_output_tokens,
       total_duration_ms: run_duration,
       gossip_rounds: config.gossip.rounds,
       topology: config.gossip.topology,
       knowledge: %{
         total_entries: length(entries),
         by_topic: knowledge_by_topic,
         entries: Enum.map(entries, &entry_to_map/1)
       }
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

  defp group_entries_by_topic(entries) do
    entries
    |> Enum.group_by(& &1.topic)
    |> Enum.map(fn {topic, topic_entries} -> {topic, length(topic_entries)} end)
    |> Map.new()
  end

  @spec entry_to_map(Entry.t()) :: map()
  defp entry_to_map(entry) do
    %{
      id: entry.id,
      topic: entry.topic,
      content: entry.content,
      source: entry.source,
      confidence: entry.confidence
    }
  end

  # -- End-of-run summary file (always written, regardless of coordinator) ------

  @spec write_run_summary(String.t(), GossipConfig.t(), list(), [Entry.t()], non_neg_integer()) ::
          :ok
  defp write_run_summary(workspace_path, config, results, entries, run_duration) do
    summaries_dir = Path.join([workspace_path, ".cortex", "summaries"])
    File.mkdir_p!(summaries_dir)

    timestamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601()
      |> String.replace(~r/[:\-]/, "")
      |> String.slice(0, 15)

    filename = "#{timestamp}_run_complete.md"

    succeeded = Enum.count(results, fn {_n, s, _d} -> s == :ok end)
    failed = Enum.filter(results, fn {_n, s, _d} -> s != :ok end)
    total_input = sum_result_field(results, :input_tokens, 0)
    total_output = sum_result_field(results, :output_tokens, 0)
    agent_lines = format_agent_lines(results)
    failure_lines = format_failure_lines(failed, config)
    knowledge_lines = format_knowledge_lines(entries)

    content = """
    # Run Summary: #{config.name}

    **Status**: #{succeeded}/#{length(results)} agents completed, #{length(failed)} failed
    **Duration**: #{div(run_duration, 1000)}s
    **Tokens**: #{total_input} in / #{total_output} out
    **Gossip**: #{config.gossip.rounds} rounds, #{config.gossip.topology} topology
    **Knowledge**: #{length(entries)} unique entries

    ## Agent Results
    #{agent_lines}
    #{failure_lines}
    ## Knowledge by Topic
    #{knowledge_lines}
    """

    File.write!(Path.join(summaries_dir, filename), String.trim(content))
    :ok
  rescue
    _ -> :ok
  end

  defp format_agent_lines(results) do
    Enum.map_join(results, "\n", fn {name, status, data} ->
      status_str = if status == :ok, do: "completed", else: "FAILED"
      "- **#{name}**: #{status_str}\n    #{format_agent_detail(data)}"
    end)
  end

  defp format_agent_detail(%{result: result}) do
    input = result.input_tokens || 0
    output = result.output_tokens || 0
    turns = result.num_turns || 0
    snippet = truncate(result.result, 200)
    "#{input} in / #{output} out, #{turns} turns\n    Result: #{snippet}"
  end

  defp format_agent_detail(%{type: :error, reason: reason}), do: "Error: #{inspect(reason)}"
  defp format_agent_detail(_), do: "No result data"

  defp format_failure_lines([], _config), do: ""

  defp format_failure_lines(failed, config) do
    lines =
      Enum.map_join(failed, "\n", fn {name, _status, data} ->
        "- **#{name}**: #{format_failure_reason(data, config)}"
      end)

    "\n## Failures\n#{lines}"
  end

  defp format_failure_reason(%{type: :error, reason: :timeout}, config),
    do: "Timed out after #{config.defaults.timeout_minutes} minutes"

  defp format_failure_reason(%{type: :error, reason: reason}, _config), do: inspect(reason)

  defp format_failure_reason(%{type: :failure, result: result}, _config),
    do: truncate(result.result, 500) || "Unknown failure"

  defp format_failure_reason(_, _config), do: "Unknown error — no result data captured"

  defp format_knowledge_lines(entries) do
    entries
    |> Enum.group_by(& &1.topic)
    |> Enum.map_join("\n", fn {topic, topic_entries} ->
      "- #{topic}: #{length(topic_entries)} entries"
    end)
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

  @spec broadcast(atom(), map()) :: :ok
  defp broadcast(type, payload) do
    Cortex.Events.broadcast(type, payload)
    :ok
  rescue
    _ -> :ok
  end
end
