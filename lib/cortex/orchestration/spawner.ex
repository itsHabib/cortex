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

    args = build_args(prompt, model, max_turns, permission_mode)
    command_path = resolve_command(command)
    timeout_ms = round(timeout_minutes * 60 * 1_000)

    log_device = open_log_device(log_path)

    try do
      port = open_port(command_path, args)
      timer_ref = Process.send_after(self(), {:spawner_timeout, port}, timeout_ms)

      result = collect_output(port, timer_ref, team_name, log_device)
      Process.cancel_timer(timer_ref)
      result
    after
      close_log_device(log_device)
    end
  end

  # -- Private ---------------------------------------------------------------

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

  @spec open_port(charlist(), [String.t()]) :: port()
  defp open_port(command_path, args) do
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

    Port.open(
      {:spawn_executable, ~c"/bin/sh"},
      [:binary, :exit_status, :use_stdio, {:args, ["-c", shell_cmd]}, {:env, env}]
    )
  end

  @spec open_log_device(String.t() | nil) :: File.io_device() | nil
  defp open_log_device(nil), do: nil

  defp open_log_device(path) when is_binary(path) do
    # Ensure parent directory exists
    path |> Path.dirname() |> File.mkdir_p!()

    case File.open(path, [:write, :binary]) do
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

  @spec collect_output(port(), reference(), String.t(), File.io_device() | nil) ::
          {:ok, TeamResult.t()} | {:error, term()}
  defp collect_output(port, timer_ref, team_name, log_device) do
    collect_loop(
      port,
      timer_ref,
      team_name,
      log_device,
      _buffer = "",
      _session_id = nil,
      _result_line = nil
    )
  end

  defp collect_loop(port, timer_ref, team_name, log_device, buffer, session_id, result_line) do
    receive do
      {^port, {:data, data}} ->
        write_to_log(log_device, data)
        {lines, new_buffer} = extract_lines(buffer <> data)
        {new_session_id, new_result_line} = parse_lines(lines, session_id, result_line)

        collect_loop(
          port,
          timer_ref,
          team_name,
          log_device,
          new_buffer,
          new_session_id,
          new_result_line
        )

      {^port, {:exit_status, 0}} ->
        # Process any remaining data in the buffer
        {final_session_id, final_result_line} = parse_remaining(buffer, session_id, result_line)
        build_team_result(team_name, final_session_id, final_result_line)

      {^port, {:exit_status, code}} ->
        {:error, {:exit_code, code}}

      {:spawner_timeout, ^port} ->
        kill_port(port)
        Process.cancel_timer(timer_ref)
        {:ok, %TeamResult{team: team_name, status: :timeout, session_id: session_id}}
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
          {String.t() | nil, map() | nil}
  defp parse_lines(lines, session_id, result_line) do
    Enum.reduce(lines, {session_id, result_line}, fn line, {sid, res} ->
      parse_ndjson_line(String.trim(line), sid, res)
    end)
  end

  @spec parse_remaining(String.t(), String.t() | nil, map() | nil) ::
          {String.t() | nil, map() | nil}
  defp parse_remaining("", session_id, result_line), do: {session_id, result_line}

  defp parse_remaining(buffer, session_id, result_line) do
    parse_ndjson_line(String.trim(buffer), session_id, result_line)
  end

  @spec parse_ndjson_line(String.t(), String.t() | nil, map() | nil) ::
          {String.t() | nil, map() | nil}
  defp parse_ndjson_line("", session_id, result_line), do: {session_id, result_line}

  defp parse_ndjson_line(line, session_id, result_line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result"} = parsed} ->
        {session_id, parsed}

      {:ok, %{"type" => "system", "subtype" => "init", "session_id" => sid}} ->
        {sid, result_line}

      {:ok, _other} ->
        {session_id, result_line}

      {:error, _} ->
        # Non-JSON line (e.g. stderr interleaved) — skip
        {session_id, result_line}
    end
  end

  @spec build_team_result(String.t(), String.t() | nil, map() | nil) ::
          {:ok, TeamResult.t()} | {:error, :no_result_line}
  defp build_team_result(_team_name, _session_id, nil) do
    {:error, :no_result_line}
  end

  defp build_team_result(team_name, session_id, result_map) do
    status = parse_status(Map.get(result_map, "subtype", "success"))
    cost = Map.get(result_map, "total_cost_usd") || Map.get(result_map, "cost_usd")

    {:ok,
     %TeamResult{
       team: team_name,
       status: status,
       result: Map.get(result_map, "result"),
       cost_usd: cost,
       num_turns: Map.get(result_map, "num_turns"),
       duration_ms: Map.get(result_map, "duration_ms"),
       session_id: session_id || Map.get(result_map, "session_id")
     }}
  end

  @spec parse_status(String.t()) :: TeamResult.status()
  defp parse_status("success"), do: :success
  defp parse_status("error"), do: :error
  defp parse_status(_other), do: :error

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
