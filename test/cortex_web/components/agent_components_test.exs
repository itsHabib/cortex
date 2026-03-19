defmodule CortexWeb.AgentComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CortexWeb.AgentComponents

  @agent %{
    name: "researcher",
    role: "Research Agent",
    capabilities: ["search", "summarize"],
    status: :idle,
    transport: :grpc,
    last_heartbeat: ~U[2024-01-01 12:00:00Z],
    registered_at: ~U[2024-01-01 11:00:00Z],
    id: "abc12345-6789-0def-ghij-klmnopqrstuv"
  }

  describe "agent_card/1 :grid mode" do
    test "renders agent name and role" do
      html = render_component(&AgentComponents.agent_card/1, agent: @agent)
      assert html =~ "researcher"
      assert html =~ "Research Agent"
    end

    test "renders capabilities" do
      html = render_component(&AgentComponents.agent_card/1, agent: @agent)
      assert html =~ "search"
      assert html =~ "summarize"
    end

    test "renders transport badge" do
      html = render_component(&AgentComponents.agent_card/1, agent: @agent)
      assert html =~ "grpc"
    end

    test "renders status badge" do
      html = render_component(&AgentComponents.agent_card/1, agent: @agent)
      assert html =~ "idle"
    end

    test "renders truncated agent ID" do
      html = render_component(&AgentComponents.agent_card/1, agent: @agent)
      assert html =~ "abc12345"
    end

    test "handles nil capabilities" do
      agent = %{@agent | capabilities: nil}
      html = render_component(&AgentComponents.agent_card/1, agent: agent)
      assert html =~ "researcher"
      refute html =~ "summarize"
    end

    test "handles nil role" do
      agent = Map.put(@agent, :role, nil)
      html = render_component(&AgentComponents.agent_card/1, agent: agent)
      assert html =~ "\u2014"
    end

    test "highlights selected agent" do
      html = render_component(&AgentComponents.agent_card/1, agent: @agent, selected: true)
      assert html =~ "border-cortex-600"
    end

    test "emits click event" do
      html =
        render_component(&AgentComponents.agent_card/1, agent: @agent, on_click: "select_agent")

      assert html =~ "phx-click=\"select_agent\""
      assert html =~ "phx-value-name=\"researcher\""
    end
  end

  describe "agent_card/1 :list mode" do
    test "renders as table row" do
      html = render_component(&AgentComponents.agent_card/1, agent: @agent, mode: :list)
      assert html =~ "<tr"
      assert html =~ "researcher"
    end

    test "shows role and capabilities in columns" do
      html = render_component(&AgentComponents.agent_card/1, agent: @agent, mode: :list)
      assert html =~ "Research Agent"
      assert html =~ "search"
    end
  end

  describe "agent_card/1 :compact mode" do
    test "renders minimal card" do
      html = render_component(&AgentComponents.agent_card/1, agent: @agent, mode: :compact)
      assert html =~ "researcher"
      refute html =~ "abc12345"
    end

    test "shows status dot" do
      html = render_component(&AgentComponents.agent_card/1, agent: @agent, mode: :compact)
      assert html =~ "rounded-full"
    end
  end

  describe "agent_grid/1" do
    test "renders grid of agents" do
      agents = [
        %{name: "a1", status: :idle, capabilities: []},
        %{name: "a2", status: :working, capabilities: []}
      ]

      html = render_component(&AgentComponents.agent_grid/1, agents: agents)
      assert html =~ "a1"
      assert html =~ "a2"
      assert html =~ "grid-cols-1"
    end

    test "renders empty state for no agents" do
      html = render_component(&AgentComponents.agent_grid/1, agents: [])
      assert html =~ "No agents connected"
    end

    test "highlights selected agent" do
      agents = [%{name: "a1", status: :idle, capabilities: []}]

      html =
        render_component(&AgentComponents.agent_grid/1,
          agents: agents,
          selected: "a1",
          on_select: "select"
        )

      assert html =~ "border-cortex-600"
    end
  end

  describe "agent_list/1" do
    test "renders table with headers" do
      agents = [%{name: "agent-x", status: :idle, role: "Writer", capabilities: ["write"]}]
      html = render_component(&AgentComponents.agent_list/1, agents: agents)
      assert html =~ "<table"
      assert html =~ "Name"
      assert html =~ "Role"
      assert html =~ "Capabilities"
      assert html =~ "Status"
      assert html =~ "agent-x"
    end

    test "handles empty agent list" do
      html = render_component(&AgentComponents.agent_list/1, agents: [])
      assert html =~ "<table"
    end
  end

  describe "agent_picker/1" do
    test "renders available agents as compact cards" do
      available = [
        %{name: "alpha", status: :idle, capabilities: ["code"]},
        %{name: "beta", status: :idle, capabilities: ["review"]}
      ]

      html = render_component(&AgentComponents.agent_picker/1, available: available)
      assert html =~ "alpha"
      assert html =~ "beta"
    end

    test "renders selected agents as chips" do
      available = [%{name: "alpha", status: :idle, capabilities: []}]

      html =
        render_component(&AgentComponents.agent_picker/1,
          available: available,
          selected: ["alpha"],
          on_remove: "remove_agent"
        )

      assert html =~ "alpha"
      # Remove button
      assert html =~ "aria-label=\"Remove alpha\""
    end

    test "shows empty state when no agents match filter" do
      available = [%{name: "alpha", status: :idle, capabilities: []}]

      html =
        render_component(&AgentComponents.agent_picker/1,
          available: available,
          filter: "zzz"
        )

      assert html =~ "No matching agents"
    end

    test "filters agents by name" do
      available = [
        %{name: "alpha", status: :idle, capabilities: []},
        %{name: "beta", status: :idle, capabilities: []}
      ]

      html =
        render_component(&AgentComponents.agent_picker/1,
          available: available,
          filter: "alp"
        )

      assert html =~ "alpha"
      refute html =~ "beta"
    end

    test "filters agents by capability" do
      available = [
        %{name: "alpha", status: :idle, capabilities: ["code"]},
        %{name: "beta", status: :idle, capabilities: ["review"]}
      ]

      html =
        render_component(&AgentComponents.agent_picker/1,
          available: available,
          filter: "code"
        )

      assert html =~ "alpha"
      refute html =~ "beta"
    end
  end
end
