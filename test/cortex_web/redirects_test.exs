defmodule CortexWeb.RedirectsTest do
  @moduledoc """
  Tests that all legacy routes redirect to their new homes.
  """

  use CortexWeb.ConnCase

  describe "legacy route redirects" do
    test "/gossip redirects to /runs", %{conn: conn} do
      conn = get(conn, "/gossip")
      assert redirected_to(conn) == "/runs"
    end

    test "/mesh redirects to /runs", %{conn: conn} do
      conn = get(conn, "/mesh")
      assert redirected_to(conn) == "/runs"
    end

    test "/cluster redirects to /agents", %{conn: conn} do
      conn = get(conn, "/cluster")
      assert redirected_to(conn) == "/agents"
    end

    test "/jobs redirects to /runs", %{conn: conn} do
      conn = get(conn, "/jobs")
      assert redirected_to(conn) == "/runs"
    end

    test "/runs/compare redirects to /runs?view=compare", %{conn: conn} do
      conn = get(conn, "/runs/compare")
      assert redirected_to(conn) == "/runs?view=compare"
    end
  end

  describe "new routes resolve correctly" do
    test "/ mounts OverviewLive", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Overview"
    end

    test "/agents mounts AgentsLive", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Agents"
    end

    test "/workflows mounts WorkflowsLive", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/workflows")
      assert html =~ "Workflows"
    end

    test "/runs mounts RunsLive", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/runs")
      assert html =~ "Runs"
    end
  end

  describe "sidebar" do
    test "renders exactly 4 nav items", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Check all 4 nav items are present
      assert html =~ "Overview"
      assert html =~ "Agents"
      assert html =~ "Workflows"
      assert html =~ "Runs"

      # Check old nav items are NOT present
      refute html =~ ">Dashboard<"
      refute html =~ ">Gossip<"
      refute html =~ ">Mesh<"
      refute html =~ ">Cluster<"
      refute html =~ ">Jobs<"
    end
  end
end
