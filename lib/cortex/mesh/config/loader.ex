defmodule Cortex.Mesh.Config.Loader do
  @moduledoc """
  Loads and parses mesh YAML config files into validated `Mesh.Config` structs.

  Handles `mode: mesh` YAML files with flat agent lists and mesh settings.
  Returns validated config or error list.

  ## Examples

      iex> Loader.load("path/to/mesh.yaml")
      {:ok, %Mesh.Config{}}

      iex> Loader.load_string("name: test\\nmode: mesh\\nagents: []")
      {:error, ["agents list cannot be empty"]}

  """

  alias Cortex.Mesh.Config, as: MeshConfig
  alias Cortex.Mesh.Config.{Agent, MeshSettings}
  alias Cortex.Orchestration.Config.Defaults

  @doc """
  Loads a mesh config from a YAML file path.

  Returns `{:ok, config}` on success or `{:error, errors}` on failure.
  """
  @spec load(String.t()) :: {:ok, MeshConfig.t()} | {:error, [String.t()]}
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
  Loads a mesh config from a YAML string.

  Useful for testing without file I/O.
  """
  @spec load_string(String.t()) :: {:ok, MeshConfig.t()} | {:error, [String.t()]}
  def load_string(yaml_string) when is_binary(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, raw} ->
        build_and_validate(raw)

      {:error, reason} ->
        {:error, ["failed to parse YAML: #{inspect(reason)}"]}
    end
  end

  # --- Private ---

  @spec build_and_validate(map()) :: {:ok, MeshConfig.t()} | {:error, [String.t()]}
  defp build_and_validate(raw) when is_map(raw) do
    config = build_config(raw)
    validate(config)
  end

  defp build_and_validate(_raw) do
    {:error, ["YAML root must be a map"]}
  end

  @spec build_config(map()) :: MeshConfig.t()
  defp build_config(raw) do
    %MeshConfig{
      name: Map.get(raw, "name", ""),
      cluster_context: Map.get(raw, "cluster_context"),
      defaults: build_defaults(Map.get(raw, "defaults")),
      mesh: build_mesh_settings(Map.get(raw, "mesh")),
      agents: build_agents(Map.get(raw, "agents"))
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

  defp build_mesh_settings(nil), do: %MeshSettings{}

  defp build_mesh_settings(raw) when is_map(raw) do
    %MeshSettings{
      heartbeat_interval_seconds: Map.get(raw, "heartbeat_interval_seconds", 30),
      suspect_timeout_seconds: Map.get(raw, "suspect_timeout_seconds", 90),
      dead_timeout_seconds: Map.get(raw, "dead_timeout_seconds", 180)
    }
  end

  defp build_mesh_settings(_), do: %MeshSettings{}

  defp build_agents(nil), do: []
  defp build_agents(agents) when is_list(agents), do: Enum.map(agents, &build_agent/1)
  defp build_agents(_), do: []

  defp build_agent(raw) when is_map(raw) do
    %Agent{
      name: Map.get(raw, "name", ""),
      role: Map.get(raw, "role", ""),
      prompt: Map.get(raw, "prompt", ""),
      model: Map.get(raw, "model"),
      metadata: build_metadata(Map.get(raw, "metadata"))
    }
  end

  defp build_agent(_), do: %Agent{name: "", role: "", prompt: ""}

  defp build_metadata(nil), do: %{}
  defp build_metadata(raw) when is_map(raw), do: raw
  defp build_metadata(_), do: %{}

  # --- Validation ---

  @spec validate(MeshConfig.t()) :: {:ok, MeshConfig.t()} | {:error, [String.t()]}
  defp validate(config) do
    errors =
      []
      |> validate_name(config)
      |> validate_agents(config)
      |> validate_mesh_settings(config)
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
      |> Enum.flat_map(&validate_single_agent/1)

    dupe_errors = check_duplicate_names(agents)

    Enum.reverse(agent_errors ++ dupe_errors) ++ errors
  end

  defp validate_single_agent({agent, i}) do
    prefix = "agent[#{i}] (#{agent.name || "unnamed"})"

    []
    |> check_blank(agent.name, "#{prefix}: name cannot be empty")
    |> check_blank(agent.role, "#{prefix}: role cannot be empty")
    |> check_blank(agent.prompt, "#{prefix}: prompt cannot be empty")
  end

  defp check_blank(errors, value, msg) when value in ["", nil], do: [msg | errors]
  defp check_blank(errors, _value, _msg), do: errors

  defp check_duplicate_names(agents) do
    names = agents |> Enum.map(& &1.name) |> Enum.filter(&(&1 != ""))
    dupes = names -- Enum.uniq(names)

    case dupes do
      [] -> []
      dupes -> ["duplicate agent names: #{Enum.join(Enum.uniq(dupes), ", ")}"]
    end
  end

  defp validate_mesh_settings(errors, %{mesh: settings}) do
    heartbeat_err =
      if settings.heartbeat_interval_seconds < 1,
        do: ["heartbeat_interval_seconds must be at least 1"],
        else: []

    suspect_err =
      if settings.suspect_timeout_seconds < 1,
        do: ["suspect_timeout_seconds must be at least 1"],
        else: []

    dead_err =
      if settings.dead_timeout_seconds < 1,
        do: ["dead_timeout_seconds must be at least 1"],
        else: []

    Enum.reverse(heartbeat_err ++ suspect_err ++ dead_err) ++ errors
  end
end
