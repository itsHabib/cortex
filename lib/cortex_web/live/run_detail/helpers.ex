defmodule CortexWeb.RunDetail.Helpers do
  @moduledoc """
  Shared helper functions for RunDetail tab components.

  Provides formatting, status classification, and display helpers
  used across multiple tab components. Extracted from RunDetailLive
  to reduce duplication.
  """

  @stale_threshold_seconds 300

  # -- Mode helpers --

  @doc "Returns true if the run is a gossip-mode run."
  @spec gossip?(map()) :: boolean()
  def gossip?(run), do: run.mode == "gossip"

  @doc "Returns true if the run is a mesh-mode run."
  @spec mesh?(map()) :: boolean()
  def mesh?(run), do: run.mode == "mesh"

  @doc "Returns true if the run is non-DAG (gossip or mesh)."
  @spec non_dag?(map()) :: boolean()
  def non_dag?(run), do: gossip?(run) or mesh?(run)

  # -- Participant labels (mode-aware terminology) --

  @doc "Returns the participant label for the run's mode."
  @spec participant_label(map(), :singular | :plural | :lower_plural) :: String.t()
  def participant_label(run, form) do
    cond do
      gossip?(run) -> gossip_label(form)
      mesh?(run) -> mesh_label(form)
      true -> team_label(form)
    end
  end

  defp gossip_label(:singular), do: "node"
  defp gossip_label(:plural), do: "Nodes"
  defp gossip_label(:lower_plural), do: "nodes"

  defp mesh_label(:singular), do: "agent"
  defp mesh_label(:plural), do: "Agents"
  defp mesh_label(:lower_plural), do: "agents"

  defp team_label(:singular), do: "team"
  defp team_label(:plural), do: "Teams"
  defp team_label(:lower_plural), do: "teams"

  # -- Status helpers --

  @doc "Returns the display status, marking stalled teams."
  @spec display_status(map(), map(), map()) :: String.t()
  def display_status(team, last_seen, pid_status \\ %{}) do
    raw = team.status || "pending"

    if raw == "running" and team_stalled?(team, last_seen, pid_status) do
      "stalled"
    else
      raw
    end
  end

  @doc "Returns true if the team appears stalled."
  @spec team_stalled?(map(), map(), map()) :: boolean()
  def team_stalled?(team_run, last_seen, pid_status) do
    (team_run.status || "pending") == "running" and
      not pid_alive?(team_run.team_name, pid_status) and
      case Map.get(last_seen, team_run.team_name) do
        nil ->
          case team_run.started_at do
            nil -> true
            ts -> DateTime.diff(DateTime.utc_now(), ts, :second) > @stale_threshold_seconds
          end

        ts ->
          DateTime.diff(DateTime.utc_now(), ts, :second) > @stale_threshold_seconds
      end
  end

  defp pid_alive?(team_name, pid_status), do: Map.get(pid_status, team_name, false)

  @doc "Counts teams in the given status(es)."
  @spec count_by_status(list(), String.t() | list()) :: non_neg_integer()
  def count_by_status(team_runs, statuses) when is_list(statuses) do
    team_runs
    |> Enum.reject(& &1.internal)
    |> Enum.count(fn tr -> (tr.status || "pending") in statuses end)
  end

  def count_by_status(team_runs, status) do
    team_runs
    |> Enum.reject(& &1.internal)
    |> Enum.count(fn tr -> (tr.status || "pending") == status end)
  end

  @doc "Counts actively running (non-stalled) teams."
  @spec count_active_running(list(), map(), map()) :: non_neg_integer()
  def count_active_running(team_runs, last_seen, pid_status) do
    team_runs
    |> Enum.reject(& &1.internal)
    |> Enum.count(fn tr ->
      (tr.status || "pending") == "running" and not team_stalled?(tr, last_seen, pid_status)
    end)
  end

  @doc "Counts stalled teams."
  @spec count_stalled(list(), map(), map()) :: non_neg_integer()
  def count_stalled(team_runs, last_seen, pid_status) do
    team_runs
    |> Enum.reject(& &1.internal)
    |> Enum.count(fn tr -> team_stalled?(tr, last_seen, pid_status) end)
  end

  @doc "Returns sorted names of stalled teams."
  @spec stalled_team_names(list(), map(), map()) :: [String.t()]
  def stalled_team_names(team_runs, last_seen, pid_status) do
    team_runs
    |> Enum.filter(fn tr -> team_stalled?(tr, last_seen, pid_status) end)
    |> Enum.map(& &1.team_name)
    |> Enum.sort()
  end

  @doc "Returns true if any teams are stalled."
  @spec has_stalled_teams?(list(), String.t(), map(), map()) :: boolean()
  def has_stalled_teams?(team_runs, run_status, last_seen, pid_status) do
    run_status in ["running", "failed"] and
      team_runs
      |> Enum.reject(& &1.internal)
      |> Enum.any?(fn tr -> team_stalled?(tr, last_seen, pid_status) end)
  end

  # -- Formatting helpers --

  @doc "Sums a field across non-internal team runs."
  @spec sum_team_field(list(), atom()) :: number()
  def sum_team_field(team_runs, field) do
    team_runs
    |> Enum.reject(& &1.internal)
    |> Enum.map(&(Map.get(&1, field) || 0))
    |> Enum.sum()
  end

  @doc "Total input tokens including cache."
  @spec total_input(map()) :: number()
  def total_input(team_run) do
    (team_run.input_tokens || 0) + (team_run.cache_read_tokens || 0) +
      (team_run.cache_creation_tokens || 0)
  end

  @doc "Truncates text to max length with ellipsis."
  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  @doc "Formats a DateTime to HH:MM:SS."
  @spec format_now() :: String.t()
  def format_now do
    DateTime.utc_now() |> Calendar.strftime("%H:%M:%S")
  end

  @doc "Formats a DateTime or NaiveDateTime."
  @spec format_datetime(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def format_datetime(nil), do: "--"
  def format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  def format_datetime(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
  def format_datetime(_), do: "--"

  @doc "Formats a token count with K/M suffixes."
  @spec format_token_count(number() | nil) :: String.t()
  def format_token_count(nil), do: "0"
  def format_token_count(0), do: "0"
  def format_token_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def format_token_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  def format_token_count(n), do: to_string(n)

  @doc "Returns elapsed time since a DateTime."
  @spec elapsed_since(DateTime.t()) :: String.t()
  def elapsed_since(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second)
    |> max(0)
    |> format_duration_seconds()
  end

  @doc "Formats seconds into human-readable duration."
  @spec format_duration_seconds(integer()) :: String.t()
  def format_duration_seconds(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
    end
  end

  @doc "Returns a human-readable time ago string."
  @spec time_ago(DateTime.t()) :: String.t()
  def time_ago(datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      true -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m ago"
    end
  end

  @doc "Formats an ISO 8601 timestamp to HH:MM:SS."
  @spec format_iso_time(String.t() | nil) :: String.t()
  def format_iso_time(nil), do: ""

  def format_iso_time(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso_string
    end
  end

  @doc "Formats JSON value for display."
  @spec format_json_value(any()) :: String.t()
  def format_json_value(val) when is_binary(val) do
    if String.length(val) > 500, do: String.slice(val, 0, 500) <> "...", else: val
  end

  def format_json_value(val) when is_map(val) or is_list(val),
    do: Jason.encode!(val, pretty: true)

  def format_json_value(val), do: inspect(val)

  # -- Activity helpers --

  @doc "Returns the icon character for an activity kind."
  @spec activity_icon(atom()) :: String.t()
  def activity_icon(:tool), do: ">"
  def activity_icon(:progress), do: "*"
  def activity_icon(:message), do: "@"
  def activity_icon(:resume), do: "!"
  def activity_icon(_), do: "-"

  @doc "Returns the CSS class for an activity icon."
  @spec activity_icon_class(atom()) :: String.t()
  def activity_icon_class(:tool), do: "text-blue-400 font-mono"
  def activity_icon_class(:progress), do: "text-green-400 font-mono"
  def activity_icon_class(:message), do: "text-yellow-400 font-mono"
  def activity_icon_class(:resume), do: "text-purple-400 font-mono"
  def activity_icon_class(_), do: "text-gray-400 font-mono"

  # -- Log helpers --

  @doc "Returns the CSS class for a log type badge."
  @spec log_type_class(String.t() | nil) :: String.t()
  def log_type_class("assistant"), do: "bg-blue-900/50 text-blue-300"
  def log_type_class("system"), do: "bg-purple-900/50 text-purple-300"
  def log_type_class("result"), do: "bg-cyan-900/50 text-cyan-300"
  def log_type_class("error"), do: "bg-red-900/50 text-red-300"
  def log_type_class("tool_use"), do: "bg-green-900/50 text-green-300"
  def log_type_class("tool_result"), do: "bg-emerald-900/50 text-emerald-300"
  def log_type_class(_), do: "bg-gray-800/50 text-gray-400"

  # -- Diagnostics helpers --

  @doc "Returns the CSS class for a diagnostics banner."
  @spec diag_banner_class(atom()) :: String.t()
  def diag_banner_class(:in_progress), do: "bg-blue-950/30 border-blue-800 text-blue-300"
  def diag_banner_class(:completed), do: "bg-green-950/30 border-green-800 text-green-300"
  def diag_banner_class(:max_turns), do: "bg-yellow-950/30 border-yellow-800 text-yellow-300"
  def diag_banner_class(:empty_log), do: "bg-red-950/30 border-red-800 text-red-300"
  def diag_banner_class(:no_session), do: "bg-red-950/30 border-red-800 text-red-300"
  def diag_banner_class(:died_during_tool), do: "bg-red-950/30 border-red-800 text-red-300"
  def diag_banner_class(:died_after_tool_result), do: "bg-red-950/30 border-red-800 text-red-300"
  def diag_banner_class(:log_ends_without_result), do: "bg-red-950/30 border-red-800 text-red-300"

  def diag_banner_class(:error_during_execution),
    do: "bg-red-950/30 border-red-800 text-red-300"

  def diag_banner_class(_), do: "bg-gray-900 border-gray-800 text-gray-300"

  @doc "Returns the icon text for a diagnosis."
  @spec diag_icon(atom()) :: String.t()
  def diag_icon(:in_progress), do: ">>"
  def diag_icon(:completed), do: "OK"
  def diag_icon(:max_turns), do: "!!"
  def diag_icon(:empty_log), do: "XX"
  def diag_icon(:no_session), do: "XX"
  def diag_icon(:error_during_execution), do: "!!"
  def diag_icon(:died_during_tool), do: "!!"
  def diag_icon(:died_after_tool_result), do: "!!"
  def diag_icon(:log_ends_without_result), do: "!!"
  def diag_icon(_), do: "??"

  @doc "Returns the human-readable title for a diagnosis."
  @spec diag_title(atom()) :: String.t()
  def diag_title(:in_progress), do: "Still Running"
  def diag_title(:completed), do: "Completed Successfully"
  def diag_title(:max_turns), do: "Hit Max Turns"
  def diag_title(:empty_log), do: "Empty Log — Never Started"
  def diag_title(:no_session), do: "No Session — Crashed on Startup"
  def diag_title(:error_during_execution), do: "Error During Execution"
  def diag_title(:died_during_tool), do: "Died During Tool Execution"
  def diag_title(:died_after_tool_result), do: "Died After Tool Result"
  def diag_title(:log_ends_without_result), do: "Log Ends Without Result"
  def diag_title(:exited), do: "Exited with Error"
  def diag_title(_), do: "Unknown Status"

  @doc "Returns CSS class for a diagnostics entry type."
  @spec diag_entry_class(atom()) :: String.t()
  def diag_entry_class(:session_start), do: "bg-purple-900/60 text-purple-300"
  def diag_entry_class(:thinking), do: "bg-gray-800/60 text-gray-400"
  def diag_entry_class(:text), do: "bg-blue-900/60 text-blue-300"
  def diag_entry_class(:tool_use), do: "bg-green-900/60 text-green-300"
  def diag_entry_class(:tool_start), do: "bg-green-900/60 text-green-300"
  def diag_entry_class(:tool_result), do: "bg-emerald-900/60 text-emerald-300"
  def diag_entry_class(:tool_error), do: "bg-red-900/60 text-red-300"
  def diag_entry_class(:result), do: "bg-cyan-900/60 text-cyan-300"
  def diag_entry_class(:end_turn), do: "bg-gray-800/60 text-gray-400"
  def diag_entry_class(:parse_error), do: "bg-red-900/60 text-red-300"
  def diag_entry_class(_), do: "bg-gray-800/60 text-gray-400"

  @doc "Returns the human-readable label for a diagnostics entry type."
  @spec diag_entry_label(atom()) :: String.t()
  def diag_entry_label(:session_start), do: "session"
  def diag_entry_label(:thinking), do: "thinking"
  def diag_entry_label(:text), do: "text"
  def diag_entry_label(:tool_use), do: "tool"
  def diag_entry_label(:tool_start), do: "tool"
  def diag_entry_label(:tool_result), do: "result"
  def diag_entry_label(:tool_error), do: "error"
  def diag_entry_label(:result), do: "done"
  def diag_entry_label(:end_turn), do: "end"
  def diag_entry_label(:parse_error), do: "parse err"
  def diag_entry_label(type), do: Atom.to_string(type)

  # -- Job helpers --

  @doc "Returns CSS class for a job status row."
  @spec job_row_class(atom()) :: String.t()
  def job_row_class(:running), do: "bg-blue-900/20 border border-blue-800/50"
  def job_row_class(:completed), do: "bg-green-900/20 border border-green-800/50"
  def job_row_class(:failed), do: "bg-red-900/20 border border-red-800/50"
  def job_row_class(_), do: "bg-gray-900/20 border border-gray-800/50"

  @doc "Returns CSS class for a job status badge."
  @spec job_badge_class(atom()) :: String.t()
  def job_badge_class(:running), do: "bg-blue-900/40 text-blue-300"
  def job_badge_class(:completed), do: "bg-green-900/40 text-green-300"
  def job_badge_class(:failed), do: "bg-red-900/40 text-red-300"
  def job_badge_class(_), do: "bg-gray-900/40 text-gray-300"

  @doc "Returns the human-readable label for a job status."
  @spec job_label(atom()) :: String.t()
  def job_label(:running), do: "Running"
  def job_label(:completed), do: "Done"
  def job_label(:failed), do: "Failed"
  def job_label(_), do: "Unknown"

  @doc "Returns the label for a job type by team name."
  @spec job_type_label_for(String.t()) :: String.t()
  def job_type_label_for("coordinator"), do: "Coordinator"
  def job_type_label_for("summary-agent"), do: "Summary"
  def job_type_label_for("debug-agent"), do: "Debug Report"
  def job_type_label_for(name), do: name

  @doc "Extracts the target from a job role string."
  @spec job_target_from_role(String.t() | nil) :: String.t() | nil
  def job_target_from_role(nil), do: nil

  def job_target_from_role(role) do
    case String.split(role, " — ", parts: 2) do
      [_, target] -> target
      _ -> nil
    end
  end

  @doc "Returns CSS class for a job status text."
  @spec job_status_class(String.t()) :: String.t()
  def job_status_class("completed"), do: "text-green-300"
  def job_status_class("running"), do: "text-blue-300"
  def job_status_class("failed"), do: "text-red-300"
  def job_status_class(_), do: "text-gray-400"

  @doc "Formats a DateTime for job display."
  @spec format_job_datetime(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def format_job_datetime(nil), do: "—"
  def format_job_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  def format_job_datetime(%NaiveDateTime{} = ndt),
    do: Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")

  def format_job_datetime(_), do: "—"

  @doc "Formats a job duration in ms."
  @spec format_job_duration(integer() | nil) :: String.t() | nil
  def format_job_duration(nil), do: nil
  def format_job_duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"

  def format_job_duration(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1000)
    "#{mins}m #{String.pad_leading(to_string(secs), 2, "0")}s"
  end

  @doc "Returns the run job log CSS class for a log type."
  @spec run_job_log_class(String.t() | nil) :: String.t()
  def run_job_log_class("assistant"), do: "bg-blue-900/50 text-blue-300"
  def run_job_log_class("system"), do: "bg-purple-900/50 text-purple-300"
  def run_job_log_class("result"), do: "bg-cyan-900/50 text-cyan-300"
  def run_job_log_class("error"), do: "bg-red-900/50 text-red-300"
  def run_job_log_class("tool_use"), do: "bg-green-900/50 text-green-300"
  def run_job_log_class("tool_result"), do: "bg-emerald-900/50 text-emerald-300"
  def run_job_log_class(_), do: "bg-gray-800/50 text-gray-400"

  # -- Summary/filename helpers --

  @doc "Pretty-prints a summary or debug report filename."
  @spec pretty_filename(String.t()) :: String.t()
  def pretty_filename(filename) do
    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})_(.+)\.md$/, filename) do
      [_, _y, month, day, hour, min, _sec, label] ->
        month_name = month_abbrev(month)
        pretty_label = label |> String.replace("_", " ") |> String.replace("-", " ")

        pretty_label =
          pretty_label
          |> String.replace("ai summary", "AI Summary")
          |> String.replace(~r/^debug /, "Debug: ")
          |> String.replace(~r/^mesh complete$/, "Mesh Complete")
          |> String.replace(~r/^dag complete$/, "DAG Complete")

        "#{pretty_label} — #{month_name} #{day}, #{hour}:#{min}"

      _ ->
        filename
    end
  end

  defp month_abbrev("01"), do: "Jan"
  defp month_abbrev("02"), do: "Feb"
  defp month_abbrev("03"), do: "Mar"
  defp month_abbrev("04"), do: "Apr"
  defp month_abbrev("05"), do: "May"
  defp month_abbrev("06"), do: "Jun"
  defp month_abbrev("07"), do: "Jul"
  defp month_abbrev("08"), do: "Aug"
  defp month_abbrev("09"), do: "Sep"
  defp month_abbrev("10"), do: "Oct"
  defp month_abbrev("11"), do: "Nov"
  defp month_abbrev("12"), do: "Dec"
  defp month_abbrev(_), do: "?"

  # -- Gossip/Mesh config helpers --

  @doc "Parses gossip config info from a run's config_yaml."
  @spec parse_gossip_info(map()) :: map() | nil
  def parse_gossip_info(run) do
    if run.config_yaml do
      case YamlElixir.read_from_string(run.config_yaml) do
        {:ok, raw} ->
          gossip = Map.get(raw, "gossip", %{})

          %{
            topology: Map.get(gossip, "topology", "random"),
            rounds: Map.get(gossip, "rounds", 5),
            exchange_interval: Map.get(gossip, "exchange_interval_seconds", 60)
          }

        _ ->
          nil
      end
    else
      nil
    end
  end

  @doc "Parses mesh config info from a run's config_yaml."
  @spec parse_mesh_info(map()) :: map() | nil
  def parse_mesh_info(run) do
    if run.config_yaml do
      case YamlElixir.read_from_string(run.config_yaml) do
        {:ok, raw} ->
          mesh = Map.get(raw, "mesh", %{})

          %{
            heartbeat: Map.get(mesh, "heartbeat_interval_seconds", 30),
            suspect_timeout: Map.get(mesh, "suspect_timeout_seconds", 90),
            dead_timeout: Map.get(mesh, "dead_timeout_seconds", 180),
            cluster_context: Map.get(raw, "cluster_context")
          }

        _ ->
          nil
      end
    else
      nil
    end
  end

  @doc "Returns a topology description string."
  @spec topology_description(String.t(), non_neg_integer()) :: String.t()
  def topology_description("full_mesh", count),
    do: "Every node shares knowledge with all #{count - 1} others each round"

  def topology_description("ring", _count),
    do: "Each node shares knowledge with its two neighbors"

  def topology_description("random", _count),
    do: "Each node shares knowledge with 2 random peers per round"

  def topology_description(other, _count),
    do: "Nodes exchange knowledge via #{other} topology"

  @doc "Returns a confidence label."
  @spec confidence_label(number()) :: String.t()
  def confidence_label(c) when c >= 0.8, do: "high confidence"
  def confidence_label(c) when c >= 0.5, do: "medium confidence"
  def confidence_label(_), do: "low confidence"

  @doc "Returns the CSS class for a confidence label."
  @spec confidence_label_class(number()) :: String.t()
  def confidence_label_class(c) when c >= 0.8, do: "text-green-400"
  def confidence_label_class(c) when c >= 0.5, do: "text-yellow-400"
  def confidence_label_class(_), do: "text-red-400"
end
