defmodule RengaWeb.OperatorApiTest do
  use RengaWeb.OperatorCase, async: true

  import Ecto.Query

  alias Renga.Operators

  describe "while no token can authenticate" do
    setup do
      Renga.Repo.delete_all(Operators.OperatorToken)
      :ok
    end

    test "every documented operation answers the documented 404", %{conn: conn} do
      for {method, path} <- [
            {:get, "/operator/v1/deployment"},
            {:get, "/operator/v1/openapi.json"},
            {:delete, "/operator/v1/tokens/self"}
          ] do
        conn = conn |> authorize("renga_operator_anything") |> dispatch(@endpoint, method, path)

        assert valid_operator_response(conn, 404) == %{"error" => "not_found"}
      end
    end

    test "nothing tells a caller which paths exist", %{conn: conn} do
      responses =
        for request <- [
              &get(&1, "/operator/v1/deployment"),
              &get(&1, "/operator/v1/nothing-here"),
              &get(&1, "/elsewhere"),
              &post(&1, "/operator/v1/deployment"),
              &(&1 |> put_req_header("accept", "text/html") |> get("/operator/v1/deployment")),
              &(&1
                |> put_req_header("content-type", "application/json")
                |> post("/operator/v1/tokens/self", "{not json"))
            ] do
          conn = request.(conn)
          {conn.status, conn.resp_body}
        end

      assert Enum.uniq(responses) == [{404, ~s({"error":"not_found"})}]
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

    test "accepts the bearer scheme in any case, and only one Authorization header", %{
      conn: conn,
      plaintext: plaintext
    } do
      for scheme <- ["bearer", "BEARER", "Bearer"] do
        conn =
          conn
          |> put_req_header("authorization", scheme <> " " <> plaintext)
          |> get("/operator/v1/deployment")

        assert valid_operator_response(conn, 200)
      end

      conn = authorize(conn, plaintext)
      conn = %{conn | req_headers: [{"authorization", "Bearer " <> plaintext} | conn.req_headers]}

      assert length(get_req_header(conn, "authorization")) == 2
      assert conn |> get("/operator/v1/deployment") |> valid_operator_response(401)
    end

    test "never reads the body of an unauthenticated request", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> delete("/operator/v1/tokens/self", "{not json")

      assert valid_operator_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "answers unknown paths in its own error shape once authenticated", %{
      conn: conn,
      plaintext: plaintext
    } do
      assert %{status: 401} = get(conn, "/operator/v1/nothing-here")

      assert conn
             |> authorize(plaintext)
             |> get("/operator/v1/nothing-here")
             |> json_response(404) ==
               %{"error" => "not_found"}
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

      revoked = conn |> authorize(plaintext) |> delete("/operator/v1/tokens/self")
      assert response(revoked, 204) == ""
      [request_id] = get_resp_header(revoked, "x-request-id")

      assert Operators.get_token(token.id).revoked_at

      assert %{actor: actor, actor_token_id: actor_token_id, changed: ["revoked_at"]} =
               Renga.Repo.get_by!(Renga.DeploymentAudit.Event, invocation_id: request_id)

      assert {actor, actor_token_id} == {"token: " <> token.name, token.id}
      refute Operators.get_token(other.id).revoked_at

      assert conn |> authorize(plaintext) |> get("/operator/v1/deployment") |> response(401)
      assert conn |> authorize(other_plaintext) |> get("/operator/v1/deployment") |> response(200)
    end
  end

  describe "an authenticated self-revocation" do
    test "reaches the operation, which records it, whatever its body or Accept header", %{
      conn: conn
    } do
      for request <- [
            &(&1
              |> put_req_header("content-type", "application/json")
              |> delete("/operator/v1/tokens/self", "{not json")),
            &(&1 |> put_req_header("accept", "text/html") |> delete("/operator/v1/tokens/self"))
          ] do
        {token, plaintext} = operator_token_fixture()

        conn = conn |> authorize(plaintext) |> request.()
        [request_id] = get_resp_header(conn, "x-request-id")

        assert response(conn, 204) == ""
        assert Operators.get_token(token.id).revoked_at

        assert [%{outcome: "succeeded"}] =
                 Renga.Repo.all(
                   from event in Renga.DeploymentAudit.Event,
                     where: event.invocation_id == ^request_id
                 )
      end
    end

    test "is never recorded when the request fails authentication", %{conn: conn} do
      {_token, plaintext} = operator_token_fixture()
      before = Renga.Repo.aggregate(Renga.DeploymentAudit.Event, :count)

      assert conn
             |> authorize(plaintext <> "x")
             |> delete("/operator/v1/tokens/self")
             |> response(401)

      assert Renga.Repo.aggregate(Renga.DeploymentAudit.Event, :count) == before
    end
  end

  describe "GET /operator/v1/openapi.json" do
    test "serves this API's document", %{conn: conn} do
      {_token, plaintext} = operator_token_fixture()

      body =
        conn
        |> authorize(plaintext)
        |> get("/operator/v1/openapi.json")
        |> valid_operator_response(200)

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

  test "the main endpoint answers no operator path", %{conn: conn} do
    {_token, plaintext} = operator_token_fixture()

    for {method, path} <- [
          {:get, "/operator/v1/deployment"},
          {:get, "/operator/v1/openapi.json"},
          {:delete, "/operator/v1/tokens/self"}
        ] do
      conn =
        conn
        |> authorize(plaintext)
        |> put_req_header("accept", "application/json")
        |> dispatch(RengaWeb.Endpoint, method, path)

      assert conn.status == 404
      refute conn.resp_body =~ "renga_operator"
      refute Operators.get_token(Operators.list_tokens() |> hd() |> Map.fetch!(:id)).revoked_at
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
