defmodule CortexWeb.RunListLiveTest do
  use CortexWeb.ConnCase

  test "renders run list page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/runs")
    assert html =~ "Runs"
    assert html =~ "All orchestration runs"
  end

  test "shows empty state when no runs exist", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/runs")
    assert html =~ "No runs found"
  end

  test "shows runs in table when they exist", %{conn: conn} do
    {:ok, _run} =
      Cortex.Store.create_run(%{
        name: "my-run",
        status: "running",
        team_count: 2
      })

    {:ok, _view, html} = live(conn, "/runs")
    assert html =~ "my-run"
    assert html =~ "running"
  end

  test "status filter works", %{conn: conn} do
    {:ok, _} = Cortex.Store.create_run(%{name: "running-run", status: "running"})
    {:ok, _} = Cortex.Store.create_run(%{name: "done-run", status: "completed"})

    {:ok, view, _html} = live(conn, "/runs")

    html =
      view
      |> element("form")
      |> render_change(%{"status" => "running"})

    assert html =~ "running-run"
    refute html =~ "done-run"
  end
end
