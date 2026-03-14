defmodule Cortex.Messaging.MessageTest do
  use ExUnit.Case, async: true

  alias Cortex.Messaging.Message

  describe "struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Message, %{})
      end
    end

    test "can be created with all fields" do
      msg = %Message{
        id: "test-id",
        from: "agent-a",
        to: "agent-b",
        content: "hello",
        type: :message,
        timestamp: DateTime.utc_now(),
        metadata: %{foo: "bar"}
      }

      assert msg.id == "test-id"
      assert msg.from == "agent-a"
      assert msg.to == "agent-b"
      assert msg.content == "hello"
      assert msg.type == :message
      assert msg.metadata == %{foo: "bar"}
    end

    test "optional fields default to nil" do
      msg = %Message{id: "x", from: "a", to: "b", content: "c"}
      assert msg.type == nil
      assert msg.timestamp == nil
      assert msg.metadata == nil
    end
  end

  describe "new/1" do
    test "auto-generates UUID id" do
      msg = Message.new(%{from: "a", to: "b", content: "hi"})

      assert is_binary(msg.id)
      assert String.length(msg.id) == 36

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               msg.id
             )
    end

    test "auto-generates UTC timestamp" do
      before = DateTime.utc_now()
      msg = Message.new(%{from: "a", to: "b", content: "hi"})
      after_time = DateTime.utc_now()

      assert %DateTime{} = msg.timestamp
      assert DateTime.compare(msg.timestamp, before) in [:gt, :eq]
      assert DateTime.compare(msg.timestamp, after_time) in [:lt, :eq]
    end

    test "defaults type to :message" do
      msg = Message.new(%{from: "a", to: "b", content: "hi"})
      assert msg.type == :message
    end

    test "accepts custom type" do
      msg = Message.new(%{from: "a", to: "b", content: "hi", type: :request})
      assert msg.type == :request
    end

    test "accepts all valid types" do
      for type <- [:message, :request, :response, :result, :error] do
        msg = Message.new(%{from: "a", to: "b", content: "hi", type: type})
        assert msg.type == type
      end
    end

    test "rejects invalid type" do
      assert_raise ArgumentError, fn ->
        Message.new(%{from: "a", to: "b", content: "hi", type: :bogus})
      end
    end

    test "preserves from, to, and content" do
      msg = Message.new(%{from: "sender", to: "receiver", content: %{data: 42}})
      assert msg.from == "sender"
      assert msg.to == "receiver"
      assert msg.content == %{data: 42}
    end

    test "accepts :broadcast as to" do
      msg = Message.new(%{from: "a", to: :broadcast, content: "hello all"})
      assert msg.to == :broadcast
    end

    test "accepts metadata" do
      msg = Message.new(%{from: "a", to: "b", content: "hi", metadata: %{trace_id: "xyz"}})
      assert msg.metadata == %{trace_id: "xyz"}
    end

    test "metadata defaults to nil when not provided" do
      msg = Message.new(%{from: "a", to: "b", content: "hi"})
      assert msg.metadata == nil
    end

    test "each call generates a unique id" do
      msg1 = Message.new(%{from: "a", to: "b", content: "1"})
      msg2 = Message.new(%{from: "a", to: "b", content: "2"})
      assert msg1.id != msg2.id
    end

    test "content can be any term" do
      for content <- ["string", 42, [:list], %{map: true}, {:tuple, 1}, nil] do
        msg = Message.new(%{from: "a", to: "b", content: content})
        assert msg.content == content
      end
    end
  end

  describe "valid_types/0" do
    test "returns all valid message types" do
      types = Message.valid_types()
      assert :message in types
      assert :request in types
      assert :response in types
      assert :result in types
      assert :error in types
      assert length(types) == 5
    end
  end
end
