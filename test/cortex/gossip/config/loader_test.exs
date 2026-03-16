defmodule Cortex.Gossip.Config.LoaderTest do
  use ExUnit.Case, async: true

  alias Cortex.Gossip.Config, as: GossipConfig
  alias Cortex.Gossip.Config.{Agent, GossipSettings, Loader, SeedKnowledge}

  @valid_yaml """
  name: "market-research-hyrox"
  mode: gossip

  defaults:
    model: sonnet
    max_turns: 20
    timeout_minutes: 15

  gossip:
    rounds: 5
    topology: random
    exchange_interval_seconds: 60

  agents:
    - name: competitor-analyst
      topic: "competitor analysis"
      prompt: |
        Research the competitive landscape.
    - name: market-sizer
      topic: "market sizing"
      prompt: |
        Estimate the total addressable market.
    - name: product-ideator
      topic: "product ideas"
      prompt: |
        Brainstorm product ideas.

  seed_knowledge:
    - topic: "context"
      content: "Hyrox is a fitness racing format."
  """

  describe "load_string/1" do
    test "parses valid gossip config" do
      assert {:ok, %GossipConfig{} = config} = Loader.load_string(@valid_yaml)

      assert config.name == "market-research-hyrox"
      assert config.defaults.model == "sonnet"
      assert config.defaults.max_turns == 20
      assert config.defaults.timeout_minutes == 15
    end

    test "parses gossip settings" do
      {:ok, config} = Loader.load_string(@valid_yaml)

      assert %GossipSettings{} = config.gossip
      assert config.gossip.rounds == 5
      assert config.gossip.topology == :random
      assert config.gossip.exchange_interval_seconds == 60
    end

    test "parses agents" do
      {:ok, config} = Loader.load_string(@valid_yaml)

      assert length(config.agents) == 3

      [first | _] = config.agents
      assert %Agent{} = first
      assert first.name == "competitor-analyst"
      assert first.topic == "competitor analysis"
      assert first.prompt =~ "Research the competitive landscape"
    end

    test "parses seed knowledge" do
      {:ok, config} = Loader.load_string(@valid_yaml)

      assert length(config.seed_knowledge) == 1
      [seed] = config.seed_knowledge
      assert %SeedKnowledge{} = seed
      assert seed.topic == "context"
      assert seed.content == "Hyrox is a fitness racing format."
    end

    test "parses topology variants" do
      for {topo_str, topo_atom} <- [
            {"full_mesh", :full_mesh},
            {"ring", :ring},
            {"random", :random}
          ] do
        yaml = """
        name: test
        mode: gossip
        gossip:
          topology: #{topo_str}
        agents:
          - name: a
            topic: t
            prompt: p
        """

        {:ok, config} = Loader.load_string(yaml)
        assert config.gossip.topology == topo_atom
      end
    end

    test "parses coordinator: true" do
      yaml = """
      name: test
      mode: gossip
      gossip:
        rounds: 3
        coordinator: true
      agents:
        - name: a
          topic: t
          prompt: p
      """

      {:ok, config} = Loader.load_string(yaml)
      assert config.gossip.coordinator == true
    end

    test "coordinator defaults to false" do
      yaml = """
      name: test
      mode: gossip
      gossip:
        rounds: 3
      agents:
        - name: a
          topic: t
          prompt: p
      """

      {:ok, config} = Loader.load_string(yaml)
      assert config.gossip.coordinator == false
    end

    test "uses defaults when gossip section is missing" do
      yaml = """
      name: test
      mode: gossip
      agents:
        - name: agent-a
          topic: "research"
          prompt: "Do research."
      """

      {:ok, config} = Loader.load_string(yaml)
      assert config.gossip.rounds == 5
      assert config.gossip.topology == :random
      assert config.gossip.exchange_interval_seconds == 60
      assert config.gossip.coordinator == false
    end

    test "uses defaults when defaults section is missing" do
      yaml = """
      name: test
      mode: gossip
      agents:
        - name: agent-a
          topic: "research"
          prompt: "Do research."
      """

      {:ok, config} = Loader.load_string(yaml)
      assert config.defaults.model == "sonnet"
      assert config.defaults.max_turns == 200
    end

    test "agent model override" do
      yaml = """
      name: test
      mode: gossip
      agents:
        - name: smart-agent
          topic: "deep research"
          prompt: "Think deeply."
          model: opus
      """

      {:ok, config} = Loader.load_string(yaml)
      [agent] = config.agents
      assert agent.model == "opus"
    end

    test "empty seed knowledge is fine" do
      yaml = """
      name: test
      mode: gossip
      agents:
        - name: agent-a
          topic: "research"
          prompt: "Do research."
      """

      {:ok, config} = Loader.load_string(yaml)
      assert config.seed_knowledge == []
    end
  end

  describe "validation" do
    test "rejects empty project name" do
      yaml = """
      name: ""
      mode: gossip
      agents:
        - name: a
          topic: t
          prompt: p
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert "project name cannot be empty" in errors
    end

    test "rejects empty agents list" do
      yaml = """
      name: test
      mode: gossip
      agents: []
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert "agents list cannot be empty" in errors
    end

    test "rejects agent with empty name" do
      yaml = """
      name: test
      mode: gossip
      agents:
        - name: ""
          topic: t
          prompt: p
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &String.contains?(&1, "name cannot be empty"))
    end

    test "rejects agent with empty topic" do
      yaml = """
      name: test
      mode: gossip
      agents:
        - name: agent-a
          topic: ""
          prompt: p
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &String.contains?(&1, "topic cannot be empty"))
    end

    test "rejects agent with empty prompt" do
      yaml = """
      name: test
      mode: gossip
      agents:
        - name: agent-a
          topic: t
          prompt: ""
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &String.contains?(&1, "prompt cannot be empty"))
    end

    test "rejects duplicate agent names" do
      yaml = """
      name: test
      mode: gossip
      agents:
        - name: agent-a
          topic: t1
          prompt: p1
        - name: agent-a
          topic: t2
          prompt: p2
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &String.contains?(&1, "duplicate agent names"))
    end

    test "rejects non-map YAML root" do
      assert {:error, ["YAML root must be a map"]} = Loader.load_string("just a string")
    end

    test "returns file not found for missing files" do
      assert {:error, ["file not found: /nonexistent/path.yaml"]} =
               Loader.load("/nonexistent/path.yaml")
    end
  end

  describe "load/1 with file" do
    @tag :tmp_dir
    test "loads from file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "gossip.yaml")
      File.write!(path, @valid_yaml)

      assert {:ok, %GossipConfig{} = config} = Loader.load(path)
      assert config.name == "market-research-hyrox"
      assert length(config.agents) == 3
    end
  end
end
