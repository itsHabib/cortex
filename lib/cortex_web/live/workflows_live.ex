defmodule CortexWeb.WorkflowsLive do
  @moduledoc """
  Unified workflow composition and launch page.

  Supports all three coordination modes (DAG, Mesh, Gossip) with both
  YAML-first and visual composition paths. Replaces the former separate
  launcher UIs with one coherent workflow composition experience.
  """

  use CortexWeb, :live_view

  import CortexWeb.DAGComponents

  alias CortexWeb.WorkflowsLive.{
    AgentPicker,
    DAGPanel,
    GossipPanel,
    Launcher,
    MeshPanel,
    Templates
  }

  alias Cortex.Orchestration.Config.Loader
  alias Cortex.Orchestration.DAG

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: AgentPicker.subscribe_gateway_events()

    {:ok,
     assign(socket,
       # Mode
       mode: "dag",
       composition_mode: "yaml",

       # YAML path
       yaml_content: "",
       file_path: "",

       # Shared config
       project_name: "",
       workspace_path: "",
       model: "sonnet",
       max_turns: 200,
       provider: "cli",
       backend: "local",

       # DAG visual state
       dag_teams: [],

       # Mesh visual state
       mesh_agents: [],
       mesh_settings: %{heartbeat: 30, suspect: 90, dead: 180},
       cluster_context: "",

       # Gossip visual state
       gossip_agents: [],
       gossip_settings: %{rounds: 5, topology: :random, interval: 60},
       seed_knowledge: [],

       # Agent picker
       available_agents: AgentPicker.safe_list_agents(),
       agent_filter: "",

       # Validation
       validation_result: nil,
       config: nil,
       tiers: [],
       edges: [],
       errors: [],
       warnings: [],
       detected_mode: nil,

       # Templates
       templates: Templates.list(),
       active_template: nil,

       # Page
       page_title: "Workflows"
     )}
  end

  # -- Events: Mode & Composition --

  @impl true
  def handle_event("select_mode", %{"mode" => mode}, socket) do
    {:noreply,
     assign(socket,
       mode: mode,
       validation_result: nil,
       config: nil,
       tiers: [],
       edges: [],
       errors: [],
       warnings: [],
       detected_mode: nil
     )}
  end

  def handle_event("select_composition", %{"mode" => comp_mode}, socket) do
    socket =
      if comp_mode == "yaml" && socket.assigns.composition_mode == "visual" do
        # Generate YAML from visual state when switching to YAML
        yaml = generate_yaml_from_visual(socket.assigns)
        assign(socket, yaml_content: yaml)
      else
        socket
      end

    {:noreply, assign(socket, composition_mode: comp_mode)}
  end

  # -- Events: Form --

  def handle_event("form_changed", params, socket) do
    yaml = Map.get(params, "yaml", socket.assigns.yaml_content)
    path = Map.get(params, "path", socket.assigns.file_path)
    workspace = Map.get(params, "workspace_path", socket.assigns.workspace_path)
    project_name = Map.get(params, "project_name", socket.assigns.project_name)
    model = Map.get(params, "model", socket.assigns.model)
    provider = Map.get(params, "provider", socket.assigns.provider)
    backend = Map.get(params, "backend", socket.assigns.backend)

    max_turns =
      case Map.get(params, "max_turns") do
        nil -> socket.assigns.max_turns
        val -> parse_int(val, socket.assigns.max_turns)
      end

    # Mesh settings
    mesh_settings = update_mesh_settings(params, socket.assigns.mesh_settings)

    # Gossip settings
    gossip_settings = update_gossip_settings(params, socket.assigns.gossip_settings)

    cluster_context = Map.get(params, "cluster_context", socket.assigns.cluster_context)

    {:noreply,
     assign(socket,
       yaml_content: yaml,
       file_path: path,
       workspace_path: workspace,
       project_name: project_name,
       model: model,
       max_turns: max_turns,
       provider: provider,
       backend: backend,
       mesh_settings: mesh_settings,
       gossip_settings: gossip_settings,
       cluster_context: cluster_context,
       validation_result: nil,
       config: nil,
       detected_mode: nil
     )}
  end

  # -- Events: Templates --

  def handle_event("load_template", %{"template" => template_id}, socket) do
    case Templates.get(template_id) do
      nil ->
        {:noreply, socket}

      yaml ->
        mode = Templates.mode_for(template_id) || socket.assigns.mode

        {:noreply,
         assign(socket,
           yaml_content: yaml,
           mode: mode,
           composition_mode: "yaml",
           active_template: template_id,
           validation_result: nil,
           config: nil,
           detected_mode: nil
         )}
    end
  end

  # -- Events: DAG Visual Builder --

  def handle_event("add_dag_team", _params, socket) do
    new_team = %{name: "", lead_role: "", task_summary: "", depends_on: []}
    {:noreply, assign(socket, dag_teams: socket.assigns.dag_teams ++ [new_team])}
  end

  def handle_event("remove_dag_team", %{"name" => name}, socket) do
    teams =
      socket.assigns.dag_teams
      |> Enum.reject(&(&1.name == name))
      |> Enum.map(fn t -> %{t | depends_on: Enum.reject(t.depends_on, &(&1 == name))} end)

    {:noreply, assign(socket, dag_teams: teams)}
  end

  def handle_event("update_dag_team", params, socket) do
    idx = parse_int(params["index"], 0)
    field = params["field"]
    value = params["value"] || ""

    teams =
      List.update_at(socket.assigns.dag_teams, idx, fn team ->
        case field do
          "name" -> %{team | name: value}
          "lead_role" -> %{team | lead_role: value}
          "task_summary" -> %{team | task_summary: value}
          _ -> team
        end
      end)

    {:noreply, assign(socket, dag_teams: teams)}
  end

  def handle_event("toggle_dag_dependency", %{"team" => team_name, "dep" => dep}, socket) do
    teams =
      Enum.map(socket.assigns.dag_teams, fn team ->
        if team.name == team_name, do: toggle_dep(team, dep), else: team
      end)

    {:noreply, assign(socket, dag_teams: teams)}
  end

  # -- Events: Mesh Visual Builder --

  def handle_event("add_mesh_agent", _params, socket) do
    new_agent = %{name: "", role: "", prompt: ""}
    {:noreply, assign(socket, mesh_agents: socket.assigns.mesh_agents ++ [new_agent])}
  end

  def handle_event("remove_mesh_agent", %{"index" => idx_str}, socket) do
    idx = parse_int(idx_str, -1)
    agents = List.delete_at(socket.assigns.mesh_agents, idx)
    {:noreply, assign(socket, mesh_agents: agents)}
  end

  def handle_event("update_mesh_agent", params, socket) do
    idx = parse_int(params["index"], 0)
    field = params["field"]
    value = params["value"] || ""

    agents =
      List.update_at(socket.assigns.mesh_agents, idx, fn agent ->
        Map.put(agent, String.to_existing_atom(field), value)
      end)

    {:noreply, assign(socket, mesh_agents: agents)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  # -- Events: Gossip Visual Builder --

  def handle_event("add_gossip_agent", _params, socket) do
    new_agent = %{name: "", topic: "", prompt: ""}
    {:noreply, assign(socket, gossip_agents: socket.assigns.gossip_agents ++ [new_agent])}
  end

  def handle_event("remove_gossip_agent", %{"index" => idx_str}, socket) do
    idx = parse_int(idx_str, -1)
    agents = List.delete_at(socket.assigns.gossip_agents, idx)
    {:noreply, assign(socket, gossip_agents: agents)}
  end

  def handle_event("update_gossip_agent", params, socket) do
    idx = parse_int(params["index"], 0)
    field = params["field"]
    value = params["value"] || ""

    agents =
      List.update_at(socket.assigns.gossip_agents, idx, fn agent ->
        Map.put(agent, String.to_existing_atom(field), value)
      end)

    {:noreply, assign(socket, gossip_agents: agents)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  # -- Events: Seed Knowledge --

  def handle_event("add_seed_knowledge", _params, socket) do
    new_entry = %{topic: "", content: ""}
    {:noreply, assign(socket, seed_knowledge: socket.assigns.seed_knowledge ++ [new_entry])}
  end

  def handle_event("remove_seed_knowledge", %{"index" => idx_str}, socket) do
    idx = parse_int(idx_str, -1)
    {:noreply, assign(socket, seed_knowledge: List.delete_at(socket.assigns.seed_knowledge, idx))}
  end

  def handle_event("update_seed_knowledge", params, socket) do
    idx = parse_int(params["index"], 0)
    field = params["field"]
    value = params["value"] || ""

    entries =
      List.update_at(socket.assigns.seed_knowledge, idx, fn entry ->
        Map.put(entry, String.to_existing_atom(field), value)
      end)

    {:noreply, assign(socket, seed_knowledge: entries)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  # -- Events: Agent Picker --

  def handle_event("filter_agents", %{"value" => query}, socket) do
    {:noreply, assign(socket, agent_filter: query)}
  end

  def handle_event("add_agent", %{"name" => name}, socket) do
    case socket.assigns.mode do
      "mesh" ->
        if Enum.any?(socket.assigns.mesh_agents, &(&1.name == name)) do
          {:noreply, socket}
        else
          agent = %{name: name, role: "", prompt: ""}
          {:noreply, assign(socket, mesh_agents: socket.assigns.mesh_agents ++ [agent])}
        end

      "gossip" ->
        if Enum.any?(socket.assigns.gossip_agents, &(&1.name == name)) do
          {:noreply, socket}
        else
          agent = %{name: name, topic: "", prompt: ""}
          {:noreply, assign(socket, gossip_agents: socket.assigns.gossip_agents ++ [agent])}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_agent", %{"name" => name}, socket) do
    case socket.assigns.mode do
      "mesh" ->
        agents = Enum.reject(socket.assigns.mesh_agents, &(&1.name == name))
        {:noreply, assign(socket, mesh_agents: agents)}

      "gossip" ->
        agents = Enum.reject(socket.assigns.gossip_agents, &(&1.name == name))
        {:noreply, assign(socket, gossip_agents: agents)}

      _ ->
        {:noreply, socket}
    end
  end

  # -- Events: Validate --

  def handle_event("validate", params, socket) do
    yaml_content = Map.get(params, "yaml", socket.assigns.yaml_content)
    file_path = Map.get(params, "path", socket.assigns.file_path)
    workspace_path = Map.get(params, "workspace_path", socket.assigns.workspace_path)

    socket =
      assign(socket,
        yaml_content: yaml_content,
        file_path: file_path,
        workspace_path: workspace_path
      )

    yaml =
      if socket.assigns.composition_mode == "visual" do
        generate_yaml_from_visual(socket.assigns)
      else
        effective_yaml(socket)
      end

    if yaml == "" do
      {:noreply,
       assign(socket,
         validation_result: :error,
         errors: ["Please provide YAML content or a file path"],
         warnings: [],
         config: nil,
         tiers: [],
         edges: [],
         detected_mode: nil
       )}
    else
      mode = resolve_mode(socket.assigns.mode, yaml)

      case validate_for_mode(yaml, workspace_path, mode) do
        {:ok, config, warnings, tiers, edges} ->
          {:noreply,
           assign(socket,
             validation_result: :ok,
             config: config,
             tiers: tiers,
             edges: edges,
             errors: [],
             warnings: warnings,
             detected_mode: mode
           )}

        {:error, errors} ->
          {:noreply,
           assign(socket,
             validation_result: :error,
             errors: errors,
             warnings: [],
             config: nil,
             tiers: [],
             edges: [],
             detected_mode: mode
           )}
      end
    end
  end

  # -- Events: Launch --

  def handle_event("launch", _params, socket) do
    config = socket.assigns.config
    mode = socket.assigns.detected_mode || socket.assigns.mode
    ui_workspace = String.trim(socket.assigns.workspace_path)

    if config == nil do
      {:noreply,
       socket
       |> put_flash(:error, "Please validate configuration before launching")}
    else
      yaml =
        if socket.assigns.composition_mode == "visual" do
          generate_yaml_from_visual(socket.assigns)
        else
          effective_yaml(socket)
        end

      workspace = Launcher.resolve_workspace(config, mode, ui_workspace)

      case Launcher.launch(yaml, config, mode, workspace) do
        {:ok, run} ->
          {:noreply,
           socket
           |> put_flash(:info, "Run started successfully!")
           |> push_navigate(to: "/runs/#{run.id}")}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to create run: #{inspect(reason)}")}
      end
    end
  end

  # -- Private helpers --

  defp toggle_dep(team, dep) do
    if dep in team.depends_on do
      %{team | depends_on: List.delete(team.depends_on, dep)}
    else
      %{team | depends_on: team.depends_on ++ [dep]}
    end
  end

  # -- Events: Gateway PubSub --

  @impl true
  def handle_info(%{type: type}, socket)
      when type in [:agent_registered, :agent_unregistered, :agent_heartbeat] do
    {:noreply, assign(socket, available_agents: AgentPicker.safe_list_agents())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Workflows
      <:subtitle>Compose and launch multi-agent orchestration runs</:subtitle>
    </.header>

    <%!-- Mode selector --%>
    <.mode_selector selected={@mode} on_select="select_mode">
      <:dag_config>
        {render_mode_content(assigns)}
      </:dag_config>
      <:mesh_config>
        {render_mode_content(assigns)}
      </:mesh_config>
      <:gossip_config>
        {render_mode_content(assigns)}
      </:gossip_config>
    </.mode_selector>
    """
  end

  # -- Render helpers --

  defp render_mode_content(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-4">
      <%!-- Input Column --%>
      <form phx-change="form_changed" phx-submit="validate">
        <%!-- Composition toggle --%>
        <div class="flex items-center gap-2 mb-4">
          <button
            type="button"
            phx-click="select_composition"
            phx-value-mode="yaml"
            class={[
              "px-3 py-1.5 text-sm rounded-md transition-colors",
              if(@composition_mode == "yaml",
                do: "bg-gray-800 text-white",
                else: "text-gray-400 hover:text-gray-300"
              )
            ]}
          >
            YAML
          </button>
          <button
            type="button"
            phx-click="select_composition"
            phx-value-mode="visual"
            class={[
              "px-3 py-1.5 text-sm rounded-md transition-colors",
              if(@composition_mode == "visual",
                do: "bg-gray-800 text-white",
                else: "text-gray-400 hover:text-gray-300"
              )
            ]}
          >
            Visual
          </button>
        </div>

        <%!-- Mode-specific panel --%>
        {render_input_panel(assigns)}

        <%!-- Agent picker (visual mode, mesh/gossip only) --%>
        <%= if @composition_mode == "visual" and @mode in ["mesh", "gossip"] do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 mt-4">
            <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Connected Agents</h3>
            <p class="text-xs text-gray-500 mb-3">Select from connected agents to add them to your configuration.</p>
            <.agent_picker
              available={@available_agents}
              selected={selected_agent_names(assigns)}
              filter={@agent_filter}
              on_add="add_agent"
              on_remove="remove_agent"
              on_filter="filter_agents"
            />
          </div>
        <% end %>

        <%!-- Action buttons --%>
        <div class="flex gap-3 mt-4">
          <button
            type="submit"
            class="inline-flex items-center rounded-md bg-gray-700 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-gray-600"
          >
            Validate
          </button>
          <button
            :if={@validation_result == :ok}
            type="button"
            phx-click="launch"
            class={[
              "inline-flex items-center rounded-md px-4 py-2 text-sm font-semibold text-white shadow-sm",
              launch_button_class(@mode)
            ]}
          >
            Launch Run
          </button>
        </div>
      </form>

      <%!-- Preview Column --%>
      <div>
        <%!-- Detected Mode --%>
        <%= if @detected_mode do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-3 mb-4">
            <span class="text-xs text-gray-500">Detected mode:</span>
            <.mode_badge mode={@detected_mode} class="ml-2" />
          </div>
        <% end %>

        <%!-- Errors --%>
        <%= if @validation_result == :error and @errors != [] do %>
          <div class="bg-rose-900/30 border border-rose-800 rounded-lg p-4 mb-4">
            <h3 class="text-sm font-medium text-rose-300 mb-2">Validation Errors</h3>
            <ul class="list-disc list-inside text-sm text-rose-200 space-y-1">
              <li :for={error <- @errors}>{error}</li>
            </ul>
          </div>
        <% end %>

        <%!-- Warnings --%>
        <%= if @warnings != [] do %>
          <div class="bg-yellow-900/30 border border-yellow-800 rounded-lg p-4 mb-4">
            <h3 class="text-sm font-medium text-yellow-300 mb-2">Warnings</h3>
            <ul class="list-disc list-inside text-sm text-yellow-200 space-y-1">
              <li :for={warning <- @warnings}>{warning}</li>
            </ul>
          </div>
        <% end %>

        <%!-- Config Preview --%>
        <%= if @config do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
            <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Configuration Preview</h3>
            {render_config_preview(assigns)}
          </div>

          <%!-- DAG Preview (dag mode only) --%>
          <%= if @tiers != [] do %>
            <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
              <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Dependency Graph</h3>
              <.dag_graph
                tiers={@tiers}
                teams={preview_teams(@config)}
                edges={@edges}
                run_id="preview"
              />
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_input_panel(%{composition_mode: "yaml", mode: "dag"} = assigns) do
    ~H"""
    <DAGPanel.yaml_panel
      yaml_content={@yaml_content}
      file_path={@file_path}
      workspace_path={@workspace_path}
      provider={@provider}
      backend={@backend}
      templates={@templates}
    />
    """
  end

  defp render_input_panel(%{composition_mode: "yaml", mode: "mesh"} = assigns) do
    ~H"""
    <MeshPanel.yaml_panel
      yaml_content={@yaml_content}
      file_path={@file_path}
      workspace_path={@workspace_path}
      provider={@provider}
      backend={@backend}
      templates={@templates}
    />
    """
  end

  defp render_input_panel(%{composition_mode: "yaml", mode: "gossip"} = assigns) do
    ~H"""
    <GossipPanel.yaml_panel
      yaml_content={@yaml_content}
      file_path={@file_path}
      workspace_path={@workspace_path}
      provider={@provider}
      backend={@backend}
      templates={@templates}
    />
    """
  end

  defp render_input_panel(%{composition_mode: "visual", mode: "dag"} = assigns) do
    ~H"""
    <DAGPanel.visual_panel
      dag_teams={@dag_teams}
      project_name={@project_name}
      workspace_path={@workspace_path}
      model={@model}
      max_turns={@max_turns}
      available_agents={@available_agents}
      agent_filter={@agent_filter}
    />
    <DAGPanel.execution_settings provider={@provider} backend={@backend} />
    """
  end

  defp render_input_panel(%{composition_mode: "visual", mode: "mesh"} = assigns) do
    ~H"""
    <MeshPanel.visual_panel
      mesh_settings={@mesh_settings}
      project_name={@project_name}
      workspace_path={@workspace_path}
      model={@model}
      max_turns={@max_turns}
      cluster_context={@cluster_context}
      mesh_agents={@mesh_agents}
      available_agents={@available_agents}
      agent_filter={@agent_filter}
    />
    <DAGPanel.execution_settings provider={@provider} backend={@backend} />
    """
  end

  defp render_input_panel(%{composition_mode: "visual", mode: "gossip"} = assigns) do
    ~H"""
    <GossipPanel.visual_panel
      gossip_settings={@gossip_settings}
      project_name={@project_name}
      workspace_path={@workspace_path}
      model={@model}
      max_turns={@max_turns}
      cluster_context={@cluster_context}
      gossip_agents={@gossip_agents}
      seed_knowledge={@seed_knowledge}
      available_agents={@available_agents}
      agent_filter={@agent_filter}
    />
    <DAGPanel.execution_settings provider={@provider} backend={@backend} />
    """
  end

  defp render_config_preview(%{detected_mode: "gossip"} = assigns) do
    ~H"<GossipPanel.config_preview config={@config} />"
  end

  defp render_config_preview(%{detected_mode: "mesh"} = assigns) do
    ~H"<MeshPanel.config_preview config={@config} />"
  end

  defp render_config_preview(assigns) do
    ~H"<DAGPanel.config_preview config={@config} />"
  end

  # -- Private helpers --

  defp effective_yaml(socket) do
    file_path = String.trim(socket.assigns.file_path)

    cond do
      # File path takes priority when set — user explicitly chose a file
      file_path != "" ->
        case File.read(file_path) do
          {:ok, content} ->
            content

          _ ->
            # Try relative to project root
            case File.read(Path.join(File.cwd!(), file_path)) do
              {:ok, content} -> content
              _ -> ""
            end
        end

      socket.assigns.yaml_content != "" ->
        socket.assigns.yaml_content

      true ->
        ""
    end
  end

  defp resolve_mode(ui_mode, yaml) do
    # If user explicitly selected a mode, use it for validation dispatch.
    # Fall back to YAML auto-detection for backward compat.
    case ui_mode do
      "mesh" -> "mesh"
      "gossip" -> "gossip"
      "dag" -> detect_yaml_mode(yaml)
      _ -> detect_yaml_mode(yaml)
    end
  end

  defp detect_yaml_mode(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, parsed} ->
        mode = Map.get(parsed, "mode")

        cond do
          mode == "gossip" -> "gossip"
          mode == "mesh" -> "mesh"
          Map.has_key?(parsed, "gossip") -> "gossip"
          Map.has_key?(parsed, "mesh") -> "mesh"
          true -> "dag"
        end

      _ ->
        "dag"
    end
  end

  defp validate_for_mode(yaml, _workspace_path, "gossip") do
    case Cortex.Gossip.Config.Loader.load_string(yaml) do
      {:ok, config} -> {:ok, config, [], [], []}
      {:error, errors} -> {:error, errors}
    end
  end

  defp validate_for_mode(yaml, _workspace_path, "mesh") do
    case Cortex.Mesh.Config.Loader.load_string(yaml) do
      {:ok, config} -> {:ok, config, [], [], []}
      {:error, errors} -> {:error, errors}
    end
  end

  defp validate_for_mode(yaml, workspace_path, _dag) do
    case Loader.load_string(yaml) do
      {:ok, config, warnings} ->
        ui_ws = String.trim(workspace_path)
        yaml_ws = config.workspace_path

        has_ui = ui_ws != ""
        has_yaml = yaml_ws != nil && yaml_ws != ""

        if has_ui && has_yaml do
          {:error, ["workspace_path is set in both YAML and the form — use only one"]}
        else
          {tiers, edges} = build_preview_dag(config)
          {:ok, config, warnings, tiers, edges}
        end

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp build_preview_dag(config) do
    teams =
      Enum.map(config.teams, fn t ->
        %{name: t.name, depends_on: t.depends_on || []}
      end)

    case DAG.build_tiers(teams) do
      {:ok, tiers} -> {tiers, build_edges(teams)}
      _ -> {[], []}
    end
  end

  defp build_edges(teams) do
    Enum.flat_map(teams, fn team ->
      Enum.map(team.depends_on, fn dep -> {dep, team.name} end)
    end)
  end

  defp preview_teams(config) do
    if Map.has_key?(config, :teams) do
      Enum.map(config.teams, fn t ->
        %{team_name: t.name, status: "pending", cost_usd: nil}
      end)
    else
      []
    end
  end

  defp generate_yaml_from_visual(assigns) do
    case assigns.mode do
      "dag" -> DAGPanel.generate_yaml(assigns)
      "mesh" -> generate_mesh_yaml(assigns)
      "gossip" -> generate_gossip_yaml(assigns)
      _ -> ""
    end
  end

  defp generate_mesh_yaml(assigns) do
    agents_yaml =
      assigns.mesh_agents
      |> Enum.filter(&(&1.name != ""))
      |> Enum.map_join("\n", fn a ->
        "    - name: #{a.name}\n      role: #{a.role}\n      prompt: #{a.prompt}"
      end)

    context =
      if assigns.cluster_context != "" do
        "\n  cluster_context: #{assigns.cluster_context}"
      else
        ""
      end

    """
    name: #{assigns.project_name}
    mode: mesh
    defaults:
      model: #{assigns.model}
      max_turns: #{assigns.max_turns}
    mesh:
      heartbeat_interval_seconds: #{assigns.mesh_settings.heartbeat}
      suspect_timeout_seconds: #{assigns.mesh_settings.suspect}
      dead_timeout_seconds: #{assigns.mesh_settings.dead}#{context}
    agents:
    #{agents_yaml}
    """
    |> String.trim()
  end

  defp generate_gossip_yaml(assigns) do
    agents_yaml =
      assigns.gossip_agents
      |> Enum.filter(&(&1.name != ""))
      |> Enum.map_join("\n", fn a ->
        "    - name: #{a.name}\n      topic: #{a.topic}\n      prompt: #{a.prompt}"
      end)

    seed_yaml =
      if assigns.seed_knowledge != [] do
        entries =
          assigns.seed_knowledge
          |> Enum.filter(&(&1.topic != ""))
          |> Enum.map_join("\n", fn e ->
            "    - topic: #{e.topic}\n      content: \"#{e.content}\""
          end)

        "\nseed_knowledge:\n#{entries}"
      else
        ""
      end

    context =
      if assigns.cluster_context != "" do
        "\n  cluster_context: #{assigns.cluster_context}"
      else
        ""
      end

    """
    name: #{assigns.project_name}
    mode: gossip
    defaults:
      model: #{assigns.model}
      max_turns: #{assigns.max_turns}
    gossip:
      rounds: #{assigns.gossip_settings.rounds}
      topology: #{assigns.gossip_settings.topology}
      exchange_interval_seconds: #{assigns.gossip_settings.interval}#{context}
    agents:
    #{agents_yaml}#{seed_yaml}
    """
    |> String.trim()
  end

  defp selected_agent_names(%{mode: "mesh"} = assigns) do
    Enum.map(assigns.mesh_agents, & &1.name)
  end

  defp selected_agent_names(%{mode: "gossip"} = assigns) do
    Enum.map(assigns.gossip_agents, & &1.name)
  end

  defp selected_agent_names(_), do: []

  defp update_mesh_settings(params, current) do
    %{
      heartbeat: parse_int(params["mesh_heartbeat"], current.heartbeat),
      suspect: parse_int(params["mesh_suspect"], current.suspect),
      dead: parse_int(params["mesh_dead"], current.dead)
    }
  end

  defp update_gossip_settings(params, current) do
    %{
      rounds: parse_int(params["gossip_rounds"], current.rounds),
      topology: parse_topology(params["gossip_topology"], current.topology),
      interval: parse_int(params["gossip_interval"], current.interval)
    }
  end

  defp parse_topology(nil, default), do: default
  defp parse_topology("random", _), do: :random
  defp parse_topology("full_mesh", _), do: :full_mesh
  defp parse_topology("ring", _), do: :ring
  defp parse_topology(_, default), do: default

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default

  defp launch_button_class("mesh"), do: "bg-blue-600 hover:bg-blue-500"
  defp launch_button_class("gossip"), do: "bg-purple-600 hover:bg-purple-500"
  defp launch_button_class(_), do: "bg-cortex-600 hover:bg-cortex-500"
end
