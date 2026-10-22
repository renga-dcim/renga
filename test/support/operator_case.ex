defmodule RengaWeb.OperatorCase do
  @moduledoc """
  Tests against the operator API's endpoint (RFD 22), which has its own
  router and OpenAPI document.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint RengaWeb.OperatorEndpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import RengaWeb.OperatorCase
    end
  end

  setup tags do
    Renga.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates an operator token and returns `{token, plaintext}`.
  """
  def operator_token_fixture(attrs \\ %{}) do
    {:ok, result} =
      attrs
      |> Enum.into(%{
        name: "control-plane-#{System.unique_integer([:positive])}",
        scopes: Renga.Operators.scopes()
      })
      |> Renga.Operators.create_token(Renga.DeploymentAudit.operator("operator-case"))

    result
  end

  def authorize(conn, plaintext),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> plaintext)

  @doc """
  Asserts the status, checks the body against the operation's documented
  response in `RengaWeb.OperatorApiSpec`, and returns the decoded body.
  """
  def valid_operator_response(conn, status) do
    %{route: route} =
      Phoenix.Router.route_info(
        RengaWeb.OperatorRouter,
        conn.method,
        conn.request_path,
        conn.host
      )

    key = {String.downcase(conn.method), String.replace(route, ~r/:(\w+)/, "{\\1}")}

    %{"paths" => paths} =
      Oaskit.normalize_spec!(RengaWeb.OperatorApiSpec.spec(),
        spec_module: RengaWeb.OperatorApiSpec
      )

    {method, path} = key
    %{"operationId" => operation_id} = paths |> Map.fetch!(path) |> Map.fetch!(method)

    conn
    |> Plug.Conn.put_private(:oaskit, %{operation_id: operation_id})
    |> then(&Oaskit.Test.valid_response(RengaWeb.OperatorApiSpec, &1, status))
  end
end
