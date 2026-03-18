defmodule Cortex.Gateway.EventsTest do
  use ExUnit.Case, async: true

  alias Cortex.Gateway.Events

  describe "topic/0" do
    test "returns the gateway PubSub topic" do
      assert Events.topic() == "cortex:gateway"
    end
  end

  describe "subscribe/0 and broadcast/2" do
    test "subscriber receives broadcast event" do
      :ok = Events.subscribe()

      :ok = Events.broadcast(:agent_registered, %{agent_id: "test-1", name: "scanner"})

      assert_receive %{
        type: :agent_registered,
        payload: %{agent_id: "test-1", name: "scanner"},
        timestamp: %DateTime{}
      }
    end

    test "event has correct shape with type, payload, and timestamp" do
      :ok = Events.subscribe()

      :ok = Events.broadcast(:agent_heartbeat, %{agent_id: "test-1", status: :idle})

      assert_receive event
      assert Map.has_key?(event, :type)
      assert Map.has_key?(event, :payload)
      assert Map.has_key?(event, :timestamp)
      assert is_atom(event.type)
      assert is_map(event.payload)
      assert %DateTime{} = event.timestamp
    end

    test "broadcast with default empty payload" do
      :ok = Events.subscribe()

      :ok = Events.broadcast(:agent_unregistered)

      assert_receive %{type: :agent_unregistered, payload: %{}}
    end
  end

  describe "broadcast/2 with all event types" do
    setup do
      :ok = Events.subscribe()
      :ok
    end

    test "broadcasts agent_registered" do
      :ok = Events.broadcast(:agent_registered, %{agent_id: "a1", name: "w1"})
      assert_receive %{type: :agent_registered}
    end

    test "broadcasts agent_unregistered" do
      :ok = Events.broadcast(:agent_unregistered, %{agent_id: "a1", reason: :disconnect})
      assert_receive %{type: :agent_unregistered}
    end

    test "broadcasts agent_heartbeat" do
      :ok = Events.broadcast(:agent_heartbeat, %{agent_id: "a1", status: :idle})
      assert_receive %{type: :agent_heartbeat}
    end

    test "broadcasts agent_status_changed" do
      :ok =
        Events.broadcast(:agent_status_changed, %{
          agent_id: "a1",
          old_status: :idle,
          new_status: :working
        })

      assert_receive %{type: :agent_status_changed}
    end

    test "broadcasts task_dispatched" do
      :ok = Events.broadcast(:task_dispatched, %{task_id: "t1", agent_id: "a1"})
      assert_receive %{type: :task_dispatched}
    end

    test "broadcasts task_completed" do
      :ok = Events.broadcast(:task_completed, %{task_id: "t1", agent_id: "a1", status: :ok})
      assert_receive %{type: :task_completed}
    end
  end
end
