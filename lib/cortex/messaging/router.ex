defmodule Cortex.Messaging.Router do
  @moduledoc """
  Routes messages between registered agent mailboxes.

  The Router is a singleton GenServer that maintains a mapping of
  `agent_id -> mailbox_pid`. When a message is sent, the Router looks
  up the recipient's mailbox and delivers the message. Broadcasts
  deliver to every registered mailbox.

  All routed messages also emit a `:message_sent` event via
  `Cortex.Events` for observability.

  ## Registration

  Agents register with their ID and mailbox pid. Unregistration happens
  when an agent shuts down.
  """

  use GenServer

  alias Cortex.Messaging.Mailbox
  alias Cortex.Messaging.Message
  alias Cortex.Events

  # --- Client API ---

  @doc """
  Starts the Router GenServer.

  ## Options

    - `:name` — optional process name (defaults to unnamed)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, :ok, gen_opts)
  end

  @doc """
  Registers an agent's mailbox with the router.

  ## Parameters

    - `server` — the Router process
    - `agent_id` — the agent's string identifier
    - `mailbox_pid` — the pid of the agent's `Mailbox` GenServer

  """
  @spec register(GenServer.server(), String.t(), pid()) :: :ok
  def register(server, agent_id, mailbox_pid) do
    GenServer.call(server, {:register, agent_id, mailbox_pid})
  end

  @doc """
  Removes an agent's registration from the router.
  """
  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(server, agent_id) do
    GenServer.call(server, {:unregister, agent_id})
  end

  @doc """
  Sends a message to a specific agent or broadcasts to all.

  - If `message.to` is `:broadcast`, delivers to all registered mailboxes.
  - Otherwise, looks up the agent_id and delivers to that mailbox.

  Returns `:ok` on success, `{:error, :not_found}` if the recipient is
  not registered.
  """
  @spec send(GenServer.server(), Message.t()) :: :ok | {:error, :not_found}
  def send(server, %Message{} = message) do
    GenServer.call(server, {:send, message})
  end

  @doc """
  Broadcasts a message to all registered mailboxes.

  Always returns `:ok`, even if there are no registered agents.
  """
  @spec broadcast(GenServer.server(), Message.t()) :: :ok
  def broadcast(server, %Message{} = message) do
    GenServer.call(server, {:broadcast, message})
  end

  @doc """
  Returns a list of all currently registered agent IDs.
  """
  @spec list_agents(GenServer.server()) :: [String.t()]
  def list_agents(server) do
    GenServer.call(server, :list_agents)
  end

  # --- Server Callbacks ---

  @impl true
  def init(:ok) do
    {:ok, %{agents: %{}}}
  end

  @impl true
  def handle_call({:register, agent_id, mailbox_pid}, _from, state) do
    # Monitor the mailbox so we can auto-unregister on crash
    Process.monitor(mailbox_pid)
    new_agents = Map.put(state.agents, agent_id, mailbox_pid)
    {:reply, :ok, %{state | agents: new_agents}}
  end

  @impl true
  def handle_call({:unregister, agent_id}, _from, state) do
    new_agents = Map.delete(state.agents, agent_id)
    {:reply, :ok, %{state | agents: new_agents}}
  end

  @impl true
  def handle_call({:send, %Message{to: :broadcast} = message}, _from, state) do
    deliver_to_all(state.agents, message)
    broadcast_event(message)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:send, %Message{to: to} = message}, _from, state) do
    case Map.get(state.agents, to) do
      nil ->
        {:reply, {:error, :not_found}, state}

      mailbox_pid ->
        Mailbox.send_message(mailbox_pid, message)
        broadcast_event(message)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:broadcast, message}, _from, state) do
    deliver_to_all(state.agents, message)
    broadcast_event(message)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_agents, _from, state) do
    {:reply, Map.keys(state.agents), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, down_pid, _reason}, state) do
    # Auto-unregister any agent whose mailbox went down
    new_agents =
      state.agents
      |> Enum.reject(fn {_id, pid} -> pid == down_pid end)
      |> Map.new()

    {:noreply, %{state | agents: new_agents}}
  end

  # --- Private ---

  defp deliver_to_all(agents, message) do
    Enum.each(agents, fn {_id, mailbox_pid} ->
      Mailbox.send_message(mailbox_pid, message)
    end)
  end

  defp broadcast_event(message) do
    Events.broadcast(:message_sent, %{
      message_id: message.id,
      from: message.from,
      to: message.to,
      type: message.type
    })
  rescue
    # If PubSub is not started (e.g., in some test scenarios), silently continue
    _ -> :ok
  end
end
