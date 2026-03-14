defmodule Cortex.Messaging.Bus do
  @moduledoc """
  High-level messaging API for inter-agent communication.

  The Bus is the primary interface that agents and the orchestration
  runner use to exchange messages. It wraps the `Router` and `Mailbox`
  systems with a clean, agent-id-oriented API.

  All functions reference agents by their string ID. The Bus looks up
  the appropriate mailbox via the global `Cortex.Messaging.Router`.

  ## Examples

      {:ok, msg} = Bus.send_message("agent-a", "agent-b", "hello")
      {:ok, received} = Bus.receive_message("agent-b")
      received.content
      #=> "hello"

  """

  alias Cortex.Messaging.Message
  alias Cortex.Messaging.Router

  @router Cortex.Messaging.Router

  @doc """
  Sends a message from one agent to another.

  ## Parameters

    - `from` — sender agent_id
    - `to` — recipient agent_id
    - `content` — the message payload (any term)
    - `opts` — optional keyword list:
      - `:type` — message type (default `:message`)
      - `:metadata` — additional metadata map

  ## Returns

    - `{:ok, %Message{}}` on success
    - `{:error, :not_found}` if the recipient is not registered

  """
  @spec send_message(String.t(), String.t(), term(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def send_message(from, to, content, opts \\ []) do
    message =
      Message.new(%{
        from: from,
        to: to,
        content: content,
        type: Keyword.get(opts, :type, :message),
        metadata: Keyword.get(opts, :metadata)
      })

    case Router.send(@router, message) do
      :ok -> {:ok, message}
      {:error, _} = error -> error
    end
  end

  @doc """
  Broadcasts a message from one agent to all registered agents.

  ## Parameters

    - `from` — sender agent_id
    - `content` — the message payload
    - `opts` — optional keyword list (`:type`, `:metadata`)

  ## Returns

    - `{:ok, %Message{}}` always succeeds

  """
  @spec broadcast(String.t(), term(), keyword()) :: {:ok, Message.t()}
  def broadcast(from, content, opts \\ []) do
    message =
      Message.new(%{
        from: from,
        to: :broadcast,
        content: content,
        type: Keyword.get(opts, :type, :message),
        metadata: Keyword.get(opts, :metadata)
      })

    Router.broadcast(@router, message)
    {:ok, message}
  end

  @doc """
  Dequeues the oldest message from an agent's mailbox (non-blocking).

  Returns `{:ok, message}` or `:empty`.
  """
  @spec receive_message(String.t()) :: {:ok, Message.t()} | :empty
  def receive_message(agent_id) do
    case lookup_mailbox(agent_id) do
      {:ok, mailbox_pid} ->
        Cortex.Messaging.Mailbox.receive_message(mailbox_pid)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Dequeues the oldest message, blocking up to `timeout` milliseconds.

  Returns `{:ok, message}` or `:timeout`.
  """
  @spec receive_message(String.t(), timeout()) :: {:ok, Message.t()} | :timeout
  def receive_message(agent_id, timeout) do
    case lookup_mailbox(agent_id) do
      {:ok, mailbox_pid} ->
        Cortex.Messaging.Mailbox.receive_message(mailbox_pid, timeout)

      {:error, _} ->
        :timeout
    end
  end

  @doc """
  Returns all queued messages for an agent without consuming them.
  """
  @spec inbox(String.t()) :: [Message.t()]
  def inbox(agent_id) do
    case lookup_mailbox(agent_id) do
      {:ok, mailbox_pid} ->
        Cortex.Messaging.Mailbox.peek(mailbox_pid)

      {:error, _} ->
        []
    end
  end

  @doc """
  Subscribes the calling process to PubSub notifications for
  messages addressed to a specific agent.

  The subscriber will receive `%{type: :message_sent, payload: ...}`
  events whenever any message is routed through the system.
  """
  @spec subscribe_to_messages(String.t()) :: :ok
  def subscribe_to_messages(_agent_id) do
    # Subscribe to the global events topic — the caller can filter by
    # agent_id in the payload. A per-agent topic can be added later.
    Cortex.Events.subscribe()
  end

  # --- Private ---

  defp lookup_mailbox(agent_id) do
    case Registry.lookup(Cortex.Messaging.MailboxRegistry, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
