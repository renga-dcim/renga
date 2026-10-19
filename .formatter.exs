[
  import_deps: [:ecto, :ecto_sql, :phoenix, :oaskit],
  subdirectories: ["priv/*/migrations", "ui"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
