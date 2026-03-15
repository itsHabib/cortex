defmodule Cortex.Orchestration.Injection do
  @moduledoc """
  Builds rich prompts for each team's `claude -p` session.

  The prompt structure varies based on whether the team is a solo agent
  (no members) or a team lead (has members). Both formats include the
  lead's role, project name, technical context, tasks, upstream results
  from dependencies, and closing instructions. Team lead prompts add
  a "Your Team" section describing the available teammates.
  """

  alias Cortex.Orchestration.Config
  alias Cortex.Orchestration.Config.{Defaults, Team}
  alias Cortex.Orchestration.State

  @doc """
  Constructs the full prompt string for a team's `claude -p` session.

  ## Parameters

    - `team` — a `%Team{}` struct describing the team
    - `project_name` — the project name string
    - `state` — a `%State{}` struct containing upstream team results
    - `defaults` — a `%Defaults{}` struct with fallback settings

  ## Returns

  A string containing the complete prompt with all sections assembled.
  """
  @spec build_prompt(Team.t(), String.t(), State.t(), Defaults.t()) :: String.t()
  def build_prompt(%Team{} = team, project_name, %State{} = state, %Defaults{} = _defaults) do
    sections = [
      build_header(team, project_name),
      build_context_section(team),
      build_team_section(team),
      build_tasks_section(team),
      build_dependencies_section(team, state),
      build_inbox_section(team),
      build_instructions_section()
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Returns the model string for a team.

  Uses the team lead's model if set, otherwise falls back to the
  defaults model.

  ## Parameters

    - `team` — a `%Team{}` struct
    - `defaults` — a `%Defaults{}` struct

  ## Returns

  A model identifier string.
  """
  @spec build_model(Team.t(), Defaults.t()) :: String.t()
  def build_model(%Team{lead: %{model: model}}, %Defaults{}) when is_binary(model), do: model
  def build_model(%Team{}, %Defaults{model: model}), do: model

  @doc """
  Returns the max_turns value from defaults.

  ## Parameters

    - `defaults` — a `%Defaults{}` struct

  ## Returns

  A positive integer.
  """
  @spec build_max_turns(Defaults.t()) :: pos_integer()
  def build_max_turns(%Defaults{max_turns: max_turns}), do: max_turns

  @doc """
  Returns the permission_mode value from defaults.

  ## Parameters

    - `defaults` — a `%Defaults{}` struct

  ## Returns

  A permission mode string.
  """
  @spec build_permission_mode(Defaults.t()) :: String.t()
  def build_permission_mode(%Defaults{permission_mode: permission_mode}), do: permission_mode

  @doc """
  Builds the coordinator agent prompt.

  The coordinator runs alongside all teams, monitors their progress,
  responds to status queries, and acts as a messaging relay. It checks
  its inbox on a fast loop (10s) and reads workspace state files to
  produce ground-truth health reports.

  ## Parameters

    - `config` — the full `%Config{}` struct with all team definitions
    - `tiers` — the DAG tiers as `[[team_name]]`
    - `workspace_path` — the `.cortex/` workspace directory path

  ## Returns

  A prompt string for the coordinator's `claude -p` session.
  """
  @spec build_coordinator_prompt(Config.t(), [[String.t()]], String.t()) :: String.t()
  def build_coordinator_prompt(%Config{} = config, tiers, workspace_path) do
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

    ## Important
    - You are stateless — if restarted, re-read state files to catch up
    - Do NOT modify state.json or registry.json — those are owned by the orchestrator
    - Do NOT do the teams' work — only observe, coordinate, and communicate
    - Keep responses concise — you're a monitoring agent, not a writer
    - Start your inbox loop IMMEDIATELY on startup, before anything else
    """
    |> String.trim()
  end

  defp build_team_roster(teams, tiers) do
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

  # --- Private section builders ---

  defp build_header(%Team{lead: lead}, project_name) do
    "You are: #{lead.role}\nProject: #{project_name}"
  end

  defp build_context_section(%Team{context: nil}), do: nil
  defp build_context_section(%Team{context: ""}), do: nil

  defp build_context_section(%Team{context: context}) do
    "## Technical Context\n#{String.trim(context)}"
  end

  defp build_team_section(%Team{members: []}), do: nil
  defp build_team_section(%Team{members: nil}), do: nil

  defp build_team_section(%Team{members: members}) do
    member_lines =
      Enum.map(members, fn member ->
        "- **#{member.role}**: #{member.focus || "general"}"
      end)

    header =
      "## Your Team\nYou are the team lead. You have the following teammates:"

    body = Enum.join(member_lines, "\n")

    "#{header}\n#{body}\n\nCoordinate your team to accomplish the tasks below. Delegate appropriately based on each member's focus area."
  end

  defp build_tasks_section(%Team{tasks: tasks}) do
    task_blocks =
      Enum.map(tasks, fn task ->
        lines = ["### Task: #{task.summary}"]

        lines =
          if task.details && task.details != "" do
            lines ++ [task.details |> String.trim()]
          else
            lines
          end

        lines =
          if task.deliverables && task.deliverables != [] do
            lines ++ ["Deliverables: #{Enum.join(task.deliverables, ", ")}"]
          else
            lines
          end

        lines =
          if task.verify && task.verify != "" do
            lines ++ ["Verify: #{task.verify}"]
          else
            lines
          end

        Enum.join(lines, "\n")
      end)

    "## Your Tasks\n#{Enum.join(task_blocks, "\n\n")}"
  end

  defp build_dependencies_section(%Team{depends_on: []}, _state) do
    "## Context from Previous Teams\nNo previous team results available."
  end

  defp build_dependencies_section(%Team{depends_on: nil}, _state) do
    "## Context from Previous Teams\nNo previous team results available."
  end

  defp build_dependencies_section(%Team{depends_on: deps}, %State{teams: teams}) do
    completed =
      deps
      |> Enum.filter(fn dep ->
        case Map.get(teams, dep) do
          %{status: "done"} -> true
          _ -> false
        end
      end)
      |> Enum.map(fn dep ->
        team_state = Map.fetch!(teams, dep)
        "### #{dep}\n#{team_state.result_summary || "No summary available."}"
      end)

    if completed == [] do
      "## Context from Previous Teams\nNo previous team results available."
    else
      "## Context from Previous Teams\n#{Enum.join(completed, "\n\n")}"
    end
  end

  defp build_inbox_section(%Team{name: name, members: members}) do
    team_lead_extra =
      if has_members?(members) do
        "\nAs team lead, check your inbox more frequently for coordination messages.\n" <>
          "The coordinator may send corrections, priority changes, or answers to questions."
      else
        ""
      end

    """
    ## Message Inbox
    You have a message inbox that the coordinator and other teams can write to.
    Check it periodically for guidance, corrections, or additional context.

    Your inbox file: .cortex/messages/#{name}/inbox.json
    Your outbox file: .cortex/messages/#{name}/outbox.json

    To check your inbox, set up a loop:
    /loop 2m cat .cortex/messages/#{name}/inbox.json

    If you see new messages, read them and adjust your work accordingly.

    To send a message to the coordinator or another team, append to your outbox:
    Write a JSON message to .cortex/messages/#{name}/outbox.json

    Format: [{"from": "#{name}", "to": "coordinator", "content": "your message", "timestamp": "<ISO8601>"}]\
    """
    |> String.trim()
    |> Kernel.<>(team_lead_extra)
  end

  defp has_members?(nil), do: false
  defp has_members?([]), do: false
  defp has_members?(_members), do: true

  defp build_instructions_section do
    "## Instructions\n" <>
      "Work through your tasks in order. After completing each task, run the verify command " <>
      "to confirm it works. When all tasks are complete, provide a summary of what you " <>
      "accomplished and which files you created or modified."
  end
end
