defmodule CortexWeb.StatusComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CortexWeb.StatusComponents

  describe "status_badge/1" do
    test "renders run status strings" do
      for status <- ~w(pending running completed done failed stopped stalled) do
        html = render_component(&StatusComponents.status_badge/1, status: status)
        assert html =~ status
        assert html =~ "aria-label"
      end
    end

    test "renders mesh member state atoms" do
      for status <- [:alive, :suspect, :dead, :left] do
        html = render_component(&StatusComponents.status_badge/1, status: status)
        assert html =~ Atom.to_string(status)
      end
    end

    test "renders gateway agent status atoms" do
      for status <- [:idle, :working, :draining, :disconnected] do
        html = render_component(&StatusComponents.status_badge/1, status: status)
        assert html =~ Atom.to_string(status)
      end
    end

    test "renders gossip node status atoms" do
      for status <- [:online, :converged] do
        html = render_component(&StatusComponents.status_badge/1, status: status)
        assert html =~ Atom.to_string(status)
      end
    end

    test "renders unknown status with default styling" do
      html = render_component(&StatusComponents.status_badge/1, status: "mystery")
      assert html =~ "mystery"
      assert html =~ "bg-gray-800"
    end

    test "renders nil status without crashing" do
      html = render_component(&StatusComponents.status_badge/1, status: nil)
      assert html =~ "unknown"
    end

    test "applies correct colors for running" do
      html = render_component(&StatusComponents.status_badge/1, status: "running")
      assert html =~ "bg-blue-900/60"
      assert html =~ "text-blue-300"
    end

    test "applies correct colors for completed" do
      html = render_component(&StatusComponents.status_badge/1, status: "completed")
      assert html =~ "bg-emerald-900/60"
      assert html =~ "text-emerald-300"
    end

    test "applies correct colors for failed" do
      html = render_component(&StatusComponents.status_badge/1, status: "failed")
      assert html =~ "bg-rose-900/60"
      assert html =~ "text-rose-300"
    end

    test "applies correct colors for alive atom" do
      html = render_component(&StatusComponents.status_badge/1, status: :alive)
      assert html =~ "bg-blue-900/50"
      assert html =~ "text-blue-300"
    end

    test "supports custom class" do
      html = render_component(&StatusComponents.status_badge/1, status: "running", class: "ml-2")
      assert html =~ "ml-2"
    end

    test "includes aria-label" do
      html = render_component(&StatusComponents.status_badge/1, status: "running")
      assert html =~ "aria-label=\"Status: running\""
    end
  end

  describe "status_dot/1" do
    test "renders colored dot for each status" do
      for status <- ~w(running completed failed alive suspect dead) do
        html = render_component(&StatusComponents.status_dot/1, status: status)
        assert html =~ "rounded-full"
      end
    end

    test "renders with pulse animation" do
      html = render_component(&StatusComponents.status_dot/1, status: "running", pulse: true)
      assert html =~ "animate-pulse"
    end

    test "renders without pulse by default" do
      html = render_component(&StatusComponents.status_dot/1, status: "running")
      refute html =~ "animate-pulse"
    end

    test "renders correct color for alive" do
      html = render_component(&StatusComponents.status_dot/1, status: :alive)
      assert html =~ "bg-blue-400"
    end

    test "renders correct color for dead" do
      html = render_component(&StatusComponents.status_dot/1, status: :dead)
      assert html =~ "bg-red-400"
    end
  end

  describe "transport_badge/1" do
    test "renders gRPC badge" do
      html = render_component(&StatusComponents.transport_badge/1, transport: :grpc)
      assert html =~ "grpc"
      assert html =~ "bg-blue-900/50"
    end

    test "renders WebSocket badge" do
      html = render_component(&StatusComponents.transport_badge/1, transport: :websocket)
      assert html =~ "websocket"
      assert html =~ "bg-green-900/50"
    end

    test "renders unknown transport with default styling" do
      html = render_component(&StatusComponents.transport_badge/1, transport: :unknown)
      assert html =~ "bg-gray-800"
    end
  end

  describe "mode_badge/1" do
    test "renders DAG mode badge" do
      html = render_component(&StatusComponents.mode_badge/1, mode: "dag")
      assert html =~ "DAG"
    end

    test "renders mesh mode badge" do
      html = render_component(&StatusComponents.mode_badge/1, mode: "mesh")
      assert html =~ "Mesh"
    end

    test "renders gossip mode badge" do
      html = render_component(&StatusComponents.mode_badge/1, mode: "gossip")
      assert html =~ "Gossip"
    end

    test "renders workflow mode badge" do
      html = render_component(&StatusComponents.mode_badge/1, mode: "workflow")
      assert html =~ "Workflow"
    end

    test "renders unknown mode" do
      html = render_component(&StatusComponents.mode_badge/1, mode: "custom")
      assert html =~ "custom"
    end
  end

  describe "normalize_status/1" do
    test "normalizes atoms to lowercase strings" do
      assert StatusComponents.normalize_status(:alive) == "alive"
      assert StatusComponents.normalize_status(:Running) == "Running"
    end

    test "normalizes strings to lowercase" do
      assert StatusComponents.normalize_status("Running") == "running"
      assert StatusComponents.normalize_status("FAILED") == "failed"
    end

    test "handles nil" do
      assert StatusComponents.normalize_status(nil) == "unknown"
    end

    test "handles integers" do
      assert StatusComponents.normalize_status(42) == "unknown"
    end
  end

  describe "svg_fill/1" do
    test "returns correct fill for known statuses" do
      assert StatusComponents.svg_fill("running") == "#1e3a5f"
      assert StatusComponents.svg_fill("completed") == "#064e3b"
      assert StatusComponents.svg_fill("failed") == "#7f1d1d"
      assert StatusComponents.svg_fill(:alive) == "#1e3a5f"
      assert StatusComponents.svg_fill(:suspect) == "#713f12"
      assert StatusComponents.svg_fill(:dead) == "#7f1d1d"
    end

    test "returns default for unknown status" do
      assert StatusComponents.svg_fill("mystery") == "#1f2937"
    end
  end

  describe "svg_stroke/1" do
    test "returns correct stroke for known statuses" do
      assert StatusComponents.svg_stroke("running") == "#3b82f6"
      assert StatusComponents.svg_stroke("completed") == "#10b981"
      assert StatusComponents.svg_stroke(:alive) == "#3b82f6"
      assert StatusComponents.svg_stroke(:dead) == "#ef4444"
    end

    test "returns default for unknown status" do
      assert StatusComponents.svg_stroke("mystery") == "#4b5563"
    end
  end
end
