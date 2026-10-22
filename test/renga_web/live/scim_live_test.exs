defmodule RengaWeb.ScimLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  alias Renga.Repo
  alias Renga.Scim
  alias Renga.Scim.Client
  alias Renga.Scim.Groups

  setup %{conn: conn} do
    organization = organization_fixture()
    owner = member_scope(organization, "owner")

    conn =
      conn
      |> log_in_user(owner.user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn, organization: organization, owner: owner}
  end

  test "an owner connects a provider and issues a token shown once", %{conn: conn} = context do
    provider = scim_provider_fixture(%{"display_name" => "Acme Okta"})
    {:ok, view, _html} = live(conn, ~p"/settings/scim")

    view
    |> form("#scim-connect-form",
      connection: %{"provider_id" => provider.id, "default_role" => "viewer"}
    )
    |> render_submit()

    assert has_element?(view, "#scim-connection-heading", "Acme Okta")
    assert has_element?(view, "#scim-base-url", "/scim/v2")
    assert [%{default_role: "viewer"}] = Scim.list_connections(context.owner)

    view |> element("#scim-new-token") |> render_click()
    view |> form("#scim-token-form", token: %{"name" => "Okta"}) |> render_submit()

    value =
      view
      |> element("#issued-scim-token")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert {:ok, _connection, _token} = Scim.authenticate(value)

    view |> element("#scim-token-saved") |> render_click()
    refute has_element?(view, "#issued-scim-token")
    refute render(view) =~ value
    assert has_element?(view, "#scim-token-list", "Okta")
  end

  test "the token button goes away at two tokens, and revoking frees one", context do
    connection = scim_connection_fixture(context.owner)
    {first, _value} = scim_token_fixture(context.owner, connection, "One")
    scim_token_fixture(context.owner, connection, "Two")

    {:ok, view, _html} = live(context.conn, ~p"/settings/scim")
    refute has_element?(view, "#scim-new-token")

    render_click(view, "revoke_token", %{"id" => first.id})
    assert has_element?(view, "#scim-new-token")
    refute has_element?(view, "#scim-token-#{first.id}")
    assert Repo.reload!(first).revoked_at
  end

  test "an owner changes the default role and maps pushed groups", context do
    connection = scim_connection_fixture(context.owner, %{"default_role" => "member"})
    {token, _value} = scim_token_fixture(context.owner, connection)
    client = %Client{connection: connection, token_id: token.id, request_id: "req"}
    {:ok, view, _html} = live(context.conn, ~p"/settings/scim")

    assert has_element?(view, "#scim-group-list", "No groups pushed yet")

    # A push arrives while the page is open.
    {:ok, group} = Groups.create(client, %{"displayName" => "Admins"})
    assert has_element?(view, "#scim-group-#{group.id}", "Admins")
    assert has_element?(view, "#scim-group-#{group.id}", "0 members")

    view |> form("#scim-group-#{group.id}", role: "admin") |> render_change()
    assert Repo.reload!(group).role == "admin"

    view |> form("#scim-default-role-form", default_role: %{role: ""}) |> render_change()
    assert Repo.reload!(connection).default_role == nil
  end

  test "disabling keeps the connection as history and it can be enabled again", context do
    connection = scim_connection_fixture(context.owner)
    {:ok, view, _html} = live(context.conn, ~p"/settings/scim")

    render_click(view, "disable", %{"id" => connection.id})
    assert has_element?(view, "#scim-connect")
    assert has_element?(view, "#scim-connection-#{connection.id}")

    view |> element("#scim-connection-#{connection.id}-enable") |> render_click()
    assert has_element?(view, "#scim-connection")
    refute has_element?(view, "#scim-connection-#{connection.id}-enable")
  end

  test "without an OpenID Connect provider there is nothing to connect", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/scim")
    assert has_element?(view, "#scim-no-providers")
    refute has_element?(view, "#scim-connect-form")
  end

  test "admins see that only owners manage SCIM", %{conn: conn} = context do
    scim_connection_fixture(context.owner)
    admin = member_scope(context.organization, "admin")

    conn =
      conn
      |> log_in_user(admin.user)
      |> put_session(:current_organization_id, context.organization.id)

    {:ok, view, _html} = live(conn, ~p"/settings/scim")
    assert has_element?(view, "#scim-owners-only")
    refute has_element?(view, "#scim-connection")
  end
end
