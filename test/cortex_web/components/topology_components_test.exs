defmodule CortexWeb.TopologyComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CortexWeb.TopologyComponents

  describe "topology_graph/1 :dag variant" do
    test "renders DAG SVG with nodes and edges" do
      tiers = [["team-a"], ["team-b", "team-c"]]

      teams = [
        %{team_name: "team-a", status: "completed", input_tokens: 1000, output_tokens: 500},
        %{team_name: "team-b", status: "running", input_tokens: nil, output_tokens: nil},
        %{team_name: "team-c", status: "pending", input_tokens: nil, output_tokens: nil}
      ]

      edges = [{"team-a", "team-b"}, {"team-a", "team-c"}]

      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :dag,
          tiers: tiers,
          teams: teams,
          edges: edges,
          run_id: "run-123"
        )

      assert html =~ "team-a"
      assert html =~ "team-b"
      assert html =~ "team-c"
      assert html =~ "<svg"
      assert html =~ "arrowhead"
    end

    test "renders token labels on DAG nodes" do
      tiers = [["team-a"]]

      teams = [
        %{team_name: "team-a", status: "completed", input_tokens: 1000, output_tokens: 500}
      ]

      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :dag,
          tiers: tiers,
          teams: teams,
          edges: [],
          run_id: "run-1"
        )

      assert html =~ "1.5K tok"
    end

    test "handles empty tiers" do
      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :dag,
          tiers: [],
          teams: [],
          edges: [],
          run_id: "run-1"
        )

      assert html =~ "<svg"
    end

    test "links nodes to team detail page" do
      tiers = [["team-a"]]
      teams = [%{team_name: "team-a", status: "running"}]

      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :dag,
          tiers: tiers,
          teams: teams,
          edges: [],
          run_id: "run-42"
        )

      assert html =~ "/runs/run-42/teams/team-a"
    end

    test "uses correct SVG colors from StatusComponents" do
      tiers = [["team-a"]]
      teams = [%{team_name: "team-a", status: "running"}]

      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :dag,
          tiers: tiers,
          teams: teams,
          edges: [],
          run_id: "r1"
        )

      assert html =~ "#1e3a5f"
      assert html =~ "#3b82f6"
    end
  end

  describe "topology_graph/1 :radial variant" do
    test "renders radial SVG with nodes" do
      nodes = [
        %{name: "alpha", state: :alive},
        %{name: "beta", state: :alive},
        %{name: "gamma", state: :suspect}
      ]

      edges = [{"alpha", "beta"}, {"beta", "gamma"}, {"alpha", "gamma"}]

      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :radial,
          nodes: nodes,
          edges: edges
        )

      assert html =~ "alpha"
      assert html =~ "beta"
      assert html =~ "gamma"
      assert html =~ "<svg"
    end

    test "highlights selected node" do
      nodes = [
        %{name: "alpha", state: :alive},
        %{name: "beta", state: :alive}
      ]

      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :radial,
          nodes: nodes,
          edges: [{"alpha", "beta"}],
          selected: "alpha"
        )

      # Should have selection ring with dashed stroke
      assert html =~ "stroke-dasharray"
      assert html =~ "#38bdf8"
    end

    test "renders empty state for no nodes" do
      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :radial,
          nodes: [],
          edges: []
        )

      assert html =~ "No nodes to display"
    end

    test "handles nodes with status field instead of state" do
      nodes = [
        %{name: "node-1", status: :online},
        %{name: "node-2", status: :converged}
      ]

      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :radial,
          nodes: nodes,
          edges: [{"node-1", "node-2"}]
        )

      assert html =~ "node-1"
      assert html =~ "node-2"
    end

    test "emits click event with node name" do
      nodes = [%{name: "alpha", state: :alive}]

      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :radial,
          nodes: nodes,
          edges: [],
          on_node_click: "select_member"
        )

      assert html =~ "phx-click=\"select_member\""
      assert html =~ "phx-value-name=\"alpha\""
    end

    test "includes accessibility attributes" do
      nodes = [%{name: "alpha", state: :alive}]

      html =
        render_component(&TopologyComponents.topology_graph/1,
          variant: :radial,
          nodes: nodes,
          edges: []
        )

      assert html =~ "role=\"button\""
      assert html =~ "aria-label"
      assert html =~ "aria-selected"
    end
  end

  describe "topology_legend/1" do
    test "renders legend items" do
      items = [
        %{label: "alive", color: "blue"},
        %{label: "suspect", color: "yellow"},
        %{label: "dead", color: "red"}
      ]

      html = render_component(&TopologyComponents.topology_legend/1, items: items)

      assert html =~ "alive"
      assert html =~ "suspect"
      assert html =~ "dead"
    end

    test "includes aria label" do
      html =
        render_component(&TopologyComponents.topology_legend/1,
          items: [%{label: "active", color: "green"}]
        )

      assert html =~ "aria-label=\"Topology legend\""
    end
  end
end
