defmodule RengaUIConsumerTest do
  use ExUnit.Case, async: true

  test "renders components without the Renga application" do
    html =
      %{}
      |> RengaUIConsumer.sample()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ ~s(role="alert")
    assert html =~ "can&#39;t be blank"
    assert html =~ "hero-x-mark"
    assert html =~ ~s(phx-hook="Overlay")
    assert RengaUI.CoreComponents.translate_error({"can't be blank", []}) == "can't be blank"
  end

  test "ships the fonts the stylesheet loads" do
    fonts = Application.app_dir(:renga_ui, "priv/static/fonts")
    css = File.read!("deps/renga_ui/ui/assets/css/fonts.css")

    for [file] <- Regex.scan(~r{/fonts/([\w.-]+\.woff2)}, css, capture: :all_but_first) do
      assert File.exists?(Path.join(fonts, file)), "missing #{file}"
    end
  end
end
