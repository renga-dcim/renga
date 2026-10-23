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
#
# Local tests use the same socket as development. CI explicitly selects TCP for
# its service container; this avoids stale local host/port exports overriding
# the socket configuration after an upgrade.
database_tcp? = System.get_env("DATABASE_TRANSPORT") == "tcp"

config :renga, Renga.Repo,
  username: System.get_env("DATABASE_USER") || "postgres",
  password: System.get_env("DATABASE_PASSWORD"),
  hostname: if(database_tcp?, do: System.get_env("DATABASE_HOST"), else: nil),
  port:
    if(database_tcp?,
      do: String.to_integer(System.get_env("DATABASE_PORT") || "5432"),
      else: 5432
    ),
  socket_dir: if(database_tcp?, do: nil, else: Path.expand("../tmp/postgres-socket", __DIR__)),
  database: "renga_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Production sets a baseline from DATABASE_STATEMENT_TIMEOUT (RFD 21); tests
  # run with one too, generous enough for slow CI machines.
  parameters: [statement_timeout: "60s"],
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
config :renga, :same_machine_sweeper_enabled, false
config :renga, :collector_findings_worker_enabled, false
config :renga, :job_sweeper_enabled, false
config :renga, :assignment_expiry_worker_enabled, false
config :renga, :invitation_delivery_worker_enabled, false
config :renga, :power_finding_sweeper_enabled, false
config :renga, :telemetry_pruner_enabled, false

# Tests add an imperative capability to exercise retry classes.
config :renga, Renga.Jobs.Registry, extra_capabilities: [Renga.Jobs.TestCapabilities.Restart]

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :renga, Renga.Vault, keys: "test:JEhIiyOdTqyJVJP6LBS3Tt65N+Ho5AQzC7ov/t6FjVM="

config :renga, :webauthn, origin: "http://localhost:4002"

# Provider requests (RFD 15) go to Renga.FakeOIDCProvider's stub.
config :renga, :oidc_req_options, plug: {Req.Test, Renga.Accounts.OIDC}
config :renga, :oidc_resolver, &Renga.FakeResolver.resolve/1
config :renga, :dns_txt_resolver, &Renga.FakeTxtResolver.lookup/1
config :renga, :organization_domain_worker_enabled, false
