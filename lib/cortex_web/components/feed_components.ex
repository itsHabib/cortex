defmodule CortexWeb.FeedComponents do
  @moduledoc """
  Activity feed components for the Cortex UI.

  Provides a timestamped event stream with icon and color coding per event type.
  Replaces inline feed rendering in MeshLive, GossipLive, and RunDetailLive.
  """
  use Phoenix.Component

  # -- Activity Feed --

  @doc """
  Renders a scrollable activity feed of timestamped events.

  Each entry has a type (atom), name (string), optional detail, and timestamp.

  ## Examples

      <.activity_feed activities={activities} />
      <.activity_feed activities={activities} max={25} />
  """
  attr(:activities, :list, required: true)
  attr(:max, :integer, default: 50)
  attr(:class, :string, default: nil)

  def activity_feed(assigns) do
    visible = Enum.take(assigns.activities, assigns.max)
    assigns = assign(assigns, :visible, visible)

    ~H"""
    <div class={@class}>
      <%= if @visible != [] do %>
        <div class="space-y-1 max-h-[50vh] overflow-y-auto" role="log" aria-label="Activity feed">
          <.activity_entry :for={entry <- @visible} entry={entry} />
        </div>
      <% else %>
        <p class="text-gray-500 text-sm">Waiting for events...</p>
      <% end %>
    </div>
    """
  end

  # -- Activity Entry --

  @doc """
  Renders a single activity feed entry with icon, name, detail, and timestamp.

  ## Examples

      <.activity_entry entry={%{type: :member_joined, name: "alpha", detail: nil, timestamp: ~U[...]}} />
  """
  attr(:entry, :map, required: true)
  attr(:class, :string, default: nil)

  def activity_entry(assigns) do
    ~H"""
    <div class={["flex items-center gap-2 text-xs py-1 border-b border-gray-800/50", @class]}>
      <span class="text-gray-700 font-mono w-16 shrink-0">
        {format_time(Map.get(@entry, :timestamp))}
      </span>
      <span class={activity_icon_class(@entry.type)}>{activity_icon(@entry.type)}</span>
      <span class="text-gray-300">{@entry.name}</span>
      <span :if={Map.get(@entry, :detail)} class="text-gray-600">{@entry.detail}</span>
    </div>
    """
  end

  # -- Activity icons and colors --

  defp activity_icon(:mesh_started), do: ">"
  defp activity_icon(:mesh_completed), do: "#"
  defp activity_icon(:gossip_started), do: ">"
  defp activity_icon(:gossip_completed), do: "#"
  defp activity_icon(:member_joined), do: "+"
  defp activity_icon(:member_alive), do: "*"
  defp activity_icon(:member_suspect), do: "?"
  defp activity_icon(:member_dead), do: "x"
  defp activity_icon(:member_left), do: "<"
  defp activity_icon(:team_activity), do: "!"
  defp activity_icon(:team_progress), do: ">"
  defp activity_icon(:run_started), do: ">"
  defp activity_icon(:run_completed), do: "#"
  defp activity_icon(:run_failed), do: "x"
  defp activity_icon(:tier_completed), do: "#"
  defp activity_icon(:team_started), do: "+"
  defp activity_icon(:team_completed), do: "#"
  defp activity_icon(:team_failed), do: "x"
  defp activity_icon(_), do: "."

  defp activity_icon_class(:member_joined), do: "text-green-400"
  defp activity_icon_class(:member_alive), do: "text-blue-400"
  defp activity_icon_class(:member_suspect), do: "text-yellow-400"
  defp activity_icon_class(:member_dead), do: "text-red-400"
  defp activity_icon_class(:member_left), do: "text-gray-400"
  defp activity_icon_class(:mesh_started), do: "text-cortex-400"
  defp activity_icon_class(:mesh_completed), do: "text-cortex-400"
  defp activity_icon_class(:gossip_started), do: "text-purple-400"
  defp activity_icon_class(:gossip_completed), do: "text-purple-400"
  defp activity_icon_class(:team_progress), do: "text-purple-400"
  defp activity_icon_class(:team_activity), do: "text-cortex-400"
  defp activity_icon_class(:run_started), do: "text-blue-400"
  defp activity_icon_class(:run_completed), do: "text-green-400"
  defp activity_icon_class(:run_failed), do: "text-red-400"
  defp activity_icon_class(:tier_completed), do: "text-emerald-400"
  defp activity_icon_class(:team_started), do: "text-blue-400"
  defp activity_icon_class(:team_completed), do: "text-green-400"
  defp activity_icon_class(:team_failed), do: "text-red-400"
  defp activity_icon_class(_), do: "text-gray-500"

  defp format_time(nil), do: "\u2014"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: "\u2014"
end
