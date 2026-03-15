defmodule Cortex.Application do
  @moduledoc """
  OTP Application for Cortex.

  Starts the supervision tree with the core children in dependency order,
  plus Ecto Repo, EventSink, and Phoenix Endpoint for the web layer.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # PubSub must start first — agents broadcast events during init
        {Phoenix.PubSub, name: Cortex.PubSub},
        # Registry must start before DynamicSupervisor — agents register via via_tuple during init
        {Registry, keys: :unique, name: Cortex.Agent.Registry},
        # DynamicSupervisor for agent GenServers
        {DynamicSupervisor, name: Cortex.Agent.Supervisor, strategy: :one_for_one},
        # Task.Supervisor for sandboxed tool execution
        {Task.Supervisor, name: Cortex.Tool.Supervisor},
        # Agent-backed tool registry for name -> module lookup
        {Cortex.Tool.Registry, []},
        # Orchestration: Registry for tracking live Runner processes by run_id
        {Registry, keys: :unique, name: Cortex.Orchestration.RunnerRegistry},
        # Messaging: Registry for mailbox name lookups (agent_id -> mailbox pid)
        {Registry, keys: :unique, name: Cortex.Messaging.MailboxRegistry},
        # Messaging: Router singleton for message routing between agents
        {Cortex.Messaging.Router, name: Cortex.Messaging.Router},
        # Messaging: DynamicSupervisor for per-agent Mailbox processes
        {Cortex.Messaging.Supervisor, name: Cortex.Messaging.Supervisor}
      ] ++ persistence_children() ++ web_children()

    opts = [strategy: :one_for_one, name: Cortex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp persistence_children do
    [
      Cortex.Repo,
      Cortex.Store.EventSink
    ]
  end

  defp web_children do
    [
      CortexWeb.Telemetry,
      {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics()},
      CortexWeb.Endpoint
    ]
  end

  defp prometheus_metrics do
    import Telemetry.Metrics

    [
      # Run metrics
      counter("cortex.run.started.team_count",
        tags: [:project],
        description: "Total runs started"
      ),
      distribution("cortex.run.completed.duration_ms",
        tags: [:project, :status],
        description: "Run duration in milliseconds",
        reporter_options: [buckets: [1_000, 5_000, 30_000, 60_000, 300_000, 600_000]]
      ),

      # Tier metrics
      counter("cortex.tier.completed.team_count",
        tags: [:tier_index],
        description: "Total tiers completed"
      ),

      # Team metrics
      counter("cortex.team.completed.duration_ms",
        tags: [:team_name, :status],
        description: "Total teams completed"
      ),
      distribution("cortex.team.completed.cost_usd",
        tags: [:team_name],
        description: "Team cost in USD",
        reporter_options: [buckets: [0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0]]
      ),

      # Gossip metrics
      distribution("cortex.gossip.exchange.duration_us",
        description: "Gossip exchange duration in microseconds",
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 10_000, 50_000]]
      ),

      # Tool metrics
      distribution("cortex.tool.executed.duration_ms",
        tags: [:tool_name, :success],
        description: "Tool execution duration",
        reporter_options: [buckets: [10, 50, 100, 500, 1_000, 5_000]]
      ),

      # Agent metrics
      counter("cortex.agent.started.system_time",
        tags: [:name, :role],
        description: "Total agents started"
      ),
      counter("cortex.agent.stopped.system_time",
        tags: [:agent_id, :reason],
        description: "Total agents stopped"
      )
    ]
  end
end
