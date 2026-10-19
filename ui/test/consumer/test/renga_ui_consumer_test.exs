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
end
