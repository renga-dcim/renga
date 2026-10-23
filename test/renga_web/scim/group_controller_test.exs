defmodule RengaWeb.Scim.GroupControllerTest do
  use RengaWeb.ConnCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo

  @patch_schema "urn:ietf:params:scim:api:messages:2.0:PatchOp"

  setup %{conn: conn} do
    owner = member_scope(organization_fixture(), "owner")
    {_token, value} = scim_token_fixture(owner, scim_connection_fixture(owner))

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> value)
      |> put_req_header("content-type", "application/scim+json")

    %{conn: conn}
  end

  defp body(conn, status) do
    assert conn.status == status, conn.resp_body
    if conn.resp_body == "", do: %{}, else: Jason.decode!(conn.resp_body)
  end

  defp user!(conn, name) do
    conn |> post(~p"/scim/v2/Users", Jason.encode!(%{"userName" => name})) |> body(201)
  end

  defp group!(conn, attrs) do
    conn
    |> post(~p"/scim/v2/Groups", Jason.encode!(Map.merge(%{"displayName" => "Ops"}, attrs)))
    |> body(201)
  end

  defp patch_ops(conn, id, operations) do
    patch(
      conn,
      ~p"/scim/v2/Groups/#{id}",
      Jason.encode!(%{"schemas" => [@patch_schema], "Operations" => operations})
    )
  end

  defp member_ids(group), do: group["members"] |> Enum.map(& &1["value"]) |> Enum.sort()

  test "creates a group with members and shows it on the user", %{conn: conn} do
    sam = user!(conn, "sam")
    group = group!(conn, %{"members" => [%{"value" => sam["id"]}]})

    assert member_ids(group) == [sam["id"]]
    assert [%{"display" => "sam"}] = group["members"]

    assert [%{"value" => group_id, "display" => "Ops"}] =
             conn |> get(~p"/scim/v2/Users/#{sam["id"]}") |> body(200) |> Map.fetch!("groups")

    assert group_id == group["id"]

    event = Repo.get_by!(ChangeEvent, kind: "scim_group_created")
    assert event.metadata["members_added"] == [sam["id"]]
  end

  test "an omitted members list on POST makes an empty group", %{conn: conn} do
    assert group!(conn, %{})["members"] == []
  end

  test "PUT replaces the member set whole and empties it when omitted", %{conn: conn} do
    sam = user!(conn, "sam")
    kim = user!(conn, "kim")
    group = group!(conn, %{"members" => [%{"value" => sam["id"]}]})

    replaced =
      conn
      |> put(
        ~p"/scim/v2/Groups/#{group["id"]}",
        Jason.encode!(%{"displayName" => "Ops", "members" => [%{"value" => kim["id"]}]})
      )
      |> body(200)

    assert member_ids(replaced) == [kim["id"]]

    emptied =
      conn
      |> put(~p"/scim/v2/Groups/#{group["id"]}", Jason.encode!(%{"displayName" => "Ops"}))
      |> body(200)

    assert emptied["members"] == []
  end

  test "PATCH add and remove change only the named members", %{conn: conn} do
    [sam, kim, lee] = Enum.map(~w(sam kim lee), &user!(conn, &1))
    group = group!(conn, %{"members" => [%{"value" => sam["id"]}]})

    added =
      conn
      |> patch_ops(group["id"], [
        %{
          "op" => "add",
          "path" => "members",
          "value" => [%{"value" => kim["id"]}, %{"value" => lee["id"]}]
        }
      ])
      |> body(200)

    assert member_ids(added) == Enum.sort([sam["id"], kim["id"], lee["id"]])

    removed =
      conn
      |> patch_ops(group["id"], [
        %{"op" => "remove", "path" => ~s(members[value eq "#{kim["id"]}"])}
      ])
      |> body(200)

    assert member_ids(removed) == Enum.sort([sam["id"], lee["id"]])

    event =
      ChangeEvent
      |> Repo.all()
      |> Enum.filter(&(&1.kind == "scim_group_updated"))
      |> Enum.find(&(&1.metadata["members_removed"] != []))

    assert event.metadata["members_removed"] == [kim["id"]]

    cleared =
      conn |> patch_ops(group["id"], [%{"op" => "remove", "path" => "members"}]) |> body(200)

    assert cleared["members"] == []
  end

  test "member ids match without case", %{conn: conn} do
    [sam, kim] = Enum.map(~w(sam kim), &user!(conn, &1))
    group = group!(conn, %{"members" => [%{"value" => String.upcase(sam["id"])}]})
    assert member_ids(group) == [sam["id"]]

    patched =
      conn
      |> patch_ops(group["id"], [
        %{
          "op" => "add",
          "path" => "members",
          "value" => [%{"value" => String.upcase(kim["id"])}]
        },
        %{"op" => "remove", "path" => "members", "value" => [%{"value" => kim["id"]}]},
        %{"op" => "remove", "path" => ~s(members[value eq "#{String.upcase(sam["id"])}"])}
      ])
      |> body(200)

    assert patched["members"] == []
  end

  test "members must be users of the same connection", %{conn: conn} = context do
    other_owner = member_scope(organization_fixture(), "owner")
    {_token, other} = scim_token_fixture(other_owner, scim_connection_fixture(other_owner))
    other_conn = put_req_header(context.conn, "authorization", "Bearer " <> other)
    foreign = user!(other_conn, "foreign")

    for members <- [[%{"value" => foreign["id"]}], [%{"value" => "not-an-id"}], [%{}]] do
      assert %{"scimType" => "invalidValue"} =
               conn
               |> post(
                 ~p"/scim/v2/Groups",
                 Jason.encode!(%{"displayName" => "x", "members" => members})
               )
               |> body(400)
    end

    group = group!(conn, %{})

    assert %{"scimType" => "invalidValue"} =
             conn
             |> patch_ops(group["id"], [
               %{"op" => "add", "path" => "members", "value" => [%{"value" => foreign["id"]}]}
             ])
             |> body(400)

    assert conn |> get(~p"/scim/v2/Groups/#{group["id"]}") |> body(200) |> Map.fetch!("members") ==
             []

    assert body(get(other_conn, ~p"/scim/v2/Groups/#{group["id"]}"), 404)
  end

  test "a rename keeps the group's id; a recreated group gets a new one", %{conn: conn} do
    group = group!(conn, %{})

    renamed =
      conn
      |> patch_ops(group["id"], [%{"op" => "replace", "path" => "displayName", "value" => "SRE"}])
      |> body(200)

    assert renamed["id"] == group["id"] and renamed["displayName"] == "SRE"

    assert body(delete(conn, ~p"/scim/v2/Groups/#{group["id"]}"), 204)
    assert group!(conn, %{"displayName" => "SRE"})["id"] != group["id"]
  end

  test "deleting a user removes it from its groups", %{conn: conn} do
    sam = user!(conn, "sam")
    group = group!(conn, %{"members" => [%{"value" => sam["id"]}]})

    body(delete(conn, ~p"/scim/v2/Users/#{sam["id"]}"), 204)

    assert conn |> get(~p"/scim/v2/Groups/#{group["id"]}") |> body(200) |> Map.fetch!("members") ==
             []
  end

  test "filters, pages, and excludes members", %{conn: conn} do
    sam = user!(conn, "sam")

    group!(conn, %{
      "displayName" => "Ops",
      "externalId" => "g1",
      "members" => [%{"value" => sam["id"]}]
    })

    group!(conn, %{"displayName" => "SRE"})

    assert %{"totalResults" => 1, "Resources" => [ops]} =
             conn |> get(~p"/scim/v2/Groups?#{[filter: ~s(displayName eq "ops")]}") |> body(200)

    assert ops["externalId"] == "g1"
    assert member_ids(ops) == [sam["id"]]

    assert %{"Resources" => [bare]} =
             conn
             |> get(
               ~p"/scim/v2/Groups?#{[filter: ~s(externalId eq "g1"), excludedAttributes: "members"]}"
             )
             |> body(200)

    refute Map.has_key?(bare, "members")

    refute conn
           |> get(~p"/scim/v2/Groups/#{ops["id"]}?excludedAttributes=members")
           |> body(200)
           |> Map.has_key?("members")

    assert %{"totalResults" => 2, "itemsPerPage" => 1} =
             conn |> get(~p"/scim/v2/Groups?count=1") |> body(200)

    assert %{"scimType" => "invalidFilter"} =
             conn |> get(~p"/scim/v2/Groups?#{[filter: ~s(members eq "x")]}") |> body(400)
  end

  # The column holds 255 code points; a combining accent is a code point but
  # not a grapheme, so a grapheme count would pass this and fail in Postgres.
  test "a displayName too long for its column is invalidValue with a readable detail",
       %{conn: conn} do
    refused =
      conn
      |> post(
        ~p"/scim/v2/Groups",
        Jason.encode!(%{"displayName" => String.duplicate("e\u0301", 128)})
      )
      |> body(400)

    assert refused["scimType"] == "invalidValue"
    assert refused["detail"] =~ "at most 255 character(s)"
  end

  test "displayName is required", %{conn: conn} do
    assert %{"scimType" => "invalidValue"} =
             conn |> post(~p"/scim/v2/Groups", Jason.encode!(%{})) |> body(400)

    group = group!(conn, %{})

    assert %{"scimType" => "invalidValue"} =
             conn
             |> patch_ops(group["id"], [%{"op" => "remove", "path" => "displayName"}])
             |> body(400)
  end
end
