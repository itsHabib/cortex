defmodule CortexWeb.ModeComponents do
  @moduledoc """
  Mode selector component for the Cortex UI.

  Provides a tab-based selector for coordination modes (DAG, Mesh, Gossip)
  with named slots for per-mode config panel content.
  """
  use Phoenix.Component

  # -- Mode Selector --

  @doc """
  Renders a tab-based coordination mode selector with named slots for
  per-mode config panels.

  The parent LiveView provides the config form content via named slots.
  The component handles the tab/selection UI and renders the active slot.

  ## Examples

      <.mode_selector selected="dag" on_select="select_mode">
        <:dag_config>DAG config form here</:dag_config>
        <:mesh_config>Mesh config form here</:mesh_config>
        <:gossip_config>Gossip config form here</:gossip_config>
      </.mode_selector>
  """
  attr(:selected, :string, required: true)
  attr(:on_select, :string, default: nil)
  attr(:class, :string, default: nil)

  slot(:dag_config)
  slot(:mesh_config)
  slot(:gossip_config)

  def mode_selector(assigns) do
    ~H"""
    <div class={["space-y-4", @class]}>
      <%!-- Tab bar --%>
      <div class="flex gap-1 bg-gray-950 rounded-lg p-1" role="tablist" aria-label="Coordination mode">
        <.mode_tab
          mode="dag"
          label="DAG Workflow"
          selected={@selected == "dag"}
          on_select={@on_select}
        />
        <.mode_tab
          mode="mesh"
          label="Mesh"
          selected={@selected == "mesh"}
          on_select={@on_select}
        />
        <.mode_tab
          mode="gossip"
          label="Gossip"
          selected={@selected == "gossip"}
          on_select={@on_select}
        />
      </div>

      <%!-- Config panel --%>
      <div :if={@selected == "dag"} role="tabpanel" aria-label="DAG workflow configuration">
        {render_slot(@dag_config)}
      </div>
      <div :if={@selected == "mesh"} role="tabpanel" aria-label="Mesh configuration">
        {render_slot(@mesh_config)}
      </div>
      <div :if={@selected == "gossip"} role="tabpanel" aria-label="Gossip configuration">
        {render_slot(@gossip_config)}
      </div>
    </div>
    """
  end

  # -- Private: Mode Tab --

  attr(:mode, :string, required: true)
  attr(:label, :string, required: true)
  attr(:selected, :boolean, required: true)
  attr(:on_select, :string, default: nil)

  defp mode_tab(assigns) do
    ~H"""
    <button
      phx-click={@on_select}
      phx-value-mode={@mode}
      class={[
        "flex-1 px-4 py-2 text-sm font-medium rounded-md transition-colors",
        if(@selected,
          do: "bg-gray-800 text-white shadow-sm",
          else: "text-gray-400 hover:text-gray-300"
        )
      ]}
      role="tab"
      aria-selected={to_string(@selected)}
      aria-controls={"#{@mode}-config"}
    >
      <div class="flex items-center justify-center gap-2">
        <span class={mode_indicator_class(@mode, @selected)}>&#9679;</span>
        {@label}
      </div>
    </button>
    """
  end

  defp mode_indicator_class("dag", true), do: "text-cortex-400 text-xs"
  defp mode_indicator_class("dag", false), do: "text-gray-600 text-xs"
  defp mode_indicator_class("mesh", true), do: "text-blue-400 text-xs"
  defp mode_indicator_class("mesh", false), do: "text-gray-600 text-xs"
  defp mode_indicator_class("gossip", true), do: "text-purple-400 text-xs"
  defp mode_indicator_class("gossip", false), do: "text-gray-600 text-xs"
  defp mode_indicator_class(_, _), do: "text-gray-600 text-xs"
end
