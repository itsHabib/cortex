defmodule CortexWeb.Router do
  use CortexWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {CortexWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", CortexWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/runs", RunListLive, :index)
    live("/runs/:id", RunDetailLive, :show)
    live("/runs/:id/teams/:name", TeamDetailLive, :show)
    live("/new", NewRunLive, :index)
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:cortex, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      live_dashboard("/dashboard", metrics: CortexWeb.Telemetry)
    end
  end
end
