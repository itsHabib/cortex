defmodule Cortex.Agent.ExternalSupervisorTest do
  use ExUnit.Case, async: false

  @moduletag :external

  alias Cortex.Agent.ExternalSupervisor
  alias Cortex.Gateway.Registry, as: GatewayRegistry

  @agent_name "test-supervised-agent"

  setup do
    # Start Gateway.Registry with a unique name per test
    registry_name = :"gateway_registry_sup_#{System.unique_integer([:positive])}"
    start_supervised!({GatewayRegistry, name: registry_name})

    # Start PendingTasks with a unique name per test
    pending_name = :"pending_tasks_sup_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Cortex.Provider.External.PendingTasks, name: pending_name, table_name: pending_name}
    )

    # ExternalSupervisor is already started by the application supervision tree.
    # We use the global Cortex.Agent.ExternalSupervisor.

    %{registry: registry_name, pending_tasks: pending_name}
  end

  defp register_mock_agent(registry, name) do
    transport_pid = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, agent} =
      GatewayRegistry.register_grpc(
        registry,
        %{
          "name" => name,
          "role" => "worker",
          "capabilities" => ["general"]
        },
        transport_pid
      )

    {agent, transport_pid}
  end

  describe "start_agent/1" do
    test "starts an ExternalAgent and returns {:ok, pid}", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)

      assert {:ok, pid} =
               ExternalSupervisor.start_agent(
                 name: @agent_name,
                 registry: ctx.registry,
                 pending_tasks: ctx.pending_tasks
               )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns error when sidecar is not registered", ctx do
      assert {:error, :agent_not_found} =
               ExternalSupervisor.start_agent(
                 name: "nonexistent-agent",
                 registry: ctx.registry,
                 pending_tasks: ctx.pending_tasks
               )
    end
  end

  describe "find_agent/1" do
    test "returns {:ok, pid} for a running agent", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)

      {:ok, pid} =
        ExternalSupervisor.start_agent(
          name: @agent_name,
          registry: ctx.registry,
          pending_tasks: ctx.pending_tasks
        )

      assert {:ok, ^pid} = ExternalSupervisor.find_agent(@agent_name)
    end

    test "returns :not_found for an unknown name", _ctx do
      assert :not_found = ExternalSupervisor.find_agent("unknown-agent")
    end
  end

  describe "stop_agent/1" do
    test "stops a running agent", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)

      {:ok, pid} =
        ExternalSupervisor.start_agent(
          name: @agent_name,
          registry: ctx.registry,
          pending_tasks: ctx.pending_tasks
        )

      assert :ok = ExternalSupervisor.stop_agent(@agent_name)
      refute Process.alive?(pid)
    end

    test "returns {:error, :not_found} for unknown name", _ctx do
      assert {:error, :not_found} = ExternalSupervisor.stop_agent("unknown-agent")
    end
  end

  describe "list_agents/0" do
    test "returns all running agents", ctx do
      name1 = "list-agent-alpha-#{System.unique_integer([:positive])}"
      name2 = "list-agent-beta-#{System.unique_integer([:positive])}"

      {_agent1, _tp1} = register_mock_agent(ctx.registry, name1)
      {_agent2, _tp2} = register_mock_agent(ctx.registry, name2)

      {:ok, _pid1} =
        ExternalSupervisor.start_agent(
          name: name1,
          registry: ctx.registry,
          pending_tasks: ctx.pending_tasks
        )

      {:ok, _pid2} =
        ExternalSupervisor.start_agent(
          name: name2,
          registry: ctx.registry,
          pending_tasks: ctx.pending_tasks
        )

      agents = ExternalSupervisor.list_agents()
      names = Enum.map(agents, fn {name, _pid} -> name end)
      assert name1 in names
      assert name2 in names
    end

    test "stopped agents no longer appear", ctx do
      {_agent, _transport_pid} = register_mock_agent(ctx.registry, @agent_name)

      {:ok, _pid} =
        ExternalSupervisor.start_agent(
          name: @agent_name,
          registry: ctx.registry,
          pending_tasks: ctx.pending_tasks
        )

      assert ExternalSupervisor.list_agents() != []

      :ok = ExternalSupervisor.stop_agent(@agent_name)

      # Allow registry cleanup
      Process.sleep(10)

      agents = ExternalSupervisor.list_agents()
      names = Enum.map(agents, fn {name, _pid} -> name end)
      refute @agent_name in names

      assert :not_found = ExternalSupervisor.find_agent(@agent_name)
    end
  end
end
