defmodule Cortex.Messaging.MailboxTest do
  use ExUnit.Case, async: true

  alias Cortex.Messaging.Mailbox
  alias Cortex.Messaging.Message

  setup do
    {:ok, pid} = Mailbox.start_link(owner: "test-agent")
    %{mailbox: pid}
  end

  defp make_message(content, opts \\ []) do
    Message.new(%{
      from: Keyword.get(opts, :from, "sender"),
      to: Keyword.get(opts, :to, "test-agent"),
      content: content
    })
  end

  describe "send_message/2 and receive_message/1" do
    test "roundtrip: send then receive", %{mailbox: mailbox} do
      msg = make_message("hello")
      :ok = Mailbox.send_message(mailbox, msg)

      assert {:ok, received} = Mailbox.receive_message(mailbox)
      assert received.id == msg.id
      assert received.content == "hello"
    end

    test "returns :empty when no messages", %{mailbox: mailbox} do
      assert :empty = Mailbox.receive_message(mailbox)
    end

    test "FIFO ordering", %{mailbox: mailbox} do
      msg1 = make_message("first")
      msg2 = make_message("second")
      msg3 = make_message("third")

      :ok = Mailbox.send_message(mailbox, msg1)
      :ok = Mailbox.send_message(mailbox, msg2)
      :ok = Mailbox.send_message(mailbox, msg3)

      assert {:ok, r1} = Mailbox.receive_message(mailbox)
      assert {:ok, r2} = Mailbox.receive_message(mailbox)
      assert {:ok, r3} = Mailbox.receive_message(mailbox)

      assert r1.content == "first"
      assert r2.content == "second"
      assert r3.content == "third"
      assert :empty = Mailbox.receive_message(mailbox)
    end
  end

  describe "receive_message/2 (blocking with timeout)" do
    test "receives when message arrives within timeout", %{mailbox: mailbox} do
      # Send a message after a short delay
      parent = self()

      spawn(fn ->
        Process.sleep(50)
        msg = make_message("delayed")
        Mailbox.send_message(mailbox, msg)
        send(parent, :sent)
      end)

      result = Mailbox.receive_message(mailbox, 2000)
      assert {:ok, received} = result
      assert received.content == "delayed"
      assert_receive :sent
    end

    test "returns :timeout when no message arrives", %{mailbox: mailbox} do
      result = Mailbox.receive_message(mailbox, 100)
      assert result == :timeout
    end

    test "immediately returns if message already in queue", %{mailbox: mailbox} do
      msg = make_message("already here")
      :ok = Mailbox.send_message(mailbox, msg)

      assert {:ok, received} = Mailbox.receive_message(mailbox, 5000)
      assert received.content == "already here"
    end

    test "multiple waiters are served in order", %{mailbox: mailbox} do
      parent = self()

      # Spawn two waiters
      waiter1 =
        spawn(fn ->
          result = Mailbox.receive_message(mailbox, 2000)
          send(parent, {:waiter1, result})
        end)

      Process.sleep(10)

      waiter2 =
        spawn(fn ->
          result = Mailbox.receive_message(mailbox, 2000)
          send(parent, {:waiter2, result})
        end)

      Process.sleep(10)

      # Send two messages — first waiter gets first message
      msg1 = make_message("for-waiter-1")
      msg2 = make_message("for-waiter-2")
      Mailbox.send_message(mailbox, msg1)
      Mailbox.send_message(mailbox, msg2)

      assert_receive {:waiter1, {:ok, r1}}, 2000
      assert_receive {:waiter2, {:ok, r2}}, 2000
      assert r1.content == "for-waiter-1"
      assert r2.content == "for-waiter-2"

      # Cleanup — ensure spawned processes are done
      refute Process.alive?(waiter1)
      refute Process.alive?(waiter2)
    end
  end

  describe "peek/1" do
    test "returns messages without consuming", %{mailbox: mailbox} do
      msg = make_message("peek-me")
      :ok = Mailbox.send_message(mailbox, msg)

      assert [peeked] = Mailbox.peek(mailbox)
      assert peeked.content == "peek-me"

      # Still there after peek
      assert {:ok, received} = Mailbox.receive_message(mailbox)
      assert received.content == "peek-me"
    end

    test "returns empty list when no messages", %{mailbox: mailbox} do
      assert [] = Mailbox.peek(mailbox)
    end

    test "returns messages in FIFO order", %{mailbox: mailbox} do
      :ok = Mailbox.send_message(mailbox, make_message("a"))
      :ok = Mailbox.send_message(mailbox, make_message("b"))
      :ok = Mailbox.send_message(mailbox, make_message("c"))

      messages = Mailbox.peek(mailbox)
      assert length(messages) == 3
      assert Enum.map(messages, & &1.content) == ["a", "b", "c"]
    end
  end

  describe "count/1" do
    test "tracks queue size", %{mailbox: mailbox} do
      assert Mailbox.count(mailbox) == 0

      :ok = Mailbox.send_message(mailbox, make_message("1"))
      assert Mailbox.count(mailbox) == 1

      :ok = Mailbox.send_message(mailbox, make_message("2"))
      assert Mailbox.count(mailbox) == 2

      {:ok, _} = Mailbox.receive_message(mailbox)
      assert Mailbox.count(mailbox) == 1

      {:ok, _} = Mailbox.receive_message(mailbox)
      assert Mailbox.count(mailbox) == 0
    end
  end

  describe "subscribe/1" do
    test "subscriber gets :new_message notification", %{mailbox: mailbox} do
      :ok = Mailbox.subscribe(mailbox)

      msg = make_message("notify-me")
      :ok = Mailbox.send_message(mailbox, msg)

      assert_receive {:new_message, notification}
      assert notification.content == "notify-me"
      assert notification.id == msg.id
    end

    test "subscriber gets notifications for multiple messages", %{mailbox: mailbox} do
      :ok = Mailbox.subscribe(mailbox)

      :ok = Mailbox.send_message(mailbox, make_message("one"))
      :ok = Mailbox.send_message(mailbox, make_message("two"))

      assert_receive {:new_message, %{content: "one"}}
      assert_receive {:new_message, %{content: "two"}}
    end
  end

  describe "clear/1" do
    test "empties the queue", %{mailbox: mailbox} do
      :ok = Mailbox.send_message(mailbox, make_message("a"))
      :ok = Mailbox.send_message(mailbox, make_message("b"))
      assert Mailbox.count(mailbox) == 2

      :ok = Mailbox.clear(mailbox)
      assert Mailbox.count(mailbox) == 0
      assert :empty = Mailbox.receive_message(mailbox)
    end

    test "blocked waiters get :timeout on clear", %{mailbox: mailbox} do
      parent = self()

      spawn(fn ->
        result = Mailbox.receive_message(mailbox, 5000)
        send(parent, {:waiter_result, result})
      end)

      # Give waiter time to register
      Process.sleep(50)

      :ok = Mailbox.clear(mailbox)

      assert_receive {:waiter_result, :timeout}, 1000
    end
  end
end
