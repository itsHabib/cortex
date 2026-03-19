defmodule CortexWeb.RunDetail.ActivityTab do
  @moduledoc """
  Activity tab for RunDetailLive.

  Renders the full activity feed with team filter.
  Stateless function component.
  """
  use Phoenix.Component

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the activity tab content.
  """
  attr(:run, :map, required: true)
  attr(:activities, :list, required: true)
  attr(:activity_team, :any, default: nil)
  attr(:team_names, :list, required: true)
  attr(:expanded_activities, :any, required: true)

  def activity_tab(assigns) do
    visible = filtered_activities(assigns.activities, assigns.activity_team)
    assigns = assign(assigns, :visible, visible)

    ~H"""
    <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
      <div class="flex items-center gap-3 mb-3">
        <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider">Activity Feed</h2>
        <form phx-change="select_activity_team" class="flex-1 max-w-xs">
          <select
            name="team"
            class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1 text-xs text-gray-300"
          >
            <option value="">All {Helpers.participant_label(@run, :lower_plural)}</option>
            <option :for={name <- @team_names} value={name} selected={name == @activity_team}>
              {name}
            </option>
          </select>
        </form>
        <span class="text-xs text-gray-600 ml-auto">{length(@visible)} events</span>
      </div>
      <%= if @visible == [] do %>
        <p class="text-gray-500 text-sm">No activity yet. Events appear here in real-time and clear on page reload.</p>
      <% else %>
        <div class="space-y-0.5 min-h-[60vh] max-h-[80vh] overflow-y-auto" id="activity-feed">
          <%= for {entry, idx} <- Enum.with_index(@visible) do %>
            <% expanded = MapSet.member?(@expanded_activities, idx) %>
            <div
              phx-click="toggle_activity"
              phx-value-index={idx}
              class={["flex items-start gap-2 text-sm py-1 px-1 rounded cursor-pointer transition-colors", if(expanded, do: "bg-gray-800/40", else: "hover:bg-gray-800/20")]}
            >
              <span class="text-gray-600 text-xs shrink-0 mt-0.5">{entry.at}</span>
              <span class={Helpers.activity_icon_class(entry.kind)}>{Helpers.activity_icon(entry.kind)}</span>
              <span class="text-cortex-400 font-medium shrink-0">{entry.team}:</span>
              <%= if expanded do %>
                <span class="text-gray-300 break-all min-w-0">{entry.text}</span>
              <% else %>
                <span class="text-gray-300 truncate min-w-0">{entry.text}</span>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp filtered_activities(activities, nil), do: activities

  defp filtered_activities(activities, team_name) do
    Enum.filter(activities, fn entry -> entry.team == team_name end)
  end
end
