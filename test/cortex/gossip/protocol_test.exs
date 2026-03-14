defmodule Cortex.Gossip.ProtocolTest do
  use ExUnit.Case, async: true

  alias Cortex.Gossip.Entry
  alias Cortex.Gossip.KnowledgeStore
  alias Cortex.Gossip.Protocol

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

  setup do
    {:ok, store_a} = KnowledgeStore.start_link(agent_id: "agent_a")
    {:ok, store_b} = KnowledgeStore.start_link(agent_id: "agent_b")
    %{store_a: store_a, store_b: store_b}
  end

  describe "exchange/2" do
    test "syncs entries from A to B", %{store_a: store_a, store_b: store_b} do
      entry = make_entry(id: "e1", source: "agent_a")
      KnowledgeStore.put(store_a, entry)

      assert :ok = Protocol.exchange(store_a, store_b)

      assert {:ok, synced} = KnowledgeStore.get(store_b, "e1")
      assert synced.id == "e1"
    end

    test "syncs entries from B to A", %{store_a: store_a, store_b: store_b} do
      entry = make_entry(id: "e1", source: "agent_b")
      KnowledgeStore.put(store_b, entry)

      assert :ok = Protocol.exchange(store_a, store_b)

      assert {:ok, synced} = KnowledgeStore.get(store_a, "e1")
      assert synced.id == "e1"
    end

    test "bidirectional sync — both gain entries", %{store_a: store_a, store_b: store_b} do
      entry_a = make_entry(id: "from-a", source: "agent_a", content: "A's knowledge")
      entry_b = make_entry(id: "from-b", source: "agent_b", content: "B's knowledge")

      KnowledgeStore.put(store_a, entry_a)
      KnowledgeStore.put(store_b, entry_b)

      assert :ok = Protocol.exchange(store_a, store_b)

      # A now has B's entry
      assert {:ok, _} = KnowledgeStore.get(store_a, "from-b")
      # B now has A's entry
      assert {:ok, _} = KnowledgeStore.get(store_b, "from-a")

      assert KnowledgeStore.size(store_a) == 2
      assert KnowledgeStore.size(store_b) == 2
    end

    test "no-op when both stores are empty", %{store_a: store_a, store_b: store_b} do
      assert :ok = Protocol.exchange(store_a, store_b)
      assert KnowledgeStore.size(store_a) == 0
      assert KnowledgeStore.size(store_b) == 0
    end

    test "no-op when both stores have identical entries", %{store_a: store_a, store_b: store_b} do
      entry = make_entry(id: "shared")
      KnowledgeStore.put(store_a, entry)
      KnowledgeStore.put(store_b, entry)

      assert :ok = Protocol.exchange(store_a, store_b)

      assert KnowledgeStore.size(store_a) == 1
      assert KnowledgeStore.size(store_b) == 1
    end

    test "newer version propagates to the other store", %{store_a: store_a, store_b: store_b} do
      old = make_entry(id: "e1", vector_clock: %{"a" => 1}, content: "old")
      new = make_entry(id: "e1", vector_clock: %{"a" => 2}, content: "new")

      KnowledgeStore.put(store_a, new)
      KnowledgeStore.put(store_b, old)

      assert :ok = Protocol.exchange(store_a, store_b)

      assert {:ok, stored} = KnowledgeStore.get(store_b, "e1")
      assert stored.content == "new"
    end

    test "multiple entries sync correctly", %{store_a: store_a, store_b: store_b} do
      entries_a =
        for i <- 1..5 do
          make_entry(id: "a-#{i}", source: "agent_a", content: "A content #{i}")
        end

      entries_b =
        for i <- 1..3 do
          make_entry(id: "b-#{i}", source: "agent_b", content: "B content #{i}")
        end

      Enum.each(entries_a, &KnowledgeStore.put(store_a, &1))
      Enum.each(entries_b, &KnowledgeStore.put(store_b, &1))

      assert :ok = Protocol.exchange(store_a, store_b)

      assert KnowledgeStore.size(store_a) == 8
      assert KnowledgeStore.size(store_b) == 8
    end

    test "exchange is idempotent", %{store_a: store_a, store_b: store_b} do
      entry = make_entry(id: "e1")
      KnowledgeStore.put(store_a, entry)

      Protocol.exchange(store_a, store_b)
      Protocol.exchange(store_a, store_b)
      Protocol.exchange(store_a, store_b)

      assert KnowledgeStore.size(store_a) == 1
      assert KnowledgeStore.size(store_b) == 1
    end
  end
end
