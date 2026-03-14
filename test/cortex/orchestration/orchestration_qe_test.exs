defmodule Cortex.Orchestration.OrchestrationQETest do
  @moduledoc """
  Phase 4 — DAG Orchestration QE tests.

  Stress tests, edge cases, failure cascades, and config boundary tests
  that complement Phase 3's 350-test coverage.
  """

  use ExUnit.Case, async: false

  alias Cortex.Orchestration.Config.Loader
  alias Cortex.Orchestration.DAG
  alias Cortex.Orchestration.Runner
  alias Cortex.Orchestration.Workspace

  @moduletag :orchestration_qe

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cortex_qe_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp cleanup(dir) do
    File.rm_rf!(dir)
  end

  defp write_yaml(dir, filename, content) do
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  defp write_mock_script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/bash\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp success_ndjson(opts) do
    cost = Keyword.get(opts, :cost, 0.10)
    turns = Keyword.get(opts, :turns, 2)
    duration = Keyword.get(opts, :duration, 1_000)
    result_text = Keyword.get(opts, :result, "Done")

    """
    echo '{"type":"system","subtype":"init","session_id":"sess-ok"}'
    echo '{"type":"result","subtype":"success","result":"#{result_text}","cost_usd":#{cost},"num_turns":#{turns},"duration_ms":#{duration}}'
    """
  end

  # Writes a marker file so we can prove which teams actually ran
  defp marker_ndjson(marker_dir, opts \\ []) do
    cost = Keyword.get(opts, :cost, 0.10)
    turns = Keyword.get(opts, :turns, 2)
    duration = Keyword.get(opts, :duration, 1_000)
    result_text = Keyword.get(opts, :result, "Done")

    # The script creates a file named after process PID + a random suffix to
    # avoid collisions. We also echo the args to the marker so we can inspect.
    """
    MARKER_DIR="#{marker_dir}"
    # Claude passes args: -p <prompt> --output-format stream-json ...
    # We use $$ (bash PID) + $RANDOM to make unique filenames.
    MARKER_FILE="${MARKER_DIR}/$$.${RANDOM}.marker"
    echo "$@" > "${MARKER_FILE}"
    echo '{"type":"system","subtype":"init","session_id":"sess-ok"}'
    echo '{"type":"result","subtype":"success","result":"#{result_text}","cost_usd":#{cost},"num_turns":#{turns},"duration_ms":#{duration}}'
    """
  end

  defp build_team_yaml(name, opts \\ []) do
    role = Keyword.get(opts, :role, "#{name} Lead")
    deps = Keyword.get(opts, :depends_on, [])
    summary = Keyword.get(opts, :summary, "Do #{name} work")
    context = Keyword.get(opts, :context, nil)

    deps_yaml =
      if deps == [] do
        "        depends_on: []"
      else
        deps_lines = Enum.map(deps, fn d -> "          - #{d}" end) |> Enum.join("\n")
        "        depends_on:\n#{deps_lines}"
      end

    context_yaml =
      if context do
        "        context: |\n          #{context}"
      else
        ""
      end

    """
          - name: #{name}
            lead:
              role: "#{role}"
            tasks:
              - summary: "#{summary}"
    #{deps_yaml}
    #{context_yaml}
    """
  end

  # ---------------------------------------------------------------------------
  # 1. Complex DAG stress test — 10+ teams, 4+ tiers
  # ---------------------------------------------------------------------------

  describe "complex DAG stress test (12 teams, 5 tiers)" do
    @tag timeout: 60_000
    test "all tiers execute in correct order and all results are captured" do
      tmp_dir = create_tmp_dir()

      try do
        #  DAG layout (5 tiers):
        #
        #  Tier 0: infra, auth, logging          (no deps)
        #  Tier 1: database, cache               (-> infra)
        #  Tier 2: api, gateway, events           (-> database, cache)
        #  Tier 3: frontend, mobile, workers      (-> api, gateway)
        #  Tier 4: integration                    (-> frontend, mobile, workers, events)

        teams_yaml = [
          build_team_yaml("infra"),
          build_team_yaml("auth"),
          build_team_yaml("logging"),
          build_team_yaml("database", depends_on: ["infra"]),
          build_team_yaml("cache", depends_on: ["infra"]),
          build_team_yaml("api", depends_on: ["database", "cache"]),
          build_team_yaml("gateway", depends_on: ["database", "cache"]),
          build_team_yaml("events", depends_on: ["database"]),
          build_team_yaml("frontend", depends_on: ["api", "gateway"]),
          build_team_yaml("mobile", depends_on: ["api", "gateway"]),
          build_team_yaml("workers", depends_on: ["api"]),
          build_team_yaml("integration", depends_on: ["frontend", "mobile", "workers", "events"])
        ]

        yaml = """
        name: "stress-12-teams"
        defaults:
          model: sonnet
          max_turns: 5
          permission_mode: acceptEdits
          timeout_minutes: 2
        teams:
        #{Enum.join(teams_yaml, "\n")}
        """

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", yaml)
        mock = write_mock_script(tmp_dir, "mock.sh", success_ndjson(cost: 0.05, duration: 200))

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
        assert summary.project == "stress-12-teams"
        assert map_size(summary.teams) == 12

        # Every team should be done
        for {name, info} <- summary.teams do
          assert info.status == "done",
                 "Expected team #{name} to be done, got #{info.status}"
        end

        # Total cost: 12 teams * $0.05 = $0.60
        assert_in_delta summary.total_cost, 0.60, 0.01

        # Verify the workspace state file
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)
        assert map_size(state.teams) == 12

        # Verify result files exist for all 12 teams
        all_names = [
          "infra", "auth", "logging", "database", "cache",
          "api", "gateway", "events", "frontend", "mobile",
          "workers", "integration"
        ]

        for name <- all_names do
          assert {:ok, result} = Workspace.read_result(ws, name),
                 "Expected result file for team #{name}"

          assert result["status"] == "success"
        end

        # Verify DAG tier structure is as expected
        teams_for_dag =
          Enum.map(all_names, fn name ->
            deps =
              case name do
                "infra" -> []
                "auth" -> []
                "logging" -> []
                "database" -> ["infra"]
                "cache" -> ["infra"]
                "api" -> ["database", "cache"]
                "gateway" -> ["database", "cache"]
                "events" -> ["database"]
                "frontend" -> ["api", "gateway"]
                "mobile" -> ["api", "gateway"]
                "workers" -> ["api"]
                "integration" -> ["frontend", "mobile", "workers", "events"]
              end

            %{name: name, depends_on: deps}
          end)

        assert {:ok, tiers} = DAG.build_tiers(teams_for_dag)
        assert length(tiers) == 5

        # Tier 0: auth, infra, logging (alphabetical)
        assert Enum.at(tiers, 0) == ["auth", "infra", "logging"]
        # Tier 1: cache, database
        assert Enum.at(tiers, 1) == ["cache", "database"]
        # Tier 2: api, events, gateway
        assert Enum.at(tiers, 2) == ["api", "events", "gateway"]
        # Tier 3: frontend, mobile, workers
        assert Enum.at(tiers, 3) == ["frontend", "mobile", "workers"]
        # Tier 4: integration
        assert Enum.at(tiers, 4) == ["integration"]
      after
        cleanup(tmp_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Failure cascade — 3-tier DAG (A -> B -> C)
  # ---------------------------------------------------------------------------

  describe "failure cascade in 3-tier DAG" do
    test "continue_on_error: false — C never runs when B fails" do
      tmp_dir = create_tmp_dir()

      try do
        yaml = """
        name: "cascade-stop"
        defaults:
          model: sonnet
          max_turns: 5
          permission_mode: acceptEdits
          timeout_minutes: 2
        teams:
          - name: team_a
            lead:
              role: "A Lead"
            tasks:
              - summary: "A work"
            depends_on: []
          - name: team_b
            lead:
              role: "B Lead"
            tasks:
              - summary: "B work"
            depends_on:
              - team_a
          - name: team_c
            lead:
              role: "C Lead"
            tasks:
              - summary: "C work"
            depends_on:
              - team_b
        """

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", yaml)

        # Write TWO scripts: one success, one failure.
        # The runner uses a single --command for all teams, so we need a
        # script that inspects the prompt to decide success/failure.
        # The prompt contains the team role; we can match on that.
        script_body = """
        # Check if prompt (arg 2, after -p) mentions "A Lead" — succeed
        # If it mentions "B Lead" — fail
        # If it mentions "C Lead" — succeed (should not be reached)
        PROMPT="$2"
        if echo "$PROMPT" | grep -q "A Lead"; then
          echo '{"type":"system","subtype":"init","session_id":"sess-a"}'
          echo '{"type":"result","subtype":"success","result":"A done","cost_usd":0.05,"num_turns":1,"duration_ms":100}'
        elif echo "$PROMPT" | grep -q "B Lead"; then
          echo '{"type":"system","subtype":"init","session_id":"sess-b"}'
          echo '{"type":"result","subtype":"error","result":"B crashed","cost_usd":0.02,"num_turns":1,"duration_ms":50}'
        else
          echo '{"type":"system","subtype":"init","session_id":"sess-c"}'
          echo '{"type":"result","subtype":"success","result":"C done","cost_usd":0.05,"num_turns":1,"duration_ms":100}'
        fi
        """

        mock = write_mock_script(tmp_dir, "mock.sh", script_body)

        result =
          Runner.run(yaml_path,
            command: mock,
            workspace_path: tmp_dir,
            continue_on_error: false
          )

        # Tier 1 (team_b) should fail, causing early stop
        assert {:error, {:tier_failed, 1, ["team_b"]}} = result

        # Verify team states
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)

        assert state.teams["team_a"].status == "done"
        assert state.teams["team_b"].status == "failed"
        # team_c should never have been touched beyond "pending" (seeded state)
        assert state.teams["team_c"].status == "pending"
      after
        cleanup(tmp_dir)
      end
    end

    test "continue_on_error: true — C still runs despite B failing" do
      tmp_dir = create_tmp_dir()

      try do
        yaml = """
        name: "cascade-continue"
        defaults:
          model: sonnet
          max_turns: 5
          permission_mode: acceptEdits
          timeout_minutes: 2
        teams:
          - name: team_a
            lead:
              role: "A Lead"
            tasks:
              - summary: "A work"
            depends_on: []
          - name: team_b
            lead:
              role: "B Lead"
            tasks:
              - summary: "B work"
            depends_on:
              - team_a
          - name: team_c
            lead:
              role: "C Lead"
            tasks:
              - summary: "C work"
            depends_on:
              - team_b
        """

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", yaml)

        script_body = """
        PROMPT="$2"
        if echo "$PROMPT" | grep -q "B Lead"; then
          echo '{"type":"system","subtype":"init","session_id":"sess-b"}'
          echo '{"type":"result","subtype":"error","result":"B crashed","cost_usd":0.02,"num_turns":1,"duration_ms":50}'
        else
          echo '{"type":"system","subtype":"init","session_id":"sess-ok"}'
          echo '{"type":"result","subtype":"success","result":"OK","cost_usd":0.05,"num_turns":1,"duration_ms":100}'
        fi
        """

        mock = write_mock_script(tmp_dir, "mock.sh", script_body)

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   continue_on_error: true
                 )

        # Overall status should be :failed because B failed
        assert summary.status == :failed

        # A and C ran successfully, B failed
        assert summary.teams["team_a"].status == "done"
        assert summary.teams["team_b"].status == "failed"
        # C should have been executed (continue_on_error: true)
        assert summary.teams["team_c"].status == "done"
      after
        cleanup(tmp_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Concurrent tier verification — 5 parallel teams
  # ---------------------------------------------------------------------------

  describe "concurrent tier verification (5 parallel teams)" do
    @tag timeout: 30_000
    test "all 5 teams actually run and leave workspace state entries" do
      tmp_dir = create_tmp_dir()
      marker_dir = Path.join(tmp_dir, "markers")
      File.mkdir_p!(marker_dir)

      try do
        team_names = for i <- 1..5, do: "team_#{i}"

        teams_yaml =
          Enum.map(team_names, fn name ->
            build_team_yaml(name)
          end)

        yaml = """
        name: "parallel-5"
        defaults:
          model: sonnet
          max_turns: 5
          permission_mode: acceptEdits
          timeout_minutes: 2
        teams:
        #{Enum.join(teams_yaml, "\n")}
        """

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", yaml)
        mock = write_mock_script(tmp_dir, "mock.sh", marker_ndjson(marker_dir))

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
        assert map_size(summary.teams) == 5

        # Check all teams are done in summary
        for name <- team_names do
          assert summary.teams[name].status == "done",
                 "Team #{name} should be done"
        end

        # Verify marker files were created — one per team
        {:ok, marker_files} = File.ls(marker_dir)
        markers = Enum.filter(marker_files, &String.ends_with?(&1, ".marker"))
        assert length(markers) == 5, "Expected 5 marker files, got #{length(markers)}"

        # Verify workspace state entries exist for all 5 teams
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)

        for name <- team_names do
          assert Map.has_key?(state.teams, name),
                 "Missing workspace state entry for #{name}"

          assert state.teams[name].status == "done"
          assert state.teams[name].cost_usd != nil
        end

        # Verify result files exist
        for name <- team_names do
          assert {:ok, _} = Workspace.read_result(ws, name)
        end

        # Verify log files exist
        for name <- team_names do
          log = Workspace.log_path(ws, name)
          assert File.exists?(log), "Missing log file for #{name}"
        end
      after
        cleanup(tmp_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Workspace state integrity after failures
  # ---------------------------------------------------------------------------

  describe "workspace state integrity after mixed success/failure" do
    test "state.json correctly reflects team statuses" do
      tmp_dir = create_tmp_dir()

      try do
        # 4 teams, all parallel (tier 0). Two succeed, two fail.
        yaml = """
        name: "mixed-status"
        defaults:
          model: sonnet
          max_turns: 5
          permission_mode: acceptEdits
          timeout_minutes: 2
        teams:
          - name: good_1
            lead:
              role: "Good1 Lead"
            tasks:
              - summary: "Succeed"
            depends_on: []
          - name: bad_1
            lead:
              role: "Bad1 Lead"
            tasks:
              - summary: "Fail"
            depends_on: []
          - name: good_2
            lead:
              role: "Good2 Lead"
            tasks:
              - summary: "Succeed"
            depends_on: []
          - name: bad_2
            lead:
              role: "Bad2 Lead"
            tasks:
              - summary: "Fail"
            depends_on: []
        """

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", yaml)

        # Script that fails for any team whose prompt contains "Bad"
        script_body = """
        PROMPT="$2"
        if echo "$PROMPT" | grep -q "Bad"; then
          echo '{"type":"system","subtype":"init","session_id":"sess-bad"}'
          echo '{"type":"result","subtype":"error","result":"Exploded","cost_usd":0.01,"num_turns":1,"duration_ms":100}'
        else
          echo '{"type":"system","subtype":"init","session_id":"sess-good"}'
          echo '{"type":"result","subtype":"success","result":"All good","cost_usd":0.10,"num_turns":2,"duration_ms":500}'
        fi
        """

        mock = write_mock_script(tmp_dir, "mock.sh", script_body)

        # With continue_on_error: true so all 4 teams run even if some fail
        # (they're all in the same tier, but the runner flags failures)
        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   continue_on_error: true
                 )

        assert summary.status == :failed

        # Verify state.json directly
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)

        assert state.teams["good_1"].status == "done"
        assert state.teams["good_2"].status == "done"
        assert state.teams["bad_1"].status == "failed"
        assert state.teams["bad_2"].status == "failed"

        # Cost should only accumulate from successful + failed teams
        assert state.teams["good_1"].cost_usd == 0.10
        assert state.teams["good_2"].cost_usd == 0.10
        assert state.teams["bad_1"].cost_usd == 0.01
        assert state.teams["bad_2"].cost_usd == 0.01

        # Duration should be set for all teams
        assert state.teams["good_1"].duration_ms != nil
        assert state.teams["bad_1"].duration_ms != nil

        # Result summary should reflect the outcome
        assert state.teams["good_1"].result_summary == "All good"
        assert state.teams["bad_1"].result_summary == "Exploded"

        # Verify registry.json has proper entries
        {:ok, registry} = Workspace.read_registry(ws)
        assert registry.project == "mixed-status"
        assert length(registry.teams) == 4

        for entry <- registry.teams do
          assert entry.ended_at != nil, "#{entry.name} should have ended_at"
          assert entry.status in ["done", "failed"]
        end

        # Result files for successful teams should exist with status=success
        {:ok, good_result} = Workspace.read_result(ws, "good_1")
        assert good_result["status"] == "success"

        # Result files for failed teams should exist with status=error
        {:ok, bad_result} = Workspace.read_result(ws, "bad_1")
        assert bad_result["status"] == "error"
      after
        cleanup(tmp_dir)
      end
    end

    test "state reflects error type when spawner itself errors (non-zero exit)" do
      tmp_dir = create_tmp_dir()

      try do
        yaml = """
        name: "exit-code-test"
        defaults:
          model: sonnet
          max_turns: 5
          permission_mode: acceptEdits
          timeout_minutes: 2
        teams:
          - name: crasher
            lead:
              role: "Crash Lead"
            tasks:
              - summary: "Crash hard"
            depends_on: []
        """

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", yaml)

        # Script that exits with non-zero code without producing valid NDJSON
        mock = write_mock_script(tmp_dir, "mock.sh", "exit 1")

        # continue_on_error true so we get back {:ok, summary}
        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   continue_on_error: true
                 )

        assert summary.status == :failed

        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)

        # Team should be marked as failed
        assert state.teams["crasher"].status == "failed"
        # result_summary should contain the error info
        assert state.teams["crasher"].result_summary =~ "Error:"
      after
        cleanup(tmp_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Config edge cases
  # ---------------------------------------------------------------------------

  describe "config edge cases" do
    test "unicode team names are accepted" do
      yaml = """
      name: "unicode-project"
      defaults:
        model: sonnet
      teams:
        - name: "backend-日本語"
          lead:
            role: "Japanese Backend Lead"
          tasks:
            - summary: "Build Japanese backend"
          depends_on: []
        - name: "frontend-émoji"
          lead:
            role: "French Frontend Lead"
          tasks:
            - summary: "Build French frontend"
          depends_on:
            - "backend-日本語"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      assert length(config.teams) == 2
      assert Enum.at(config.teams, 0).name == "backend-日本語"
      assert Enum.at(config.teams, 1).name == "frontend-émoji"

      # DAG should process unicode names correctly
      assert {:ok, tiers} = DAG.build_tiers(config.teams)
      assert length(tiers) == 2
      assert Enum.at(tiers, 0) == ["backend-日本語"]
      assert Enum.at(tiers, 1) == ["frontend-émoji"]
    end

    test "very long context string is preserved" do
      long_context = String.duplicate("x", 10_000)

      yaml = """
      name: "long-context"
      defaults:
        model: sonnet
      teams:
        - name: reader
          lead:
            role: "Reader Lead"
          context: "#{long_context}"
          tasks:
            - summary: "Read all that context"
      """

      assert {:ok, config, _warnings} = Loader.load_string(yaml)
      team = hd(config.teams)
      assert String.length(team.context) == 10_000
    end

    test "tasks with no verify command produce soft warning only" do
      yaml = """
      name: "no-verify"
      defaults:
        model: sonnet
      teams:
        - name: unverified
          lead:
            role: "Lead"
          tasks:
            - summary: "Do something"
              details: "With details but no verify"
      """

      assert {:ok, _config, warnings} = Loader.load_string(yaml)
      assert Enum.any?(warnings, &(&1 =~ "empty verify"))
    end

    test "team with empty depends_on is equivalent to missing depends_on" do
      yaml_explicit = """
      name: "deps-explicit"
      defaults:
        model: sonnet
      teams:
        - name: solo
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
          depends_on: []
      """

      yaml_missing = """
      name: "deps-missing"
      defaults:
        model: sonnet
      teams:
        - name: solo
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
      """

      assert {:ok, config_explicit, _} = Loader.load_string(yaml_explicit)
      assert {:ok, config_missing, _} = Loader.load_string(yaml_missing)

      assert hd(config_explicit.teams).depends_on == []
      assert hd(config_missing.teams).depends_on == []

      # Both should produce identical DAG tiers
      assert {:ok, tiers_explicit} = DAG.build_tiers(config_explicit.teams)
      assert {:ok, tiers_missing} = DAG.build_tiers(config_missing.teams)
      assert tiers_explicit == tiers_missing
    end

    test "tasks with empty details produce soft warning" do
      yaml = """
      name: "no-details"
      defaults:
        model: sonnet
      teams:
        - name: sparse
          lead:
            role: "Lead"
          tasks:
            - summary: "Minimal task"
              verify: "echo ok"
      """

      assert {:ok, _config, warnings} = Loader.load_string(yaml)
      assert Enum.any?(warnings, &(&1 =~ "empty details"))
    end

    test "empty team list is a hard validation error" do
      yaml = """
      name: "empty-teams"
      defaults:
        model: sonnet
      teams: []
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &(&1 =~ "teams list cannot be empty"))
    end

    test "duplicate team names are a hard validation error" do
      yaml = """
      name: "dupes"
      defaults:
        model: sonnet
      teams:
        - name: alpha
          lead:
            role: "Lead"
          tasks:
            - summary: "Work"
        - name: alpha
          lead:
            role: "Lead 2"
          tasks:
            - summary: "More work"
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &(&1 =~ "duplicate team names"))
    end

    test "self-referencing depends_on is caught" do
      yaml = """
      name: "self-ref"
      defaults:
        model: sonnet
      teams:
        - name: ouroboros
          lead:
            role: "Lead"
          tasks:
            - summary: "Chase own tail"
          depends_on:
            - ouroboros
      """

      assert {:error, errors} = Loader.load_string(yaml)
      assert Enum.any?(errors, &(&1 =~ "self-reference"))
    end
  end

  # ---------------------------------------------------------------------------
  # 6. DAG with maximum parallelism — all teams in tier 1
  # ---------------------------------------------------------------------------

  describe "DAG with maximum parallelism" do
    test "8 independent teams all land in a single tier" do
      team_names = for i <- 1..8, do: "worker_#{i}"

      teams =
        Enum.map(team_names, fn name ->
          %{name: name, depends_on: []}
        end)

      assert {:ok, [single_tier]} = DAG.build_tiers(teams)
      assert length(single_tier) == 8
      assert single_tier == Enum.sort(team_names)
    end

    @tag timeout: 30_000
    test "8 independent teams all run concurrently via the runner" do
      tmp_dir = create_tmp_dir()
      marker_dir = Path.join(tmp_dir, "markers")
      File.mkdir_p!(marker_dir)

      try do
        team_names = for i <- 1..8, do: "worker_#{i}"

        teams_yaml =
          Enum.map(team_names, fn name ->
            build_team_yaml(name)
          end)

        yaml = """
        name: "max-parallel"
        defaults:
          model: sonnet
          max_turns: 5
          permission_mode: acceptEdits
          timeout_minutes: 2
        teams:
        #{Enum.join(teams_yaml, "\n")}
        """

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", yaml)
        mock = write_mock_script(tmp_dir, "mock.sh", marker_ndjson(marker_dir))

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
        assert map_size(summary.teams) == 8

        # All 8 should be done
        for name <- team_names do
          assert summary.teams[name].status == "done"
        end

        # 8 marker files created
        {:ok, files} = File.ls(marker_dir)
        markers = Enum.filter(files, &String.ends_with?(&1, ".marker"))
        assert length(markers) == 8

        # Verify the DAG only had 1 tier (captured via dry_run)
        assert {:ok, plan} =
                 Runner.run(yaml_path, dry_run: true, workspace_path: tmp_dir)

        assert plan.status == :dry_run
        assert length(plan.tiers) == 1
        assert length(hd(plan.tiers).teams) == 8
      after
        cleanup(tmp_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Bonus: DAG-only edge cases (pure unit, no filesystem)
  # ---------------------------------------------------------------------------

  describe "DAG edge cases" do
    test "wide fan-out: 1 root -> 20 leaves -> 1 collector" do
      leaf_names = for i <- 1..20, do: "leaf_#{String.pad_leading(Integer.to_string(i), 2, "0")}"

      root = %{name: "root", depends_on: []}
      leaves = Enum.map(leaf_names, fn n -> %{name: n, depends_on: ["root"]} end)
      collector = %{name: "collector", depends_on: leaf_names}

      teams = [root | leaves] ++ [collector]

      assert {:ok, tiers} = DAG.build_tiers(teams)
      assert length(tiers) == 3
      assert Enum.at(tiers, 0) == ["root"]
      assert length(Enum.at(tiers, 1)) == 20
      assert Enum.at(tiers, 2) == ["collector"]
    end

    test "diamond of diamonds produces correct tier count" do
      # Two independent diamonds that merge at the end:
      #
      #  a1          a2
      #  / \        / \
      # b1  c1    b2  c2
      #  \ /        \ /
      #   d1         d2
      #     \       /
      #      final
      teams = [
        %{name: "a1", depends_on: []},
        %{name: "a2", depends_on: []},
        %{name: "b1", depends_on: ["a1"]},
        %{name: "c1", depends_on: ["a1"]},
        %{name: "b2", depends_on: ["a2"]},
        %{name: "c2", depends_on: ["a2"]},
        %{name: "d1", depends_on: ["b1", "c1"]},
        %{name: "d2", depends_on: ["b2", "c2"]},
        %{name: "final", depends_on: ["d1", "d2"]}
      ]

      assert {:ok, tiers} = DAG.build_tiers(teams)
      assert length(tiers) == 4

      assert Enum.at(tiers, 0) == ["a1", "a2"]
      assert Enum.at(tiers, 1) == ["b1", "b2", "c1", "c2"]
      assert Enum.at(tiers, 2) == ["d1", "d2"]
      assert Enum.at(tiers, 3) == ["final"]
    end

    test "long sequential chain (15 deep) produces 15 tiers" do
      teams =
        for i <- 0..14 do
          deps = if i == 0, do: [], else: ["step_#{i - 1}"]
          %{name: "step_#{i}", depends_on: deps}
        end

      assert {:ok, tiers} = DAG.build_tiers(teams)
      assert length(tiers) == 15

      for {tier, i} <- Enum.with_index(tiers) do
        assert tier == ["step_#{i}"]
      end
    end
  end
end
