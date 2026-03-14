import Config

# Configure the test database
config :cortex, Cortex.Repo,
  database: Path.expand("../cortex_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

# We don't run a server during test
config :cortex, CortexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_only_ok_ok",
  server: false

config :logger, level: :warning
