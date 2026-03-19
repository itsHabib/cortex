defmodule Cortex.Gateway.RegisteredAgent do
  @moduledoc """
  Struct representing an externally connected agent registered via the gateway.

  Tracks the agent's identity, capabilities, health state, and the connection
  process (Phoenix Channel or gRPC stream). This is distinct from `Cortex.Mesh.Member`,
  which tracks locally-spawned agents in a mesh cluster.

  ## Fields

    - `id` — UUID v4, assigned at registration time
    - `name` — human-readable agent name
    - `role` — the agent's role description
    - `capabilities` — list of capability tags (e.g. `["security-review", "cve-lookup"]`)
    - `status` — lifecycle status: `:idle`, `:working`, `:draining`, or `:disconnected`
    - `channel_pid` — the Phoenix Channel process pid (nil for gRPC agents)
    - `stream_pid` — the gRPC stream process pid (nil for WebSocket agents)
    - `transport` — `:websocket` or `:grpc`
    - `monitor_ref` — `Process.monitor` reference for the connection pid
    - `metadata` — arbitrary key-value metadata (model, provider, max_concurrent, etc.)
    - `registered_at` — UTC timestamp of registration
    - `last_heartbeat` — UTC timestamp of last heartbeat (or registration time initially)
    - `load` — current load info: `%{active_tasks: integer, queue_depth: integer}`

  """

  @enforce_keys [:id, :name, :role, :capabilities, :monitor_ref]
  defstruct [
    :id,
    :name,
    :role,
    :capabilities,
    :channel_pid,
    :stream_pid,
    :monitor_ref,
    :registered_at,
    :last_heartbeat,
    status: :idle,
    transport: :websocket,
    metadata: %{},
    load: %{active_tasks: 0, queue_depth: 0}
  ]

  @type transport :: :websocket | :grpc

  @type status :: :idle | :working | :draining | :disconnected

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          role: String.t(),
          capabilities: [String.t()],
          status: status(),
          channel_pid: pid() | nil,
          stream_pid: pid() | nil,
          transport: transport(),
          monitor_ref: reference(),
          metadata: map(),
          registered_at: DateTime.t() | nil,
          last_heartbeat: DateTime.t() | nil,
          load: map()
        }

  @valid_statuses [:idle, :working, :draining, :disconnected]

  @doc """
  Returns the list of valid status atoms for a registered agent.
  """
  @spec valid_statuses() :: [status()]
  def valid_statuses, do: @valid_statuses

  @doc """
  Returns `true` if the given atom is a valid agent status.
  """
  @spec valid_status?(atom()) :: boolean()
  def valid_status?(status), do: status in @valid_statuses
end
