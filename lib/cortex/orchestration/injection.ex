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

  Delegates to `Cortex.Coordinator.Prompt.build/3`.
  """
  @spec build_coordinator_prompt(Config.t(), [[String.t()]], String.t()) :: String.t()
  def build_coordinator_prompt(%Config{} = config, tiers, workspace_path) do
    Cortex.Coordinator.Prompt.build(config, tiers, workspace_path)
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
