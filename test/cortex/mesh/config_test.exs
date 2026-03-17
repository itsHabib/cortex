defmodule Cortex.Mesh.ConfigTest do
  use ExUnit.Case, async: true

  alias Cortex.Mesh.Config, as: MeshConfig
  alias Cortex.Mesh.Config.{Agent, MeshSettings}
  alias Cortex.Orchestration.Config.Defaults

  describe "MeshSettings struct" do
    test "has correct defaults" do
      settings = %MeshSettings{}
      assert settings.heartbeat_interval_seconds == 30
      assert settings.suspect_timeout_seconds == 90
      assert settings.dead_timeout_seconds == 180
    end
  end

  describe "Agent struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Agent, %{name: "a"})
      end
    end

    test "creates with required fields" do
      agent = %Agent{name: "a", role: "researcher", prompt: "Do it."}
      assert agent.name == "a"
      assert agent.role == "researcher"
      assert agent.prompt == "Do it."
      assert agent.model == nil
      assert agent.metadata == %{}
    end
  end

  describe "MeshConfig struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(MeshConfig, %{})
      end
    end

    test "creates with defaults" do
      config = %MeshConfig{
        name: "test",
        agents: [%Agent{name: "a", role: "r", prompt: "p"}]
      }

      assert config.name == "test"
      assert %Defaults{} = config.defaults
      assert %MeshSettings{} = config.mesh
      assert config.cluster_context == nil
    end
  end
end
