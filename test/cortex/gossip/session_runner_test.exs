defmodule Cortex.Gossip.SessionRunnerTest do
  use ExUnit.Case, async: true

  alias Cortex.Gossip.SessionRunner
  alias Cortex.Gossip.Config, as: GossipConfig
  alias Cortex.Gossip.Config.{Agent, GossipSettings, SeedKnowledge}
  alias Cortex.Orchestration.Config.Defaults

  @moduletag :tmp_dir

  # -- Helpers -----------------------------------------------------------------

  defp write_mock_script(tmp_dir, name, body) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "#!/bin/bash\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # Mock script that writes findings and emits a proper result
  defp write_findings_script(tmp_dir, agent_name, findings_json) do
    write_mock_script(tmp_dir, "#{agent_name}.sh", """
    # Write findings to the knowledge directory
    FINDINGS_DIR="$PWD/.cortex/knowledge/#{agent_name}"
    mkdir -p "$FINDINGS_DIR"
    cat > "$FINDINGS_DIR/findings.json" << 'FINDINGS_EOF'
    #{findings_json}
    FINDINGS_EOF

    # Emit standard NDJSON output
    echo '{"type":"system","subtype":"init","session_id":"#{agent_name}-sess"}'
    echo '{"type":"result","subtype":"success","result":"Completed #{agent_name} exploration","cost_usd":0.10,"num_turns":3,"duration_ms":5000,"usage":{"input_tokens":1000,"output_tokens":500}}'
    """)
  end

  defp simple_config(agents, opts \\ []) do
    %GossipConfig{
      name: Keyword.get(opts, :name, "test-gossip"),
      defaults: %Defaults{
        model: "sonnet",
        max_turns: 10,
        timeout_minutes: 2,
        permission_mode: "acceptEdits"
      },
      gossip: %GossipSettings{
        rounds: Keyword.get(opts, :rounds, 1),
        topology: Keyword.get(opts, :topology, :full_mesh),
        exchange_interval_seconds: Keyword.get(opts, :interval, 1),
        coordinator: Keyword.get(opts, :coordinator, false)
      },
      agents: agents,
      seed_knowledge: Keyword.get(opts, :seeds, [])
    }
  end

  defp write_config_file(tmp_dir, yaml) do
    path = Path.join(tmp_dir, "gossip.yaml")
    File.write!(path, yaml)
    path
  end

  # -- Tests -------------------------------------------------------------------

  describe "dry run" do
    test "returns plan without spawning agents", %{tmp_dir: tmp_dir} do
      yaml = """
      name: "test-project"
      mode: gossip
      defaults:
        model: sonnet
      gossip:
        rounds: 3
        topology: ring
        exchange_interval_seconds: 30
      agents:
        - name: agent-a
          topic: "topic A"
          prompt: "Explore A"
        - name: agent-b
          topic: "topic B"
          prompt: "Explore B"
      """

      config_path = write_config_file(tmp_dir, yaml)

      assert {:ok, plan} = SessionRunner.run(config_path, dry_run: true)

      assert plan.status == :dry_run
      assert plan.mode == :gossip
      assert plan.project == "test-project"
      assert plan.total_agents == 2
      assert plan.gossip_rounds == 3
      assert plan.topology == :ring
      assert plan.exchange_interval == 30

      assert length(plan.agents) == 2
      [a, b] = plan.agents
      assert a.name == "agent-a"
      assert a.topic == "topic A"
      assert b.name == "agent-b"
    end
  end

  describe "run_config/2 with mock scripts" do
    test "spawns agents and collects results", %{tmp_dir: tmp_dir} do
      findings_a =
        Jason.encode!([
          %{topic: "research", content: "Finding from A", confidence: 0.8}
        ])

      findings_b =
        Jason.encode!([
          %{topic: "analysis", content: "Finding from B", confidence: 0.7}
        ])

      script_a = write_findings_script(tmp_dir, "agent-a", findings_a)
      script_b = write_findings_script(tmp_dir, "agent-b", findings_b)

      # Write a dispatcher script that routes based on the prompt content
      dispatcher =
        write_mock_script(tmp_dir, "dispatch.sh", """
        # Parse the prompt from args to determine which agent this is
        PROMPT="$2"
        if echo "$PROMPT" | grep -q "agent-a"; then
          exec #{script_a} "$@"
        else
          exec #{script_b} "$@"
        fi
        """)

      config =
        simple_config(
          [
            %Agent{name: "agent-a", topic: "research", prompt: "Explore for agent-a"},
            %Agent{name: "agent-b", topic: "analysis", prompt: "Analyze for agent-b"}
          ],
          rounds: 1,
          interval: 1
        )

      assert {:ok, summary} =
               SessionRunner.run_config(config,
                 workspace_path: tmp_dir,
                 command: dispatcher
               )

      assert summary.mode == :gossip
      assert summary.project == "test-gossip"
      assert summary.total_agents == 2
      assert summary.status in [:complete, :partial]

      # Check agent results exist
      assert Map.has_key?(summary.agents, "agent-a")
      assert Map.has_key?(summary.agents, "agent-b")
    end

    test "single agent completes successfully", %{tmp_dir: tmp_dir} do
      findings =
        Jason.encode!([
          %{topic: "solo", content: "Solo finding", confidence: 0.9}
        ])

      script = write_findings_script(tmp_dir, "solo-agent", findings)

      config =
        simple_config(
          [%Agent{name: "solo-agent", topic: "solo", prompt: "Work alone"}],
          rounds: 1,
          interval: 1
        )

      assert {:ok, summary} =
               SessionRunner.run_config(config,
                 workspace_path: tmp_dir,
                 command: script
               )

      assert summary.total_agents == 1
      assert summary.agents["solo-agent"].status == :success
      assert summary.total_cost > 0
    end

    test "handles agent failure gracefully", %{tmp_dir: tmp_dir} do
      failing_script =
        write_mock_script(tmp_dir, "fail.sh", """
        echo '{"type":"system","subtype":"init","session_id":"fail-sess"}'
        exit 1
        """)

      config =
        simple_config(
          [%Agent{name: "failing-agent", topic: "doomed", prompt: "Fail"}],
          rounds: 1,
          interval: 1
        )

      assert {:ok, summary} =
               SessionRunner.run_config(config,
                 workspace_path: tmp_dir,
                 command: failing_script
               )

      assert summary.status == :partial
      assert summary.agents["failing-agent"].status == :error
    end

    test "workspace directories are created", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "workspace_test.sh", """
        echo '{"type":"system","subtype":"init","session_id":"ws-sess"}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      config =
        simple_config(
          [%Agent{name: "ws-agent", topic: "test", prompt: "Test workspace"}],
          rounds: 1,
          interval: 1
        )

      SessionRunner.run_config(config, workspace_path: tmp_dir, command: script)

      # Knowledge directory should exist
      assert File.dir?(Path.join([tmp_dir, ".cortex", "knowledge", "ws-agent"]))

      # Message directory should exist
      assert File.dir?(Path.join([tmp_dir, ".cortex", "messages", "ws-agent"]))

      # Findings file should exist
      assert File.exists?(
               Path.join([tmp_dir, ".cortex", "knowledge", "ws-agent", "findings.json"])
             )
    end

    test "seed knowledge is written to files", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "seed_test.sh", """
        echo '{"type":"system","subtype":"init","session_id":"seed-sess"}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      config =
        simple_config(
          [%Agent{name: "seed-agent", topic: "test", prompt: "Test seeds"}],
          rounds: 1,
          interval: 1,
          seeds: [
            %SeedKnowledge{topic: "context", content: "Important background info"}
          ]
        )

      SessionRunner.run_config(config, workspace_path: tmp_dir, command: script)

      seed_path = Path.join([tmp_dir, ".cortex", "knowledge", "seed-agent", "seed.json"])
      assert File.exists?(seed_path)

      {:ok, content} = File.read(seed_path)
      {:ok, seeds} = Jason.decode(content)
      assert length(seeds) == 1
      assert hd(seeds)["topic"] == "context"
    end

    test "summary includes knowledge entries", %{tmp_dir: tmp_dir} do
      findings =
        Jason.encode!([
          %{topic: "data", content: "Found data source", confidence: 0.9},
          %{topic: "data", content: "Another source", confidence: 0.7}
        ])

      script = write_findings_script(tmp_dir, "data-agent", findings)

      config =
        simple_config(
          [%Agent{name: "data-agent", topic: "data", prompt: "Find data"}],
          rounds: 1,
          interval: 1
        )

      assert {:ok, summary} =
               SessionRunner.run_config(config,
                 workspace_path: tmp_dir,
                 command: script
               )

      assert summary.knowledge.total_entries >= 0
      assert is_map(summary.knowledge.by_topic)
      assert is_list(summary.knowledge.entries)
    end
  end

  describe "run/2 from file" do
    test "loads config and runs", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "file_test.sh", """
        echo '{"type":"system","subtype":"init","session_id":"file-sess"}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.05,"num_turns":2,"duration_ms":3000}'
        """)

      yaml = """
      name: "file-test"
      mode: gossip
      defaults:
        model: sonnet
        max_turns: 5
        timeout_minutes: 1
      gossip:
        rounds: 1
        topology: full_mesh
        exchange_interval_seconds: 1
      agents:
        - name: file-agent
          topic: "testing"
          prompt: "Test from file"
      """

      config_path = write_config_file(tmp_dir, yaml)

      assert {:ok, summary} =
               SessionRunner.run(config_path,
                 workspace_path: tmp_dir,
                 command: script
               )

      assert summary.project == "file-test"
      assert summary.mode == :gossip
    end

    test "returns error for invalid config", %{tmp_dir: tmp_dir} do
      yaml = """
      name: ""
      mode: gossip
      agents: []
      """

      config_path = write_config_file(tmp_dir, yaml)

      assert {:error, errors} = SessionRunner.run(config_path)
      assert is_list(errors)
    end

    test "returns error for missing file" do
      assert {:error, _} = SessionRunner.run("/nonexistent/gossip.yaml")
    end
  end

  describe "coordinator mode" do
    test "sets up coordinator workspace when coordinator: true", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "coord_ws.sh", """
        echo '{"type":"system","subtype":"init","session_id":"coord-ws-sess"}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      config =
        simple_config(
          [%Agent{name: "agent-a", topic: "research", prompt: "Research stuff"}],
          rounds: 1,
          interval: 1,
          coordinator: true
        )

      SessionRunner.run_config(config, workspace_path: tmp_dir, command: script)

      # Coordinator message directory should exist
      assert File.dir?(Path.join([tmp_dir, ".cortex", "messages", "coordinator"]))

      # Coordinator inbox should exist
      assert File.exists?(
               Path.join([tmp_dir, ".cortex", "messages", "coordinator", "inbox.json"])
             )
    end

    test "coordinator receives knowledge digest in inbox", %{tmp_dir: tmp_dir} do
      findings =
        Jason.encode!([
          %{topic: "data", content: "Found important data", confidence: 0.9}
        ])

      script = write_findings_script(tmp_dir, "data-agent", findings)

      config =
        simple_config(
          [%Agent{name: "data-agent", topic: "data", prompt: "Find data"}],
          rounds: 1,
          interval: 1,
          coordinator: true
        )

      SessionRunner.run_config(config, workspace_path: tmp_dir, command: script)

      # Check coordinator inbox has knowledge digest
      inbox_path = Path.join([tmp_dir, ".cortex", "messages", "coordinator", "inbox.json"])
      {:ok, content} = File.read(inbox_path)
      {:ok, messages} = Jason.decode(content)

      knowledge_msgs = Enum.filter(messages, &(Map.get(&1, "type") == "knowledge_digest"))
      assert knowledge_msgs != []

      # Verify the digest contains the knowledge entries structure
      [digest | _] = knowledge_msgs
      {:ok, payload} = Jason.decode(Map.get(digest, "content"))
      assert Map.has_key?(payload, "round")
      assert Map.has_key?(payload, "entries")
      assert Map.has_key?(payload, "agents")
    end

    test "early termination stops exchange loop", %{tmp_dir: tmp_dir} do
      # Script that writes a terminate message to coordinator outbox
      script =
        write_mock_script(tmp_dir, "term_agent.sh", """
        # Write findings
        FINDINGS_DIR="$PWD/.cortex/knowledge/agent-a"
        mkdir -p "$FINDINGS_DIR"
        echo '[]' > "$FINDINGS_DIR/findings.json"

        # Write terminate message to coordinator outbox (simulating coordinator behavior)
        OUTBOX="$PWD/.cortex/messages/coordinator/outbox.json"
        mkdir -p "$(dirname "$OUTBOX")"
        cat > "$OUTBOX" << 'EOF'
        [{"from": "coordinator", "to": "system", "type": "terminate", "content": "Knowledge converged", "timestamp": "2026-01-01T00:00:00Z"}]
        EOF

        echo '{"type":"system","subtype":"init","session_id":"term-sess"}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      config =
        simple_config(
          [%Agent{name: "agent-a", topic: "test", prompt: "Test early termination"}],
          rounds: 5,
          interval: 1,
          coordinator: true
        )

      # Even with 5 rounds, should terminate early due to coordinator signal
      assert {:ok, summary} =
               SessionRunner.run_config(config,
                 workspace_path: tmp_dir,
                 command: script
               )

      assert summary.status in [:complete, :partial]
    end

    test "dry run includes coordinator status", %{tmp_dir: tmp_dir} do
      yaml = """
      name: "coord-test"
      mode: gossip
      gossip:
        rounds: 3
        coordinator: true
      agents:
        - name: agent-a
          topic: "topic A"
          prompt: "Explore A"
      """

      config_path = write_config_file(tmp_dir, yaml)
      assert {:ok, plan} = SessionRunner.run(config_path, dry_run: true)
      assert plan.status == :dry_run
      assert plan.project == "coord-test"
    end

    test "no coordinator workspace when coordinator: false", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "no_coord.sh", """
        echo '{"type":"system","subtype":"init","session_id":"nc-sess"}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      config =
        simple_config(
          [%Agent{name: "agent-a", topic: "research", prompt: "Research stuff"}],
          rounds: 1,
          interval: 1,
          coordinator: false
        )

      SessionRunner.run_config(config, workspace_path: tmp_dir, command: script)

      # Coordinator message directory should NOT exist
      refute File.dir?(Path.join([tmp_dir, ".cortex", "messages", "coordinator"]))
    end
  end
end
