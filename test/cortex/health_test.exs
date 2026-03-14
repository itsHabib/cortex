defmodule Cortex.HealthTest do
  use ExUnit.Case

  alias Cortex.Health

  describe "check/0" do
    test "returns a map with status and checks" do
      result = Health.check()

      assert is_map(result)
      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checks)
      assert result.status in [:ok, :degraded, :down]
    end

    test "checks contain expected keys" do
      %{checks: checks} = Health.check()

      assert Map.has_key?(checks, :pubsub)
      assert Map.has_key?(checks, :supervisor)
      assert Map.has_key?(checks, :repo)
      assert Map.has_key?(checks, :tool_registry)
    end

    test "all core components are healthy in test env" do
      %{status: status, checks: checks} = Health.check()

      # In test env, all core components should be running
      assert checks.pubsub == true
      assert checks.supervisor == true
      assert checks.repo == true
      assert checks.tool_registry == true
      assert status == :ok
    end
  end
end
