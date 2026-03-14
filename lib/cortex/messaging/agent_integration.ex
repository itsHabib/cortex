defmodule Cortex.Messaging.AgentIntegration do
  @moduledoc """
  Bridges the Agent system with the Messaging system.

  Provides setup/teardown lifecycle hooks and convenience wrappers so
  that agents can send and receive messages without knowing the internal
  plumbing (mailboxes, router registration, etc.).

  This module exists to avoid modifying `Cortex.Agent.Server` directly.
  The orchestration layer calls `setup/1` after spawning an agent and
  `teardown/1` before stopping it.

  ## Example

      # After starting an agent:
      AgentIntegration.setup(agent_id)

      # Agent A sends to Agent B:
      AgentIntegration.send("agent-a-id", "agent-b-id", %{result: "done"})

      # Agent B checks inbox:
      AgentIntegration.inbox("agent-b-id")
      #=> [%Message{...}]

      # Before stopping:
      AgentIntegration.teardown(agent_id)

  """

  alias Cortex.Messaging.Bus
  alias Cortex.Messaging.Mailbox
  alias Cortex.Messaging.Message
  alias Cortex.Messaging.Router

  @router Cortex.Messaging.Router
  @mailbox_supervisor Cortex.Messaging.Supervisor
  @mailbox_registry Cortex.Messaging.MailboxRegistry

  @doc """
  Sets up messaging for an agent.

  Creates a Mailbox process under the messaging DynamicSupervisor,
  registers it in the MailboxRegistry (for Bus lookups), and registers
  with the Router (for message delivery).

  ## Parameters

    - `agent_id` — the agent's UUID string

  ## Returns

    - `:ok` on success

  """
  @spec setup(String.t()) :: :ok
  def setup(agent_id) do
    # Start a mailbox under the DynamicSupervisor
    {:ok, mailbox_pid} =
      DynamicSupervisor.start_child(
        @mailbox_supervisor,
        {Mailbox, owner: agent_id, name: {:via, Registry, {@mailbox_registry, agent_id}}}
      )

    # Register with the router for message routing
    Router.register(@router, agent_id, mailbox_pid)
    :ok
  end

  @doc """
  Tears down messaging for an agent.

  Unregisters from the Router and terminates the Mailbox process.

  ## Parameters

    - `agent_id` — the agent's UUID string

  ## Returns

    - `:ok` always (idempotent)

  """
  @spec teardown(String.t()) :: :ok
  def teardown(agent_id) do
    Router.unregister(@router, agent_id)

    # Find and terminate the mailbox process
    case Registry.lookup(@mailbox_registry, agent_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(@mailbox_supervisor, pid)

      [] ->
        :ok
    end

    :ok
  end

  @doc """
  Sends a message from one agent to another.

  Convenience wrapper around `Cortex.Messaging.Bus.send_message/4`.

  ## Parameters

    - `from_id` — sender agent_id
    - `to_id` — recipient agent_id
    - `content` — the message payload

  ## Returns

    - `{:ok, %Message{}}` on success
    - `{:error, :not_found}` if the recipient is not registered

  """
  @spec send(String.t(), String.t(), term()) :: {:ok, Message.t()} | {:error, term()}
  def send(from_id, to_id, content) do
    Bus.send_message(from_id, to_id, content)
  end

  @doc """
  Returns all queued messages for an agent without consuming them.

  ## Parameters

    - `agent_id` — the agent's UUID string

  ## Returns

    - list of `%Message{}` structs (may be empty)

  """
  @spec inbox(String.t()) :: [Message.t()]
  def inbox(agent_id) do
    Bus.inbox(agent_id)
  end
end
