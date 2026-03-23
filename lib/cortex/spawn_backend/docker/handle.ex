defmodule Cortex.SpawnBackend.Docker.Handle do
  @moduledoc """
  Handle struct for Docker-based spawn backend.

  Carries the container IDs, network ID, and metadata needed to manage
  a sidecar + worker container pair through their lifecycle. Returned
  by `SpawnBackend.Docker.spawn/1` and consumed by `stream/1`, `stop/1`,
  and `status/1`.

  The `docker_client` field enables test injection — production code
  uses `Cortex.SpawnBackend.Docker.Client`, tests can substitute a mock.
  """

  @enforce_keys [:sidecar_container_id, :worker_container_id, :team_name, :run_id, :network_id]
  defstruct [
    :sidecar_container_id,
    :worker_container_id,
    :team_name,
    :run_id,
    :network_id,
    docker_client: Cortex.SpawnBackend.Docker.Client
  ]

  @type t :: %__MODULE__{
          sidecar_container_id: String.t(),
          worker_container_id: String.t(),
          team_name: String.t(),
          run_id: String.t(),
          network_id: String.t(),
          docker_client: module()
        }
end
