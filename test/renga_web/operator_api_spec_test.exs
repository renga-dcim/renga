defmodule RengaWeb.OperatorApiSpecTest do
  use ExUnit.Case, async: true

  test "priv/openapi/operator-v1.json is a valid, current copy of RengaWeb.OperatorApiSpec" do
    generated =
      Oaskit.to_json!(RengaWeb.OperatorApiSpec,
        pretty: true,
        validation_error_handler: fn error -> raise error end
      )
      |> IO.iodata_to_binary()

    if File.read!("priv/openapi/operator-v1.json") != generated do
      flunk("priv/openapi/operator-v1.json is out of date; regenerate it with `mix api.spec`")
    end
  end

  test "every operator route is documented" do
    %{"paths" => paths} =
      Oaskit.normalize_spec!(RengaWeb.OperatorApiSpec.spec(),
        spec_module: RengaWeb.OperatorApiSpec
      )

    undocumented =
      for %{path: path, verb: verb} <- Phoenix.Router.routes(RengaWeb.OperatorRouter),
          spec_path = String.replace(path, ~r/:(\w+)/, "{\\1}"),
          not is_map_key(Map.get(paths, spec_path, %{}), Atom.to_string(verb)),
          do: "#{verb |> Atom.to_string() |> String.upcase()} #{path}"

    assert undocumented == [],
           "declare an Oaskit operation for: #{Enum.join(undocumented, ", ")}"
  end
end
