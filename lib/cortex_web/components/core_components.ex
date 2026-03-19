defmodule CortexWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for the Cortex dashboard.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash messages.
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages")
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup")
  attr(:title, :string, default: nil)

  slot(:inner_block, doc: "the optional inner block that renders the message")

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-4 right-4 z-50 w-80 rounded-lg p-4 shadow-lg ring-1",
        @kind == :info && "bg-emerald-900/80 text-emerald-200 ring-emerald-500/20",
        @kind == :error && "bg-rose-900/80 text-rose-200 ring-rose-500/20"
      ]}
    >
      <p :if={@title} class="flex items-center gap-1.5 text-sm font-semibold leading-6">
        {@title}
      </p>
      <p class="mt-1 text-sm leading-5">{msg}</p>
      <button type="button" class="absolute top-2 right-2 text-current opacity-40 hover:opacity-80" aria-label="close">
        &#x2715;
      </button>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard flash names.
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group")

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} flash={@flash} title="Success" />
      <.flash kind={:error} flash={@flash} title="Error" />
    </div>
    """
  end

  @doc """
  Renders a page header with title.

  ## Examples

      <.header>Dashboard</.header>
      <.header>Run Detail</.header>
  """
  attr(:class, :string, default: nil)

  slot(:inner_block, required: true)
  slot(:subtitle)
  slot(:actions)

  def header(assigns) do
    ~H"""
    <header class={["mb-6", @class]}>
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-white">
            {render_slot(@inner_block)}
          </h1>
          <p :for={subtitle <- @subtitle} class="mt-1 text-sm text-gray-400">
            {render_slot(subtitle)}
          </p>
        </div>
        <div :for={actions <- @actions} class="flex items-center gap-3">
          {render_slot(actions)}
        </div>
      </div>
    </header>
    """
  end

  @doc """
  Renders a slide-over panel that slides in from the right edge.

  Used for detail panels (e.g., team detail in Runs page).

  ## Examples

      <.slide_over show={@show_panel} on_close="close_panel" title="Details">
        Panel content here
      </.slide_over>
  """
  attr(:show, :boolean, default: false)
  attr(:on_close, :string, default: nil)
  attr(:title, :string, default: nil)
  attr(:id, :string, default: "slide-over")
  attr(:class, :string, default: nil)

  slot(:inner_block, required: true)

  def slide_over(assigns) do
    ~H"""
    <div
      :if={@show}
      id={@id}
      class="fixed inset-0 z-40 overflow-hidden"
      aria-labelledby={"#{@id}-title"}
      role="dialog"
      aria-modal="true"
    >
      <%!-- Backdrop --%>
      <div
        class="absolute inset-0 bg-black/50 transition-opacity"
        phx-click={@on_close}
        aria-hidden="true"
      />

      <%!-- Panel --%>
      <div class="absolute inset-y-0 right-0 flex max-w-full pl-10">
        <div class={[
          "w-screen max-w-md transform transition-transform",
          @class
        ]}>
          <div class="h-full bg-gray-900 border-l border-gray-800 shadow-xl flex flex-col">
            <%!-- Header --%>
            <div class="flex items-center justify-between px-4 py-3 border-b border-gray-800">
              <h2
                :if={@title}
                id={"#{@id}-title"}
                class="text-lg font-semibold text-white"
              >
                {@title}
              </h2>
              <button
                :if={@on_close}
                phx-click={@on_close}
                class="text-gray-500 hover:text-gray-300 transition-colors"
                aria-label="Close panel"
              >
                &#x2715;
              </button>
            </div>

            <%!-- Content --%>
            <div class="flex-1 overflow-y-auto p-4">
              {render_slot(@inner_block)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  JS command to hide an element.
  """
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end
end
