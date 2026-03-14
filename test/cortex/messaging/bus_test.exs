defmodule Cortex.Messaging.BusTest do
  use ExUnit.Case, async: false

  alias Cortex.Messaging.Bus
  alias Cortex.Messaging.AgentIntegration

  # These tests use the global Router and MailboxRegistry, so async: false.

  setup do
    # Generate unique agent IDs to avoid collisions between test runs
    agent_a = "bus-a-#{Uniq.UUID.uuid4()}"
    agent_b = "bus-b-#{Uniq.UUID.uuid4()}"
    agent_c = "bus-c-#{Uniq.UUID.uuid4()}"

    :ok = AgentIntegration.setup(agent_a)
    :ok = AgentIntegration.setup(agent_b)

    on_exit(fn ->
      AgentIntegration.teardown(agent_a)
      AgentIntegration.teardown(agent_b)
      AgentIntegration.teardown(agent_c)
    end)

    %{agent_a: agent_a, agent_b: agent_b, agent_c: agent_c}
  end

  describe "send_message/4 and receive_message/1" do
    test "high-level send and receive", %{agent_a: a, agent_b: b} do
      {:ok, sent} = Bus.send_message(a, b, "hello from bus")
      assert sent.from == a
      assert sent.to == b
      assert sent.content == "hello from bus"

      assert {:ok, received} = Bus.receive_message(b)
      assert received.content == "hello from bus"
      assert received.from == a
    end

    test "send with custom type", %{agent_a: a, agent_b: b} do
      {:ok, sent} = Bus.send_message(a, b, %{query: "status?"}, type: :request)
      assert sent.type == :request

      {:ok, received} = Bus.receive_message(b)
      assert received.type == :request
    end

    test "send to unregistered agent returns error", %{agent_a: a} do
      assert {:error, :not_found} = Bus.send_message(a, "nonexistent-agent", "lost")
    end

    test "receive from empty mailbox returns :empty", %{agent_a: a} do
      assert :empty = Bus.receive_message(a)
    end
  end

  describe "broadcast/3" do
    test "delivers to all agents", %{agent_a: a, agent_b: b, agent_c: c} do
      :ok = AgentIntegration.setup(c)

      {:ok, sent} = Bus.broadcast(a, "announcement")
      assert sent.to == :broadcast

      # All registered agents receive it (including the sender,
      # since broadcast goes to all)
      # Give the cast time to deliver
      Process.sleep(20)

      # a, b, and c should all have the broadcast
      for agent <- [a, b, c] do
        assert {:ok, received} = Bus.receive_message(agent)
        assert received.content == "announcement"
      end
    end
  end

  describe "inbox/1" do
    test "returns messages without consuming", %{agent_a: a, agent_b: b} do
      {:ok, _} = Bus.send_message(a, b, "peek-1")
      {:ok, _} = Bus.send_message(a, b, "peek-2")

      # Give casts time to deliver
      Process.sleep(20)

      inbox = Bus.inbox(b)
      assert length(inbox) == 2
      assert Enum.map(inbox, & &1.content) == ["peek-1", "peek-2"]

      # Messages still there
      assert {:ok, r1} = Bus.receive_message(b)
      assert r1.content == "peek-1"
    end

    test "returns empty list for unknown agent" do
      assert Bus.inbox("no-such-agent") == []
    end
  end

  describe "receive_message/2 (blocking)" do
    test "blocks until message arrives", %{agent_a: a, agent_b: b} do
      parent = self()

      spawn(fn ->
        Process.sleep(50)
        Bus.send_message(a, b, "delayed-bus-msg")
        send(parent, :sent)
      end)

      assert {:ok, received} = Bus.receive_message(b, 2000)
      assert received.content == "delayed-bus-msg"
      assert_receive :sent
    end
  end

  describe "integration: 3 agents messaging each other" do
    test "triangle communication", %{agent_a: a, agent_b: b, agent_c: c} do
      :ok = AgentIntegration.setup(c)

      # A -> B
      {:ok, _} = Bus.send_message(a, b, "a-to-b")
      # B -> C
      {:ok, _} = Bus.send_message(b, c, "b-to-c")
      # C -> A
      {:ok, _} = Bus.send_message(c, a, "c-to-a")

      # Give casts time
      Process.sleep(20)

      assert {:ok, rb} = Bus.receive_message(b)
      assert rb.content == "a-to-b"
      assert rb.from == a

      assert {:ok, rc} = Bus.receive_message(c)
      assert rc.content == "b-to-c"
      assert rc.from == b

      assert {:ok, ra} = Bus.receive_message(a)
      assert ra.content == "c-to-a"
      assert ra.from == c
    end
  end
end
