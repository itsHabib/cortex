defmodule Cortex.Perf.ProfilerTest do
  use ExUnit.Case, async: true

  alias Cortex.Perf.Profiler

  describe "measure/1" do
    test "returns {microseconds, result}" do
      {us, result} = Profiler.measure(fn -> 1 + 1 end)

      assert is_integer(us)
      assert us >= 0
      assert result == 2
    end

    test "measures time for a slow operation" do
      {us, _result} = Profiler.measure(fn -> Process.sleep(10) end)

      # Should be at least 10ms = 10_000us (with some tolerance)
      assert us >= 5_000
    end
  end

  describe "measure_ms/1" do
    test "returns {milliseconds, result}" do
      {ms, result} = Profiler.measure_ms(fn -> 1 + 1 end)

      assert is_float(ms)
      assert ms >= 0.0
      assert result == 2
    end

    test "measures time in milliseconds" do
      {ms, _result} = Profiler.measure_ms(fn -> Process.sleep(10) end)

      # Should be at least ~10ms
      assert ms >= 5.0
    end
  end
end
