defmodule Cortex.Orchestration.SpawnerTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.{Spawner, TeamResult}

  @moduletag :tmp_dir

  # -- Helpers ---------------------------------------------------------------

  defp write_mock_script(tmp_dir, name, body) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "#!/bin/bash\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp base_opts(tmp_dir, script_path) do
    [
      team_name: "test-team",
      prompt: "Do the thing",
      command: script_path,
      timeout_minutes: 1,
      log_path: Path.join(tmp_dir, "test.log")
    ]
  end

  # -- Tests -----------------------------------------------------------------

  describe "spawn/1 with valid NDJSON result" do
    test "parses a successful result from mock script", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "success.sh", """
        echo '{"type":"system","subtype":"init","session_id":"test-sess-001"}'
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Working..."}]}}'
        echo '{"type":"result","subtype":"success","result":"All tasks completed","cost_usd":0.45,"num_turns":5,"duration_ms":30000,"session_id":"test-sess-001"}'
        """)

      assert {:ok, %TeamResult{} = result} =
               Spawner.spawn(base_opts(tmp_dir, script))

      assert result.team == "test-team"
      assert result.status == :success
      assert result.result == "All tasks completed"
      assert result.cost_usd == 0.45
      assert result.num_turns == 5
      assert result.duration_ms == 30_000
      assert result.session_id == "test-sess-001"
    end

    test "captures session_id from system init line", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "session.sh", """
        echo '{"type":"system","subtype":"init","session_id":"unique-session-42"}'
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.10,"num_turns":1,"duration_ms":5000}'
        """)

      assert {:ok, %TeamResult{session_id: "unique-session-42"}} =
               Spawner.spawn(base_opts(tmp_dir, script))
    end

    test "falls back to session_id from result line when no init line", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "no_init.sh", """
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.10,"num_turns":1,"duration_ms":5000,"session_id":"from-result"}'
        """)

      assert {:ok, %TeamResult{session_id: "from-result"}} =
               Spawner.spawn(base_opts(tmp_dir, script))
    end

    test "handles error subtype in result line", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "error_result.sh", """
        echo '{"type":"system","subtype":"init","session_id":"err-sess"}'
        echo '{"type":"result","subtype":"error","result":"Tool execution failed","cost_usd":0.05,"num_turns":2,"duration_ms":10000}'
        """)

      assert {:ok, %TeamResult{status: :error, result: "Tool execution failed"}} =
               Spawner.spawn(base_opts(tmp_dir, script))
    end
  end

  describe "spawn/1 with non-zero exit code" do
    test "returns error tuple with exit code", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "fail.sh", """
        echo '{"type":"system","subtype":"init","session_id":"fail-sess"}'
        exit 1
        """)

      assert {:error, {:exit_code, 1}} =
               Spawner.spawn(base_opts(tmp_dir, script))
    end

    test "returns specific exit code value", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "fail42.sh", """
        exit 42
        """)

      assert {:error, {:exit_code, 42}} =
               Spawner.spawn(base_opts(tmp_dir, script))
    end
  end

  describe "spawn/1 with timeout" do
    test "kills the process and returns timeout status", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "hang.sh", """
        echo '{"type":"system","subtype":"init","session_id":"hang-sess"}'
        sleep 300
        """)

      # Use a short timeout (5 seconds = 5/60 minute).
      # Must be long enough for the shell to start and emit the echo line
      # before the timer fires, even on a loaded system.
      opts =
        tmp_dir
        |> base_opts(script)
        |> Keyword.put(:timeout_minutes, 5 / 60)

      start = System.monotonic_time(:millisecond)
      result = Spawner.spawn(opts)
      elapsed = System.monotonic_time(:millisecond) - start

      assert {:ok, %TeamResult{status: :timeout, team: "test-team"}} = result

      # Should have returned well within 15 seconds (timeout is ~5s)
      assert elapsed < 15_000
    end
  end

  describe "spawn/1 log file writing" do
    test "writes raw output to log_path when set", %{tmp_dir: tmp_dir} do
      log_path = Path.join(tmp_dir, "team.log")

      script =
        write_mock_script(tmp_dir, "log_test.sh", """
        echo '{"type":"system","subtype":"init","session_id":"log-sess"}'
        echo '{"type":"result","subtype":"success","result":"Logged","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      opts =
        [
          team_name: "log-team",
          prompt: "Log this",
          command: script,
          timeout_minutes: 1,
          log_path: log_path
        ]

      assert {:ok, %TeamResult{}} = Spawner.spawn(opts)
      assert File.exists?(log_path)

      contents = File.read!(log_path)
      assert contents =~ "system"
      assert contents =~ "result"
      assert contents =~ "log-sess"
    end

    test "does not create log file when log_path is nil", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "no_log.sh", """
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      opts = [
        team_name: "no-log-team",
        prompt: "No log",
        command: script,
        timeout_minutes: 1
      ]

      assert {:ok, %TeamResult{}} = Spawner.spawn(opts)

      # No log file should exist in the tmp_dir (besides the script)
      log_files =
        tmp_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".log"))

      assert log_files == []
    end

    test "creates parent directories for log_path", %{tmp_dir: tmp_dir} do
      log_path = Path.join([tmp_dir, "nested", "dirs", "team.log"])

      script =
        write_mock_script(tmp_dir, "nested_log.sh", """
        echo '{"type":"result","subtype":"success","result":"Done","cost_usd":0.01,"num_turns":1,"duration_ms":1000}'
        """)

      opts = [
        team_name: "nested-team",
        prompt: "Nested log",
        command: script,
        timeout_minutes: 1,
        log_path: log_path
      ]

      assert {:ok, %TeamResult{}} = Spawner.spawn(opts)
      assert File.exists?(log_path)
    end
  end

  describe "spawn/1 with missing result line" do
    test "returns error when process exits without result line", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "no_result.sh", """
        echo '{"type":"system","subtype":"init","session_id":"no-result-sess"}'
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Working"}]}}'
        """)

      assert {:error, :no_result_line} =
               Spawner.spawn(base_opts(tmp_dir, script))
    end
  end

  describe "spawn/1 option defaults" do
    test "requires team_name" do
      assert_raise KeyError, ~r/:team_name/, fn ->
        Spawner.spawn(prompt: "test")
      end
    end

    test "requires prompt" do
      assert_raise KeyError, ~r/:prompt/, fn ->
        Spawner.spawn(team_name: "test")
      end
    end
  end

  describe "spawn/1 with interleaved non-JSON lines" do
    test "skips non-JSON lines gracefully", %{tmp_dir: tmp_dir} do
      script =
        write_mock_script(tmp_dir, "noisy.sh", """
        echo 'WARNING: something happened'
        echo '{"type":"system","subtype":"init","session_id":"noisy-sess"}'
        echo 'Another non-JSON line'
        echo '{"type":"result","subtype":"success","result":"Done despite noise","cost_usd":0.02,"num_turns":1,"duration_ms":2000}'
        """)

      assert {:ok, %TeamResult{status: :success, result: "Done despite noise"}} =
               Spawner.spawn(base_opts(tmp_dir, script))
    end
  end
end
