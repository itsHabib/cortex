defmodule Mix.Tasks.Cortex.Run do
  @shortdoc "Run a Cortex orchestration (DAG, gossip, or mesh mode)"

  @moduledoc """
  Runs a multi-agent orchestration defined in a YAML config file.

  Automatically detects the mode from the config:
  - `mode: gossip` → gossip exploration with peer agents
  - `mode: mesh` → autonomous mesh agents with optional messaging
  - Default (no mode) → DAG orchestration with tiered teams

  ## Usage

      mix cortex.run <config_path> [options]

  ## Options

    * `--dry-run` - Show execution plan without running
    * `--continue-on-error` - Continue to next tier even if a team fails (DAG mode)
    * `--workspace` - Directory for .cortex/ workspace (default: current dir)

  ## Examples

      mix cortex.run orchestra.yaml
      mix cortex.run gossip.yaml --dry-run
      mix cortex.run mesh.yaml --dry-run
      mix cortex.run orchestra.yaml --continue-on-error --workspace /tmp/run

  """

  use Mix.Task

  alias Cortex.Gossip.SessionRunner
  alias Cortex.Mesh.SessionRunner, as: MeshSessionRunner
  alias Cortex.Orchestration.Runner
  alias Cortex.Orchestration.Summary

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [dry_run: :boolean, continue_on_error: :boolean, workspace: :string],
        aliases: [d: :dry_run, c: :continue_on_error, w: :workspace]
      )

    Mix.Task.run("app.start")

    config_path = List.first(positional) || raise_usage()

    runner_opts = [
      dry_run: Keyword.get(opts, :dry_run, false),
      continue_on_error: Keyword.get(opts, :continue_on_error, false),
      workspace_path: Keyword.get(opts, :workspace, "."),
      coordinator: true
    ]

    mode = detect_mode(config_path)

    case mode do
      :gossip -> run_gossip(config_path, runner_opts)
      :mesh -> run_mesh(config_path, runner_opts)
      :dag -> run_dag(config_path, runner_opts)
    end
  end

  # -- Mode Detection ----------------------------------------------------------

  @spec detect_mode(String.t()) :: :gossip | :mesh | :dag
  defp detect_mode(config_path) do
    case YamlElixir.read_from_file(config_path) do
      {:ok, %{"mode" => "gossip"}} -> :gossip
      {:ok, %{"mode" => "mesh"}} -> :mesh
      _ -> :dag
    end
  end

  # -- Mesh Mode ---------------------------------------------------------------

  defp run_mesh(config_path, opts) do
    Mix.shell().info("\n=> Cortex Mesh Engine\n")

    case MeshSessionRunner.run(config_path, opts) do
      {:ok, %{status: :dry_run} = plan} ->
        Mix.shell().info(format_mesh_dry_run(plan))

      {:ok, summary} ->
        Mix.shell().info(format_mesh_summary(summary))

      {:error, reasons} when is_list(reasons) ->
        Mix.shell().error("Mesh orchestration failed:")

        Enum.each(reasons, fn reason ->
          Mix.shell().error("  - #{reason}")
        end)

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Mesh orchestration failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # -- Gossip Mode -------------------------------------------------------------

  defp run_gossip(config_path, opts) do
    Mix.shell().info("\n=> Cortex Gossip Engine\n")

    case SessionRunner.run(config_path, opts) do
      {:ok, %{status: :dry_run} = plan} ->
        Mix.shell().info(format_gossip_dry_run(plan))

      {:ok, summary} ->
        Mix.shell().info(format_gossip_summary(summary))

      {:error, reasons} when is_list(reasons) ->
        Mix.shell().error("Gossip orchestration failed:")

        Enum.each(reasons, fn reason ->
          Mix.shell().error("  - #{reason}")
        end)

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Gossip orchestration failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # -- DAG Mode ----------------------------------------------------------------

  defp run_dag(config_path, opts) do
    Mix.shell().info("\n=> Cortex Orchestration Engine\n")

    case Runner.run(config_path, opts) do
      {:ok, %{status: :dry_run} = plan} ->
        Mix.shell().info(format_dry_run(plan))

      {:ok, summary} ->
        Mix.shell().info(format_summary(summary))

      {:error, {:tier_failed, tier_index, failures}} ->
        Mix.shell().error(
          "Orchestration failed at tier #{tier_index}: #{Enum.join(failures, ", ")}"
        )

        exit({:shutdown, 1})

      {:error, reasons} when is_list(reasons) ->
        Mix.shell().error("Orchestration failed:")

        Enum.each(reasons, fn reason ->
          Mix.shell().error("  - #{reason}")
        end)

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Orchestration failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # -- Usage -------------------------------------------------------------------

  @spec raise_usage() :: no_return()
  defp raise_usage do
    Mix.raise(
      "Usage: mix cortex.run <config_path> [--dry-run] [--continue-on-error] [--workspace DIR]"
    )
  end

  # -- DAG Formatting ----------------------------------------------------------

  @spec format_dry_run(map()) :: String.t()
  defp format_dry_run(plan) do
    tier_lines =
      Enum.map(plan.tiers, fn tier ->
        team_names = Enum.map(tier.teams, & &1.name)

        team_details =
          Enum.map(tier.teams, fn t ->
            "      - #{t.name} (#{t.role}, model: #{t.model})"
          end)

        ["    Tier #{tier.tier}:  #{Enum.join(team_names, ", ")}" | team_details]
      end)
      |> List.flatten()

    lines =
      [
        "DRY RUN -- No agents will be spawned",
        "",
        "  Project: #{plan.project}",
        "  Teams:   #{plan.total_teams}",
        "  Tiers:   #{length(plan.tiers)}",
        ""
      ] ++ tier_lines

    Enum.join(lines, "\n")
  end

  @spec format_summary(map()) :: String.t()
  defp format_summary(summary) do
    status_label = if summary.status == :complete, do: "COMPLETE", else: "FAILED"

    wall_clock =
      if Map.has_key?(summary, :wall_clock_ms),
        do: Summary.format_duration(summary.wall_clock_ms),
        else: "--"

    lines =
      [
        summary.summary,
        "",
        "  Wall clock: #{wall_clock}",
        "  Status:     #{status_label}"
      ]

    Enum.join(lines, "\n")
  end

  # -- Gossip Formatting -------------------------------------------------------

  @spec format_gossip_dry_run(map()) :: String.t()
  defp format_gossip_dry_run(plan) do
    agent_lines =
      Enum.map(plan.agents, fn a ->
        "    - #{a.name} (topic: #{a.topic}, model: #{a.model})"
      end)

    lines =
      [
        "DRY RUN (gossip mode) -- No agents will be spawned",
        "",
        "  Project:    #{plan.project}",
        "  Agents:     #{plan.total_agents}",
        "  Rounds:     #{plan.gossip_rounds}",
        "  Topology:   #{plan.topology}",
        "  Interval:   #{plan.exchange_interval}s",
        ""
      ] ++ agent_lines

    Enum.join(lines, "\n")
  end

  @spec format_gossip_summary(map()) :: String.t()
  defp format_gossip_summary(summary) do
    status_label =
      case summary.status do
        :complete -> "COMPLETE"
        :partial -> "PARTIAL"
        _ -> "FAILED"
      end

    duration = format_duration(summary.total_duration_ms)

    agent_lines =
      Enum.map(summary.agents, fn {name, info} ->
        cost = Map.get(info, :cost_usd) || 0.0
        "    - #{name}: #{info.status} ($#{:erlang.float_to_binary(cost, decimals: 4)})"
      end)

    knowledge = summary.knowledge

    topic_lines =
      Enum.map(knowledge.by_topic, fn {topic, count} ->
        "    - #{topic}: #{count} entries"
      end)

    lines =
      [
        "Gossip Exploration: #{summary.project}",
        "",
        "  Status:     #{status_label}",
        "  Duration:   #{duration}",
        "  Agents:     #{summary.total_agents}",
        "  Rounds:     #{summary.gossip_rounds}",
        "  Topology:   #{summary.topology}",
        "  Total cost: $#{:erlang.float_to_binary(summary.total_cost, decimals: 4)}",
        "",
        "  Agent Results:"
      ] ++
        agent_lines ++
        [
          "",
          "  Knowledge Collected: #{knowledge.total_entries} entries"
        ] ++ topic_lines

    Enum.join(lines, "\n")
  end

  defp format_duration(nil), do: "--"

  defp format_duration(ms) when is_number(ms) do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    if minutes > 0 do
      "#{minutes}m #{remaining_seconds}s"
    else
      "#{remaining_seconds}s"
    end
  end

  # -- Mesh Formatting ---------------------------------------------------------

  @spec format_mesh_dry_run(map()) :: String.t()
  defp format_mesh_dry_run(plan) do
    agent_lines =
      Enum.map(plan.agents, fn a ->
        "    - #{a.name} (role: #{a.role}, model: #{a.model})"
      end)

    lines =
      [
        "DRY RUN (mesh mode) -- No agents will be spawned",
        "",
        "  Project:           #{plan.project}",
        "  Agents:            #{plan.total_agents}",
        "  Heartbeat:         #{plan.heartbeat_interval}s",
        "  Suspect timeout:   #{plan.suspect_timeout}s",
        "  Dead timeout:      #{plan.dead_timeout}s",
        ""
      ] ++ agent_lines

    Enum.join(lines, "\n")
  end

  @spec format_mesh_summary(map()) :: String.t()
  defp format_mesh_summary(summary) do
    status_label =
      case summary.status do
        :complete -> "COMPLETE"
        :partial -> "PARTIAL"
        _ -> "FAILED"
      end

    duration = format_duration(summary.total_duration_ms)

    agent_lines =
      Enum.map(summary.agents, fn {name, info} ->
        cost = Map.get(info, :cost_usd) || 0.0
        "    - #{name}: #{info.status} ($#{:erlang.float_to_binary(cost, decimals: 4)})"
      end)

    lines =
      [
        "Mesh Session: #{summary.project}",
        "",
        "  Status:     #{status_label}",
        "  Duration:   #{duration}",
        "  Agents:     #{summary.total_agents}",
        "  Total cost: $#{:erlang.float_to_binary(summary.total_cost, decimals: 4)}",
        "",
        "  Agent Results:"
      ] ++ agent_lines

    Enum.join(lines, "\n")
  end
end
