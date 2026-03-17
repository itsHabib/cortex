defmodule Cortex.Mesh.Coordinator.Prompt do
  @moduledoc """
  Builds the prompt for a mesh-mode coordinator agent.

  The mesh coordinator is a lightweight observer that watches autonomous
  agents work. Unlike the gossip coordinator (which actively synthesizes
  and steers), the mesh coordinator stays hands-off unless it detects
  problems — agents are autonomous by design.

  Its main jobs:
  1. Monitor progress via log files and outboxes
  2. Detect issues (stalls, failures, conflicts)
  3. Write status summaries to `.cortex/summaries/`
  4. Relay messages between agents only when asked
  5. Answer status queries from its inbox
  """

  alias Cortex.Mesh.Config, as: MeshConfig
  alias Cortex.Messaging.InboxBridge

  @doc """
  Builds the mesh coordinator prompt.

  ## Parameters

    - `config` — the `%MeshConfig{}` struct
    - `workspace_path` — the project root directory (`.cortex/` lives here)
    - `roster` — list of `%{name, role, state}` maps from MemberList

  ## Returns

  A prompt string for the coordinator's `claude -p` session.
  """
  @spec build(MeshConfig.t(), String.t(), [map()]) :: String.t()
  def build(%MeshConfig{} = config, workspace_path, roster) do
    cortex_path = Path.join(workspace_path, ".cortex")
    agent_roster = build_agent_roster(roster)
    cluster_section = build_cluster_section(config.cluster_context)
    inbox_path = InboxBridge.inbox_path(workspace_path, "coordinator")
    outbox_path = InboxBridge.outbox_path(workspace_path, "coordinator")
    logs_dir = Path.join(cortex_path, "logs")
    messages_dir = Path.join(cortex_path, "messages")
    summaries_dir = Path.join(cortex_path, "summaries")

    """
    You are: Mesh Coordinator
    Project: #{config.name}

    ## Your Role
    You are a lightweight coordinator for a mesh of autonomous agents.
    These agents work independently — they do NOT need you to tell them
    what to do. Your job is to observe, report, and intervene only when needed.

    ### 1. Monitor
    Watch agent activity by checking log file sizes and reading outboxes.
    Agents that stop producing log output may be stalled or rate-limited.
    ```
    ls -la #{logs_dir}/
    ```

    ### 2. Detect Issues
    Flag problems when you see them:
    - Agent log stopped growing (possible stall or rate limit)
    - Agent writing error messages to outbox
    - Two agents doing the same work (duplicate effort)
    - Agent asking for help in outbox but nobody responding

    ### 3. Status Summaries
    Write periodic status reports to `#{summaries_dir}/`.
    Create the directory first: `mkdir -p #{summaries_dir}`

    File naming: `<ISO8601_compact>_<event>.md`
    Example: `20260315T230000_status.md`

    Each summary should include:
    - Which agents are active (log growing) vs quiet
    - Token usage (from log file sizes as a proxy)
    - Any issues detected
    - Agent outbox activity (are they communicating?)

    ### 4. Relay Messages
    If an agent writes to their outbox asking for help from another agent
    and it goes unanswered, relay it. But do NOT inject yourself into
    agent-to-agent communication that's working fine.

    ### 5. Answer Queries
    If someone writes to your inbox asking for status, read the latest
    state and respond with a concise report.
    #{cluster_section}
    ## Agents
    #{agent_roster}

    ## Workspace Layout
    Logs dir:    #{logs_dir}/
    Messages:    #{messages_dir}/
    Your inbox:  #{inbox_path}
    Your outbox: #{outbox_path}

    Each agent has:
      - Log: `#{logs_dir}/<agent_name>.log`
      - Inbox: `#{messages_dir}/<agent_name>/inbox.json`
      - Outbox: `#{messages_dir}/<agent_name>/outbox.json`

    ## Message Protocol
    To send a message to an agent, write to your outbox:
    ```json
    [{"from": "coordinator", "to": "<agent_name>", "content": "...", "timestamp": "<ISO8601>"}]
    ```

    ## Inbox Loop
    Set up a poll loop immediately on startup:
    ```
    /loop 30s cat #{inbox_path}
    ```

    Also monitor agent activity:
    ```
    /loop 60s ls -la #{logs_dir}/
    ```
    #{build_outbox_poll_commands(config.agents, messages_dir)}

    ## Important
    - You are an OBSERVER, not a director. Agents are autonomous.
    - Do NOT tell agents what to do unless they are clearly stuck or failing.
    - Do NOT relay messages that agents can handle themselves.
    - Keep summaries concise (under 80 lines).
    - Start your loops IMMEDIATELY on startup.
    """
    |> String.trim()
  end

  @spec build_agent_roster([map()]) :: String.t()
  defp build_agent_roster(roster) do
    roster
    |> Enum.map_join("\n", fn member ->
      "  - **#{member.name}** — #{member.role} (#{member.state})"
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

  @spec build_outbox_poll_commands([MeshConfig.Agent.t()], String.t()) :: String.t()
  defp build_outbox_poll_commands(agents, messages_dir) do
    agents
    |> Enum.map_join("\n", fn agent ->
      outbox = Path.join([messages_dir, agent.name, "outbox.json"])
      "```\n/loop 60s cat #{outbox}\n```"
    end)
  end
end
