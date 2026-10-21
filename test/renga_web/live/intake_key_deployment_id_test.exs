defmodule RengaWeb.IntakeKeyDeploymentIdTest do
  # Changes the deployment identifier, which is application environment.
  use RengaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory

  setup %{conn: conn} do
    previous = Application.get_env(:renga, :deployment_id)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:renga, :deployment_id, previous),
        else: Application.delete_env(:renga, :deployment_id)
    end)

    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    %{conn: conn, scope: scope}
  end

  test "shows the identifier each key carries", %{conn: conn, scope: scope} do
    Application.delete_env(:renga, :deployment_id)
    {:ok, {old_key, _token}} = Inventory.create_intake_api_key(scope, %{name: "Old"})
    Application.put_env(:renga, :deployment_id, "eu1")
    {:ok, {new_key, _token}} = Inventory.create_intake_api_key(scope, %{name: "New"})

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")

    assert has_element?(view, "#intake-key-deployment-id", "eu1")
    assert has_element?(view, "#intake-key-#{new_key.id}-deployment-id", "eu1")
    refute has_element?(view, "#intake-key-#{old_key.id}-deployment-id")
  end

  test "issues keys carrying the identifier", %{conn: conn} do
    Application.put_env(:renga, :deployment_id, "eu1")
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")

    view |> element("#new-intake-key-button") |> render_click()

    view
    |> form("#new-intake-key-form", intake_api_key: %{name: "Fleet"})
    |> render_submit()

    assert has_element?(view, "#issued-intake-key", "renga_intake_eu1_")
  end

  test "says nothing about identifiers when the deployment has none", %{
    conn: conn,
    scope: scope
  } do
    Application.delete_env(:renga, :deployment_id)
    {:ok, {key, _token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")

    refute has_element?(view, "#intake-key-deployment-id")
    refute has_element?(view, "#intake-key-#{key.id}-deployment-id")
  end
end
