ExUnit.start(exclude: [:pending, :integration, :e2e])
Ecto.Adapters.SQL.Sandbox.mode(Cortex.Repo, :manual)
