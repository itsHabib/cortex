defmodule Cortex.Gossip.CoordinatorPromptTest do
  use ExUnit.Case, async: true

  alias Cortex.Gossip.Config, as: GossipConfig
  alias Cortex.Gossip.Config.{Agent, GossipSettings}
  alias Cortex.Gossip.CoordinatorPrompt
  alias Cortex.Orchestration.Config.Defaults

  @moduletag :tmp_dir

  defp sample_config(opts \\ []) do
    %GossipConfig{
      name: Keyword.get(opts, :name, "test-project"),
      cluster_context: Keyword.get(opts, :cluster_context),
      defaults: %Defaults{
        model: "sonnet",
        max_turns: 20,
        timeout_minutes: 15,
        permission_mode: "acceptEdits"
      },
      gossip: %GossipSettings{
        rounds: Keyword.get(opts, :rounds, 5),
        topology: :random,
        exchange_interval_seconds: Keyword.get(opts, :interval, 60),
        coordinator: true
      },
      agents:
        Keyword.get(opts, :agents, [
          %Agent{name: "agent-a", topic: "competitor analysis", prompt: "Research competitors"},
          %Agent{name: "agent-b", topic: "market sizing", prompt: "Estimate the TAM"},
          %Agent{name: "agent-c", topic: "product ideas", prompt: "Brainstorm products"}
        ])
    }
  end

  describe "build/2" do
    test "includes project name", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(), tmp_dir)
      assert prompt =~ "Project: test-project"
    end

    test "includes gossip coordinator role", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(), tmp_dir)
      assert prompt =~ "Gossip Coordinator"
    end

    test "includes all agent names and topics", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(), tmp_dir)
      assert prompt =~ "agent-a"
      assert prompt =~ "competitor analysis"
      assert prompt =~ "agent-b"
      assert prompt =~ "market sizing"
      assert prompt =~ "agent-c"
      assert prompt =~ "product ideas"
    end

    test "includes synthesize instructions", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(), tmp_dir)
      assert prompt =~ "Synthesize"
      assert prompt =~ "synthesis summary"
      assert prompt =~ "Gaps"
      assert prompt =~ "Contradictions"
    end

    test "includes steer instructions", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(), tmp_dir)
      assert prompt =~ "Steer"
      assert prompt =~ "steering messages"
    end

    test "includes message summarization instructions", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(), tmp_dir)
      assert prompt =~ "Summarize Messages"
      assert prompt =~ "relay relevant information"
    end

    test "includes termination instructions", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(), tmp_dir)
      assert prompt =~ "Terminate Early"
      assert prompt =~ "terminate"
      assert prompt =~ "converged"
    end

    test "includes workspace paths", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(), tmp_dir)
      assert prompt =~ Path.join([tmp_dir, ".cortex", "messages", "coordinator", "inbox.json"])
      assert prompt =~ Path.join([tmp_dir, ".cortex", "messages", "coordinator", "outbox.json"])
      assert prompt =~ Path.join([tmp_dir, ".cortex", "knowledge"])
    end

    test "includes session parameters", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(rounds: 7, interval: 90), tmp_dir)
      assert prompt =~ "Gossip rounds: 7"
      assert prompt =~ "Exchange interval: 90s"
    end

    test "includes cluster context when present", %{tmp_dir: tmp_dir} do
      prompt =
        CoordinatorPrompt.build(
          sample_config(cluster_context: "We are researching the Hyrox market"),
          tmp_dir
        )

      assert prompt =~ "Cluster Context"
      assert prompt =~ "We are researching the Hyrox market"
    end

    test "omits cluster context when nil", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(cluster_context: nil), tmp_dir)
      refute prompt =~ "Cluster Context"
    end

    test "includes outbox polling for each agent", %{tmp_dir: tmp_dir} do
      prompt = CoordinatorPrompt.build(sample_config(), tmp_dir)
      assert prompt =~ "agent-a/outbox.json"
      assert prompt =~ "agent-b/outbox.json"
      assert prompt =~ "agent-c/outbox.json"
    end

    test "poll interval scales with exchange interval", %{tmp_dir: tmp_dir} do
      # 60s exchange -> 20s poll (60/3)
      prompt = CoordinatorPrompt.build(sample_config(interval: 60), tmp_dir)
      assert prompt =~ "/loop 20s"

      # 180s exchange -> 1m poll (180/3 = 60)
      prompt = CoordinatorPrompt.build(sample_config(interval: 180), tmp_dir)
      assert prompt =~ "/loop 1m"

      # 15s exchange -> 10s poll (clamped minimum)
      prompt = CoordinatorPrompt.build(sample_config(interval: 15), tmp_dir)
      assert prompt =~ "/loop 10s"
    end

    test "includes agent model override note", %{tmp_dir: tmp_dir} do
      agents = [
        %Agent{name: "smart-one", topic: "deep work", prompt: "Go deep", model: "opus"}
      ]

      prompt = CoordinatorPrompt.build(sample_config(agents: agents), tmp_dir)
      assert prompt =~ "model: opus"
    end
  end
end
