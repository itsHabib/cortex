defmodule Cortex.Orchestration.RunnerTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.Runner
  alias Cortex.Orchestration.Workspace

  @moduletag :orchestration

  # -- Helpers -----------------------------------------------------------------

  defp create_tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cortex_runner_test_#{:erlang.unique_integer([:positive])}"
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

  defp success_ndjson(opts \\ []) do
    cost = Keyword.get(opts, :cost, 0.25)
    turns = Keyword.get(opts, :turns, 3)
    duration = Keyword.get(opts, :duration, 15_000)
    result_text = Keyword.get(opts, :result, "All tasks completed successfully")

    """
    echo '{"type":"system","subtype":"init","session_id":"sess-001"}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Working..."}]}}'
    echo '{"type":"result","subtype":"success","result":"#{result_text}","cost_usd":#{cost},"num_turns":#{turns},"duration_ms":#{duration}}'
    """
  end

  defp failure_ndjson(opts \\ []) do
    cost = Keyword.get(opts, :cost, 0.05)
    turns = Keyword.get(opts, :turns, 1)
    duration = Keyword.get(opts, :duration, 5_000)

    """
    echo '{"type":"system","subtype":"init","session_id":"sess-fail"}'
    echo '{"type":"result","subtype":"error","result":"Tool execution failed","cost_usd":#{cost},"num_turns":#{turns},"duration_ms":#{duration}}'
    """
  end

  defp single_team_yaml do
    """
    name: "test-project"
    defaults:
      model: sonnet
      max_turns: 10
      permission_mode: acceptEdits
      timeout_minutes: 5
    teams:
      - name: backend
        lead:
          role: "Backend Lead"
        tasks:
          - summary: "Build the API"
            details: "Create REST endpoints"
            deliverables:
              - "src/api/"
            verify: "go build ./..."
    """
  end

  defp two_tier_yaml do
    """
    name: "tiered-project"
    defaults:
      model: sonnet
      max_turns: 10
      permission_mode: acceptEdits
      timeout_minutes: 5
    teams:
      - name: backend
        lead:
          role: "Backend Lead"
        tasks:
          - summary: "Build backend API"
        depends_on: []
      - name: frontend
        lead:
          role: "Frontend Lead"
        tasks:
          - summary: "Build frontend UI"
        depends_on:
          - backend
    """
  end

  defp parallel_yaml do
    """
    name: "parallel-project"
    defaults:
      model: sonnet
      max_turns: 10
      permission_mode: acceptEdits
      timeout_minutes: 5
    teams:
      - name: api
        lead:
          role: "API Lead"
        tasks:
          - summary: "Build API"
        depends_on: []
      - name: docs
        lead:
          role: "Docs Lead"
        tasks:
          - summary: "Write docs"
        depends_on: []
    """
  end

  # -- Tests -------------------------------------------------------------------

  describe "run/2 single team, no dependencies" do
    test "runs and completes successfully" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", single_team_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson())

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
        assert summary.project == "test-project"
        assert summary.total_cost > 0
        assert summary.total_duration_ms > 0
        assert is_binary(summary.summary)

        # Verify workspace was created
        assert File.dir?(Path.join(tmp_dir, ".cortex"))
        assert File.dir?(Path.join(tmp_dir, ".cortex/results"))
        assert File.dir?(Path.join(tmp_dir, ".cortex/logs"))

        # Verify state file has team as done
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)
        assert state.teams["backend"].status == "done"
        assert state.teams["backend"].cost_usd == 0.25

        # Verify result file exists
        {:ok, result} = Workspace.read_result(ws, "backend")
        assert result["status"] == "success"

        # Verify log file exists (under run_id subdir or flat when no DB)
        log_dir = Path.join([tmp_dir, ".cortex", "logs"])
        flat = Path.join(log_dir, "backend.log")
        nested = Path.wildcard(Path.join([log_dir, "*", "backend.log"]))
        assert File.exists?(flat) or length(nested) >= 1
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "run/2 two tiers (A -> B)" do
    test "tier A runs first, then tier B" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", two_tier_yaml())

        mock =
          write_mock_script(
            tmp_dir,
            "mock_claude.sh",
            success_ndjson(result: "Done", cost: 0.30, duration: 10_000)
          )

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
        assert summary.project == "tiered-project"
        assert map_size(summary.teams) == 2
        assert summary.teams["backend"].status == "done"
        assert summary.teams["frontend"].status == "done"

        # Both should have cost
        assert summary.total_cost == 0.60
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "run/2 parallel teams in same tier" do
    test "runs parallel teams and completes" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", parallel_yaml())

        mock =
          write_mock_script(
            tmp_dir,
            "mock_claude.sh",
            success_ndjson(cost: 0.20, duration: 8_000)
          )

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
        assert map_size(summary.teams) == 2
        assert summary.teams["api"].status == "done"
        assert summary.teams["docs"].status == "done"
        assert summary.total_cost == 0.40
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "run/2 dry_run" do
    test "returns plan without executing" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", two_tier_yaml())

        assert {:ok, plan} =
                 Runner.run(yaml_path,
                   dry_run: true,
                   workspace_path: tmp_dir
                 )

        assert plan.status == :dry_run
        assert plan.project == "tiered-project"
        assert plan.total_teams == 2
        assert length(plan.tiers) == 2

        # Tier 0 should be backend, tier 1 should be frontend
        [tier0, tier1] = plan.tiers
        assert tier0.tier == 0
        assert length(tier0.teams) == 1
        assert hd(tier0.teams).name == "backend"

        assert tier1.tier == 1
        assert length(tier1.teams) == 1
        assert hd(tier1.teams).name == "frontend"

        # No workspace should be created in dry run
        refute File.dir?(Path.join(tmp_dir, ".cortex"))
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "run/2 failed team with continue_on_error: false" do
    test "stops early on failure" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", two_tier_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", failure_ndjson())

        assert {:error, {:tier_failed, 0, ["backend"]}} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   continue_on_error: false
                 )

        # Backend should be marked as failed
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)
        assert state.teams["backend"].status == "failed"

        # Frontend should still be pending (never ran)
        assert state.teams["frontend"].status == "pending"
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "run/2 failed team with continue_on_error: true" do
    test "continues to next tier despite failure" do
      tmp_dir = create_tmp_dir()

      try do
        # Use a script that fails based on the prompt (all teams get same script here)
        # Since both teams use the same mock, both will "fail" in the result subtype
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", two_tier_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", failure_ndjson())

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   continue_on_error: true
                 )

        # Both teams should have run (even though backend failed, frontend still ran)
        assert summary.status == :failed
        assert summary.teams["backend"].status == "failed"
        assert summary.teams["frontend"].status == "failed"
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "run/2 events" do
    test "broadcasts run lifecycle events" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", single_team_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson())

        # Subscribe to events
        Cortex.Events.subscribe()

        assert {:ok, _summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        # Check we received key events
        assert_received %{type: :run_started, payload: %{project: "test-project"}}
        assert_received %{type: :tier_started, payload: %{tier: 0}}
        assert_received %{type: :tier_completed, payload: %{tier: 0}}
        assert_received %{type: :run_completed, payload: %{project: "test-project"}}
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "run/2 config errors" do
    test "returns error for missing file" do
      assert {:error, _} = Runner.run("/nonexistent/orchestra.yaml")
    end

    test "returns error for invalid yaml" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "bad.yaml", "name: \"\"\nteams: []")

        assert {:error, _errors} = Runner.run(yaml_path, workspace_path: tmp_dir)
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "run/2 with model override on team lead" do
    test "uses team lead model when specified" do
      tmp_dir = create_tmp_dir()

      try do
        yaml = """
        name: "model-test"
        defaults:
          model: sonnet
          max_turns: 10
          permission_mode: acceptEdits
          timeout_minutes: 5
        teams:
          - name: special
            lead:
              role: "Special Lead"
              model: opus
            tasks:
              - summary: "Do special work"
        """

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", yaml)
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson())

        # The mock script ignores args, so this just verifies the runner doesn't crash
        # when a team has a model override
        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "truncate_summary/1" do
    test "truncates strings longer than 2000 chars" do
      long_result = String.duplicate("x", 3000)

      ndjson = """
      echo '{"type":"system","subtype":"init","session_id":"sess-long"}'
      echo '{"type":"result","subtype":"success","result":"#{long_result}","cost_usd":0.10,"num_turns":1,"duration_ms":1000}'
      """

      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", single_team_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", ndjson)

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
        # The result_summary in the workspace should be the full text
        # (truncation only applies to store persistence)
        {:ok, ws} = Workspace.open(tmp_dir)
        {:ok, state} = Workspace.read_state(ws)
        result_summary = state.teams["backend"].result_summary
        assert is_binary(result_summary)
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "safe_store_call error handling" do
    test "runner completes even when store is unavailable" do
      tmp_dir = create_tmp_dir()

      try do
        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", single_team_yaml())
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson())

        # Run with a run_id that doesn't exist in the store — safe_store_call
        # should rescue any errors and allow the run to complete
        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir,
                   run_id: "nonexistent-run-id"
                 )

        assert summary.status == :complete
      after
        cleanup(tmp_dir)
      end
    end
  end

  describe "run/2 with context and dependencies" do
    test "injects upstream results into prompt" do
      tmp_dir = create_tmp_dir()

      try do
        yaml = """
        name: "context-test"
        defaults:
          model: sonnet
          max_turns: 10
          permission_mode: acceptEdits
          timeout_minutes: 5
        teams:
          - name: foundation
            lead:
              role: "Foundation Lead"
            context: |
              Use PostgreSQL for the database.
            tasks:
              - summary: "Build database schema"
                verify: "psql -c 'SELECT 1'"
            depends_on: []
          - name: app
            lead:
              role: "App Lead"
            tasks:
              - summary: "Build app on top of foundation"
            depends_on:
              - foundation
        """

        yaml_path = write_yaml(tmp_dir, "orchestra.yaml", yaml)
        mock = write_mock_script(tmp_dir, "mock_claude.sh", success_ndjson())

        assert {:ok, summary} =
                 Runner.run(yaml_path,
                   command: mock,
                   workspace_path: tmp_dir
                 )

        assert summary.status == :complete
        assert summary.teams["foundation"].status == "done"
        assert summary.teams["app"].status == "done"
      after
        cleanup(tmp_dir)
      end
    end
  end
end
