defmodule Cortex.Orchestration.WorkspaceLock do
  @moduledoc """
  Serializes workspace file writes to prevent concurrent read-modify-write races.

  Workspace files like `state.json` and `registry.json` are shared between
  concurrent team tasks. Without serialization, two tasks can read the same
  version, each apply their own update, and one overwrites the other's changes.

  This GenServer acts as a simple mutex — all read-modify-write operations
  on workspace files go through `serialize/2`, which runs them sequentially.

  ## Usage

      WorkspaceLock.serialize("state.json", fn ->
        # read, modify, write — guaranteed exclusive
      end)

  Started as part of the application supervision tree.
  """

  use GenServer

  @doc """
  Starts the workspace lock process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs `fun` with exclusive access to the given `key`.

  The key is typically a file path or logical name (e.g., `"state.json"`).
  All calls with the same key are serialized. Calls with different keys
  are also serialized through this single process, but workspace writes
  are fast enough that this is not a bottleneck.

  Returns whatever `fun` returns. If the lock process is not running,
  falls back to running `fun` directly (best-effort, no crash).
  """
  @spec serialize(term(), (-> result)) :: result when result: var
  def serialize(key, fun) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:run, key, fun}, :infinity)
  catch
    :exit, _ ->
      # Lock process not running — fall back to unserialized execution
      fun.()
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:run, _key, fun}, _from, state) do
    result = fun.()
    {:reply, result, state}
  rescue
    e -> {:reply, {:error, e}, state}
  end
end
