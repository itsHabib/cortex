defmodule CortexWeb.WorkflowsLive.DAGPanel do
  @moduledoc """
  DAG-specific configuration panel for the Workflows page.

  Provides the YAML editor panel for DAG mode and the visual team builder
  for composing DAG workflows with dependency management.
  """
  use Phoenix.Component

  # -- YAML Panel --

  @doc """
  Renders the DAG YAML editor panel with mode-specific placeholder.
  """
  attr(:yaml_content, :string, required: true)
  attr(:file_path, :string, required: true)
  attr(:workspace_path, :string, required: true)
  attr(:provider, :string, default: "cli")
  attr(:backend, :string, default: "local")
  attr(:templates, :list, default: [])

  def yaml_panel(assigns) do
    dag_templates = Enum.filter(assigns.templates, &(&1.mode == "dag"))
    assigns = assign(assigns, :dag_templates, dag_templates)

    ~H"""
    <div class="space-y-4">
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">DAG Workflow YAML</h3>
          <%= if @dag_templates != [] do %>
            <div class="flex items-center gap-2">
              <span class="text-xs text-gray-500">Template:</span>
              <button
                :for={t <- @dag_templates}
                phx-click="load_template"
                phx-value-template={t.id}
                class="text-xs text-cortex-400 hover:text-cortex-300 underline"
              >
                {t.name}
              </button>
            </div>
          <% end %>
        </div>
        <textarea
          name="yaml"
          rows="16"
          class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-cortex-500 focus:border-cortex-500 resize-y"
          placeholder={"name: my-project\ndefaults:\n  model: sonnet\n  max_turns: 200\nteams:\n  - name: backend\n    lead:\n      role: Backend Developer\n    tasks:\n      - summary: Build API"}
        ><%= @yaml_content %></textarea>
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Or Load From File</h3>
        <input
          type="text"
          name="path"
          value={@file_path}
          class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-cortex-500 focus:border-cortex-500"
          placeholder="/path/to/orchestra.yaml"
        />
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Workspace Path</h3>
        <p class="text-xs text-gray-500 mb-2">Where agents write files. Set here OR in YAML, not both.</p>
        <input
          type="text"
          name="workspace_path"
          value={@workspace_path}
          class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-cortex-500 focus:border-cortex-500"
          placeholder="/path/to/project (default: /tmp)"
        />
      </div>

      <.execution_settings provider={@provider} backend={@backend} />
    </div>
    """
  end

  # -- Visual Panel --

  @doc """
  Renders the DAG visual team builder for composing workflows
  with dependency management.
  """
  attr(:dag_teams, :list, required: true)
  attr(:project_name, :string, required: true)
  attr(:workspace_path, :string, required: true)
  attr(:model, :string, required: true)
  attr(:max_turns, :integer, required: true)
  attr(:available_agents, :list, default: [])
  attr(:selected_agents, :list, default: [])
  attr(:agent_filter, :string, default: "")

  def visual_panel(assigns) do
    all_team_names = Enum.map(assigns.dag_teams, & &1.name)
    assigns = assign(assigns, :all_team_names, all_team_names)

    ~H"""
    <div class="space-y-4">
      <%!-- Project config --%>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 space-y-4">
        <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Project Settings</h3>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <label class="text-xs text-gray-500 block mb-1">Project Name</label>
            <input
              type="text"
              name="project_name"
              value={@project_name}
              class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
              placeholder="my-project"
            />
          </div>
          <div>
            <label class="text-xs text-gray-500 block mb-1">Model</label>
            <select
              name="model"
              class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
            >
              <option value="sonnet" selected={@model == "sonnet"}>Sonnet</option>
              <option value="opus" selected={@model == "opus"}>Opus</option>
              <option value="haiku" selected={@model == "haiku"}>Haiku</option>
            </select>
          </div>
          <div>
            <label class="text-xs text-gray-500 block mb-1">Max Turns</label>
            <input
              type="number"
              name="max_turns"
              value={@max_turns}
              class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
            />
          </div>
          <div>
            <label class="text-xs text-gray-500 block mb-1">Workspace Path</label>
            <input
              type="text"
              name="workspace_path"
              value={@workspace_path}
              class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
              placeholder="/path/to/project"
            />
          </div>
        </div>
      </div>

      <%!-- Teams --%>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 space-y-4">
        <div class="flex items-center justify-between">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Teams</h3>
          <button
            type="button"
            phx-click="add_dag_team"
            class="text-xs bg-gray-800 text-gray-300 px-3 py-1.5 rounded hover:bg-gray-700"
          >
            + Add Team
          </button>
        </div>

        <%= if @dag_teams == [] do %>
          <p class="text-gray-500 text-sm text-center py-6">
            No teams yet. Click "Add Team" to start building your DAG workflow.
          </p>
        <% end %>

        <div :for={{team, idx} <- Enum.with_index(@dag_teams)} class="bg-gray-950 rounded-lg border border-gray-800 p-4 space-y-3">
          <div class="flex items-center justify-between">
            <span class="text-sm font-medium text-white">Team {idx + 1}</span>
            <button
              type="button"
              phx-click="remove_dag_team"
              phx-value-name={team.name}
              class="text-xs text-red-400 hover:text-red-300"
            >
              Remove
            </button>
          </div>

          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="text-xs text-gray-500 block mb-1">Team Name</label>
              <input
                type="text"
                name={"team_name_#{idx}"}
                value={team.name}
                phx-blur="update_dag_team"
                phx-value-index={idx}
                phx-value-field="name"
                class="w-full bg-gray-900 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
                placeholder="team-name"
              />
            </div>
            <div>
              <label class="text-xs text-gray-500 block mb-1">Lead Role</label>
              <input
                type="text"
                name={"team_role_#{idx}"}
                value={team.lead_role}
                phx-blur="update_dag_team"
                phx-value-index={idx}
                phx-value-field="lead_role"
                class="w-full bg-gray-900 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
                placeholder="Backend Developer"
              />
            </div>
          </div>

          <div>
            <label class="text-xs text-gray-500 block mb-1">Task Summary</label>
            <input
              type="text"
              name={"team_task_#{idx}"}
              value={team.task_summary}
              phx-blur="update_dag_team"
              phx-value-index={idx}
              phx-value-field="task_summary"
              class="w-full bg-gray-900 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
              placeholder="What should this team accomplish?"
            />
          </div>

          <div>
            <label class="text-xs text-gray-500 block mb-1">Depends On</label>
            <div class="flex flex-wrap gap-2">
              <button
                :for={other <- @all_team_names}
                :if={other != team.name && other != ""}
                type="button"
                phx-click="toggle_dag_dependency"
                phx-value-team={team.name}
                phx-value-dep={other}
                class={[
                  "text-xs px-2 py-1 rounded border transition-colors",
                  if(other in team.depends_on,
                    do: "bg-cortex-900/50 text-cortex-300 border-cortex-700",
                    else: "bg-gray-900 text-gray-400 border-gray-700 hover:border-gray-600"
                  )
                ]}
              >
                {other}
              </button>
              <span :if={Enum.count(@all_team_names, &(&1 != team.name && &1 != "")) == 0} class="text-xs text-gray-600">
                Add more teams to set dependencies
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Config Preview --

  @doc """
  Renders a DAG-specific config preview.
  """
  attr(:config, :map, required: true)

  def config_preview(assigns) do
    ~H"""
    <div class="space-y-2">
      <div>
        <span class="text-sm text-gray-500">Project:</span>
        <span class="text-sm text-white ml-2">{@config.name}</span>
      </div>
      <div>
        <span class="text-sm text-gray-500">Teams:</span>
        <span class="text-sm text-white ml-2">{length(@config.teams)}</span>
      </div>
      <div>
        <span class="text-sm text-gray-500">Model:</span>
        <span class="text-sm text-white ml-2">{@config.defaults.model}</span>
      </div>
      <div>
        <span class="text-sm text-gray-500">Provider:</span>
        <span class="text-sm text-white ml-2">{@config.defaults.provider}</span>
      </div>
      <div>
        <span class="text-sm text-gray-500">Backend:</span>
        <span class="text-sm text-white ml-2">{@config.defaults.backend}</span>
      </div>
      <div class="pt-2">
        <span class="text-sm text-gray-500">Team Names:</span>
        <div class="flex flex-wrap gap-2 mt-1">
          <span
            :for={team <- @config.teams}
            class="inline-flex items-center rounded-full bg-gray-800 px-2.5 py-0.5 text-xs font-medium text-gray-300"
          >
            {team.name}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # -- Execution Settings (shared across modes) --

  @doc """
  Provider and backend dropdowns for controlling how agents execute.
  """
  attr(:provider, :string, default: "cli")
  attr(:backend, :string, default: "local")
  attr(:docker_debug, :boolean, default: false)

  def execution_settings(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
      <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Execution</h3>
      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="text-xs text-gray-500 block mb-1">Provider</label>
          <select
            name="provider"
            class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
          >
            <option value="cli" selected={@provider == "cli"}>CLI (local claude -p)</option>
            <option value="external" selected={@provider == "external"}>External (sidecar + worker)</option>
          </select>
        </div>
        <div>
          <label class="text-xs text-gray-500 block mb-1">Backend</label>
          <select
            name="backend"
            class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
          >
            <option value="local" selected={@backend == "local"}>Local</option>
            <option value="docker" selected={@backend == "docker"}>Docker</option>
            <option value="k8s" selected={@backend == "k8s"}>Kubernetes</option>
          </select>
        </div>
      </div>
      <%= if @backend == "docker" do %>
        <label class="flex items-center gap-2 mt-3 cursor-pointer">
          <input
            type="checkbox"
            name="docker_debug"
            value="true"
            checked={@docker_debug}
            class="rounded border-gray-600 bg-gray-950 text-blue-500 focus:ring-blue-500"
          />
          <span class="text-xs text-gray-400">Debug mode — preserve containers after run for inspection</span>
        </label>
      <% end %>
      <p class="text-xs text-gray-600 mt-2">Docker and Kubernetes backends require provider "External".</p>
    </div>
    """
  end

  # -- YAML Generation --

  @doc """
  Generates YAML from the visual DAG builder state.
  """
  @spec generate_yaml(map()) :: String.t()
  def generate_yaml(assigns) do
    teams_yaml =
      assigns.dag_teams
      |> Enum.filter(&(&1.name != ""))
      |> Enum.map_join("\n", fn team ->
        deps =
          if team.depends_on != [] do
            dep_list = Enum.map_join(team.depends_on, "\n", &"        - #{&1}")
            "\n      depends_on:\n#{dep_list}"
          else
            ""
          end

        task =
          if team.task_summary != "" do
            "\n      tasks:\n        - summary: #{team.task_summary}"
          else
            ""
          end

        "    - name: #{team.name}\n      lead:\n        role: #{team.lead_role}#{task}#{deps}"
      end)

    workspace =
      if assigns.workspace_path != "" do
        "\n  workspace_path: #{assigns.workspace_path}"
      else
        ""
      end

    provider_backend =
      case {assigns[:provider], assigns[:backend]} do
        {"cli", "local"} -> ""
        {p, b} when is_binary(p) and is_binary(b) -> "\n  provider: #{p}\n  backend: #{b}"
        _ -> ""
      end

    """
    name: #{assigns.project_name}
    defaults:
      model: #{assigns.model}
      max_turns: #{assigns.max_turns}#{provider_backend}#{workspace}
    teams:
    #{teams_yaml}
    """
    |> String.trim()
  end
end
