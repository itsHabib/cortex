defmodule CortexWeb.ModeComponentsTest do
  use CortexWeb.ComponentCase, async: true

  import Phoenix.LiveViewTest

  alias CortexWeb.ModeComponents

  describe "mode_selector/1" do
    test "renders all three mode tabs" do
      html = render_component(&ModeComponents.mode_selector/1, selected: "dag")
      assert html =~ "DAG Workflow"
      assert html =~ "Mesh"
      assert html =~ "Gossip"
    end

    test "highlights selected mode" do
      html = render_component(&ModeComponents.mode_selector/1, selected: "dag")
      assert html =~ "bg-gray-800 text-white"
    end

    test "renders dag tabpanel when dag selected" do
      html = render_component(&ModeComponents.mode_selector/1, selected: "dag")
      assert html =~ "DAG workflow configuration"
      refute html =~ "Mesh configuration"
    end

    test "renders mesh tabpanel when mesh selected" do
      html = render_component(&ModeComponents.mode_selector/1, selected: "mesh")
      assert html =~ "Mesh configuration"
      refute html =~ "DAG workflow configuration"
    end

    test "emits click event" do
      html =
        render_component(&ModeComponents.mode_selector/1,
          selected: "dag",
          on_select: "select_mode"
        )

      assert html =~ "phx-click=\"select_mode\""
    end

    test "includes tab role attributes" do
      html = render_component(&ModeComponents.mode_selector/1, selected: "dag")
      assert html =~ "role=\"tablist\""
      assert html =~ "role=\"tab\""
    end

    test "marks selected tab with aria-selected" do
      html = render_component(&ModeComponents.mode_selector/1, selected: "mesh")
      assert html =~ "aria-selected"
    end

    test "renders tabpanel for selected mode" do
      html = render_component(&ModeComponents.mode_selector/1, selected: "mesh")
      assert html =~ "role=\"tabpanel\""
      assert html =~ "Mesh configuration"
    end
  end
end
