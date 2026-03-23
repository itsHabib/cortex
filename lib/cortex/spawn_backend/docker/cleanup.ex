defmodule Cortex.SpawnBackend.Docker.Cleanup do
  @moduledoc """
  Orphan container reaper for the Docker spawn backend.

  On Cortex startup (or on demand), queries the Docker daemon for containers
  labeled `cortex.managed=true` that are stopped or exited, and removes them.
  Prevents container accumulation from crashes or unclean shutdowns.

  ## Usage

      # Reap all orphan containers (uses default client)
      {:ok, count} = Cleanup.reap_orphans()

      # With custom client (for testing)
      {:ok, count} = Cleanup.reap_orphans(docker_client: MockClient)

  """

  alias Cortex.SpawnBackend.Docker.Client

  require Logger

  @doc """
  Finds and removes containers labeled `cortex.managed=true`.

  Returns `{:ok, count}` where `count` is the number of containers removed.
  Idempotent — returns `{:ok, 0}` if no orphans are found.

  ## Options

    - `:docker_client` — client module (default: `Docker.Client`)
    - `:socket_path` — Docker socket path
    - `:timeout` — request timeout in ms

  """
  @spec reap_orphans(keyword()) :: {:ok, non_neg_integer()}
  def reap_orphans(opts \\ []) do
    client = Keyword.get(opts, :docker_client, Client)
    client_opts = Keyword.take(opts, [:socket_path, :timeout])

    case client.list_containers(%{"label" => ["cortex.managed=true"]}, client_opts) do
      {:ok, containers} ->
        count =
          containers
          |> Enum.map(fn container ->
            container_id = Map.get(container, "Id", "")
            container_name = get_container_name(container)

            case client.remove_container(container_id, [{:force, true} | client_opts]) do
              :ok ->
                Logger.info("Docker.Cleanup: removed orphan container #{container_name}")
                1

              {:error, reason} ->
                Logger.warning(
                  "Docker.Cleanup: failed to remove #{container_name}: #{inspect(reason)}"
                )

                0
            end
          end)
          |> Enum.sum()

        if count > 0 do
          Logger.info("Docker.Cleanup: reaped #{count} orphan container(s)")
        end

        {:ok, count}

      {:error, :docker_unavailable} ->
        Logger.debug("Docker.Cleanup: Docker not available, skipping orphan reap")
        {:ok, 0}

      {:error, reason} ->
        Logger.warning("Docker.Cleanup: failed to list containers: #{inspect(reason)}")
        {:ok, 0}
    end
  end

  @spec get_container_name(map()) :: String.t()
  defp get_container_name(container) do
    case Map.get(container, "Names", []) do
      [name | _] -> name
      _ -> Map.get(container, "Id", "unknown") |> String.slice(0, 12)
    end
  end
end
