defmodule Cortex.InternalAgent.Debug do
  @moduledoc """
  Spawns a short-lived `claude -p` agent to produce a diagnostic report
  for a team — works on completed, failed, stalled, or running agents.

  Pre-reads the team's log file, state.json entry, and diagnostics report,
  embeds them in the prompt, and gets back a structured analysis. Uses haiku
  with max_turns 1 — no tool calls needed, pure analysis.

  ## Usage

      Debug.analyze("/path/to/project", "team-name", run_name: "my-run")
      #=> {:ok, %{content: "...", team: "...", generated_at: "..."}}
  """

  alias Cortex.InternalAgent.Launcher
  alias Cortex.InternalAgent.SpawnConfig

  require Logger

  @max_log_lines 200

  @doc """
  Produces an AI-generated diagnostic report for a specific team.

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

    config = %SpawnConfig{
      team_name: "debug-agent",
      prompt: prompt,
      model: "haiku",
      max_turns: 1,
      permission_mode: "bypassPermissions",
      timeout_minutes: 2,
      command: Keyword.get(opts, :command, "claude"),
      cwd: workspace_path,
      log_path: log_path,
      on_activity: Keyword.get(opts, :on_activity),
      on_token_update: Keyword.get(opts, :on_token_update)
    }

    case Launcher.run(config) do
      {:ok, %{result: text, status: :success}} ->
        filename = save_to_disk(cortex_path, team_name, text)

        {:ok,
         %{
           content: text,
           team: team_name,
           generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
           filename: filename
         }}

      {:ok, %{result: text}} ->
        filename = save_to_disk(cortex_path, team_name, text)

        {:ok,
         %{
           content: text,
           team: team_name,
           generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
           filename: filename
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
    You are a diagnostic agent analyzing an agent's run.

    ## Run: #{run_name}
    ## Team: #{team_name}

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
    Analyze the log and state data above. Determine the agent's current state and
    produce a diagnostic report. Adapt your analysis to what actually happened —
    the agent may have completed successfully, may still be running, may have failed,
    or may be stalled.

    Structure your report as:

    1. **Status** — current state of the agent (completed, failed, stalled, running, etc.)
    2. **What Happened** — describe what the agent did in plain language
    3. **Key Observations** — notable patterns, errors, or successes from the log
    4. **Evidence** — specific log lines or state data that support your observations
    5. **Recommendations** — if there were issues, what to change next time;
       if successful, any optimization opportunities

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

  defp save_to_disk(cortex_path, team_name, content) do
    dir = Path.join(cortex_path, "debug")
    File.mkdir_p!(dir)

    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%dT%H%M%S")

    filename = "#{timestamp}_debug_#{team_name}.md"
    path = Path.join(dir, filename)
    File.write!(path, content)
    filename
  rescue
    e ->
      Logger.warning("Failed to save debug report to disk: #{inspect(e)}")
      nil
  end
end
