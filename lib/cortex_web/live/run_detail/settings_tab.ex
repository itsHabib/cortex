defmodule CortexWeb.RunDetail.SettingsTab do
  @moduledoc """
  Settings tab for RunDetailLive.

  Renders run config, metadata, team summary table, and raw YAML
  viewer. Stateless function component.
  """
  use Phoenix.Component

  import CortexWeb.StatusComponents
  import CortexWeb.TokenComponents, except: [format_token_count: 1, format_number: 1]

  alias Cortex.Orchestration.Config.Loader, as: ConfigLoader
  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the settings tab content.
  """
  attr(:run, :map, required: true)
  attr(:team_runs, :list, required: true)
  attr(:tiers, :list, required: true)

  def settings_tab(assigns) do
    config = parse_run_config(assigns.run)
    assigns = assign(assigns, :config, config)

    ~H"""
    <div class="space-y-4">
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
        <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Run</h2>
        <dl class="grid grid-cols-1 md:grid-cols-2 gap-x-6 gap-y-3">
          <div>
            <dt class="text-xs text-gray-500">Name</dt>
            <dd class="text-sm text-gray-200 font-mono">{@run.name || "Untitled"}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-500">ID</dt>
            <dd class="text-sm text-gray-400 font-mono text-xs">{@run.id}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-500">Status</dt>
            <dd><.status_badge status={@run.status} /></dd>
          </div>
          <div>
            <dt class="text-xs text-gray-500">Mode</dt>
            <dd class="text-sm text-gray-200">{@run.mode || "workflow"}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-500">Workspace Path</dt>
            <dd class="text-sm text-gray-200 font-mono">{@run.workspace_path || "--"}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-500">Created</dt>
            <dd class="text-sm text-gray-200">{Helpers.format_datetime(@run.inserted_at)}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-500">Started</dt>
            <dd class="text-sm text-gray-200">{Helpers.format_datetime(@run.started_at)}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-500">Completed</dt>
            <dd class="text-sm text-gray-200">{Helpers.format_datetime(@run.completed_at)}</dd>
          </div>
        </dl>
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
        <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Execution</h2>
        <dl class="grid grid-cols-2 md:grid-cols-4 gap-x-6 gap-y-3">
          <div>
            <dt class="text-xs text-gray-500">{Helpers.participant_label(@run, :plural)}</dt>
            <dd class="text-sm text-gray-200">{Enum.count(@team_runs, &(not &1.internal))}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-500">{cond do
              Helpers.gossip?(@run) -> "Rounds"
              Helpers.mesh?(@run) -> "Mode"
              true -> "Tiers"
            end}</dt>
            <dd class="text-sm text-gray-200">{cond do
              Helpers.gossip?(@run) -> (Helpers.parse_gossip_info(@run) || %{rounds: 0}).rounds
              Helpers.mesh?(@run) -> "autonomous"
              true -> length(@tiers)
            end}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-500">Tokens</dt>
            <dd class="text-sm text-gray-200"><.token_display input={Helpers.sum_team_field(@team_runs, :input_tokens)} output={Helpers.sum_team_field(@team_runs, :output_tokens)} /></dd>
          </div>
          <div>
            <dt class="text-xs text-gray-500">Duration</dt>
            <dd class="text-sm text-gray-200"><.duration_display ms={@run.total_duration_ms} /></dd>
          </div>
        </dl>
      </div>

      <%= if @config do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Defaults</h2>
          <dl class="grid grid-cols-2 md:grid-cols-4 gap-x-6 gap-y-3">
            <div>
              <dt class="text-xs text-gray-500">Model</dt>
              <dd class="text-sm text-gray-200">{@config.defaults.model}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500">Max Turns</dt>
              <dd class="text-sm text-gray-200">{@config.defaults.max_turns}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500">Permission Mode</dt>
              <dd class="text-sm text-gray-200">{@config.defaults.permission_mode}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500">Timeout</dt>
              <dd class="text-sm text-gray-200">{@config.defaults.timeout_minutes}m</dd>
            </div>
          </dl>
        </div>

        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">{Helpers.participant_label(@run, :plural)}</h2>
          <div class="overflow-x-auto">
            <table class="w-full">
              <thead>
                <tr class="border-b border-gray-800">
                  <th class="text-left text-xs font-medium text-gray-500 uppercase px-3 py-2">Name</th>
                  <th class="text-left text-xs font-medium text-gray-500 uppercase px-3 py-2">Lead</th>
                  <th class="text-left text-xs font-medium text-gray-500 uppercase px-3 py-2">Model</th>
                  <th class="text-left text-xs font-medium text-gray-500 uppercase px-3 py-2">Members</th>
                  <th class="text-left text-xs font-medium text-gray-500 uppercase px-3 py-2">Tasks</th>
                  <th class="text-left text-xs font-medium text-gray-500 uppercase px-3 py-2">Depends On</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={team <- @config.teams} class="border-b border-gray-800/50">
                  <td class="px-3 py-2 text-sm text-cortex-400 font-medium">{team.name}</td>
                  <td class="px-3 py-2 text-sm text-gray-300">{team.lead.role}</td>
                  <td class="px-3 py-2 text-sm text-gray-400">{team.lead.model || @config.defaults.model}</td>
                  <td class="px-3 py-2 text-sm text-gray-400">{length(team.members)}</td>
                  <td class="px-3 py-2 text-sm text-gray-400">{length(team.tasks)}</td>
                  <td class="px-3 py-2 text-sm text-gray-400 font-mono">
                    {if team.depends_on == [], do: "--", else: Enum.join(team.depends_on, ", ")}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>

      <%= if @run.config_yaml do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">orchestra.yaml</h2>
          <pre class="bg-gray-950 rounded p-4 text-xs text-gray-300 font-mono overflow-auto max-h-[60vh] whitespace-pre-wrap">{@run.config_yaml}</pre>
        </div>
      <% end %>
    </div>
    """
  end

  defp parse_run_config(run) do
    with yaml when is_binary(yaml) <- run.config_yaml,
         {:ok, config, _warnings} <- ConfigLoader.load_string(yaml) do
      config
    else
      _ -> nil
    end
  end
end
