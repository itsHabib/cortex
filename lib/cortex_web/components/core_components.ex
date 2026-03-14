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
  Renders a colored status badge.

  ## Examples

      <.status_badge status="running" />
      <.status_badge status="completed" />
  """
  attr(:status, :string, required: true)

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
      status_color(@status)
    ]}>
      {@status}
    </span>
    """
  end

  defp status_color("pending"), do: "bg-gray-700 text-gray-300"
  defp status_color("running"), do: "bg-blue-900/60 text-blue-300 ring-1 ring-blue-500/30"

  defp status_color("completed"),
    do: "bg-emerald-900/60 text-emerald-300 ring-1 ring-emerald-500/30"

  defp status_color("done"), do: "bg-emerald-900/60 text-emerald-300 ring-1 ring-emerald-500/30"
  defp status_color("failed"), do: "bg-rose-900/60 text-rose-300 ring-1 ring-rose-500/30"
  defp status_color(_), do: "bg-gray-700 text-gray-300"

  @doc """
  Formats and displays a USD cost amount.

  ## Examples

      <.cost_display amount={0.0523} />
      <.cost_display amount={nil} />
  """
  attr(:amount, :float, default: nil)

  def cost_display(assigns) do
    ~H"""
    <span class="text-sm font-mono text-gray-300">
      {format_cost(@amount)}
    </span>
    """
  end

  defp format_cost(nil), do: "--"

  defp format_cost(amount) when is_number(amount),
    do: "$#{:erlang.float_to_binary(amount / 1, decimals: 4)}"

  defp format_cost(_), do: "--"

  @doc """
  Formats and displays duration from milliseconds.

  ## Examples

      <.duration_display ms={123456} />
      <.duration_display ms={nil} />
  """
  attr(:ms, :integer, default: nil)

  def duration_display(assigns) do
    ~H"""
    <span class="text-sm font-mono text-gray-300">
      {format_duration(@ms)}
    </span>
    """
  end

  defp format_duration(nil), do: "--"

  defp format_duration(ms) when is_integer(ms) do
    cond do
      ms < 1_000 ->
        "#{ms}ms"

      ms < 60_000 ->
        "#{Float.round(ms / 1_000, 1)}s"

      ms < 3_600_000 ->
        minutes = div(ms, 60_000)
        seconds = div(rem(ms, 60_000), 1_000)
        "#{minutes}m #{seconds}s"

      true ->
        hours = div(ms, 3_600_000)
        minutes = div(rem(ms, 3_600_000), 60_000)
        "#{hours}h #{minutes}m"
    end
  end

  defp format_duration(_), do: "--"

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
