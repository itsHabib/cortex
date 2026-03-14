defmodule Cortex.Gossip.KnowledgeStoreTest do
  use ExUnit.Case, async: true

  alias Cortex.Gossip.Entry
  alias Cortex.Gossip.KnowledgeStore

  setup do
    {:ok, pid} = KnowledgeStore.start_link(agent_id: "test_agent")
    %{store: pid}
  end

  defp make_entry(overrides) do
    defaults = [
      id: Uniq.UUID.uuid4(),
      topic: "research",
      content: "some finding",
      source: "agent_a",
      confidence: 0.5,
      timestamp: DateTime.utc_now(),
      vector_clock: %{"agent_a" => 1}
    ]

    struct!(Entry, Keyword.merge(defaults, overrides))
  end

  describe "put/2 and get/2" do
    test "stores and retrieves an entry", %{store: store} do
      entry = make_entry(id: "entry-1")
      :ok = KnowledgeStore.put(store, entry)

      assert {:ok, ^entry} = KnowledgeStore.get(store, "entry-1")
    end

    test "returns :not_found for missing entry", %{store: store} do
      assert :not_found = KnowledgeStore.get(store, "nonexistent")
    end

    test "overwrites entry with same id if remote dominates", %{store: store} do
      entry_v1 = make_entry(id: "entry-1", vector_clock: %{"a" => 1}, content: "old")
      entry_v2 = make_entry(id: "entry-1", vector_clock: %{"a" => 2}, content: "new")

      :ok = KnowledgeStore.put(store, entry_v1)
      :ok = KnowledgeStore.put(store, entry_v2)

      assert {:ok, stored} = KnowledgeStore.get(store, "entry-1")
      assert stored.content == "new"
    end

    test "keeps local entry when local dominates", %{store: store} do
      entry_v2 = make_entry(id: "entry-1", vector_clock: %{"a" => 2}, content: "newer")
      entry_v1 = make_entry(id: "entry-1", vector_clock: %{"a" => 1}, content: "older")

      :ok = KnowledgeStore.put(store, entry_v2)
      :ok = KnowledgeStore.put(store, entry_v1)

      assert {:ok, stored} = KnowledgeStore.get(store, "entry-1")
      assert stored.content == "newer"
    end
  end

  describe "all/1" do
    test "returns empty list for empty store", %{store: store} do
      assert KnowledgeStore.all(store) == []
    end

    test "returns all entries", %{store: store} do
      entry1 = make_entry(id: "entry-1")
      entry2 = make_entry(id: "entry-2")

      KnowledgeStore.put(store, entry1)
      KnowledgeStore.put(store, entry2)

      entries = KnowledgeStore.all(store)
      assert length(entries) == 2
      ids = Enum.map(entries, & &1.id) |> Enum.sort()
      assert ids == ["entry-1", "entry-2"]
    end
  end

  describe "by_topic/2" do
    test "filters entries by topic", %{store: store} do
      entry1 = make_entry(id: "e1", topic: "research")
      entry2 = make_entry(id: "e2", topic: "market")
      entry3 = make_entry(id: "e3", topic: "research")

      KnowledgeStore.put(store, entry1)
      KnowledgeStore.put(store, entry2)
      KnowledgeStore.put(store, entry3)

      research = KnowledgeStore.by_topic(store, "research")
      assert length(research) == 2
      assert Enum.all?(research, &(&1.topic == "research"))

      market = KnowledgeStore.by_topic(store, "market")
      assert length(market) == 1
    end

    test "returns empty list for nonexistent topic", %{store: store} do
      assert KnowledgeStore.by_topic(store, "nonexistent") == []
    end
  end

  describe "digest/1" do
    test "returns list of {id, vector_clock} pairs", %{store: store} do
      vc = %{"agent_a" => 1}
      entry = make_entry(id: "e1", vector_clock: vc)
      KnowledgeStore.put(store, entry)

      digest = KnowledgeStore.digest(store)
      assert [{"e1", ^vc}] = digest
    end

    test "returns empty list for empty store", %{store: store} do
      assert KnowledgeStore.digest(store) == []
    end

    test "returns digest for multiple entries", %{store: store} do
      KnowledgeStore.put(store, make_entry(id: "e1", vector_clock: %{"a" => 1}))
      KnowledgeStore.put(store, make_entry(id: "e2", vector_clock: %{"b" => 2}))

      digest = KnowledgeStore.digest(store)
      assert length(digest) == 2

      ids = Enum.map(digest, fn {id, _vc} -> id end) |> Enum.sort()
      assert ids == ["e1", "e2"]
    end
  end

  describe "merge/2" do
    test "accepts entries not in the store", %{store: store} do
      entries = [
        make_entry(id: "e1", content: "first"),
        make_entry(id: "e2", content: "second")
      ]

      :ok = KnowledgeStore.merge(store, entries)

      assert {:ok, e1} = KnowledgeStore.get(store, "e1")
      assert e1.content == "first"

      assert {:ok, e2} = KnowledgeStore.get(store, "e2")
      assert e2.content == "second"
    end

    test "remote dominates local — accepts remote", %{store: store} do
      local = make_entry(id: "e1", vector_clock: %{"a" => 1}, content: "old")
      remote = make_entry(id: "e1", vector_clock: %{"a" => 2}, content: "new")

      KnowledgeStore.put(store, local)
      KnowledgeStore.merge(store, [remote])

      assert {:ok, stored} = KnowledgeStore.get(store, "e1")
      assert stored.content == "new"
    end

    test "local dominates remote — keeps local", %{store: store} do
      local = make_entry(id: "e1", vector_clock: %{"a" => 3}, content: "local")
      remote = make_entry(id: "e1", vector_clock: %{"a" => 1}, content: "remote")

      KnowledgeStore.put(store, local)
      KnowledgeStore.merge(store, [remote])

      assert {:ok, stored} = KnowledgeStore.get(store, "e1")
      assert stored.content == "local"
    end

    test "concurrent entries — higher confidence wins", %{store: store} do
      local =
        make_entry(
          id: "e1",
          vector_clock: %{"a" => 2, "b" => 1},
          confidence: 0.6,
          content: "local"
        )

      remote =
        make_entry(
          id: "e1",
          vector_clock: %{"a" => 1, "b" => 2},
          confidence: 0.9,
          content: "remote"
        )

      KnowledgeStore.put(store, local)
      KnowledgeStore.merge(store, [remote])

      assert {:ok, stored} = KnowledgeStore.get(store, "e1")
      assert stored.content == "remote"
      assert stored.confidence == 0.9
    end

    test "concurrent entries — equal confidence, later timestamp wins", %{store: store} do
      early = ~U[2026-01-01 00:00:00Z]
      late = ~U[2026-06-01 00:00:00Z]

      local =
        make_entry(
          id: "e1",
          vector_clock: %{"a" => 2, "b" => 1},
          confidence: 0.5,
          timestamp: early,
          content: "local"
        )

      remote =
        make_entry(
          id: "e1",
          vector_clock: %{"a" => 1, "b" => 2},
          confidence: 0.5,
          timestamp: late,
          content: "remote"
        )

      KnowledgeStore.put(store, local)
      KnowledgeStore.merge(store, [remote])

      assert {:ok, stored} = KnowledgeStore.get(store, "e1")
      assert stored.content == "remote"
    end

    test "concurrent entries — equal confidence and timestamp, keeps local", %{store: store} do
      ts = ~U[2026-03-01 12:00:00Z]

      local =
        make_entry(
          id: "e1",
          vector_clock: %{"a" => 2, "b" => 1},
          confidence: 0.5,
          timestamp: ts,
          content: "local"
        )

      remote =
        make_entry(
          id: "e1",
          vector_clock: %{"a" => 1, "b" => 2},
          confidence: 0.5,
          timestamp: ts,
          content: "remote"
        )

      KnowledgeStore.put(store, local)
      KnowledgeStore.merge(store, [remote])

      assert {:ok, stored} = KnowledgeStore.get(store, "e1")
      assert stored.content == "local"
    end

    test "equal vector clocks — keeps local", %{store: store} do
      vc = %{"a" => 1}

      local = make_entry(id: "e1", vector_clock: vc, content: "local")
      remote = make_entry(id: "e1", vector_clock: vc, content: "remote")

      KnowledgeStore.put(store, local)
      KnowledgeStore.merge(store, [remote])

      assert {:ok, stored} = KnowledgeStore.get(store, "e1")
      assert stored.content == "local"
    end
  end

  describe "entries_for_ids/2" do
    test "returns entries matching the given IDs", %{store: store} do
      KnowledgeStore.put(store, make_entry(id: "e1"))
      KnowledgeStore.put(store, make_entry(id: "e2"))
      KnowledgeStore.put(store, make_entry(id: "e3"))

      entries = KnowledgeStore.entries_for_ids(store, ["e1", "e3"])
      ids = Enum.map(entries, & &1.id) |> Enum.sort()
      assert ids == ["e1", "e3"]
    end

    test "skips missing IDs", %{store: store} do
      KnowledgeStore.put(store, make_entry(id: "e1"))

      entries = KnowledgeStore.entries_for_ids(store, ["e1", "missing"])
      assert length(entries) == 1
      assert hd(entries).id == "e1"
    end

    test "returns empty list for all missing", %{store: store} do
      assert KnowledgeStore.entries_for_ids(store, ["x", "y"]) == []
    end
  end

  describe "size/1" do
    test "returns 0 for empty store", %{store: store} do
      assert KnowledgeStore.size(store) == 0
    end

    test "returns correct count", %{store: store} do
      KnowledgeStore.put(store, make_entry(id: "e1"))
      KnowledgeStore.put(store, make_entry(id: "e2"))
      assert KnowledgeStore.size(store) == 2
    end

    test "duplicate IDs do not increase count", %{store: store} do
      entry = make_entry(id: "e1", vector_clock: %{"a" => 1})
      KnowledgeStore.put(store, entry)
      KnowledgeStore.put(store, %{entry | vector_clock: %{"a" => 2}, content: "updated"})
      assert KnowledgeStore.size(store) == 1
    end
  end
end
