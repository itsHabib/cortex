defmodule Cortex.SpawnBackend.K8s.PodSpecTest do
  use ExUnit.Case, async: true

  alias Cortex.SpawnBackend.K8s.PodSpec

  @default_opts [team_name: "researcher", run_id: "abc-12345678"]

  describe "build/1" do
    test "returns a valid Pod manifest with required fields" do
      spec = PodSpec.build(@default_opts)

      assert spec["apiVersion"] == "v1"
      assert spec["kind"] == "Pod"
      assert spec["metadata"]["name"]
      assert spec["metadata"]["namespace"]
      assert spec["metadata"]["labels"]

      containers = spec["spec"]["containers"]
      assert length(containers) == 2

      container_names = Enum.map(containers, & &1["name"])
      assert "sidecar" in container_names
      assert "worker" in container_names
    end

    test "sets restartPolicy to Never" do
      spec = PodSpec.build(@default_opts)
      assert spec["spec"]["restartPolicy"] == "Never"
    end

    test "sets activeDeadlineSeconds from timeout_ms" do
      spec = PodSpec.build(@default_opts ++ [timeout_ms: 7_200_000])
      assert spec["spec"]["activeDeadlineSeconds"] == 7200
    end

    test "defaults activeDeadlineSeconds to 3600" do
      spec = PodSpec.build(@default_opts)
      assert spec["spec"]["activeDeadlineSeconds"] == 3600
    end

    test "sets mandatory labels" do
      spec = PodSpec.build(@default_opts)
      labels = spec["metadata"]["labels"]

      assert labels["app.kubernetes.io/managed-by"] == "cortex"
      assert labels["cortex.dev/run-id"] == "abc-12345678"
      assert labels["cortex.dev/team"] == "researcher"
      assert labels["cortex.dev/component"] == "agent-pod"
    end

    test "sets namespace from option" do
      spec = PodSpec.build(@default_opts ++ [namespace: "production"])
      assert spec["metadata"]["namespace"] == "production"
    end

    test "sets serviceAccountName when provided" do
      spec = PodSpec.build(@default_opts ++ [service_account: "cortex-agent"])
      assert spec["spec"]["serviceAccountName"] == "cortex-agent"
    end

    test "does not include serviceAccountName when not provided" do
      spec = PodSpec.build(@default_opts)
      refute Map.has_key?(spec["spec"], "serviceAccountName")
    end

    test "sets imagePullSecrets when provided" do
      spec = PodSpec.build(@default_opts ++ [image_pull_secrets: ["my-registry"]])
      assert spec["spec"]["imagePullSecrets"] == [%{"name" => "my-registry"}]
    end

    test "does not include imagePullSecrets when empty" do
      spec = PodSpec.build(@default_opts)
      refute Map.has_key?(spec["spec"], "imagePullSecrets")
    end

    test "includes created-at annotation" do
      spec = PodSpec.build(@default_opts)
      assert spec["metadata"]["annotations"]["cortex.dev/created-at"]
    end
  end

  describe "sidecar container" do
    test "has correct env vars" do
      spec = PodSpec.build(@default_opts ++ [gateway_url: "gateway:4001"])
      sidecar = find_container(spec, "sidecar")

      env_map = env_to_map(sidecar["env"])
      assert env_map["CORTEX_GATEWAY_URL"] == "gateway:4001"
      assert env_map["CORTEX_AGENT_NAME"] == "researcher"
      assert env_map["CORTEX_SIDECAR_PORT"] == "9091"
    end

    test "uses auth_token directly when provided" do
      spec = PodSpec.build(@default_opts ++ [auth_token: "test-token"])
      sidecar = find_container(spec, "sidecar")

      env_map = env_to_map(sidecar["env"])
      assert env_map["CORTEX_AUTH_TOKEN"] == "test-token"
    end

    test "uses secretKeyRef for auth_token when not provided" do
      spec = PodSpec.build(@default_opts)
      sidecar = find_container(spec, "sidecar")

      auth_env = Enum.find(sidecar["env"], &(&1["name"] == "CORTEX_AUTH_TOKEN"))
      assert auth_env["valueFrom"]["secretKeyRef"]["name"] == "cortex-gateway-token"
      assert auth_env["valueFrom"]["secretKeyRef"]["key"] == "token"
    end

    test "custom sidecar image overrides default" do
      spec = PodSpec.build(@default_opts ++ [sidecar_image: "my-sidecar:v2"])
      sidecar = find_container(spec, "sidecar")
      assert sidecar["image"] == "my-sidecar:v2"
    end

    test "has readiness and liveness probes" do
      spec = PodSpec.build(@default_opts)
      sidecar = find_container(spec, "sidecar")

      assert sidecar["readinessProbe"]["httpGet"]["path"] == "/healthz"
      assert sidecar["readinessProbe"]["httpGet"]["port"] == 9091
      assert sidecar["livenessProbe"]["httpGet"]["path"] == "/healthz"
      assert sidecar["livenessProbe"]["httpGet"]["port"] == 9091
    end

    test "has container port 9091" do
      spec = PodSpec.build(@default_opts)
      sidecar = find_container(spec, "sidecar")
      assert [%{"containerPort" => 9091}] = sidecar["ports"]
    end

    test "has default resource limits" do
      spec = PodSpec.build(@default_opts)
      sidecar = find_container(spec, "sidecar")

      assert sidecar["resources"]["requests"]["cpu"] == "100m"
      assert sidecar["resources"]["requests"]["memory"] == "64Mi"
      assert sidecar["resources"]["limits"]["cpu"] == "500m"
      assert sidecar["resources"]["limits"]["memory"] == "256Mi"
    end
  end

  describe "worker container" do
    test "has SIDECAR_URL pointing to localhost:9091" do
      spec = PodSpec.build(@default_opts)
      worker = find_container(spec, "worker")

      env_map = env_to_map(worker["env"])
      assert env_map["SIDECAR_URL"] == "http://localhost:9091"
    end

    test "has ANTHROPIC_API_KEY from secret" do
      spec = PodSpec.build(@default_opts)
      worker = find_container(spec, "worker")

      api_key_env = Enum.find(worker["env"], &(&1["name"] == "ANTHROPIC_API_KEY"))
      assert api_key_env["valueFrom"]["secretKeyRef"]["name"] == "anthropic-api-key"
      assert api_key_env["valueFrom"]["secretKeyRef"]["key"] == "key"
    end

    test "custom worker image overrides default" do
      spec = PodSpec.build(@default_opts ++ [worker_image: "my-worker:v3"])
      worker = find_container(spec, "worker")
      assert worker["image"] == "my-worker:v3"
    end

    test "has default resource limits" do
      spec = PodSpec.build(@default_opts)
      worker = find_container(spec, "worker")

      assert worker["resources"]["requests"]["cpu"] == "200m"
      assert worker["resources"]["requests"]["memory"] == "128Mi"
      assert worker["resources"]["limits"]["cpu"] == "1000m"
      assert worker["resources"]["limits"]["memory"] == "512Mi"
    end
  end

  describe "custom resources" do
    test "applies custom sidecar resources" do
      custom = %{
        sidecar: %{
          "requests" => %{"cpu" => "250m", "memory" => "128Mi"},
          "limits" => %{"cpu" => "1000m", "memory" => "512Mi"}
        }
      }

      spec = PodSpec.build(@default_opts ++ [resources: custom])
      sidecar = find_container(spec, "sidecar")

      assert sidecar["resources"]["requests"]["cpu"] == "250m"
      assert sidecar["resources"]["limits"]["cpu"] == "1000m"
    end

    test "applies custom worker resources" do
      custom = %{
        worker: %{
          "requests" => %{"cpu" => "500m", "memory" => "256Mi"},
          "limits" => %{"cpu" => "2000m", "memory" => "1Gi"}
        }
      }

      spec = PodSpec.build(@default_opts ++ [resources: custom])
      worker = find_container(spec, "worker")

      assert worker["resources"]["requests"]["cpu"] == "500m"
      assert worker["resources"]["limits"]["memory"] == "1Gi"
    end
  end

  describe "pod_name/2" do
    test "generates deterministic name" do
      name = PodSpec.pod_name("abc-12345678", "researcher")
      assert name == "cortex-abc-1234-researcher"
    end

    test "truncates long run_id" do
      name = PodSpec.pod_name("abcdefghijklmnop", "team")
      assert String.starts_with?(name, "cortex-abcdefgh-team")
    end

    test "handles special characters" do
      name = PodSpec.pod_name("run_123", "My Team!")
      assert name =~ ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/
    end
  end

  describe "sanitize_name/1" do
    test "downcases" do
      assert PodSpec.sanitize_name("MyPod") == "mypod"
    end

    test "replaces non-alphanumeric with hyphens" do
      assert PodSpec.sanitize_name("my_pod.name") == "my-pod-name"
    end

    test "collapses consecutive hyphens" do
      assert PodSpec.sanitize_name("my--pod---name") == "my-pod-name"
    end

    test "strips leading and trailing hyphens" do
      assert PodSpec.sanitize_name("-my-pod-") == "my-pod"
    end

    test "truncates to 63 characters" do
      long_name = String.duplicate("a", 100)
      result = PodSpec.sanitize_name(long_name)
      assert String.length(result) <= 63
    end

    test "handles empty string edge case" do
      assert PodSpec.sanitize_name("") == ""
    end

    test "ensures result ends with alphanumeric after truncation" do
      # 63 chars followed by a hyphen — truncation should strip the trailing hyphen
      name = String.duplicate("a", 62) <> "-extra"
      result = PodSpec.sanitize_name(name)
      assert String.length(result) <= 63
      refute String.ends_with?(result, "-")
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp find_container(spec, name) do
    Enum.find(spec["spec"]["containers"], &(&1["name"] == name))
  end

  defp env_to_map(env_list) do
    env_list
    |> Enum.filter(&Map.has_key?(&1, "value"))
    |> Map.new(&{&1["name"], &1["value"]})
  end
end
