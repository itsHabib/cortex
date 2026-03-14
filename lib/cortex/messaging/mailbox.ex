defmodule Cortex.Messaging.Mailbox do
  @moduledoc """
  Per-agent message queue backed by an Erlang `:queue`.

  Each agent gets its own `Mailbox` GenServer. Incoming messages are
  enqueued in FIFO order. Consumers can poll with `receive_message/1`
  (non-blocking) or block with `receive_message/2` (with timeout).

  ## Blocking Receive

  When `receive_message/2` is called and the queue is empty, the caller
  is parked in a waiting list. As soon as a new message arrives via
  `send_message/2`, the oldest waiting caller is replied to immediately
  instead of enqueuing the message.

  ## Subscriptions

  Processes can subscribe to get `{:new_message, message}` notifications
  whenever a message is enqueued. This is useful for UI or logging.

  ## State

      %{
        owner: String.t(),
        messages: :queue.queue(Message.t()),
        waiters: [GenServer.from()],
        subscribers: [pid()]
      }

  """

  use GenServer

  alias Cortex.Messaging.Message

  # --- Client API ---

  @doc """
  Starts a Mailbox GenServer linked to the calling process.

  ## Options

    - `:owner` (required) — the agent_id this mailbox belongs to

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, owner, gen_opts)
  end

  @doc """
  Delivers a message to this mailbox.

  If any callers are blocked in `receive_message/2`, the oldest waiter
  is replied to immediately. Otherwise the message is enqueued.
  """
  @spec send_message(GenServer.server(), Message.t()) :: :ok
  def send_message(server, %Message{} = message) do
    GenServer.cast(server, {:send_message, message})
  end

  @doc """
  Dequeues the oldest message (non-blocking).

  Returns `{:ok, message}` or `:empty`.
  """
  @spec receive_message(GenServer.server()) :: {:ok, Message.t()} | :empty
  def receive_message(server) do
    GenServer.call(server, :receive_message)
  end

  @doc """
  Dequeues the oldest message, blocking up to `timeout` milliseconds.

  Returns `{:ok, message}` if a message arrives in time, or `:timeout`
  if the deadline passes with no message.
  """
  @spec receive_message(GenServer.server(), timeout()) :: {:ok, Message.t()} | :timeout
  def receive_message(server, timeout) do
    # We use a slightly longer GenServer.call timeout so the server can
    # reply with :timeout itself before the call times out.
    call_timeout = if is_integer(timeout), do: timeout + 500, else: timeout

    try do
      GenServer.call(server, {:receive_message, timeout}, call_timeout)
    catch
      :exit, {:timeout, _} -> :timeout
    end
  end

  @doc """
  Returns all queued messages without consuming them.
  """
  @spec peek(GenServer.server()) :: [Message.t()]
  def peek(server) do
    GenServer.call(server, :peek)
  end

  @doc """
  Returns the number of messages currently in the queue.
  """
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server) do
    GenServer.call(server, :count)
  end

  @doc """
  Subscribes the calling process to new-message notifications.

  The subscriber will receive `{:new_message, message}` for each
  message enqueued into this mailbox.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc """
  Removes all messages from the queue and cancels any blocked waiters.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server) do
    GenServer.call(server, :clear)
  end

  # --- Server Callbacks ---

  @impl true
  def init(owner) do
    {:ok,
     %{
       owner: owner,
       messages: :queue.new(),
       waiters: [],
       subscribers: []
     }}
  end

  @impl true
  def handle_cast({:send_message, message}, state) do
    # Notify subscribers
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:new_message, message})
    end)

    case state.waiters do
      [] ->
        # No one is waiting — enqueue
        {:noreply, %{state | messages: :queue.in(message, state.messages)}}

      [oldest | rest] ->
        # Reply to the oldest blocked caller directly
        GenServer.reply(oldest, {:ok, message})
        {:noreply, %{state | waiters: rest}}
    end
  end

  @impl true
  def handle_call(:receive_message, _from, state) do
    case :queue.out(state.messages) do
      {{:value, message}, remaining} ->
        {:reply, {:ok, message}, %{state | messages: remaining}}

      {:empty, _} ->
        {:reply, :empty, state}
    end
  end

  @impl true
  def handle_call({:receive_message, timeout}, from, state) do
    case :queue.out(state.messages) do
      {{:value, message}, remaining} ->
        {:reply, {:ok, message}, %{state | messages: remaining}}

      {:empty, _} ->
        # Park the caller; schedule a timeout to unblock them
        timer_ref = Process.send_after(self(), {:waiter_timeout, from}, timeout)
        {:noreply, %{state | waiters: state.waiters ++ [{from, timer_ref}]}}
    end
  end

  @impl true
  def handle_call(:peek, _from, state) do
    {:reply, :queue.to_list(state.messages), state}
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, :queue.len(state.messages), state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    # Reply :timeout to any blocked waiters
    Enum.each(state.waiters, fn {waiter_from, timer_ref} ->
      Process.cancel_timer(timer_ref)
      GenServer.reply(waiter_from, :timeout)
    end)

    {:reply, :ok, %{state | messages: :queue.new(), waiters: []}}
  end

  @impl true
  def handle_info({:waiter_timeout, from}, state) do
    # Find and remove the waiter, then reply :timeout
    case Enum.split_with(state.waiters, fn {f, _ref} -> f == from end) do
      {[{^from, _ref}], rest} ->
        GenServer.reply(from, :timeout)
        {:noreply, %{state | waiters: rest}}

      {[], _rest} ->
        # Already replied (message arrived before timeout) — ignore
        {:noreply, state}
    end
  end

  # The waiters field stores {from, timer_ref} tuples when blocking receive
  # is used, but plain `from` when dispatching from send_message. We need
  # to handle the cast path correctly: when a message arrives and we reply
  # to a waiter, we must also cancel their timer.

  # Override the cast handler to use the tuple form
  defoverridable handle_cast: 2

  def handle_cast({:send_message, message}, state) do
    # Notify subscribers
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:new_message, message})
    end)

    case state.waiters do
      [] ->
        # No one is waiting — enqueue
        {:noreply, %{state | messages: :queue.in(message, state.messages)}}

      [{oldest_from, timer_ref} | rest] ->
        # Reply to the oldest blocked caller directly, cancel their timer
        Process.cancel_timer(timer_ref)
        GenServer.reply(oldest_from, {:ok, message})
        {:noreply, %{state | waiters: rest}}
    end
  end
end
