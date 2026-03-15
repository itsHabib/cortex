defmodule CortexWeb.NewRunLive do
  use CortexWeb, :live_view

  import CortexWeb.DAGComponents

  alias Cortex.Orchestration.Config.Loader
  alias Cortex.Orchestration.DAG

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       yaml_content: "",
       file_path: "",
       workspace_path: "",
       validation_result: nil,
       config: nil,
       tiers: [],
       edges: [],
       errors: [],
       warnings: [],
       page_title: "New Run"
     )}
  end

  @impl true
  def handle_event("form_changed", params, socket) do
    yaml = Map.get(params, "yaml", socket.assigns.yaml_content)
    path = Map.get(params, "path", socket.assigns.file_path)
    workspace = Map.get(params, "workspace_path", socket.assigns.workspace_path)
    {:noreply, assign(socket, yaml_content: yaml, file_path: path, workspace_path: workspace, validation_result: nil, config: nil)}
  end

  def handle_event("validate", params, socket) do
    # Update assigns from form params in case form_changed didn't fire
    yaml_content = Map.get(params, "yaml", socket.assigns.yaml_content)
    file_path = Map.get(params, "path", socket.assigns.file_path)
    workspace_path = Map.get(params, "workspace_path", socket.assigns.workspace_path)
    socket = assign(socket, yaml_content: yaml_content, file_path: file_path, workspace_path: workspace_path)

    yaml = effective_yaml(socket)

    if yaml == "" do
      {:noreply,
       assign(socket,
         validation_result: :error,
         errors: ["Please provide YAML content or a file path"],
         warnings: [],
         config: nil,
         tiers: [],
         edges: []
       )}
    else
      case Loader.load_string(yaml) do
        {:ok, config, warnings} ->
          ui_ws = String.trim(workspace_path)
          yaml_ws = config.workspace_path

          has_ui = ui_ws != ""
          has_yaml = yaml_ws != nil && yaml_ws != ""

          if has_ui && has_yaml do
            {:noreply,
             assign(socket,
               validation_result: :error,
               errors: ["workspace_path is set in both YAML and the form — use only one"],
               warnings: [],
               config: nil,
               tiers: [],
               edges: []
             )}
          else
            {tiers, edges} = build_preview_dag(config)

            {:noreply,
             assign(socket,
               validation_result: :ok,
               config: config,
               tiers: tiers,
               edges: edges,
               errors: [],
               warnings: warnings
             )}
          end

        {:error, errors} ->
          {:noreply,
           assign(socket,
             validation_result: :error,
             errors: errors,
             warnings: [],
             config: nil,
             tiers: [],
             edges: []
           )}
      end
    end
  end

  def handle_event("launch", _params, socket) do
    yaml = effective_yaml(socket)
    config = socket.assigns.config
    ui_workspace = String.trim(socket.assigns.workspace_path)

    if config == nil do
      {:noreply,
       socket
       |> put_flash(:error, "Please validate configuration before launching")}
    else
      # Merge UI workspace into config (validation already ensured only one is set)
      config =
        if ui_workspace != "" do
          %{config | workspace_path: ui_workspace}
        else
          config
        end

      run_attrs = %{
        name: config.name,
        config_yaml: yaml,
        status: "pending",
        team_count: length(config.teams),
        started_at: DateTime.utc_now()
      }

      case safe_create_run(run_attrs) do
        {:ok, run} ->
          # Start orchestration asynchronously
          spawn_orchestration(run, config)

          {:noreply,
           socket
           |> put_flash(:info, "Run started successfully!")
           |> push_navigate(to: "/runs/#{run.id}")}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to create run")}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      New Run
      <:subtitle>Configure and launch an orchestration run</:subtitle>
    </.header>

    <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
      <!-- Input Column -->
      <form phx-change="form_changed" phx-submit="validate">
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 mb-4">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Orchestra YAML</h3>
          <textarea
            name="yaml"
            rows="16"
            class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-cortex-500 focus:border-cortex-500 resize-y"
            placeholder="Paste your orchestra.yaml content here..."
          ><%= @yaml_content %></textarea>
        </div>

        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 mb-4">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Or Load From File</h3>
          <input
            type="text"
            name="path"
            value={@file_path}
            class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-cortex-500 focus:border-cortex-500"
            placeholder="/path/to/orchestra.yaml"
          />
        </div>

        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 mb-4">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Workspace Path</h3>
          <p class="text-xs text-gray-500 mb-2">Where agents write files. Set here OR in YAML, not both. Defaults to /tmp.</p>
          <input
            type="text"
            name="workspace_path"
            value={@workspace_path}
            class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-cortex-500 focus:border-cortex-500"
            placeholder="/path/to/project (default: /tmp)"
          />
        </div>

        <div class="flex gap-3">
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
            class="inline-flex items-center rounded-md bg-cortex-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-cortex-500"
          >
            Launch Run
          </button>
        </div>
      </form>

      <!-- Preview Column -->
      <div>
        <!-- Errors -->
        <%= if @validation_result == :error and @errors != [] do %>
          <div class="bg-rose-900/30 border border-rose-800 rounded-lg p-4 mb-4">
            <h3 class="text-sm font-medium text-rose-300 mb-2">Validation Errors</h3>
            <ul class="list-disc list-inside text-sm text-rose-200 space-y-1">
              <li :for={error <- @errors}>{error}</li>
            </ul>
          </div>
        <% end %>

        <!-- Warnings -->
        <%= if @warnings != [] do %>
          <div class="bg-yellow-900/30 border border-yellow-800 rounded-lg p-4 mb-4">
            <h3 class="text-sm font-medium text-yellow-300 mb-2">Warnings</h3>
            <ul class="list-disc list-inside text-sm text-yellow-200 space-y-1">
              <li :for={warning <- @warnings}>{warning}</li>
            </ul>
          </div>
        <% end %>

        <!-- Config Preview -->
        <%= if @config do %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 mb-4">
            <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Configuration Preview</h3>
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
          </div>

          <!-- DAG Preview -->
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

  # -- Private helpers --

  defp effective_yaml(socket) do
    cond do
      socket.assigns.yaml_content != "" ->
        socket.assigns.yaml_content

      socket.assigns.file_path != "" ->
        case File.read(socket.assigns.file_path) do
          {:ok, content} -> content
          _ -> ""
        end

      true ->
        ""
    end
  end

  defp build_preview_dag(config) do
    teams =
      Enum.map(config.teams, fn t ->
        %{name: t.name, depends_on: t.depends_on || []}
      end)

    case DAG.build_tiers(teams) do
      {:ok, tiers} ->
        edges =
          Enum.flat_map(teams, fn team ->
            Enum.map(team.depends_on, fn dep -> {dep, team.name} end)
          end)

        {tiers, edges}

      _ ->
        {[], []}
    end
  end

  defp preview_teams(config) do
    Enum.map(config.teams, fn t ->
      %{team_name: t.name, status: "pending", cost_usd: nil}
    end)
  end

  defp resolve_workspace_path(config, run_id) do
    case config.workspace_path do
      nil -> Path.join(System.tmp_dir!(), "cortex_#{run_id}")
      "" -> Path.join(System.tmp_dir!(), "cortex_#{run_id}")
      path -> path
    end
  end

  defp safe_create_run(attrs) do
    Cortex.Store.create_run(attrs)
  rescue
    e -> {:error, e}
  end

  defp safe_update_run_status(run, status) do
    # Re-fetch to avoid stale struct (runner may have updated it)
    case Cortex.Store.get_run(run.id) do
      nil ->
        :ok

      fresh_run ->
        Cortex.Store.update_run(fresh_run, %{
          status: status,
          completed_at: DateTime.utc_now()
        })
    end
  rescue
    _ -> :ok
  end

  defp spawn_orchestration(run, config) do
    yaml = run.config_yaml
    run_id = run.id

    # Resolve workspace: UI field > YAML config > /tmp default
    workspace_path = resolve_workspace_path(config, run_id)

    Task.start(fn ->
      # Write YAML to a temp file for the runner
      tmp_path = Path.join(System.tmp_dir!(), "cortex_run_#{run_id}.yaml")
      File.write!(tmp_path, yaml)

      try do
        result =
          Cortex.Orchestration.Runner.run(tmp_path,
            workspace_path: workspace_path,
            run_id: run_id
          )

        case result do
          {:ok, _summary} ->
            # Runner already persists completed status to Store;
            # this is a fallback in case that didn't happen
            safe_update_run_status(run, "completed")

          {:error, reason} ->
            safe_update_run_status(run, "failed")

            require Logger
            Logger.error("Run #{run_id} failed: #{inspect(reason)}")
        end
      rescue
        e ->
          safe_update_run_status(run, "failed")

          require Logger
          Logger.error("Run #{run_id} crashed: #{inspect(e)}")
      after
        File.rm(tmp_path)
      end
    end)
  end
end
