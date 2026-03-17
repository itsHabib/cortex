defmodule Cortex.Mesh.PromptTest do
  use ExUnit.Case, async: true

  alias Cortex.Mesh.Config, as: MeshConfig
  alias Cortex.Mesh.Config.{Agent, MeshSettings}
  alias Cortex.Mesh.Prompt
  alias Cortex.Orchestration.Config.Defaults

  @agent %Agent{name: "market-sizing", role: "Market researcher", prompt: "Research market size."}

  @config %MeshConfig{
    name: "test-mesh",
    cluster_context: "We're researching the Hyrox market.",
    defaults: %Defaults{},
    mesh: %MeshSettings{},
    agents: [
      @agent,
      %Agent{name: "competitor", role: "Competitive analyst", prompt: "Analyze competitors."}
    ]
  }

  @roster [
    %{name: "market-sizing", role: "Market researcher", state: :alive},
    %{name: "competitor", role: "Competitive analyst", state: :alive}
  ]

  describe "build/4" do
    test "includes agent identity" do
      prompt = Prompt.build(@agent, @config, @roster, "/tmp/workspace")
      assert prompt =~ "market-sizing"
      assert prompt =~ "Market researcher"
    end

    test "includes cluster context" do
      prompt = Prompt.build(@agent, @config, @roster, "/tmp/workspace")
      assert prompt =~ "Hyrox"
    end

    test "includes roster table" do
      prompt = Prompt.build(@agent, @config, @roster, "/tmp/workspace")
      assert prompt =~ "Mesh Roster"
      assert prompt =~ "market-sizing"
      assert prompt =~ "competitor"
    end

    test "includes assignment" do
      prompt = Prompt.build(@agent, @config, @roster, "/tmp/workspace")
      assert prompt =~ "Research market size."
    end

    test "includes messaging instructions" do
      prompt = Prompt.build(@agent, @config, @roster, "/tmp/workspace")
      assert prompt =~ "outbox"
      assert prompt =~ "inbox"
      assert prompt =~ "competitor"
    end

    test "includes autonomy instructions" do
      prompt = Prompt.build(@agent, @config, @roster, "/tmp/workspace")
      assert prompt =~ "NOT required to coordinate"
    end

    test "excludes self from available agents list" do
      prompt = Prompt.build(@agent, @config, @roster, "/tmp/workspace")
      # The messaging section lists "available agents" — should have competitor but not self
      lines = String.split(prompt, "\n")

      available_section =
        lines
        |> Enum.drop_while(fn l -> not String.contains?(l, "Available agents") end)
        |> Enum.take(5)
        |> Enum.join("\n")

      assert available_section =~ "competitor"
    end

    test "handles nil cluster_context" do
      config = %{@config | cluster_context: nil}
      prompt = Prompt.build(@agent, config, @roster, "/tmp/workspace")
      refute prompt =~ "Cluster Context"
    end

    test "handles empty roster" do
      prompt = Prompt.build(@agent, @config, [], "/tmp/workspace")
      refute prompt =~ "Mesh Roster"
    end
  end
end
