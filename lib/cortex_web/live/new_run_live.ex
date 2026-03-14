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
  def handle_event("update_yaml", %{"yaml" => yaml}, socket) do
    {:noreply, assign(socket, yaml_content: yaml, validation_result: nil, config: nil)}
  end

  def handle_event("update_path", %{"path" => path}, socket) do
    {:noreply, assign(socket, file_path: path)}
  end

  def handle_event("validate", _params, socket) do
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

    if config == nil do
      {:noreply,
       socket
       |> put_flash(:error, "Please validate configuration before launching")}
    else
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
      <div>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 mb-4">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Orchestra YAML</h3>
          <textarea
            phx-blur="update_yaml"
            phx-value-yaml={@yaml_content}
            name="yaml"
            rows="16"
            class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-cortex-500 focus:border-cortex-500 resize-y"
            placeholder="Paste your orchestra.yaml content here..."
          >{@yaml_content}</textarea>
        </div>

        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 mb-4">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Or Load From File</h3>
          <input
            type="text"
            phx-blur="update_path"
            name="path"
            value={@file_path}
            class="w-full bg-gray-950 border border-gray-700 rounded-lg p-3 text-sm font-mono text-gray-300 focus:ring-cortex-500 focus:border-cortex-500"
            placeholder="/path/to/orchestra.yaml"
          />
        </div>

        <div class="flex gap-3">
          <button
            phx-click="validate"
            class="inline-flex items-center rounded-md bg-gray-700 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-gray-600"
          >
            Validate
          </button>
          <button
            :if={@validation_result == :ok}
            phx-click="launch"
            class="inline-flex items-center rounded-md bg-cortex-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-cortex-500"
          >
            Launch Run
          </button>
        </div>
      </div>

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

  defp safe_create_run(attrs) do
    Cortex.Store.create_run(attrs)
  rescue
    e -> {:error, e}
  end

  defp spawn_orchestration(_run, _config) do
    # In Phase 5, we just create the Run record.
    # Full orchestration integration will come in a later phase.
    :ok
  end
end
