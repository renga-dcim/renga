defmodule RengaWeb.DevConfigTest do
  use ExUnit.Case, async: true

  test "the extracted UI package reloads during development" do
    endpoint_config =
      "config/dev.exs"
      |> Config.Reader.read!()
      |> Keyword.fetch!(:renga)
      |> Keyword.fetch!(RengaWeb.Endpoint)

    assert endpoint_config[:reloadable_apps] == [:renga, :renga_ui]

    assert Enum.any?(endpoint_config[:live_reload][:patterns], fn pattern ->
             Regex.match?(pattern, "ui/lib/renga_ui/components.ex")
           end)
  end
end
