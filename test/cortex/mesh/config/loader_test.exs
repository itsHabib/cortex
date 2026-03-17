defmodule Cortex.Mesh.Config.LoaderTest do
  use ExUnit.Case, async: true

  alias Cortex.Mesh.Config, as: MeshConfig
  alias Cortex.Mesh.Config.{Agent, Loader, MeshSettings}

  @valid_yaml """
  name: "market-research"
  mode: mesh

  cluster_context: |
    Research the Hyrox fitness market.

  defaults:
    model: sonnet
    max_turns: 100
    timeout_minutes: 15

  mesh:
    heartbeat_interval_seconds: 20
    suspect_timeout_seconds: 60
    dead_timeout_seconds: 120

  agents:
    - name: market-sizing
      role: "Market researcher"
      prompt: |
        Research market size.
    - name: competitor-analysis
      role: "Competitive analyst"
      prompt: |
        Analyze competitors.
      model: opus
      metadata:
        capabilities:
          - research
          - comparison
  """

  describe "load_string/1" do
    test "parses valid mesh config" do
      assert {:ok, %MeshConfig{} = config} = Loader.load_string(@valid_yaml)
      assert config.name == "market-research"
      assert config.defaults.model == "sonnet"
      assert config.defaults.max_turns == 100
      assert config.defaults.timeout_minutes == 15
    end

    test "parses cluster_context" do
      {:ok, config} = Loader.load_string(@valid_yaml)
      assert config.cluster_context =~ "Hyrox"
    end

    test "parses mesh settings" do
      {:ok, config} = Loader.load_string(@valid_yaml)
      assert %MeshSettings{} = config.mesh
      assert config.mesh.heartbeat_interval_seconds == 20
      assert config.mesh.suspect_timeout_seconds == 60
      assert config.mesh.dead_timeout_seconds == 120
    end

    test "parses agents" do
      {:ok, config} = Loader.load_string(@valid_yaml)
      assert length(config.agents) == 2

      [first | _] = config.agents
      assert %Agent{} = first
      assert first.name == "market-sizing"
      assert first.role == "Market researcher"
      assert first.prompt =~ "market size"
    end

    test "parses agent model override" do
      {:ok, config} = Loader.load_string(@valid_yaml)
      [_, second] = config.agents
      assert second.model == "opus"
    end

    test "parses agent metadata" do
      {:ok, config} = Loader.load_string(@valid_yaml)
      [_, second] = config.agents
      assert is_map(second.metadata)
      assert Map.has_key?(second.metadata, "capabilities")
    end

    test "uses defaults when mesh section is missing" do
      yaml = """
      name: test
      mode: mesh
      agents:
        - name: a
          role: researcher
          prompt: do it
      """

      {:ok, config} = Loader.load_string(yaml)
      assert config.mesh.heartbeat_interval_seconds == 30
      assert config.mesh.suspect_timeout_seconds == 90
      assert config.mesh.dead_timeout_seconds == 180
    end

    test "uses defaults when defaults section is missing" do
      yaml = """
      name: test
      mode: mesh
      agents:
        - name: a
          role: researcher
          prompt: do it
      """

      {:ok, config} = Loader.load_string(yaml)
      assert config.defaults.model == "sonnet"
      assert config.defaults.max_turns == 200
    end

    test "handles nil metadata gracefully" do
      yaml = """
      name: test
      mode: mesh
      agents:
        - name: a
          role: researcher
          prompt: do it
      """

      {:ok, config} = Loader.load_string(yaml)
      [agent] = config.agents
      assert agent.metadata == %{}
    end
  end

  describe "validation" do
    test "rejects empty project name" do
      yaml = """
      name: ""
      mode: mesh
      agents:
        - name: a
          role: r
          prompt: p
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert "project name cannot be empty" in errors
    end

    test "rejects empty agents list" do
      yaml = """
      name: test
      mode: mesh
      agents: []
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert "agents list cannot be empty" in errors
    end

    test "rejects agent with empty name" do
      yaml = """
      name: test
      mode: mesh
      agents:
        - name: ""
          role: r
          prompt: p
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &String.contains?(&1, "name cannot be empty"))
    end

    test "rejects agent with empty role" do
      yaml = """
      name: test
      mode: mesh
      agents:
        - name: a
          role: ""
          prompt: p
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &String.contains?(&1, "role cannot be empty"))
    end

    test "rejects agent with empty prompt" do
      yaml = """
      name: test
      mode: mesh
      agents:
        - name: a
          role: r
          prompt: ""
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &String.contains?(&1, "prompt cannot be empty"))
    end

    test "rejects duplicate agent names" do
      yaml = """
      name: test
      mode: mesh
      agents:
        - name: agent-a
          role: r1
          prompt: p1
        - name: agent-a
          role: r2
          prompt: p2
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &String.contains?(&1, "duplicate agent names"))
    end

    test "rejects non-map YAML root" do
      assert {:error, ["YAML root must be a map"]} = Loader.load_string("just a string")
    end

    test "rejects invalid mesh settings" do
      yaml = """
      name: test
      mode: mesh
      mesh:
        heartbeat_interval_seconds: 0
      agents:
        - name: a
          role: r
          prompt: p
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &String.contains?(&1, "heartbeat_interval_seconds"))
    end

    test "returns file not found for missing files" do
      assert {:error, ["file not found: /nonexistent/path.yaml"]} =
               Loader.load("/nonexistent/path.yaml")
    end
  end

  describe "load/1 with file" do
    @tag :tmp_dir
    test "loads from file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "mesh.yaml")
      File.write!(path, @valid_yaml)

      assert {:ok, %MeshConfig{} = config} = Loader.load(path)
      assert config.name == "market-research"
      assert length(config.agents) == 2
    end
  end
end
