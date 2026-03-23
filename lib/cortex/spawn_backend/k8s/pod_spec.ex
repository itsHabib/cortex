defmodule Cortex.SpawnBackend.K8s.PodSpec do
  @moduledoc """
  Pure-function Pod manifest builder for the K8s spawn backend.

  Constructs Kubernetes Pod specs with sidecar + worker containers from
  configuration options. All functions are side-effect-free — input config
  in, Pod manifest map out.

  ## Pod Structure

  Each Pod contains two containers sharing localhost networking:

    - **sidecar** — connects to Cortex Gateway via gRPC, registers the
      agent, and exposes an HTTP API on port 9091 for the worker
    - **worker** — polls the sidecar for tasks, executes them (via
      `claude -p` or the Claude API), and posts results back

  ## Naming

  Pod names follow the pattern `cortex-<run_id_short>-<team_name>`,
  sanitized to K8s DNS-1123 label rules:

    - Lowercase alphanumeric and hyphens only
    - Must start and end with alphanumeric
    - Max 63 characters
  """

  @default_namespace "cortex"
  @default_sidecar_image "cortex-sidecar:latest"
  @default_worker_image "cortex-agent-worker:latest"
  @default_sidecar_port 9091
  @default_active_deadline_seconds 3600
  @max_pod_name_length 63

  @doc """
  Builds a complete Pod manifest map from configuration options.

  ## Required Options

    - `:team_name` — agent name
    - `:run_id` — unique run identifier

  ## Optional Options

    - `:namespace` — K8s namespace (default: `"cortex"`)
    - `:gateway_url` — gRPC gateway address (default from app config)
    - `:sidecar_image` — sidecar container image (default: `"cortex-sidecar:latest"`)
    - `:worker_image` — worker container image (default: `"cortex-agent-worker:latest"`)
    - `:timeout_ms` — max pod lifetime in milliseconds (default: 3,600,000)
    - `:resources` — resource requests/limits override map
    - `:service_account` — K8s service account name
    - `:auth_token` — gateway auth token (if not using K8s Secret)
    - `:image_pull_secrets` — list of image pull secret names
  """
  @spec build(keyword()) :: map()
  def build(opts) when is_list(opts) do
    team_name = Keyword.fetch!(opts, :team_name)
    run_id = Keyword.fetch!(opts, :run_id)
    namespace = Keyword.get(opts, :namespace, default_namespace())
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_active_deadline_seconds * 1_000)
    service_account = Keyword.get(opts, :service_account)
    image_pull_secrets = Keyword.get(opts, :image_pull_secrets, [])

    active_deadline = div(timeout_ms, 1_000)
    name = pod_name(run_id, team_name)

    spec = %{
      "restartPolicy" => "Never",
      "activeDeadlineSeconds" => active_deadline,
      "containers" => [
        sidecar_container(opts),
        worker_container(opts)
      ]
    }

    spec =
      if service_account do
        Map.put(spec, "serviceAccountName", service_account)
      else
        spec
      end

    spec =
      if image_pull_secrets != [] do
        secrets = Enum.map(image_pull_secrets, &%{"name" => &1})
        Map.put(spec, "imagePullSecrets", secrets)
      else
        spec
      end

    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => labels(run_id, team_name),
        "annotations" => %{
          "cortex.dev/created-at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      },
      "spec" => spec
    }
  end

  @doc """
  Generates a deterministic pod name from run_id and team_name.

  The name is sanitized to K8s DNS-1123 label rules: lowercase,
  alphanumeric + hyphens, max 63 characters, must start and end
  with alphanumeric.
  """
  @spec pod_name(String.t(), String.t()) :: String.t()
  def pod_name(run_id, team_name) do
    # Take first 8 chars of run_id for brevity
    run_short = String.slice(run_id, 0, 8)
    raw = "cortex-#{run_short}-#{team_name}"
    sanitize_name(raw)
  end

  @doc """
  Sanitizes a string to conform to K8s DNS-1123 label rules.

  - Downcases
  - Replaces non-alphanumeric chars (except hyphens) with hyphens
  - Collapses consecutive hyphens
  - Strips leading/trailing hyphens
  - Truncates to 63 characters
  - Ensures starts and ends with alphanumeric
  """
  @spec sanitize_name(String.t()) :: String.t()
  def sanitize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim_leading("-")
    |> String.trim_trailing("-")
    |> String.slice(0, @max_pod_name_length)
    |> String.trim_trailing("-")
  end

  # -- Private -----------------------------------------------------------------

  @spec labels(String.t(), String.t()) :: map()
  defp labels(run_id, team_name) do
    %{
      "app.kubernetes.io/managed-by" => "cortex",
      "cortex.dev/run-id" => run_id,
      "cortex.dev/team" => sanitize_label_value(team_name),
      "cortex.dev/component" => "agent-pod"
    }
  end

  @spec sanitize_label_value(String.t()) :: String.t()
  defp sanitize_label_value(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
    |> String.slice(0, 63)
    |> String.trim_leading("-")
    |> String.trim_trailing("-")
  end

  @spec sidecar_container(keyword()) :: map()
  defp sidecar_container(opts) do
    team_name = Keyword.fetch!(opts, :team_name)
    sidecar_image = Keyword.get(opts, :sidecar_image, default_sidecar_image())
    gateway_url = Keyword.get(opts, :gateway_url, default_gateway_url())
    auth_token = Keyword.get(opts, :auth_token)
    resources = Keyword.get(opts, :resources, %{})
    sidecar_resources = Map.get(resources, :sidecar, default_sidecar_resources())

    env = [
      %{"name" => "CORTEX_GATEWAY_URL", "value" => gateway_url},
      %{"name" => "CORTEX_AGENT_NAME", "value" => team_name},
      %{"name" => "CORTEX_SIDECAR_PORT", "value" => "#{@default_sidecar_port}"}
    ]

    env =
      if auth_token do
        env ++ [%{"name" => "CORTEX_AUTH_TOKEN", "value" => auth_token}]
      else
        env ++
          [
            %{
              "name" => "CORTEX_AUTH_TOKEN",
              "valueFrom" => %{
                "secretKeyRef" => %{
                  "name" => "cortex-gateway-token",
                  "key" => "token"
                }
              }
            }
          ]
      end

    %{
      "name" => "sidecar",
      "image" => sidecar_image,
      "env" => env,
      "ports" => [%{"containerPort" => @default_sidecar_port}],
      "resources" => sidecar_resources,
      "readinessProbe" => %{
        "httpGet" => %{"path" => "/healthz", "port" => @default_sidecar_port},
        "initialDelaySeconds" => 2,
        "periodSeconds" => 3
      },
      "livenessProbe" => %{
        "httpGet" => %{"path" => "/healthz", "port" => @default_sidecar_port},
        "initialDelaySeconds" => 10,
        "periodSeconds" => 10
      }
    }
  end

  @spec worker_container(keyword()) :: map()
  defp worker_container(opts) do
    worker_image = Keyword.get(opts, :worker_image, default_worker_image())
    resources = Keyword.get(opts, :resources, %{})
    worker_resources = Map.get(resources, :worker, default_worker_resources())

    %{
      "name" => "worker",
      "image" => worker_image,
      "env" => [
        %{"name" => "SIDECAR_URL", "value" => "http://localhost:#{@default_sidecar_port}"},
        %{
          "name" => "ANTHROPIC_API_KEY",
          "valueFrom" => %{
            "secretKeyRef" => %{
              "name" => "anthropic-api-key",
              "key" => "key"
            }
          }
        }
      ],
      "resources" => worker_resources
    }
  end

  @spec default_sidecar_resources() :: map()
  defp default_sidecar_resources do
    %{
      "requests" => %{"cpu" => "100m", "memory" => "64Mi"},
      "limits" => %{"cpu" => "500m", "memory" => "256Mi"}
    }
  end

  @spec default_worker_resources() :: map()
  defp default_worker_resources do
    %{
      "requests" => %{"cpu" => "200m", "memory" => "128Mi"},
      "limits" => %{"cpu" => "1000m", "memory" => "512Mi"}
    }
  end

  @spec default_namespace() :: String.t()
  defp default_namespace do
    app_config = Application.get_env(:cortex, Cortex.SpawnBackend.K8s, [])
    Keyword.get(app_config, :namespace, @default_namespace)
  end

  @spec default_sidecar_image() :: String.t()
  defp default_sidecar_image do
    app_config = Application.get_env(:cortex, Cortex.SpawnBackend.K8s, [])
    Keyword.get(app_config, :sidecar_image, @default_sidecar_image)
  end

  @spec default_worker_image() :: String.t()
  defp default_worker_image do
    app_config = Application.get_env(:cortex, Cortex.SpawnBackend.K8s, [])
    Keyword.get(app_config, :worker_image, @default_worker_image)
  end

  @spec default_gateway_url() :: String.t()
  defp default_gateway_url do
    app_config = Application.get_env(:cortex, Cortex.SpawnBackend.K8s, [])
    Keyword.get(app_config, :gateway_url, "cortex-gateway:4001")
  end
end
