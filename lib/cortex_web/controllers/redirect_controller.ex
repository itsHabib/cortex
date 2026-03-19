defmodule CortexWeb.RedirectController do
  @moduledoc """
  Handles legacy route redirects from the old 7-item navigation to the new 4-item structure.

  All redirects are 302 (temporary) during the transition period.
  """

  use CortexWeb, :controller

  @doc "Redirect /gossip -> /runs with flash."
  @spec gossip(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def gossip(conn, _params) do
    conn
    |> put_flash(:info, "Gossip sessions are now launched and viewed as runs")
    |> redirect(to: "/runs")
  end

  @doc "Redirect /mesh -> /runs with flash."
  @spec mesh(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mesh(conn, _params) do
    conn
    |> put_flash(:info, "Mesh sessions are now launched and viewed as runs")
    |> redirect(to: "/runs")
  end

  @doc "Redirect /cluster -> /agents."
  @spec cluster(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cluster(conn, _params) do
    conn
    |> redirect(to: "/agents")
  end

  @doc "Redirect /jobs -> /runs with flash."
  @spec jobs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def jobs(conn, _params) do
    conn
    |> put_flash(:info, "Jobs are now accessed per-run in the run detail Jobs tab")
    |> redirect(to: "/runs")
  end

  @doc "Redirect /runs/compare -> /runs?view=compare."
  @spec runs_compare(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def runs_compare(conn, _params) do
    conn
    |> redirect(to: "/runs?view=compare")
  end
end
