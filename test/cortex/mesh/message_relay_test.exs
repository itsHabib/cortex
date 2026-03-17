defmodule Cortex.Mesh.MessageRelayTest do
  use ExUnit.Case, async: false

  alias Cortex.Mesh.MessageRelay
  alias Cortex.Messaging.InboxBridge

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "mesh_relay_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    agent_names = ["agent-a", "agent-b"]
    InboxBridge.setup(tmp_dir, agent_names)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir, agent_names: agent_names}
  end

  describe "message relay" do
    test "relays messages from outbox to inbox", %{tmp_dir: tmp_dir, agent_names: agent_names} do
      # Write a message in agent-a's outbox addressed to agent-b
      outbox_path = InboxBridge.outbox_path(tmp_dir, "agent-a")

      message = %{
        "to" => "agent-b",
        "from" => "agent-a",
        "content" => "Hello from A!",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      File.write!(outbox_path, Jason.encode!([message], pretty: true))

      # Start relay with fast polling
      {:ok, relay_pid} =
        MessageRelay.start(
          workspace_path: tmp_dir,
          run_id: "test-run",
          agent_names: agent_names,
          poll_interval_ms: 50
        )

      # Wait for relay to poll
      Process.sleep(150)

      # Check agent-b's inbox
      {:ok, inbox} = InboxBridge.read_inbox(tmp_dir, "agent-b")
      assert inbox != []

      delivered = List.last(inbox)
      assert delivered["from"] == "agent-a"
      assert delivered["content"] == "Hello from A!"
      assert delivered["type"] == "mesh_message"

      GenServer.stop(relay_pid)
    end

    test "does not relay messages to self", %{tmp_dir: tmp_dir, agent_names: agent_names} do
      outbox_path = InboxBridge.outbox_path(tmp_dir, "agent-a")

      message = %{
        "to" => "agent-a",
        "from" => "agent-a",
        "content" => "Self message"
      }

      File.write!(outbox_path, Jason.encode!([message], pretty: true))

      {:ok, relay_pid} =
        MessageRelay.start(
          workspace_path: tmp_dir,
          run_id: "test-run",
          agent_names: agent_names,
          poll_interval_ms: 50
        )

      Process.sleep(150)

      # agent-a's inbox should still be empty (only the initial empty array)
      {:ok, inbox} = InboxBridge.read_inbox(tmp_dir, "agent-a")
      assert inbox == []

      GenServer.stop(relay_pid)
    end

    test "broadcasts :team_progress events", %{tmp_dir: tmp_dir, agent_names: agent_names} do
      Cortex.Events.subscribe()

      outbox_path = InboxBridge.outbox_path(tmp_dir, "agent-a")

      message = %{
        "to" => "agent-b",
        "from" => "agent-a",
        "content" => "Progress update"
      }

      File.write!(outbox_path, Jason.encode!([message], pretty: true))

      {:ok, relay_pid} =
        MessageRelay.start(
          workspace_path: tmp_dir,
          run_id: "test-run",
          agent_names: agent_names,
          poll_interval_ms: 50
        )

      assert_receive %{type: :team_progress, payload: %{team_name: "agent-a"}}, 1000

      GenServer.stop(relay_pid)
    end

    test "ignores messages to unknown agents", %{tmp_dir: tmp_dir, agent_names: agent_names} do
      outbox_path = InboxBridge.outbox_path(tmp_dir, "agent-a")

      message = %{
        "to" => "unknown-agent",
        "from" => "agent-a",
        "content" => "Hello?"
      }

      File.write!(outbox_path, Jason.encode!([message], pretty: true))

      {:ok, relay_pid} =
        MessageRelay.start(
          workspace_path: tmp_dir,
          run_id: "test-run",
          agent_names: agent_names,
          poll_interval_ms: 50
        )

      Process.sleep(150)

      # No crash, relay is still alive
      assert Process.alive?(relay_pid)

      GenServer.stop(relay_pid)
    end
  end
end
