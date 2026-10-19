defmodule RengaUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :renga_ui,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.1"},
      {:gettext, "~> 1.0"}
    ]
  end
end
