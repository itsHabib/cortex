defmodule Cortex.Test.Eventually do
  @moduledoc """
  Polling assertion helper for timing-sensitive tests.

  `assert_eventually/3` retries an assertion function until it passes
  or the timeout expires, checking every `interval_ms` milliseconds.
  Use this instead of `Process.sleep/1` in tests that wait for a
  GenServer (Health, Detector, etc.) to process a tick.

  ## Example

      import Cortex.Test.Eventually

      assert_eventually(fn ->
        {:ok, agent} = Registry.get(reg, agent.id)
        assert agent.status == :disconnected
      end)
  """

  @doc """
  Polls `fun` until it returns without raising, or raises after `timeout_ms`.
  """
  @spec assert_eventually((-> any()), pos_integer(), pos_integer()) :: :ok
  def assert_eventually(fun, timeout_ms \\ 2_000, interval_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(fun, deadline, interval_ms)
  end

  defp poll(fun, deadline, interval_ms) do
    fun.()
    :ok
  rescue
    _ ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(interval_ms)
        poll(fun, deadline, interval_ms)
      else
        fun.()
      end
  end
end
