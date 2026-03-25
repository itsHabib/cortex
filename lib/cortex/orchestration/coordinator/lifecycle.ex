defmodule Cortex.Orchestration.Coordinator.Lifecycle do
  @moduledoc """
  Manages the spawn/stop lifecycle of the orchestration coordinator agent.

  The coordinator is spawned as an async `Task` that runs a `claude -p`
  session. It lives for the entire duration of the DAG workflow and is
  stopped (with a graceful yield then brutal kill) after all tiers complete.
  """

  alias Cortex.InternalAgent.Launcher
  alias Cortex.InternalAgent.SpawnConfig
  alias Cortex.Orchestration.Config
  alias Cortex.Orchestration.Coordinator.Config, as: CoordConfig
  alias Cortex.Orchestration.Coordinator.Prompt
  alias Cortex.Orchestration.Workspace

  require Logger

  @doc """
  Spawns the coordinator agent as an async Task.

  Builds the coordinator prompt, sets up a `%SpawnConfig{}`, and
  delegates to `Launcher.run_async/1`.

  ## Parameters

    - `config` — the parsed `%Config{}` for this project
    - `tiers` — the DAG tiers as `[[team_name]]`
    - `workspace` — the `%Workspace{}` struct
    - `command` — the CLI command string (e.g. `"claude"`)
    - `run_id` — the run ID for event broadcasting
    - `broadcast_fn` — function `(atom, map) -> :ok` for sending events

  ## Returns

    - A `Task.t()` on success
    - `nil` if spawning fails

  """
  @spec spawn(Config.t(), [[String.t()]], Workspace.t(), String.t(), String.t() | nil, function()) ::
          Task.t() | nil
  def spawn(config, tiers, workspace, command, run_id, broadcast_fn) do
    prompt = Prompt.build(config, tiers, workspace.path)
    log_path = Workspace.log_path(workspace, run_id, CoordConfig.name())

    on_token_update = fn name, tokens ->
      broadcast_fn.(:team_tokens_updated, %{
        run_id: run_id,
        team_name: name,
        input_tokens: tokens.input_tokens,
        output_tokens: tokens.output_tokens,
        cache_read_tokens: tokens.cache_read_tokens,
        cache_creation_tokens: tokens.cache_creation_tokens
      })
    end

    on_activity = fn name, activity ->
      broadcast_fn.(:team_activity, %{
        run_id: run_id,
        team_name: name,
        type: activity.type,
        tools: Map.get(activity, :tools, []),
        details: Map.get(activity, :details, []),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end

    spawn_config = %SpawnConfig{
      team_name: CoordConfig.name(),
      prompt: prompt,
      model: CoordConfig.model(),
      max_turns: CoordConfig.max_turns(),
      permission_mode: CoordConfig.permission_mode(),
      timeout_minutes:
        CoordConfig.timeout_minutes(config.defaults.timeout_minutes, length(tiers)),
      log_path: log_path,
      command: command,
      cwd: Path.dirname(workspace.path),
      on_token_update: on_token_update,
      on_activity: on_activity,
      on_port_opened: fn _name, _pid -> :ok end
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
end
