defmodule Cortex.Orchestration.DebugAgent do
  @moduledoc """
  Spawns a short-lived `claude -p` agent to produce a root cause analysis
  for a failed or stalled team.

  Pre-reads the team's log file, state.json entry, and diagnostics report,
  embeds them in the prompt, and gets back a structured RCA. Uses haiku
  with max_turns 1 — no tool calls needed, pure analysis.

  ## Usage

      DebugAgent.analyze("/path/to/project", "team-name", run_name: "my-run")
      #=> {:ok, %{content: "...", team: "...", generated_at: "..."}}
  """

  alias Cortex.Orchestration.Spawner

  require Logger

  @max_log_lines 200

  @doc """
  Produces an AI-generated root cause analysis for a specific team.

  Reads the team's log file and workspace state, spawns `claude -p`
  with haiku, and returns the RCA text.

  ## Options

    - `:run_name` — display name for the run (default: `"Untitled"`)
    - `:command` — override the claude command path (default: `"claude"`)
    - `:on_activity` — `fn name, activity -> ...` callback for tool use events
    - `:on_token_update` — `fn name, tokens -> ...` callback for token updates

  ## Returns

    - `{:ok, %{content: String.t(), team: String.t(), generated_at: String.t()}}`
    - `{:error, term()}`
  """
  @spec analyze(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def analyze(workspace_path, team_name, opts \\ []) do
    cortex_path = Path.join(workspace_path, ".cortex")
    run_name = Keyword.get(opts, :run_name, "Untitled")
    log_path = Path.join([cortex_path, "logs", "debug-agent.log"])

    context = gather_context(cortex_path, team_name)
    prompt = build_prompt(run_name, team_name, context)

    spawn_opts = [
      team_name: "debug-agent",
      prompt: prompt,
      model: "haiku",
      max_turns: 1,
      permission_mode: "bypassPermissions",
      timeout_minutes: 2,
      command: Keyword.get(opts, :command, "claude"),
      cwd: workspace_path,
      log_path: log_path
    ]

    spawn_opts =
      spawn_opts
      |> maybe_add_callback(:on_activity, opts)
      |> maybe_add_callback(:on_token_update, opts)

    result = Spawner.spawn(spawn_opts)

    case result do
      {:ok, %{result: text, status: :success}} ->
        {:ok,
         %{
           content: text,
           team: team_name,
           generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:ok, %{result: text}} ->
        {:ok,
         %{
           content: text,
           team: team_name,
           generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Context gathering --

  defp gather_context(cortex_path, team_name) do
    %{
      state: read_file(Path.join(cortex_path, "state.json")),
      team_log: read_log_tail(Path.join([cortex_path, "logs", "#{team_name}.log"])),
      coordinator_log: read_log_tail(Path.join([cortex_path, "logs", "coordinator.log"]), 50)
    }
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp read_log_tail(path, max_lines \\ @max_log_lines) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.take(-max_lines)
        |> Enum.join("\n")

      _ ->
        nil
    end
  end

  # -- Prompt --

  defp build_prompt(run_name, team_name, context) do
    team_state = extract_team_state(context.state, team_name)

    """
    You are a debug agent performing root cause analysis on a failed agent run.

    ## Run: #{run_name}
    ## Failed Team: #{team_name}

    ## Team State (from state.json)
    ```json
    #{team_state || "No state entry found for this team"}
    ```

    ## Team Log (last #{@max_log_lines} lines)
    ```
    #{context.team_log || "No log file found"}
    ```

    #{if context.coordinator_log, do: "## Coordinator Log (last 50 lines)\n```\n#{context.coordinator_log}\n```\n", else: ""}

    ## Instructions
    Analyze the log and state data above to determine why this agent failed.
    Produce a root cause analysis covering:

    1. **What Happened** — describe the failure in plain language
    2. **Root Cause** — the most likely underlying cause (rate limit, permission error,
       tool failure, timeout, prompt issue, etc.)
    3. **Evidence** — specific log lines or state data that support your diagnosis
    4. **Impact** — what work was lost or incomplete
    5. **Suggested Fix** — what to change to prevent this failure next time
       (config change, prompt adjustment, retry strategy, etc.)

    Be direct and specific. Reference actual log lines and error messages.
    Keep the analysis under 60 lines. Use markdown formatting.
    Do NOT use any tools. Just analyze the data provided above.
    """
    |> String.trim()
  end

  defp extract_team_state(nil, _team_name), do: nil

  defp extract_team_state(state_json, team_name) do
    case Jason.decode(state_json) do
      {:ok, %{"teams" => teams}} ->
        case Map.get(teams, team_name) do
          nil -> nil
          team_data -> Jason.encode!(team_data, pretty: true)
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp maybe_add_callback(opts, key, source_opts) do
    case Keyword.get(source_opts, key) do
      nil -> opts
      cb -> Keyword.put(opts, key, cb)
    end
  end
end
