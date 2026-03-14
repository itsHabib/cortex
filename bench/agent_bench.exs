# Agent benchmark suite
#
# Measures agent lifecycle operations: start/stop, concurrent creation,
# and state query latency.
#
# Run: mix run bench/agent_bench.exs

alias Cortex.Agent.Config
alias Cortex.Agent.Server

defmodule AgentBenchHelper do
  @moduledoc false

  def make_config(i) do
    Config.new!(%{name: "bench-agent-#{i}", role: "benchmark worker #{i}"})
  end

  def start_and_stop_agent(config) do
    {:ok, pid} = Server.start_link(config)
    {:ok, state} = Server.get_state(state_id(pid))
    Server.stop(state.id)
  end

  def state_id(pid) do
    {:ok, state} = Server.get_state_by_pid(pid)
    state.id
  rescue
    _ ->
      # Fallback: query via GenServer call directly
      {:ok, state} = GenServer.call(pid, :get_state)
      state.id
  end
end

# Pre-build configs to exclude config creation from benchmarks
config_1 = Config.new!(%{name: "bench-single", role: "benchmark worker"})

configs_10 = Enum.map(1..10, &AgentBenchHelper.make_config/1)
configs_50 = Enum.map(1..50, &AgentBenchHelper.make_config/1)
configs_100 = Enum.map(1..100, &AgentBenchHelper.make_config/1)

Benchee.run(
  %{
    "agent start/stop cycle" => fn ->
      {:ok, pid} = Server.start_link(config_1)
      {:ok, state} = GenServer.call(pid, :get_state)
      Server.stop(state.id)
    end,
    "concurrent agent creation (10)" => fn ->
      pids =
        Enum.map(configs_10, fn config ->
          {:ok, pid} = Server.start_link(config)
          pid
        end)

      Enum.each(pids, fn pid ->
        {:ok, state} = GenServer.call(pid, :get_state)
        Server.stop(state.id)
      end)
    end,
    "concurrent agent creation (50)" => fn ->
      pids =
        Enum.map(configs_50, fn config ->
          {:ok, pid} = Server.start_link(config)
          pid
        end)

      Enum.each(pids, fn pid ->
        {:ok, state} = GenServer.call(pid, :get_state)
        Server.stop(state.id)
      end)
    end,
    "concurrent agent creation (100)" => fn ->
      pids =
        Enum.map(configs_100, fn config ->
          {:ok, pid} = Server.start_link(config)
          pid
        end)

      Enum.each(pids, fn pid ->
        {:ok, state} = GenServer.call(pid, :get_state)
        Server.stop(state.id)
      end)
    end,
    "agent state query latency" => {
      fn pid ->
        GenServer.call(pid, :get_state)
      end,
      before_scenario: fn _ ->
        {:ok, pid} = Server.start_link(config_1)
        pid
      end,
      after_scenario: fn pid ->
        {:ok, state} = GenServer.call(pid, :get_state)
        Server.stop(state.id)
      end
    }
  },
  warmup: 1,
  time: 5,
  memory_time: 2,
  print: [benchmarking: true, configuration: true]
)
