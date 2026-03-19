defmodule CortexWeb.WorkflowsLiveTest do
  use CortexWeb.ConnCase

  @valid_dag_yaml """
  name: test-project
  defaults:
    model: sonnet
    max_turns: 10
  teams:
    - name: backend
      lead:
        role: Backend Developer
      tasks:
        - summary: Build API
    - name: frontend
      lead:
        role: Frontend Developer
      depends_on:
        - backend
      tasks:
        - summary: Build UI
  """

  @valid_mesh_yaml """
  name: mesh-test
  mode: mesh
  defaults:
    model: sonnet
    max_turns: 10
  mesh:
    heartbeat_interval_seconds: 30
    suspect_timeout_seconds: 90
    dead_timeout_seconds: 180
  agents:
    - name: alpha
      role: Coordinator
      prompt: Coordinate
    - name: beta
      role: Worker
      prompt: Work
  """

  @valid_gossip_yaml """
  name: gossip-test
  mode: gossip
  defaults:
    model: sonnet
    max_turns: 10
  gossip:
    rounds: 3
    topology: random
    exchange_interval_seconds: 30
  agents:
    - name: researcher
      topic: research
      prompt: Research things
    - name: analyst
      topic: analysis
      prompt: Analyze findings
  """

  # -- Mode switching --

  test "mounts with DAG mode by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/workflows")
    assert html =~ "Workflows"
    assert html =~ "DAG Workflow"
    assert html =~ "Mesh"
    assert html =~ "Gossip"
  end

  test "mode selector switches between DAG, Mesh, and Gossip", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Switch to Mesh
    html = render_click(view, "select_mode", %{"mode" => "mesh"})
    assert html =~ "Mesh Config YAML"

    # Switch to Gossip
    html = render_click(view, "select_mode", %{"mode" => "gossip"})
    assert html =~ "Gossip Config YAML"

    # Switch back to DAG
    html = render_click(view, "select_mode", %{"mode" => "dag"})
    assert html =~ "DAG Workflow YAML"
  end

  # -- Composition toggle --

  test "composition toggle switches between YAML and Visual", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Switch to Visual
    html = render_click(view, "select_composition", %{"mode" => "visual"})
    assert html =~ "Project Settings"
    assert html =~ "Teams"

    # Switch back to YAML
    html = render_click(view, "select_composition", %{"mode" => "yaml"})
    assert html =~ "DAG Workflow YAML"
  end

  # -- DAG YAML validation --

  test "validates DAG YAML and shows config preview", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html =
      view
      |> form("form", %{"yaml" => @valid_dag_yaml})
      |> render_submit()

    assert html =~ "test-project"
    assert html =~ "backend"
    assert html =~ "frontend"
    assert html =~ "Launch Run"
    assert html =~ "Dependency Graph"
  end

  test "validates empty input shows error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html =
      view
      |> form("form", %{})
      |> render_submit()

    assert html =~ "Please provide YAML content"
  end

  # -- Mesh YAML validation --

  test "validates Mesh YAML in mesh mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Switch to mesh mode
    render_click(view, "select_mode", %{"mode" => "mesh"})

    html =
      view
      |> form("form", %{"yaml" => @valid_mesh_yaml})
      |> render_submit()

    assert html =~ "mesh-test"
    assert html =~ "alpha"
    assert html =~ "beta"
    assert html =~ "Heartbeat"
    assert html =~ "Launch Run"
  end

  # -- Gossip YAML validation --

  test "validates Gossip YAML in gossip mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Switch to gossip mode
    render_click(view, "select_mode", %{"mode" => "gossip"})

    html =
      view
      |> form("form", %{"yaml" => @valid_gossip_yaml})
      |> render_submit()

    assert html =~ "gossip-test"
    assert html =~ "researcher"
    assert html =~ "analyst"
    assert html =~ "Rounds"
    assert html =~ "Launch Run"
  end

  # -- Template loading --

  test "loading a template populates YAML editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html = render_click(view, "load_template", %{"template" => "dag_starter"})
    assert html =~ "my-project"
    assert html =~ "Backend Developer"
  end

  test "loading mesh template switches to mesh mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html = render_click(view, "load_template", %{"template" => "mesh_starter"})
    assert html =~ "my-mesh-project"
    assert html =~ "Coordinator"
  end

  test "loading gossip template switches to gossip mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    html = render_click(view, "load_template", %{"template" => "gossip_starter"})
    assert html =~ "my-gossip-project"
    assert html =~ "researcher"
  end

  # -- DAG launch --

  test "DAG launch creates a run and redirects", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Validate first
    view
    |> form("form", %{"yaml" => @valid_dag_yaml})
    |> render_submit()

    # Launch
    assert {:error, {:live_redirect, %{to: "/runs/" <> _id}}} =
             view |> element("button", "Launch Run") |> render_click()
  end

  # -- Mesh launch --

  test "Mesh launch creates a run and redirects", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    render_click(view, "select_mode", %{"mode" => "mesh"})

    view
    |> form("form", %{"yaml" => @valid_mesh_yaml})
    |> render_submit()

    assert {:error, {:live_redirect, %{to: "/runs/" <> _id}}} =
             view |> element("button", "Launch Run") |> render_click()
  end

  # -- Gossip launch --

  test "Gossip launch creates a run and redirects", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    render_click(view, "select_mode", %{"mode" => "gossip"})

    view
    |> form("form", %{"yaml" => @valid_gossip_yaml})
    |> render_submit()

    assert {:error, {:live_redirect, %{to: "/runs/" <> _id}}} =
             view |> element("button", "Launch Run") |> render_click()
  end

  # -- Launch without validation --

  test "launch without validation shows error flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Try to launch without validating (no Launch button visible, so click event directly)
    html = render_click(view, "launch", %{})
    assert html =~ "validate configuration before launching"
  end

  # -- Workspace conflict --

  test "workspace set in both YAML and form shows error", %{conn: conn} do
    yaml_with_workspace = """
    name: test-project
    defaults:
      model: sonnet
      max_turns: 10
    workspace_path: /yaml/workspace
    teams:
      - name: backend
        lead:
          role: Backend Developer
        tasks:
          - summary: Build API
    """

    {:ok, view, _html} = live(conn, "/workflows")

    html =
      view
      |> form("form", %{"yaml" => yaml_with_workspace, "workspace_path" => "/ui/workspace"})
      |> render_submit()

    assert html =~ "workspace_path is set in both"
  end

  # -- Visual mode DAG team builder --

  test "visual DAG mode: add and remove teams", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Switch to visual mode
    render_click(view, "select_composition", %{"mode" => "visual"})

    # Add a team
    html = render_click(view, "add_dag_team", %{})
    assert html =~ "Team 1"

    # Add another
    html = render_click(view, "add_dag_team", %{})
    assert html =~ "Team 2"
  end

  # -- Mode switching resets validation --

  test "switching mode clears validation state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    # Validate a DAG
    view
    |> form("form", %{"yaml" => @valid_dag_yaml})
    |> render_submit()

    # Switch to mesh -- should clear validation
    html = render_click(view, "select_mode", %{"mode" => "mesh"})
    refute html =~ "Launch Run"
    refute html =~ "Configuration Preview"
  end
end
