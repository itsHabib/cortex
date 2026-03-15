defmodule CortexWeb.TeamDetailLive do
  use CortexWeb, :live_view

  @impl true
  def mount(%{"id" => run_id, "name" => team_name}, _session, socket) do
    if connected?(socket), do: safe_subscribe()

    run = safe_get_run(run_id)
    team_run = safe_get_team_run(run_id, team_name)

    team_config = extract_team_config(run, team_name)
    team_members = extract_members(run, team_name)
    log_content = read_log(team_run)

    {:ok,
     assign(socket,
       run: run,
       run_id: run_id,
       team_name: team_name,
       team_run: team_run,
       team_config: team_config,
       team_members: team_members,
       log_content: log_content,
       active_tab: "result",
       page_title: "Team: #{team_name}"
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def handle_info(%{type: :team_completed, payload: _payload}, socket) do
    team_run = safe_get_team_run(socket.assigns.run_id, socket.assigns.team_name)
    log_content = read_log(team_run)
    run = safe_get_run(socket.assigns.run_id)

    {:noreply, assign(socket, team_run: team_run, log_content: log_content, run: run)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@team_name}
      <:subtitle>
        <%= if @team_run do %>
          <.status_badge status={@team_run.status || "pending"} />
          <span :if={@team_run.role} class="ml-2 text-gray-400">{@team_run.role}</span>
          <span class="ml-2 text-gray-400"><.token_display input={team_input_tokens(@team_run)} output={team_output_tokens(@team_run)} /></span>
          <span class="ml-2 text-gray-400"><.duration_display ms={team_duration(@team_run)} /></span>
        <% else %>
          <span class="text-gray-400">Team not found in this run</span>
        <% end %>
      </:subtitle>
      <:actions>
        <a href={"/runs/#{@run_id}"} class="text-sm text-gray-400 hover:text-white">Back to Run</a>
      </:actions>
    </.header>

    <!-- Team Members -->
    <div :if={@team_members != []} class="mb-6 bg-gray-900 rounded-lg border border-gray-800 p-4">
      <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Team Members</h3>
      <div class="space-y-2">
        <div :for={member <- @team_members} class="flex items-start gap-3">
          <span class="inline-flex items-center rounded bg-cortex-900 px-2 py-0.5 text-xs font-medium text-cortex-300 shrink-0">
            {member.role}
          </span>
          <span :if={member.focus} class="text-sm text-gray-400">{member.focus}</span>
        </div>
      </div>
    </div>

    <!-- Tabs -->
    <div class="flex border-b border-gray-800 mb-6">
      <button
        :for={tab <- ~w(result log config prompt)}
        phx-click="switch_tab"
        phx-value-tab={tab}
        class={[
          "px-4 py-2 text-sm font-medium border-b-2 transition-colors",
          if(@active_tab == tab,
            do: "text-cortex-400 border-cortex-400",
            else: "text-gray-400 border-transparent hover:text-gray-200 hover:border-gray-600"
          )
        ]}
      >
        {String.capitalize(tab)}
      </button>
    </div>

    <!-- Tab Content -->
    <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
      <%= case @active_tab do %>
        <% "result" -> %>
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Result Summary</h3>
          <%= if @team_run && @team_run.result_summary do %>
            <div class="prose prose-invert max-w-none">
              <pre class="whitespace-pre-wrap text-sm text-gray-300 font-sans">{@team_run.result_summary}</pre>
            </div>
          <% else %>
            <p class="text-gray-500">No result summary available.</p>
          <% end %>

        <% "log" -> %>
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Log Output</h3>
          <%= if @log_content do %>
            <pre class="bg-gray-950 rounded p-4 text-xs text-gray-300 font-mono overflow-auto max-h-96">{@log_content}</pre>
          <% else %>
            <p class="text-gray-500">No log file available.</p>
          <% end %>

        <% "config" -> %>
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Team Configuration</h3>
          <%= if @team_config do %>
            <pre class="bg-gray-950 rounded p-4 text-xs text-gray-300 font-mono overflow-auto max-h-96">{@team_config}</pre>
          <% else %>
            <p class="text-gray-500">No configuration available.</p>
          <% end %>

        <% "prompt" -> %>
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Prompt</h3>
          <%= if @team_run && @team_run.prompt do %>
            <pre class="bg-gray-950 rounded p-4 text-xs text-gray-300 font-mono overflow-auto max-h-96 whitespace-pre-wrap">{@team_run.prompt}</pre>
          <% else %>
            <p class="text-gray-500">No prompt available.</p>
          <% end %>

        <% _ -> %>
          <p class="text-gray-500">Unknown tab.</p>
      <% end %>
    </div>
    """
  end

  # -- Private helpers --

  defp safe_get_run(id) do
    Cortex.Store.get_run(id)
  rescue
    _ -> nil
  end

  defp safe_get_team_run(run_id, team_name) do
    Cortex.Store.get_team_run(run_id, team_name)
  rescue
    _ -> nil
  end

  defp safe_subscribe do
    Cortex.Events.subscribe()
  rescue
    _ -> :ok
  end

  defp team_input_tokens(nil), do: nil
  defp team_input_tokens(team_run), do: team_run.input_tokens

  defp team_output_tokens(nil), do: nil
  defp team_output_tokens(team_run), do: team_run.output_tokens

  defp team_duration(nil), do: nil
  defp team_duration(team_run), do: team_run.duration_ms

  defp extract_team_config(nil, _team_name), do: nil

  defp extract_team_config(run, team_name) do
    if run.config_yaml do
      case YamlElixir.read_from_string(run.config_yaml) do
        {:ok, raw} ->
          teams = Map.get(raw, "teams", [])

          case Enum.find(teams, fn t -> Map.get(t, "name") == team_name end) do
            nil -> nil
            team_map -> Jason.encode!(team_map, pretty: true)
          end

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp extract_members(nil, _team_name), do: []

  defp extract_members(run, team_name) do
    if run.config_yaml do
      case YamlElixir.read_from_string(run.config_yaml) do
        {:ok, raw} ->
          teams = Map.get(raw, "teams", [])

          case Enum.find(teams, fn t -> Map.get(t, "name") == team_name end) do
            nil ->
              []

            team_map ->
              (Map.get(team_map, "members") || [])
              |> Enum.map(fn m ->
                %{role: Map.get(m, "role", ""), focus: Map.get(m, "focus")}
              end)
          end

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp read_log(nil), do: nil

  defp read_log(team_run) do
    if team_run.log_path && File.exists?(team_run.log_path) do
      case File.read(team_run.log_path) do
        {:ok, content} -> content
        _ -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end
end
