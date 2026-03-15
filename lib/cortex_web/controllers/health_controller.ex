defmodule CortexWeb.HealthController do
  @moduledoc """
  HTTP health check endpoints.

  - `/health/live` — returns 200 if the BEAM is up (liveness probe)
  - `/health/ready` — returns 200 if all subsystems are healthy (readiness probe)
  """

  use CortexWeb, :controller

  @doc "Liveness probe — always 200 if the BEAM is responding."
  def live(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @doc "Readiness probe — runs `Cortex.Health.check/0` and returns status."
  def ready(conn, _params) do
    health = Cortex.Health.check()

    status_code =
      case health.status do
        :ok -> 200
        :degraded -> 200
        :down -> 503
      end

    conn
    |> put_status(status_code)
    |> json(%{
      status: Atom.to_string(health.status),
      checks: Map.new(health.checks, fn {k, v} -> {Atom.to_string(k), v} end)
    })
  end
end
