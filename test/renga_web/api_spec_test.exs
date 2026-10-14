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

  # Oaskit silently leaves out routes whose action declares no operation, so
  # a new endpoint would otherwise ship undocumented without failing a test.
  test "every /api route is documented" do
    %{"paths" => paths} =
      Oaskit.normalize_spec!(RengaWeb.ApiSpec.spec(), spec_module: RengaWeb.ApiSpec)

    undocumented =
      for %{path: "/api/" <> _ = path, verb: verb} <- Phoenix.Router.routes(RengaWeb.Router),
          spec_path = String.replace(path, ~r/:(\w+)/, "{\\1}"),
          not is_map_key(Map.get(paths, spec_path, %{}), Atom.to_string(verb)),
          do: "#{verb |> Atom.to_string() |> String.upcase()} #{path}"

    assert undocumented == [],
           "declare an Oaskit operation for: #{Enum.join(undocumented, ", ")}"
  end

  # json_response/2 skips the spec check, so a new API test that used it
  # would let the endpoint's responses drift from the published document.
  test "API controller tests check responses with valid_api_response" do
    offenders =
      for file <- Path.wildcard("test/renga_web/controllers/api/**/*_test.exs"),
          File.read!(file) =~ "json_response(",
          do: file

    assert offenders == [],
           "use valid_api_response/2 instead of json_response/2 in: #{Enum.join(offenders, ", ")}"
  end
end
