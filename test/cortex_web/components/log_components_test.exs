defmodule CortexWeb.LogComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CortexWeb.LogComponents

  @now ~U[2024-01-01 12:00:00Z]

  @line %{
    id: "log-1",
    timestamp: @now,
    source: "team-a",
    level: :info,
    content: "Processing started",
    raw: "Full raw log output here"
  }

  describe "log_viewer/1" do
    test "renders log entries" do
      html = render_component(&LogComponents.log_viewer/1, lines: [@line])
      assert html =~ "team-a"
      assert html =~ "Processing started"
    end

    test "shows entry count" do
      lines = [
        %{id: "1", content: "a", source: "s", level: :info},
        %{id: "2", content: "b", source: "s", level: :info}
      ]

      html = render_component(&LogComponents.log_viewer/1, lines: lines)
      assert html =~ "(2)"
    end

    test "renders empty state for no lines" do
      html = render_component(&LogComponents.log_viewer/1, lines: [])
      assert html =~ "No log entries"
    end

    test "renders sort toggle" do
      html =
        render_component(&LogComponents.log_viewer/1,
          lines: [@line],
          sort: :desc,
          on_toggle_sort: "toggle_sort"
        )

      assert html =~ "Newest first"
      assert html =~ "phx-click=\"toggle_sort\""
    end

    test "renders ascending sort label" do
      html =
        render_component(&LogComponents.log_viewer/1,
          lines: [@line],
          sort: :asc,
          on_toggle_sort: "toggle_sort"
        )

      assert html =~ "Oldest first"
    end

    test "includes log role for accessibility" do
      html = render_component(&LogComponents.log_viewer/1, lines: [@line])
      assert html =~ "role=\"log\""
    end

    test "handles expanded entries" do
      html =
        render_component(&LogComponents.log_viewer/1,
          lines: [@line],
          expanded: ["log-1"],
          on_toggle_expand: "toggle_log"
        )

      assert html =~ "Full raw log output here"
    end
  end

  describe "log_entry/1" do
    test "renders entry with timestamp and source" do
      html = render_component(&LogComponents.log_entry/1, line: @line)
      assert html =~ "12:00:00"
      assert html =~ "team-a"
      assert html =~ "Processing started"
    end

    test "shows level with correct color for error" do
      line = %{@line | level: :error}
      html = render_component(&LogComponents.log_entry/1, line: line)
      assert html =~ "text-red-400"
      assert html =~ "error"
    end

    test "shows level with correct color for warn" do
      line = %{@line | level: :warn}
      html = render_component(&LogComponents.log_entry/1, line: line)
      assert html =~ "text-yellow-400"
    end

    test "shows level with correct color for debug" do
      line = %{@line | level: :debug}
      html = render_component(&LogComponents.log_entry/1, line: line)
      assert html =~ "text-gray-500"
    end

    test "handles string level" do
      line = %{@line | level: "error"}
      html = render_component(&LogComponents.log_entry/1, line: line)
      assert html =~ "text-red-400"
    end

    test "shows expand toggle" do
      html =
        render_component(&LogComponents.log_entry/1,
          line: @line,
          on_toggle: "toggle_log"
        )

      assert html =~ "phx-click=\"toggle_log\""
      assert html =~ "phx-value-id=\"log-1\""
    end

    test "shows raw content when expanded" do
      html =
        render_component(&LogComponents.log_entry/1,
          line: @line,
          expanded: true,
          on_toggle: "toggle_log"
        )

      assert html =~ "Full raw log output here"
    end

    test "hides raw content when collapsed" do
      html =
        render_component(&LogComponents.log_entry/1,
          line: @line,
          expanded: false,
          on_toggle: "toggle_log"
        )

      refute html =~ "Full raw log output here"
    end

    test "handles nil timestamp" do
      line = %{@line | timestamp: nil}
      html = render_component(&LogComponents.log_entry/1, line: line)
      assert html =~ "Processing started"
    end

    test "handles missing level" do
      line = Map.delete(@line, :level)
      html = render_component(&LogComponents.log_entry/1, line: line)
      assert html =~ "info"
    end
  end
end
