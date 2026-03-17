defmodule Cortex.Mesh.Supervisor do
  @moduledoc """
  Ephemeral supervisor for a mesh session's infrastructure processes.

  Started per-session by `Mesh.SessionRunner`, NOT in the Application tree.
  Supervises the MemberList and Detector for the lifetime of a mesh run.

  ## Children

    - `Cortex.Mesh.MemberList` — the authoritative member roster
    - `Cortex.Mesh.Detector` — heartbeat-based failure detection

  """

  use Supervisor

  alias Cortex.Mesh.{Detector, MemberList}

  @doc """
  Starts the mesh supervisor with MemberList and Detector children.

  ## Options

    - `:cluster_name` — name for the mesh cluster (default: "mesh")
    - `:run_id` — run ID for event payloads
    - `:heartbeat_interval_ms` — heartbeat interval in ms (default: 30_000)
    - `:suspect_timeout_ms` — suspect timeout in ms (default: 90_000)
    - `:dead_timeout_ms` — dead timeout in ms (default: 180_000)

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    cluster_name = Keyword.get(opts, :cluster_name, "mesh")
    run_id = Keyword.get(opts, :run_id)
    heartbeat_ms = Keyword.get(opts, :heartbeat_interval_ms, 30_000)
    suspect_ms = Keyword.get(opts, :suspect_timeout_ms, 90_000)
    dead_ms = Keyword.get(opts, :dead_timeout_ms, 180_000)

    children = [
      {MemberList, cluster_name: cluster_name, run_id: run_id},
      {Detector,
       member_list: MemberList,
       heartbeat_interval_ms: heartbeat_ms,
       suspect_timeout_ms: suspect_ms,
       dead_timeout_ms: dead_ms}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
