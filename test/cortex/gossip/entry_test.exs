defmodule Cortex.Gossip.EntryTest do
  use ExUnit.Case, async: true

  alias Cortex.Gossip.Entry

  describe "struct creation" do
    test "creates entry with enforce_keys" do
      entry = %Entry{
        id: "test-id",
        topic: "research",
        content: "some finding",
        source: "agent_a"
      }

      assert entry.id == "test-id"
      assert entry.topic == "research"
      assert entry.content == "some finding"
      assert entry.source == "agent_a"
    end

    test "default confidence is 0.5" do
      entry = %Entry{
        id: "test-id",
        topic: "research",
        content: "some finding",
        source: "agent_a"
      }

      assert entry.confidence == 0.5
    end

    test "default vector_clock is empty map" do
      entry = %Entry{
        id: "test-id",
        topic: "research",
        content: "some finding",
        source: "agent_a"
      }

      assert entry.vector_clock == %{}
    end

    test "default metadata is empty map" do
      entry = %Entry{
        id: "test-id",
        topic: "research",
        content: "some finding",
        source: "agent_a"
      }

      assert entry.metadata == %{}
    end

    test "default timestamp is nil" do
      entry = %Entry{
        id: "test-id",
        topic: "research",
        content: "some finding",
        source: "agent_a"
      }

      assert entry.timestamp == nil
    end

    test "raises when missing enforce_keys" do
      assert_raise ArgumentError, fn ->
        struct!(Entry, %{topic: "research"})
      end
    end

    test "all fields can be set" do
      now = DateTime.utc_now()
      vc = %{"agent_a" => 1}

      entry = %Entry{
        id: "custom-id",
        topic: "market",
        content: "market is big",
        source: "agent_a",
        confidence: 0.9,
        timestamp: now,
        vector_clock: vc,
        metadata: %{tags: ["finance"]}
      }

      assert entry.confidence == 0.9
      assert entry.timestamp == now
      assert entry.vector_clock == vc
      assert entry.metadata == %{tags: ["finance"]}
    end
  end

  describe "new/1" do
    test "creates entry with generated UUID" do
      entry = Entry.new(topic: "test", content: "hello", source: "agent_a")

      assert is_binary(entry.id)
      assert String.length(entry.id) == 36
    end

    test "creates entry with timestamp set to now" do
      before = DateTime.utc_now()
      entry = Entry.new(topic: "test", content: "hello", source: "agent_a")
      after_time = DateTime.utc_now()

      assert %DateTime{} = entry.timestamp
      assert DateTime.compare(entry.timestamp, before) in [:gt, :eq]
      assert DateTime.compare(entry.timestamp, after_time) in [:lt, :eq]
    end

    test "creates entry with vector clock initialized for source" do
      entry = Entry.new(topic: "test", content: "hello", source: "agent_a")
      assert entry.vector_clock == %{"agent_a" => 1}
    end

    test "accepts map attrs" do
      entry = Entry.new(%{topic: "test", content: "hello", source: "agent_a"})
      assert entry.topic == "test"
    end

    test "allows overriding id" do
      entry = Entry.new(id: "custom-id", topic: "test", content: "hello", source: "agent_a")
      assert entry.id == "custom-id"
    end

    test "allows overriding vector_clock" do
      vc = %{"agent_a" => 3, "agent_b" => 1}
      entry = Entry.new(topic: "test", content: "hello", source: "agent_a", vector_clock: vc)
      assert entry.vector_clock == vc
    end

    test "allows overriding timestamp" do
      ts = ~U[2026-01-01 00:00:00Z]
      entry = Entry.new(topic: "test", content: "hello", source: "agent_a", timestamp: ts)
      assert entry.timestamp == ts
    end

    test "sets confidence to default 0.5" do
      entry = Entry.new(topic: "test", content: "hello", source: "agent_a")
      assert entry.confidence == 0.5
    end

    test "allows setting confidence" do
      entry = Entry.new(topic: "test", content: "hello", source: "agent_a", confidence: 0.9)
      assert entry.confidence == 0.9
    end
  end
end
