defmodule Cortex.Mesh.MemberTest do
  use ExUnit.Case, async: true

  alias Cortex.Mesh.Member

  @valid_attrs %{id: "agent-a", name: "agent-a", role: "researcher", prompt: "Do research."}

  describe "struct" do
    test "creates with required fields" do
      member = struct!(Member, @valid_attrs)
      assert member.id == "agent-a"
      assert member.name == "agent-a"
      assert member.role == "researcher"
      assert member.prompt == "Do research."
    end

    test "defaults" do
      member = struct!(Member, @valid_attrs)
      assert member.state == :alive
      assert member.incarnation == 0
      assert member.metadata == %{}
      assert member.port == nil
      assert member.os_pid == nil
      assert member.session_id == nil
      assert member.log_path == nil
      assert member.started_at == nil
      assert member.last_seen == nil
      assert member.died_at == nil
    end
  end

  describe "alive?/1" do
    test "true when alive" do
      member = struct!(Member, @valid_attrs)
      assert Member.alive?(member)
    end

    test "false when suspect" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :suspect))
      refute Member.alive?(member)
    end

    test "false when dead" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :dead))
      refute Member.alive?(member)
    end

    test "false when left" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :left))
      refute Member.alive?(member)
    end
  end

  describe "active?/1" do
    test "true when alive" do
      member = struct!(Member, @valid_attrs)
      assert Member.active?(member)
    end

    test "true when suspect" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :suspect))
      assert Member.active?(member)
    end

    test "false when dead" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :dead))
      refute Member.active?(member)
    end

    test "false when left" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :left))
      refute Member.active?(member)
    end
  end

  describe "bump_incarnation/1" do
    test "increments incarnation counter" do
      member = struct!(Member, @valid_attrs)
      assert member.incarnation == 0
      bumped = Member.bump_incarnation(member)
      assert bumped.incarnation == 1
      bumped2 = Member.bump_incarnation(bumped)
      assert bumped2.incarnation == 2
    end
  end

  describe "transition/2" do
    test "alive → suspect" do
      member = struct!(Member, @valid_attrs)
      assert {:ok, updated} = Member.transition(member, :suspect)
      assert updated.state == :suspect
    end

    test "alive → dead" do
      member = struct!(Member, @valid_attrs)
      assert {:ok, updated} = Member.transition(member, :dead)
      assert updated.state == :dead
      assert %DateTime{} = updated.died_at
    end

    test "alive → left" do
      member = struct!(Member, @valid_attrs)
      assert {:ok, updated} = Member.transition(member, :left)
      assert updated.state == :left
      assert %DateTime{} = updated.died_at
    end

    test "alive → alive is error" do
      member = struct!(Member, @valid_attrs)
      assert {:error, _} = Member.transition(member, :alive)
    end

    test "suspect → alive (refuted)" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :suspect))
      assert {:ok, updated} = Member.transition(member, :alive)
      assert updated.state == :alive
      assert updated.incarnation == 1
      assert %DateTime{} = updated.last_seen
    end

    test "suspect → dead" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :suspect))
      assert {:ok, updated} = Member.transition(member, :dead)
      assert updated.state == :dead
      assert %DateTime{} = updated.died_at
    end

    test "suspect → left" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :suspect))
      assert {:ok, updated} = Member.transition(member, :left)
      assert updated.state == :left
    end

    test "dead → anything is error" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :dead))
      assert {:error, "cannot transition from :dead"} = Member.transition(member, :alive)
      assert {:error, "cannot transition from :dead"} = Member.transition(member, :suspect)
      assert {:error, "cannot transition from :dead"} = Member.transition(member, :left)
    end

    test "left → anything is error" do
      member = struct!(Member, Map.put(@valid_attrs, :state, :left))
      assert {:error, "cannot transition from :left"} = Member.transition(member, :alive)
      assert {:error, "cannot transition from :left"} = Member.transition(member, :suspect)
      assert {:error, "cannot transition from :left"} = Member.transition(member, :dead)
    end
  end
end
