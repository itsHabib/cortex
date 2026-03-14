defmodule Cortex.Gossip.TopologyTest do
  use ExUnit.Case, async: true

  alias Cortex.Gossip.Topology

  describe "build/3 with :full_mesh" do
    test "returns empty map for empty list" do
      assert Topology.build([], :full_mesh) == %{}
    end

    test "single agent has no peers" do
      assert Topology.build(["a"], :full_mesh) == %{"a" => []}
    end

    test "two agents peer with each other" do
      result = Topology.build(["a", "b"], :full_mesh)
      assert result == %{"a" => ["b"], "b" => ["a"]}
    end

    test "three agents — each peers with the other two" do
      result = Topology.build(["a", "b", "c"], :full_mesh)
      assert result["a"] |> Enum.sort() == ["b", "c"]
      assert result["b"] |> Enum.sort() == ["a", "c"]
      assert result["c"] |> Enum.sort() == ["a", "b"]
    end

    test "no agent peers with itself" do
      agents = ["a", "b", "c", "d"]
      result = Topology.build(agents, :full_mesh)

      for agent <- agents do
        refute agent in result[agent]
      end
    end

    test "peer count is n-1 for each agent" do
      agents = Enum.map(1..5, &"agent_#{&1}")
      result = Topology.build(agents, :full_mesh)

      for agent <- agents do
        assert length(result[agent]) == 4
      end
    end
  end

  describe "build/3 with :ring" do
    test "returns empty map for empty list" do
      assert Topology.build([], :ring) == %{}
    end

    test "single agent has no peers" do
      assert Topology.build(["a"], :ring) == %{"a" => []}
    end

    test "two agents peer with each other" do
      result = Topology.build(["a", "b"], :ring)
      assert result["a"] == ["b"]
      assert result["b"] == ["a"]
    end

    test "three agents — each has exactly two peers (prev and next)" do
      result = Topology.build(["a", "b", "c"], :ring)

      for agent <- ["a", "b", "c"] do
        assert length(result[agent]) == 2
        refute agent in result[agent]
      end
    end

    test "ring topology wraps around" do
      # For [a, b, c, d]: a peers with d (prev) and b (next)
      result = Topology.build(["a", "b", "c", "d"], :ring)

      assert "d" in result["a"]
      assert "b" in result["a"]
      assert "a" in result["b"]
      assert "c" in result["b"]
      assert "b" in result["c"]
      assert "d" in result["c"]
      assert "c" in result["d"]
      assert "a" in result["d"]
    end

    test "each agent has at most 2 peers" do
      agents = Enum.map(1..10, &"agent_#{&1}")
      result = Topology.build(agents, :ring)

      for agent <- agents do
        assert length(result[agent]) == 2
      end
    end

    test "no agent peers with itself" do
      agents = Enum.map(1..5, &"agent_#{&1}")
      result = Topology.build(agents, :ring)

      for agent <- agents do
        refute agent in result[agent]
      end
    end
  end

  describe "build/3 with :random" do
    test "returns empty map for empty list" do
      assert Topology.build([], :random) == %{}
    end

    test "single agent has no peers" do
      assert Topology.build(["a"], :random) == %{"a" => []}
    end

    test "default k=3" do
      agents = Enum.map(1..10, &"agent_#{&1}")
      result = Topology.build(agents, :random)

      for agent <- agents do
        assert length(result[agent]) == 3
      end
    end

    test "custom k value" do
      agents = Enum.map(1..10, &"agent_#{&1}")
      result = Topology.build(agents, :random, k: 5)

      for agent <- agents do
        assert length(result[agent]) == 5
      end
    end

    test "k is capped at n-1" do
      agents = ["a", "b", "c"]
      result = Topology.build(agents, :random, k: 100)

      for agent <- agents do
        assert length(result[agent]) == 2
      end
    end

    test "no agent peers with itself" do
      agents = Enum.map(1..10, &"agent_#{&1}")
      result = Topology.build(agents, :random)

      for agent <- agents do
        refute agent in result[agent]
      end
    end

    test "all peers are valid agent IDs" do
      agents = Enum.map(1..10, &"agent_#{&1}")
      agent_set = MapSet.new(agents)
      result = Topology.build(agents, :random)

      for agent <- agents do
        for peer <- result[agent] do
          assert peer in agent_set
        end
      end
    end

    test "peers are unique per agent" do
      agents = Enum.map(1..10, &"agent_#{&1}")
      result = Topology.build(agents, :random, k: 5)

      for agent <- agents do
        peers = result[agent]
        assert length(peers) == length(Enum.uniq(peers))
      end
    end
  end
end
