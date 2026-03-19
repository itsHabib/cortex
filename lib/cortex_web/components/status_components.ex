defmodule CortexWeb.StatusComponents do
  @moduledoc """
  Unified status badge system for the Cortex UI.

  Handles all status types across the application: run statuses (strings),
  mesh member states (atoms), gossip node statuses (atoms), and gateway
  agent statuses (atoms). Accepts both strings and atoms, normalizing
  internally to a canonical atom.
  """
  use Phoenix.Component

  # -- Status Badge --

  @doc """
  Renders a colored status badge pill.

  Accepts both string and atom status values. Unknown statuses render
  a neutral gray badge — never crashes.

  ## Examples

      <.status_badge status="running" />
      <.status_badge status={:alive} />
      <.status_badge status={:idle} />
  """
  attr(:status, :any, required: true)
  attr(:class, :string, default: nil)

  def status_badge(assigns) do
    normalized = normalize_status(assigns.status)
    assigns = assign(assigns, :normalized, normalized)

    ~H"""
    <span
      class={[
        "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
        badge_classes(@normalized),
        @class
      ]}
      aria-label={"Status: #{@normalized}"}
    >
      {@normalized}
    </span>
    """
  end

  # -- Status Dot --

  @doc """
  Renders a small colored circle indicator with optional pulse animation.

  ## Examples

      <.status_dot status={:alive} />
      <.status_dot status="running" pulse={true} />
  """
  attr(:status, :any, required: true)
  attr(:pulse, :boolean, default: false)
  attr(:class, :string, default: nil)

  def status_dot(assigns) do
    normalized = normalize_status(assigns.status)
    assigns = assign(assigns, :normalized, normalized)

    ~H"""
    <span
      class={[
        "inline-block w-2 h-2 rounded-full",
        dot_color(@normalized),
        @pulse && "animate-pulse",
        @class
      ]}
      aria-label={"Status: #{@normalized}"}
    />
    """
  end

  # -- Transport Badge --

  @doc """
  Renders a transport type badge (gRPC or WebSocket).

  ## Examples

      <.transport_badge transport={:grpc} />
      <.transport_badge transport={:websocket} />
  """
  attr(:transport, :atom, required: true)
  attr(:class, :string, default: nil)

  def transport_badge(assigns) do
    ~H"""
    <span class={[
      "text-xs px-1.5 py-0.5 rounded shrink-0",
      transport_classes(@transport),
      @class
    ]}>
      {@transport}
    </span>
    """
  end

  # -- Mode Badge --

  @doc """
  Renders a coordination mode pill (DAG, Mesh, or Gossip).

  ## Examples

      <.mode_badge mode="dag" />
      <.mode_badge mode="mesh" />
      <.mode_badge mode="gossip" />
  """
  attr(:mode, :string, required: true)
  attr(:class, :string, default: nil)

  def mode_badge(assigns) do
    ~H"""
    <span class={[
      "text-xs px-2 py-0.5 rounded font-medium",
      mode_classes(@mode),
      @class
    ]}>
      {mode_label(@mode)}
    </span>
    """
  end

  # -- Status normalization --

  @doc """
  Normalizes a status value (string or atom) to a canonical string.

  Returns a lowercase string. Unknown values pass through as-is.

  ## Examples

      iex> normalize_status(:alive)
      "alive"
      iex> normalize_status("Running")
      "running"
  """
  @spec normalize_status(any()) :: String.t()
  def normalize_status(status) when is_atom(status) and not is_nil(status) do
    Atom.to_string(status)
  end

  def normalize_status(status) when is_binary(status) do
    String.downcase(status)
  end

  def normalize_status(_), do: "unknown"

  # -- SVG color helpers (for topology components) --

  @doc """
  Returns the SVG fill color for a given status.
  """
  @spec svg_fill(String.t()) :: String.t()
  def svg_fill(status), do: do_svg_fill(normalize_status(status))

  defp do_svg_fill("pending"), do: "#374151"
  defp do_svg_fill("running"), do: "#1e3a5f"
  defp do_svg_fill("completed"), do: "#064e3b"
  defp do_svg_fill("done"), do: "#064e3b"
  defp do_svg_fill("failed"), do: "#7f1d1d"
  defp do_svg_fill("stalled"), do: "#78350f"
  defp do_svg_fill("alive"), do: "#1e3a5f"
  defp do_svg_fill("suspect"), do: "#713f12"
  defp do_svg_fill("dead"), do: "#7f1d1d"
  defp do_svg_fill("left"), do: "#1f2937"
  defp do_svg_fill("online"), do: "#1e3a5f"
  defp do_svg_fill("converged"), do: "#14532d"
  defp do_svg_fill(_), do: "#1f2937"

  @doc """
  Returns the SVG stroke color for a given status.
  """
  @spec svg_stroke(String.t()) :: String.t()
  def svg_stroke(status), do: do_svg_stroke(normalize_status(status))

  defp do_svg_stroke("pending"), do: "#6b7280"
  defp do_svg_stroke("running"), do: "#3b82f6"
  defp do_svg_stroke("completed"), do: "#10b981"
  defp do_svg_stroke("done"), do: "#10b981"
  defp do_svg_stroke("failed"), do: "#ef4444"
  defp do_svg_stroke("stalled"), do: "#f59e0b"
  defp do_svg_stroke("alive"), do: "#3b82f6"
  defp do_svg_stroke("suspect"), do: "#eab308"
  defp do_svg_stroke("dead"), do: "#ef4444"
  defp do_svg_stroke("left"), do: "#4b5563"
  defp do_svg_stroke("online"), do: "#3b82f6"
  defp do_svg_stroke("converged"), do: "#22c55e"
  defp do_svg_stroke(_), do: "#4b5563"

  @doc """
  Returns the SVG text color for a given status.
  """
  @spec svg_text_color(String.t()) :: String.t()
  def svg_text_color(status) do
    case normalize_status(status) do
      "pending" -> "#9ca3af"
      "running" -> "#93c5fd"
      "completed" -> "#6ee7b7"
      "done" -> "#6ee7b7"
      "failed" -> "#fca5a5"
      "stalled" -> "#fcd34d"
      _ -> "#9ca3af"
    end
  end

  # -- Private helpers --

  defp badge_classes("pending"), do: "bg-gray-700 text-gray-300"
  defp badge_classes("running"), do: "bg-blue-900/60 text-blue-300 ring-1 ring-blue-500/30"

  defp badge_classes("completed"),
    do: "bg-emerald-900/60 text-emerald-300 ring-1 ring-emerald-500/30"

  defp badge_classes("done"), do: "bg-emerald-900/60 text-emerald-300 ring-1 ring-emerald-500/30"
  defp badge_classes("failed"), do: "bg-rose-900/60 text-rose-300 ring-1 ring-rose-500/30"
  defp badge_classes("stopped"), do: "bg-orange-900/60 text-orange-300 ring-1 ring-orange-500/30"
  defp badge_classes("stalled"), do: "bg-yellow-900/60 text-yellow-300 ring-1 ring-yellow-500/30"
  defp badge_classes("alive"), do: "bg-blue-900/50 text-blue-300"
  defp badge_classes("suspect"), do: "bg-yellow-900/50 text-yellow-300"
  defp badge_classes("dead"), do: "bg-red-900/50 text-red-300"
  defp badge_classes("left"), do: "bg-gray-800 text-gray-400"
  defp badge_classes("idle"), do: "bg-blue-900/50 text-blue-300"
  defp badge_classes("working"), do: "bg-green-900/50 text-green-300"
  defp badge_classes("draining"), do: "bg-yellow-900/50 text-yellow-300"
  defp badge_classes("disconnected"), do: "bg-red-900/50 text-red-300"
  defp badge_classes("online"), do: "bg-blue-900/50 text-blue-300"
  defp badge_classes("converged"), do: "bg-emerald-900/50 text-emerald-300"
  defp badge_classes(_), do: "bg-gray-800 text-gray-500"

  defp dot_color("pending"), do: "bg-gray-500"
  defp dot_color("running"), do: "bg-blue-400"
  defp dot_color("completed"), do: "bg-emerald-400"
  defp dot_color("done"), do: "bg-emerald-400"
  defp dot_color("failed"), do: "bg-red-400"
  defp dot_color("stopped"), do: "bg-orange-400"
  defp dot_color("stalled"), do: "bg-yellow-400"
  defp dot_color("alive"), do: "bg-blue-400"
  defp dot_color("suspect"), do: "bg-yellow-400"
  defp dot_color("dead"), do: "bg-red-400"
  defp dot_color("left"), do: "bg-gray-500"
  defp dot_color("idle"), do: "bg-blue-400"
  defp dot_color("working"), do: "bg-green-400"
  defp dot_color("draining"), do: "bg-yellow-400"
  defp dot_color("disconnected"), do: "bg-red-400"
  defp dot_color("online"), do: "bg-blue-400"
  defp dot_color("converged"), do: "bg-emerald-400"
  defp dot_color(_), do: "bg-gray-600"

  defp transport_classes(:grpc), do: "bg-blue-900/50 text-blue-300"
  defp transport_classes(:websocket), do: "bg-green-900/50 text-green-300"
  defp transport_classes(_), do: "bg-gray-800 text-gray-400"

  defp mode_classes("dag"), do: "bg-cortex-900/50 text-cortex-300"
  defp mode_classes("workflow"), do: "bg-cortex-900/50 text-cortex-300"
  defp mode_classes("mesh"), do: "bg-blue-900/50 text-blue-300"
  defp mode_classes("gossip"), do: "bg-purple-900/50 text-purple-300"
  defp mode_classes(_), do: "bg-gray-800 text-gray-400"

  defp mode_label("dag"), do: "DAG"
  defp mode_label("workflow"), do: "Workflow"
  defp mode_label("mesh"), do: "Mesh"
  defp mode_label("gossip"), do: "Gossip"
  defp mode_label(other), do: other
end
