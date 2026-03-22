ExUnit.start(exclude: [:pending, :integration, :e2e, :external])
Ecto.Adapters.SQL.Sandbox.mode(Cortex.Repo, :manual)
