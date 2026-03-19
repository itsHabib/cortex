defmodule CortexWeb.GossipComponentsTest do
  use CortexWeb.ComponentCase, async: true

  import Phoenix.LiveViewTest

  alias CortexWeb.GossipComponents

  describe "gossip_overview/1" do
    test "renders active session banner when running" do
      html =
        render_component(&GossipComponents.gossip_overview/1,
          running: true,
          project: "my-project",
          rounds_completed: 3,
          rounds_total: 5,
          nodes: [],
          entries: []
        )

      assert html =~ "Gossip session active"
      assert html =~ "my-project"
      assert html =~ "3/5"
    end

    test "hides banner when not running" do
      html =
        render_component(&GossipComponents.gossip_overview/1,
          running: false,
          rounds_completed: 0,
          rounds_total: 0
        )

      refute html =~ "Gossip session active"
    end

    test "shows convergence state for entries" do
      nodes = [%{name: "a"}, %{name: "b"}]

      entries = [
        %{
          topic: "t1",
          source: "a",
          vector_clock: %{"a" => 1, "b" => 1},
          content: "test",
          confidence: 0.9,
          id: "e1"
        }
      ]

      html =
        render_component(&GossipComponents.gossip_overview/1,
          running: false,
          rounds_completed: 5,
          rounds_total: 5,
          nodes: nodes,
          entries: entries
        )

      assert html =~ "Converged"
    end

    test "shows divergent state when not all nodes have entries" do
      nodes = [%{name: "a"}, %{name: "b"}]

      entries = [
        %{
          topic: "t1",
          source: "a",
          vector_clock: %{"a" => 1},
          content: "test",
          confidence: 0.9,
          id: "e1"
        }
      ]

      html =
        render_component(&GossipComponents.gossip_overview/1,
          running: false,
          rounds_completed: 2,
          rounds_total: 5,
          nodes: nodes,
          entries: entries
        )

      assert html =~ "Divergent"
    end
  end

  describe "gossip_topology/1" do
    test "renders topology SVG with nodes" do
      nodes = [
        %{name: "alpha", status: :online},
        %{name: "beta", status: :online}
      ]

      topology = %{"alpha" => ["beta"], "beta" => ["alpha"]}

      html =
        render_component(&GossipComponents.gossip_topology/1,
          nodes: nodes,
          topology: topology
        )

      assert html =~ "<svg"
      assert html =~ "alpha"
      assert html =~ "beta"
    end

    test "renders nothing for empty nodes" do
      html =
        render_component(&GossipComponents.gossip_topology/1,
          nodes: [],
          topology: %{}
        )

      refute html =~ "<svg"
    end

    test "includes accessibility attributes" do
      nodes = [%{name: "a", status: :online}]

      html =
        render_component(&GossipComponents.gossip_topology/1,
          nodes: nodes,
          topology: %{}
        )

      assert html =~ "role=\"button\""
      assert html =~ "aria-label"
    end
  end

  describe "knowledge_entries/1" do
    test "renders entries with topic and content" do
      entries = [
        %{
          topic: "summary",
          source: "alpha",
          content: "This is a test entry",
          confidence: 0.95,
          vector_clock: %{"alpha" => 1},
          id: "entry-123"
        }
      ]

      html = render_component(&GossipComponents.knowledge_entries/1, entries: entries)
      assert html =~ "summary"
      assert html =~ "This is a test entry"
      assert html =~ "0.95"
      assert html =~ "entry-12"
    end

    test "highlights selected node entries" do
      entries = [
        %{
          topic: "t1",
          source: "alpha",
          content: "test",
          confidence: 0.8,
          vector_clock: %{},
          id: "e1"
        }
      ]

      html =
        render_component(&GossipComponents.knowledge_entries/1,
          entries: entries,
          selected_node: "alpha"
        )

      assert html =~ "bg-cortex-900/20"
    end

    test "renders empty state" do
      html = render_component(&GossipComponents.knowledge_entries/1, entries: [])
      assert html =~ "Waiting for knowledge entries"
    end

    test "applies confidence color classes" do
      entries = [
        %{
          topic: "t1",
          source: "a",
          content: "test",
          confidence: 0.3,
          vector_clock: %{},
          id: "e1"
        }
      ]

      html = render_component(&GossipComponents.knowledge_entries/1, entries: entries)
      assert html =~ "text-red-400"
    end
  end

  describe "round_progress/1" do
    test "renders progress bar" do
      html = render_component(&GossipComponents.round_progress/1, current: 3, total: 5)
      assert html =~ "3/5"
      assert html =~ "role=\"progressbar\""
    end

    test "renders 100% when complete" do
      html = render_component(&GossipComponents.round_progress/1, current: 5, total: 5)
      assert html =~ "width: 100%"
    end

    test "renders 0% when no progress" do
      html = render_component(&GossipComponents.round_progress/1, current: 0, total: 5)
      assert html =~ "width: 0%"
    end
  end
end
