defmodule CortexWeb.MeshComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CortexWeb.MeshComponents

  @member %{
    name: "alpha",
    role: "Researcher",
    state: :alive,
    incarnation: 2,
    last_seen: ~U[2024-01-01 12:00:00Z],
    started_at: ~U[2024-01-01 11:00:00Z],
    died_at: nil,
    os_pid: nil
  }

  describe "mesh_overview/1" do
    test "renders active session banner when running" do
      members = [
        %{@member | name: "a", state: :alive},
        %{@member | name: "b", state: :alive},
        %{@member | name: "c", state: :dead}
      ]

      html =
        render_component(&MeshComponents.mesh_overview/1,
          running: true,
          project: "test-mesh",
          members: members
        )

      assert html =~ "Mesh session active"
      assert html =~ "test-mesh"
      assert html =~ "2 of 3 agents alive"
    end

    test "hides banner when not running" do
      html =
        render_component(&MeshComponents.mesh_overview/1,
          running: false,
          members: []
        )

      refute html =~ "Mesh session active"
    end
  end

  describe "mesh_topology/1" do
    test "renders SVG with member nodes" do
      members = [
        %{@member | name: "alpha"},
        %{@member | name: "beta"}
      ]

      html = render_component(&MeshComponents.mesh_topology/1, members: members)
      assert html =~ "<svg"
      assert html =~ "alpha"
      assert html =~ "beta"
    end

    test "renders nothing for empty members" do
      html = render_component(&MeshComponents.mesh_topology/1, members: [])
      refute html =~ "<svg"
    end

    test "highlights selected member" do
      members = [%{@member | name: "alpha"}]

      html =
        render_component(&MeshComponents.mesh_topology/1,
          members: members,
          selected_member: "alpha"
        )

      assert html =~ "stroke-dasharray"
    end

    test "includes accessibility attributes" do
      members = [%{@member | name: "alpha"}]

      html = render_component(&MeshComponents.mesh_topology/1, members: members)
      assert html =~ "role=\"button\""
      assert html =~ "aria-label"
    end
  end

  describe "membership_table/1" do
    test "renders table with member data" do
      members = [
        %{@member | name: "alpha", role: "Researcher", state: :alive, incarnation: 2},
        %{@member | name: "beta", role: "Writer", state: :suspect, incarnation: 0}
      ]

      html = render_component(&MeshComponents.membership_table/1, members: members)
      assert html =~ "<table"
      assert html =~ "alpha"
      assert html =~ "beta"
      assert html =~ "Researcher"
      assert html =~ "Writer"
    end

    test "highlights selected member row" do
      members = [%{@member | name: "alpha"}]

      html =
        render_component(&MeshComponents.membership_table/1,
          members: members,
          selected_member: "alpha"
        )

      assert html =~ "bg-cortex-900/20"
    end

    test "shows token stats" do
      members = [%{@member | name: "alpha"}]
      token_stats = %{"alpha" => %{input: 1500, output: 800}}

      html =
        render_component(&MeshComponents.membership_table/1,
          members: members,
          token_stats: token_stats
        )

      assert html =~ "2.3K"
    end

    test "renders status badge for each member" do
      members = [%{@member | name: "alpha", state: :suspect}]
      html = render_component(&MeshComponents.membership_table/1, members: members)
      assert html =~ "suspect"
    end

    test "emits click event" do
      members = [%{@member | name: "alpha"}]

      html =
        render_component(&MeshComponents.membership_table/1,
          members: members,
          click_event: "select_member"
        )

      assert html =~ "phx-click=\"select_member\""
    end
  end

  describe "member_card/1" do
    test "renders member details" do
      html =
        render_component(&MeshComponents.member_card/1,
          member: @member,
          token_stats: %{input: 500, output: 200}
        )

      assert html =~ "alpha"
      assert html =~ "Researcher"
      assert html =~ "500"
      assert html =~ "200"
    end

    test "shows incarnation" do
      html =
        render_component(&MeshComponents.member_card/1,
          member: @member,
          token_stats: %{input: 0, output: 0}
        )

      assert html =~ "2"
    end

    test "shows close button" do
      html =
        render_component(&MeshComponents.member_card/1,
          member: @member,
          token_stats: %{input: 0, output: 0},
          on_close: "select_member"
        )

      assert html =~ "aria-label=\"Close alpha detail\""
    end

    test "shows messages when provided" do
      messages = [
        %{from: "alpha", to: "beta", content: "Hello world", timestamp: ~U[2024-01-01 12:00:00Z]}
      ]

      html =
        render_component(&MeshComponents.member_card/1,
          member: @member,
          token_stats: %{input: 0, output: 0},
          messages: messages
        )

      assert html =~ "Hello world"
      assert html =~ "Messages (1)"
    end
  end

  describe "mesh_legend/1" do
    test "renders all state labels" do
      html = render_component(&MeshComponents.mesh_legend/1, %{})
      assert html =~ "alive"
      assert html =~ "suspect"
      assert html =~ "dead"
      assert html =~ "left"
    end

    test "includes aria label" do
      html = render_component(&MeshComponents.mesh_legend/1, %{})
      assert html =~ "aria-label=\"Mesh state legend\""
    end
  end
end
