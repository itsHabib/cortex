defmodule Cortex.Orchestration.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.RegistryEntry
  alias Cortex.Orchestration.RunRegistry
  alias Cortex.Orchestration.State
  alias Cortex.Orchestration.TeamState
  alias Cortex.Orchestration.Workspace

  @moduletag :orchestration

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cortex_workspace_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp init_workspace(tmp_dir, opts \\ []) do
    project = Keyword.get(opts, :project, "test-project")
    teams = Keyword.get(opts, :teams, ["backend", "frontend"])
    config = %{project: project, teams: teams}
    Workspace.init(tmp_dir, config)
  end

  # --- Init ---

  describe "init/2" do
    test "creates .cortex directory structure", %{tmp_dir: tmp_dir} do
      assert {:ok, %Workspace{}} = init_workspace(tmp_dir)

      cortex_path = Path.join(tmp_dir, ".cortex")
      assert File.dir?(cortex_path)
      assert File.dir?(Path.join(cortex_path, "results"))
      assert File.dir?(Path.join(cortex_path, "logs"))
    end

    test "seeds state.json with project and pending teams", %{tmp_dir: tmp_dir} do
      assert {:ok, ws} = init_workspace(tmp_dir)
      assert {:ok, state} = Workspace.read_state(ws)

      assert state.project == "test-project"
      assert map_size(state.teams) == 2
      assert state.teams["backend"].status == "pending"
      assert state.teams["frontend"].status == "pending"
    end

    test "seeds registry.json with project and pending entries", %{tmp_dir: tmp_dir} do
      assert {:ok, ws} = init_workspace(tmp_dir)
      assert {:ok, registry} = Workspace.read_registry(ws)

      assert registry.project == "test-project"
      assert length(registry.teams) == 2

      names = Enum.map(registry.teams, & &1.name)
      assert "backend" in names
      assert "frontend" in names
      assert Enum.all?(registry.teams, fn e -> e.status == "pending" end)
    end

    test "works with no teams", %{tmp_dir: tmp_dir} do
      config = %{project: "empty-project", teams: []}
      assert {:ok, ws} = Workspace.init(tmp_dir, config)

      assert {:ok, state} = Workspace.read_state(ws)
      assert state.teams == %{}

      assert {:ok, registry} = Workspace.read_registry(ws)
      assert registry.teams == []
    end

    test "returns workspace with correct path", %{tmp_dir: tmp_dir} do
      assert {:ok, ws} = init_workspace(tmp_dir)
      assert ws.path == Path.join(tmp_dir, ".cortex")
    end
  end

  # --- Open ---

  describe "open/1" do
    test "opens an existing workspace", %{tmp_dir: tmp_dir} do
      {:ok, _} = init_workspace(tmp_dir)
      assert {:ok, %Workspace{}} = Workspace.open(tmp_dir)
    end

    test "returns error for non-existent workspace", %{tmp_dir: tmp_dir} do
      assert {:error, :workspace_not_found} = Workspace.open(tmp_dir)
    end

    test "returns workspace with correct path", %{tmp_dir: tmp_dir} do
      {:ok, _} = init_workspace(tmp_dir)
      {:ok, ws} = Workspace.open(tmp_dir)
      assert ws.path == Path.join(tmp_dir, ".cortex")
    end
  end

  # --- State Operations ---

  describe "read_state/1 and write_state/2" do
    test "roundtrips state through JSON", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      state = %State{
        project: "roundtrip",
        teams: %{
          "api" => %TeamState{
            status: "done",
            result_summary: "Built REST API",
            artifacts: ["src/api/"],
            cost_usd: 1.23,
            duration_ms: 45_000
          }
        }
      }

      assert :ok = Workspace.write_state(ws, state)
      assert {:ok, read_state} = Workspace.read_state(ws)

      assert read_state.project == "roundtrip"
      assert read_state.teams["api"].status == "done"
      assert read_state.teams["api"].result_summary == "Built REST API"
      assert read_state.teams["api"].artifacts == ["src/api/"]
      assert read_state.teams["api"].cost_usd == 1.23
      assert read_state.teams["api"].duration_ms == 45_000
    end
  end

  describe "update_team_state/3" do
    test "updates an existing team's status", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      assert :ok = Workspace.update_team_state(ws, "backend", status: "running")
      {:ok, state} = Workspace.read_state(ws)

      assert state.teams["backend"].status == "running"
      # Other team untouched
      assert state.teams["frontend"].status == "pending"
    end

    test "updates multiple fields at once", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      assert :ok =
               Workspace.update_team_state(ws, "backend",
                 status: "done",
                 result_summary: "All endpoints built",
                 cost_usd: 2.50,
                 duration_ms: 120_000,
                 artifacts: ["src/api/", "src/models/"]
               )

      {:ok, state} = Workspace.read_state(ws)
      ts = state.teams["backend"]

      assert ts.status == "done"
      assert ts.result_summary == "All endpoints built"
      assert ts.cost_usd == 2.50
      assert ts.duration_ms == 120_000
      assert ts.artifacts == ["src/api/", "src/models/"]
    end

    test "creates a new team entry if it doesn't exist", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      assert :ok = Workspace.update_team_state(ws, "new-team", status: "running")
      {:ok, state} = Workspace.read_state(ws)

      assert state.teams["new-team"].status == "running"
    end

    test "preserves existing fields when updating a subset", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      :ok =
        Workspace.update_team_state(ws, "backend",
          status: "running",
          cost_usd: 0.50
        )

      :ok = Workspace.update_team_state(ws, "backend", status: "done")

      {:ok, state} = Workspace.read_state(ws)
      ts = state.teams["backend"]

      assert ts.status == "done"
      assert ts.cost_usd == 0.50
    end
  end

  # --- Registry Operations ---

  describe "read_registry/1 and write_registry/2" do
    test "roundtrips registry through JSON", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      registry = %RunRegistry{
        project: "roundtrip",
        teams: [
          %RegistryEntry{
            name: "api",
            status: "done",
            session_id: "sess-123",
            pid: 42_000,
            started_at: "2025-01-01T00:00:00Z",
            ended_at: "2025-01-01T00:05:00Z"
          }
        ]
      }

      assert :ok = Workspace.write_registry(ws, registry)
      assert {:ok, read_reg} = Workspace.read_registry(ws)

      assert read_reg.project == "roundtrip"
      assert length(read_reg.teams) == 1
      entry = hd(read_reg.teams)
      assert entry.name == "api"
      assert entry.status == "done"
      assert entry.session_id == "sess-123"
      assert entry.pid == 42_000
      assert entry.started_at == "2025-01-01T00:00:00Z"
      assert entry.ended_at == "2025-01-01T00:05:00Z"
    end
  end

  describe "update_registry_entry/3" do
    test "updates an existing entry", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      assert :ok =
               Workspace.update_registry_entry(ws, "backend",
                 status: "running",
                 pid: 12_345,
                 started_at: "2025-01-01T00:00:00Z"
               )

      {:ok, registry} = Workspace.read_registry(ws)
      {:ok, entry} = RunRegistry.find_entry(registry, "backend")

      assert entry.status == "running"
      assert entry.pid == 12_345
      assert entry.started_at == "2025-01-01T00:00:00Z"
    end

    test "creates a new entry if team doesn't exist", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      assert :ok = Workspace.update_registry_entry(ws, "devops", status: "pending")

      {:ok, registry} = Workspace.read_registry(ws)
      {:ok, entry} = RunRegistry.find_entry(registry, "devops")
      assert entry.status == "pending"
    end

    test "preserves other entries when updating one", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      :ok = Workspace.update_registry_entry(ws, "backend", status: "running")
      {:ok, registry} = Workspace.read_registry(ws)

      {:ok, frontend_entry} = RunRegistry.find_entry(registry, "frontend")
      assert frontend_entry.status == "pending"
    end
  end

  # --- Result Operations ---

  describe "write_result/3 and read_result/2" do
    test "roundtrips result through JSON", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      result = %{
        "team" => "backend",
        "status" => "success",
        "result" => "Built all endpoints",
        "cost_usd" => 1.50,
        "duration_ms" => 60_000
      }

      assert :ok = Workspace.write_result(ws, "backend", result)
      assert {:ok, read_result} = Workspace.read_result(ws, "backend")

      assert read_result == result
    end

    test "returns error for non-existent result", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)
      assert {:error, :enoent} = Workspace.read_result(ws, "nonexistent")
    end

    test "overwrites existing result", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)

      :ok = Workspace.write_result(ws, "backend", %{"v" => 1})
      :ok = Workspace.write_result(ws, "backend", %{"v" => 2})

      {:ok, result} = Workspace.read_result(ws, "backend")
      assert result["v"] == 2
    end
  end

  # --- Log Operations ---

  describe "log_path/3" do
    test "returns expected path with run_id", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)
      expected = Path.join([tmp_dir, ".cortex", "logs", "run-abc", "backend.log"])
      assert Workspace.log_path(ws, "run-abc", "backend") == expected
    end
  end

  describe "open_log/3" do
    test "opens a writable file and creates run_id directory", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir)
      assert {:ok, io} = Workspace.open_log(ws, "run-abc", "backend")

      IO.write(io, "line 1\n")
      IO.write(io, "line 2\n")
      File.close(io)

      log_content = File.read!(Workspace.log_path(ws, "run-abc", "backend"))
      assert log_content == "line 1\nline 2\n"
    end
  end

  # --- Integration / Multi-step ---

  describe "full workflow" do
    test "init → update state → update registry → write result → read all", %{tmp_dir: tmp_dir} do
      {:ok, ws} = init_workspace(tmp_dir, project: "integration", teams: ["alpha", "beta"])

      # Start alpha
      :ok = Workspace.update_team_state(ws, "alpha", status: "running")
      :ok = Workspace.update_registry_entry(ws, "alpha", status: "running", pid: 100)

      # Complete alpha
      :ok =
        Workspace.update_team_state(ws, "alpha",
          status: "done",
          result_summary: "Built alpha",
          cost_usd: 1.00,
          duration_ms: 30_000
        )

      :ok =
        Workspace.update_registry_entry(ws, "alpha",
          status: "done",
          ended_at: "2025-01-01T00:05:00Z"
        )

      :ok = Workspace.write_result(ws, "alpha", %{"output" => "alpha done"})

      # Start + complete beta
      :ok = Workspace.update_team_state(ws, "beta", status: "running")

      :ok =
        Workspace.update_team_state(ws, "beta",
          status: "done",
          result_summary: "Built beta",
          cost_usd: 0.75,
          duration_ms: 20_000
        )

      :ok = Workspace.write_result(ws, "beta", %{"output" => "beta done"})

      # Verify final state
      {:ok, state} = Workspace.read_state(ws)
      assert state.project == "integration"
      assert state.teams["alpha"].status == "done"
      assert state.teams["beta"].status == "done"
      assert state.teams["alpha"].cost_usd == 1.00
      assert state.teams["beta"].cost_usd == 0.75

      # Verify registry
      {:ok, registry} = Workspace.read_registry(ws)
      {:ok, alpha_entry} = RunRegistry.find_entry(registry, "alpha")
      assert alpha_entry.status == "done"
      assert alpha_entry.pid == 100

      # Verify results
      {:ok, alpha_result} = Workspace.read_result(ws, "alpha")
      assert alpha_result["output"] == "alpha done"
      {:ok, beta_result} = Workspace.read_result(ws, "beta")
      assert beta_result["output"] == "beta done"
    end
  end
end
