defmodule RengaWeb.ComponentFindingLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Catalog.ComponentFinding
  alias Renga.Inventory
  alias Renga.Repo

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: "finding-server"})

    %{conn: conn, organization: organization, resource: resource, scope: scope}
  end

  test "lists organization findings with resource navigation and filters by status", %{
    conn: conn,
    resource: resource,
    scope: scope
  } do
    open = finding_fixture(scope, resource, "component_drift", "open")
    resolved = finding_fixture(scope, resource, "missing_expected_component", "resolved")

    {:ok, view, _html} = live(conn, ~p"/inventory/component-findings")

    assert has_element?(view, "#component-findings")
    assert has_element?(view, "#component-findings-#{open.id}", "Component drift")
    refute has_element?(view, "#component-findings-#{resolved.id}")

    assert has_element?(
             view,
             "#component-findings-#{open.id} a[href='/inventory/resources/#{resource.id}/hardware']"
           )

    view
    |> form("#component-finding-filters", filters: %{status: "resolved"})
    |> render_change()

    refute has_element?(view, "#component-findings-#{open.id}")
    assert has_element?(view, "#component-findings-#{resolved.id}", "Missing expected component")
  end

  test "finding list and counts exclude another organization", %{
    conn: conn,
    resource: resource,
    scope: scope
  } do
    local = finding_fixture(scope, resource, "unexpected_actual_component", "open")

    other_user = user_fixture()
    other_organization = organization_fixture()
    organization_membership_fixture(other_user, other_organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, other_organization.id)

    {:ok, foreign_resource} =
      Inventory.create_resource(other_scope, %{kind: "server", name: "foreign-finding-server"})

    foreign = finding_fixture(other_scope, foreign_resource, "component_drift", "open")

    {:ok, view, _html} = live(conn, ~p"/inventory/component-findings")

    assert has_element?(view, "#component-findings-#{local.id}")
    refute has_element?(view, "#component-findings-#{foreign.id}")
    assert has_element?(view, "#component-findings", "1")
  end

  test "viewer has organization-scoped read access", %{
    organization: organization,
    resource: resource,
    scope: scope
  } do
    finding = finding_fixture(scope, resource, "ambiguous_component_identity", "open")
    viewer = user_fixture()
    organization_membership_fixture(viewer, organization, %{role: "viewer"})

    viewer_conn =
      build_conn()
      |> log_in_user(viewer)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(viewer_conn, ~p"/inventory/component-findings")
    assert has_element?(view, "#component-findings-#{finding.id}")
    refute has_element?(view, "#component-findings-list form")
    refute has_element?(view, "#component-findings-list [phx-click]")
  end

  test "requires authentication", %{resource: resource} do
    assert {:error, {:redirect, %{to: path}}} =
             live(build_conn(), ~p"/inventory/resources/#{resource.id}/hardware")

    assert path =~ "/users/log-in"
  end

  defp finding_fixture(scope, resource, kind, status) do
    resolved_at = if status == "resolved", do: ~U[2026-08-20 13:00:00.000000Z]

    %ComponentFinding{
      organization_id: scope.organization_id,
      resource_id: resource.id
    }
    |> ComponentFinding.changeset(%{
      kind: kind,
      resolution_key: "#{kind}:#{System.unique_integer([:positive])}",
      status: status,
      message: kind |> String.replace("_", " ") |> String.capitalize(),
      details: %{"slot" => "CPU1"},
      resolved_at: resolved_at,
      last_observed_at: ~U[2026-08-20 12:00:00.000000Z]
    })
    |> Repo.insert!()
  end
end
