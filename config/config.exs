# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :renga, :scopes,
  user: [
    default: true,
    module: Renga.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Renga.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :renga,
  ecto_repos: [Renga.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :renga, Renga.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_foreign_key: [type: :binary_id]

# Public issuance is serialized per profile and capped in its database transaction.
config :renga, :open_challenge_limit, 100

# Trust no reverse proxy by default. Adding a CIDR delegates the security-sensitive
# enrollment rate-limit source identity to peers in that network.
config :renga, :enrollment_trusted_proxy_cidrs, []

# This bounded guard is node-local; the database cap above is authoritative.
config :renga, Renga.Enrollment.ChallengeRateLimiter,
  tuple_limit: 20,
  source_limit: 100,
  window: :timer.minutes(1),
  prune_interval: :timer.minutes(1),
  max_keys: 10_000

config :renga, Renga.Enrollment.Cleanup,
  interval: :timer.minutes(5),
  batch_size: 500,
  max_batches_per_tick: 4

# Configures the endpoint
config :renga, RengaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RengaWeb.ErrorHTML, json: RengaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Renga.PubSub,
  live_view: [signing_salt: "hbEUUN7o"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :renga, Renga.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  renga: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  renga: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
