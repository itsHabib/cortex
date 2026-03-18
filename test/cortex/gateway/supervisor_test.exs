defmodule Cortex.Gateway.SupervisorTest do
  use ExUnit.Case, async: false

  alias Cortex.Gateway

  describe "Gateway.Supervisor" do
    test "is alive after application boot" do
      pid = Process.whereis(Gateway.Supervisor)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "Gateway.Registry child is alive" do
      pid = Process.whereis(Gateway.Registry)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "Gateway.Health child is alive" do
      pid = Process.whereis(Gateway.Health)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "killing Registry child causes it to be restarted" do
      old_pid = Process.whereis(Gateway.Registry)
      assert old_pid != nil

      Process.exit(old_pid, :kill)

      # Give the supervisor time to restart the child
      Process.sleep(100)

      new_pid = Process.whereis(Gateway.Registry)
      assert new_pid != nil
      assert Process.alive?(new_pid)
      assert new_pid != old_pid
    end

    test "killing Health child causes it to be restarted" do
      old_pid = Process.whereis(Gateway.Health)
      assert old_pid != nil

      Process.exit(old_pid, :kill)

      Process.sleep(100)

      new_pid = Process.whereis(Gateway.Health)
      assert new_pid != nil
      assert Process.alive?(new_pid)
      assert new_pid != old_pid
    end
  end
end
