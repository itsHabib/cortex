defmodule Cortex.Mesh.Coordinator.PromptTest do
  use ExUnit.Case, async: true

  alias Cortex.Mesh.Config, as: MeshConfig
  alias Cortex.Mesh.Config.{Agent, MeshSettings}
  alias Cortex.Mesh.Coordinator.Prompt
  alias Cortex.Orchestration.Config.Defaults

  @moduletag :tmp_dir

  defp sample_config(opts \\ []) do
    %MeshConfig{
      name: Keyword.get(opts, :name, "test-mesh"),
      cluster_context: Keyword.get(opts, :cluster_context),
      defaults: %Defaults{
        model: "sonnet",
        max_turns: 200,
        timeout_minutes: 30,
        permission_mode: "acceptEdits"
      },
      mesh: %MeshSettings{
        heartbeat_interval_seconds: 30,
        suspect_timeout_seconds: 90,
        dead_timeout_seconds: 180,
        coordinator: true
      },
      agents:
        Keyword.get(opts, :agents, [
          %Agent{name: "backend", role: "backend engineer", prompt: "Build the API"},
          %Agent{name: "frontend", role: "frontend engineer", prompt: "Build the UI"},
          %Agent{name: "devops", role: "DevOps engineer", prompt: "Set up infra"}
        ])
    }
  end

  defp sample_roster do
    [
      %{name: "backend", role: "backend engineer", state: :alive},
      %{name: "frontend", role: "frontend engineer", state: :alive},
      %{name: "devops", role: "DevOps engineer", state: :alive}
    ]
  end

  describe "build/3" do
    test "includes project name", %{tmp_dir: tmp_dir} do
      prompt = Prompt.build(sample_config(), tmp_dir, sample_roster())
      assert prompt =~ "Project: test-mesh"
    end

    test "includes mesh coordinator role", %{tmp_dir: tmp_dir} do
      prompt = Prompt.build(sample_config(), tmp_dir, sample_roster())
      assert prompt =~ "Mesh Coordinator"
    end

    test "includes all agent names and roles", %{tmp_dir: tmp_dir} do
      prompt = Prompt.build(sample_config(), tmp_dir, sample_roster())
      assert prompt =~ "backend"
      assert prompt =~ "backend engineer"
      assert prompt =~ "frontend"
      assert prompt =~ "frontend engineer"
      assert prompt =~ "devops"
      assert prompt =~ "DevOps engineer"
    end

    test "includes workspace paths", %{tmp_dir: tmp_dir} do
      prompt = Prompt.build(sample_config(), tmp_dir, sample_roster())
      assert prompt =~ Path.join([tmp_dir, ".cortex", "messages", "coordinator", "inbox.json"])
      assert prompt =~ Path.join([tmp_dir, ".cortex", "messages", "coordinator", "outbox.json"])
      assert prompt =~ Path.join([tmp_dir, ".cortex", "logs"])
    end

    test "includes monitoring instructions", %{tmp_dir: tmp_dir} do
      prompt = Prompt.build(sample_config(), tmp_dir, sample_roster())
      assert prompt =~ "Monitor"
      assert prompt =~ "Detect Issues"
      assert prompt =~ "Status Summaries"
    end

    test "emphasizes autonomy — coordinator is observer", %{tmp_dir: tmp_dir} do
      prompt = Prompt.build(sample_config(), tmp_dir, sample_roster())
      assert prompt =~ "OBSERVER"
      assert prompt =~ "autonomous"
      assert prompt =~ "Do NOT tell agents what to do"
    end

    test "includes outbox polling for each agent", %{tmp_dir: tmp_dir} do
      prompt = Prompt.build(sample_config(), tmp_dir, sample_roster())
      assert prompt =~ "backend/outbox.json"
      assert prompt =~ "frontend/outbox.json"
      assert prompt =~ "devops/outbox.json"
    end

    test "includes cluster context when present", %{tmp_dir: tmp_dir} do
      prompt =
        Prompt.build(
          sample_config(cluster_context: "Building an e-commerce platform"),
          tmp_dir,
          sample_roster()
        )

      assert prompt =~ "Cluster Context"
      assert prompt =~ "Building an e-commerce platform"
    end

    test "omits cluster context when nil", %{tmp_dir: tmp_dir} do
      prompt = Prompt.build(sample_config(cluster_context: nil), tmp_dir, sample_roster())
      refute prompt =~ "Cluster Context"
    end

    test "includes inbox loop setup", %{tmp_dir: tmp_dir} do
      prompt = Prompt.build(sample_config(), tmp_dir, sample_roster())
      assert prompt =~ "/loop 30s"
      assert prompt =~ "inbox.json"
    end
  end
end
