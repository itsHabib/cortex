defmodule CortexWeb.NewRunLiveTest do
  use CortexWeb.ConnCase

  @valid_yaml """
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

  test "renders new run page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/new")
    assert html =~ "New Run"
    assert html =~ "Orchestra YAML"
    assert html =~ "Validate"
  end

  test "validate button shows errors for empty input", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/new")

    html =
      view
      |> element("button", "Validate")
      |> render_click()

    assert html =~ "Please provide YAML content"
  end

  test "validate button shows config preview for valid YAML", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/new")

    # Set YAML content via blur event
    view |> element("textarea") |> render_blur(%{"yaml" => @valid_yaml})

    html =
      view
      |> element("button", "Validate")
      |> render_click()

    assert html =~ "test-project"
    assert html =~ "backend"
    assert html =~ "frontend"
    assert html =~ "Launch Run"
  end

  test "launch creates a run and redirects", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/new")

    view |> element("textarea") |> render_blur(%{"yaml" => @valid_yaml})
    view |> element("button", "Validate") |> render_click()

    assert {:error, {:live_redirect, %{to: "/runs/" <> _id}}} =
             view |> element("button", "Launch Run") |> render_click()
  end
end
