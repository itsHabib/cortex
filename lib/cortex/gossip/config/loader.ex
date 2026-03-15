defmodule Cortex.Gossip.Config.Loader do
  @moduledoc """
  Loads and parses gossip YAML config files into validated `Gossip.Config` structs.

  Handles `mode: gossip` YAML files with flat agent lists, gossip settings,
  and optional seed knowledge. Returns validated config or error list.

  ## Examples

      iex> Loader.load("path/to/gossip.yaml")
      {:ok, %Gossip.Config{}}

      iex> Loader.load_string("name: test\\nmode: gossip\\nagents: []")
      {:error, ["agents list cannot be empty"]}

  """

  alias Cortex.Gossip.Config, as: GossipConfig
  alias Cortex.Gossip.Config.{Agent, GossipSettings, SeedKnowledge}
  alias Cortex.Orchestration.Config.Defaults

  @doc """
  Loads a gossip config from a YAML file path.

  Returns `{:ok, config}` on success or `{:error, errors}` on failure.
  """
  @spec load(String.t()) :: {:ok, GossipConfig.t()} | {:error, [String.t()]}
  def load(path) when is_binary(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, raw} ->
        build_and_validate(raw)

      {:error, %YamlElixir.FileNotFoundError{}} ->
        {:error, ["file not found: #{path}"]}

      {:error, reason} ->
        {:error, ["failed to parse YAML: #{inspect(reason)}"]}
    end
  end

  @doc """
  Loads a gossip config from a YAML string.

  Useful for testing without file I/O.
  """
  @spec load_string(String.t()) :: {:ok, GossipConfig.t()} | {:error, [String.t()]}
  def load_string(yaml_string) when is_binary(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, raw} ->
        build_and_validate(raw)

      {:error, reason} ->
        {:error, ["failed to parse YAML: #{inspect(reason)}"]}
    end
  end

  # --- Private ---

  @spec build_and_validate(map()) :: {:ok, GossipConfig.t()} | {:error, [String.t()]}
  defp build_and_validate(raw) when is_map(raw) do
    config = build_config(raw)
    validate(config)
  end

  defp build_and_validate(_raw) do
    {:error, ["YAML root must be a map"]}
  end

  @spec build_config(map()) :: GossipConfig.t()
  defp build_config(raw) do
    %GossipConfig{
      name: Map.get(raw, "name", ""),
      cluster_context: Map.get(raw, "cluster_context"),
      defaults: build_defaults(Map.get(raw, "defaults")),
      gossip: build_gossip_settings(Map.get(raw, "gossip")),
      agents: build_agents(Map.get(raw, "agents")),
      seed_knowledge: build_seed_knowledge(Map.get(raw, "seed_knowledge"))
    }
  end

  defp build_defaults(nil), do: %Defaults{}

  defp build_defaults(raw) when is_map(raw) do
    %Defaults{
      model: Map.get(raw, "model", "sonnet"),
      max_turns: Map.get(raw, "max_turns", 200),
      permission_mode: Map.get(raw, "permission_mode", "acceptEdits"),
      timeout_minutes: Map.get(raw, "timeout_minutes", 30)
    }
  end

  defp build_defaults(_), do: %Defaults{}

  defp build_gossip_settings(nil), do: %GossipSettings{}

  defp build_gossip_settings(raw) when is_map(raw) do
    %GossipSettings{
      rounds: Map.get(raw, "rounds", 5),
      topology: parse_topology(Map.get(raw, "topology", "random")),
      exchange_interval_seconds: Map.get(raw, "exchange_interval_seconds", 60)
    }
  end

  defp build_gossip_settings(_), do: %GossipSettings{}

  defp parse_topology("full_mesh"), do: :full_mesh
  defp parse_topology("ring"), do: :ring
  defp parse_topology("random"), do: :random
  defp parse_topology(_), do: :random

  defp build_agents(nil), do: []
  defp build_agents(agents) when is_list(agents), do: Enum.map(agents, &build_agent/1)
  defp build_agents(_), do: []

  defp build_agent(raw) when is_map(raw) do
    %Agent{
      name: Map.get(raw, "name", ""),
      topic: Map.get(raw, "topic", ""),
      prompt: Map.get(raw, "prompt", ""),
      model: Map.get(raw, "model")
    }
  end

  defp build_agent(_), do: %Agent{name: "", topic: "", prompt: ""}

  defp build_seed_knowledge(nil), do: []
  defp build_seed_knowledge(seeds) when is_list(seeds), do: Enum.map(seeds, &build_seed/1)
  defp build_seed_knowledge(_), do: []

  defp build_seed(raw) when is_map(raw) do
    %SeedKnowledge{
      topic: Map.get(raw, "topic", ""),
      content: Map.get(raw, "content", "")
    }
  end

  defp build_seed(_), do: %SeedKnowledge{topic: "", content: ""}

  # --- Validation ---

  @spec validate(GossipConfig.t()) :: {:ok, GossipConfig.t()} | {:error, [String.t()]}
  defp validate(config) do
    errors =
      []
      |> validate_name(config)
      |> validate_agents(config)
      |> validate_gossip_settings(config)
      |> Enum.reverse()

    case errors do
      [] -> {:ok, config}
      errors -> {:error, errors}
    end
  end

  defp validate_name(errors, %{name: name}) when is_binary(name) and name != "" do
    errors
  end

  defp validate_name(errors, _config) do
    ["project name cannot be empty" | errors]
  end

  defp validate_agents(errors, %{agents: []}) do
    ["agents list cannot be empty" | errors]
  end

  defp validate_agents(errors, %{agents: agents}) do
    agent_errors =
      agents
      |> Enum.with_index()
      |> Enum.flat_map(fn {agent, i} ->
        agent_prefix = "agent[#{i}] (#{agent.name || "unnamed"})"

        name_err =
          if agent.name == "" or is_nil(agent.name),
            do: ["#{agent_prefix}: name cannot be empty"],
            else: []

        topic_err =
          if agent.topic == "" or is_nil(agent.topic),
            do: ["#{agent_prefix}: topic cannot be empty"],
            else: []

        prompt_err =
          if agent.prompt == "" or is_nil(agent.prompt),
            do: ["#{agent_prefix}: prompt cannot be empty"],
            else: []

        name_err ++ topic_err ++ prompt_err
      end)

    # Check unique names
    names = Enum.map(agents, & &1.name) |> Enum.filter(&(&1 != ""))
    dupes = names -- Enum.uniq(names)

    dupe_errors =
      case dupes do
        [] -> []
        dupes -> ["duplicate agent names: #{Enum.join(Enum.uniq(dupes), ", ")}"]
      end

    Enum.reverse(agent_errors ++ dupe_errors) ++ errors
  end

  defp validate_gossip_settings(errors, %{gossip: settings}) do
    round_err =
      if settings.rounds < 1,
        do: ["gossip rounds must be at least 1"],
        else: []

    interval_err =
      if settings.exchange_interval_seconds < 1,
        do: ["exchange_interval_seconds must be at least 1"],
        else: []

    topo_err =
      if settings.topology in [:full_mesh, :ring, :random],
        do: [],
        else: ["invalid topology: #{inspect(settings.topology)}"]

    Enum.reverse(round_err ++ interval_err ++ topo_err) ++ errors
  end
end
