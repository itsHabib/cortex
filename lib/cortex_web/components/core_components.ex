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
  defp status_color("stopped"), do: "bg-orange-900/60 text-orange-300 ring-1 ring-orange-500/30"
  defp status_color("stalled"), do: "bg-yellow-900/60 text-yellow-300 ring-1 ring-yellow-500/30"
  defp status_color(_), do: "bg-gray-700 text-gray-300"

  @doc """
  Formats and displays token counts (input/output).

  ## Examples

      <.token_display input={16584} output={45} />
      <.token_display input={nil} output={nil} />
  """
  attr(:input, :integer, default: nil)
  attr(:output, :integer, default: nil)

  def token_display(assigns) do
    ~H"""
    <span class="text-sm font-mono text-gray-300">
      {format_token_pair(@input, @output)}
    </span>
    """
  end

  @doc """
  Click-to-expand token breakdown showing cache details.

  Shows compact "in / out" by default. Click to reveal:
  input, cache read, cache creation, and output.

  ## Examples

      <.token_detail
        input={16584}
        output={45}
        cache_read={12000}
        cache_creation={3000}
      />
  """
  attr(:input, :integer, default: nil)
  attr(:output, :integer, default: nil)
  attr(:cache_read, :integer, default: nil)
  attr(:cache_creation, :integer, default: nil)
  attr(:id, :string, required: true)

  def token_detail(assigns) do
    combined_input =
      (assigns.input || 0) + (assigns.cache_read || 0) + (assigns.cache_creation || 0)

    assigns = assign(assigns, :combined_input, combined_input)

    ~H"""
    <span class="relative inline-block">
      <button
        phx-click={JS.toggle(to: "##{@id}-detail")}
        class="text-sm font-mono text-gray-300 hover:text-cortex-300 transition-colors cursor-pointer"
        title="Click for token breakdown"
      >
        {format_token_pair(@combined_input, @output)}
      </button>
      <div
        id={"#{@id}-detail"}
        class="hidden absolute z-20 top-full left-0 mt-1 bg-gray-900 border border-gray-700 rounded-lg p-3 shadow-xl min-w-[200px]"
        phx-click-away={JS.hide(to: "##{@id}-detail")}
      >
        <div class="space-y-1.5 text-xs font-mono">
          <div class="flex justify-between gap-4">
            <span class="text-gray-500">Input</span>
            <span class="text-gray-300">{format_token_count(@input)}</span>
          </div>
          <div class="flex justify-between gap-4">
            <span class="text-gray-500">Cache Read</span>
            <span class="text-emerald-400">{format_token_count(@cache_read)}</span>
          </div>
          <div class="flex justify-between gap-4">
            <span class="text-gray-500">Cache Create</span>
            <span class="text-yellow-400">{format_token_count(@cache_creation)}</span>
          </div>
          <div class="border-t border-gray-700 pt-1.5 flex justify-between gap-4">
            <span class="text-gray-500">Output</span>
            <span class="text-gray-300">{format_token_count(@output)}</span>
          </div>
        </div>
      </div>
    </span>
    """
  end

  defp format_token_count(nil), do: "0"
  defp format_token_count(0), do: "0"
  defp format_token_count(n) when is_integer(n) and n < 1_000, do: Integer.to_string(n)

  defp format_token_count(n) when is_integer(n) do
    value = n / 1_000
    formatted = :erlang.float_to_binary(value, decimals: 1)

    formatted =
      if String.ends_with?(formatted, ".0") do
        String.trim_trailing(formatted, ".0")
      else
        formatted
      end

    "#{formatted}K"
  end

  defp format_token_count(_), do: "0"

  defp format_token_pair(nil, nil), do: "--"

  defp format_token_pair(input, output) do
    "#{format_token_count(input)} in / #{format_token_count(output)} out"
  end

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
