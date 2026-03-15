defmodule Cortex.Orchestration.Config.Loader do
  @moduledoc """
  Loads and parses orchestra YAML config files into validated `Config` structs.

  The loader reads a YAML file (or string), converts the raw map into nested
  `Config` structs, and runs validation. It returns either a validated config
  with any soft warnings, or a list of hard errors.

  ## Examples

      iex> Loader.load("path/to/orchestra.yaml")
      {:ok, %Config{}, []}

      iex> Loader.load_string("name: test\\nteams: []")
      {:error, ["teams list cannot be empty"]}

  """

  alias Cortex.Orchestration.Config
  alias Cortex.Orchestration.Config.{Defaults, Lead, Member, Task, Team}
  alias Cortex.Orchestration.Config.Validator

  @doc """
  Loads an orchestra config from a YAML file path.

  Reads the file, parses YAML, converts to structs, and validates.

  Returns `{:ok, config, warnings}` on success or `{:error, errors}` on failure.
  """
  @spec load(String.t()) :: {:ok, Config.t(), [String.t()]} | {:error, [String.t()]}
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
  Loads an orchestra config from a YAML string.

  Parses the string as YAML, converts to structs, and validates.
  Useful for testing without file I/O.

  Returns `{:ok, config, warnings}` on success or `{:error, errors}` on failure.
  """
  @spec load_string(String.t()) :: {:ok, Config.t(), [String.t()]} | {:error, [String.t()]}
  def load_string(yaml_string) when is_binary(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, raw} ->
        build_and_validate(raw)

      {:error, reason} ->
        {:error, ["failed to parse YAML: #{inspect(reason)}"]}
    end
  end

  # --- Private ---

  defp build_and_validate(raw) when is_map(raw) do
    config = build_config(raw)
    Validator.validate(config)
  end

  defp build_and_validate(_raw) do
    {:error, ["YAML root must be a map"]}
  end

  defp build_config(raw) do
    %Config{
      name: Map.get(raw, "name", ""),
      workspace_path: Map.get(raw, "workspace_path"),
      defaults: build_defaults(Map.get(raw, "defaults")),
      teams: build_teams(Map.get(raw, "teams"))
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

  defp build_teams(nil), do: []
  defp build_teams(teams) when is_list(teams), do: Enum.map(teams, &build_team/1)
  defp build_teams(_), do: []

  defp build_team(raw) when is_map(raw) do
    %Team{
      name: Map.get(raw, "name", ""),
      lead: build_lead(Map.get(raw, "lead")),
      members: build_members(Map.get(raw, "members")),
      tasks: build_tasks(Map.get(raw, "tasks")),
      depends_on: Map.get(raw, "depends_on") || [],
      context: Map.get(raw, "context")
    }
  end

  defp build_team(_), do: %Team{name: "", lead: %Lead{role: ""}, tasks: []}

  defp build_lead(nil), do: %Lead{role: ""}

  defp build_lead(raw) when is_map(raw) do
    %Lead{
      role: Map.get(raw, "role", ""),
      model: Map.get(raw, "model")
    }
  end

  defp build_lead(_), do: %Lead{role: ""}

  defp build_members(nil), do: []
  defp build_members(members) when is_list(members), do: Enum.map(members, &build_member/1)
  defp build_members(_), do: []

  defp build_member(raw) when is_map(raw) do
    %Member{
      role: Map.get(raw, "role", ""),
      focus: Map.get(raw, "focus")
    }
  end

  defp build_member(_), do: %Member{role: ""}

  defp build_tasks(nil), do: []
  defp build_tasks(tasks) when is_list(tasks), do: Enum.map(tasks, &build_task/1)
  defp build_tasks(_), do: []

  defp build_task(raw) when is_map(raw) do
    %Task{
      summary: Map.get(raw, "summary", ""),
      details: Map.get(raw, "details"),
      deliverables: Map.get(raw, "deliverables") || [],
      verify: Map.get(raw, "verify")
    }
  end

  defp build_task(_), do: %Task{summary: ""}
end
