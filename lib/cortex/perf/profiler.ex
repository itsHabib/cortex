defmodule Cortex.Perf.Profiler do
  @moduledoc """
  Simple profiling utilities for measuring Cortex operations.

  Provides wrappers around `:timer.tc/1` for quick microbenchmarks and
  `:fprof` for detailed profiling. Use `measure/1` and `measure_ms/1`
  for inline timing of individual operations. Use `profile/2` for
  comprehensive call-graph profiling via `:fprof`.

  ## Examples

      # Quick timing
      {microseconds, result} = Cortex.Perf.Profiler.measure(fn ->
        Cortex.Orchestration.DAG.build_tiers(teams)
      end)

      # Millisecond timing
      {ms, result} = Cortex.Perf.Profiler.measure_ms(fn ->
        Cortex.Gossip.Protocol.exchange(store_a, store_b)
      end)

      # Full fprof profiling (writes to file)
      Cortex.Perf.Profiler.profile(fn -> expensive_operation() end,
        output: "tmp/profile.txt"
      )

  """

  @doc """
  Measures the execution time of a function in microseconds.

  Returns `{microseconds, result}` where `microseconds` is the wall-clock
  time taken and `result` is the return value of the function.

  ## Examples

      {us, {:ok, tiers}} = Profiler.measure(fn ->
        DAG.build_tiers(teams)
      end)

  """
  @spec measure(function()) :: {microseconds :: integer(), result :: term()}
  def measure(fun) when is_function(fun, 0) do
    :timer.tc(fun)
  end

  @doc """
  Measures the execution time of a function in milliseconds.

  Returns `{milliseconds, result}` where `milliseconds` is a float
  representing the wall-clock time taken.

  ## Examples

      {ms, :ok} = Profiler.measure_ms(fn ->
        Protocol.exchange(store_a, store_b)
      end)

  """
  @spec measure_ms(function()) :: {milliseconds :: float(), result :: term()}
  def measure_ms(fun) when is_function(fun, 0) do
    {us, result} = :timer.tc(fun)
    {us / 1_000.0, result}
  end

  @doc """
  Runs a function under `:fprof` and outputs profiling results.

  ## Options

    - `:output` -- file path for the profiling report (default: prints to stdout)
    - `:sort` -- sort column for the report (default: `:own`)

  ## Examples

      Profiler.profile(fn -> heavy_computation() end, output: "tmp/profile.txt")

  """
  @spec profile(function(), keyword()) :: :ok
  def profile(fun, opts \\ []) when is_function(fun, 0) do
    # Ensure the :tools application is loaded (provides :fprof)
    {:ok, _} = Application.ensure_all_started(:tools)

    output = Keyword.get(opts, :output)
    sort = Keyword.get(opts, :sort, :own)

    # Use apply/3 to avoid compile-time warnings about :fprof module availability.
    # :fprof is part of the :tools OTP application and may not be loaded at compile time.
    apply(:fprof, :apply, [fun, []])
    apply(:fprof, :profile, [])

    fprof_opts =
      case output do
        nil -> [{:sort, sort}]
        path -> [{:sort, sort}, {:dest, to_charlist(path)}]
      end

    apply(:fprof, :analyse, [fprof_opts])
    :ok
  end
end
