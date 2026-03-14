defmodule Cortex.Messaging.IntegrationTest do
  use ExUnit.Case, async: false

  alias Cortex.Messaging.AgentIntegration
  alias Cortex.Messaging.Bus

  # Full integration tests that exercise the entire messaging stack.
  # async: false because they use the global Router and MailboxRegistry.

  defp unique_id(prefix) do
    "#{prefix}-#{Uniq.UUID.uuid4()}"
  end

  describe "full flow: 3 agents" do
    setup do
      a = unique_id("int-a")
      b = unique_id("int-b")
      c = unique_id("int-c")

      :ok = AgentIntegration.setup(a)
      :ok = AgentIntegration.setup(b)
      :ok = AgentIntegration.setup(c)

      on_exit(fn ->
        AgentIntegration.teardown(a)
        AgentIntegration.teardown(b)
        AgentIntegration.teardown(c)
      end)

      %{a: a, b: b, c: c}
    end

    test "A sends to B, B receives, B sends result to C, C receives", %{a: a, b: b, c: c} do
      # A sends work to B
      {:ok, _} = Bus.send_message(a, b, %{task: "compute"}, type: :request)

      # B receives the request
      assert {:ok, request} = Bus.receive_message(b)
      assert request.content == %{task: "compute"}
      assert request.type == :request
      assert request.from == a

      # B sends the result to C
      {:ok, _} = Bus.send_message(b, c, %{result: 42}, type: :result)

      # C receives the result
      assert {:ok, result} = Bus.receive_message(c)
      assert result.content == %{result: 42}
      assert result.type == :result
      assert result.from == b
    end

    test "broadcast: A broadcasts, B and C both receive", %{a: a, b: b, c: c} do
      {:ok, _} = Bus.broadcast(a, "status-update")

      # Give broadcast time to deliver
      Process.sleep(20)

      # B and C both get it
      assert {:ok, rb} = Bus.receive_message(b)
      assert rb.content == "status-update"
      assert rb.from == a

      assert {:ok, rc} = Bus.receive_message(c)
      assert rc.content == "status-update"
      assert rc.from == a

      # A also gets it (broadcast goes to all)
      assert {:ok, ra} = Bus.receive_message(a)
      assert ra.content == "status-update"
    end
  end

  describe "message ordering" do
    setup do
      sender = unique_id("ord-sender")
      receiver = unique_id("ord-receiver")

      :ok = AgentIntegration.setup(sender)
      :ok = AgentIntegration.setup(receiver)

      on_exit(fn ->
        AgentIntegration.teardown(sender)
        AgentIntegration.teardown(receiver)
      end)

      %{sender: sender, receiver: receiver}
    end

    test "5 messages received in FIFO order", %{sender: sender, receiver: receiver} do
      for i <- 1..5 do
        {:ok, _} = Bus.send_message(sender, receiver, "msg-#{i}")
      end

      # Give casts time
      Process.sleep(30)

      for i <- 1..5 do
        assert {:ok, msg} = Bus.receive_message(receiver)
        assert msg.content == "msg-#{i}"
      end

      assert :empty = Bus.receive_message(receiver)
    end
  end

  describe "concurrent messaging" do
    test "5 agents all sending to each other simultaneously" do
      agents =
        for i <- 1..5 do
          id = unique_id("conc-#{i}")
          :ok = AgentIntegration.setup(id)
          id
        end

      on_exit_teardown =
        fn ->
          Enum.each(agents, &AgentIntegration.teardown/1)
        end

      on_exit(fn -> on_exit_teardown.() end)

      # Each agent sends one message to every other agent
      tasks =
        for sender <- agents, receiver <- agents, sender != receiver do
          Task.async(fn ->
            Bus.send_message(sender, receiver, "from-#{sender}-to-#{receiver}")
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All sends should succeed
      for result <- results do
        assert {:ok, _msg} = result
      end

      # Give casts time to deliver
      Process.sleep(50)

      # Each agent should have received exactly 4 messages (one from each other agent)
      for agent <- agents do
        inbox = Bus.inbox(agent)
        assert length(inbox) == 4, "Agent #{agent} has #{length(inbox)} messages, expected 4"

        # Verify all messages are from different senders
        senders = Enum.map(inbox, & &1.from) |> Enum.sort()
        expected_senders = (agents -- [agent]) |> Enum.sort()
        assert senders == expected_senders
      end
    end
  end

  describe "teardown" do
    test "messages cannot be sent after teardown" do
      a = unique_id("td-a")
      b = unique_id("td-b")

      :ok = AgentIntegration.setup(a)
      :ok = AgentIntegration.setup(b)

      # Verify messaging works before teardown
      {:ok, _} = Bus.send_message(a, b, "before-teardown")
      Process.sleep(10)
      assert {:ok, _} = Bus.receive_message(b)

      # Teardown B
      :ok = AgentIntegration.teardown(b)

      # Sending to B should now fail
      assert {:error, :not_found} = Bus.send_message(a, b, "after-teardown")

      # Cleanup
      AgentIntegration.teardown(a)
    end
  end
end
