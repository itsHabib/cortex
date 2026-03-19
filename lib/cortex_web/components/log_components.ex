defmodule CortexWeb.LogComponents do
  @moduledoc """
  Log viewer components for the Cortex UI.

  Provides a sortable, expandable log panel with monospace rendering.
  Replaces inline log rendering in RunDetailLive and JobsLive.
  """
  use Phoenix.Component

  # -- Log Viewer --

  @doc """
  Renders a full log panel with header (sort toggle, count), scrollable body,
  and expandable entries.

  ## Examples

      <.log_viewer lines={lines} sort={:desc} on_toggle_sort="toggle_sort" />
  """
  attr(:lines, :list, required: true)
  attr(:sort, :atom, default: :desc, values: [:asc, :desc])
  attr(:on_toggle_sort, :string, default: nil)
  attr(:expanded, :any, default: nil)
  attr(:on_toggle_expand, :string, default: nil)
  attr(:max_lines, :integer, default: 500)
  attr(:class, :string, default: nil)

  slot(:header_actions)

  def log_viewer(assigns) do
    sorted =
      case assigns.sort do
        :asc -> Enum.reverse(assigns.lines)
        :desc -> assigns.lines
      end
      |> Enum.take(assigns.max_lines)

    expanded_set = normalize_expanded(assigns.expanded)

    assigns =
      assigns
      |> assign(:sorted, sorted)
      |> assign(:expanded_set, expanded_set)

    ~H"""
    <div class={["bg-gray-900 rounded-lg border border-gray-800", @class]}>
      <%!-- Header --%>
      <div class="flex items-center justify-between p-3 border-b border-gray-800">
        <div class="flex items-center gap-2">
          <h3 class="text-sm font-medium text-gray-400 uppercase tracking-wider">
            Logs
          </h3>
          <span class="text-xs text-gray-600">({length(@lines)})</span>
        </div>
        <div class="flex items-center gap-2">
          {render_slot(@header_actions)}
          <button
            :if={@on_toggle_sort}
            phx-click={@on_toggle_sort}
            class="text-xs text-gray-500 hover:text-gray-300 transition-colors"
            aria-label={"Sort #{if @sort == :desc, do: "ascending", else: "descending"}"}
          >
            {if @sort == :desc, do: "Newest first", else: "Oldest first"}
          </button>
        </div>
      </div>

      <%!-- Log entries --%>
      <div class="max-h-[60vh] overflow-y-auto" role="log" aria-label="Log entries">
        <%= if @sorted != [] do %>
          <.log_entry
            :for={line <- @sorted}
            line={line}
            expanded={MapSet.member?(@expanded_set, line_id(line))}
            on_toggle={@on_toggle_expand}
          />
        <% else %>
          <p class="text-gray-500 text-sm p-4 text-center">No log entries</p>
        <% end %>
      </div>
    </div>
    """
  end

  # -- Log Entry --

  @doc """
  Renders a single log entry with optional expand/collapse.

  ## Examples

      <.log_entry line={line} expanded={false} on_toggle="toggle_log" />
  """
  attr(:line, :map, required: true)
  attr(:expanded, :boolean, default: false)
  attr(:on_toggle, :string, default: nil)
  attr(:class, :string, default: nil)

  def log_entry(assigns) do
    ~H"""
    <div class={[
      "border-b border-gray-800/50 px-3 py-2 font-mono text-xs",
      @expanded && "bg-gray-950",
      @class
    ]}>
      <div
        class={["flex items-start gap-3", @on_toggle && "cursor-pointer"]}
        phx-click={@on_toggle}
        phx-value-id={line_id(@line)}
        role={if @on_toggle, do: "button"}
        aria-expanded={if @on_toggle, do: to_string(@expanded)}
      >
        <%!-- Timestamp --%>
        <span class="text-gray-700 shrink-0 w-20">
          {format_time(Map.get(@line, :timestamp))}
        </span>

        <%!-- Level --%>
        <span class={["shrink-0 w-12 uppercase", level_class(@line)]}>
          {format_level(@line)}
        </span>

        <%!-- Source --%>
        <span class="text-cortex-400 shrink-0">
          {Map.get(@line, :source, "")}
        </span>

        <%!-- Content (truncated unless expanded) --%>
        <span class={["text-gray-300 flex-1", !@expanded && "truncate"]}>
          {Map.get(@line, :content, "")}
        </span>

        <%!-- Expand indicator --%>
        <span :if={@on_toggle} class="text-gray-600 shrink-0">
          {if @expanded, do: "-", else: "+"}
        </span>
      </div>

      <%!-- Expanded content --%>
      <div :if={@expanded && Map.get(@line, :raw)} class="mt-2 ml-[8.5rem] text-gray-400 whitespace-pre-wrap">
        {Map.get(@line, :raw)}
      </div>
    </div>
    """
  end

  # -- Private helpers --

  defp line_id(%{id: id}) when is_binary(id), do: id
  defp line_id(line), do: Map.get(line, :id, "")

  defp normalize_expanded(nil), do: MapSet.new()
  defp normalize_expanded(%MapSet{} = set), do: set

  defp normalize_expanded(list) when is_list(list), do: MapSet.new(list)
  defp normalize_expanded(_), do: MapSet.new()

  defp format_time(nil), do: "\u2014"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: "\u2014"

  defp format_level(%{level: level}) when is_atom(level), do: Atom.to_string(level)
  defp format_level(%{level: level}) when is_binary(level), do: level
  defp format_level(_), do: "info"

  defp level_class(%{level: :error}), do: "text-red-400"
  defp level_class(%{level: "error"}), do: "text-red-400"
  defp level_class(%{level: :warn}), do: "text-yellow-400"
  defp level_class(%{level: "warn"}), do: "text-yellow-400"
  defp level_class(%{level: :warning}), do: "text-yellow-400"
  defp level_class(%{level: "warning"}), do: "text-yellow-400"
  defp level_class(%{level: :debug}), do: "text-gray-500"
  defp level_class(%{level: "debug"}), do: "text-gray-500"
  defp level_class(_), do: "text-blue-400"
end
