defmodule RengaWeb.OperatorApiTest do
  use RengaWeb.OperatorCase, async: true

  alias Renga.Operators

  describe "while no token can authenticate" do
    test "the API is off", %{conn: conn} do
      Renga.Repo.delete_all(Operators.OperatorToken)

      conn = conn |> authorize("renga_operator_anything") |> get("/operator/v1/deployment")

      assert json_response(conn, 404) == %{"error" => "not_found"}
    end
  end

  describe "authentication" do
    setup do
      {_token, plaintext} = operator_token_fixture()
      %{plaintext: plaintext}
    end

    test "refuses requests without a valid token", %{conn: conn, plaintext: plaintext} do
      for conn <- [
            conn,
            authorize(conn, plaintext <> "x"),
            put_req_header(conn, "authorization", "Basic " <> plaintext)
          ] do
        conn = get(conn, "/operator/v1/deployment")

        assert valid_operator_response(conn, 401) == %{"error" => "unauthorized"}
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      end
    end

    test "refuses a token used from an address it does not allow", %{conn: conn} do
      {_token, plaintext} = operator_token_fixture(%{allowed_sources: ["192.0.2.0/24"]})

      refused = conn |> authorize(plaintext) |> get("/operator/v1/deployment")
      assert valid_operator_response(refused, 401)

      allowed =
        %{conn | remote_ip: {192, 0, 2, 10}}
        |> authorize(plaintext)
        |> get("/operator/v1/deployment")

      assert valid_operator_response(allowed, 200)
    end

    test "ignores forwarding headers when checking the source", %{conn: conn} do
      {_token, plaintext} = operator_token_fixture(%{allowed_sources: ["192.0.2.0/24"]})

      conn =
        conn
        |> put_req_header("x-forwarded-for", "192.0.2.10")
        |> authorize(plaintext)
        |> get("/operator/v1/deployment")

      assert valid_operator_response(conn, 401)
    end
  end

  describe "GET /operator/v1/deployment" do
    test "reports the identifier and public URL", %{conn: conn} do
      {_token, plaintext} = operator_token_fixture(%{scopes: ["usage:read"]})

      body =
        conn
        |> authorize(plaintext)
        |> get("/operator/v1/deployment")
        |> valid_operator_response(200)

      assert body == %{"identifier" => Renga.Deployment.id(), "url" => RengaWeb.Endpoint.url()}
    end
  end

  describe "DELETE /operator/v1/tokens/self" do
    test "revokes only the token making the request", %{conn: conn} do
      {token, plaintext} = operator_token_fixture()
      {other, other_plaintext} = operator_token_fixture()

      conn |> authorize(plaintext) |> delete("/operator/v1/tokens/self") |> response(204)

      assert Operators.get_token(token.id).revoked_at
      refute Operators.get_token(other.id).revoked_at

      assert conn |> authorize(plaintext) |> get("/operator/v1/deployment") |> response(401)
      assert conn |> authorize(other_plaintext) |> get("/operator/v1/deployment") |> response(200)
    end
  end

  describe "GET /operator/v1/openapi.json" do
    test "serves this API's document", %{conn: conn} do
      {_token, plaintext} = operator_token_fixture()

      body =
        conn |> authorize(plaintext) |> get("/operator/v1/openapi.json") |> json_response(200)

      assert body["info"]["title"] == "Renga operator API"
      assert Map.has_key?(body["paths"], "/operator/v1/deployment")
    end
  end

  describe "require_scope/2" do
    test "lets a token through only with the scope", %{conn: conn} do
      {token, _plaintext} = operator_token_fixture(%{scopes: ["usage:read"]})
      conn = assign(conn, :operator_token, token)

      refute RengaWeb.OperatorAuth.require_scope(conn, "usage:read").halted

      refused = RengaWeb.OperatorAuth.require_scope(conn, "organizations:read")
      assert refused.halted
      assert json_response(refused, 403) == %{"error" => "forbidden"}
    end
  end

  test "the main listener serves no operator routes" do
    for {method, path} <- [
          {"GET", "/operator/v1/deployment"},
          {"DELETE", "/operator/v1/tokens/self"}
        ] do
      assert Phoenix.Router.route_info(RengaWeb.Router, method, path, "localhost") == :error
    end

    refute Enum.any?(
             Phoenix.Router.routes(RengaWeb.Router),
             &String.starts_with?(&1.path, "/operator")
           )
  end
end
