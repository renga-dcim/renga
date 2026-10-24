defmodule Renga.MixProject do
  use Mix.Project

  def project do
    [
      app: :renga,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Renga.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:renga_ui, path: "ui"},
      {:argon2_elixir, "~> 4.0"},
      {:nimble_totp, "~> 1.0"},
      # WebAuthn verification (RFD 19). Pinned: upgrades are reviewed, not
      # picked up by `mix deps.update`.
      {:wax_, "== 0.7.0"},
      # RFD 15: a pinned, reviewed OpenID Connect client. Renga binds state,
      # nonce, and PKCE to each attempt itself.
      {:oidcc, "== 3.9.0"},
      {:eqrcode, "~> 0.2"},
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_test_playwright, "~> 0.18", only: :test, runtime: false},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:oaskit, "~> 0.17.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3"},
      {:bandit, "~> 1.5"},

      # dev or test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "ecto.migration": ["ecto.migrate", "ecto.dump"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # Regenerates the committed OpenAPI document; a test fails when it is stale.
      "api.spec": &api_spec/1,
      # Regenerates the query contract the agent's tests read (RFD 12).
      "queries.contract": &queries_contract/1,
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd npm ci --prefix assets --no-audit --no-fund"
      ],
      "assets.build": ["compile", "tailwind renga", "esbuild renga"],
      "assets.deploy": [
        "tailwind renga --minify",
        "esbuild renga --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp queries_contract(_args) do
    Mix.Task.run("compile")
    File.mkdir_p!("priv/queries")
    File.write!(Renga.Jobs.Query.contract_path(), Renga.Jobs.Query.contract_json())
  end

  # The machine API and the operator API (RFD 22) each have a document.
  # openapi.dump runs once per Mix invocation unless re-enabled.
  defp api_spec(_args) do
    Mix.Task.run("openapi.dump", ~w(RengaWeb.ApiSpec --pretty -o priv/openapi/v1.json))

    Mix.Task.rerun(
      "openapi.dump",
      ~w(RengaWeb.OperatorApiSpec --pretty -o priv/openapi/operator-v1.json)
    )
  end
end
