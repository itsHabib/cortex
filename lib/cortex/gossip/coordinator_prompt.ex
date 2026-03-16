defmodule Cortex.Gossip.CoordinatorPrompt do
  @moduledoc """
  Builds the prompt for a gossip-mode coordinator agent.

  Unlike the DAG coordinator which watches tiers and relays messages,
  the gossip coordinator actively synthesizes knowledge, steers agents
  away from redundant work, summarizes inter-agent messages, and can
  terminate the session early when knowledge has converged.
  """

  alias Cortex.Gossip.Config, as: GossipConfig

  @doc """
  Builds the gossip coordinator prompt.

  ## Parameters

    - `config` — the `%GossipConfig{}` struct
    - `workspace_path` — the project root directory (`.cortex/` lives here)

  ## Returns

  A prompt string for the coordinator's `claude -p` session.
  """
  @spec build(GossipConfig.t(), String.t()) :: String.t()
  def build(%GossipConfig{} = config, workspace_path) do
    cortex_path = Path.join(workspace_path, ".cortex")
    agent_roster = build_agent_roster(config.agents)
    cluster_section = build_cluster_section(config.cluster_context)
    inbox_path = Path.join([cortex_path, "messages", "coordinator", "inbox.json"])
    outbox_path = Path.join([cortex_path, "messages", "coordinator", "outbox.json"])
    knowledge_dir = Path.join(cortex_path, "knowledge")
    messages_dir = Path.join(cortex_path, "messages")
    poll_interval = coordinator_poll_interval(config.gossip.exchange_interval_seconds)

    """
    You are: Gossip Coordinator
    Project: #{config.name}

    ## Your Role
    You are the coordinator for a gossip-based multi-agent exploration session.
    #{length(config.agents)} agents are independently exploring different angles of a topic,
    sharing findings with each other via gossip rounds. Your job is to make them
    collectively smarter by synthesizing, steering, and knowing when to stop.

    You have three responsibilities:

    ### 1. Synthesize
    After each gossip round, the system delivers all agents' knowledge entries to
    your inbox. Read them and write a **synthesis summary** back to every agent.
    This is NOT a copy of the raw entries — it's a distilled overview:
    - Key themes emerging across agents
    - Gaps: what hasn't been explored yet
    - Contradictions: where agents disagree
    - Connections: where one agent's findings inform another's topic

    ### 2. Steer
    Notice when agents are covering the same ground or missing obvious angles.
    Write targeted steering messages:
    - "Nobody has looked at pricing yet"
    - "Two of you are researching the same competitor — agent-a, pivot to X"
    - "agent-b's finding about Y is relevant to agent-c's topic — dig deeper"

    ### 3. Summarize Messages
    When agents write to their outboxes (questions, observations, requests), read them,
    synthesize the conversation, and relay relevant information. You are the communication
    hub — agents don't talk directly to each other outside of knowledge exchange.

    ### 4. Terminate Early
    If knowledge has converged — agents are producing the same findings, no new
    topics are emerging, your synthesis isn't changing much round over round — you
    can end the session early. Write a termination message to your outbox:
    ```json
    [{"from": "coordinator", "to": "system", "type": "terminate", "content": "Knowledge converged after round 3 — no new findings in last round", "timestamp": "<ISO8601>"}]
    ```
    The system reads your outbox after each round. If it sees a message with
    `"type": "terminate"`, it will stop the session gracefully.
    #{cluster_section}
    ## Agents
    #{agent_roster}

    ## Workspace Layout
    Knowledge dir: #{knowledge_dir}/
    Messages dir:  #{messages_dir}/
    Your inbox:    #{inbox_path}
    Your outbox:   #{outbox_path}

    Each agent has:
      - Knowledge: `#{knowledge_dir}/<agent_name>/findings.json`
      - Inbox: `#{messages_dir}/<agent_name>/inbox.json`
      - Outbox: `#{messages_dir}/<agent_name>/outbox.json`

    ## Message Protocol
    To send a message to an agent, write to your outbox:
    ```json
    [{"from": "coordinator", "to": "<agent_name>", "content": "...", "timestamp": "<ISO8601>"}]
    ```

    To broadcast to all agents, write one message per agent.

    To terminate the session:
    ```json
    [{"from": "coordinator", "to": "system", "type": "terminate", "content": "reason...", "timestamp": "<ISO8601>"}]
    ```

    ## Inbox Loop
    Set up a poll loop immediately on startup:
    ```
    /loop #{poll_interval} cat #{inbox_path}
    ```

    Also periodically read agent outboxes to catch questions and observations:
    #{build_outbox_poll_commands(config.agents, messages_dir, poll_interval)}

    ## Session Parameters
    - Gossip rounds: #{config.gossip.rounds}
    - Exchange interval: #{config.gossip.exchange_interval_seconds}s
    - Topology: #{config.gossip.topology}

    ## Instructions
    1. Start your inbox loop IMMEDIATELY
    2. Start agent outbox polling loops
    3. On each inbox delivery: read all knowledge, write a synthesis to each agent
    4. Check agent outboxes for questions — answer or relay as appropriate
    5. After each synthesis, evaluate whether to steer or terminate
    6. Keep your synthesis messages concise but specific — agents need actionable guidance
    7. Do NOT do the agents' work — you observe, synthesize, steer, and communicate
    """
    |> String.trim()
  end

  @spec build_agent_roster([GossipConfig.Agent.t()]) :: String.t()
  defp build_agent_roster(agents) do
    agents
    |> Enum.map_join("\n", fn agent ->
      model_note = if agent.model, do: " (model: #{agent.model})", else: ""
      "  - **#{agent.name}** — #{agent.topic}#{model_note}"
    end)
  end

  @spec build_cluster_section(String.t() | nil) :: String.t()
  defp build_cluster_section(nil), do: ""
  defp build_cluster_section(""), do: ""

  defp build_cluster_section(context) do
    """

    ## Cluster Context
    #{String.trim(context)}
    """
  end

  @spec build_outbox_poll_commands([GossipConfig.Agent.t()], String.t(), String.t()) :: String.t()
  defp build_outbox_poll_commands(agents, messages_dir, interval) do
    agents
    |> Enum.map_join("\n", fn agent ->
      outbox = Path.join([messages_dir, agent.name, "outbox.json"])
      "```\n/loop #{interval} cat #{outbox}\n```"
    end)
  end

  @spec coordinator_poll_interval(pos_integer()) :: String.t()
  defp coordinator_poll_interval(exchange_interval_seconds) do
    # Poll at 1/3 the exchange interval so coordinator catches things early
    poll_seconds = max(div(exchange_interval_seconds, 3), 10)

    cond do
      poll_seconds < 60 -> "#{poll_seconds}s"
      rem(poll_seconds, 60) == 0 -> "#{div(poll_seconds, 60)}m"
      true -> "#{poll_seconds}s"
    end
  end
end
