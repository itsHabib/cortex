defmodule Cortex.Mesh.Detector do
  @moduledoc """
  GenServer that performs SWIM-inspired failure detection for mesh members.

  Runs a periodic heartbeat loop that checks whether each alive member's
  port/process is still running. If not reachable, marks the member as
  suspect and starts a suspect timer. When the timer expires, promotes
  to dead.

  ## State

      %{
        member_list: pid() | atom(),
        heartbeat_interval_ms: pos_integer(),
        suspect_timeout_ms: pos_integer(),
        dead_timeout_ms: pos_integer(),
        suspect_timers: %{name => timer_ref}
      }

  """

  use GenServer

  alias Cortex.Mesh.MemberList

  require Logger

  @doc "Starts the Detector GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    member_list = Keyword.fetch!(opts, :member_list)
    heartbeat_ms = Keyword.get(opts, :heartbeat_interval_ms, 30_000)
    suspect_ms = Keyword.get(opts, :suspect_timeout_ms, 90_000)
    dead_ms = Keyword.get(opts, :dead_timeout_ms, 180_000)

    state = %{
      member_list: member_list,
      heartbeat_interval_ms: heartbeat_ms,
      suspect_timeout_ms: suspect_ms,
      dead_timeout_ms: dead_ms,
      suspect_timers: %{}
    }

    schedule_heartbeat(heartbeat_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    new_state = run_heartbeat(state)
    schedule_heartbeat(state.heartbeat_interval_ms)
    {:noreply, new_state}
  end

  def handle_info({:suspect_expired, name}, state) do
    MemberList.mark_dead(state.member_list, name)
    new_timers = Map.delete(state.suspect_timers, name)
    {:noreply, %{state | suspect_timers: new_timers}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp schedule_heartbeat(interval_ms) do
    Process.send_after(self(), :heartbeat, interval_ms)
  end

  defp run_heartbeat(state) do
    members = MemberList.alive_members(state.member_list)

    Enum.reduce(members, state, fn member, acc ->
      if process_alive?(member) do
        MemberList.mark_alive(acc.member_list, member.name)
        # Cancel suspect timer if one exists (member came back)
        cancel_suspect_timer(acc, member.name)
      else
        MemberList.mark_suspect(acc.member_list, member.name)
        start_suspect_timer(acc, member.name)
      end
    end)
  end

  defp process_alive?(%{os_pid: nil}), do: false

  defp process_alive?(%{os_pid: os_pid}) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp start_suspect_timer(state, name) do
    if Map.has_key?(state.suspect_timers, name) do
      state
    else
      timer_ref = Process.send_after(self(), {:suspect_expired, name}, state.suspect_timeout_ms)
      %{state | suspect_timers: Map.put(state.suspect_timers, name, timer_ref)}
    end
  end

  defp cancel_suspect_timer(state, name) do
    case Map.pop(state.suspect_timers, name) do
      {nil, _timers} ->
        state

      {timer_ref, new_timers} ->
        Process.cancel_timer(timer_ref)
        %{state | suspect_timers: new_timers}
    end
  end
end
