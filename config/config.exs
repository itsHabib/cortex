import Config

config :cortex,
  ecto_repos: [Cortex.Repo]

config :cortex, Cortex.Repo,
  database: Path.expand("../cortex_#{config_env()}.db", __DIR__),
  pool_size: 5,
  show_sensitive_data_on_connection_error: true

config :cortex, CortexWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: CortexWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Cortex.PubSub,
  live_view: [signing_salt: "cortex_lv_salt"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# gRPC server disabled — Provider.External is gated until agent worker ships.
# Re-enable with: start_server: true
config :cortex, Cortex.Gateway.GrpcEndpoint,
  port: 4001,
  start_server: false

config :phoenix, :json_library, Jason

config :tailwind, :version, "4.1.12"

import_config "#{config_env()}.exs"
