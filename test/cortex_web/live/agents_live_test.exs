defmodule CortexWeb.AgentsLiveTest do
  use CortexWeb.ConnCase

  alias Cortex.Gateway.Registry

  # Clean up all agents before each test for isolation
  setup do
    for agent <- Registry.list() do
      Registry.unregister(agent.id)
    end

    :ok
  end

  # Helper to register a test agent and return its struct
  defp register_agent(name, opts \\ []) do
    role = Keyword.get(opts, :role, "test-role")
    capabilities = Keyword.get(opts, :capabilities, ["cap-a"])
    pid = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, agent} =
      Registry.register(
        %{
          "name" => name,
          "role" => role,
          "capabilities" => capabilities,
          "metadata" => Keyword.get(opts, :metadata, %{})
        },
        pid
      )

    {agent, pid}
  end

  defp cleanup_agent(agent) do
    Registry.unregister(agent.id)
  rescue
    _ -> :ok
  end

  # -- Mount tests --

  test "renders agents page with empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agents")
    assert html =~ "Agents"
    assert html =~ "No agents connected"
    assert html =~ "Deploy a sidecar"
  end

  test "renders agents page with registered agents", %{conn: conn} do
    {agent, _pid} = register_agent("alpha-agent", capabilities: ["search", "review"])

    {:ok, _view, html} = live(conn, "/agents")
    assert html =~ "alpha-agent"
    assert html =~ "search"
    assert html =~ "review"

    cleanup_agent(agent)
  end

  test "shows agent count badge", %{conn: conn} do
    {a1, _} = register_agent("agent-1")
    {a2, _} = register_agent("agent-2")

    {:ok, _view, html} = live(conn, "/agents")
    assert html =~ "2"

    cleanup_agent(a1)
    cleanup_agent(a2)
  end

  # -- PubSub event tests --

  test "handle_info :agent_registered adds agent to grid", %{conn: conn} do
    {:ok, view, html} = live(conn, "/agents")
    assert html =~ "No agents connected"

    {agent, _pid} = register_agent("new-agent")
    Process.sleep(50)

    html = render(view)
    assert html =~ "new-agent"

    cleanup_agent(agent)
  end

  test "handle_info :agent_unregistered removes agent from grid", %{conn: conn} do
    {_agent, pid} = register_agent("departing-agent")

    {:ok, view, _html} = live(conn, "/agents")
    assert render(view) =~ "departing-agent"

    Process.exit(pid, :kill)
    Process.sleep(100)

    html = render(view)
    # After removal, the empty state should appear (agent list is empty)
    assert html =~ "No agents connected"
  end

  test "handle_info :agent_status_changed updates status", %{conn: conn} do
    {agent, _pid} = register_agent("status-agent")

    {:ok, view, _html} = live(conn, "/agents")
    assert render(view) =~ "idle"

    Registry.update_status(agent.id, :working)
    Process.sleep(50)

    html = render(view)
    assert html =~ "working"

    cleanup_agent(agent)
  end

  test "handle_info :refresh_heartbeats updates now assign", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agents")

    send(view.pid, :refresh_heartbeats)

    assert render(view) =~ "Agents"
  end

  # -- Search and filter tests --

  test "search filters agents by name", %{conn: conn} do
    {a1, _} = register_agent("alpha-one", capabilities: ["search"])
    {a2, _} = register_agent("beta-two", capabilities: ["review"])

    {:ok, view, _html} = live(conn, "/agents")

    html =
      view
      |> element("input[name=query]")
      |> render_keyup(%{"query" => "alpha"})

    assert html =~ "alpha-one"
    refute html =~ "beta-two"

    cleanup_agent(a1)
    cleanup_agent(a2)
  end

  test "search filters agents by capability", %{conn: conn} do
    {a1, _} = register_agent("agent-x", capabilities: ["security-review"])
    {a2, _} = register_agent("agent-y", capabilities: ["code-gen"])

    {:ok, view, _html} = live(conn, "/agents")

    html =
      view
      |> element("input[name=query]")
      |> render_keyup(%{"query" => "security"})

    assert html =~ "agent-x"
    refute html =~ "agent-y"

    cleanup_agent(a1)
    cleanup_agent(a2)
  end

  test "status filter works", %{conn: conn} do
    {a1, _} = register_agent("idle-agent")
    {a2, _} = register_agent("working-agent")
    Registry.update_status(a2.id, :working)

    {:ok, view, _html} = live(conn, "/agents")

    html =
      view
      |> element("select[name=status]")
      |> render_change(%{"status" => "working"})

    assert html =~ "working-agent"
    refute html =~ "idle-agent"

    cleanup_agent(a1)
    cleanup_agent(a2)
  end

  test "transport filter works", %{conn: conn} do
    {a1, _} = register_agent("ws-agent")

    {:ok, view, _html} = live(conn, "/agents")

    html =
      view
      |> element("select[name=transport]")
      |> render_change(%{"transport" => "websocket"})

    assert html =~ "ws-agent"

    cleanup_agent(a1)
  end

  test "clear_filters resets all filters", %{conn: conn} do
    {a1, _} = register_agent("agent-filtered")

    {:ok, view, _html} = live(conn, "/agents")

    # Apply status filter that hides idle agents
    view
    |> element("select[name=status]")
    |> render_change(%{"status" => "working"})

    html = render(view)
    assert html =~ "No agents match"

    # Clear filters using the toolbar button (not the empty-state one)
    view
    |> element("button[phx-click=clear_filters]", "Clear filters")
    |> render_click()

    assert render(view) =~ "agent-filtered"

    cleanup_agent(a1)
  end

  # -- View mode toggle tests --

  test "toggle_view switches between grid and topology", %{conn: conn} do
    {a1, _} = register_agent("topo-agent")

    {:ok, view, _html} = live(conn, "/agents")

    # Switch to topology
    html =
      view
      |> element("button[phx-value-mode=topology]")
      |> render_click()

    assert html =~ "Radial topology graph"

    # Switch back to grid
    html =
      view
      |> element("button[phx-value-mode=grid]")
      |> render_click()

    refute html =~ "Radial topology graph"

    cleanup_agent(a1)
  end

  # -- Detail panel tests --

  test "navigating to /agents/:id opens detail panel", %{conn: conn} do
    {agent, _pid} = register_agent("detail-agent", capabilities: ["analysis"], role: "analyst")

    {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
    assert html =~ "detail-agent"
    assert html =~ "analyst"
    assert html =~ "analysis"
    assert html =~ "Agent ID"
    assert html =~ agent.id

    cleanup_agent(agent)
  end

  test "close_detail navigates back to /agents", %{conn: conn} do
    {agent, _pid} = register_agent("closeme-agent")

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}")
    assert render(view) =~ "closeme-agent"

    view
    |> element("button[aria-label=\"Close panel\"]")
    |> render_click()

    assert_patch(view, "/agents")

    cleanup_agent(agent)
  end

  test "detail panel shows agent load information", %{conn: conn} do
    {agent, _pid} = register_agent("load-agent")

    {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
    assert html =~ "Active tasks"
    assert html =~ "Queue depth"

    cleanup_agent(agent)
  end

  test "navigating to non-existent agent shows no panel", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agents/00000000-0000-0000-0000-000000000000")
    assert html =~ "Agents"
  end

  # -- Grouping tests --

  test "group_by status groups agents", %{conn: conn} do
    {a1, _} = register_agent("idle-grouped")
    {a2, _} = register_agent("working-grouped")
    Registry.update_status(a2.id, :working)

    {:ok, view, _html} = live(conn, "/agents")

    html =
      view
      |> element("select[name=group]")
      |> render_change(%{"group" => "status"})

    assert html =~ "idle"
    assert html =~ "working"

    cleanup_agent(a1)
    cleanup_agent(a2)
  end

  test "group_by transport groups agents", %{conn: conn} do
    {a1, _} = register_agent("grouped-ws")

    {:ok, view, _html} = live(conn, "/agents")

    html =
      view
      |> element("select[name=group]")
      |> render_change(%{"group" => "transport"})

    assert html =~ "websocket"

    cleanup_agent(a1)
  end

  # -- Capability discovery tests --

  test "capability chips are rendered from all agents", %{conn: conn} do
    {a1, _} = register_agent("cap-agent-1", capabilities: ["search", "review"])
    {a2, _} = register_agent("cap-agent-2", capabilities: ["code-gen"])

    {:ok, _view, html} = live(conn, "/agents")
    assert html =~ "search"
    assert html =~ "review"
    assert html =~ "code-gen"

    cleanup_agent(a1)
    cleanup_agent(a2)
  end

  test "clicking a capability chip filters agents", %{conn: conn} do
    {a1, _} = register_agent("has-cap", capabilities: ["unique-cap"])
    {a2, _} = register_agent("no-cap", capabilities: ["other-cap"])

    {:ok, view, _html} = live(conn, "/agents")

    html =
      view
      |> element("button[phx-value-capability=unique-cap]")
      |> render_click()

    assert html =~ "has-cap"
    refute html =~ "no-cap"

    cleanup_agent(a1)
    cleanup_agent(a2)
  end

  # -- Layout toggle tests --

  test "toggle_layout switches between cards and list", %{conn: conn} do
    {a1, _} = register_agent("layout-agent")

    {:ok, view, _html} = live(conn, "/agents")

    html =
      view
      |> element("button[phx-value-layout=rows]")
      |> render_click()

    # List view renders a table
    assert html =~ "Name"
    assert html =~ "Role"

    cleanup_agent(a1)
  end

  # -- Integration: multiple agents --

  test "registers multiple agents and renders them all", %{conn: conn} do
    agents =
      for i <- 1..5 do
        {agent, _pid} = register_agent("multi-#{i}", capabilities: ["cap-#{i}"])
        agent
      end

    {:ok, _view, html} = live(conn, "/agents")

    for i <- 1..5 do
      assert html =~ "multi-#{i}"
    end

    Enum.each(agents, &cleanup_agent/1)
  end
end
