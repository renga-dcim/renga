import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :argon2_elixir,
  t_cost: 1,
  m_cost: 8

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :renga, Renga.Repo,
  username: System.get_env("DATABASE_USER") || "postgres",
  password: System.get_env("DATABASE_PASSWORD") || "postgres",
  hostname: System.get_env("DATABASE_HOST") || "localhost",
  port: String.to_integer(System.get_env("DATABASE_PORT") || "5434"),
  database: "renga_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Browser tests (tagged :playwright) need a running server to visit.
config :renga, RengaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Z808bOYBdFc8c0fqxXrsogXZu1vZxHLv4ekokPnp+TOEbyT4FfnAduj3TULGPMQI",
  server: true

# Lets browser tests share their database transaction with the server.
config :renga, :sql_sandbox, Ecto.Adapters.SQL.Sandbox

# Mounts test-only fixture pages, such as the shared component review page.
config :renga, :test_routes, true

# Browser tests run through Playwright with browsers that match
# assets/package.json (see flake.nix). Set PW_TRACE or PW_SCREENSHOT to keep a
# trace or screenshot of each failing browser test under tmp/.
config :phoenix_test,
  otp_app: :renga,
  endpoint: RengaWeb.Endpoint,
  playwright: [
    browser: :chromium,
    trace: System.get_env("PW_TRACE", "false") in ~w(1 true),
    trace_dir: "tmp/traces",
    screenshot: System.get_env("PW_SCREENSHOT", "false") in ~w(1 true),
    screenshot_dir: "tmp/screenshots"
  ]

# In test we don't send emails
config :renga, Renga.Mailer, adapter: Swoosh.Adapters.Test

# Tests invoke deterministic expiry sweeps directly under the SQL sandbox.
config :renga, :neighbor_expiry_worker_enabled, false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
