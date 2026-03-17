defmodule Cortex.Mesh.MemberList do
  @moduledoc """
  GenServer that maintains the authoritative member roster for a mesh cluster.

  Tracks all members and their lifecycle states. Emits `Cortex.Events` on
  every state transition: `:member_joined`, `:member_suspect`, `:member_dead`,
  `:member_left`, `:member_alive`.

  ## State

      %{
        cluster_name: String.t(),
        members: %{name => Member.t()},
        run_id: String.t() | nil
      }

  """

  use GenServer

  alias Cortex.Mesh.Member

  require Logger

  # -- Public API --

  @doc "Starts the MemberList GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Registers a new member in the roster."
  @spec register(GenServer.server(), Member.t()) :: :ok | {:error, :already_registered}
  def register(server, %Member{} = member) do
    GenServer.call(server, {:register, member})
  end

  @doc "Marks a member as alive (heartbeat success or refutation)."
  @spec mark_alive(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def mark_alive(server, name) do
    GenServer.call(server, {:transition, name, :alive})
  end

  @doc "Marks a member as suspect (missed heartbeat)."
  @spec mark_suspect(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def mark_suspect(server, name) do
    GenServer.call(server, {:transition, name, :suspect})
  end

  @doc "Marks a member as dead (suspect timeout expired)."
  @spec mark_dead(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def mark_dead(server, name) do
    GenServer.call(server, {:transition, name, :dead})
  end

  @doc "Marks a member as left (clean exit)."
  @spec mark_left(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def mark_left(server, name) do
    GenServer.call(server, {:transition, name, :left})
  end

  @doc "Gets a member by name."
  @spec get_member(GenServer.server(), String.t()) :: Member.t() | nil
  def get_member(server, name) do
    GenServer.call(server, {:get_member, name})
  end

  @doc "Returns all members in the `:alive` state."
  @spec alive_members(GenServer.server()) :: [Member.t()]
  def alive_members(server) do
    GenServer.call(server, :alive_members)
  end

  @doc "Returns all members in `:alive` or `:suspect` state."
  @spec active_members(GenServer.server()) :: [Member.t()]
  def active_members(server) do
    GenServer.call(server, :active_members)
  end

  @doc "Returns all members regardless of state."
  @spec all_members(GenServer.server()) :: [Member.t()]
  def all_members(server) do
    GenServer.call(server, :all_members)
  end

  @doc "Returns a roster summary: list of `%{name, role, state}` maps."
  @spec roster(GenServer.server()) :: [map()]
  def roster(server) do
    GenServer.call(server, :roster)
  end

  @doc "Updates arbitrary fields on a member."
  @spec update_member(GenServer.server(), String.t(), map()) :: :ok | {:error, :not_found}
  def update_member(server, name, updates) do
    GenServer.call(server, {:update_member, name, updates})
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    cluster_name = Keyword.get(opts, :cluster_name, "mesh")
    run_id = Keyword.get(opts, :run_id)

    state = %{
      cluster_name: cluster_name,
      members: %{},
      run_id: run_id
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, %Member{} = member}, _from, state) do
    if Map.has_key?(state.members, member.name) do
      {:reply, {:error, :already_registered}, state}
    else
      now = DateTime.utc_now()

      member = %{
        member
        | started_at: member.started_at || now,
          last_seen: member.last_seen || now
      }

      new_members = Map.put(state.members, member.name, member)
      new_state = %{state | members: new_members}

      safe_broadcast(:member_joined, %{
        cluster: state.cluster_name,
        run_id: state.run_id,
        name: member.name,
        role: member.role
      })

      {:reply, :ok, new_state}
    end
  end

  def handle_call({:transition, name, new_state_atom}, _from, state) do
    case Map.get(state.members, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      member ->
        handle_transition(member, new_state_atom, name, state)
    end
  end

  def handle_call({:get_member, name}, _from, state) do
    {:reply, Map.get(state.members, name), state}
  end

  def handle_call(:alive_members, _from, state) do
    members = state.members |> Map.values() |> Enum.filter(&Member.alive?/1)
    {:reply, members, state}
  end

  def handle_call(:active_members, _from, state) do
    members = state.members |> Map.values() |> Enum.filter(&Member.active?/1)
    {:reply, members, state}
  end

  def handle_call(:all_members, _from, state) do
    {:reply, Map.values(state.members), state}
  end

  def handle_call(:roster, _from, state) do
    roster =
      state.members
      |> Map.values()
      |> Enum.map(fn m -> %{name: m.name, role: m.role, state: m.state} end)
      |> Enum.sort_by(& &1.name)

    {:reply, roster, state}
  end

  def handle_call({:update_member, name, updates}, _from, state) do
    case Map.get(state.members, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      member ->
        updated = struct(member, updates)
        new_members = Map.put(state.members, name, updated)
        {:reply, :ok, %{state | members: new_members}}
    end
  end

  # -- Private --

  defp handle_transition(member, new_state_atom, name, state) do
    case Member.transition(member, new_state_atom) do
      {:ok, updated} ->
        updated = maybe_touch_last_seen(updated, new_state_atom)
        new_members = Map.put(state.members, name, updated)
        new_state = %{state | members: new_members}
        emit_transition_event(new_state_atom, state, updated)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp maybe_touch_last_seen(member, :alive), do: %{member | last_seen: DateTime.utc_now()}
  defp maybe_touch_last_seen(member, _), do: member

  defp emit_transition_event(:alive, state, member) do
    safe_broadcast(:member_alive, %{
      cluster: state.cluster_name,
      run_id: state.run_id,
      name: member.name
    })
  end

  defp emit_transition_event(:suspect, state, member) do
    safe_broadcast(:member_suspect, %{
      cluster: state.cluster_name,
      run_id: state.run_id,
      name: member.name
    })
  end

  defp emit_transition_event(:dead, state, member) do
    safe_broadcast(:member_dead, %{
      cluster: state.cluster_name,
      run_id: state.run_id,
      name: member.name
    })
  end

  defp emit_transition_event(:left, state, member) do
    safe_broadcast(:member_left, %{
      cluster: state.cluster_name,
      run_id: state.run_id,
      name: member.name
    })
  end

  defp safe_broadcast(type, payload) do
    Cortex.Events.broadcast(type, payload)
  rescue
    _ -> :ok
  end
end
