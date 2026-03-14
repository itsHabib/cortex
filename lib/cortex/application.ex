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
        {Cortex.Tool.Registry, []}
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
    [CortexWeb.Endpoint]
  end
end
