defmodule CortexWeb.Telemetry do
  @moduledoc """
  Telemetry metrics definitions for LiveDashboard.

  Defines `Telemetry.Metrics` counters, histograms, and summaries
  matching the 8 events in `Cortex.Telemetry` so that LiveDashboard
  at `/dev/dashboard` can display them.
  """

  use Supervisor

  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the list of telemetry metrics for LiveDashboard.
  """
  def metrics do
    [
      # Phoenix metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),

      # Cortex run metrics
      counter("cortex.run.started.team_count",
        description: "Number of runs started"
      ),
      summary("cortex.run.completed.duration_ms",
        description: "Run duration in milliseconds",
        unit: :millisecond
      ),

      # Cortex tier metrics
      counter("cortex.tier.completed.team_count",
        description: "Number of tiers completed"
      ),

      # Cortex team metrics
      counter("cortex.team.completed.duration_ms",
        description: "Number of teams completed"
      ),
      summary("cortex.team.completed.cost_usd",
        description: "Team cost in USD"
      ),

      # Cortex live token metrics
      last_value("cortex.team.tokens_updated.input_tokens",
        description: "Running input token count per team",
        tags: [:team_name]
      ),
      last_value("cortex.team.tokens_updated.output_tokens",
        description: "Running output token count per team",
        tags: [:team_name]
      ),

      # Cortex gossip metrics
      summary("cortex.gossip.exchange.duration_us",
        description: "Gossip exchange duration in microseconds",
        unit: :microsecond
      ),

      # Cortex agent metrics
      counter("cortex.agent.started.system_time",
        description: "Number of agents started"
      ),
      counter("cortex.agent.stopped.system_time",
        description: "Number of agents stopped"
      ),

      # Cortex tool metrics
      summary("cortex.tool.executed.duration_ms",
        description: "Tool execution duration",
        unit: :millisecond
      ),

      # Cortex gateway metrics
      counter("cortex.gateway.agent.registered.system_time",
        description: "Gateway agents registered"
      ),
      counter("cortex.gateway.agent.unregistered.system_time",
        description: "Gateway agents unregistered"
      ),
      counter("cortex.gateway.agent.heartbeat.system_time",
        description: "Gateway agent heartbeats"
      ),
      counter("cortex.gateway.task.dispatched.system_time",
        description: "Gateway tasks dispatched"
      ),
      summary("cortex.gateway.task.completed.duration_ms",
        description: "Gateway task completion duration",
        unit: :millisecond
      ),

      # VM metrics
      summary("vm.memory.total", unit: {:byte, :megabyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    []
  end
end
