defmodule Cortex.Orchestration.Config.Validator do
  @moduledoc """
  Validates an orchestra `Config` struct for correctness.

  Produces hard errors that block execution and soft warnings that are
  returned alongside the config but do not prevent it from being used.

  ## Hard Errors

    - Non-empty project name
    - Non-empty teams list
    - Unique team names
    - Each team has a lead with a non-empty role
    - Each team has at least one task with a non-empty summary
    - `depends_on` references must exist (no dangling refs)
    - No self-references in `depends_on`
    - No dependency cycles
    - Invalid `provider` value (must be `:cli`, `:http`, or `:external`)
    - Invalid `backend` value (must be `:local`, `:docker`, or `:k8s`)
    - `provider: :http` is blocked until Provider.HTTP ships (not yet implemented)

  ## Soft Warnings

    - Team with more than 5 members
    - Task with empty details
    - Task with empty verify command
  """

  alias Cortex.Orchestration.Config

  @doc """
  Validates a `Config` struct.

  Returns `{:ok, config, warnings}` if all hard validations pass, where
  `warnings` is a list of warning strings (possibly empty).

  Returns `{:error, errors}` if any hard validation fails, where `errors`
  is a list of error strings.
  """
  @spec validate(Config.t()) :: {:ok, Config.t(), [String.t()]} | {:error, [String.t()]}
  def validate(%Config{} = config) do
    errors = collect_errors(config)

    case errors do
      [] ->
        warnings = collect_warnings(config)
        {:ok, config, warnings}

      errors ->
        {:error, errors}
    end
  end

  # --- Hard Error Collection ---

  @valid_providers [:cli, :http, :external]
  @valid_backends [:local, :docker, :k8s]

  defp collect_errors(config) do
    []
    |> validate_name(config)
    |> validate_teams_present(config)
    |> validate_unique_team_names(config)
    |> validate_team_leads(config)
    |> validate_team_tasks(config)
    |> validate_depends_on(config)
    |> validate_no_cycles(config)
    |> validate_provider_backend(config)
    |> validate_backend_requires_external(config)
    |> Enum.reverse()
  end

  defp validate_name(errors, %Config{name: name}) do
    if is_binary(name) and String.trim(name) != "" do
      errors
    else
      ["name cannot be empty" | errors]
    end
  end

  defp validate_teams_present(errors, %Config{teams: teams}) do
    if is_list(teams) and teams != [] do
      errors
    else
      ["teams list cannot be empty" | errors]
    end
  end

  defp validate_unique_team_names(errors, %Config{teams: teams}) do
    names = Enum.map(teams, & &1.name)
    duplicates = names -- Enum.uniq(names)

    case Enum.uniq(duplicates) do
      [] -> errors
      dupes -> ["duplicate team names: #{Enum.join(dupes, ", ")}" | errors]
    end
  end

  defp validate_team_leads(errors, %Config{teams: teams}) do
    Enum.reduce(teams, errors, fn team, acc ->
      cond do
        is_nil(team.lead) ->
          ["team '#{team.name}' is missing a lead" | acc]

        not is_binary(team.lead.role) or String.trim(team.lead.role) == "" ->
          ["team '#{team.name}' lead must have a non-empty role" | acc]

        true ->
          acc
      end
    end)
  end

  defp validate_team_tasks(errors, %Config{teams: teams}) do
    Enum.reduce(teams, errors, fn team, acc ->
      cond do
        not is_list(team.tasks) or Enum.empty?(team.tasks) ->
          ["team '#{team.name}' must have at least one task" | acc]

        Enum.any?(team.tasks, fn task ->
          not is_binary(task.summary) or String.trim(task.summary) == ""
        end) ->
          ["team '#{team.name}' has a task with an empty summary" | acc]

        true ->
          acc
      end
    end)
  end

  defp validate_depends_on(errors, %Config{teams: teams}) do
    known_names = MapSet.new(teams, & &1.name)

    Enum.reduce(teams, errors, fn team, acc ->
      depends = team.depends_on || []

      acc =
        if team.name in depends do
          ["team '#{team.name}' has a self-reference in depends_on" | acc]
        else
          acc
        end

      dangling = Enum.filter(depends, fn dep -> dep not in known_names end)

      case dangling do
        [] -> acc
        refs -> ["team '#{team.name}' depends on unknown teams: #{Enum.join(refs, ", ")}" | acc]
      end
    end)
  end

  defp validate_no_cycles(errors, %Config{teams: teams}) do
    # Kahn's algorithm to detect cycles
    team_names = Enum.map(teams, & &1.name)

    # Build adjacency and in-degree maps
    {adj, in_degree} =
      Enum.reduce(teams, {%{}, Map.new(team_names, fn n -> {n, 0} end)}, fn team,
                                                                            {adj_acc, deg_acc} ->
        deps = team.depends_on || []

        # For each dependency: dep -> team (dep must complete before team)
        adj_acc =
          Enum.reduce(deps, adj_acc, fn dep, a ->
            Map.update(a, dep, [team.name], fn existing -> [team.name | existing] end)
          end)

        deg_acc = Map.put(deg_acc, team.name, length(deps))

        {adj_acc, deg_acc}
      end)

    # Seed with zero in-degree nodes
    queue = for {name, 0} <- in_degree, do: name

    processed = process_queue(queue, adj, in_degree, 0)

    if processed == length(team_names) do
      errors
    else
      ["dependency cycle detected among teams" | errors]
    end
  end

  defp process_queue([], _adj, _in_degree, count), do: count

  defp process_queue([current | rest], adj, in_degree, count) do
    dependents = Map.get(adj, current, [])

    {new_queue_additions, new_in_degree} =
      Enum.reduce(dependents, {[], in_degree}, fn dep, {queue_acc, deg_acc} ->
        new_deg = Map.get(deg_acc, dep, 0) - 1
        deg_acc = Map.put(deg_acc, dep, new_deg)

        if new_deg == 0 do
          {[dep | queue_acc], deg_acc}
        else
          {queue_acc, deg_acc}
        end
      end)

    process_queue(rest ++ new_queue_additions, adj, new_in_degree, count + 1)
  end

  defp validate_provider_backend(errors, %Config{defaults: defaults, teams: teams}) do
    errors
    |> validate_single_provider(defaults.provider, "defaults")
    |> validate_single_backend(defaults.backend, "defaults")
    |> validate_external_blocked(defaults.provider, "defaults")
    |> validate_http_blocked(defaults.provider, "defaults")
    |> validate_team_provider_backends(teams)
  end

  defp validate_single_provider(errors, provider, _context)
       when provider in @valid_providers,
       do: errors

  defp validate_single_provider(errors, nil, _context), do: errors

  defp validate_single_provider(errors, provider, context) do
    valid = Enum.map_join(@valid_providers, ", ", &Atom.to_string/1)
    ["#{context}: invalid provider '#{inspect(provider)}', must be one of: #{valid}" | errors]
  end

  defp validate_single_backend(errors, backend, _context)
       when backend in @valid_backends,
       do: errors

  defp validate_single_backend(errors, nil, _context), do: errors

  defp validate_single_backend(errors, backend, context) do
    valid = Enum.map_join(@valid_backends, ", ", &Atom.to_string/1)
    ["#{context}: invalid backend '#{inspect(backend)}', must be one of: #{valid}" | errors]
  end

  defp validate_external_blocked(errors, _provider, _context), do: errors

  # TODO(Future): remove this gate when Provider.HTTP ships
  defp validate_http_blocked(errors, :http, context) do
    ["#{context}: provider 'http' is not yet implemented" | errors]
  end

  defp validate_http_blocked(errors, _provider, _context), do: errors

  defp validate_team_provider_backends(errors, teams) do
    Enum.reduce(teams, errors, fn team, acc ->
      context = "team '#{team.name}'"

      acc
      |> validate_single_provider(team.provider, context)
      |> validate_single_backend(team.backend, context)
      |> validate_external_blocked(team.provider, context)
      |> validate_http_blocked(team.provider, context)
    end)
  end

  # backend: docker/k8s requires provider: external — the CLI provider runs
  # claude as a local Erlang port, which can't work inside a container.
  defp validate_backend_requires_external(errors, %Config{defaults: defaults, teams: teams}) do
    errors =
      check_provider_backend_compat(errors, defaults.provider, defaults.backend, "defaults")

    Enum.reduce(teams, errors, fn team, acc ->
      effective_provider = team.provider || defaults.provider
      effective_backend = team.backend || defaults.backend

      check_provider_backend_compat(
        acc,
        effective_provider,
        effective_backend,
        "team '#{team.name}'"
      )
    end)
  end

  defp check_provider_backend_compat(errors, provider, backend, context)
       when backend in [:docker, :k8s] and provider != :external do
    [
      "#{context}: backend '#{backend}' requires provider 'external' (got '#{provider}')" | errors
    ]
  end

  defp check_provider_backend_compat(errors, _provider, _backend, _context), do: errors

  # --- Soft Warning Collection ---

  defp collect_warnings(%Config{defaults: defaults, teams: teams}) do
    provider_backend_warnings(defaults.provider, defaults.backend, "defaults") ++
      Enum.flat_map(teams, fn team ->
        effective_provider = team.provider || defaults.provider
        effective_backend = team.backend || defaults.backend

        provider_backend_warnings(effective_provider, effective_backend, "team '#{team.name}'") ++
          member_warnings(team) ++ task_warnings(team)
      end)
  end

  defp provider_backend_warnings(_provider, _backend, _context), do: []

  defp member_warnings(team) do
    if length(team.members) > 5 do
      ["team '#{team.name}' has #{length(team.members)} members (consider splitting)"]
    else
      []
    end
  end

  defp task_warnings(team) do
    Enum.flat_map(team.tasks, fn task ->
      details_warning =
        if is_nil(task.details) or (is_binary(task.details) and String.trim(task.details) == "") do
          ["team '#{team.name}' task '#{task.summary}' has empty details"]
        else
          []
        end

      verify_warning =
        if is_nil(task.verify) or (is_binary(task.verify) and String.trim(task.verify) == "") do
          ["team '#{team.name}' task '#{task.summary}' has empty verify"]
        else
          []
        end

      details_warning ++ verify_warning
    end)
  end
end
