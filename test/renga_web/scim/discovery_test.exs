defmodule RengaWeb.Scim.DiscoveryTest do
  use RengaWeb.ConnCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  alias Renga.Scim

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"
  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  setup %{conn: conn} do
    organization = organization_fixture()
    owner = member_scope(organization, "owner")
    connection = scim_connection_fixture(owner)
    {token, value} = scim_token_fixture(owner, connection)

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> value),
      bare: conn,
      owner: owner,
      organization: organization,
      token: token,
      value: value
    }
  end

  describe "authentication" do
    test "refuses a missing, malformed, or revoked token", context do
      for conn <- [
            context.bare,
            put_req_header(context.bare, "authorization", "Basic " <> context.value),
            put_req_header(context.bare, "authorization", "Bearer renga_scim_nope")
          ] do
        conn = get(conn, ~p"/scim/v2/ServiceProviderConfig")
        assert_scim_error(conn, 401)
        assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="scim")]
      end

      {:ok, _} = Scim.revoke_token(context.owner, context.token.id)
      assert_scim_error(get(context.conn, ~p"/scim/v2/ServiceProviderConfig"), 401)
    end

    test "accepts the scheme in any case and records use", context do
      conn =
        context.bare
        |> put_req_header("authorization", "bearer " <> context.value)
        |> get(~p"/scim/v2/ServiceProviderConfig")

      assert conn.status == 200
      assert Renga.Repo.reload!(context.token).last_used_at
    end

    test "a browser session never reaches SCIM", context do
      conn =
        context.bare
        |> log_in_user(context.owner.user)
        |> get(~p"/scim/v2/ServiceProviderConfig")

      assert_scim_error(conn, 401)
    end

    test "a SCIM token never reaches the agent API", context do
      conn =
        context.bare
        |> put_req_header("authorization", "Bearer " <> context.value)
        |> put_req_header("x-renga-installation-id", Ecto.UUID.generate())
        |> post(~p"/api/v1/agent/checkins", %{})

      assert conn.status == 401
    end

    test "an intake key never reaches SCIM", context do
      {:ok, {_key, intake}} =
        Renga.Inventory.create_intake_api_key(context.owner, %{"name" => "agent"})

      conn =
        context.bare
        |> put_req_header("authorization", "Bearer " <> intake)
        |> get(~p"/scim/v2/ServiceProviderConfig")

      assert_scim_error(conn, 401)
    end
  end

  describe "discovery" do
    test "ServiceProviderConfig advertises only what Renga supports", %{conn: conn} do
      conn = get(conn, ~p"/scim/v2/ServiceProviderConfig")

      assert ["application/scim+json" <> _] = get_resp_header(conn, "content-type")
      config = Jason.decode!(conn.resp_body)

      assert config["patch"] == %{"supported" => true}
      assert config["filter"] == %{"supported" => true, "maxResults" => 100}

      for capability <- ~w(bulk changePassword sort etag),
          do: assert(config[capability]["supported"] == false)

      assert [%{"type" => "oauthbearertoken", "primary" => true}] =
               config["authenticationSchemes"]

      assert config["meta"]["location"] =~ "/scim/v2/ServiceProviderConfig"
    end

    test "lists and finds the resource types", %{conn: conn} do
      list = conn |> get(~p"/scim/v2/ResourceTypes") |> json_response(200)

      assert list["totalResults"] == 2
      assert Enum.map(list["Resources"], & &1["endpoint"]) == ["/Users", "/Groups"]

      assert %{"schema" => @group_schema} =
               conn |> get(~p"/scim/v2/ResourceTypes/Group") |> json_response(200)

      assert_scim_error(get(conn, ~p"/scim/v2/ResourceTypes/Device"), 404)
    end

    test "lists and finds the schemas", %{conn: conn} do
      list = conn |> get(~p"/scim/v2/Schemas") |> json_response(200)
      assert Enum.map(list["Resources"], & &1["id"]) == [@user_schema, @group_schema]

      user = conn |> get(~p"/scim/v2/Schemas/#{@user_schema}") |> json_response(200)
      names = Enum.map(user["attributes"], & &1["name"])
      assert names == ~w(userName name displayName emails active groups)
      refute "password" in names

      groups = Enum.find(user["attributes"], &(&1["name"] == "groups"))
      assert groups["mutability"] == "readOnly"

      assert_scim_error(get(conn, ~p"/scim/v2/Schemas/urn:example:nope"), 404)
    end

    test "/Me is not implemented", %{conn: conn} do
      assert_scim_error(get(conn, ~p"/scim/v2/Me"), 501)
      assert_scim_error(post(conn, ~p"/scim/v2/Me", %{}), 501)
    end

    test "an unknown path is a SCIM not-found", %{conn: conn} do
      assert_scim_error(get(conn, ~p"/scim/v2/Bulk"), 404)
    end
  end

  describe "request bodies" do
    test "malformed JSON is invalidSyntax", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/scim+json")
        |> post(~p"/scim/v2/Users", "{not json")

      assert %{"scimType" => "invalidSyntax"} = assert_scim_error(conn, 400)
    end

    test "parses application/scim+json", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/scim+json")
        |> post(~p"/scim/v2/Me", ~s({"userName": "sam"}))

      assert conn.body_params == %{"userName" => "sam"}
    end

    test "an oversized body is refused", %{conn: conn} do
      body =
        Jason.encode!(%{"filler" => String.duplicate("a", RengaWeb.Parsers.scim_max_bytes())})

      conn =
        conn
        |> put_req_header("content-type", "application/scim+json")
        |> post(~p"/scim/v2/Users", body)

      assert_scim_error(conn, 413)
    end

    # The router decodes /%73cim to /scim, so the bound must apply there too.
    test "a percent-encoded SCIM path gets the same bound and errors", %{conn: conn} do
      conn = put_req_header(conn, "content-type", "application/scim+json")

      body =
        Jason.encode!(%{"filler" => String.duplicate("a", RengaWeb.Parsers.scim_max_bytes())})

      assert_scim_error(post(conn, "/%73cim/v2/Me", body), 413)

      assert %{"scimType" => "invalidSyntax"} =
               assert_scim_error(post(conn, "/%73cim/v2/Me", "{not json"), 400)
    end
  end

  describe "rate limit" do
    test "counts per key in one-minute windows" do
      key = make_ref()
      now = 1_000_040

      assert :ok = RengaWeb.Scim.RateLimit.check(key, 2, now)
      assert :ok = RengaWeb.Scim.RateLimit.check(key, 2, now)
      assert {:error, 40} = RengaWeb.Scim.RateLimit.check(key, 2, now)
      assert :ok = RengaWeb.Scim.RateLimit.check(make_ref(), 2, now)
      assert :ok = RengaWeb.Scim.RateLimit.check(key, 2, now + 60)
    end
  end

  defp assert_scim_error(conn, status) do
    assert conn.status == status
    assert ["application/scim+json" <> _] = get_resp_header(conn, "content-type")
    body = Jason.decode!(conn.resp_body)
    assert body["schemas"] == [@error_schema]
    assert body["status"] == Integer.to_string(status)
    body
  end
end
