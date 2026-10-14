defmodule RengaWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  # Tools outside this app, such as the agent's contract tests, read the
  # committed copy, so it must match what the code declares.
  test "priv/openapi/v1.json is a valid, current copy of RengaWeb.ApiSpec" do
    generated =
      Oaskit.to_json!(RengaWeb.ApiSpec,
        pretty: true,
        validation_error_handler: fn error -> raise error end
      )
      |> IO.iodata_to_binary()

    if File.read!("priv/openapi/v1.json") != generated do
      flunk("priv/openapi/v1.json is out of date; regenerate it with `mix api.spec`")
    end
  end
end
