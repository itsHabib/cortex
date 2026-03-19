defmodule CortexWeb.WorkflowsLive.Templates do
  @moduledoc """
  Quick-start YAML templates for workflow composition.

  Provides one starter template per coordination mode (DAG, Mesh, Gossip)
  to give users a working example to modify rather than starting from scratch.
  """

  @dag_template """
  name: my-project
  defaults:
    model: sonnet
    max_turns: 200
    timeout_minutes: 30
  teams:
    - name: backend
      lead:
        role: Backend Developer
      tasks:
        - summary: Build the API layer
          instructions: |
            Implement REST endpoints for the core resources.
    - name: frontend
      lead:
        role: Frontend Developer
      depends_on:
        - backend
      tasks:
        - summary: Build the UI
          instructions: |
            Create a web interface consuming the backend API.
  """

  @mesh_template """
  name: my-mesh-project
  mode: mesh
  defaults:
    model: sonnet
    max_turns: 200
    timeout_minutes: 30
  mesh:
    heartbeat_interval_seconds: 30
    suspect_timeout_seconds: 90
    dead_timeout_seconds: 180
  agents:
    - name: alpha
      role: Coordinator
      prompt: You coordinate the team effort.
    - name: beta
      role: Implementer
      prompt: You implement features as directed.
    - name: gamma
      role: Reviewer
      prompt: You review code for quality and correctness.
  """

  @gossip_template """
  name: my-gossip-project
  mode: gossip
  defaults:
    model: sonnet
    max_turns: 200
    timeout_minutes: 30
  gossip:
    rounds: 5
    topology: random
    exchange_interval_seconds: 60
  agents:
    - name: researcher
      topic: research
      prompt: You research the problem domain and share findings.
    - name: analyst
      topic: analysis
      prompt: You analyze research findings and synthesize insights.
    - name: writer
      topic: writing
      prompt: You write documentation based on analysis.
  seed_knowledge:
    - topic: research
      content: "Project goal: explore the problem space."
  """

  @doc """
  Returns the list of available template descriptors.

  Each descriptor is a map with `:id`, `:name`, `:mode`, and `:description`.
  """
  @spec list() :: [map()]
  def list do
    [
      %{
        id: "dag_starter",
        name: "DAG Workflow Starter",
        mode: "dag",
        description: "Two-team pipeline with backend and frontend"
      },
      %{
        id: "mesh_starter",
        name: "Mesh Starter",
        mode: "mesh",
        description: "Three-agent mesh with SWIM failure detection"
      },
      %{
        id: "gossip_starter",
        name: "Gossip Starter",
        mode: "gossip",
        description: "Three-agent gossip protocol with knowledge exchange"
      }
    ]
  end

  @doc """
  Returns the YAML content for a template by ID.

  Returns `nil` if the template ID is not recognized.
  """
  @spec get(String.t()) :: String.t() | nil
  def get("dag_starter"), do: @dag_template
  def get("mesh_starter"), do: @mesh_template
  def get("gossip_starter"), do: @gossip_template
  def get(_), do: nil

  @doc """
  Returns the mode string for a given template ID.
  """
  @spec mode_for(String.t()) :: String.t() | nil
  def mode_for("dag_starter"), do: "dag"
  def mode_for("mesh_starter"), do: "mesh"
  def mode_for("gossip_starter"), do: "gossip"
  def mode_for(_), do: nil
end
