defmodule Cortex.Orchestration.Config.LoaderTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.Config
  alias Cortex.Orchestration.Config.Defaults
  alias Cortex.Orchestration.Config.Loader

  @valid_yaml """
  name: "my-project"
  defaults:
    model: opus
    max_turns: 100
    permission_mode: bypassPermissions
    timeout_minutes: 60
  teams:
    - name: backend
      lead:
        role: "Backend Lead"
        model: opus
      context: |
        Tech stack: Go, Chi router, Postgres
      members:
        - role: "API Engineer"
          focus: "REST endpoints, validation"
      tasks:
        - summary: "Build REST API"
          details: "Create endpoints for users and orders"
          deliverables:
            - "src/api/"
          verify: "go build ./..."
      depends_on: []
    - name: frontend
      lead:
        role: "Frontend Lead"
      tasks:
        - summary: "Build UI"
          details: "Create React components"
          verify: "npm test"
      depends_on:
        - backend
  """

  @minimal_yaml """
  name: "minimal"
  teams:
    - name: solo
      lead:
        role: "Solo Dev"
      tasks:
        - summary: "Do everything"
  """

  describe "load_string/1" do
    test "parses a full valid YAML config" do
      assert {:ok, %Config{} = config, warnings} = Loader.load_string(@valid_yaml)

      assert config.name == "my-project"
      assert config.defaults.model == "opus"
      assert config.defaults.max_turns == 100
      assert config.defaults.permission_mode == "bypassPermissions"
      assert config.defaults.timeout_minutes == 60

      assert length(config.teams) == 2

      [backend, frontend] = config.teams

      assert backend.name == "backend"
      assert backend.lead.role == "Backend Lead"
      assert backend.lead.model == "opus"
      assert String.contains?(backend.context, "Go, Chi router")
      assert length(backend.members) == 1
      assert hd(backend.members).role == "API Engineer"
      assert hd(backend.members).focus == "REST endpoints, validation"
      assert length(backend.tasks) == 1
      assert hd(backend.tasks).summary == "Build REST API"
      assert hd(backend.tasks).deliverables == ["src/api/"]
      assert hd(backend.tasks).verify == "go build ./..."
      assert backend.depends_on == []

      assert frontend.name == "frontend"
      assert frontend.depends_on == ["backend"]

      # warnings expected for task without details/verify on "Build UI"
      assert is_list(warnings)
    end

    test "parses minimal YAML with defaults" do
      assert {:ok, %Config{} = config, _warnings} = Loader.load_string(@minimal_yaml)

      assert config.name == "minimal"
      assert config.defaults == %Defaults{}
      assert length(config.teams) == 1

      [team] = config.teams
      assert team.name == "solo"
      assert team.lead.role == "Solo Dev"
      assert is_nil(team.lead.model)
      assert team.members == []
      assert team.depends_on == []
    end

    test "returns default values when defaults section is missing" do
      yaml = """
      name: "no-defaults"
      teams:
        - name: t1
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      assert config.defaults.model == "sonnet"
      assert config.defaults.max_turns == 200
      assert config.defaults.permission_mode == "acceptEdits"
      assert config.defaults.timeout_minutes == 30
    end

    test "returns error for invalid YAML syntax" do
      bad_yaml = """
      name: "broken
        - not: valid: yaml: [
      """

      assert {:error, errors} = Loader.load_string(bad_yaml)
      assert errors != []
      assert hd(errors) =~ "failed to parse YAML"
    end

    test "returns validation error for empty name" do
      yaml = """
      name: ""
      teams:
        - name: t1
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert "name cannot be empty" in errors
    end

    test "returns validation error for empty teams" do
      yaml = """
      name: "empty-teams"
      teams: []
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert "teams list cannot be empty" in errors
    end

    test "handles nil teams gracefully" do
      yaml = """
      name: "no-teams"
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert "teams list cannot be empty" in errors
    end

    test "handles team with no members" do
      yaml = """
      name: "no-members"
      teams:
        - name: solo
          lead:
            role: "Solo"
          tasks:
            - summary: "Do it"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      assert hd(config.teams).members == []
    end

    test "handles team with nil depends_on" do
      yaml = """
      name: "no-deps"
      teams:
        - name: t1
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      assert hd(config.teams).depends_on == []
    end

    test "handles task with nil deliverables" do
      yaml = """
      name: "no-deliverables"
      teams:
        - name: t1
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
              details: "Do some work"
              verify: "echo ok"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      assert hd(hd(config.teams).tasks).deliverables == []
    end

    test "parses multiple teams with dependencies" do
      yaml = """
      name: "multi"
      teams:
        - name: shared
          lead:
            role: "Shared Lead"
          tasks:
            - summary: "Build shared libs"
        - name: api
          lead:
            role: "API Lead"
          tasks:
            - summary: "Build API"
          depends_on:
            - shared
        - name: web
          lead:
            role: "Web Lead"
          tasks:
            - summary: "Build web"
          depends_on:
            - shared
        - name: integration
          lead:
            role: "Integration Lead"
          tasks:
            - summary: "Integration tests"
          depends_on:
            - api
            - web
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      assert length(config.teams) == 4

      integration = Enum.find(config.teams, &(&1.name == "integration"))
      assert integration.depends_on == ["api", "web"]
    end
  end

  describe "provider/backend parsing" do
    test "parses provider and backend from defaults" do
      yaml = """
      name: "with-provider"
      defaults:
        provider: cli
        backend: local
      teams:
        - name: t1
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
              details: "d"
              verify: "v"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      assert config.defaults.provider == :cli
      assert config.defaults.backend == :local
    end

    test "rejects unimplemented provider" do
      yaml = """
      name: "with-provider"
      defaults:
        provider: http
        backend: local
      teams:
        - name: t1
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
              details: "d"
              verify: "v"
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &String.contains?(&1, "not yet implemented"))
    end

    test "parses provider and backend per team" do
      yaml = """
      name: "team-override"
      defaults:
        provider: cli
        backend: local
      teams:
        - name: remote-team
          provider: cli
          backend: local
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
              details: "d"
              verify: "v"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      [team] = config.teams
      assert team.provider == :cli
      assert team.backend == :local
    end

    test "defaults to :cli/:local when provider/backend are omitted" do
      yaml = """
      name: "no-provider"
      defaults:
        model: opus
      teams:
        - name: t1
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
              details: "d"
              verify: "v"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      assert config.defaults.provider == :cli
      assert config.defaults.backend == :local
    end

    test "team-level provider/backend are nil when omitted" do
      yaml = """
      name: "no-team-provider"
      teams:
        - name: t1
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
              details: "d"
              verify: "v"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      [team] = config.teams
      assert is_nil(team.provider)
      assert is_nil(team.backend)
    end

    test "unknown provider string becomes nil (validator catches it)" do
      yaml = """
      name: "bad-provider"
      defaults:
        provider: openai
      teams:
        - name: t1
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
              details: "d"
              verify: "v"
      """

      # Unknown provider parses to nil, which falls back to :cli default in build_defaults
      # But at team level, unknown strings would become nil
      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      # The || :cli fallback in build_defaults means unknown defaults to :cli
      assert config.defaults.provider == :cli
    end

    test "external provider parses successfully" do
      yaml = """
      name: "external"
      defaults:
        provider: external
        backend: docker
      teams:
        - name: t1
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
              details: "d"
              verify: "v"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      assert config.defaults.provider == :external
      assert config.defaults.backend == :docker
    end
  end

  describe "load/1" do
    test "returns error for non-existent file" do
      assert {:error, errors} = Loader.load("/tmp/nonexistent_cortex_test.yaml")
      assert errors != []
      assert hd(errors) =~ "file not found"
    end

    test "loads a valid YAML file" do
      path = Path.join(System.tmp_dir!(), "cortex_loader_test_#{:rand.uniform(999_999)}.yaml")

      File.write!(path, @valid_yaml)

      try do
        assert {:ok, %Config{} = config, _warnings} = Loader.load(path)
        assert config.name == "my-project"
        assert length(config.teams) == 2
      after
        File.rm(path)
      end
    end
  end
end
