defmodule Cortex.Mesh.Prompt do
  @moduledoc """
  Builds agent prompts for mesh mode.

  Each agent gets a prompt containing their role, the cluster context,
  a roster of peers, and messaging instructions. Agents are NOT required
  to coordinate — they message only when they need info from another domain.
  """

  alias Cortex.Mesh.Config, as: MeshConfig
  alias Cortex.Messaging.InboxBridge

  @doc """
  Builds the full prompt for a mesh agent.

  ## Parameters

    - `agent` — the agent's config (`Mesh.Config.Agent`)
    - `config` — the mesh config (`Mesh.Config`)
    - `roster` — list of `%{name, role, state}` maps from MemberList
    - `workspace_path` — the project root directory

  """
  @spec build(MeshConfig.Agent.t(), MeshConfig.t(), [map()], String.t()) :: String.t()
  def build(agent, config, roster, workspace_path) do
    inbox_path = InboxBridge.inbox_path(workspace_path, agent.name)
    outbox_path = InboxBridge.outbox_path(workspace_path, agent.name)

    sections = [
      role_section(agent),
      cluster_section(config, roster),
      assignment_section(agent),
      messaging_section(agent.name, inbox_path, outbox_path, roster),
      autonomy_section()
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  # -- Sections --

  defp role_section(agent) do
    """
    ## Your Identity

    You are **#{agent.name}**, a #{agent.role} in a mesh cluster of autonomous agents.
    """
  end

  defp cluster_section(config, roster) do
    context_block =
      if config.cluster_context do
        """

        ## Cluster Context

        #{String.trim(config.cluster_context)}
        """
      end

    roster_block = build_roster_table(roster)

    [context_block, roster_block]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp build_roster_table([]), do: nil

  defp build_roster_table(roster) do
    header = """

    ## Mesh Roster

    | Agent | Role | Status |
    |-------|------|--------|
    """

    rows =
      Enum.map_join(roster, "\n", fn member ->
        "| #{member.name} | #{member.role} | #{member.state} |"
      end)

    header <> rows <> "\n"
  end

  defp assignment_section(agent) do
    """

    ## Your Assignment

    #{String.trim(agent.prompt)}
    """
  end

  defp messaging_section(agent_name, inbox_path, outbox_path, roster) do
    other_agents =
      roster
      |> Enum.reject(fn m -> m.name == agent_name end)
      |> Enum.map_join("\n", fn m -> "  - **#{m.name}** (#{m.role})" end)

    """

    ## Messaging

    You can communicate with other agents if you need information from their domain.
    You are NOT required to coordinate. Reach out ONLY if you need info from another agent's domain.

    **To send a message**, write a JSON object to your outbox file:
      #{outbox_path}

    Format: append to the JSON array:
    ```json
    {"to": "agent-name", "from": "#{agent_name}", "content": "your message", "timestamp": "ISO8601"}
    ```

    **To receive messages**, check your inbox:
      #{inbox_path}

    Set up a loop to monitor incoming messages:
    /loop 15s cat #{inbox_path}

    **Available agents:**
    #{other_agents}
    """
  end

  defp autonomy_section do
    """

    ## Working Style

    - Work independently on your assignment. Do your own research and produce your own deliverables.
    - Only message another agent if you genuinely need information that falls in their domain.
    - Do NOT wait for messages from others before starting your work.
    - When you are done with your assignment, provide a final summary of your work and finish up.
    """
  end
end
