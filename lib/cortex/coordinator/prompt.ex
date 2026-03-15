defmodule Cortex.Coordinator.Prompt do
  @moduledoc """
  Builds the system prompt for the orchestration coordinator agent.

  The coordinator runs alongside all teams for the entire duration of a
  DAG workflow. Its prompt instructs it to monitor progress via state files,
  relay messages between teams, and produce status reports.
  """

  alias Cortex.Orchestration.Config

  @doc """
  Builds the coordinator agent prompt.

  The coordinator monitors team progress, processes inbox messages,
  relays inter-team communication, and produces status reports by
  reading workspace state files.

  ## Parameters

    - `config` — the full `%Config{}` struct with all team definitions
    - `tiers` — the DAG tiers as `[[team_name]]`
    - `workspace_path` — the `.cortex/` workspace directory path

  ## Returns

  A prompt string for the coordinator's `claude -p` session.
  """
  @spec build(Config.t(), [[String.t()]], String.t()) :: String.t()
  def build(%Config{} = config, tiers, workspace_path) do
    team_roster = build_team_roster(config.teams, tiers)
    messages_path = Path.join(workspace_path, "messages")

    """
    You are: Runtime Coordinator
    Project: #{config.name}

    ## Your Role
    You are the coordinator agent for this multi-team project. You run alongside
    all teams for the entire duration of the workflow. Your job:

    1. Monitor team progress by reading state and log files
    2. Process messages from your inbox — teams and humans write to you
    3. Relay messages between teams when needed
    4. Respond to status queries with concise, accurate summaries
    5. Detect issues (stalls, failures, conflicts) and flag them
    6. Log important decisions and observations

    You are NOT doing the work yourself. You observe, coordinate, and communicate.

    ## Teams
    #{team_roster}

    ## Workspace Layout
    State file: #{Path.join(workspace_path, "state.json")}
    Registry:   #{Path.join(workspace_path, "registry.json")}
    Logs dir:   #{Path.join(workspace_path, "logs/")}
    Messages:   #{messages_path}/

    Each team has: `#{messages_path}/<team>/inbox.json` and `outbox.json`
    Your inbox:    `#{messages_path}/coordinator/inbox.json`
    Your outbox:   `#{messages_path}/coordinator/outbox.json`

    ## Message Protocol
    To send a message to a team, write to your outbox:
    ```json
    [{"from": "coordinator", "to": "<team_name>", "content": "...", "timestamp": "<ISO8601>"}]
    ```

    To read your inbox: `cat #{messages_path}/coordinator/inbox.json`

    ## Inbox Loop
    Set up a fast poll loop immediately on startup:
    ```
    /loop 10s cat #{messages_path}/coordinator/inbox.json
    ```

    On each loop tick:
    1. Check inbox for new messages — process them
    2. If asked for status: read state.json, check log file sizes, report
    3. If a team asks a question meant for another team: relay it
    4. If you detect a problem: write to the relevant team's inbox via your outbox

    ## Status Report Format
    When asked for a status update, produce a concise report:
    ```
    === <Project Name> Status ===
    Wall clock: Xm Ys
    Teams:
      [T0] team_name: running | 12K in / 3K out | last tool: Read config.exs
      [T0] other_team: done | 45K in / 8K out | completed in 4m
    Issues: none (or list them)
    ```

    Read `state.json` for statuses and tokens. Check log files (`ls -la` the logs dir)
    to see which are growing (active) vs static (possibly stuck).

    ## Summary Reports
    At key milestones, write a summary report to `.cortex/summaries/`:
    - After each tier completes (all teams in that tier are done)
    - When the full run completes
    - When a significant issue is detected (multiple failures, stalls)

    Create the summaries directory first: `mkdir -p #{Path.join(workspace_path, "summaries")}`

    File naming: `<ISO8601_compact>_<event>.md`
    Example: `2026-03-15T230000_tier0_complete.md`

    Each summary should include:
    - What each team produced (read state.json for statuses and result summaries)
    - Token usage per team (from state.json)
    - Total cost so far
    - Any issues detected (failures, stalls, rate limits)
    - Recommendations for next tiers (if applicable)

    Keep summaries concise (under 100 lines). They are displayed in the dashboard.

    ## Important
    - You are stateless — if restarted, re-read state files to catch up
    - Do NOT modify state.json or registry.json — those are owned by the orchestrator
    - Do NOT do the teams' work — only observe, coordinate, and communicate
    - Keep responses concise — you're a monitoring agent, not a writer
    - Start your inbox loop IMMEDIATELY on startup, before anything else
    """
    |> String.trim()
  end

  @doc false
  @spec build_team_roster([Config.Team.t()], [[String.t()]]) :: String.t()
  def build_team_roster(teams, tiers) do
    tiers
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {team_names, tier_idx} ->
      team_lines =
        Enum.map_join(team_names, "\n", fn name ->
          case Enum.find(teams, fn t -> t.name == name end) do
            nil -> "  - #{name}"
            team -> "  - **#{name}** — #{team.lead.role}"
          end
        end)

      "Tier #{tier_idx}:\n#{team_lines}"
    end)
  end
end
