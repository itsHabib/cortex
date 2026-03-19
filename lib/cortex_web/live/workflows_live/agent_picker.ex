defmodule CortexWeb.WorkflowsLive.AgentPicker do
  @moduledoc """
  Agent picker wrapper for the Workflows page.

  Queries the Gateway Registry for connected agents and provides
  helpers for safe registry access. The actual picker UI rendering
  is delegated to the shared `AgentComponents.agent_picker/1`.
  """

  alias Cortex.Gateway.Events
  alias Cortex.Gateway.Registry

  @doc """
  Safely lists agents from the Gateway Registry.

  Returns `[]` if the Registry is not running or raises an error.
  """
  @spec safe_list_agents() :: [map()]
  def safe_list_agents do
    Registry.list()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Subscribes the calling process to Gateway events for live agent updates.

  Silently ignores failures if PubSub is not available.
  """
  @spec subscribe_gateway_events() :: :ok
  def subscribe_gateway_events do
    Events.subscribe()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
