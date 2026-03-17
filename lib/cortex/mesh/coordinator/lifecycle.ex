defmodule Cortex.Mesh.Coordinator.Lifecycle do
  @moduledoc """
  Manages the spawn/stop lifecycle of the mesh coordinator agent.

  The mesh coordinator is a lightweight observer that runs for the
  entire duration of a mesh session. It monitors agent activity,
  writes status summaries, and intervenes only when agents are stuck.
  """

  alias Cortex.InternalAgent.Launcher
  alias Cortex.InternalAgent.SpawnConfig
  alias Cortex.Mesh.Config, as: MeshConfig
  alias Cortex.Mesh.Coordinator.Prompt

  require Logger

  @doc """
  Spawns the mesh coordinator agent as an async Task.

  Builds the coordinator prompt, creates a TeamRun DB record,
  and delegates to `Launcher.run_async/1`.

  ## Parameters

    - `config` — the `%MeshConfig{}` struct
    - `workspace_path` — the project root directory
    - `command` — the CLI command string (e.g. `"claude"`)
    - `run_id` — the run ID for event broadcasting and DB records
    - `roster` — list of `%{name, role, state}` maps from MemberList

  ## Returns

    - A `Task.t()` on success
    - `nil` if spawning fails
  """
  @spec spawn(MeshConfig.t(), String.t(), String.t(), String.t() | nil, [map()]) ::
          Task.t() | nil
  def spawn(config, workspace_path, command, run_id, roster) do
    prompt = Prompt.build(config, workspace_path, roster)
    log_dir = Path.join([workspace_path, ".cortex", "logs"])
    File.mkdir_p!(log_dir)
    log_path = Path.join(log_dir, "coordinator.log")

    create_team_run(run_id, prompt, log_path)

    on_token_update = fn name, tokens ->
      broadcast(:team_tokens_updated, %{
        run_id: run_id,
        team_name: name,
        input_tokens: tokens.input_tokens,
        output_tokens: tokens.output_tokens,
        cache_read_tokens: tokens.cache_read_tokens,
        cache_creation_tokens: tokens.cache_creation_tokens
      })
    end

    on_activity = fn name, activity ->
      broadcast(:team_activity, %{
        run_id: run_id,
        team_name: name,
        type: Map.get(activity, :type, :unknown),
        tools: Map.get(activity, :tools, []),
        details: Map.get(activity, :details, []),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end

    spawn_config = %SpawnConfig{
      team_name: "coordinator",
      prompt: prompt,
      model: "haiku",
      max_turns: 500,
      permission_mode: "bypassPermissions",
      timeout_minutes: config.defaults.timeout_minutes,
      log_path: log_path,
      command: command,
      on_token_update: on_token_update,
      on_activity: on_activity
    }

    Launcher.run_async(spawn_config)
  end

  @doc """
  Stops the coordinator task.

  Yields for 5 seconds, then brutal-kills if the task hasn't finished.
  Safe to call with `nil` (no-op).
  """
  @spec stop(Task.t() | nil) :: :ok
  def stop(task), do: Launcher.stop(task)

  # -- DB Persistence --

  @spec create_team_run(String.t() | nil, String.t(), String.t()) :: :ok
  defp create_team_run(nil, _prompt, _log_path), do: :ok

  defp create_team_run(run_id, prompt, log_path) do
    Cortex.Store.upsert_internal_team_run(%{
      run_id: run_id,
      team_name: "coordinator",
      role: "Mesh Coordinator",
      tier: -1,
      internal: true,
      status: "running",
      prompt: prompt,
      log_path: log_path,
      started_at: DateTime.utc_now()
    })
  rescue
    _ -> :ok
  end

  @spec broadcast(atom(), map()) :: :ok
  defp broadcast(type, payload) do
    Cortex.Events.broadcast(type, payload)
    :ok
  rescue
    _ -> :ok
  end
end
