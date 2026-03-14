defmodule Cortex.Gossip.RunnerTest do
  use ExUnit.Case, async: true

  alias Cortex.Gossip.Entry
  alias Cortex.Gossip.Runner

  defp make_entry(overrides) do
    defaults = [
      id: Uniq.UUID.uuid4(),
      topic: "research",
      content: "finding",
      source: "agent_a",
      confidence: 0.5,
      timestamp: DateTime.utc_now(),
      vector_clock: %{"agent_a" => 1}
    ]

    struct!(Entry, Keyword.merge(defaults, overrides))
  end

  describe "run/1" do
    test "returns error for empty agents" do
      assert {:error, :no_agents} = Runner.run(agents: [])
    end

    test "runs with a single agent and no seed knowledge" do
      assert {:ok, result} = Runner.run(agents: ["agent_a"], rounds: 1)
      assert result.entries == []
      assert result.rounds_completed == 1
      assert result.agent_count == 1
    end

    test "distributes seed knowledge and returns it" do
      entry = make_entry(id: "seed-1", source: "agent_a")

      assert {:ok, result} =
               Runner.run(
                 agents: ["agent_a"],
                 rounds: 1,
                 seed_knowledge: [%{agent_id: "agent_a", entries: [entry]}]
               )

      assert length(result.entries) == 1
      assert hd(result.entries).id == "seed-1"
    end

    test "gossip converges — all agents end up with all entries" do
      entry_a = make_entry(id: "from-a", source: "agent_a", content: "A's finding")
      entry_b = make_entry(id: "from-b", source: "agent_b", content: "B's finding")
      entry_c = make_entry(id: "from-c", source: "agent_c", content: "C's finding")

      assert {:ok, result} =
               Runner.run(
                 agents: ["agent_a", "agent_b", "agent_c"],
                 rounds: 10,
                 topology: :full_mesh,
                 seed_knowledge: [
                   %{agent_id: "agent_a", entries: [entry_a]},
                   %{agent_id: "agent_b", entries: [entry_b]},
                   %{agent_id: "agent_c", entries: [entry_c]}
                 ]
               )

      # After enough rounds with full_mesh, all 3 entries should be present
      entry_ids = Enum.map(result.entries, & &1.id) |> Enum.sort()
      assert "from-a" in entry_ids
      assert "from-b" in entry_ids
      assert "from-c" in entry_ids
    end

    test "returns correct metadata" do
      assert {:ok, result} =
               Runner.run(
                 agents: ["a", "b"],
                 rounds: 5,
                 topology: :full_mesh
               )

      assert result.rounds_completed == 5
      assert result.agent_count == 2
      assert result.topology_strategy == :full_mesh
    end

    test "works with ring topology" do
      entry_a = make_entry(id: "from-a", source: "agent_a")
      entry_b = make_entry(id: "from-b", source: "agent_b")

      assert {:ok, result} =
               Runner.run(
                 agents: ["agent_a", "agent_b", "agent_c"],
                 rounds: 10,
                 topology: :ring,
                 seed_knowledge: [
                   %{agent_id: "agent_a", entries: [entry_a]},
                   %{agent_id: "agent_b", entries: [entry_b]}
                 ]
               )

      assert result.topology_strategy == :ring
      entry_ids = Enum.map(result.entries, & &1.id)
      assert "from-a" in entry_ids
      assert "from-b" in entry_ids
    end

    test "works with random topology" do
      entries =
        for i <- 1..5 do
          make_entry(id: "entry-#{i}", source: "agent_#{i}")
        end

      seed_knowledge =
        Enum.with_index(entries, 1)
        |> Enum.map(fn {entry, i} ->
          %{agent_id: "agent_#{i}", entries: [entry]}
        end)

      assert {:ok, result} =
               Runner.run(
                 agents: Enum.map(1..5, &"agent_#{&1}"),
                 rounds: 20,
                 topology: :random,
                 topology_opts: [k: 3],
                 seed_knowledge: seed_knowledge
               )

      assert result.topology_strategy == :random
      assert result.agent_count == 5
      # With enough rounds and k=3, most/all entries should propagate
      assert length(result.entries) >= 1
    end

    test "convergence verification — full mesh converges quickly" do
      entries =
        for i <- 1..4 do
          make_entry(id: "e-#{i}", source: "agent_#{i}", content: "content #{i}")
        end

      seed_knowledge =
        Enum.with_index(entries, 1)
        |> Enum.map(fn {entry, i} ->
          %{agent_id: "agent_#{i}", entries: [entry]}
        end)

      assert {:ok, result} =
               Runner.run(
                 agents: Enum.map(1..4, &"agent_#{&1}"),
                 rounds: 5,
                 topology: :full_mesh,
                 seed_knowledge: seed_knowledge
               )

      # Full mesh with 4 agents and 5 rounds should fully converge
      entry_ids = Enum.map(result.entries, & &1.id) |> Enum.sort()
      assert entry_ids == ["e-1", "e-2", "e-3", "e-4"]
    end

    test "handles seed knowledge for nonexistent agent gracefully" do
      entry = make_entry(id: "orphan", source: "ghost")

      assert {:ok, result} =
               Runner.run(
                 agents: ["agent_a"],
                 rounds: 1,
                 seed_knowledge: [%{agent_id: "ghost", entries: [entry]}]
               )

      # The orphan entry should not appear since the agent doesn't exist
      assert result.entries == []
    end

    test "many entries across many agents converge" do
      agent_count = 6
      entries_per_agent = 3
      agents = Enum.map(1..agent_count, &"agent_#{&1}")

      seed_knowledge =
        Enum.map(1..agent_count, fn i ->
          agent_entries =
            Enum.map(1..entries_per_agent, fn j ->
              make_entry(
                id: "agent_#{i}_entry_#{j}",
                source: "agent_#{i}",
                content: "Agent #{i} finding #{j}"
              )
            end)

          %{agent_id: "agent_#{i}", entries: agent_entries}
        end)

      assert {:ok, result} =
               Runner.run(
                 agents: agents,
                 rounds: 15,
                 topology: :full_mesh,
                 seed_knowledge: seed_knowledge
               )

      # All 18 entries should have converged
      assert length(result.entries) == agent_count * entries_per_agent
    end
  end
end
