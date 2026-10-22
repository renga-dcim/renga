defmodule RengaWeb.Api.V1.AgentHomeControllerTest do
  use RengaWeb.ConnCase, async: true

  describe "GET /api/v1/agent/home" do
    test "answers with this deployment's public URL without a credential", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/agent/home?deployment=eu1")

      assert valid_api_response(conn, 200) == %{"home" => RengaWeb.Endpoint.url()}
      # A cached answer could outlive a change of the deployment's URL.
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "is its own home whatever identifier is asked for", %{conn: conn} do
      for query <- ["", "?deployment=", "?deployment=elsewhere"] do
        body = conn |> get("/api/v1/agent/home" <> query) |> valid_api_response(200)

        assert body == %{"home" => RengaWeb.Endpoint.url()}
      end
    end

    test "ignores the request's host when answering", %{conn: conn} do
      body =
        %{conn | host: "attacker.example"}
        |> put_req_header("x-forwarded-host", "attacker.example")
        |> get(~p"/api/v1/agent/home")
        |> valid_api_response(200)

      assert body == %{"home" => RengaWeb.Endpoint.url()}
    end
  end
end
