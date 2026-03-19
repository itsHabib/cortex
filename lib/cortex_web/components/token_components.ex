defmodule CortexWeb.TokenComponents do
  @moduledoc """
  Token, cost, and duration display components for the Cortex UI.

  Provides consistent formatting for token counts, cost in USD, and
  duration values across all pages. Consolidates the formatting logic
  previously split between CoreComponents and inline helpers in
  MeshLive/GossipLive.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # -- Token Display --

  @doc """
  Formats and displays token counts (input/output) in a compact format.

  ## Examples

      <.token_display input={16584} output={45} />
      <.token_display input={nil} output={nil} />
  """
  attr(:input, :integer, default: nil)
  attr(:output, :integer, default: nil)
  attr(:class, :string, default: nil)

  def token_display(assigns) do
    ~H"""
    <span class={["text-sm font-mono text-gray-300", @class]}>
      {format_token_pair(@input, @output)}
    </span>
    """
  end

  # -- Token Detail --

  @doc """
  Click-to-expand token breakdown showing cache details.

  Shows compact "in / out" by default. Click to reveal:
  input, cache read, cache creation, and output.

  ## Examples

      <.token_detail
        id="run-1"
        input={16584}
        output={45}
        cache_read={12000}
        cache_creation={3000}
      />
  """
  attr(:id, :string, required: true)
  attr(:input, :integer, default: nil)
  attr(:output, :integer, default: nil)
  attr(:cache_read, :integer, default: nil)
  attr(:cache_creation, :integer, default: nil)
  attr(:class, :string, default: nil)

  def token_detail(assigns) do
    combined_input =
      (assigns.input || 0) + (assigns.cache_read || 0) + (assigns.cache_creation || 0)

    assigns = assign(assigns, :combined_input, combined_input)

    ~H"""
    <span class={["relative inline-block", @class]}>
      <button
        phx-click={JS.toggle(to: "##{@id}-detail")}
        class="text-sm font-mono text-gray-300 hover:text-cortex-300 transition-colors cursor-pointer"
        title="Click for token breakdown"
        aria-expanded="false"
        aria-controls={"#{@id}-detail"}
      >
        {format_token_pair(@combined_input, @output)}
      </button>
      <div
        id={"#{@id}-detail"}
        class="hidden absolute z-20 top-full left-0 mt-1 bg-gray-900 border border-gray-700 rounded-lg p-3 shadow-xl min-w-[200px]"
        phx-click-away={JS.hide(to: "##{@id}-detail")}
        role="tooltip"
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

  # -- Cost Display --

  @doc """
  Displays a cost value in USD with appropriate precision.

  ## Examples

      <.cost_display usd={0.05} />
      <.cost_display usd={nil} />
  """
  attr(:usd, :float, default: nil)
  attr(:class, :string, default: nil)

  def cost_display(assigns) do
    ~H"""
    <span class={["text-sm font-mono text-gray-300", @class]}>
      {format_cost(@usd)}
    </span>
    """
  end

  # -- Duration Display --

  @doc """
  Formats and displays duration from milliseconds.

  ## Examples

      <.duration_display ms={123456} />
      <.duration_display ms={nil} />
  """
  attr(:ms, :integer, default: nil)
  attr(:class, :string, default: nil)

  def duration_display(assigns) do
    ~H"""
    <span class={["text-sm font-mono text-gray-300", @class]}>
      {format_duration(@ms)}
    </span>
    """
  end

  # -- Public formatting helpers --

  @doc """
  Formats a token count with K/M suffixes.

  ## Examples

      iex> format_token_count(1500)
      "1.5K"
      iex> format_token_count(nil)
      "0"
  """
  @spec format_token_count(integer() | nil) :: String.t()
  def format_token_count(nil), do: "0"
  def format_token_count(0), do: "0"
  def format_token_count(n) when is_integer(n) and n < 0, do: "0"
  def format_token_count(n) when is_integer(n) and n < 1_000, do: Integer.to_string(n)

  def format_token_count(n) when is_integer(n) and n < 1_000_000 do
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

  def format_token_count(n) when is_integer(n) do
    value = n / 1_000_000
    formatted = :erlang.float_to_binary(value, decimals: 1)

    formatted =
      if String.ends_with?(formatted, ".0") do
        String.trim_trailing(formatted, ".0")
      else
        formatted
      end

    "#{formatted}M"
  end

  def format_token_count(_), do: "0"

  @doc """
  Formats a number with K/M suffixes (general purpose).

  ## Examples

      iex> format_number(1500)
      "1.5K"
      iex> format_number(2_500_000)
      "2.5M"
  """
  @spec format_number(number()) :: String.t()
  def format_number(n) when is_number(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  def format_number(n) when is_number(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end

  def format_number(n) when is_number(n), do: "#{n}"
  def format_number(_), do: "0"

  # -- Private helpers --

  defp format_token_pair(nil, nil), do: "--"

  defp format_token_pair(input, output) do
    "#{format_token_count(input)} in / #{format_token_count(output)} out"
  end

  defp format_cost(nil), do: "--"

  defp format_cost(usd) when is_float(usd) do
    "$#{:erlang.float_to_binary(usd, decimals: 4)}"
  end

  defp format_cost(usd) when is_integer(usd), do: format_cost(usd / 1)
  defp format_cost(_), do: "--"

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
end
