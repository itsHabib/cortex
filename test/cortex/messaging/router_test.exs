defmodule Cortex.Messaging.RouterTest do
  use ExUnit.Case, async: true

  alias Cortex.Messaging.Mailbox
  alias Cortex.Messaging.Message
  alias Cortex.Messaging.Router

  setup do
    {:ok, router} = Router.start_link()
    %{router: router}
  end

  defp start_mailbox(owner) do
    {:ok, pid} = Mailbox.start_link(owner: owner)
    pid
  end

  describe "register/3 and unregister/2" do
    test "register and list agents", %{router: router} do
      mb1 = start_mailbox("agent-1")
      mb2 = start_mailbox("agent-2")

      :ok = Router.register(router, "agent-1", mb1)
      :ok = Router.register(router, "agent-2", mb2)

      agents = Router.list_agents(router)
      assert "agent-1" in agents
      assert "agent-2" in agents
      assert length(agents) == 2
    end

    test "unregister removes agent from list", %{router: router} do
      mb = start_mailbox("agent-x")
      :ok = Router.register(router, "agent-x", mb)
      assert "agent-x" in Router.list_agents(router)

      :ok = Router.unregister(router, "agent-x")
      refute "agent-x" in Router.list_agents(router)
    end

    test "unregister is idempotent", %{router: router} do
      :ok = Router.unregister(router, "nonexistent")
      assert Router.list_agents(router) == []
    end
  end

  describe "send/2 (point-to-point)" do
    test "delivers message to registered agent", %{router: router} do
      mb = start_mailbox("agent-b")
      :ok = Router.register(router, "agent-b", mb)

      msg = Message.new(%{from: "agent-a", to: "agent-b", content: "hello"})
      assert :ok = Router.send(router, msg)

      assert {:ok, received} = Mailbox.receive_message(mb)
      assert received.content == "hello"
      assert received.id == msg.id
    end

    test "returns {:error, :not_found} for unregistered agent", %{router: router} do
      msg = Message.new(%{from: "a", to: "nobody", content: "lost"})
      assert {:error, :not_found} = Router.send(router, msg)
    end

    test "send with :broadcast to field calls broadcast path", %{router: router} do
      mb1 = start_mailbox("b1")
      mb2 = start_mailbox("b2")
      :ok = Router.register(router, "b1", mb1)
      :ok = Router.register(router, "b2", mb2)

      msg = Message.new(%{from: "sender", to: :broadcast, content: "to-all"})
      assert :ok = Router.send(router, msg)

      assert {:ok, r1} = Mailbox.receive_message(mb1)
      assert {:ok, r2} = Mailbox.receive_message(mb2)
      assert r1.content == "to-all"
      assert r2.content == "to-all"
    end
  end

  describe "broadcast/2" do
    test "delivers to all registered mailboxes", %{router: router} do
      mb1 = start_mailbox("c1")
      mb2 = start_mailbox("c2")
      mb3 = start_mailbox("c3")
      :ok = Router.register(router, "c1", mb1)
      :ok = Router.register(router, "c2", mb2)
      :ok = Router.register(router, "c3", mb3)

      msg = Message.new(%{from: "announcer", to: :broadcast, content: "broadcast-msg"})
      assert :ok = Router.broadcast(router, msg)

      for mb <- [mb1, mb2, mb3] do
        assert {:ok, received} = Mailbox.receive_message(mb)
        assert received.content == "broadcast-msg"
      end
    end

    test "broadcast with no agents succeeds", %{router: router} do
      msg = Message.new(%{from: "a", to: :broadcast, content: "echo"})
      assert :ok = Router.broadcast(router, msg)
    end
  end

  describe "list_agents/1" do
    test "returns empty list initially", %{router: router} do
      assert Router.list_agents(router) == []
    end

    test "reflects registrations and unregistrations", %{router: router} do
      mb = start_mailbox("d1")
      :ok = Router.register(router, "d1", mb)
      assert Router.list_agents(router) == ["d1"]

      :ok = Router.unregister(router, "d1")
      assert Router.list_agents(router) == []
    end
  end

  describe "auto-cleanup on mailbox crash" do
    test "unregisters agent when mailbox process dies", %{router: router} do
      # Trap exits so killing the linked mailbox doesn't crash the test
      Process.flag(:trap_exit, true)

      mb = start_mailbox("dying-agent")
      :ok = Router.register(router, "dying-agent", mb)
      assert "dying-agent" in Router.list_agents(router)

      # Kill the mailbox
      Process.exit(mb, :kill)
      assert_receive {:EXIT, ^mb, :killed}
      # Give the router time to handle the :DOWN message
      Process.sleep(50)

      refute "dying-agent" in Router.list_agents(router)
    end
  end
end
