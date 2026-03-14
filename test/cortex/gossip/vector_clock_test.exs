defmodule Cortex.Gossip.VectorClockTest do
  use ExUnit.Case, async: true

  alias Cortex.Gossip.VectorClock

  describe "new/0" do
    test "returns an empty map" do
      assert VectorClock.new() == %{}
    end
  end

  describe "increment/2" do
    test "increments a new node to 1" do
      vc = VectorClock.new()
      assert VectorClock.increment(vc, "agent_a") == %{"agent_a" => 1}
    end

    test "increments an existing node" do
      vc = %{"agent_a" => 2}
      assert VectorClock.increment(vc, "agent_a") == %{"agent_a" => 3}
    end

    test "increments only the specified node" do
      vc = %{"agent_a" => 1, "agent_b" => 2}
      result = VectorClock.increment(vc, "agent_a")
      assert result == %{"agent_a" => 2, "agent_b" => 2}
    end

    test "adding a new node preserves existing nodes" do
      vc = %{"agent_a" => 3}
      result = VectorClock.increment(vc, "agent_b")
      assert result == %{"agent_a" => 3, "agent_b" => 1}
    end
  end

  describe "merge/2" do
    test "merging two empty clocks returns empty" do
      assert VectorClock.merge(%{}, %{}) == %{}
    end

    test "merging with an empty clock returns the other" do
      vc = %{"a" => 2, "b" => 1}
      assert VectorClock.merge(vc, %{}) == vc
      assert VectorClock.merge(%{}, vc) == vc
    end

    test "takes element-wise maximum" do
      vc_a = %{"a" => 2, "b" => 1}
      vc_b = %{"a" => 1, "b" => 3}
      assert VectorClock.merge(vc_a, vc_b) == %{"a" => 2, "b" => 3}
    end

    test "includes nodes only in one clock" do
      vc_a = %{"a" => 2}
      vc_b = %{"b" => 3}
      assert VectorClock.merge(vc_a, vc_b) == %{"a" => 2, "b" => 3}
    end

    test "merging identical clocks returns the same clock" do
      vc = %{"a" => 1, "b" => 2}
      assert VectorClock.merge(vc, vc) == vc
    end
  end

  describe "compare/2" do
    test "equal clocks" do
      vc = %{"a" => 1, "b" => 2}
      assert VectorClock.compare(vc, vc) == :equal
    end

    test "two empty clocks are equal" do
      assert VectorClock.compare(%{}, %{}) == :equal
    end

    test "before — vc_a happened before vc_b" do
      vc_a = %{"a" => 1}
      vc_b = %{"a" => 2}
      assert VectorClock.compare(vc_a, vc_b) == :before
    end

    test "after — vc_a happened after vc_b" do
      vc_a = %{"a" => 3}
      vc_b = %{"a" => 1}
      assert VectorClock.compare(vc_a, vc_b) == :after
    end

    test "before — vc_b has a superset of nodes" do
      vc_a = %{"a" => 1}
      vc_b = %{"a" => 1, "b" => 1}
      assert VectorClock.compare(vc_a, vc_b) == :before
    end

    test "after — vc_a has a superset of nodes" do
      vc_a = %{"a" => 1, "b" => 1}
      vc_b = %{"a" => 1}
      assert VectorClock.compare(vc_a, vc_b) == :after
    end

    test "concurrent — neither dominates" do
      vc_a = %{"a" => 2, "b" => 1}
      vc_b = %{"a" => 1, "b" => 2}
      assert VectorClock.compare(vc_a, vc_b) == :concurrent
    end

    test "concurrent — disjoint nodes" do
      vc_a = %{"a" => 1}
      vc_b = %{"b" => 1}
      assert VectorClock.compare(vc_a, vc_b) == :concurrent
    end
  end

  describe "dominates?/2" do
    test "empty clock does not dominate empty clock" do
      refute VectorClock.dominates?(%{}, %{})
    end

    test "non-empty dominates empty" do
      assert VectorClock.dominates?(%{"a" => 1}, %{})
    end

    test "empty does not dominate non-empty" do
      refute VectorClock.dominates?(%{}, %{"a" => 1})
    end

    test "strictly greater dominates" do
      assert VectorClock.dominates?(%{"a" => 3}, %{"a" => 1})
    end

    test "equal does not dominate" do
      refute VectorClock.dominates?(%{"a" => 1}, %{"a" => 1})
    end

    test "superset with equal values dominates" do
      assert VectorClock.dominates?(%{"a" => 1, "b" => 1}, %{"a" => 1})
    end

    test "concurrent clocks — neither dominates" do
      refute VectorClock.dominates?(%{"a" => 2, "b" => 1}, %{"a" => 1, "b" => 2})
      refute VectorClock.dominates?(%{"a" => 1, "b" => 2}, %{"a" => 2, "b" => 1})
    end

    test "missing node means 0 — vc_a missing a node that vc_b has" do
      refute VectorClock.dominates?(%{"a" => 5}, %{"a" => 1, "b" => 1})
    end
  end
end
