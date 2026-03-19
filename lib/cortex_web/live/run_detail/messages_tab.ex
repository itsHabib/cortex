defmodule CortexWeb.RunDetail.MessagesTab do
  @moduledoc """
  Messages tab for RunDetailLive.

  Renders the message viewer with team selector and send form.
  Stateless function component.
  """
  use Phoenix.Component

  alias CortexWeb.RunDetail.Helpers

  @doc """
  Renders the messages tab content.
  """
  attr(:run, :map, required: true)
  attr(:team_names, :list, required: true)
  attr(:messages_team, :any, default: nil)
  attr(:team_inbox, :list, default: [])
  attr(:msg_to, :string, default: "")
  attr(:msg_content, :string, default: "")

  def messages_tab(assigns) do
    ~H"""
    <div>
      <%= if @run.workspace_path do %>
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div class="lg:col-span-2 space-y-4">
            <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
              <div class="flex items-center gap-3">
                <label class="text-sm text-gray-400 shrink-0">{String.capitalize(Helpers.participant_label(@run, :singular))}:</label>
                <form phx-change="select_messages_team" class="flex-1">
                  <select
                    name="team"
                    class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                  >
                    <option value="">Select {Helpers.participant_label(@run, :singular)}...</option>
                    <option value="coordinator" selected={@messages_team == "coordinator"}>[internal] coordinator</option>
                    <option :for={name <- @team_names} value={name} selected={name == @messages_team}>
                      {name}
                    </option>
                  </select>
                </form>
                <button
                  :if={@messages_team}
                  phx-click="refresh_messages"
                  class="text-xs text-gray-500 hover:text-gray-300 px-2 py-1 rounded border border-gray-700 hover:border-gray-500"
                >
                  Refresh
                </button>
              </div>
            </div>

            <div :if={@messages_team} class="bg-gray-900 rounded-lg border border-gray-800 p-4">
              <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">
                Inbox ({length(@team_inbox)} messages to {@messages_team})
              </h3>
              <%= if @team_inbox == [] do %>
                <p class="text-gray-500 text-sm">No messages received.</p>
              <% else %>
                <div class="space-y-2 max-h-[40vh] overflow-y-auto">
                  <div :for={msg <- @team_inbox} class="bg-gray-950 rounded p-3 text-sm">
                    <div class="flex items-center justify-between mb-1">
                      <span class="text-cortex-400 font-medium">from: {Map.get(msg, "from", "?")}</span>
                      <span class="text-gray-500 text-xs">{Map.get(msg, "timestamp", "")}</span>
                    </div>
                    <p class="text-gray-300">{Map.get(msg, "content", "")}</p>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 h-fit">
            <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Send Message</h2>
            <form phx-submit="send_message" phx-change="form_update" class="space-y-3">
              <div>
                <label class="text-xs text-gray-500 block mb-1">To</label>
                <select
                  name="to"
                  class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300"
                >
                  <option value="">Select recipient...</option>
                  <option value="coordinator" selected={@msg_to == "coordinator"}>[coordinator]</option>
                  <option :for={name <- @team_names} value={name} selected={name == @msg_to}>
                    {name}
                  </option>
                </select>
              </div>
              <div>
                <label class="text-xs text-gray-500 block mb-1">Message</label>
                <textarea
                  name="content"
                  rows="4"
                  class="w-full bg-gray-950 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-300 resize-y"
                  placeholder="Type your message..."
                ><%= @msg_content %></textarea>
              </div>
              <button
                type="submit"
                class="w-full rounded bg-cortex-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-cortex-500"
              >
                Send
              </button>
            </form>
          </div>
        </div>
      <% else %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <p class="text-gray-500">No workspace path available. Messages require a workspace with .cortex/ directory.</p>
        </div>
      <% end %>
    </div>
    """
  end
end
