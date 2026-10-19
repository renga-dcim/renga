defmodule RengaUIConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :renga_ui_consumer,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:renga_ui,
       git: System.fetch_env!("RENGA_UI_GIT"),
       ref: System.fetch_env!("RENGA_UI_REF"),
       sparse: "ui"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:tailwind, "~> 0.3", runtime: false},
      {:esbuild, "~> 0.10", runtime: false}
    ]
  end
end
