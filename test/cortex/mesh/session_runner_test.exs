defmodule Cortex.Mesh.SessionRunnerTest do
  use ExUnit.Case, async: false

  alias Cortex.Mesh.Config, as: MeshConfig
  alias Cortex.Mesh.Config.{Agent, MeshSettings}
  alias Cortex.Mesh.SessionRunner
  alias Cortex.Orchestration.Config.Defaults

  setup do
    :ok
  end

  @config %MeshConfig{
    name: "test-mesh",
    cluster_context: "Test cluster.",
    defaults: %Defaults{model: "sonnet", max_turns: 10, timeout_minutes: 1},
    mesh: %MeshSettings{
      heartbeat_interval_seconds: 30,
      suspect_timeout_seconds: 90,
      dead_timeout_seconds: 180
    },
    agents: [
      %Agent{name: "agent-a", role: "researcher", prompt: "Research things."},
      %Agent{name: "agent-b", role: "analyst", prompt: "Analyze things."}
    ]
  }

  describe "dry run" do
    test "returns plan without spawning" do
      {:ok, plan} = SessionRunner.run_config(@config, dry_run: true)

      assert plan.status == :dry_run
      assert plan.mode == :mesh
      assert plan.project == "test-mesh"
      assert plan.total_agents == 2
      assert length(plan.agents) == 2
      assert plan.heartbeat_interval == 30
      assert plan.suspect_timeout == 90
      assert plan.dead_timeout == 180
    end

    test "agents include name, role, and model" do
      {:ok, plan} = SessionRunner.run_config(@config, dry_run: true)

      [first | _] = plan.agents
      assert first.name == "agent-a"
      assert first.role == "researcher"
      assert first.model == "sonnet"
    end

    test "dry run from YAML file" do
      tmp_dir = Path.join(System.tmp_dir!(), "mesh_dr_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      yaml = """
      name: test-from-file
      mode: mesh
      agents:
        - name: a
          role: researcher
          prompt: do it
      """

      path = Path.join(tmp_dir, "mesh.yaml")
      File.write!(path, yaml)

      {:ok, plan} = SessionRunner.run(path, dry_run: true)
      assert plan.project == "test-from-file"
      assert plan.total_agents == 1

      File.rm_rf!(tmp_dir)
    end
  end

  describe "execution with mock" do
    @tag :tmp_dir
    test "runs agents with mock script and returns summary", %{tmp_dir: tmp_dir} do
      # Create a mock script that outputs valid NDJSON
      mock_script = Path.join(tmp_dir, "mock_claude.sh")

      File.write!(mock_script, """
      #!/bin/bash
      echo '{"type":"system","subtype":"init","session_id":"mock-sess-123"}'
      echo '{"type":"result","result":"Mock result from agent","subtype":"success","session_id":"mock-sess-123","total_cost_usd":0.001,"num_turns":2,"duration_ms":500,"usage":{"input_tokens":100,"output_tokens":50}}'
      """)

      File.chmod!(mock_script, 0o755)

      config = %{
        @config
        | defaults: %Defaults{model: "sonnet", max_turns: 10, timeout_minutes: 1}
      }

      {:ok, summary} =
        SessionRunner.run_config(config,
          workspace_path: tmp_dir,
          command: mock_script
        )

      assert summary.status == :complete
      assert summary.mode == :mesh
      assert summary.project == "test-mesh"
      assert summary.total_agents == 2
      assert map_size(summary.agents) == 2

      # Check agent results
      assert summary.agents["agent-a"].status == :success
      assert summary.agents["agent-b"].status == :success
    end

    @tag :tmp_dir
    test "handles agent failures gracefully", %{tmp_dir: tmp_dir} do
      # Create a mock script that exits with error
      mock_script = Path.join(tmp_dir, "mock_fail.sh")

      File.write!(mock_script, """
      #!/bin/bash
      echo '{"type":"system","subtype":"init","session_id":"fail-sess"}'
      exit 1
      """)

      File.chmod!(mock_script, 0o755)

      config = %{
        @config
        | defaults: %Defaults{model: "sonnet", max_turns: 10, timeout_minutes: 1}
      }

      {:ok, summary} =
        SessionRunner.run_config(config,
          workspace_path: tmp_dir,
          command: mock_script
        )

      assert summary.status == :partial
      assert summary.total_agents == 2
    end

    @tag :tmp_dir
    test "creates workspace directories", %{tmp_dir: tmp_dir} do
      mock_script = Path.join(tmp_dir, "mock_claude.sh")

      File.write!(mock_script, """
      #!/bin/bash
      echo '{"type":"system","subtype":"init","session_id":"ws-test"}'
      echo '{"type":"result","result":"done","subtype":"success"}'
      """)

      File.chmod!(mock_script, 0o755)

      config = %{
        @config
        | defaults: %Defaults{model: "sonnet", max_turns: 10, timeout_minutes: 1}
      }

      SessionRunner.run_config(config, workspace_path: tmp_dir, command: mock_script)

      # Check workspace was created
      assert File.exists?(Path.join([tmp_dir, ".cortex", "messages", "agent-a", "inbox.json"]))
      assert File.exists?(Path.join([tmp_dir, ".cortex", "messages", "agent-b", "inbox.json"]))
    end

    @tag :tmp_dir
    test "writes run summary file", %{tmp_dir: tmp_dir} do
      mock_script = Path.join(tmp_dir, "mock_claude.sh")

      File.write!(mock_script, """
      #!/bin/bash
      echo '{"type":"system","subtype":"init","session_id":"sum-test"}'
      echo '{"type":"result","result":"done","subtype":"success","usage":{"input_tokens":10,"output_tokens":5}}'
      """)

      File.chmod!(mock_script, 0o755)

      config = %{
        @config
        | defaults: %Defaults{model: "sonnet", max_turns: 10, timeout_minutes: 1}
      }

      SessionRunner.run_config(config, workspace_path: tmp_dir, command: mock_script)

      summaries_dir = Path.join([tmp_dir, ".cortex", "summaries"])
      assert File.exists?(summaries_dir)

      files = File.ls!(summaries_dir)
      mesh_summaries = Enum.filter(files, &String.contains?(&1, "mesh_complete"))
      assert mesh_summaries != []
    end
  end
end
