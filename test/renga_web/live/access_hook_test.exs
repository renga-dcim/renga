defmodule RengaWeb.AccessHookTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  alias Renga.Accounts.UserIdentity
  alias Renga.Repo
  alias Renga.Scim
  alias Renga.Scim.Client
  alias Renga.Scim.Groups
  alias Renga.Scim.Linking
  alias Renga.Scim.Users

  setup do
    organization = organization_fixture()
    owner = member_scope(organization, "owner")
    provider = scim_provider_fixture()

    connection =
      scim_connection_fixture(owner, %{"provider_id" => provider.id, "default_role" => "viewer"})

    {token, _value} = scim_token_fixture(owner, connection)
    client = %Client{connection: connection, token_id: token.id}

    {:ok, entry} = Users.create(client, %{"userName" => "sam", "externalId" => "sub-sam"})
    user = user_fixture()

    identity =
      Repo.insert!(%UserIdentity{user_id: user.id, provider_id: provider.id, subject: "sub-sam"})

    Linking.link_identity(identity, %{"sub" => "sub-sam"})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{
      conn: conn,
      client: client,
      entry: entry,
      owner: owner,
      user: user,
      organization: organization
    }
  end

  test "losing the SCIM grant sends an open page to organization selection", context do
    {:ok, view, _html} = live(context.conn, ~p"/inventory")

    {:ok, _} =
      Users.patch(context.client, context.entry.id, [
        %{"op" => "Replace", "path" => "active", "value" => "False"}
      ])

    flash = assert_redirect(view, "/organizations")
    assert flash["error"] =~ "no longer have access"
  end

  # The page's scope is read before the hook subscribes; a revocation in
  # between is announced to nobody, so mounting re-reads it.
  test "a scope that went stale before subscribing is refreshed at mount", context do
    stale = Renga.Accounts.scope_for_user(context.user, context.organization.id)

    {:ok, _} =
      Users.patch(context.client, context.entry.id, [
        %{"op" => "replace", "path" => "active", "value" => false}
      ])

    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}, flash: %{}, current_scope: stale}
    }

    assert {:halt, %{redirected: {:redirect, %{to: "/organizations"}}}} =
             RengaWeb.AccessHook.on_mount(:default, %{}, %{}, socket)
  end

  test "a downgrade reloads the page with the new role", context do
    {:ok, group} =
      Groups.create(context.client, %{
        "displayName" => "Admins",
        "members" => [%{"value" => context.entry.id}]
      })

    {:ok, _} = Scim.map_group(context.owner, group.id, "admin")

    {:ok, view, _html} = live(context.conn, ~p"/inventory?q=rack")

    {:ok, _} =
      Groups.patch(context.client, group.id, [%{"op" => "remove", "path" => "members"}])

    assert_redirect(view, "/inventory?q=rack")
  end

  test "a change in another organization leaves the page alone", context do
    other = organization_fixture()
    organization_membership_fixture(context.user, other, %{role: "member"})

    {:ok, view, _html} =
      context.conn
      |> put_session(:current_organization_id, other.id)
      |> live(~p"/inventory")

    {:ok, _} =
      Users.patch(context.client, context.entry.id, [
        %{"op" => "replace", "path" => "active", "value" => false}
      ])

    assert render(view) =~ "Inventory"
  end

  test "a failed change announces nothing", context do
    {:ok, view, _html} = live(context.conn, ~p"/inventory")

    assert {:error, {:invalid_value, _}} =
             Users.patch(context.client, context.entry.id, [
               %{"op" => "replace", "path" => "active", "value" => false},
               %{"op" => "replace", "path" => "active", "value" => "maybe"}
             ])

    assert render(view) =~ "Inventory"
  end
end
