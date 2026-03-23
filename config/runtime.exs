import Config

# config/runtime.exs is executed at runtime, before the application starts.
# It is executed in the release environment (no Mix, no source code).

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      Path.join(System.get_env("RELEASE_ROOT", "/app"), "data/cortex.db")

  config :cortex, Cortex.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :cortex, CortexWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    server: true

  # gRPC Gateway port
  grpc_port = String.to_integer(System.get_env("GRPC_PORT") || "4001")

  config :cortex, Cortex.Gateway.GrpcEndpoint,
    port: grpc_port,
    start_server: true

  # Gateway auth token for sidecar registration
  if token = System.get_env("CORTEX_GATEWAY_TOKEN") do
    config :cortex, Cortex.Gateway, auth_token: token
  end
end
