defmodule CortexWeb.DashboardLiveTest do
  use CortexWeb.ConnCase

  test "renders dashboard page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Dashboard"
    assert html =~ "Total Runs"
    assert html =~ "Active Runs"
    assert html =~ "Total Cost"
    assert html =~ "New Run"
  end

  test "shows empty state when no runs exist", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "No runs yet"
  end

  test "shows runs in the table", %{conn: conn} do
    {:ok, _run} =
      Cortex.Store.create_run(%{
        name: "test-run",
        status: "completed",
        team_count: 3,
        total_cost_usd: 0.05
      })

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "test-run"
    assert html =~ "completed"
  end
end
