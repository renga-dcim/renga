import Config

config :tailwind,
  version: "4.1.7",
  consumer: [
    args: ~w(--input=assets/css/app.css --output=priv/static/app.css),
    cd: Path.expand("..", __DIR__)
  ]

config :esbuild,
  version: "0.25.4",
  consumer: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static --alias:renga_ui=../deps/renga_ui/ui/assets/js),
    cd: Path.expand("../assets", __DIR__)
  ]
