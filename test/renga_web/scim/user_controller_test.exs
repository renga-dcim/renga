defmodule RengaWeb.Scim.UserControllerTest do
  use RengaWeb.ConnCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.Scim.DirectoryUser

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @patch_schema "urn:ietf:params:scim:api:messages:2.0:PatchOp"

  setup %{conn: conn} do
    owner = member_scope(organization_fixture(), "owner")
    connection = scim_connection_fixture(owner)
    {token, value} = scim_token_fixture(owner, connection)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> value)
      |> put_req_header("content-type", "application/scim+json")

    %{conn: conn, owner: owner, connection: connection, token: token}
  end

  defp create_user(conn, attrs \\ %{}) do
    body =
      Map.merge(
        %{
          "schemas" => [@user_schema],
          "userName" => "sam@example.com",
          "externalId" => "00u1",
          "name" => %{"givenName" => "Sam", "familyName" => "Lee"},
          "emails" => [%{"value" => "sam@example.com", "type" => "work", "primary" => true}],
          "active" => true,
          "password" => "Sup3rS3cret!"
        },
        attrs
      )

    post(conn, ~p"/scim/v2/Users", Jason.encode!(body))
  end

  defp patch_ops(conn, id, operations) do
    patch(
      conn,
      ~p"/scim/v2/Users/#{id}",
      Jason.encode!(%{"schemas" => [@patch_schema], "Operations" => operations})
    )
  end

  defp body(conn, status) do
    assert conn.status == status, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  test "creates a user and discards the password", %{conn: conn} = context do
    created = conn |> create_user() |> then(&body(&1, 201))

    assert created["userName"] == "sam@example.com"
    assert created["externalId"] == "00u1"
    assert created["active"] == true
    assert created["name"] == %{"givenName" => "Sam", "familyName" => "Lee"}
    assert created["emails"] == [%{"value" => "sam@example.com", "primary" => true}]
    assert created["groups"] == []
    assert created["meta"]["location"] =~ "/scim/v2/Users/#{created["id"]}"
    refute Map.has_key?(created, "password")

    entry = Repo.get!(DirectoryUser, created["id"])
    refute inspect(entry) =~ "Sup3rS3cret!"
    assert entry.connection_id == context.connection.id

    event = Repo.get_by!(ChangeEvent, kind: "scim_user_created")
    refute inspect(event) =~ "Sup3rS3cret!"
    assert event.metadata["token_id"] == context.token.id
    assert event.metadata["connection_id"] == context.connection.id
    assert is_binary(event.metadata["request_id"])
    assert event.metadata["scim_user_id"] == created["id"]
  end

  test "a duplicate userName or externalId is a uniqueness conflict", %{conn: conn} do
    body(create_user(conn), 201)

    for attrs <- [
          %{"externalId" => "00u2", "userName" => "SAM@example.com"},
          %{"userName" => "x"}
        ] do
      conflict = conn |> create_user(attrs) |> then(&body(&1, 409))
      assert conflict["scimType"] == "uniqueness"
    end
  end

  test "users without an externalId can share the empty value", %{conn: conn} do
    body(create_user(conn, %{"externalId" => nil, "userName" => "a"}), 201)
    body(create_user(conn, %{"externalId" => "", "userName" => "b"}), 201)
  end

  test "reads, filters, and pages", %{conn: conn} do
    for n <- 1..3 do
      body(
        create_user(conn, %{"userName" => "user#{n}@example.com", "externalId" => "x#{n}"}),
        201
      )
    end

    all = conn |> get(~p"/scim/v2/Users") |> then(&body(&1, 200))
    assert all["totalResults"] == 3 and all["itemsPerPage"] == 3

    page = conn |> get(~p"/scim/v2/Users?startIndex=2&count=1") |> then(&body(&1, 200))
    assert page["totalResults"] == 3 and page["startIndex"] == 2
    assert [%{"userName" => "user2@example.com"}] = page["Resources"]

    found =
      conn
      |> get(~p"/scim/v2/Users?#{[filter: ~s(userName eq "USER3@example.com")]}")
      |> then(&body(&1, 200))

    assert [%{"externalId" => "x3"} = user] = found["Resources"]

    by_external =
      conn |> get(~p"/scim/v2/Users?#{[filter: ~s(externalId eq "x3")]}") |> then(&body(&1, 200))

    assert by_external["totalResults"] == 1
    assert body(get(conn, ~p"/scim/v2/Users/#{user["id"]}"), 200)["id"] == user["id"]

    assert body(get(conn, ~p"/scim/v2/Users?#{[filter: ~s(externalId eq "X3")]}"), 200)[
             "totalResults"
           ] == 0

    assert body(get(conn, ~p"/scim/v2/Users?#{[filter: ~s(id eq "nope")]}"), 200)["totalResults"] ==
             0

    assert %{"scimType" => "invalidFilter"} =
             body(get(conn, ~p"/scim/v2/Users?#{[filter: ~s(title co "x")]}"), 400)

    assert %{"scimType" => "invalidValue"} = body(get(conn, ~p"/scim/v2/Users?count=many"), 400)
  end

  test "count is capped at the maximum page size", %{conn: conn} do
    body(create_user(conn), 201)
    page = conn |> get(~p"/scim/v2/Users?count=1000") |> then(&body(&1, 200))
    assert page["itemsPerPage"] == 1
  end

  test "replace keeps active when omitted and rejects password changes", %{conn: conn} do
    created = conn |> create_user(%{"active" => false}) |> then(&body(&1, 201))

    replaced =
      conn
      |> put(
        ~p"/scim/v2/Users/#{created["id"]}",
        Jason.encode!(%{"userName" => "sam@example.com"})
      )
      |> then(&body(&1, 200))

    assert replaced["active"] == false
    refute Map.has_key?(replaced, "externalId")

    refused =
      conn
      |> put(
        ~p"/scim/v2/Users/#{created["id"]}",
        Jason.encode!(%{"userName" => "sam@example.com", "password" => "new"})
      )
      |> then(&body(&1, 400))

    assert refused["scimType"] == "invalidValue"
  end

  test "patch applies Entra and Okta operations", %{conn: conn} do
    created = conn |> create_user() |> then(&body(&1, 201))

    entra =
      conn
      |> patch_ops(created["id"], [%{"op" => "Replace", "path" => "active", "value" => "False"}])
      |> then(&body(&1, 200))

    assert entra["active"] == false

    okta =
      conn
      |> patch_ops(created["id"], [%{"op" => "replace", "value" => %{"active" => true}}])
      |> then(&body(&1, 200))

    assert okta["active"] == true

    refused =
      conn
      |> patch_ops(created["id"], [%{"op" => "replace", "path" => "password", "value" => "x"}])
      |> then(&body(&1, 400))

    assert refused["scimType"] == "invalidValue"

    assert %{"scimType" => "invalidSyntax"} =
             body(patch(conn, ~p"/scim/v2/Users/#{created["id"]}", "{}"), 400)
  end

  test "changing externalId clears the identity binding", %{conn: conn} do
    created = conn |> create_user() |> then(&body(&1, 201))
    identity_id = bind!(created["id"])

    conn
    |> patch_ops(created["id"], [%{"op" => "replace", "path" => "displayName", "value" => "Sam"}])
    |> body(200)

    assert Repo.get!(DirectoryUser, created["id"]).user_identity_id == identity_id

    conn
    |> patch_ops(created["id"], [%{"op" => "replace", "path" => "externalId", "value" => "00u9"}])
    |> body(200)

    assert Repo.get!(DirectoryUser, created["id"]).user_identity_id == nil
  end

  test "deletes, and a deleted or foreign user is not found", %{conn: conn} = context do
    created = conn |> create_user() |> then(&body(&1, 201))
    assert delete(conn, ~p"/scim/v2/Users/#{created["id"]}").status == 204
    assert body(get(conn, ~p"/scim/v2/Users/#{created["id"]}"), 404)
    assert Repo.get_by!(ChangeEvent, kind: "scim_user_deleted")

    other_owner = member_scope(organization_fixture(), "owner")
    {_token, other} = scim_token_fixture(other_owner, scim_connection_fixture(other_owner))
    foreign = conn |> create_user() |> then(&body(&1, 201))

    other_conn = put_req_header(context.conn, "authorization", "Bearer " <> other)
    assert body(get(other_conn, ~p"/scim/v2/Users/#{foreign["id"]}"), 404)
    assert body(delete(other_conn, ~p"/scim/v2/Users/#{foreign["id"]}"), 404)
    assert body(get(other_conn, ~p"/scim/v2/Users"), 200)["totalResults"] == 0
  end

  # Binds an entry to a fresh identity, as sign-in linking will.
  defp bind!(entry_id) do
    user = Renga.AccountsFixtures.user_fixture()
    provider = scim_provider_fixture()

    identity =
      Repo.insert!(%Renga.Accounts.UserIdentity{
        user_id: user.id,
        provider_id: provider.id,
        subject: "00u1"
      })

    DirectoryUser
    |> Repo.get!(entry_id)
    |> Ecto.Changeset.change(user_identity_id: identity.id)
    |> Repo.update!()

    identity.id
  end
end
