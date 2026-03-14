import Config

config :cortex, CortexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_that_is_at_least_64_bytes_long_for_development_only_ok",
  watchers: []

config :cortex, CortexWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/cortex_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :cortex, dev_routes: true

config :logger, level: :debug
