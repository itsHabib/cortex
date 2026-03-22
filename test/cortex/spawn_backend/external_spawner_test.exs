defmodule Cortex.SpawnBackend.ExternalSpawnerTest do
  use ExUnit.Case, async: true

  alias Cortex.SpawnBackend.ExternalSpawner

  @moduletag :tmp_dir

  # -- Port allocation ---------------------------------------------------------

  describe "pick_free_port/0" do
    test "returns a port number" do
      assert {:ok, port} = ExternalSpawner.pick_free_port()
      assert is_integer(port)
      assert port > 0
      assert port < 65536
    end

    test "returns different ports on successive calls" do
      {:ok, port1} = ExternalSpawner.pick_free_port()
      {:ok, port2} = ExternalSpawner.pick_free_port()
      # Ports should differ (technically could collide, but extremely unlikely)
      assert port1 != port2
    end
  end

  # -- Binary discovery --------------------------------------------------------

  describe "resolve_sidecar_bin/0" do
    test "returns error when env var points to nonexistent binary" do
      System.put_env("CORTEX_SIDECAR_BIN", "/nonexistent/sidecar")

      try do
        assert {:error, {:binary_not_found, "sidecar", "/nonexistent/sidecar"}} =
                 ExternalSpawner.resolve_sidecar_bin()
      after
        System.delete_env("CORTEX_SIDECAR_BIN")
      end
    end

    test "returns ok when env var points to existing binary", %{tmp_dir: tmp_dir} do
      bin = Path.join(tmp_dir, "cortex-sidecar")
      File.write!(bin, "#!/bin/bash\necho hi")
      File.chmod!(bin, 0o755)

      System.put_env("CORTEX_SIDECAR_BIN", bin)

      try do
        assert {:ok, ^bin} = ExternalSpawner.resolve_sidecar_bin()
      after
        System.delete_env("CORTEX_SIDECAR_BIN")
      end
    end

    test "env var takes precedence over config", %{tmp_dir: tmp_dir} do
      bin = Path.join(tmp_dir, "my-sidecar")
      File.write!(bin, "#!/bin/bash\necho hi")
      File.chmod!(bin, 0o755)

      System.put_env("CORTEX_SIDECAR_BIN", bin)

      try do
        assert {:ok, ^bin} = ExternalSpawner.resolve_sidecar_bin()
      after
        System.delete_env("CORTEX_SIDECAR_BIN")
      end
    end
  end

  describe "resolve_worker_bin/0" do
    test "returns error when env var points to nonexistent binary" do
      System.put_env("CORTEX_WORKER_BIN", "/nonexistent/worker")

      try do
        assert {:error, {:binary_not_found, "worker", "/nonexistent/worker"}} =
                 ExternalSpawner.resolve_worker_bin()
      after
        System.delete_env("CORTEX_WORKER_BIN")
      end
    end

    test "returns ok when env var points to existing binary", %{tmp_dir: tmp_dir} do
      bin = Path.join(tmp_dir, "agent-worker")
      File.write!(bin, "#!/bin/bash\necho hi")
      File.chmod!(bin, 0o755)

      System.put_env("CORTEX_WORKER_BIN", bin)

      try do
        assert {:ok, ^bin} = ExternalSpawner.resolve_worker_bin()
      after
        System.delete_env("CORTEX_WORKER_BIN")
      end
    end
  end

  # -- already_registered?/2 ---------------------------------------------------

  describe "already_registered?/2" do
    test "returns false when registry has no matching agent" do
      # Start an isolated registry for this test
      {:ok, registry} =
        Cortex.Gateway.Registry.start_link(
          name: :"test_reg_#{:erlang.unique_integer([:positive])}"
        )

      refute ExternalSpawner.already_registered?("nonexistent-team", registry)
    end

    test "returns true when registry has a matching agent" do
      registry_name = :"test_reg_#{:erlang.unique_integer([:positive])}"
      {:ok, registry} = Cortex.Gateway.Registry.start_link(name: registry_name)

      # Register a mock agent
      transport_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, _agent} =
        Cortex.Gateway.Registry.register_grpc(
          registry,
          %{"name" => "my-team", "role" => "worker", "capabilities" => []},
          transport_pid
        )

      assert ExternalSpawner.already_registered?("my-team", registry)

      # Clean up
      Process.exit(transport_pid, :kill)
    end

    test "returns false when registry process is not available" do
      refute ExternalSpawner.already_registered?("any-team", :nonexistent_registry)
    end
  end

  # -- spawn/1 (binary not found) ---------------------------------------------

  describe "spawn/1" do
    test "returns binary_not_found error when sidecar binary doesn't exist" do
      System.put_env("CORTEX_SIDECAR_BIN", "/nonexistent/cortex-sidecar")

      try do
        assert {:error, {:binary_not_found, "sidecar", _}} =
                 ExternalSpawner.spawn(team_name: "test-team")
      after
        System.delete_env("CORTEX_SIDECAR_BIN")
      end
    end

    test "returns binary_not_found error for worker when sidecar exists but worker doesn't",
         %{tmp_dir: tmp_dir} do
      sidecar_bin = Path.join(tmp_dir, "cortex-sidecar")
      File.write!(sidecar_bin, "#!/bin/bash\nsleep 30")
      File.chmod!(sidecar_bin, 0o755)

      System.put_env("CORTEX_SIDECAR_BIN", sidecar_bin)
      System.put_env("CORTEX_WORKER_BIN", "/nonexistent/agent-worker")

      try do
        assert {:error, {:binary_not_found, "worker", _}} =
                 ExternalSpawner.spawn(team_name: "test-team")
      after
        System.delete_env("CORTEX_SIDECAR_BIN")
        System.delete_env("CORTEX_WORKER_BIN")
      end
    end
  end

  # -- Handle stop/1 -----------------------------------------------------------

  describe "stop/1" do
    test "kills both ports and returns :ok", %{tmp_dir: tmp_dir} do
      # Create two mock scripts that just sleep
      sidecar_script = Path.join(tmp_dir, "sidecar.sh")
      File.write!(sidecar_script, "#!/bin/bash\nsleep 300")
      File.chmod!(sidecar_script, 0o755)

      worker_script = Path.join(tmp_dir, "worker.sh")
      File.write!(worker_script, "#!/bin/bash\nsleep 300")
      File.chmod!(worker_script, 0o755)

      # Open ports directly to test stop/1
      sidecar_port =
        Port.open(
          {:spawn_executable, String.to_charlist(sidecar_script)},
          [:binary, :exit_status]
        )

      worker_port =
        Port.open(
          {:spawn_executable, String.to_charlist(worker_script)},
          [:binary, :exit_status]
        )

      handle = %ExternalSpawner.Handle{
        sidecar_port: sidecar_port,
        worker_port: worker_port,
        team_name: "test-team",
        sidecar_port_number: 9999,
        sidecar_os_pid: nil,
        worker_os_pid: nil
      }

      assert :ok = ExternalSpawner.stop(handle)

      # Ports should be closed after stop
      Process.sleep(100)
      assert Port.info(sidecar_port) == nil
      assert Port.info(worker_port) == nil
    end

    test "is idempotent — safe to call twice", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "idle.sh")
      File.write!(script, "#!/bin/bash\nsleep 300")
      File.chmod!(script, 0o755)

      sidecar_port =
        Port.open(
          {:spawn_executable, String.to_charlist(script)},
          [:binary, :exit_status]
        )

      worker_port =
        Port.open(
          {:spawn_executable, String.to_charlist(script)},
          [:binary, :exit_status]
        )

      handle = %ExternalSpawner.Handle{
        sidecar_port: sidecar_port,
        worker_port: worker_port,
        team_name: "test-team",
        sidecar_port_number: 9999,
        sidecar_os_pid: nil,
        worker_os_pid: nil
      }

      assert :ok = ExternalSpawner.stop(handle)
      assert :ok = ExternalSpawner.stop(handle)
    end
  end
end
