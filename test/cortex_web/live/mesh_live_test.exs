defmodule CortexWeb.MeshLiveTest do
  use CortexWeb.ConnCase

  test "renders mesh protocol page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/mesh")
    assert html =~ "Mesh Protocol"
    assert html =~ "New Mesh Run"
  end

  test "shows empty state when no active session", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/mesh")
    assert html =~ "Mesh YAML"
    assert html =~ "Validate"
  end

  test "validates valid mesh YAML", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mesh")

    yaml = """
    name: test-mesh
    mode: mesh
    agents:
      - name: agent-a
        role: Researcher
        prompt: Do research
      - name: agent-b
        role: Writer
        prompt: Write output
    """

    html =
      view
      |> element("form")
      |> render_submit(%{"yaml" => yaml})

    assert html =~ "test-mesh"
    assert html =~ "agent-a"
    assert html =~ "agent-b"
    assert html =~ "Launch Mesh Run"
  end

  test "shows validation errors for empty agents", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mesh")

    yaml = """
    name: test-mesh
    mode: mesh
    agents: []
    """

    html =
      view
      |> element("form")
      |> render_submit(%{"yaml" => yaml})

    assert html =~ "cannot be empty"
  end

  test "receives mesh_started PubSub event", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mesh")

    Cortex.Events.broadcast(:mesh_started, %{
      project: "my-mesh",
      agents: ["alpha", "beta"]
    })

    html = render(view)
    assert html =~ "my-mesh"
    assert html =~ "Mesh session active"
    assert html =~ "alpha"
    assert html =~ "beta"
  end

  test "receives member state transition events", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mesh")

    Cortex.Events.broadcast(:mesh_started, %{project: "test", agents: ["a", "b"]})

    Cortex.Events.broadcast(:member_suspect, %{cluster: "test", run_id: nil, name: "a"})
    html = render(view)
    assert html =~ "suspect"

    Cortex.Events.broadcast(:member_dead, %{cluster: "test", run_id: nil, name: "a"})
    html = render(view)
    assert html =~ "dead"
  end

  test "receives mesh_completed event", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mesh")

    Cortex.Events.broadcast(:mesh_started, %{project: "test", agents: ["a"]})
    Cortex.Events.broadcast(:mesh_completed, %{project: "test", duration_ms: 5000})

    html = render(view)
    refute html =~ "Mesh session active"
  end

  test "select and deselect member", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mesh")

    Cortex.Events.broadcast(:mesh_started, %{project: "test", agents: ["alpha", "beta"]})
    render(view)

    # Select via roster table row
    html = view |> element("tr[phx-value-name=alpha]") |> render_click()
    assert html =~ "alpha"

    # Deselect by clicking the close button in the detail panel
    html = view |> element("button[phx-value-name=alpha]") |> render_click()
    assert html =~ "Select a node"
  end

  test "tracks token updates", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mesh")

    Cortex.Events.broadcast(:mesh_started, %{project: "test", agents: ["alpha"]})

    Cortex.Events.broadcast(:team_tokens_updated, %{
      run_id: nil,
      team_name: "alpha",
      input_tokens: 1500,
      output_tokens: 800
    })

    html = render(view)
    assert html =~ "2.3K"
  end

  test "shows mesh settings in config preview", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mesh")

    yaml = """
    name: custom-mesh
    mode: mesh
    mesh:
      heartbeat_interval_seconds: 15
      suspect_timeout_seconds: 45
      dead_timeout_seconds: 120
    agents:
      - name: agent-x
        role: Builder
        prompt: Build things
    """

    html =
      view
      |> element("form")
      |> render_submit(%{"yaml" => yaml})

    assert html =~ "custom-mesh"
    assert html =~ "15s"
    assert html =~ "45s"
    assert html =~ "120s"
  end
end
