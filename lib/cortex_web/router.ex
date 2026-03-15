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

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/health", CortexWeb do
    pipe_through(:api)

    get("/live", HealthController, :live)
    get("/ready", HealthController, :ready)
  end

  scope "/", CortexWeb do
    get("/metrics", MetricsController, :index)
  end

  scope "/api", CortexWeb do
    pipe_through(:api)

    resources("/runs", RunController, only: [:index, :create, :show]) do
      resources("/teams", TeamRunController, only: [:index, :show], param: "name")
    end
  end

  scope "/", CortexWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/runs", RunListLive, :index)
    live("/runs/compare", RunCompareLive, :index)
    live("/runs/:id", RunDetailLive, :show)
    live("/runs/:id/teams/:name", TeamDetailLive, :show)
    live("/workflows", NewRunLive, :index)
    live("/gossip", GossipLive, :index)
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
