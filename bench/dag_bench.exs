# DAG orchestration benchmark suite
#
# Measures DAG tier building with Kahn's algorithm at various scales,
# config loading, and validation performance.
#
# Run: mix run bench/dag_bench.exs

alias Cortex.Orchestration.DAG
alias Cortex.Orchestration.Config.Loader

defmodule DAGBenchHelper do
  @moduledoc false

  @doc """
  Generates a list of team maps forming a valid acyclic graph.

  The strategy creates `width` independent chains of `depth` length,
  plus a final team depending on the last team in each chain.
  """
  def generate_teams(count) do
    # Build a layered DAG: sqrt(count) layers, each with sqrt(count) teams
    layer_size = max(round(:math.sqrt(count)), 1)
    num_layers = max(div(count, layer_size), 1)

    teams =
      for layer <- 0..(num_layers - 1), i <- 0..(layer_size - 1) do
        team_index = layer * layer_size + i
        if team_index >= count, do: nil, else: build_team(layer, i, layer_size)
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.take(count)

    teams
  end

  defp build_team(0, i, _layer_size) do
    %{name: "team-0-#{i}", depends_on: []}
  end

  defp build_team(layer, i, layer_size) do
    # Depend on 1-2 teams from the previous layer
    dep_count = min(2, layer_size)

    deps =
      Enum.map(0..(dep_count - 1), fn d ->
        dep_i = rem(i + d, layer_size)
        "team-#{layer - 1}-#{dep_i}"
      end)
      |> Enum.uniq()

    %{name: "team-#{layer}-#{i}", depends_on: deps}
  end

  def generate_linear_chain(count) do
    Enum.map(0..(count - 1), fn i ->
      deps = if i == 0, do: [], else: ["team-#{i - 1}"]
      %{name: "team-#{i}", depends_on: deps}
    end)
  end

  def generate_wide_parallel(count) do
    Enum.map(0..(count - 1), fn i ->
      %{name: "team-#{i}", depends_on: []}
    end)
  end

  def generate_diamond(count) do
    # One root, (count - 2) middle nodes depending on root, one sink depending on all middle
    root = %{name: "root", depends_on: []}
    middle_count = max(count - 2, 0)

    middle =
      Enum.map(1..max(middle_count, 1), fn i ->
        %{name: "middle-#{i}", depends_on: ["root"]}
      end)

    sink_deps = Enum.map(middle, & &1.name)
    sink = %{name: "sink", depends_on: sink_deps}

    [root | middle] ++ [sink]
  end

  def make_yaml_config(team_count) do
    teams = generate_teams(team_count)

    team_yaml =
      Enum.map(teams, fn t ->
        deps =
          case t.depends_on do
            [] -> ""
            deps -> "\n    depends_on:\n" <> Enum.map_join(deps, "\n", &"      - #{&1}")
          end

        """
          - name: "#{t.name}"
            lead:
              role: "benchmark worker"
            tasks:
              - summary: "Do work"#{deps}
        """
      end)
      |> Enum.join("")

    """
    name: "bench-project"
    defaults:
      model: sonnet
      max_turns: 200
    teams:
    #{team_yaml}
    """
  end
end

teams_10 = DAGBenchHelper.generate_teams(10)
teams_50 = DAGBenchHelper.generate_teams(50)
teams_100 = DAGBenchHelper.generate_teams(100)

linear_20 = DAGBenchHelper.generate_linear_chain(20)
wide_20 = DAGBenchHelper.generate_wide_parallel(20)
diamond_20 = DAGBenchHelper.generate_diamond(20)

yaml_3 = DAGBenchHelper.make_yaml_config(3)
yaml_20 = DAGBenchHelper.make_yaml_config(20)
yaml_50 = DAGBenchHelper.make_yaml_config(50)

Benchee.run(
  %{
    "DAG.build_tiers (10 teams)" => fn ->
      {:ok, _tiers} = DAG.build_tiers(teams_10)
    end,
    "DAG.build_tiers (50 teams)" => fn ->
      {:ok, _tiers} = DAG.build_tiers(teams_50)
    end,
    "DAG.build_tiers (100 teams)" => fn ->
      {:ok, _tiers} = DAG.build_tiers(teams_100)
    end,
    "DAG.build_tiers linear chain (20)" => fn ->
      {:ok, _tiers} = DAG.build_tiers(linear_20)
    end,
    "DAG.build_tiers wide parallel (20)" => fn ->
      {:ok, _tiers} = DAG.build_tiers(wide_20)
    end,
    "DAG.build_tiers diamond (20)" => fn ->
      {:ok, _tiers} = DAG.build_tiers(diamond_20)
    end,
    "config load_string (3 teams)" => fn ->
      {:ok, _config, _warnings} = Loader.load_string(yaml_3)
    end,
    "config load_string (20 teams)" => fn ->
      {:ok, _config, _warnings} = Loader.load_string(yaml_20)
    end,
    "config load_string (50 teams)" => fn ->
      {:ok, _config, _warnings} = Loader.load_string(yaml_50)
    end
  },
  warmup: 1,
  time: 5,
  memory_time: 2,
  print: [benchmarking: true, configuration: true]
)
