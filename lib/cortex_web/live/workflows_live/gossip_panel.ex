defmodule CortexWeb.WorkflowsLive.GossipPanel do
  @moduledoc """
  Gossip-specific configuration panel for the Workflows page.

  Provides the YAML editor panel for Gossip mode and the visual
  configuration form for gossip settings (rounds, topology, etc.).
  """
  use Phoenix.Component

  # -- YAML Panel --

  @doc """
  Renders the Gossip YAML editor panel with mode-specific placeholder.
  """
  attr(:yaml_content, :string, required: true)
  attr(:file_path, :string, required: true)
  attr(:workspace_path, :string, required: true)
  attr(:provider, :string, default: "cli")
  attr(:backend, :string, default: "local")
  attr(:templates, :list, default: [])

  def yaml_panel(assigns) do
    gossip_templates = Enum.filter(assigns.templates, &(&1.mode == "gossip"))
    assigns = assign(assigns, :gossip_templates, gossip_templates)

    ~H"""
    <div class="space-y-4">
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Gossip Config YAML</h3>
          <%= if @gossip_templates != [] do %>
            <div class="flex items-center gap-2">
              <span class="text-xs text-gray-500">Template:</span>
              <button
                :for={t <- @gossip_templates}
                phx-click="load_template"
                phx-value-template={t.id}
                class="text-xs text-purple-400 hover:text-purple-300 underline"
              >
                {t.name}
              </button>
            </div>
          <% end %>
        </div>
        <textarea
          name="yaml"
          rows="16"
          class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-purple-500 focus:border-purple-500 resize-y"
          placeholder={"name: my-gossip\nmode: gossip\ndefaults:\n  model: sonnet\ngossip:\n  rounds: 5\n  topology: random\nagents:\n  - name: researcher\n    topic: research"}
        ><%= @yaml_content %></textarea>
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Or Load From File</h3>
        <input
          type="text"
          name="path"
          value={@file_path}
          class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-purple-500 focus:border-purple-500"
          placeholder="/path/to/gossip.yaml"
        />
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Workspace Path</h3>
        <p class="text-xs text-gray-500 mb-2">Where agents write files. Defaults to a temp directory.</p>
        <input
          type="text"
          name="workspace_path"
          value={@workspace_path}
          class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-purple-500 focus:border-purple-500"
          placeholder="/path/to/project (default: /tmp)"
        />
      </div>

      <CortexWeb.WorkflowsLive.DAGPanel.execution_settings provider={@provider} backend={@backend} />
    </div>
    """
  end

  # -- Visual Panel --

  @doc """
  Renders the Gossip visual config panel with settings for
  rounds, topology, exchange interval, and agent selection.
  """
  attr(:gossip_settings, :map, required: true)
  attr(:project_name, :string, required: true)
  attr(:workspace_path, :string, required: true)
  attr(:model, :string, required: true)
  attr(:max_turns, :integer, required: true)
  attr(:cluster_context, :string, default: "")
  attr(:seed_knowledge, :list, default: [])
  attr(:gossip_agents, :list, default: [])
  attr(:available_agents, :list, default: [])
  attr(:agent_filter, :string, default: "")

  def visual_panel(assigns) do
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
              placeholder="my-gossip-project"
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

      <%!-- Gossip settings --%>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 space-y-4">
        <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Gossip Settings</h3>
        <div class="grid grid-cols-3 gap-4">
          <div>
            <label class="text-xs text-gray-500 block mb-1">Rounds</label>
            <input
              type="number"
              name="gossip_rounds"
              value={@gossip_settings.rounds}
              class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
            />
          </div>
          <div>
            <label class="text-xs text-gray-500 block mb-1">Topology</label>
            <select
              name="gossip_topology"
              class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
            >
              <option value="random" selected={to_string(@gossip_settings.topology) == "random"}>Random</option>
              <option value="full_mesh" selected={to_string(@gossip_settings.topology) == "full_mesh"}>Full Mesh</option>
              <option value="ring" selected={to_string(@gossip_settings.topology) == "ring"}>Ring</option>
            </select>
          </div>
          <div>
            <label class="text-xs text-gray-500 block mb-1">Exchange Interval (s)</label>
            <input
              type="number"
              name="gossip_interval"
              value={@gossip_settings.interval}
              class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm text-gray-300"
            />
          </div>
        </div>
        <div>
          <label class="text-xs text-gray-500 block mb-1">Cluster Context</label>
          <textarea
            name="cluster_context"
            rows="3"
            class="w-full bg-gray-950 border border-gray-700 rounded px-3 py-2 text-sm font-mono text-gray-300 resize-y"
            placeholder="Shared context for all agents..."
          ><%= @cluster_context %></textarea>
        </div>
      </div>

      <%!-- Agents --%>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 space-y-4">
        <div class="flex items-center justify-between">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Agents</h3>
          <button
            type="button"
            phx-click="add_gossip_agent"
            class="text-xs bg-gray-800 text-gray-300 px-3 py-1.5 rounded hover:bg-gray-700"
          >
            + Add Agent
          </button>
        </div>

        <%= if @gossip_agents == [] do %>
          <p class="text-gray-500 text-sm text-center py-4">
            No agents configured. Add agents to start building your gossip protocol.
          </p>
        <% end %>

        <div :for={{agent, idx} <- Enum.with_index(@gossip_agents)} class="bg-gray-950 rounded border border-gray-800 p-3 space-y-2">
          <div class="flex items-center justify-between">
            <span class="text-xs text-gray-500">Agent {idx + 1}</span>
            <button
              type="button"
              phx-click="remove_gossip_agent"
              phx-value-index={idx}
              class="text-xs text-red-400 hover:text-red-300"
            >
              Remove
            </button>
          </div>
          <div class="grid grid-cols-2 gap-3">
            <div>
              <input
                type="text"
                name={"gossip_agent_name_#{idx}"}
                value={agent.name}
                phx-blur="update_gossip_agent"
                phx-value-index={idx}
                phx-value-field="name"
                class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                placeholder="agent-name"
              />
            </div>
            <div>
              <input
                type="text"
                name={"gossip_agent_topic_#{idx}"}
                value={agent.topic}
                phx-blur="update_gossip_agent"
                phx-value-index={idx}
                phx-value-field="topic"
                class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                placeholder="topic"
              />
            </div>
          </div>
          <div>
            <input
              type="text"
              name={"gossip_agent_prompt_#{idx}"}
              value={agent.prompt}
              phx-blur="update_gossip_agent"
              phx-value-index={idx}
              phx-value-field="prompt"
              class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
              placeholder="Agent prompt..."
            />
          </div>
        </div>
      </div>

      <%!-- Seed knowledge --%>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 space-y-4">
        <div class="flex items-center justify-between">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Seed Knowledge</h3>
          <button
            type="button"
            phx-click="add_seed_knowledge"
            class="text-xs bg-gray-800 text-gray-300 px-3 py-1.5 rounded hover:bg-gray-700"
          >
            + Add Entry
          </button>
        </div>

        <div :for={{entry, idx} <- Enum.with_index(@seed_knowledge)} class="bg-gray-950 rounded border border-gray-800 p-3 space-y-2">
          <div class="flex items-center justify-between">
            <span class="text-xs text-gray-500">Entry {idx + 1}</span>
            <button
              type="button"
              phx-click="remove_seed_knowledge"
              phx-value-index={idx}
              class="text-xs text-red-400 hover:text-red-300"
            >
              Remove
            </button>
          </div>
          <div class="grid grid-cols-3 gap-3">
            <div>
              <input
                type="text"
                name={"seed_topic_#{idx}"}
                value={entry.topic}
                phx-blur="update_seed_knowledge"
                phx-value-index={idx}
                phx-value-field="topic"
                class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                placeholder="topic"
              />
            </div>
            <div class="col-span-2">
              <input
                type="text"
                name={"seed_content_#{idx}"}
                value={entry.content}
                phx-blur="update_seed_knowledge"
                phx-value-index={idx}
                phx-value-field="content"
                class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                placeholder="Knowledge content..."
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Config Preview --

  @doc """
  Renders a Gossip-specific config preview.
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
        <span class="text-sm text-gray-500">Agents:</span>
        <span class="text-sm text-white ml-2">{length(@config.agents)}</span>
      </div>
      <div>
        <span class="text-sm text-gray-500">Rounds:</span>
        <span class="text-sm text-white ml-2">{@config.gossip.rounds}</span>
      </div>
      <div>
        <span class="text-sm text-gray-500">Topology:</span>
        <span class="text-sm text-white ml-2">{@config.gossip.topology}</span>
      </div>
      <div class="flex flex-wrap gap-1 pt-1">
        <span
          :for={agent <- @config.agents}
          class="bg-purple-900/50 text-purple-300 text-xs px-2 py-0.5 rounded"
        >
          {agent.name}
        </span>
      </div>
    </div>
    """
  end
end
