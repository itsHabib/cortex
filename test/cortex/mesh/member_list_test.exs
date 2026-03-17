defmodule Cortex.Mesh.MemberListTest do
  use ExUnit.Case, async: false

  alias Cortex.Mesh.{Member, MemberList}

  setup do
    {:ok, pid} = MemberList.start_link(cluster_name: "test-cluster", run_id: "test-run")
    %{pid: pid}
  end

  defp make_member(name, role \\ "researcher") do
    %Member{
      id: name,
      name: name,
      role: role,
      prompt: "Do #{name} things."
    }
  end

  describe "register/2" do
    test "registers a new member", %{pid: pid} do
      member = make_member("agent-a")
      assert :ok = MemberList.register(pid, member)
    end

    test "sets started_at and last_seen on register", %{pid: pid} do
      member = make_member("agent-a")
      MemberList.register(pid, member)
      retrieved = MemberList.get_member(pid, "agent-a")
      assert %DateTime{} = retrieved.started_at
      assert %DateTime{} = retrieved.last_seen
    end

    test "rejects duplicate registration", %{pid: pid} do
      member = make_member("agent-a")
      assert :ok = MemberList.register(pid, member)
      assert {:error, :already_registered} = MemberList.register(pid, member)
    end

    test "broadcasts :member_joined event", %{pid: pid} do
      Cortex.Events.subscribe()
      MemberList.register(pid, make_member("agent-a"))

      assert_receive %{type: :member_joined, payload: %{name: "agent-a"}}, 1000
    end
  end

  describe "transitions" do
    setup %{pid: pid} do
      MemberList.register(pid, make_member("agent-a"))
      :ok
    end

    test "mark_suspect transitions alive → suspect", %{pid: pid} do
      assert :ok = MemberList.mark_suspect(pid, "agent-a")
      member = MemberList.get_member(pid, "agent-a")
      assert member.state == :suspect
    end

    test "mark_dead transitions alive → dead", %{pid: pid} do
      assert :ok = MemberList.mark_dead(pid, "agent-a")
      member = MemberList.get_member(pid, "agent-a")
      assert member.state == :dead
      assert %DateTime{} = member.died_at
    end

    test "mark_left transitions alive → left", %{pid: pid} do
      assert :ok = MemberList.mark_left(pid, "agent-a")
      member = MemberList.get_member(pid, "agent-a")
      assert member.state == :left
    end

    test "mark_alive refutes suspicion (suspect → alive)", %{pid: pid} do
      MemberList.mark_suspect(pid, "agent-a")
      assert :ok = MemberList.mark_alive(pid, "agent-a")
      member = MemberList.get_member(pid, "agent-a")
      assert member.state == :alive
      assert member.incarnation == 1
    end

    test "cannot transition from dead", %{pid: pid} do
      MemberList.mark_dead(pid, "agent-a")
      assert {:error, _} = MemberList.mark_alive(pid, "agent-a")
      assert {:error, _} = MemberList.mark_suspect(pid, "agent-a")
    end

    test "cannot transition from left", %{pid: pid} do
      MemberList.mark_left(pid, "agent-a")
      assert {:error, _} = MemberList.mark_alive(pid, "agent-a")
    end

    test "returns error for unknown member", %{pid: pid} do
      assert {:error, :not_found} = MemberList.mark_suspect(pid, "unknown")
    end

    test "broadcasts transition events", %{pid: pid} do
      Cortex.Events.subscribe()

      MemberList.mark_suspect(pid, "agent-a")
      assert_receive %{type: :member_suspect, payload: %{name: "agent-a"}}, 1000

      MemberList.mark_alive(pid, "agent-a")
      assert_receive %{type: :member_alive, payload: %{name: "agent-a"}}, 1000

      MemberList.mark_dead(pid, "agent-a")
      assert_receive %{type: :member_dead, payload: %{name: "agent-a"}}, 1000
    end
  end

  describe "queries" do
    setup %{pid: pid} do
      MemberList.register(pid, make_member("agent-a", "researcher"))
      MemberList.register(pid, make_member("agent-b", "analyst"))
      MemberList.register(pid, make_member("agent-c", "writer"))
      MemberList.mark_suspect(pid, "agent-b")
      MemberList.mark_dead(pid, "agent-c")
      :ok
    end

    test "get_member returns the member", %{pid: pid} do
      member = MemberList.get_member(pid, "agent-a")
      assert member.name == "agent-a"
    end

    test "get_member returns nil for unknown", %{pid: pid} do
      assert MemberList.get_member(pid, "unknown") == nil
    end

    test "alive_members returns only alive", %{pid: pid} do
      alive = MemberList.alive_members(pid)
      names = Enum.map(alive, & &1.name)
      assert "agent-a" in names
      refute "agent-b" in names
      refute "agent-c" in names
    end

    test "active_members returns alive and suspect", %{pid: pid} do
      active = MemberList.active_members(pid)
      names = Enum.map(active, & &1.name)
      assert "agent-a" in names
      assert "agent-b" in names
      refute "agent-c" in names
    end

    test "all_members returns all", %{pid: pid} do
      all = MemberList.all_members(pid)
      assert length(all) == 3
    end

    test "roster returns sorted summary", %{pid: pid} do
      roster = MemberList.roster(pid)
      assert length(roster) == 3
      [first | _] = roster
      assert Map.has_key?(first, :name)
      assert Map.has_key?(first, :role)
      assert Map.has_key?(first, :state)
    end
  end

  describe "update_member/3" do
    test "updates arbitrary fields", %{pid: pid} do
      MemberList.register(pid, make_member("agent-a"))
      assert :ok = MemberList.update_member(pid, "agent-a", %{os_pid: 12_345})
      member = MemberList.get_member(pid, "agent-a")
      assert member.os_pid == 12_345
    end

    test "returns error for unknown member", %{pid: pid} do
      assert {:error, :not_found} = MemberList.update_member(pid, "unknown", %{os_pid: 1})
    end
  end
end
