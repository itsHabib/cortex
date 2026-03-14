defmodule Cortex.TelemetryTest do
  use ExUnit.Case, async: true

  alias Cortex.Telemetry

  setup do
    # Attach a test handler that sends telemetry events to the test process
    test_pid = self()

    handler_id = "test-handler-#{inspect(test_pid)}-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      Telemetry.event_names(),
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "event_names/0" do
    test "returns all defined event names" do
      names = Telemetry.event_names()
      assert is_list(names)
      assert length(names) == 8

      assert [:cortex, :agent, :started] in names
      assert [:cortex, :agent, :stopped] in names
      assert [:cortex, :run, :started] in names
      assert [:cortex, :run, :completed] in names
      assert [:cortex, :tier, :completed] in names
      assert [:cortex, :team, :completed] in names
      assert [:cortex, :gossip, :exchange] in names
      assert [:cortex, :tool, :executed] in names
    end
  end

  describe "emit_agent_started/1" do
    test "emits agent started telemetry event" do
      metadata = %{agent_id: "test-123", name: "worker", role: "builder"}
      assert :ok = Telemetry.emit_agent_started(metadata)

      assert_receive {:telemetry_event, [:cortex, :agent, :started], %{}, ^metadata}
    end
  end

  describe "emit_agent_stopped/1" do
    test "emits agent stopped telemetry event" do
      metadata = %{agent_id: "test-123", reason: :normal}
      assert :ok = Telemetry.emit_agent_stopped(metadata)

      assert_receive {:telemetry_event, [:cortex, :agent, :stopped], %{}, ^metadata}
    end
  end

  describe "emit_run_started/1" do
    test "emits run started event with team count" do
      metadata = %{project: "demo", teams: ["a", "b", "c"]}
      assert :ok = Telemetry.emit_run_started(metadata)

      assert_receive {:telemetry_event, [:cortex, :run, :started], %{team_count: 3}, ^metadata}
    end

    test "handles missing teams key" do
      metadata = %{project: "demo"}
      assert :ok = Telemetry.emit_run_started(metadata)

      assert_receive {:telemetry_event, [:cortex, :run, :started], %{team_count: 0}, ^metadata}
    end
  end

  describe "emit_run_completed/1" do
    test "emits run completed event with duration" do
      metadata = %{project: "demo", duration_ms: 5000, status: :complete}
      assert :ok = Telemetry.emit_run_completed(metadata)

      assert_receive {:telemetry_event, [:cortex, :run, :completed], %{duration_ms: 5000},
                      ^metadata}
    end
  end

  describe "emit_tier_completed/1" do
    test "emits tier completed event" do
      metadata = %{tier_index: 0, teams: ["backend", "frontend"], failures: []}
      assert :ok = Telemetry.emit_tier_completed(metadata)

      assert_receive {:telemetry_event, [:cortex, :tier, :completed], %{team_count: 2}, ^metadata}
    end
  end

  describe "emit_team_completed/1" do
    test "emits team completed event with measurements" do
      metadata = %{team_name: "backend", status: :ok, duration_ms: 3000, cost_usd: 0.15}
      assert :ok = Telemetry.emit_team_completed(metadata)

      assert_receive {:telemetry_event, [:cortex, :team, :completed],
                      %{duration_ms: 3000, cost_usd: 0.15}, ^metadata}
    end
  end

  describe "emit_gossip_exchange/1" do
    test "emits gossip exchange event" do
      metadata = %{store_a: "agent-1", store_b: "agent-2", duration_us: 150}
      assert :ok = Telemetry.emit_gossip_exchange(metadata)

      assert_receive {:telemetry_event, [:cortex, :gossip, :exchange], %{duration_us: 150},
                      ^metadata}
    end
  end

  describe "emit_tool_executed/1" do
    test "emits tool executed event" do
      metadata = %{tool_name: "shell", success: true, duration_ms: 250}
      assert :ok = Telemetry.emit_tool_executed(metadata)

      assert_receive {:telemetry_event, [:cortex, :tool, :executed], %{duration_ms: 250},
                      ^metadata}
    end
  end
end
