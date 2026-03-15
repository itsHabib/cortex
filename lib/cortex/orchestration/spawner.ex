defmodule Cortex.Orchestration.Spawner do
  @moduledoc """
  Spawns `claude -p` processes via Erlang ports and captures NDJSON results.

  The spawner opens an external process with `--output-format stream-json`,
  collects stdout line-by-line, parses NDJSON, and builds a `TeamResult`
  from the final `"type": "result"` line.

  ## Options

    - `:team_name` — string, required. Identifies the team this run belongs to.
    - `:prompt` — string, required. The full prompt text passed to `claude -p`.
    - `:model` — string, default `"sonnet"`. The LLM model to use.
    - `:max_turns` — integer, default `200`. Maximum conversation turns.
    - `:permission_mode` — string, default `"acceptEdits"`. Permission mode flag.
    - `:timeout_minutes` — integer, default `30`. Kill the process after this many minutes.
    - `:log_path` — string or nil. If set, raw stdout is written to this file path.
    - `:command` — string, default `"claude"`. Override in tests with a mock script path.

  ## How it works

  1. Builds CLI args for `claude -p`
  2. Opens an Erlang port to the command
  3. Collects all stdout data, buffering partial lines
  4. Optionally writes raw output to `:log_path`
  5. Parses NDJSON lines, looking for `"type": "result"` and `"type": "system"`
  6. Returns `{:ok, %TeamResult{}}` on success
  7. Handles timeout by killing the port process
  8. Returns `{:error, {:exit_code, code}}` on non-zero exit

  """

  alias Cortex.Orchestration.TeamResult

  require Logger

  @default_model "sonnet"
  @default_max_turns 200
  @default_permission_mode "acceptEdits"
  @default_timeout_minutes 30
  @default_command "claude"

  @doc """
  Spawns a `claude -p` process (or mock command) and captures the result.

  Returns `{:ok, %TeamResult{}}` on success, `{:error, term()}` on failure.

  ## Examples

      iex> Spawner.spawn(team_name: "backend", prompt: "Build the API", command: "/path/to/mock")
      {:ok, %TeamResult{team: "backend", status: :success, ...}}

  """
  @spec spawn(keyword()) :: {:ok, TeamResult.t()} | {:error, term()}
  def spawn(opts) when is_list(opts) do
    team_name = Keyword.fetch!(opts, :team_name)
    prompt = Keyword.fetch!(opts, :prompt)
    model = Keyword.get(opts, :model, @default_model)
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    permission_mode = Keyword.get(opts, :permission_mode, @default_permission_mode)
    timeout_minutes = Keyword.get(opts, :timeout_minutes, @default_timeout_minutes)
    log_path = Keyword.get(opts, :log_path)
    command = Keyword.get(opts, :command, @default_command)
    cwd = Keyword.get(opts, :cwd)
    on_token_update = Keyword.get(opts, :on_token_update)
    on_activity = Keyword.get(opts, :on_activity)

    args = build_args(prompt, model, max_turns, permission_mode)
    command_path = resolve_command(command)
    timeout_ms = round(timeout_minutes * 60 * 1_000)

    log_device = open_log_device(log_path)

    try do
      port = open_port(command_path, args, cwd)
      timer_ref = Process.send_after(self(), {:spawner_timeout, port}, timeout_ms)

      result =
        collect_output(port, timer_ref, team_name, log_device, on_token_update, on_activity)

      Process.cancel_timer(timer_ref)
      result
    after
      close_log_device(log_device)
    end
  end

  @doc """
  Resumes a previous `claude -p` session using `--resume <session_id>`.

  Takes the same options as `spawn/1` plus:
    - `:session_id` — required. The session ID to resume.
    - `:prompt` — the continuation prompt (default: "continue where you left off").

  Returns `{:ok, %TeamResult{}}` on success, `{:error, term()}` on failure.
  """
  @spec resume(keyword()) :: {:ok, TeamResult.t()} | {:error, term()}
  def resume(opts) when is_list(opts) do
    team_name = Keyword.fetch!(opts, :team_name)
    session_id = Keyword.fetch!(opts, :session_id)
    prompt = Keyword.get(opts, :prompt, "continue where you left off")
    timeout_minutes = Keyword.get(opts, :timeout_minutes, @default_timeout_minutes)
    log_path = Keyword.get(opts, :log_path)
    command = Keyword.get(opts, :command, @default_command)
    cwd = Keyword.get(opts, :cwd)
    on_token_update = Keyword.get(opts, :on_token_update)
    on_activity = Keyword.get(opts, :on_activity)

    args = build_resume_args(session_id, prompt)
    command_path = resolve_command(command)
    timeout_ms = round(timeout_minutes * 60 * 1_000)

    log_device = open_log_device(log_path)

    try do
      port = open_port(command_path, args, cwd)
      timer_ref = Process.send_after(self(), {:spawner_timeout, port}, timeout_ms)

      result =
        collect_output(port, timer_ref, team_name, log_device, on_token_update, on_activity)

      Process.cancel_timer(timer_ref)
      result
    after
      close_log_device(log_device)
    end
  end

  @doc """
  Extracts a session_id from an NDJSON log file.

  Reads the first line of the log looking for `{"type":"system","subtype":"init","session_id":"..."}`.
  Falls back to scanning the result line for session_id.

  Returns `{:ok, session_id}` or `:error`.
  """
  @spec extract_session_id_from_log(String.t()) :: {:ok, String.t()} | :error
  def extract_session_id_from_log(log_path) do
    case File.read(log_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.find_value(:error, fn line ->
          case Jason.decode(String.trim(line)) do
            {:ok, %{"type" => "system", "subtype" => "init", "session_id" => sid}} ->
              {:ok, sid}

            {:ok, %{"type" => "result", "session_id" => sid}} when is_binary(sid) ->
              {:ok, sid}

            _ ->
              nil
          end
        end)

      {:error, _} ->
        :error
    end
  end

  # -- Private ---------------------------------------------------------------

  @spec build_resume_args(String.t(), String.t()) :: [String.t()]
  defp build_resume_args(session_id, prompt) do
    [
      "--resume",
      session_id,
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--verbose"
    ]
  end

  @spec build_args(String.t(), String.t(), pos_integer(), String.t()) :: [String.t()]
  defp build_args(prompt, model, max_turns, permission_mode) do
    [
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--model",
      model,
      "--max-turns",
      to_string(max_turns),
      "--permission-mode",
      permission_mode
    ]
  end

  @spec resolve_command(String.t()) :: charlist()
  defp resolve_command(command) do
    case System.find_executable(command) do
      nil -> to_charlist(command)
      path -> to_charlist(path)
    end
  end

  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  @spec open_port(charlist(), [String.t()], String.t() | nil) :: port()
  defp open_port(command_path, args, cwd) do
    # Strip CLAUDECODE env var so child claude processes don't refuse to start
    # (matches the Go agent-orchestra behavior)
    env =
      System.get_env()
      |> Map.drop(["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"])
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    # Use /bin/sh wrapper to redirect stdin from /dev/null.
    # claude -p hangs if stdin stays open (it waits for input).
    escaped_args = Enum.map(args, &shell_escape/1)
    shell_cmd = Enum.join([to_string(command_path) | escaped_args], " ") <> " </dev/null"

    port_opts = [:binary, :exit_status, :use_stdio, {:args, ["-c", shell_cmd]}, {:env, env}]
    port_opts = if cwd, do: [{:cd, String.to_charlist(cwd)} | port_opts], else: port_opts

    Port.open({:spawn_executable, ~c"/bin/sh"}, port_opts)
  end

  @spec open_log_device(String.t() | nil) :: File.io_device() | nil
  defp open_log_device(nil), do: nil

  defp open_log_device(path) when is_binary(path) do
    # Ensure parent directory exists
    path |> Path.dirname() |> File.mkdir_p!()

    case File.open(path, [:append, :binary]) do
      {:ok, device} ->
        device

      {:error, reason} ->
        Logger.warning("Failed to open log file #{path}: #{inspect(reason)}")
        nil
    end
  end

  @spec close_log_device(File.io_device() | nil) :: :ok
  defp close_log_device(nil), do: :ok
  defp close_log_device(device), do: File.close(device)

  @spec collect_output(
          port(),
          reference(),
          String.t(),
          File.io_device() | nil,
          function() | nil,
          function() | nil
        ) ::
          {:ok, TeamResult.t()} | {:error, term()}
  defp collect_output(port, timer_ref, team_name, log_device, on_token_update, on_activity) do
    state = %{
      team_name: team_name,
      buffer: "",
      session_id: nil,
      result_line: nil,
      tokens: %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0},
      on_token_update: on_token_update,
      on_activity: on_activity
    }

    collect_loop(port, timer_ref, log_device, state)
  end

  defp collect_loop(port, timer_ref, log_device, state) do
    receive do
      {^port, {:data, data}} ->
        write_to_log(log_device, data)
        {lines, new_buffer} = extract_lines(state.buffer <> data)

        {new_session_id, new_result_line, usage_deltas, activities} =
          parse_lines(lines, state.session_id, state.result_line)

        new_tokens = accumulate_tokens(state.tokens, usage_deltas)
        maybe_notify_tokens(state.on_token_update, state.team_name, state.tokens, new_tokens)
        maybe_notify_activities(state.on_activity, state.team_name, activities)

        collect_loop(port, timer_ref, log_device, %{
          state
          | buffer: new_buffer,
            session_id: new_session_id,
            result_line: new_result_line,
            tokens: new_tokens
        })

      {^port, {:exit_status, 0}} ->
        {final_session_id, final_result_line, _, _} =
          parse_remaining(state.buffer, state.session_id, state.result_line)

        build_team_result(state.team_name, final_session_id, final_result_line)

      {^port, {:exit_status, code}} ->
        {:error, {:exit_code, code}}

      {:spawner_timeout, ^port} ->
        kill_port(port)
        Process.cancel_timer(timer_ref)
        {:ok, %TeamResult{team: state.team_name, status: :timeout, session_id: state.session_id}}
    end
  end

  @spec extract_lines(String.t()) :: {[String.t()], String.t()}
  defp extract_lines(data) do
    case String.split(data, "\n") do
      [single] ->
        # No newline found — everything is still buffered
        {[], single}

      parts ->
        # Last element is the incomplete remainder (could be "")
        {lines, [remainder]} = Enum.split(parts, -1)
        {lines, remainder}
    end
  end

  @spec parse_lines([String.t()], String.t() | nil, map() | nil) ::
          {String.t() | nil, map() | nil, [map()], [map()]}
  defp parse_lines(lines, session_id, result_line) do
    Enum.reduce(lines, {session_id, result_line, [], []}, fn line, {sid, res, usages, acts} ->
      {new_sid, new_res, usage, activity} = parse_ndjson_line(String.trim(line), sid, res)
      usages = if usage, do: [usage | usages], else: usages
      acts = if activity, do: [activity | acts], else: acts
      {new_sid, new_res, usages, acts}
    end)
  end

  @spec parse_remaining(String.t(), String.t() | nil, map() | nil) ::
          {String.t() | nil, map() | nil, [map()], [map()]}
  defp parse_remaining("", session_id, result_line), do: {session_id, result_line, [], []}

  defp parse_remaining(buffer, session_id, result_line) do
    {sid, res, usage, activity} = parse_ndjson_line(String.trim(buffer), session_id, result_line)
    usages = if usage, do: [usage], else: []
    acts = if activity, do: [activity], else: []
    {sid, res, usages, acts}
  end

  @spec parse_ndjson_line(String.t(), String.t() | nil, map() | nil) ::
          {String.t() | nil, map() | nil, map() | nil, map() | nil}
  defp parse_ndjson_line("", session_id, result_line), do: {session_id, result_line, nil, nil}

  defp parse_ndjson_line(line, session_id, result_line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result"} = parsed} ->
        {session_id, parsed, nil, nil}

      {:ok, %{"type" => "system", "subtype" => "init", "session_id" => sid}} ->
        {sid, result_line, nil, nil}

      {:ok, parsed} ->
        usage = extract_usage(parsed)
        activity = extract_activity(parsed)
        {session_id, result_line, usage, activity}

      {:error, _} ->
        # Non-JSON line (e.g. stderr interleaved) — skip
        {session_id, result_line, nil, nil}
    end
  end

  @spec extract_usage(map()) :: map() | nil
  defp extract_usage(%{"message" => %{"usage" => usage}}) when is_map(usage), do: usage
  defp extract_usage(%{"usage" => usage}) when is_map(usage), do: usage
  defp extract_usage(_), do: nil

  @spec accumulate_tokens(map(), [map()]) :: map()
  defp accumulate_tokens(tokens, []), do: tokens

  defp accumulate_tokens(tokens, usage_deltas) do
    Enum.reduce(usage_deltas, tokens, fn usage, acc ->
      %{
        input_tokens: acc.input_tokens + Map.get(usage, "input_tokens", 0),
        output_tokens: acc.output_tokens + Map.get(usage, "output_tokens", 0),
        cache_read_tokens: acc.cache_read_tokens + Map.get(usage, "cache_read_input_tokens", 0),
        cache_creation_tokens:
          acc.cache_creation_tokens + Map.get(usage, "cache_creation_input_tokens", 0)
      }
    end)
  end

  @spec extract_activity(map()) :: map() | nil
  defp extract_activity(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    tools =
      content
      |> Enum.filter(fn block -> is_map(block) and Map.get(block, "type") == "tool_use" end)
      |> Enum.map(fn block -> Map.get(block, "name", "unknown") end)

    if tools != [] do
      %{type: :tool_use, tools: tools}
    else
      nil
    end
  end

  defp extract_activity(%{
         "type" => "content_block_start",
         "content_block" => %{"type" => "tool_use", "name" => name}
       }) do
    %{type: :tool_use, tools: [name]}
  end

  defp extract_activity(_), do: nil

  @spec maybe_notify_activities(function() | nil, String.t(), [map()]) :: :ok
  defp maybe_notify_activities(nil, _team_name, _activities), do: :ok
  defp maybe_notify_activities(_callback, _team_name, []), do: :ok

  defp maybe_notify_activities(callback, team_name, activities) do
    Enum.each(activities, fn activity ->
      callback.(team_name, activity)
    end)

    :ok
  end

  @spec maybe_notify_tokens(function() | nil, String.t(), map(), map()) :: :ok
  defp maybe_notify_tokens(nil, _team_name, _old, _new), do: :ok
  defp maybe_notify_tokens(_callback, _team_name, same, same), do: :ok

  defp maybe_notify_tokens(callback, team_name, _old_tokens, new_tokens) do
    callback.(team_name, new_tokens)
    :ok
  end

  @spec build_team_result(String.t(), String.t() | nil, map() | nil) ::
          {:ok, TeamResult.t()} | {:error, :no_result_line}
  defp build_team_result(_team_name, _session_id, nil) do
    {:error, :no_result_line}
  end

  defp build_team_result(team_name, session_id, result_map) do
    result_text = Map.get(result_map, "result", "")
    status = detect_status(result_map, result_text)
    cost = Map.get(result_map, "total_cost_usd") || Map.get(result_map, "cost_usd")

    usage = Map.get(result_map, "usage", %{})
    input_tokens = Map.get(usage, "input_tokens", 0)
    output_tokens = Map.get(usage, "output_tokens", 0)
    cache_read_tokens = Map.get(usage, "cache_read_input_tokens", 0)
    cache_creation_tokens = Map.get(usage, "cache_creation_input_tokens", 0)

    {:ok,
     %TeamResult{
       team: team_name,
       status: status,
       result: Map.get(result_map, "result"),
       cost_usd: cost,
       input_tokens: input_tokens,
       output_tokens: output_tokens,
       cache_read_tokens: cache_read_tokens,
       cache_creation_tokens: cache_creation_tokens,
       num_turns: Map.get(result_map, "num_turns"),
       duration_ms: Map.get(result_map, "duration_ms"),
       session_id: session_id || Map.get(result_map, "session_id")
     }}
  end

  @spec detect_status(map(), String.t() | nil) :: TeamResult.status()
  defp detect_status(result_map, result_text) do
    subtype = Map.get(result_map, "subtype", "success")

    cond do
      is_binary(result_text) and String.contains?(result_text, "rate_limit_error") ->
        :rate_limited

      subtype == "success" ->
        :success

      subtype == "error_max_turns" ->
        :success

      true ->
        :error
    end
  end

  @spec write_to_log(File.io_device() | nil, binary()) :: :ok
  defp write_to_log(nil, _data), do: :ok
  defp write_to_log(device, data), do: IO.binwrite(device, data)

  @spec kill_port(port()) :: true
  defp kill_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    true
  end
end
