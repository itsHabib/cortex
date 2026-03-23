defmodule Cortex.SpawnBackend.Docker.CleanupTest do
  use ExUnit.Case, async: true

  alias Cortex.SpawnBackend.Docker.Cleanup

  defmodule MockClient do
    @moduledoc false

    def setup(responses) do
      Process.put(:cleanup_mock_responses, responses)
      Process.put(:cleanup_mock_calls, [])
    end

    def calls do
      Process.get(:cleanup_mock_calls, []) |> Enum.reverse()
    end

    defp record_call(call) do
      calls = Process.get(:cleanup_mock_calls, [])
      Process.put(:cleanup_mock_calls, [call | calls])
    end

    defp get_response(key, default) do
      responses = Process.get(:cleanup_mock_responses, %{})
      Map.get(responses, key, default)
    end

    def list_containers(_filters, _opts \\ []) do
      record_call(:list_containers)
      get_response(:list_containers, {:ok, []})
    end

    def remove_container(id, _opts \\ []) do
      record_call({:remove_container, id})
      get_response({:remove_container, id}, :ok)
    end
  end

  describe "reap_orphans/1" do
    test "returns {:ok, 0} when no orphan containers found" do
      MockClient.setup(%{list_containers: {:ok, []}})

      assert {:ok, 0} = Cleanup.reap_orphans(docker_client: MockClient)
    end

    test "removes orphan containers and returns count" do
      containers = [
        %{"Id" => "abc123", "Names" => ["/cortex-run1-team1-sidecar"]},
        %{"Id" => "def456", "Names" => ["/cortex-run1-team1-worker"]}
      ]

      MockClient.setup(%{list_containers: {:ok, containers}})

      assert {:ok, 2} = Cleanup.reap_orphans(docker_client: MockClient)

      calls = MockClient.calls()

      assert {:remove_container, "abc123"} in calls
      assert {:remove_container, "def456"} in calls
    end

    test "counts only successfully removed containers" do
      containers = [
        %{"Id" => "abc123", "Names" => ["/success"]},
        %{"Id" => "def456", "Names" => ["/failure"]}
      ]

      MockClient.setup(
        Map.merge(
          %{list_containers: {:ok, containers}},
          %{{:remove_container, "def456"} => {:error, :some_error}}
        )
      )

      assert {:ok, 1} = Cleanup.reap_orphans(docker_client: MockClient)
    end

    test "is idempotent — returns {:ok, 0} on empty list" do
      MockClient.setup(%{list_containers: {:ok, []}})

      assert {:ok, 0} = Cleanup.reap_orphans(docker_client: MockClient)
      assert {:ok, 0} = Cleanup.reap_orphans(docker_client: MockClient)
    end

    test "handles Docker unavailable gracefully" do
      MockClient.setup(%{list_containers: {:error, :docker_unavailable}})

      assert {:ok, 0} = Cleanup.reap_orphans(docker_client: MockClient)
    end

    test "handles list_containers errors gracefully" do
      MockClient.setup(%{list_containers: {:error, {:unexpected_status, 500, "error"}}})

      assert {:ok, 0} = Cleanup.reap_orphans(docker_client: MockClient)
    end
  end
end
