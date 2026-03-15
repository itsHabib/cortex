defmodule Cortex.Orchestration.LogParser do
  @moduledoc """
  Parses NDJSON log files from `claude -p` sessions into structured timelines.

  Each log file is a sequence of newline-delimited JSON objects produced by
  `claude --output-format stream-json`. This module extracts a human-readable
  timeline of events plus a diagnostic summary for RCA.

  ## Usage

      {:ok, report} = LogParser.parse("/path/to/team.log")
      report.session_id       # => "91d764d7-..."
      report.entries          # => [%{type: :tool_use, tool: "Read", ...}, ...]
      report.diagnosis        # => :log_ends_without_result
      report.last_activity_at # => ~U[2026-03-15 16:44:12Z]

  """

  @type entry :: %{
          index: non_neg_integer(),
          type: atom(),
          detail: String.t(),
          timestamp: String.t() | nil,
          tools: [String.t()]
        }

  @type report :: %{
          session_id: String.t() | nil,
          model: String.t() | nil,
          entries: [entry()],
          has_result: boolean(),
          exit_subtype: String.t() | nil,
          result_text: String.t() | nil,
          cost_usd: float() | nil,
          total_input_tokens: non_neg_integer(),
          total_output_tokens: non_neg_integer(),
          diagnosis: atom(),
          diagnosis_detail: String.t(),
          last_activity_at: String.t() | nil,
          line_count: non_neg_integer()
        }

  @doc """
  Parses an NDJSON log file and returns a structured report.

  Returns `{:ok, report}` on success, `{:error, reason}` on failure.
  """
  @spec parse(String.t()) :: {:ok, report()} | {:error, term()}
  def parse(log_path) do
    case File.read(log_path) do
      {:ok, content} ->
        {:ok, parse_content(content)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses raw NDJSON content string into a report (for testing without files).
  """
  @spec parse_content(String.t()) :: report()
  def parse_content(content) do
    lines =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {entries, state} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], initial_state()}, fn {line, idx}, {entries, state} ->
        case Jason.decode(line) do
          {:ok, parsed} ->
            {new_entries, new_state} = process_line(parsed, idx, state)

            # Fill in missing timestamps with last known timestamp
            filled_entries =
              Enum.map(new_entries, fn entry ->
                if entry.timestamp,
                  do: entry,
                  else: %{entry | timestamp: new_state.last_timestamp}
              end)

            {entries ++ filled_entries, new_state}

          {:error, _} ->
            entry = %{
              index: idx,
              type: :parse_error,
              detail: truncate(line, 100),
              timestamp: state.last_timestamp,
              tools: []
            }

            {entries ++ [entry], state}
        end
      end)

    diagnosis = diagnose(state, entries)

    %{
      session_id: state.session_id,
      model: state.model,
      entries: entries,
      has_result: state.has_result,
      exit_subtype: state.exit_subtype,
      result_text: state.result_text,
      cost_usd: state.cost_usd,
      total_input_tokens: state.total_input_tokens,
      total_output_tokens: state.total_output_tokens,
      diagnosis: diagnosis.code,
      diagnosis_detail: diagnosis.detail,
      last_activity_at: state.last_timestamp,
      line_count: length(lines)
    }
  end

  @doc """
  Builds a context string summarizing what a previous session accomplished,
  suitable for injecting into a restart prompt.

  Extracts tool calls, files read/written, and the last action from the report.
  """
  @spec build_restart_context(report()) :: String.t()
  def build_restart_context(report) do
    lines = ["## Previous Session Context", ""]

    lines =
      if report.session_id do
        lines ++
          ["Previous session `#{report.session_id}` has expired and cannot be resumed.", ""]
      else
        lines ++ ["Previous session data was recovered from logs.", ""]
      end

    # Summarize what tools were used and what files were touched
    tool_actions =
      report.entries
      |> Enum.filter(&(&1.type in [:tool_use, :tool_start]))
      |> Enum.map(fn entry ->
        tool = List.first(entry.tools) || "unknown"
        "- #{tool}: #{entry.detail}"
      end)

    lines =
      if tool_actions != [] do
        lines ++
          ["### Actions taken in previous session:"] ++
          tool_actions ++ [""]
      else
        lines ++ ["No tool actions were recorded in the previous session.", ""]
      end

    # Add the diagnosis
    lines =
      lines ++
        ["### How the previous session ended:", "#{report.diagnosis_detail}", ""]

    # Add any result text
    lines =
      if report.result_text do
        lines ++ ["### Last output:", report.result_text, ""]
      else
        lines
      end

    lines =
      lines ++
        [
          "### Instructions:",
          "Continue the work from where the previous session left off.",
          "Check what files already exist before recreating them.",
          "Do NOT redo work that was already completed.",
          ""
        ]

    Enum.join(lines, "\n")
  end

  # -- Internal State --

  defp initial_state do
    %{
      session_id: nil,
      model: nil,
      has_result: false,
      exit_subtype: nil,
      result_text: nil,
      cost_usd: nil,
      total_input_tokens: 0,
      total_output_tokens: 0,
      last_timestamp: nil,
      last_tool: nil,
      last_text: nil,
      last_type: nil
    }
  end

  # -- Line Processing --

  defp process_line(%{"type" => "system", "subtype" => "init"} = parsed, idx, state) do
    session_id = Map.get(parsed, "session_id")
    timestamp = extract_timestamp(parsed)

    entry = %{
      index: idx,
      type: :session_start,
      detail: "session started (#{short_id(session_id)})",
      timestamp: timestamp,
      tools: []
    }

    {[entry],
     %{state | session_id: session_id, last_timestamp: timestamp || state.last_timestamp}}
  end

  defp process_line(%{"type" => "assistant", "message" => msg}, idx, state) do
    content = Map.get(msg, "content", [])
    model = Map.get(msg, "model")
    stop_reason = Map.get(msg, "stop_reason")
    timestamp = extract_timestamp(msg)

    # Extract usage from this message
    usage = Map.get(msg, "usage", %{})
    input_tokens = Map.get(usage, "input_tokens", 0)
    output_tokens = Map.get(usage, "output_tokens", 0)

    tools =
      content
      |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "tool_use"))
      |> Enum.map(fn block ->
        name = Map.get(block, "name", "unknown")
        input = Map.get(block, "input", %{})
        {name, summarize_tool_input(name, input)}
      end)

    thinking =
      content
      |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "thinking"))
      |> Enum.map_join(" ", &Map.get(&1, "thinking", ""))

    text =
      content
      |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "text"))
      |> Enum.map_join(" ", &Map.get(&1, "text", ""))

    entries = []

    # Add thinking entry if present
    entries =
      if thinking != "" do
        entries ++
          [
            %{
              index: idx,
              type: :thinking,
              detail: truncate(thinking, 150),
              timestamp: timestamp,
              tools: []
            }
          ]
      else
        entries
      end

    # Add text entry if present
    entries =
      if text != "" do
        entries ++
          [
            %{
              index: idx,
              type: :text,
              detail: truncate(text, 200),
              timestamp: timestamp,
              tools: []
            }
          ]
      else
        entries
      end

    # Add tool entries
    entries =
      entries ++
        Enum.map(tools, fn {name, summary} ->
          %{
            index: idx,
            type: :tool_use,
            detail: summary,
            timestamp: timestamp,
            tools: [name]
          }
        end)

    # Add stop reason if end_turn
    entries =
      if stop_reason == "end_turn" and tools == [] do
        entries ++
          [
            %{
              index: idx,
              type: :end_turn,
              detail: "agent finished responding",
              timestamp: timestamp,
              tools: []
            }
          ]
      else
        entries
      end

    new_state = %{
      state
      | model: model || state.model,
        last_timestamp: timestamp || state.last_timestamp,
        last_tool: if(tools != [], do: elem(hd(tools), 0), else: state.last_tool),
        last_text: if(text != "", do: truncate(text, 200), else: state.last_text),
        last_type: :assistant,
        total_input_tokens: state.total_input_tokens + input_tokens,
        total_output_tokens: state.total_output_tokens + output_tokens
    }

    {entries, new_state}
  end

  defp process_line(%{"type" => "user", "message" => msg}, idx, state) do
    content = Map.get(msg, "content", [])
    timestamp = extract_timestamp(msg)

    tool_results =
      if is_list(content) do
        content
        |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == "tool_result"))
        |> Enum.map(fn tr ->
          is_error = Map.get(tr, "is_error", false)
          result_content = Map.get(tr, "content", "")

          result_text =
            cond do
              is_binary(result_content) ->
                result_content

              is_list(result_content) ->
                Enum.map_join(result_content, " ", &Map.get(&1, "text", ""))

              true ->
                inspect(result_content)
            end

          {is_error, truncate(result_text, 150)}
        end)
      else
        []
      end

    entries =
      Enum.map(tool_results, fn {is_error, result_text} ->
        %{
          index: idx,
          type: if(is_error, do: :tool_error, else: :tool_result),
          detail: result_text,
          timestamp: timestamp,
          tools: []
        }
      end)

    new_state = %{
      state
      | last_timestamp: timestamp || state.last_timestamp,
        last_type: :user
    }

    {entries, new_state}
  end

  defp process_line(%{"type" => "result"} = parsed, idx, state) do
    subtype = Map.get(parsed, "subtype", "success")
    result_text = Map.get(parsed, "result", "")
    cost = Map.get(parsed, "total_cost_usd") || Map.get(parsed, "cost_usd")
    session_id = Map.get(parsed, "session_id")
    timestamp = extract_timestamp(parsed) || state.last_timestamp

    usage = Map.get(parsed, "usage", %{})
    input_tokens = Map.get(usage, "input_tokens", 0)
    output_tokens = Map.get(usage, "output_tokens", 0)

    detail =
      case subtype do
        "success" -> "completed successfully"
        "error_max_turns" -> "hit max turns limit"
        other -> "exited: #{other}"
      end

    detail =
      if cost, do: "#{detail} ($#{Float.round(cost * 1.0, 4)})", else: detail

    entry = %{
      index: idx,
      type: :result,
      detail: detail,
      timestamp: timestamp,
      tools: []
    }

    new_state = %{
      state
      | has_result: true,
        exit_subtype: subtype,
        result_text: truncate(to_string(result_text), 500),
        cost_usd: cost,
        session_id: session_id || state.session_id,
        total_input_tokens: state.total_input_tokens + input_tokens,
        total_output_tokens: state.total_output_tokens + output_tokens
    }

    {[entry], new_state}
  end

  defp process_line(
         %{"type" => "content_block_start", "content_block" => block} = parsed,
         idx,
         state
       ) do
    if Map.get(block, "type") == "tool_use" do
      name = Map.get(block, "name", "unknown")
      timestamp = extract_timestamp(parsed) || state.last_timestamp

      entry = %{
        index: idx,
        type: :tool_start,
        detail: name,
        timestamp: timestamp,
        tools: [name]
      }

      {[entry], %{state | last_tool: name}}
    else
      {[], state}
    end
  end

  defp process_line(%{"type" => "system", "subtype" => subtype} = parsed, idx, state)
       when subtype in ["task_progress", "task_notification"] do
    timestamp = extract_timestamp(parsed) || state.last_timestamp
    description = Map.get(parsed, "description", subtype)
    task_status = Map.get(parsed, "status")
    last_tool = Map.get(parsed, "last_tool_name")

    detail =
      case task_status do
        "completed" -> "subagent done: #{truncate(description, 80)}"
        _ -> "subagent: #{truncate(description, 80)}"
      end

    tools = if last_tool, do: [last_tool], else: []

    entry = %{
      index: idx,
      type: if(task_status == "completed", do: :tool_result, else: :tool_use),
      detail: detail,
      timestamp: timestamp,
      tools: tools
    }

    {[entry], %{state | last_timestamp: timestamp || state.last_timestamp}}
  end

  defp process_line(_parsed, _idx, state) do
    # content_block_delta, content_block_stop, etc. — skip
    {[], state}
  end

  # -- Diagnosis --

  defp diagnose(state, entries) do
    cond do
      state.has_result and state.exit_subtype == "success" ->
        %{code: :completed, detail: "Session completed successfully"}

      state.has_result and state.exit_subtype == "error_max_turns" ->
        %{code: :max_turns, detail: "Hit max turns limit"}

      state.has_result and state.exit_subtype == "error_during_execution" ->
        error_detail = extract_error_detail(state.result_text)
        %{code: :error_during_execution, detail: "Error during execution: #{error_detail}"}

      state.has_result ->
        error_detail = extract_error_detail(state.result_text)

        detail =
          if error_detail != "" do
            "Exited (#{state.exit_subtype}): #{error_detail}"
          else
            "Exited with subtype: #{state.exit_subtype}"
          end

        %{code: :exited, detail: detail}

      entries == [] ->
        %{code: :empty_log, detail: "Log file is empty — process may have never started"}

      state.session_id == nil ->
        %{code: :no_session, detail: "No session init found — process crashed on startup"}

      state.last_type == :user ->
        %{
          code: :died_after_tool_result,
          detail: "Log ends after receiving a tool result — process died before next response"
        }

      state.last_tool != nil ->
        %{
          code: :died_during_tool,
          detail:
            "Log ends after calling #{state.last_tool} — process died or was killed mid-execution"
        }

      true ->
        %{
          code: :log_ends_without_result,
          detail: "Log ends without a result line — process exited without completing"
        }
    end
  end

  defp extract_error_detail(nil), do: ""

  defp extract_error_detail(text) when is_binary(text) do
    # Try to pull a meaningful error message from result text
    cond do
      String.contains?(text, "conversation not found") ->
        "session expired (conversation not found)"

      String.contains?(text, "rate_limit_error") ->
        "rate limited (429)"

      String.contains?(text, "overloaded_error") ->
        "API overloaded"

      String.contains?(text, "authentication_error") ->
        "authentication failed"

      String.length(text) > 0 ->
        text |> String.split("\n") |> hd() |> truncate(150)

      true ->
        ""
    end
  end

  # -- Helpers --

  defp summarize_tool_input("Read", input) do
    path = Map.get(input, "file_path", "?")
    "Read #{shorten_path(path)}"
  end

  defp summarize_tool_input("Write", input) do
    path = Map.get(input, "file_path", "?")
    "Write #{shorten_path(path)}"
  end

  defp summarize_tool_input("Edit", input) do
    path = Map.get(input, "file_path", "?")
    "Edit #{shorten_path(path)}"
  end

  defp summarize_tool_input("Bash", input) do
    cmd = Map.get(input, "command", "?")
    desc = Map.get(input, "description")

    if desc do
      "Bash: #{truncate(desc, 80)}"
    else
      "Bash: #{truncate(cmd, 80)}"
    end
  end

  defp summarize_tool_input("Grep", input) do
    pattern = Map.get(input, "pattern", "?")
    "Grep: #{truncate(pattern, 60)}"
  end

  defp summarize_tool_input("Glob", input) do
    pattern = Map.get(input, "pattern", "?")
    "Glob: #{truncate(pattern, 60)}"
  end

  defp summarize_tool_input("Task", input) do
    desc = Map.get(input, "description", "?")
    "Task: #{truncate(desc, 80)}"
  end

  defp summarize_tool_input("TeamCreate", input) do
    name = Map.get(input, "name", "?")
    "TeamCreate: #{name}"
  end

  defp summarize_tool_input("SendMessage", input) do
    to = Map.get(input, "to", "?")
    "SendMessage to #{to}"
  end

  defp summarize_tool_input(name, _input), do: name

  defp extract_timestamp(%{"created" => ts}) when is_number(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp extract_timestamp(_), do: nil

  defp short_id(nil), do: "?"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 12) <> "..."
  defp short_id(id), do: id

  defp shorten_path(path) do
    parts = String.split(path, "/")

    if length(parts) > 3 do
      ".../" <> Enum.join(Enum.take(parts, -2), "/")
    else
      path
    end
  end

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp truncate(other, max), do: truncate(inspect(other), max)
end
