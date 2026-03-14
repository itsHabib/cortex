defmodule Cortex.LoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cortex.Logger, as: CortexLogger

  # Note: test config sets logger level to :warning, so info/debug messages
  # are suppressed. We test those return :ok, and test warn/error for content.

  describe "info/2" do
    test "returns :ok" do
      assert :ok = CortexLogger.info("test info message")
    end

    test "returns :ok with metadata" do
      assert :ok = CortexLogger.info("test info", project: "demo")
    end
  end

  describe "warn/2" do
    test "logs warning message" do
      log =
        capture_log(fn ->
          CortexLogger.warn("test warning", team: "backend")
        end)

      assert log =~ "test warning"
    end

    test "returns :ok" do
      capture_log(fn ->
        assert :ok = CortexLogger.warn("test")
      end)
    end
  end

  describe "error/2" do
    test "logs error message" do
      log =
        capture_log(fn ->
          CortexLogger.error("test error", reason: :timeout)
        end)

      assert log =~ "test error"
    end

    test "returns :ok" do
      capture_log(fn ->
        assert :ok = CortexLogger.error("test")
      end)
    end
  end

  describe "debug/2" do
    test "returns :ok" do
      assert :ok = CortexLogger.debug("test debug message")
    end
  end

  describe "metadata" do
    test "accepts empty metadata" do
      assert :ok = CortexLogger.warn("no extra metadata")
    end

    test "accepts keyword list metadata" do
      assert :ok = CortexLogger.warn("with metadata", project: "cortex", team: "backend")
    end
  end
end
