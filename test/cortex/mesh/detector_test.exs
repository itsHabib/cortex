defmodule Cortex.Mesh.DetectorTest do
  use ExUnit.Case, async: false

  alias Cortex.Mesh.{Detector, Member, MemberList}

  setup do
    {:ok, ml_pid} = MemberList.start_link(cluster_name: "detector-test")
    %{ml_pid: ml_pid}
  end

  describe "heartbeat detection" do
    test "marks member with invalid os_pid as suspect", %{ml_pid: ml_pid} do
      member = %Member{
        id: "agent-a",
        name: "agent-a",
        role: "researcher",
        prompt: "do it",
        os_pid: 999_999_999
      }

      MemberList.register(ml_pid, member)

      # Start detector with a very fast heartbeat
      {:ok, _det_pid} =
        Detector.start_link(
          member_list: ml_pid,
          heartbeat_interval_ms: 50,
          suspect_timeout_ms: 5_000,
          dead_timeout_ms: 10_000
        )

      # Wait for a heartbeat cycle
      Process.sleep(150)

      updated = MemberList.get_member(ml_pid, "agent-a")
      assert updated.state == :suspect
    end

    test "promotes suspect to dead after timeout", %{ml_pid: ml_pid} do
      member = %Member{
        id: "agent-a",
        name: "agent-a",
        role: "researcher",
        prompt: "do it",
        os_pid: 999_999_999
      }

      MemberList.register(ml_pid, member)

      {:ok, _det_pid} =
        Detector.start_link(
          member_list: ml_pid,
          heartbeat_interval_ms: 50,
          suspect_timeout_ms: 100,
          dead_timeout_ms: 10_000
        )

      # Wait for heartbeat + suspect timeout
      Process.sleep(300)

      updated = MemberList.get_member(ml_pid, "agent-a")
      assert updated.state == :dead
    end

    test "keeps alive member with nil os_pid as suspect", %{ml_pid: ml_pid} do
      member = %Member{
        id: "agent-b",
        name: "agent-b",
        role: "analyst",
        prompt: "analyze",
        os_pid: nil
      }

      MemberList.register(ml_pid, member)

      {:ok, _det_pid} =
        Detector.start_link(
          member_list: ml_pid,
          heartbeat_interval_ms: 50,
          suspect_timeout_ms: 5_000,
          dead_timeout_ms: 10_000
        )

      Process.sleep(150)

      updated = MemberList.get_member(ml_pid, "agent-b")
      assert updated.state == :suspect
    end
  end
end
